/*
 * The crypto core of the phone side seal (AES-256-GCM).
 *
 * The ArkTS `cryptoFramework` cannot marshal the cipher parameter objects on this device
 * (init answers 401 "build context for init fail"), so the cipher half runs in the native
 * layer: the very same framework, but reached through its C API
 * (`CryptoArchitectureKit` -> `libohcrypto.so`).
 *
 * The core is plain C so that the exact same code can be linked into the napi module and into
 * the cross platform interop program (`test/seal_interop.c`).
 *
 * The wire format is the one of `bridge/src/seal.js`:
 *
 *   envelope = iv(12B) || ciphertext || tag(16B)          (base64 on the wire)
 *   aad      = METHOD "\n" PATH "\n" TIMESTAMP            (for a body)
 *   aad      = "<accountId>:<deviceId>"                    (for the wrapped seal key)
 */

#ifndef DSH_SEAL_CORE_H
#define DSH_SEAL_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** The length of the nonce in bytes. */
#define DSH_SEAL_IV_BYTES 12
/** The length of the authentication tag in bytes. */
#define DSH_SEAL_TAG_BYTES 16
/** The length of a seal key in bytes. */
#define DSH_SEAL_KEY_BYTES 32

/** A buffer of bytes owned by the caller. */
typedef struct DshSealBytes {
    uint8_t *data;
    size_t len;
} DshSealBytes;

/** The result of an operation. */
typedef enum DshSealStatus {
    DSH_SEAL_OK = 0,
    /** The arguments do not make sense (wrong length, missing buffer, …). */
    DSH_SEAL_ERR_INVALID = 1,
    /** The system crypto framework refused the operation. */
    DSH_SEAL_ERR_CRYPTO = 2,
    /** Out of memory. */
    DSH_SEAL_ERR_MEMORY = 3,
    /** The device does not know the algorithm. */
    DSH_SEAL_ERR_UNSUPPORTED = 4
} DshSealStatus;

/**
 * Seal a body with AES-256-GCM.
 *
 * @param key the 32 bytes of the seal key
 * @param key_len the length of the key (32)
 * @param plain the body
 * @param plain_len the length of the body
 * @param aad the additional data bound into the tag (may be NULL when aad_len is 0)
 * @param aad_len the length of the additional data
 * @param iv the nonce to use; when NULL a random one is generated
 * @param iv_len the length of the nonce (12)
 * @param out_iv the nonce that was used (12 bytes, allocated by the core)
 * @param out_cipher the ciphertext (allocated by the core)
 * @param out_tag the authentication tag (16 bytes, allocated by the core)
 * @return DSH_SEAL_OK on success
 */
DshSealStatus dsh_seal(const uint8_t *key, size_t key_len,
                        const uint8_t *plain, size_t plain_len,
                        const uint8_t *aad, size_t aad_len,
                        const uint8_t *iv, size_t iv_len,
                        DshSealBytes *out_iv, DshSealBytes *out_cipher, DshSealBytes *out_tag);

/**
 * Open a seal with AES-256-GCM.
 *
 * @param key the 32 bytes of the seal key
 * @param key_len the length of the key (32)
 * @param iv the nonce of the envelope
 * @param iv_len the length of the nonce (12)
 * @param cipher the ciphertext
 * @param cipher_len the length of the ciphertext
 * @param tag the authentication tag
 * @param tag_len the length of the tag (16)
 * @param aad the additional data bound into the tag
 * @param aad_len the length of the additional data
 * @param out_plain the body (allocated by the core)
 * @return DSH_SEAL_OK on success, DSH_SEAL_ERR_CRYPTO when the tag does not match
 */
DshSealStatus dsh_unseal(const uint8_t *key, size_t key_len,
                          const uint8_t *iv, size_t iv_len,
                          const uint8_t *cipher, size_t cipher_len,
                          const uint8_t *tag, size_t tag_len,
                          const uint8_t *aad, size_t aad_len,
                          DshSealBytes *out_plain);

/**
 * Derive a key with HKDF-SHA256.
 *
 * @param ikm the input key material
 * @param ikm_len the length of the input key material
 * @param salt the salt
 * @param salt_len the length of the salt
 * @param info the info label
 * @param info_len the length of the info label
 * @param out the derived key (out_len bytes, written by the core)
 * @param out_len the length of the derived key
 * @return DSH_SEAL_OK on success
 */
DshSealStatus dsh_hkdf(const uint8_t *ikm, size_t ikm_len,
                        const uint8_t *salt, size_t salt_len,
                        const uint8_t *info, size_t info_len,
                        uint8_t *out, size_t out_len);

/**
 * Fill a buffer with random bytes.
 *
 * @param out the buffer
 * @param len the length of the buffer
 * @return DSH_SEAL_OK on success
 */
DshSealStatus dsh_random(uint8_t *out, size_t len);

/** A human readable reason for a status code (never NULL). */
const char *dsh_seal_status_message(DshSealStatus status);

/**
 * Which shape the system framework used for the ciphertext.
 *
 * 0: the tag travels in its own parameter (the documented shape)
 * 1: the framework wants the tag appended to the ciphertext
 */
int dsh_seal_variant(void);

#ifdef __cplusplus
}
#endif

#endif /* DSH_SEAL_CORE_H */
