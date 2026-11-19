#ifndef TACHI_WEBHOOK_TRANSFER_H
#define TACHI_WEBHOOK_TRANSFER_H

#include <stddef.h>

typedef struct webhook_transfer webhook_transfer;

webhook_transfer *webhook_transfer_create(void);
void webhook_transfer_destroy(webhook_transfer *transfer);
void webhook_transfer_cancel(webhook_transfer *transfer);

/* One POST. Returns 0 and writes status_out when a final status line was
   parsed. Returns 1 for an unobserved submission, or 2 if the transfer
   never started. Never
   formats the URL, path, or authorization into an error string. */
int webhook_transfer_perform(
    webhook_transfer *transfer,
    const char *url,
    const char *authorization,
    const void *body,
    size_t body_length,
    long timeout_ms,
    int *status_out
);

/* Test seam. After a final status is stored, also raise the cancel flag
   before perform returns. Production leaves this off. */
void webhook_transfer_arm_cancel_after_status(int enabled);

#endif
