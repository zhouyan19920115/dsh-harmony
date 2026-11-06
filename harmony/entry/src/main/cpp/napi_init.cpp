/*
 * The napi surface of the phone side seal.
 *
 * The ArkTS side (`common/NativeSeal.ets`) calls these functions; the crypto itself lives in
 * `seal_core.c` (plain C, the system crypto framework).
 *
 *   seal(plainText: string, aad: string, iv?: Uint8Array)
 *       -> { iv: Uint8Array, ciphertext: Uint8Array, tag: Uint8Array }
 *   unseal(iv: Uint8Array, ciphertext: Uint8Array, tag: Uint8Array, aad: string) -> string
 *   hkdf(ikm: string, salt: string, info: string, length: number) -> Uint8Array
 *   random(length: number) -> Uint8Array
 *   selfTest() -> { ok: boolean, reason: string }
 *   variant() -> number          (which GCM shape the framework used, for the diagnostics)
 *
 * No C++ exceptions are used: every failure is an error that is thrown to the caller with a
 * message that says what went wrong.
 */

#include "napi/native_api.h"
#include "hilog/log.h"

#include <cstdlib>
#include <cstring>
#include <string>

#include "seal_core.h"

/**
 * The name of the module.
 *
 * ⚠️ It has to be a **constant**, not a `const char *` variable.
 *
 * `g_seal_module` (below) copies this pointer, and "the value of a pointer variable" is *not* a
 * constant expression — so the whole `napi_module` struct would need **dynamic** initialization.
 * The dynamic initialization of a translation unit runs in `.init_array`, and GCC puts the
 * `__attribute__((constructor))` function of that same unit **before** it (verified with
 * `llvm-readelf -r libseal.so`: `.init_array` = [.., RegisterSealModule, _GLOBAL__sub_I_napi_init.cpp]).
 *
 * The consequence was fatal: `napi_module_register()` ran while `g_seal_module` was still the
 * all-zero image, so the runtime got a module with **no name** and **no register function**:
 *
 *   MMG:  [NMM:1466] app module: Name mismatch: default/seal != default/
 *   NAPI: [LoadNativeModule] init module failed, moduleName:seal
 *   ArkCompiler: export objects of native so is undefined, so name is @normalized:Y&&&libseal.so&
 *
 * ⇒ the ArkTS side got `undefined` and the whole seal channel fell back to plain text.
 * With `constexpr` the struct is a constant initializer: the loader builds it at load time,
 * long before any constructor runs.
 */
static constexpr char MODULE_NAME[] = "seal";
/** The domain and the tag of the log of the module. */
static constexpr unsigned int SEAL_LOG_DOMAIN = 0xFF04;
static const char *SEAL_LOG_TAG = "DshHarmony";

/** Throw an error with a message and return NULL. */
static napi_value throw_error(napi_env env, const std::string &message)
{
    napi_throw_error(env, nullptr, message.c_str());
    return nullptr;
}

/** Read a string argument as UTF-8 bytes. */
static bool read_string(napi_env env, napi_value value, std::string &out)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return false;
    }
    out.resize(length);
    size_t written = 0;
    if (napi_get_value_string_utf8(env, value, &out[0], length + 1, &written) != napi_ok) {
        return false;
    }
    out.resize(written);
    return true;
}

/** Read an optional Uint8Array argument into a buffer (the caller frees it). */
static uint8_t *read_bytes(napi_env env, napi_value value, size_t &out_len, bool &ok)
{
    ok = true;
    out_len = 0;
    bool is_array = false;
    if (napi_is_arraybuffer(env, value, &is_array) != napi_ok || !is_array) {
        bool is_typed = false;
        if (napi_is_typedarray(env, value, &is_typed) != napi_ok || !is_typed) {
            ok = false;
            return nullptr;
        }
    }
    void *data = nullptr;
    size_t length = 0;
    if (napi_get_typedarray_info(env, value, nullptr, &length, &data, nullptr, nullptr) != napi_ok) {
        ok = false;
        return nullptr;
    }
    uint8_t *copy = static_cast<uint8_t *>(malloc(length > 0 ? length : 1));
    if (copy == nullptr) {
        ok = false;
        return nullptr;
    }
    if (length > 0 && data != nullptr) {
        memcpy(copy, data, length);
    }
    out_len = length;
    return copy;
}

/** Build a Uint8Array out of a buffer (the buffer is copied). */
static napi_value make_bytes(napi_env env, const uint8_t *data, size_t length)
{
    void *buffer_data = nullptr;
    napi_value buffer = nullptr;
    if (napi_create_arraybuffer(env, length, &buffer_data, &buffer) != napi_ok) {
        return nullptr;
    }
    if (length > 0 && data != nullptr) {
        memcpy(buffer_data, data, length);
    }
    napi_value result = nullptr;
    if (napi_create_typedarray(env, napi_uint8_array, length, buffer, 0, &result) != napi_ok) {
        return nullptr;
    }
    return result;
}

/** Build an object with three byte fields. */
static napi_value make_seal_result(napi_env env, const DshSealBytes &iv, const DshSealBytes &cipher,
                                    const DshSealBytes &tag)
{
    napi_value result = nullptr;
    if (napi_create_object(env, &result) != napi_ok) {
        return nullptr;
    }
    napi_value iv_value = make_bytes(env, iv.data, iv.len);
    napi_value cipher_value = make_bytes(env, cipher.data, cipher.len);
    napi_value tag_value = make_bytes(env, tag.data, tag.len);
    if (iv_value == nullptr || cipher_value == nullptr || tag_value == nullptr) {
        return nullptr;
    }
    napi_set_named_property(env, result, "iv", iv_value);
    napi_set_named_property(env, result, "ciphertext", cipher_value);
    napi_set_named_property(env, result, "tag", tag_value);
    return result;
}

/**
 * seal(key, plainText, aad, iv?)
 *
 * The key is a byte array of 32 bytes and travels as an argument: the ArkTS side keeps it out of
 * the strings, and the wrapper (`common/NativeSeal.ets`) hides it behind the key it holds.
 */
static napi_value SealWithKey(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 3) {
        return throw_error(env, "seal needs a key, a plain text and an aad");
    }

    size_t key_len = 0;
    bool ok = false;
    uint8_t *key = read_bytes(env, argv[0], key_len, ok);
    if (!ok) {
        return throw_error(env, "the key must be a Uint8Array");
    }

    std::string plain;
    std::string aad;
    if (!read_string(env, argv[1], plain) || !read_string(env, argv[2], aad)) {
        free(key);
        return throw_error(env, "the plain text and the aad must be strings");
    }

    uint8_t *iv = nullptr;
    size_t iv_len = 0;
    if (argc >= 4) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[3], &type);
        if (type != napi_undefined && type != napi_null) {
            iv = read_bytes(env, argv[3], iv_len, ok);
            if (!ok) {
                free(key);
                return throw_error(env, "the iv must be a Uint8Array");
            }
        }
    }

    DshSealBytes out_iv = {nullptr, 0};
    DshSealBytes out_cipher = {nullptr, 0};
    DshSealBytes out_tag = {nullptr, 0};
    DshSealStatus status = dsh_seal(key, key_len,
                                     reinterpret_cast<const uint8_t *>(plain.data()), plain.size(),
                                     reinterpret_cast<const uint8_t *>(aad.data()), aad.size(),
                                     iv, iv_len,
                                     &out_iv, &out_cipher, &out_tag);
    free(key);
    if (iv != nullptr) {
        free(iv);
    }
    if (status != DSH_SEAL_OK) {
        return throw_error(env, std::string("the seal failed: ") + dsh_seal_status_message(status));
    }

    napi_value result = make_seal_result(env, out_iv, out_cipher, out_tag);
    free(out_iv.data);
    free(out_cipher.data);
    free(out_tag.data);
    if (result == nullptr) {
        return throw_error(env, "the seal result could not be built");
    }
    return result;
}

/** unseal(iv, ciphertext, tag, aad, key) */
static napi_value Unseal(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value argv[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 5) {
        return throw_error(env, "unseal needs the iv, the ciphertext, the tag, the aad and the key");
    }

    size_t iv_len = 0;
    size_t cipher_len = 0;
    size_t tag_len = 0;
    size_t key_len = 0;
    bool ok = false;
    uint8_t *iv = read_bytes(env, argv[0], iv_len, ok);
    if (!ok) {
        return throw_error(env, "the iv must be a Uint8Array");
    }
    uint8_t *cipher = read_bytes(env, argv[1], cipher_len, ok);
    if (!ok) {
        free(iv);
        return throw_error(env, "the ciphertext must be a Uint8Array");
    }
    uint8_t *tag = read_bytes(env, argv[2], tag_len, ok);
    if (!ok) {
        free(iv);
        free(cipher);
        return throw_error(env, "the tag must be a Uint8Array");
    }
    uint8_t *key = read_bytes(env, argv[4], key_len, ok);
    if (!ok) {
        free(iv);
        free(cipher);
        free(tag);
        return throw_error(env, "the key must be a Uint8Array");
    }

    std::string aad;
    if (!read_string(env, argv[3], aad)) {
        free(iv);
        free(cipher);
        free(tag);
        free(key);
        return throw_error(env, "the aad must be a string");
    }

    DshSealBytes out_plain = {nullptr, 0};
    DshSealStatus status = dsh_unseal(key, key_len, iv, iv_len, cipher, cipher_len, tag, tag_len,
                                      reinterpret_cast<const uint8_t *>(aad.data()), aad.size(), &out_plain);
    free(iv);
    free(cipher);
    free(tag);
    free(key);
    if (status != DSH_SEAL_OK) {
        return throw_error(env, std::string("the seal could not be opened: ") + dsh_seal_status_message(status));
    }

    napi_value result = nullptr;
    napi_create_string_utf8(env, reinterpret_cast<const char *>(out_plain.data), out_plain.len, &result);
    free(out_plain.data);
    return result;
}

/**
 * sealBytes(key, plain, aad, iv?)
 *
 * The same as `seal`, but the body and the additional data are byte arrays instead of strings.
 * It is the shape `common/Seal.ets` uses, so the cipher half can be swapped without touching
 * the callers.
 */
static napi_value SealBytes(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 3) {
        return throw_error(env, "sealBytes needs a key, a body and an aad");
    }

    size_t key_len = 0;
    size_t plain_len = 0;
    size_t aad_len = 0;
    bool ok = false;
    uint8_t *key = read_bytes(env, argv[0], key_len, ok);
    if (!ok) {
        return throw_error(env, "the key must be a Uint8Array");
    }
    uint8_t *plain = read_bytes(env, argv[1], plain_len, ok);
    if (!ok) {
        free(key);
        return throw_error(env, "the body must be a Uint8Array");
    }
    uint8_t *aad = read_bytes(env, argv[2], aad_len, ok);
    if (!ok) {
        free(key);
        free(plain);
        return throw_error(env, "the aad must be a Uint8Array");
    }

    uint8_t *iv = nullptr;
    size_t iv_len = 0;
    if (argc >= 4) {
        napi_valuetype type = napi_undefined;
        napi_typeof(env, argv[3], &type);
        if (type != napi_undefined && type != napi_null) {
            iv = read_bytes(env, argv[3], iv_len, ok);
            if (!ok) {
                free(key);
                free(plain);
                free(aad);
                return throw_error(env, "the iv must be a Uint8Array");
            }
        }
    }

    DshSealBytes out_iv = {nullptr, 0};
    DshSealBytes out_cipher = {nullptr, 0};
    DshSealBytes out_tag = {nullptr, 0};
    DshSealStatus status = dsh_seal(key, key_len, plain, plain_len, aad, aad_len, iv, iv_len,
                                     &out_iv, &out_cipher, &out_tag);
    free(key);
    free(plain);
    free(aad);
    if (iv != nullptr) {
        free(iv);
    }
    if (status != DSH_SEAL_OK) {
        return throw_error(env, std::string("the seal failed: ") + dsh_seal_status_message(status));
    }
    napi_value result = make_seal_result(env, out_iv, out_cipher, out_tag);
    free(out_iv.data);
    free(out_cipher.data);
    free(out_tag.data);
    if (result == nullptr) {
        return throw_error(env, "the seal result could not be built");
    }
    return result;
}

/** unsealBytes(key, iv, ciphertext, tag, aad) -> Uint8Array */
static napi_value UnsealBytes(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value argv[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 5) {
        return throw_error(env, "unsealBytes needs the key, the iv, the ciphertext, the tag and the aad");
    }

    size_t key_len = 0;
    size_t iv_len = 0;
    size_t cipher_len = 0;
    size_t tag_len = 0;
    size_t aad_len = 0;
    bool ok = false;
    uint8_t *key = read_bytes(env, argv[0], key_len, ok);
    if (!ok) {
        return throw_error(env, "the key must be a Uint8Array");
    }
    uint8_t *iv = read_bytes(env, argv[1], iv_len, ok);
    if (!ok) {
        free(key);
        return throw_error(env, "the iv must be a Uint8Array");
    }
    uint8_t *cipher = read_bytes(env, argv[2], cipher_len, ok);
    if (!ok) {
        free(key);
        free(iv);
        return throw_error(env, "the ciphertext must be a Uint8Array");
    }
    uint8_t *tag = read_bytes(env, argv[3], tag_len, ok);
    if (!ok) {
        free(key);
        free(iv);
        free(cipher);
        return throw_error(env, "the tag must be a Uint8Array");
    }
    uint8_t *aad = read_bytes(env, argv[4], aad_len, ok);
    if (!ok) {
        free(key);
        free(iv);
        free(cipher);
        free(tag);
        return throw_error(env, "the aad must be a Uint8Array");
    }

    DshSealBytes out_plain = {nullptr, 0};
    DshSealStatus status = dsh_unseal(key, key_len, iv, iv_len, cipher, cipher_len, tag, tag_len,
                                      aad, aad_len, &out_plain);
    free(key);
    free(iv);
    free(cipher);
    free(tag);
    free(aad);
    if (status != DSH_SEAL_OK) {
        return throw_error(env, std::string("the seal could not be opened: ") + dsh_seal_status_message(status));
    }
    napi_value result = make_bytes(env, out_plain.data, out_plain.len);
    free(out_plain.data);
    if (result == nullptr) {
        return throw_error(env, "the body could not be built");
    }
    return result;
}

/** hkdf(ikm, salt, info, length) */
static napi_value Hkdf(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 4) {
        return throw_error(env, "hkdf needs the key material, the salt, the info and the length");
    }

    std::string ikm;
    std::string salt;
    std::string info_text;
    if (!read_string(env, argv[0], ikm) || !read_string(env, argv[1], salt) || !read_string(env, argv[2], info_text)) {
        return throw_error(env, "hkdf needs the key material, the salt and the info as strings");
    }
    int32_t length = 0;
    napi_get_value_int32(env, argv[3], &length);
    if (length <= 0 || length > 1024) {
        return throw_error(env, "the length of the derived key must be between 1 and 1024");
    }

    uint8_t *out = static_cast<uint8_t *>(malloc(static_cast<size_t>(length)));
    if (out == nullptr) {
        return throw_error(env, "out of memory");
    }
    DshSealStatus status = dsh_hkdf(reinterpret_cast<const uint8_t *>(ikm.data()), ikm.size(),
                                    reinterpret_cast<const uint8_t *>(salt.data()), salt.size(),
                                    reinterpret_cast<const uint8_t *>(info_text.data()), info_text.size(),
                                    out, static_cast<size_t>(length));
    if (status != DSH_SEAL_OK) {
        free(out);
        return throw_error(env, std::string("the key derivation failed: ") + dsh_seal_status_message(status));
    }
    napi_value result = make_bytes(env, out, static_cast<size_t>(length));
    free(out);
    if (result == nullptr) {
        return throw_error(env, "the derived key could not be built");
    }
    return result;
}

/** random(length) */
static napi_value Random(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t length = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &length);
    }
    if (length <= 0 || length > 4096) {
        return throw_error(env, "the length must be between 1 and 4096");
    }
    uint8_t *out = static_cast<uint8_t *>(malloc(static_cast<size_t>(length)));
    if (out == nullptr) {
        return throw_error(env, "out of memory");
    }
    DshSealStatus status = dsh_random(out, static_cast<size_t>(length));
    if (status != DSH_SEAL_OK) {
        free(out);
        return throw_error(env, std::string("the random bytes failed: ") + dsh_seal_status_message(status));
    }
    napi_value result = make_bytes(env, out, static_cast<size_t>(length));
    free(out);
    if (result == nullptr) {
        return throw_error(env, "the random bytes could not be built");
    }
    return result;
}

/** selfTest() -> { ok, reason } */
static napi_value SelfTest(napi_env env, napi_callback_info info)
{
    uint8_t key[DSH_SEAL_KEY_BYTES];
    uint8_t aad[] = {'s', 'e', 'l', 'f', '-', 't', 'e', 's', 't'};
    const char *plain = "dsh-harmony";
    DshSealBytes iv = {nullptr, 0};
    DshSealBytes cipher = {nullptr, 0};
    DshSealBytes tag = {nullptr, 0};
    DshSealBytes opened = {nullptr, 0};
    DshSealStatus status;
    bool ok = false;
    std::string reason;

    napi_value result = nullptr;
    napi_create_object(env, &result);
    if (result == nullptr) {
        return nullptr;
    }

    status = dsh_random(key, sizeof(key));
    if (status != DSH_SEAL_OK) {
        reason = std::string("the random bytes failed: ") + dsh_seal_status_message(status);
    } else {
        status = dsh_seal(key, sizeof(key), reinterpret_cast<const uint8_t *>(plain), strlen(plain),
                          aad, sizeof(aad), nullptr, 0, &iv, &cipher, &tag);
        if (status != DSH_SEAL_OK) {
            reason = std::string("the seal failed: ") + dsh_seal_status_message(status);
        } else {
            status = dsh_unseal(key, sizeof(key), iv.data, iv.len, cipher.data, cipher.len, tag.data, tag.len,
                                aad, sizeof(aad), &opened);
            if (status != DSH_SEAL_OK) {
                reason = std::string("the seal could not be opened: ") + dsh_seal_status_message(status);
            } else if (opened.len != strlen(plain) || memcmp(opened.data, plain, opened.len) != 0) {
                reason = "the round trip did not come back the same";
            } else {
                ok = true;
                reason = "ok";
            }
        }
    }

    free(iv.data);
    free(cipher.data);
    free(tag.data);
    free(opened.data);

    napi_value ok_value = nullptr;
    napi_get_boolean(env, ok, &ok_value);
    napi_set_named_property(env, result, "ok", ok_value);
    napi_value reason_value = nullptr;
    napi_create_string_utf8(env, reason.c_str(), reason.size(), &reason_value);
    napi_set_named_property(env, result, "reason", reason_value);
    return result;
}

/** variant() -> number */
static napi_value Variant(napi_env env, napi_callback_info info)
{
    napi_value result = nullptr;
    napi_create_int32(env, dsh_seal_variant(), &result);
    return result;
}

/** The module registration. */
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor properties[] = {
        {"seal", nullptr, SealWithKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sealBytes", nullptr, SealBytes, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"unseal", nullptr, Unseal, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"unsealBytes", nullptr, UnsealBytes, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hkdf", nullptr, Hkdf, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"random", nullptr, Random, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"selfTest", nullptr, SelfTest, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"variant", nullptr, Variant, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

static napi_module g_seal_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = MODULE_NAME,
    .nm_priv = nullptr,
    .reserved = {nullptr, nullptr, nullptr, nullptr},
};

extern "C" __attribute__((constructor)) void RegisterSealModule(void)
{
    /* The module is loaded when the ArkTS side imports it. Run the round trip right here, so
     * the log of the device says right away whether the native crypto works on it. */
    uint8_t key[DSH_SEAL_KEY_BYTES];
    uint8_t aad[] = {'s', 'e', 'l', 'f', '-', 't', 'e', 's', 't'};
    const char *plain = "dsh-harmony";
    DshSealBytes iv = {nullptr, 0};
    DshSealBytes cipher = {nullptr, 0};
    DshSealBytes tag = {nullptr, 0};
    DshSealBytes opened = {nullptr, 0};
    DshSealStatus status = dsh_random(key, sizeof(key));
    if (status == DSH_SEAL_OK) {
        status = dsh_seal(key, sizeof(key), reinterpret_cast<const uint8_t *>(plain), strlen(plain),
                          aad, sizeof(aad), nullptr, 0, &iv, &cipher, &tag);
    }
    if (status == DSH_SEAL_OK) {
        status = dsh_unseal(key, sizeof(key), iv.data, iv.len, cipher.data, cipher.len, tag.data, tag.len,
                            aad, sizeof(aad), &opened);
    }
    if (status == DSH_SEAL_OK && opened.len == strlen(plain)
        && memcmp(opened.data, plain, opened.len) == 0) {
        OH_LOG_Print(LOG_APP, LOG_INFO, SEAL_LOG_DOMAIN, SEAL_LOG_TAG,
                     "the native seal is ready (AES-256-GCM, variant %{public}d)", dsh_seal_variant());
    } else {
        OH_LOG_Print(LOG_APP, LOG_ERROR, SEAL_LOG_DOMAIN, SEAL_LOG_TAG,
                     "the native seal is NOT usable: %{public}s", dsh_seal_status_message(status));
    }
    free(iv.data);
    free(cipher.data);
    free(tag.data);
    free(opened.data);

    /* The struct has to be fully built before it is registered: the runtime reads the name and
     * the register function out of it. If the image were still zeroed, the module would be
     * registered without a name and the ArkTS import would be `undefined` — so say so loudly
     * instead of failing silently. */
    if (g_seal_module.nm_modname == nullptr || g_seal_module.nm_register_func == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, SEAL_LOG_DOMAIN, SEAL_LOG_TAG,
                     "the native seal module is not built yet (name %{public}s), it will not work",
                     g_seal_module.nm_modname == nullptr ? "(null)" : g_seal_module.nm_modname);
        return;
    }

    napi_module_register(&g_seal_module);
    OH_LOG_Print(LOG_APP, LOG_INFO, SEAL_LOG_DOMAIN, SEAL_LOG_TAG,
                 "the native seal module '%{public}s' is registered", g_seal_module.nm_modname);
}
