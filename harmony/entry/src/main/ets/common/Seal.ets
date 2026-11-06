/**
 * 手机端与桌桥之间的端到端加密。
 *
 * 中继只是字节管道,它能看到手机发出去的每一个字节。所以请求体和回答体都要加密:
 *
 *   X-Dsh-Seal      base64(iv(12B) || ciphertext || tag(16B))    AES-256-GCM
 *   X-Dsh-Seal-Ts   时间戳(毫秒),同时也是防重放窗口的依据
 *   X-Dsh-Seal-Id   派生用的盐 `<accountId>:<deviceId>`(公开的,秘密是桥接令牌)
 *   X-Dsh-Seal-Key  手机自己的封签钥匙,用包装钥匙包起来
 *
 * 封签钥匙是手机随机生成的 32 字节;包装钥匙是
 * HKDF-SHA256(桥接令牌, salt=accountId:deviceId, info='dsh-harmony-seal-wrap-v1')。
 * 中继没有桥接令牌,所以它既解不开包装,也只能看见密文。
 *
 * 桥接侧的实现: bridge/src/seal.js(公式必须一模一样)。
 *
 * ⚠️ 这个 SDK 的 cryptoFramework 在真机上: **promise 形式的接口会报
 * "build context fail"**, 回调形式才正常 —— 所以下面全部用回调形式包 Promise。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NativeSealResult, nativeSealBytes, nativeSealSelfTest, nativeUnsealBytes, sealBroken, sealBrokenReason } from './NativeSeal';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF04;

const SEAL_ALG: string = 'AES256|GCM|NoPadding';
const SEAL_KDF: string = 'HKDF|SHA256';
const SEAL_KDF_NAME: string = 'HKDF';
const SEAL_WRAP_INFO: string = 'dsh-harmony-seal-wrap-v1';
const SEAL_KEY_SIZE: number = 32;
const SEAL_IV_SIZE: number = 12;
const SEAL_TAG_SIZE: number = 16;

/** 装着密文的头 */
export const SEAL_HEADER: string = 'X-Dsh-Seal';
/** 时间戳的头 */
export const SEAL_TIMESTAMP_HEADER: string = 'X-Dsh-Seal-Ts';
/** 盐的头 */
export const SEAL_ID_HEADER: string = 'X-Dsh-Seal-Id';
/** 包起来的封签钥匙的头 */
export const SEAL_KEY_HEADER: string = 'X-Dsh-Seal-Key';
/** 防重放窗口(毫秒) */
export const SEAL_MAX_AGE_MS: number = 5 * 60 * 1000;

const B64_CHARS: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export function utf8ToString(data: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(data);
}

/**
 * 把字符串编成 utf-8 字节。
 *
 * **用 `encode`, 不用 `encodeInto`** ✓
 *
 * 踩过的坑: 这台机器(Mate 80 / HarmonyOS 6)上 `encodeInto` 给回来的字节数不对
 * (52 字节的明文只拿到 12 字节) ⇒ HUKS 加密的是个残缺的明文 ⇒ 解密永远失败 ✗
 * `encode` 的行为是稳定的 ✓
 */
export function utf8(text: string): Uint8Array {
  return util.TextEncoder.create('utf-8').encode(text);
}

function fromUtf8(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}

/** base64 编码(自己写,不依赖 kit 的接口)。 */
export function toBase64(bytes: Uint8Array): string {
  let out: string = '';
  let i: number = 0;
  while (i + 2 < bytes.length) {
    const n: number = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += B64_CHARS.charAt((n >> 18) & 63) + B64_CHARS.charAt((n >> 12) & 63)
      + B64_CHARS.charAt((n >> 6) & 63) + B64_CHARS.charAt(n & 63);
    i += 3;
  }
  const rest: number = bytes.length - i;
  if (rest === 1) {
    const n: number = bytes[i] << 16;
    out += B64_CHARS.charAt((n >> 18) & 63) + B64_CHARS.charAt((n >> 12) & 63) + '==';
  } else if (rest === 2) {
    const n: number = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out += B64_CHARS.charAt((n >> 18) & 63) + B64_CHARS.charAt((n >> 12) & 63)
      + B64_CHARS.charAt((n >> 6) & 63) + '=';
  }
  return out;
}

/** base64 解码(自己写,不依赖 kit 的接口)。 */
export function fromBase64(text: string): Uint8Array {
  let clean: string = text.replace(/[^A-Za-z0-9+/]/gu, '');
  const length: number = Math.floor(clean.length * 3 / 4);
  while (clean.length % 4 !== 0) {
    clean += 'A';
  }
  const out: Uint8Array = new Uint8Array(length);
  let o: number = 0;
  let i: number = 0;
  while (i < clean.length) {
    const n: number = (B64_CHARS.indexOf(clean.charAt(i)) << 18)
      | (B64_CHARS.indexOf(clean.charAt(i + 1)) << 12)
      | (B64_CHARS.indexOf(clean.charAt(i + 2)) << 6)
      | B64_CHARS.indexOf(clean.charAt(i + 3));
    if (o < length) {
      out[o] = (n >> 16) & 255;
      o += 1;
    }
    if (o < length) {
      out[o] = (n >> 8) & 255;
      o += 1;
    }
    if (o < length) {
      out[o] = n & 255;
      o += 1;
    }
    i += 4;
  }
  return out;
}

/** DataBlob 就是一个 { data: Uint8Array }(这个 SDK 里没有 createDataBlob)。 */
function blob(data: Uint8Array): cryptoFramework.DataBlob {
  return { data: data };
}

/** 32 字节的原始密钥变成可以用的对称密钥。 */
function symmetricKey(raw: Uint8Array): cryptoFramework.SymKey {
  const generator = cryptoFramework.createSymKeyGenerator('AES256');
  return generator.convertKeySync(blob(raw));
}

/** 拼接两个数组(ArkTS 严格模式不用扩展运算符)。 */
function join(first: Uint8Array, second: Uint8Array): Uint8Array {
  const out: Uint8Array = new Uint8Array(first.length + second.length);
  out.set(first, 0);
  out.set(second, first.length);
  return out;
}

/** 随机字节(回调形式)。 */
export function randomBytes(len: number): Promise<Uint8Array> {
  return new Promise<Uint8Array>((resolve, reject) => {
    cryptoFramework.createRandom().generateRandom(len, (err: BusinessError, data: cryptoFramework.DataBlob) => {
      if (err) {
        reject(new Error(err.message));
        return;
      }
      resolve(data.data);
    });
  });
}

/** 派生密钥(回调形式)。 */
function deriveSecret(spec: cryptoFramework.HKDFSpec): Promise<Uint8Array> {
  return new Promise<Uint8Array>((resolve, reject) => {
    cryptoFramework.createKdf(SEAL_KDF).generateSecret(spec, (err: BusinessError, data: cryptoFramework.DataBlob) => {
      if (err) {
        reject(new Error(err.message));
        return;
      }
      resolve(data.data);
    });
  });
}

/** 初始化 cipher(回调形式)。 */
function cipherInit(cipher: cryptoFramework.Cipher, mode: cryptoFramework.CryptoMode,
  key: cryptoFramework.SymKey, params: cryptoFramework.ParamsSpec): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    cipher.init(mode, key, params, (err: BusinessError) => {
      if (err) {
        reject(new Error(err.message));
        return;
      }
      resolve();
    });
  });
}

/** cipher 收尾(回调形式)。 */
function cipherFinal(cipher: cryptoFramework.Cipher, data: cryptoFramework.DataBlob): Promise<Uint8Array> {
  return new Promise<Uint8Array>((resolve, reject) => {
    cipher.doFinal(data, (err: BusinessError, out: cryptoFramework.DataBlob) => {
      if (err) {
        reject(new Error(err.message));
        return;
      }
      resolve(out.data);
    });
  });
}

/** 附加数据: 方法 + 路径 + 时间戳。 */
export function sealAad(method: string, path: string, timestamp: number): Uint8Array {
  return utf8(`${method.toUpperCase()}\n${path}\n${timestamp}`);
}

/** HMAC-SHA256(回调形式)。系统可能不认 'HMAC|SHA256',那就试 'HMAC'。 */
function hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  return tryMac('HMAC|SHA256', key, data).catch((first: Error) => {
    return tryMac('HMAC', key, data).catch((second: Error) => {
      throw new Error(`${first.message} | ${second.message}`);
    });
  });
}

function tryMac(algName: string, key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  return new Promise<Uint8Array>((resolve, reject) => {
    const mac = cryptoFramework.createMac(algName);
    const symKey = cryptoFramework.createSymKeyGenerator(algName).convertKeySync(blob(key));
    mac.init(symKey, (errInit: BusinessError) => {
      if (errInit) {
        reject(new Error(errInit.message));
        return;
      }
      mac.update(blob(data), (errUpdate: BusinessError) => {
        if (errUpdate) {
          reject(new Error(errUpdate.message));
          return;
        }
        mac.doFinal((errFinal: BusinessError, out: cryptoFramework.DataBlob) => {
          if (errFinal) {
            reject(new Error(errFinal.message));
            return;
          }
          resolve(out.data);
        });
      });
    });
  });
}
export async function deriveWrapKeyManual(token: string, accountId: string, deviceId: string): Promise<Uint8Array> {
  const salt: Uint8Array = wrapAad(accountId, deviceId);
  const info: Uint8Array = utf8(SEAL_WRAP_INFO);
  const ikm: Uint8Array = utf8(token);
  const saltKey: Uint8Array = new Uint8Array(32);
  saltKey.set(salt, 0);
  const prk: Uint8Array = await hmacSha256(saltKey, ikm);
  const out: Uint8Array = new Uint8Array(SEAL_KEY_SIZE);
  let previous: Uint8Array = new Uint8Array(0);
  let written: number = 0;
  let counter: number = 1;
  while (written < SEAL_KEY_SIZE) {
    const block: Uint8Array = new Uint8Array(previous.length + info.length + 1);
    block.set(previous, 0);
    block.set(info, previous.length);
    block[block.length - 1] = counter;
    previous = await hmacSha256(prk, block);
    const take: number = Math.min(previous.length, SEAL_KEY_SIZE - written);
    out.set(previous.slice(0, take), written);
    written += take;
    counter += 1;
  }
  return out;
}

/** 包装用的附加数据: 盐。 */
export function wrapAad(accountId: string, deviceId: string): Uint8Array {
  return utf8(`${accountId}:${deviceId}`);
}

/**
 * 派生包装钥匙: HKDF-SHA256(桥接令牌, salt=accountId:deviceId)。
 *
 * @param token 桥接令牌(手机和桌桥都有,中继没有)
 * @param accountId 账号号(没有就是空串)
 * @param deviceId 本机在账号里的设备号
 */
export async function deriveWrapKey(token: string, accountId: string, deviceId: string): Promise<Uint8Array> {
  const spec: cryptoFramework.HKDFSpec = {
    algName: SEAL_KDF_NAME,
    key: utf8(token),
    salt: wrapAad(accountId, deviceId),
    info: utf8(SEAL_WRAP_INFO),
    keySize: SEAL_KEY_SIZE
  };
  try {
    return await deriveSecret(spec);
  } catch (error) {
    // 系统的 Kdf 在这台设备上不可用("build context fail"), 自己算一遍。
    hilog.warn(DOMAIN, TAG, '系统的 HKDF 用不了, 改用自己实现的: %{public}s',
      (error as Error).message ?? '');
    return deriveWrapKeyManual(token, accountId, deviceId);
  }
}

/**
 * 探针: 把 cryptoFramework 的每个能力都试一遍, 打出结果。
 *
 * 这台设备上有的接口会报 "build context fail", 到底是哪些, 一次看清楚。
 */
export async function probeCrypto(): Promise<void> {
  try {
    const random: Uint8Array = await randomBytes(8);
    hilog.info(DOMAIN, TAG, 'probe random: ok (%{public}d bytes)', random.length);
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'probe random: failed %{public}s', (error as Error).message ?? '');
  }
  await probeKdf('HKDF|SHA256', utf8('token'));
  await probeKdf('HKDF', utf8('token'));
  try {
    const spec: cryptoFramework.HKDFSpec = {
      algName: 'HKDF|SHA256',
      key: 'token',
      salt: wrapAad('acc', 'dev'),
      info: utf8(SEAL_WRAP_INFO),
      keySize: SEAL_KEY_SIZE
    };
    const secret: Uint8Array = await deriveSecret(spec);
    hilog.info(DOMAIN, TAG, 'probe kdf(string key): ok (%{public}d bytes)', secret.length);
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'probe kdf(string key): failed %{public}s', (error as Error).message ?? '');
  }
  const names: string[] = ['HMAC|SHA256', 'HMAC-SHA256', 'HMAC', 'AES256'];
  for (let i = 0; i < names.length; i++) {
    try {
      const generator = cryptoFramework.createSymKeyGenerator(names[i]);
      const sym: cryptoFramework.SymKey = generator.convertKeySync(blob(utf8('0123456789abcdef0123456789abcdef')));
      hilog.info(DOMAIN, TAG, 'probe symkey %{public}s: ok', names[i]);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'probe symkey %{public}s: failed %{public}s', names[i],
        (error as Error).message ?? '');
    }
  }
  await probeCipher('aead(nonce+aad)');
  await probeCipher('gcm(iv+aad+empty tag)');
  await probeCipher('gcm(iv+aad+zero tag)');
  await probeCipher2('gcm+generated key', true, true);
  await probeCipher2('gcm+imported key', false, true);
  await probeCipher2('cbc+generated key', true, false);
  await probeCipher2('cbc+imported key', false, false);
  await probeCipher3('ecb', 'AES256|ECB|PKCS7', false);
  await probeCipher3('gcm iv only', 'AES256|GCM|NoPadding', true);
  await probeCipher4('AES|GCM|NoPadding');
  await probeCipher5();
  await probeCipher6();
  await probeCipher7('gcm algName=AES256', 'AES256|GCM|NoPadding', 'AES256', true);
  await probeCipher7('gcm algName=AES256|GCM', 'AES256|GCM|NoPadding', 'AES256|GCM|NoPadding', true);
  await probeCipher7('cbc algName=AES256', 'AES256|CBC|PKCS7', 'AES256', false);
  await probeCipher7('gcm algName=AES256 + aad', 'AES256|GCM|NoPadding', 'AES256', true);
  // 5) HMAC 能不能用(如果能用, 就有得选: 用 HMAC 做密封)
  try {
    const macKey: Uint8Array = new Uint8Array(32);
    macKey.set(utf8('0123456789abcdef'), 0);
    const mac: Uint8Array = await hmacSha256(macKey, utf8('data'));
    hilog.info(DOMAIN, TAG, 'probe hmac: ok %{public}s', toBase64(mac));
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'probe hmac: failed %{public}s (code %{public}d)',
      (error as Error).message ?? '', (error as BusinessError).code ?? 0);
  }
  // 6) 跨端对照: 把包装钥匙的十六进制打出来, Node 那边用 bridge/src/seal.js 算一遍对得上
  try {
    const wrap: Uint8Array = await deriveWrapKey('the-bridge-token', 'acc-1', 'dev-phone');
    hilog.info(DOMAIN, TAG, 'probe wraptoken: %{public}s', toBase64(wrap));
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'probe wraptoken: failed %{public}s', (error as Error).message ?? '');
  }
}

async function probeKdf(algName: string, key: Uint8Array): Promise<void> {
  try {
    const spec: cryptoFramework.HKDFSpec = {
      algName: algName,
      key: key,
      salt: wrapAad('acc', 'dev'),
      info: utf8(SEAL_WRAP_INFO),
      keySize: SEAL_KEY_SIZE
    };
    const secret: Uint8Array = await deriveSecret(spec);
    hilog.info(DOMAIN, TAG, 'probe kdf %{public}s: ok (%{public}d bytes)', algName, secret.length);
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'probe kdf %{public}s: failed %{public}s', algName,
      (error as Error).message ?? '');
  }
}

async function probeCipher(variant: string): Promise<void> {
  try {
    const key: Uint8Array = await randomBytes(SEAL_KEY_SIZE);
    const iv: Uint8Array = await randomBytes(SEAL_IV_SIZE);
    const cipher = cryptoFramework.createCipher(SEAL_ALG);
    let params: cryptoFramework.ParamsSpec;
    if (variant === 'aead(nonce+aad)') {
      const p: cryptoFramework.AeadParamsSpec = {
        algName: SEAL_ALG,
        nonce: iv,
        authenticatedData: utf8('aad')
      };
      params = p;
    } else if (variant === 'gcm(iv+aad+empty tag)') {
      const p: cryptoFramework.GcmParamsSpec = {
        algName: SEAL_ALG,
        iv: blob(iv),
        aad: blob(utf8('aad')),
        authTag: blob(new Uint8Array(0))
      };
      params = p;
    } else {
      const p: cryptoFramework.GcmParamsSpec = {
        algName: SEAL_ALG,
        iv: blob(iv),
        aad: blob(utf8('aad')),
        authTag: blob(new Uint8Array(16))
      };
      params = p;
    }
    await cipherInit(cipher, cryptoFramework.CryptoMode.ENCRYPT_MODE, symmetricKey(key), params);
    const out: Uint8Array = await cipherFinal(cipher, blob(utf8('hello')));
    hilog.info(DOMAIN, TAG, 'probe cipher %{public}s: ok (%{public}d bytes)', variant, out.length);
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'probe cipher %{public}s: failed %{public}s', variant,
      (error as Error).message ?? '');
  }
}
async function probeCipher2(variant: string, generated: boolean, gcm: boolean): Promise<void> {
  try {
    let key: cryptoFramework.SymKey;
    if (generated) {
      key = await new Promise<cryptoFramework.SymKey>((resolve, reject) => {
        cryptoFramework.createSymKeyGenerator('AES256').generateSymKey((err: BusinessError, sym: cryptoFramework.SymKey) => {
          if (err) { reject(new Error(err.message)); return; }
          resolve(sym);
        });
      });
    } else {
      key = symmetricKey(await randomBytes(32));
    }
    const cipher = gcm
      ? cryptoFramework.createCipher('AES256|GCM|NoPadding')
      : cryptoFramework.createCipher('AES256|CBC|PKCS7');
    let params: cryptoFramework.ParamsSpec;
    if (gcm) {
      const p: cryptoFramework.GcmParamsSpec = {
        algName: 'AES256|GCM|NoPadding',
        iv: blob(await randomBytes(12)),
        aad: blob(new Uint8Array(0)),
        authTag: blob(new Uint8Array(0))
      };
      params = p;
    } else {
      const p: cryptoFramework.IvParamsSpec = {
        algName: 'AES256|CBC|PKCS7',
        iv: blob(await randomBytes(16))
      };
      params = p;
    }
    await cipherInit(cipher, cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
    const out: Uint8Array = await cipherFinal(cipher, blob(utf8('hello')));
    hilog.info(DOMAIN, TAG, 'probe cipher2 %{public}s: ok (%{public}d bytes)', variant, out.length);
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'probe cipher2 %{public}s: failed %{public}s', variant,
      (error as Error).message ?? '');
  }
}
async function probeCipher3(variant: string, transformation: string, ivOnly: boolean): Promise<void> {
  try {
    const key: cryptoFramework.SymKey = symmetricKey(await randomBytes(32));
    const cipher = cryptoFramework.createCipher(transformation);
    let params: cryptoFramework.ParamsSpec;
    if (ivOnly) {
      const p: cryptoFramework.IvParamsSpec = {
        algName: transformation,
        iv: blob(await randomBytes(16))
      };
      params = p;
    } else {
      const p: cryptoFramework.GcmParamsSpec = {
        algName: transformation,
        iv: blob(await randomBytes(16)),
        aad: blob(new Uint8Array(0)),
        authTag: blob(new Uint8Array(0))
      };
      params = p;
    }
    await cipherInit(cipher, cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
    const out: Uint8Array = await cipherFinal(cipher, blob(utf8('hello')));
    hilog.info(DOMAIN, TAG, 'probe cipher3 %{public}s: ok (%{public}d bytes)', variant, out.length);
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'probe cipher3 %{public}s: failed %{public}s (code %{public}d)', variant,
      (error as Error).message ?? '', (error as BusinessError).code ?? 0);
  }
}
async function probeCipher4(transformation: string): Promise<void> {
  try {
    const key: cryptoFramework.SymKey = symmetricKey(await randomBytes(32));
    const cipher = cryptoFramework.createCipher(transformation);
    const p: cryptoFramework.GcmParamsSpec = {
      algName: transformation,
      iv: blob(await randomBytes(16)),
      aad: blob(new Uint8Array(0)),
      authTag: blob(new Uint8Array(0))
    };
    await cipherInit(cipher, cryptoFramework.CryptoMode.ENCRYPT_MODE, key, p);
    const out: Uint8Array = await cipherFinal(cipher, blob(utf8('hello')));
    hilog.info(DOMAIN, TAG, 'probe cipher4 %{public}s: ok (%{public}d bytes)', transformation, out.length);
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'probe cipher4 %{public}s: failed %{public}s (code %{public}d)', transformation,
      (error as Error).message ?? '', (error as BusinessError).code ?? 0);
  }
}

async function probeCipher5(): Promise<void> {
  try {
    const key: cryptoFramework.SymKey = symmetricKey(await randomBytes(32));
    const cipher = cryptoFramework.createCipher('AES256|ECB|NoPadding');
    await new Promise<void>((resolve, reject) => {
      cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, null, (err: BusinessError) => {
        if (err) { reject(new Error(err.message)); return; }
        resolve();
      });
    });
    const out: Uint8Array = await cipherFinal(cipher, blob(utf8('hello')));
    hilog.info(DOMAIN, TAG, 'probe cipher5 ecb+null params: ok (%{public}d bytes)', out.length);
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'probe cipher5 ecb+null params: failed %{public}s (code %{public}d)',
      (error as Error).message ?? '', (error as BusinessError).code ?? 0);
  }
}

async function probeCipher6(): Promise<void> {
  try {
    const key: cryptoFramework.SymKey = symmetricKey(await randomBytes(32));
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const p: cryptoFramework.GcmParamsSpec = {
      algName: 'AES256|GCM|NoPadding',
      iv: blob(await randomBytes(16)),
      aad: blob(new Uint8Array(0)),
      authTag: blob(new Uint8Array(0))
    };
    cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, p);
    hilog.info(DOMAIN, TAG, 'probe cipher6 initSync: ok');
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'probe cipher6 initSync: failed %{public}s (code %{public}d)',
      (error as Error).message ?? '', (error as BusinessError).code ?? 0);
  }
}
async function probeCipher7(variant: string, transformation: string, paramsAlgName: string, gcm: boolean): Promise<void> {
  try {
    const key: cryptoFramework.SymKey = symmetricKey(await randomBytes(32));
    const cipher = cryptoFramework.createCipher(transformation);
    let params: cryptoFramework.ParamsSpec;
    if (gcm) {
      const p: cryptoFramework.GcmParamsSpec = {
        algName: paramsAlgName,
        iv: blob(await randomBytes(12)),
        aad: blob(new Uint8Array(0)),
        authTag: blob(new Uint8Array(0))
      };
      params = p;
    } else {
      const p: cryptoFramework.IvParamsSpec = {
        algName: paramsAlgName,
        iv: blob(await randomBytes(16))
      };
      params = p;
    }
    await cipherInit(cipher, cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
    const plain: Uint8Array = new Uint8Array(16);
    const out: Uint8Array = await cipherFinal(cipher, blob(plain));
    hilog.info(DOMAIN, TAG, 'probe cipher7 %{public}s: ok (%{public}d bytes)', variant, out.length);
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'probe cipher7 %{public}s: failed %{public}s (code %{public}d)', variant,
      (error as Error).message ?? '', (error as BusinessError).code ?? 0);
  }
}
/**
 * 用 AES-256-GCM 加密,返回 base64(iv || ciphertext || tag)。
 *
 * **cipher 这一半走原生实现** ✓ —— ArkTS 那条路在这个 SDK 上传不进参数(init 401 ✓),
 * 原生层直接用系统的 AES-GCM ✓。
 * 布局跟原来一模一样: iv(12) ‖ ciphertext ‖ tag(16) ✓ ✓
 * (桥接的 seal.js 就是这么解的 ✓)
 */
export async function encryptWith(key: Uint8Array, plain: Uint8Array, aad: Uint8Array): Promise<string> {
  if (sealBroken()) {
    // 原生模块用不了 ⇒ 抛出去让上层明文降级 ✓(上层会把这个原因报给用户 ✓)
    throw new Error(`原生密封不可用: ${sealBrokenReason()}`);
  }
  const result: NativeSealResult = nativeSealBytes(key, plain, aad);
  return toBase64(join(result.iv, join(result.ciphertext, result.tag)));
}

/**
 * 解开 AES-256-GCM: 入参是 base64(iv || ciphertext || tag)。
 *
 * **cipher 这一半走原生实现** ✓ —— 拆成 iv(12) / ciphertext / tag(末 16 字节) ✓
 * ⚠️ 密文布局必须是 ct ‖ tag(16) ✓ —— SDK 的 GcmParamsSpec.authTag 注释写明
 * tag 是 doFinal 结果的**最后 16 字节** ✓ ✓
 */
export async function decryptWith(key: Uint8Array, envelope: string, aad: Uint8Array): Promise<Uint8Array> {
  if (sealBroken()) {
    throw new Error(`原生密封不可用: ${sealBrokenReason()}`);
  }
  const raw: Uint8Array = fromBase64(envelope);
  if (raw.length < SEAL_IV_SIZE + SEAL_TAG_SIZE) {
    throw new Error('密文太短');
  }
  const iv: Uint8Array = raw.slice(0, SEAL_IV_SIZE);
  const tag: Uint8Array = raw.slice(raw.length - SEAL_TAG_SIZE);
  const ciphertext: Uint8Array = raw.slice(SEAL_IV_SIZE, raw.length - SEAL_TAG_SIZE);
  return nativeUnsealBytes(key, iv, ciphertext, tag, aad);
}

/** 把封签钥匙包起来交给桥接。 */
export async function wrapSealKey(wrapKey: Uint8Array, sealKey: Uint8Array,
  accountId: string, deviceId: string): Promise<string> {
  return encryptWith(wrapKey, sealKey, wrapAad(accountId, deviceId));
}

/** 封一个请求体。 */
export async function sealRequestBody(sealKey: Uint8Array, payload: string, method: string, path: string,
  timestamp: number): Promise<string> {
  return encryptWith(sealKey, utf8(payload), sealAad(method, path, timestamp));
}

/** 解一个回答体。 */
export async function unsealResponseBody(sealKey: Uint8Array, envelope: string, method: string, path: string,
  timestamp: number): Promise<string> {
  const plain: Uint8Array = await decryptWith(sealKey, envelope, sealAad(method, path, timestamp));
  return fromUtf8(plain);
}

/** 生成一把新的封签钥匙(32 字节随机)。 */
export async function newSealKey(): Promise<Uint8Array> {
  return randomBytes(SEAL_KEY_SIZE);
}

/**
 * 密封自检: 用一把临时钥匙做一次 AES-256-GCM 加解密。
 *
 * **cipher 这一半已经是原生的了** ✓ —— 自检也跟着走原生 ✓
 * (原来这条路上 cryptoFramework 的 cipher 参数传不进去, init 会返回 401 ✓)
 *
 * 原生模块用不了时(老机器没这个 so ✓)⇒ 返回一句人话 ✓
 * **上层会把它报给用户, 并且明文降级** ✓ —— 不静默 ✓ ✓
 *
 * @returns 'ok' 或者一句人话(为什么不能用)
 */
export async function sealSelfTest(): Promise<string> {
  try {
    const native: string = nativeSealSelfTest();
    if (native !== 'ok') {
      return native;
    }
    // 原生自检过了, 再用**本文件这一对函数**做一次往返 ✓
    // (保证 encryptWith/decryptWith 的布局跟桥接解得一样 ✓)
    const key: Uint8Array = await randomBytes(SEAL_KEY_SIZE);
    const envelope: string = await encryptWith(key, utf8('dsh-harmony'), utf8('self-test'));
    const plain: Uint8Array = await decryptWith(key, envelope, utf8('self-test'));
    if (fromUtf8(plain) === 'dsh-harmony') {
      return 'ok';
    }
    return 'the round trip did not come back the same';
  } catch (error) {
    return (error as Error).message ?? 'unknown';
  }
}

// ---------------------------------------------------------------------------
// 打码: 秘密往外报之前, 先摘掉能认出来的那部分。
//
// 规矩只有一条: **界面上、日志里、异常里都不出现完整秘密**。
// 需要看全貌的地方(设置页里"复制令牌")让用户自己点, 界面只给打码后的。
// ---------------------------------------------------------------------------

/**
 * 把一段秘密打码: 留头留尾, 中间换成点。
 *
 * 令牌是 64 位十六进制, 留 4 位头 4 位尾足够认出这是哪个令牌, 又认不出它。
 *
 * @param value 秘密本身
 * @param head  留几位头
 * @param tail  留几位尾
 */
export function maskSecret(value: string, head: number = 4, tail: number = 4): string {
  const text: string = value ?? '';
  if (text.length === 0) {
    return '';
  }
  if (text.length <= head + tail) {
    // 太短了, 留头留尾等于全露 —— 一律盖住。
    return '•'.repeat(Math.max(text.length, 4));
  }
  return `${text.substring(0, head)}••••••${text.substring(text.length - tail)}`;
}

/** host 的每一段: 留第一个字符, 其余盖住。 */
function maskHostLabel(label: string): string {
  if (label.length === 0) {
    return label;
  }
  return `${label.substring(0, 1)}***`;
}

/** host 是不是一个 IP(全是数字的段)。 */
function isIpHost(host: string): boolean {
  const parts: string[] = host.split('.');
  if (parts.length < 2) {
    return false;
  }
  for (const part of parts) {
    if (part.length === 0 || !/^\d+$/.test(part)) {
      return false;
    }
  }
  return true;
}

/**
 * 把 host 打码。
 *
 * 域名: 每一段留第一个字符, 顶级域(.com/.cn)留着 —— 还能看出是哪个网站 ✓
 * IP: 每一段都留第一个字符, 免得 "112" 这种尾巴露出去 ✓
 */
export function maskHost(host: string): string {
  const text: string = (host ?? '').trim();
  if (text.length === 0) {
    return '';
  }
  const parts: string[] = text.split('.');
  const ip: boolean = isIpHost(text);
  const out: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    const last: boolean = i === parts.length - 1;
    if (last && !ip) {
      out.push(parts[i]);
    } else {
      out.push(maskHostLabel(parts[i]));
    }
  }
  return out.join('.');
}

/** 路径里的一段: acc-1a2b / dev-8f2a 这种, 前缀留着, 编号盖住。 */
function maskPathSegment(segment: string): string {
  const dash: number = segment.lastIndexOf('-');
  if (dash > 0 && dash < segment.length - 1) {
    return `${segment.substring(0, dash)}-${'•'.repeat(4)}`;
  }
  if (segment.length >= 16) {
    // 一整段都是编号(uuid / 哈希): 全盖。
    return '•'.repeat(4);
  }
  return segment;
}

/**
 * 把服务器地址打码。
 *
 * `http://192.168.1.10:8788/acc-1a2b/dev-8f2a`
 *   → `http://192.***.***.***:8788/acc-••••/dev-••••`
 *
 * host 与路径里的账号/设备号都不留全貌 —— 中继地址本身就是秘密的一半。
 */
export function maskEndpoint(endpoint: string): string {
  const text: string = (endpoint ?? '').trim();
  if (text.length === 0) {
    return '';
  }
  let rest: string = text;
  let scheme: string = '';
  const schemeMatch: RegExpMatchArray | null = rest.match(/^([a-z][a-z0-9+.-]*):\/\//iu);
  if (schemeMatch !== null) {
    scheme = `${schemeMatch[1]}://`;
    rest = rest.substring(schemeMatch[0].length);
  }
  let query: string = '';
  const q: number = rest.indexOf('?');
  if (q >= 0) {
    query = rest.substring(q + 1);
    rest = rest.substring(0, q);
  }
  let path: string = '';
  const p: number = rest.indexOf('/');
  if (p >= 0) {
    path = rest.substring(p);
    rest = rest.substring(0, p);
  }
  let host: string = rest;
  let port: string = '';
  const colon: number = rest.lastIndexOf(':');
  if (colon > 0 && /^\d+$/.test(rest.substring(colon + 1))) {
    host = rest.substring(0, colon);
    port = rest.substring(colon + 1);
  }
  const maskedSegments: string[] = [];
  for (const segment of path.split('/')) {
    if (segment.length === 0) {
      maskedSegments.push(segment);
    } else {
      maskedSegments.push(maskPathSegment(segment));
    }
  }
  const maskedPath: string = maskedSegments.join('/');
  let maskedQuery: string = '';
  if (query.length > 0) {
    const pairs: string[] = query.split('&');
    const outPairs: string[] = [];
    for (const pair of pairs) {
      const eq: number = pair.indexOf('=');
      if (eq < 0) {
        outPairs.push(pair);
        continue;
      }
      const name: string = pair.substring(0, eq);
      const value: string = pair.substring(eq + 1);
      outPairs.push(`${name}=${maskSecret(value)}`);
    }
    maskedQuery = `?${outPairs.join('&')}`;
  }
  return `${scheme}${maskHost(host)}${port.length > 0 ? `:${port}` : ''}${maskedPath}${maskedQuery}`;
}

/**
 * 把一段可能夹带秘密的文本洗一遍(错误消息、URL、堆栈)。
 *
 * 这是最后一道保险: 谁在 catch 里手滑打了整个请求对象, 至少令牌不会跟着出去。
 */
export function scrubSecrets(text: string): string {
  let out: string = (text ?? '').toString();
  // Bearer <令牌>
  out = out.replace(/(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}/giu, '$1***');
  // token=xxx / accountToken=xxx / deviceToken=xxx
  out = out.replace(/((?:account|device|bridge|access)?[Tt]oken"?\s*[:=]\s*"?)[A-Za-z0-9._~+/=-]{8,}/giu, '$1***');
  // Authorization 头
  out = out.replace(/("?authorization"?\s*[:=]\s*"?)[^"',}\s]{8,}/giu, '$1***');
  // 一长串十六进制(令牌/哈希/指纹)
  out = out.replace(/\b[A-Fa-f0-9]{24,}\b/gu, '***');
  // uuid
  out = out.replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/giu, '***');
  return out;
}

/**
 * 消息正文只留长度和头几个字。
 *
 * 调试要看的是"有没有内容、大概多大", 不是内容本身 —— 正文里有用户的话,
 * 有可能还带着别的秘密。
 */
export function previewText(body: string, head: number = 40): string {
  const text: string = (body ?? '').toString();
  if (text.length === 0) {
    return '(空)';
  }
  const headText: string = text.substring(0, head).replace(/\s+/gu, ' ');
  return `${text.length} 字: ${headText}${text.length > head ? '…' : ''}`;
}
