#include "webhook_transfer.h"

#include <curl/curl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct webhook_transfer {
    atomic_int cancel;
    int status;
    int have_status;
};

static pthread_once_t curl_once = PTHREAD_ONCE_INIT;
static atomic_int arm_cancel_after_status = 0;

static void initialize_curl(void) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

webhook_transfer *webhook_transfer_create(void) {
    pthread_once(&curl_once, initialize_curl);
    struct webhook_transfer *transfer = calloc(1, sizeof(*transfer));
    return transfer;
}

void webhook_transfer_destroy(webhook_transfer *transfer) {
    free(transfer);
}

void webhook_transfer_cancel(webhook_transfer *transfer) {
    if (transfer != NULL) {
        atomic_store(&transfer->cancel, 1);
    }
}

void webhook_transfer_arm_cancel_after_status(int enabled) {
    atomic_store(&arm_cancel_after_status, enabled ? 1 : 0);
}

static int http_status_line(const char *buffer, size_t total) {
    if (total < 10 || memcmp(buffer, "HTTP/", 5) != 0) {
        return -1;
    }
    const char *space = memchr(buffer, ' ', total);
    if (space == NULL) {
        return -1;
    }
    const char *code = space + 1;
    if ((size_t)(buffer + total - code) < 3) {
        return -1;
    }
    if (code[0] < '0' || code[0] > '9' || code[1] < '0' || code[1] > '9' || code[2] < '0' || code[2] > '9') {
        return -1;
    }
    if ((size_t)(buffer + total - code) > 3) {
        char mark = code[3];
        if (mark != ' ' && mark != '\r' && mark != '\n') {
            return -1;
        }
    }
    return (code[0] - '0') * 100 + (code[1] - '0') * 10 + (code[2] - '0');
}

static int pseudo_status(const char *buffer, size_t total) {
    if (total < 11 || memcmp(buffer, ":status:", 8) != 0) {
        return -1;
    }
    size_t index = 8;
    while (index < total && (buffer[index] == ' ' || buffer[index] == '\t')) {
        index++;
    }
    if (index + 3 > total) {
        return -1;
    }
    const char *code = buffer + index;
    if (code[0] < '0' || code[0] > '9' || code[1] < '0' || code[1] > '9' || code[2] < '0' || code[2] > '9') {
        return -1;
    }
    return (code[0] - '0') * 100 + (code[1] - '0') * 10 + (code[2] - '0');
}

static size_t on_header(char *buffer, size_t size, size_t nitems, void *userdata) {
    size_t total = size * nitems;
    struct webhook_transfer *transfer = userdata;
    int code = http_status_line(buffer, total);
    if (code < 0) {
        code = pseudo_status(buffer, total);
    }
    if (code >= 100 && code <= 199) {
        return total;
    }
    if (code >= 200 && code <= 599) {
        transfer->status = code;
        transfer->have_status = 1;
        if (atomic_load(&arm_cancel_after_status)) {
            atomic_store(&transfer->cancel, 1);
        }
        /* Stop before the body. A later stall must not erase this status. */
        return 0;
    }
    return total;
}

static size_t on_body(char *buffer, size_t size, size_t nitems, void *userdata) {
    (void)buffer;
    (void)size;
    (void)nitems;
    (void)userdata;
    return 0;
}

static struct curl_slist *append_header(struct curl_slist *headers, const char *line) {
    struct curl_slist *added = curl_slist_append(headers, line);
    if (added == NULL) {
        curl_slist_free_all(headers);
        return NULL;
    }
    return added;
}

static char *authorization_header(const char *authorization) {
    static const char prefix[] = "Authorization: ";
    size_t prefix_length = sizeof(prefix) - 1;
    size_t auth_length = strlen(authorization);
    if (auth_length > 4096) {
        return NULL;
    }
    char *line = malloc(prefix_length + auth_length + 1);
    if (line == NULL) {
        return NULL;
    }
    memcpy(line, prefix, prefix_length);
    memcpy(line + prefix_length, authorization, auth_length);
    line[prefix_length + auth_length] = '\0';
    return line;
}

static long elapsed_ms(const struct timespec *start) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long)(now.tv_sec - start->tv_sec) * 1000L
        + (long)(now.tv_nsec - start->tv_nsec) / 1000000L;
}

int webhook_transfer_perform(
    webhook_transfer *transfer,
    const char *url,
    const char *authorization,
    const void *body,
    size_t body_length,
    long timeout_ms,
    int *status_out
) {
    if (status_out != NULL) {
        *status_out = 0;
    }
    if (transfer == NULL || url == NULL || authorization == NULL || status_out == NULL) {
        return 1;
    }
    if (body == NULL && body_length != 0) {
        return 1;
    }
    if (timeout_ms <= 0) {
        timeout_ms = 1;
    }
    transfer->status = 0;
    transfer->have_status = 0;

    CURL *easy = curl_easy_init();
    CURLM *multi = curl_multi_init();
    struct curl_slist *headers = NULL;
    char *auth_line = authorization_header(authorization);
    const char *payload = body != NULL ? body : "";
    int attempted = 0;
    int observed = 0;
    if (easy == NULL || multi == NULL || auth_line == NULL) {
        goto done;
    }

    headers = append_header(NULL, auth_line);
    if (headers == NULL) goto done;
    headers = append_header(headers, "Content-Type: application/json");
    if (headers == NULL) goto done;
    headers = append_header(headers, "Accept: application/json");
    if (headers == NULL) goto done;
    headers = append_header(headers, "Expect:");
    if (headers == NULL) goto done;

    curl_easy_setopt(easy, CURLOPT_URL, url);
    curl_easy_setopt(easy, CURLOPT_POST, 1L);
    curl_easy_setopt(easy, CURLOPT_POSTFIELDS, payload);
    curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_length);
    curl_easy_setopt(easy, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, on_header);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, transfer);
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, on_body);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, transfer);
    /* "" is libcurl's explicit "ignore http_proxy / all_proxy", on every platform. */
    curl_easy_setopt(easy, CURLOPT_PROXY, "");
    curl_easy_setopt(easy, CURLOPT_NOPROXY, "*");
    curl_easy_setopt(easy, CURLOPT_HTTPPROXYTUNNEL, 0L);
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(easy, CURLOPT_MAXREDIRS, 0L);
    curl_easy_setopt(easy, CURLOPT_UNRESTRICTED_AUTH, 0L);
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, timeout_ms);
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, timeout_ms);
    curl_easy_setopt(easy, CURLOPT_FRESH_CONNECT, 1L);
    curl_easy_setopt(easy, CURLOPT_FORBID_REUSE, 1L);
    curl_easy_setopt(easy, CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(easy, CURLOPT_REDIR_PROTOCOLS_STR, "");

    if (curl_multi_add_handle(multi, easy) != CURLM_OK) goto done;
    struct timespec started;
    clock_gettime(CLOCK_MONOTONIC, &started);
    for (;;) {
        if (atomic_load(&transfer->cancel)) break;
        attempted = 1;
        int running = 0;
        CURLMcode code = curl_multi_perform(multi, &running);
        if (transfer->have_status) {
            break;
        }
        if (code != CURLM_OK) {
            break;
        }
        if (running == 0 || elapsed_ms(&started) > timeout_ms + 250L) {
            break;
        }
        int fds = 0;
        curl_multi_poll(multi, NULL, 0, 50, &fds);
    }
    curl_multi_remove_handle(multi, easy);
    if (transfer->have_status) {
        *status_out = transfer->status;
        observed = 1;
    }

done:
    if (multi != NULL) {
        curl_multi_cleanup(multi);
    }
    if (easy != NULL) {
        curl_easy_cleanup(easy);
    }
    curl_slist_free_all(headers);
    free(auth_line);
    if (observed) return 0;
    return attempted ? 1 : 2;
}
