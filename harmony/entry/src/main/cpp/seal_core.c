/*
 * The crypto core of the phone side seal (AES-256-GCM) — see seal_core.h.
 *
 * Everything is done with the native C API of the system crypto framework
 * (`CryptoArchitectureKit`, `libohcrypto.so`): the same implementation the ArkTS
 * `cryptoFramework` is built on, but without the ArkTS marshalling that fails on this device.
 *
 * The GCM convention of the framework is the documented one:
 *   - encryption: the output of Final() is `ciphertext || tag(16)`, the tag travels in its own
 *     parameter,
 *   - decryption: the tag is given in the parameter and verified; the input is the ciphertext.
 *
 * No C++ exceptions are used (the NDK builds without them) and no error is thrown: every
 * failure is a status code.
 */

#include "seal_core.h"

#include <stdlib.h>
#include <string.h>

#include "CryptoArchitectureKit/crypto_common.h"
#include "CryptoArchitectureKit/crypto_kdf.h"
#include "CryptoArchitectureKit/crypto_rand.h"
#include "CryptoArchitectureKit/crypto_sym_cipher.h"
#include "CryptoArchitectureKit/crypto_sym_key.h"

/** The algorithm of the seal: AES-256 in GCM mode without padding. */
#define DSH_SEAL_ALGORITHM "AES256|GCM|NoPadding"
/** The algorithm of the key. */
#define DSH_SEAL_KEY_ALGORITHM "AES256"
/** The algorithm of the key derivation. */
#define DSH_SEAL_KDF_ALGORITHM "HKDF|SHA256"

/** Which shape the framework used (see dsh_seal_variant). */
static int g_variant = 0;

int dsh_seal_variant(void)
{
    return g_variant;
}

const char *dsh_seal_status_message(DshSealStatus status)
{
    switch (status) {
        case DSH_SEAL_OK:
            return "ok";
        case DSH_SEAL_ERR_INVALID:
            return "the arguments of the seal are not valid";
        case DSH_SEAL_ERR_CRYPTO:
            return "the system crypto framework refused the operation";
        case DSH_SEAL_ERR_MEMORY:
            return "out of memory";
        case DSH_SEAL_ERR_UNSUPPORTED:
            return "the device does not support AES-256-GCM";
        default:
            return "unknown seal error";
    }
}

/** Turn the error code of the framework into a status code. */
static DshSealStatus status_of(OH_Crypto_ErrCode code)
{
    if (code == CRYPTO_SUCCESS) {
        return DSH_SEAL_OK;
    }
    if (code == CRYPTO_NOT_SUPPORTED) {
        return DSH_SEAL_ERR_UNSUPPORTED;
    }
    if (code == CRYPTO_MEMORY_ERROR) {
        return DSH_SEAL_ERR_MEMORY;
    }
    return DSH_SEAL_ERR_CRYPTO;
}

/** Copy a buffer into a fresh one that the caller frees with dsh_seal_bytes_free. */
static DshSealStatus copy_bytes(const uint8_t *data, size_t len, DshSealBytes *out)
{
    out->data = NULL;
    out->len = 0;
    if (len == 0) {
        return DSH_SEAL_OK;
    }
    if (data == NULL) {
        return DSH_SEAL_ERR_INVALID;
    }
    out->data = (uint8_t *)malloc(len);
    if (out->data == NULL) {
        return DSH_SEAL_ERR_MEMORY;
    }
    memcpy(out->data, data, len);
    out->len = len;
    return DSH_SEAL_OK;
}

/** Turn the raw key bytes into a key of the framework. */
static DshSealStatus import_key(const uint8_t *key, size_t key_len, OH_CryptoSymKey **out_key)
{
    OH_CryptoSymKeyGenerator *generator = NULL;
    OH_Crypto_ErrCode code = OH_CryptoSymKeyGenerator_Create(DSH_SEAL_KEY_ALGORITHM, &generator);
    if (code != CRYPTO_SUCCESS) {
        return status_of(code);
    }
    Crypto_DataBlob blob;
    blob.data = (uint8_t *)key;
    blob.len = (uint32_t)key_len;
    code = OH_CryptoSymKeyGenerator_Convert(generator, &blob, out_key);
    OH_CryptoSymKeyGenerator_Destroy(generator);
    return status_of(code);
}

/**
 * Run one cipher operation.
 *
 * @param mode CRYPTO_ENCRYPT_MODE or CRYPTO_DECRYPT_MODE
 * @param key the seal key
 * @param iv the nonce
 * @param aad the additional data
 * @param tag the tag: for the encryption it is a zero buffer of DSH_SEAL_TAG_BYTES bytes (the
 *   framework only looks at its length), for the decryption it is the tag to verify
 * @param in the input
 * @param out the output
 * @param out_len the expected length of the output (0 when it does not matter)
 */
static DshSealStatus run_cipher(int mode, const uint8_t *key, size_t key_len,
                                 const uint8_t *iv, size_t iv_len,
                                 const uint8_t *aad, size_t aad_len,
                                 const uint8_t *tag, size_t tag_len,
                                 const uint8_t *in, size_t in_len,
                                 DshSealBytes *out)
{
    OH_CryptoSymKey *sym_key = NULL;
    OH_CryptoSymCipher *ctx = NULL;
    OH_CryptoSymCipherParams *params = NULL;
    DshSealStatus status = DSH_SEAL_ERR_CRYPTO;
    Crypto_DataBlob out_blob;
    Crypto_DataBlob final_blob;

    out->data = NULL;
    out->len = 0;
    memset(&out_blob, 0, sizeof(out_blob));
    memset(&final_blob, 0, sizeof(final_blob));

    status = import_key(key, key_len, &sym_key);
    if (status != DSH_SEAL_OK) {
        return status;
    }

    OH_Crypto_ErrCode code = OH_CryptoSymCipher_Create(DSH_SEAL_ALGORITHM, &ctx);
    if (code != CRYPTO_SUCCESS) {
        status = status_of(code);
        goto cleanup;
    }

    code = OH_CryptoSymCipherParams_Create(&params);
    if (code != CRYPTO_SUCCESS) {
        status = status_of(code);
        goto cleanup;
    }

    Crypto_DataBlob iv_blob;
    iv_blob.data = (uint8_t *)iv;
    iv_blob.len = (uint32_t)iv_len;
    code = OH_CryptoSymCipherParams_SetParam(params, CRYPTO_IV_DATABLOB, &iv_blob);
    if (code != CRYPTO_SUCCESS) {
        status = status_of(code);
        goto cleanup;
    }

    Crypto_DataBlob aad_blob;
    aad_blob.data = (uint8_t *)aad;
    aad_blob.len = (uint32_t)aad_len;
    code = OH_CryptoSymCipherParams_SetParam(params, CRYPTO_AAD_DATABLOB, &aad_blob);
    if (code != CRYPTO_SUCCESS) {
        status = status_of(code);
        goto cleanup;
    }

    Crypto_DataBlob tag_blob;
    tag_blob.data = (uint8_t *)tag;
    tag_blob.len = (uint32_t)tag_len;
    code = OH_CryptoSymCipherParams_SetParam(params, CRYPTO_TAG_DATABLOB, &tag_blob);
    if (code != CRYPTO_SUCCESS) {
        status = status_of(code);
        goto cleanup;
    }

    code = OH_CryptoSymCipher_Init(ctx, (Crypto_CipherMode)mode, sym_key, params);
    if (code != CRYPTO_SUCCESS) {
        status = status_of(code);
        goto cleanup;
    }

    Crypto_DataBlob in_blob;
    in_blob.data = (uint8_t *)in;
    in_blob.len = (uint32_t)in_len;
    code = OH_CryptoSymCipher_Update(ctx, &in_blob, &out_blob);
    if (code != CRYPTO_SUCCESS) {
        status = status_of(code);
        goto cleanup;
    }

    /* The final call carries no data; it produces the tag (and flushes the cipher). */
    Crypto_DataBlob empty_blob;
    empty_blob.data = NULL;
    empty_blob.len = 0;
    code = OH_CryptoSymCipher_Final(ctx, &empty_blob, &final_blob);
    if (code != CRYPTO_SUCCESS) {
        status = status_of(code);
        goto cleanup;
    }

    /* The framework may return the data in the update buffer, in the final buffer, or in both. */
    size_t total = (size_t)out_blob.len + (size_t)final_blob.len;
    if (total > 0) {
        out->data = (uint8_t *)malloc(total);
        if (out->data == NULL) {
            status = DSH_SEAL_ERR_MEMORY;
            goto cleanup;
        }
        if (out_blob.len > 0) {
            memcpy(out->data, out_blob.data, out_blob.len);
        }
        if (final_blob.len > 0) {
            memcpy(out->data + out_blob.len, final_blob.data, final_blob.len);
        }
        out->len = total;
    }

cleanup:
    if (out_blob.data != NULL) {
        OH_Crypto_FreeDataBlob(&out_blob);
    }
    if (final_blob.data != NULL) {
        OH_Crypto_FreeDataBlob(&final_blob);
    }
    if (params != NULL) {
        OH_CryptoSymCipherParams_Destroy(params);
    }
    if (ctx != NULL) {
        OH_CryptoSymCipher_Destroy(ctx);
    }
    if (sym_key != NULL) {
        OH_CryptoSymKey_Destroy(sym_key);
    }
    return status;
}

DshSealStatus dsh_seal(const uint8_t *key, size_t key_len,
                        const uint8_t *plain, size_t plain_len,
                        const uint8_t *aad, size_t aad_len,
                        const uint8_t *iv, size_t iv_len,
                        DshSealBytes *out_iv, DshSealBytes *out_cipher, DshSealBytes *out_tag)
{
    uint8_t random_iv[DSH_SEAL_IV_BYTES];
    uint8_t tag_buffer[DSH_SEAL_TAG_BYTES];
    DshSealBytes raw;
    DshSealStatus status;

    if (out_iv == NULL || out_cipher == NULL || out_tag == NULL) {
        return DSH_SEAL_ERR_INVALID;
    }
    out_iv->data = NULL;
    out_iv->len = 0;
    out_cipher->data = NULL;
    out_cipher->len = 0;
    out_tag->data = NULL;
    out_tag->len = 0;
    raw.data = NULL;
    raw.len = 0;

    if (key == NULL || key_len != DSH_SEAL_KEY_BYTES) {
        return DSH_SEAL_ERR_INVALID;
    }
    if (plain_len > 0 && plain == NULL) {
        return DSH_SEAL_ERR_INVALID;
    }
    if (aad_len > 0 && aad == NULL) {
        return DSH_SEAL_ERR_INVALID;
    }

    if (iv == NULL) {
        status = dsh_random(random_iv, sizeof(random_iv));
        if (status != DSH_SEAL_OK) {
            return status;
        }
        iv = random_iv;
        iv_len = sizeof(random_iv);
    }
    if (iv_len != DSH_SEAL_IV_BYTES) {
        return DSH_SEAL_ERR_INVALID;
    }

    /* The tag travels in its own parameter; for the encryption only its length matters. */
    memset(tag_buffer, 0, sizeof(tag_buffer));

    status = run_cipher(CRYPTO_ENCRYPT_MODE, key, key_len, iv, iv_len, aad, aad_len,
                         tag_buffer, sizeof(tag_buffer), plain, plain_len, &raw);
    if (status != DSH_SEAL_OK) {
        return status;
    }

    /* The documented shape: the output is `ciphertext || tag(16)`. */
    if (raw.len != plain_len + DSH_SEAL_TAG_BYTES) {
        /* Not the documented shape: give the raw output back, the caller reports it. */
        *out_cipher = raw;
        raw.data = NULL;
        raw.len = 0;
        status = copy_bytes(iv, iv_len, out_iv);
        if (status != DSH_SEAL_OK) {
            return status;
        }
        return DSH_SEAL_ERR_CRYPTO;
    }

    status = copy_bytes(iv, iv_len, out_iv);
    if (status != DSH_SEAL_OK) {
        free(raw.data);
        return status;
    }
    status = copy_bytes(raw.data, plain_len, out_cipher);
    if (status != DSH_SEAL_OK) {
        free(out_iv->data);
        out_iv->data = NULL;
        out_iv->len = 0;
        free(raw.data);
        return status;
    }
    status = copy_bytes(raw.data + plain_len, DSH_SEAL_TAG_BYTES, out_tag);
    free(raw.data);
    if (status != DSH_SEAL_OK) {
        free(out_iv->data);
        out_iv->data = NULL;
        free(out_cipher->data);
        out_cipher->data = NULL;
        return status;
    }
    g_variant = 0;
    return DSH_SEAL_OK;
}

DshSealStatus dsh_unseal(const uint8_t *key, size_t key_len,
                          const uint8_t *iv, size_t iv_len,
                          const uint8_t *cipher, size_t cipher_len,
                          const uint8_t *tag, size_t tag_len,
                          const uint8_t *aad, size_t aad_len,
                          DshSealBytes *out_plain)
{
    DshSealStatus status;

    if (out_plain == NULL) {
        return DSH_SEAL_ERR_INVALID;
    }
    out_plain->data = NULL;
    out_plain->len = 0;

    if (key == NULL || key_len != DSH_SEAL_KEY_BYTES) {
        return DSH_SEAL_ERR_INVALID;
    }
    if (iv == NULL || iv_len != DSH_SEAL_IV_BYTES) {
        return DSH_SEAL_ERR_INVALID;
    }
    if (tag == NULL || tag_len != DSH_SEAL_TAG_BYTES) {
        return DSH_SEAL_ERR_INVALID;
    }
    if (cipher_len > 0 && cipher == NULL) {
        return DSH_SEAL_ERR_INVALID;
    }
    if (aad_len > 0 && aad == NULL) {
        return DSH_SEAL_ERR_INVALID;
    }

    /* The documented shape: the tag is a parameter of its own, the input is the ciphertext. */
    status = run_cipher(CRYPTO_DECRYPT_MODE, key, key_len, iv, iv_len, aad, aad_len,
                         tag, tag_len, cipher, cipher_len, out_plain);
    if (status == DSH_SEAL_OK) {
        g_variant = 0;
        return DSH_SEAL_OK;
    }

    /* Some builds want the tag appended to the ciphertext. Try that before giving up. */
    {
        uint8_t *joined = (uint8_t *)malloc(cipher_len + tag_len);
        if (joined == NULL) {
            return DSH_SEAL_ERR_MEMORY;
        }
        if (cipher_len > 0) {
            memcpy(joined, cipher, cipher_len);
        }
        memcpy(joined + cipher_len, tag, tag_len);
        status = run_cipher(CRYPTO_DECRYPT_MODE, key, key_len, iv, iv_len, aad, aad_len,
                             tag, tag_len, joined, cipher_len + tag_len, out_plain);
        free(joined);
        if (status == DSH_SEAL_OK) {
            g_variant = 1;
            return DSH_SEAL_OK;
        }
    }
    return status;
}

DshSealStatus dsh_hkdf(const uint8_t *ikm, size_t ikm_len,
                        const uint8_t *salt, size_t salt_len,
                        const uint8_t *info, size_t info_len,
                        uint8_t *out, size_t out_len)
{
    OH_CryptoKdf *kdf = NULL;
    OH_CryptoKdfParams *params = NULL;
    DshSealStatus status = DSH_SEAL_ERR_CRYPTO;

    if (out == NULL || out_len == 0 || ikm == NULL || ikm_len == 0) {
        return DSH_SEAL_ERR_INVALID;
    }
    if (salt_len > 0 && salt == NULL) {
        return DSH_SEAL_ERR_INVALID;
    }
    if (info_len > 0 && info == NULL) {
        return DSH_SEAL_ERR_INVALID;
    }

    OH_Crypto_ErrCode code = OH_CryptoKdf_Create(DSH_SEAL_KDF_ALGORITHM, &kdf);
    if (code != CRYPTO_SUCCESS) {
        return status_of(code);
    }
    code = OH_CryptoKdfParams_Create(DSH_SEAL_KDF_ALGORITHM, &params);
    if (code != CRYPTO_SUCCESS) {
        OH_CryptoKdf_Destroy(kdf);
        return status_of(code);
    }

    Crypto_DataBlob key_blob;
    key_blob.data = (uint8_t *)ikm;
    key_blob.len = (uint32_t)ikm_len;
    Crypto_DataBlob salt_blob;
    salt_blob.data = (uint8_t *)salt;
    salt_blob.len = (uint32_t)salt_len;
    Crypto_DataBlob info_blob;
    info_blob.data = (uint8_t *)info;
    info_blob.len = (uint32_t)info_len;

    code = OH_CryptoKdfParams_SetParam(params, CRYPTO_KDF_KEY_DATABLOB, &key_blob);
    if (code == CRYPTO_SUCCESS) {
        code = OH_CryptoKdfParams_SetParam(params, CRYPTO_KDF_SALT_DATABLOB, &salt_blob);
    }
    if (code == CRYPTO_SUCCESS) {
        code = OH_CryptoKdfParams_SetParam(params, CRYPTO_KDF_INFO_DATABLOB, &info_blob);
    }
    if (code != CRYPTO_SUCCESS) {
        status = status_of(code);
        goto cleanup;
    }

    Crypto_DataBlob out_blob;
    memset(&out_blob, 0, sizeof(out_blob));
    code = OH_CryptoKdf_Derive(kdf, params, (int)out_len, &out_blob);
    if (code != CRYPTO_SUCCESS) {
        status = status_of(code);
        goto cleanup;
    }
    if (out_blob.len != out_len) {
        OH_Crypto_FreeDataBlob(&out_blob);
        status = DSH_SEAL_ERR_CRYPTO;
        goto cleanup;
    }
    memcpy(out, out_blob.data, out_len);
    OH_Crypto_FreeDataBlob(&out_blob);
    status = DSH_SEAL_OK;

cleanup:
    OH_CryptoKdfParams_Destroy(params);
    OH_CryptoKdf_Destroy(kdf);
    return status;
}

DshSealStatus dsh_random(uint8_t *out, size_t len)
{
    OH_CryptoRand *rand_ctx = NULL;
    DshSealStatus status = DSH_SEAL_ERR_CRYPTO;

    if (out == NULL) {
        return DSH_SEAL_ERR_INVALID;
    }
    if (len == 0) {
        return DSH_SEAL_OK;
    }

    OH_Crypto_ErrCode code = OH_CryptoRand_Create(&rand_ctx);
    if (code != CRYPTO_SUCCESS) {
        return status_of(code);
    }
    Crypto_DataBlob blob;
    memset(&blob, 0, sizeof(blob));
    code = OH_CryptoRand_GenerateRandom(rand_ctx, (int)len, &blob);
    if (code == CRYPTO_SUCCESS && blob.len == len) {
        memcpy(out, blob.data, len);
        status = DSH_SEAL_OK;
    } else if (code == CRYPTO_SUCCESS) {
        status = DSH_SEAL_ERR_CRYPTO;
    } else {
        status = status_of(code);
    }
    if (blob.data != NULL) {
        OH_Crypto_FreeDataBlob(&blob);
    }
    OH_CryptoRand_Destroy(rand_ctx);
    return status;
}
