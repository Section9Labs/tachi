#include "CTachiAccounts.h"

#ifdef __APPLE__
#include <CommonCrypto/CommonDigest.h>
#else
#include <openssl/sha.h>
#endif

int tachi_sha256(const uint8_t *input, size_t length, uint8_t output[32]) {
#ifdef __APPLE__
    return CC_SHA256(input, (CC_LONG)length, output) != NULL;
#else
    return SHA256(input, length, output) != NULL;
#endif
}
