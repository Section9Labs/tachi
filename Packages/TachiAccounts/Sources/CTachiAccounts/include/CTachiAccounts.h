#pragma once
#include <sqlite3.h>
#include <stdint.h>
#include <stddef.h>

int tachi_sha256(const uint8_t *input, size_t length, uint8_t output[32]);
