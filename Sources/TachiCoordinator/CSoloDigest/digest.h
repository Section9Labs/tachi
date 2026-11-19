#include <stdint.h>
#ifdef __APPLE__
#include <CommonCrypto/CommonDigest.h>
static inline void solo_digest(const void *bytes, size_t count, unsigned char *output) {
    CC_SHA256(bytes, (CC_LONG)count, output);
}
#else
#include <openssl/sha.h>
static inline void solo_digest(const void *bytes, size_t count, unsigned char *output) {
    SHA256(bytes, count, output);
}
#endif
