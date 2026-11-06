/*
 * The cross platform interop program of the seal.
 *
 * It links the very same crypto core as the napi module (`../seal_core.c`) and seals a fixed
 * input, so that the result can be compared byte for byte with the one the bridge computes
 * (`bridge/src/seal.js`).
 *
 * The vector is read from the standard input, one `name=hex` pair per line:
 *
 *   key=<hex>
 *   iv=<hex>
 *   aad=<hex>
 *   plain=<hex>
 *
 * and the result is written to the standard output in the same shape:
 *
 *   iv=<hex>
 *   ciphertext=<hex>
 *   tag=<hex>
 *   opened=<hex>      the body that comes out of the seal again
 *   variant=<0|1>     the shape the framework used for the ciphertext
 *
 * When the input also carries `ciphertext=<hex>` and `tag=<hex>`, the program does **not** seal
 * anything: it opens that envelope and prints `opened=<hex>` (and `variant=`). That is the other
 * direction of the interop check: the bridge seals, the phone opens.
 *
 * Everything is hex so that no newline or quote has to survive a shell.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../seal_core.h"

/** The maximum length of one line of the vector. */
#define LINE_MAX 8192

/** Read a hex string into a buffer (the caller frees it). */
static uint8_t *from_hex(const char *text, size_t *out_len)
{
    size_t length = strlen(text);
    size_t bytes = length / 2;
    uint8_t *out = (uint8_t *)malloc(bytes > 0 ? bytes : 1);
    if (out == NULL) {
        return NULL;
    }
    for (size_t i = 0; i < bytes; i++) {
        unsigned int value = 0;
        if (sscanf(text + i * 2, "%2x", &value) != 1) {
            free(out);
            return NULL;
        }
        out[i] = (uint8_t)value;
    }
    *out_len = bytes;
    return out;
}

/** Print a buffer as hex. */
static void print_hex(const char *name, const uint8_t *data, size_t length)
{
    printf("%s=", name);
    for (size_t i = 0; i < length; i++) {
        printf("%02x", data[i]);
    }
    printf("\n");
}

/** Read one `name=hex` line; the value is returned in a fresh buffer. */
static int read_field(const char *name, uint8_t **out_data, size_t *out_len)
{
    char line[LINE_MAX];
    size_t name_len = strlen(name);
    while (fgets(line, sizeof(line), stdin) != NULL) {
        size_t length = strlen(line);
        while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r')) {
            line[length - 1] = '\0';
            length -= 1;
        }
        if (strncmp(line, name, name_len) != 0 || line[name_len] != '=') {
            continue;
        }
        *out_data = from_hex(line + name_len + 1, out_len);
        return *out_data != NULL ? 0 : -1;
    }
    return -1;
}

int main(void)
{
    uint8_t *key = NULL;
    uint8_t *iv = NULL;
    uint8_t *aad = NULL;
    uint8_t *plain = NULL;
    size_t key_len = 0;
    size_t iv_len = 0;
    size_t aad_len = 0;
    size_t plain_len = 0;
    DshSealBytes out_iv = {NULL, 0};
    DshSealBytes out_cipher = {NULL, 0};
    DshSealBytes out_tag = {NULL, 0};
    DshSealBytes opened = {NULL, 0};
    DshSealStatus status;

    if (read_field("key", &key, &key_len) != 0 || read_field("iv", &iv, &iv_len) != 0
        || read_field("aad", &aad, &aad_len) != 0 || read_field("plain", &plain, &plain_len) != 0) {
        fprintf(stderr, "the vector is not complete (key, iv, aad, plain are needed)\n");
        free(key);
        free(iv);
        free(aad);
        free(plain);
        return 2;
    }

    /* The other direction: the vector carries an envelope to open instead of a body to seal. */
    {
        uint8_t *given_cipher = NULL;
        uint8_t *given_tag = NULL;
        size_t given_cipher_len = 0;
        size_t given_tag_len = 0;
        bool has_cipher = read_field("ciphertext", &given_cipher, &given_cipher_len) == 0;
        bool has_tag = read_field("tag", &given_tag, &given_tag_len) == 0;
        if (has_cipher && has_tag) {
            status = dsh_unseal(key, key_len, iv, iv_len, given_cipher, given_cipher_len,
                                given_tag, given_tag_len, aad, aad_len, &opened);
            if (status != DSH_SEAL_OK) {
                fprintf(stderr, "the seal could not be opened: %s\n", dsh_seal_status_message(status));
                free(given_cipher);
                free(given_tag);
                free(key);
                free(iv);
                free(aad);
                free(plain);
                return 1;
            }
            print_hex("opened", opened.data, opened.len);
            printf("variant=%d\n", dsh_seal_variant());
            free(opened.data);
            free(given_cipher);
            free(given_tag);
            free(key);
            free(iv);
            free(aad);
            free(plain);
            return 0;
        }
        free(given_cipher);
        free(given_tag);
    }

    status = dsh_seal(key, key_len, plain, plain_len, aad, aad_len, iv, iv_len,
                      &out_iv, &out_cipher, &out_tag);
    if (status != DSH_SEAL_OK) {
        fprintf(stderr, "the seal failed: %s\n", dsh_seal_status_message(status));
        free(key);
        free(iv);
        free(aad);
        free(plain);
        return 1;
    }

    print_hex("iv", out_iv.data, out_iv.len);
    print_hex("ciphertext", out_cipher.data, out_cipher.len);
    print_hex("tag", out_tag.data, out_tag.len);

    /* Open the envelope again with the same key. */
    status = dsh_unseal(key, key_len, out_iv.data, out_iv.len, out_cipher.data, out_cipher.len,
                        out_tag.data, out_tag.len, aad, aad_len, &opened);
    if (status != DSH_SEAL_OK) {
        fprintf(stderr, "the seal could not be opened: %s\n", dsh_seal_status_message(status));
        free(out_iv.data);
        free(out_cipher.data);
        free(out_tag.data);
        free(key);
        free(iv);
        free(aad);
        free(plain);
        return 1;
    }
    print_hex("opened", opened.data, opened.len);
    printf("variant=%d\n", dsh_seal_variant());
    free(opened.data);
    free(out_iv.data);
    free(out_cipher.data);
    free(out_tag.data);
    free(key);
    free(iv);
    free(aad);
    free(plain);
    return 0;
}
