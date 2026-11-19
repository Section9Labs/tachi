#pragma once
#include <sqlite3.h>
#include <stdint.h>
#include <stddef.h>

int tachi_sha256(const uint8_t *input, size_t length, uint8_t output[32]);

#ifdef __APPLE__
#include <fcntl.h>
static inline int tachi_open_child(int directory, const char *name) {
    return openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_NOFOLLOW | O_CLOEXEC);
}
#endif
