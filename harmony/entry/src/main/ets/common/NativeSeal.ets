/**
 * 手机端的封签(AES-256-GCM)—— 原生层的那一半。
 *
 * 为什么在原生层做 ✓:
 * 这台设备(HarmonyOS API 26)上,ArkTS 的 `cryptoFramework` **传不进 cipher 的参数对象** ——
 * 传 `null` 能 init,但任何参数对象一律 401(`build context for init fail!`)⇒ 而 GCM 必须带
 * IV/模式/填充 ⇒ `cryptoFramework` 这条路是死的 ✓。
 *
 * 官方支持的完整路径是 **NDK 的 C-API** ✓ —— 不是手写密码学,是调系统的
 * `CryptoArchitectureKit`(原生 C 接口,`libohcrypto.so`)✓ —— 和 ArkTS 那半边是同一套实现,
 * 只是绕开了 ArkTS 的参数封送 ✓。
 *
 * 原生模块:`harmony/entry/src/main/cpp/` ✓
 *   - `seal_core.c`      —— 密码学核心(纯 C,跨端对照程序也用它)
 *   - `napi_init.cpp`    —— napi 绑定
 *
 * 与桌桥的字节级一致性 ✓:
 * 桌桥用 `bridge/src/seal.js`(node 的 OpenSSL),手机用这里的原生模块 —— 两边算出来的
 * iv/密文/tag **必须一模一样** ✓(固定向量见 `bridge/test/seal.test.js` 的
 * `SEAL_TEST_VECTOR`,对照脚本是 `tools/seal-interop.js`)✓。
 *
 * 用不了的时候**明文降级,但一定要报出来** ✓:`sealBroken()` 为真时,上层必须走明文并把
 * 原因显示给用户 ✓ —— 不许悄悄降级 ✓。
 */

import seal from 'libseal.so';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { explain } from './ErrorText';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF04;

/** base64 的字母表 */
const B64_CHARS: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/**
 * base64 编码(自己写一份,不依赖别处的实现)。
 *
 * 为什么不复用 `common/Seal.ets` 里的那个:那个文件将来会反过来 import 本文件(把 cipher
 * 那一半换掉)—— 那样就成环了 ✓。所以这里自己写一份,谁也不依赖谁 ✓。
 */
export function nativeToBase64(bytes: Uint8Array): string {
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

/** base64 解码(自己写一份)。 */
export function nativeFromBase64(text: string): Uint8Array {
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

/** 封签钥匙的长度(AES-256) */
export const SEAL_KEY_SIZE: number = 32;
/** 随机数的长度(GCM 的 nonce) */
export const SEAL_IV_SIZE: number = 12;
/** 认证标签的长度 */
export const SEAL_TAG_SIZE: number = 16;

/** 一次封签的结果 */
export interface NativeSealResult {
  iv: Uint8Array;
  ciphertext: Uint8Array;
  tag: Uint8Array;
}

/** 自检的结果 */
export interface NativeSealCheck {
  ok: boolean;
  reason: string;
}

/** 原生模块用不了(系统密码学框架拒绝了) */
let broken: boolean = false;
/** 用不了的原因(人话) */
let brokenReason: string = '';
/** 自检已经跑过了 */
let checked: boolean = false;

/** 原生模块是否不可用(不可用时上层必须明文走,并且把原因报给用户) */
export function sealBroken(): boolean {
  return broken;
}

/** 原生模块不可用的原因(空字符串 = 一切正常) */
export function sealBrokenReason(): string {
  return brokenReason;
}

/**
 * 原生加密的步骤名 → 中文。
 *
 * 报错是要给人看的 ⇒ 不能只甩一个英文的 `unsealBytes` ✓
 */
function sealStepName(operation: string): string {
  if (operation === 'seal' || operation === 'sealBytes') {
    return '加密';
  }
  if (operation === 'unseal' || operation === 'unsealBytes') {
    return '解密';
  }
  if (operation === 'hkdf') {
    return '密钥派生';
  }
  if (operation === 'random') {
    return '取随机数';
  }
  return operation;
}

/** 把原生模块的调用包一层:出错时把原因记下来 */
function fail(operation: string, error: Error | BusinessError): never {
  const message = error instanceof Error ? error.message : String(error);
  hilog.error(DOMAIN, TAG, 'the native seal failed on %{public}s: %{public}s', operation, message);
  // 原文留着(排查能搜到), 后面跟一句中文说明(用户看得懂这是什么错) ✓
  throw new Error(`加密通道在${sealStepName(operation)}这一步出错: ${explain(message)}`);
}

/**
 * 能力自检:在原生层做一次 seal → unseal 往返。
 *
 * 跑不过就把模块标成不可用(`sealBroken()`),上层据此明文降级 —— 但一定要报出来 ✓。
 *
 * @returns 'ok' 或者一句人话(为什么不能用)
 */
export function nativeSealSelfTest(): string {
  if (checked) {
    return broken ? brokenReason : 'ok';
  }
  checked = true;
  try {
    const check: NativeSealCheck = seal.selfTest();
    if (check.ok) {
      hilog.info(DOMAIN, TAG, 'the native seal is ready (AES-256-GCM in the native layer)');
      return 'ok';
    }
    broken = true;
    brokenReason = `手机这边的加密通道用不了, 更新一下 App 再试(${check.reason})`;
    hilog.error(DOMAIN, TAG, 'the native seal is NOT usable: %{public}s', check.reason);
    return brokenReason;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    broken = true;
    brokenReason = `手机这边的加密通道用不了, 更新一下 App 再试(${message})`;
    hilog.error(DOMAIN, TAG, 'the native seal is NOT usable: %{public}s', message);
    return brokenReason;
  }
}

/** 系统密码学框架用的哪种密文形状(0 = 文档里的那种;只是诊断用) */
export function nativeSealVariant(): number {
  try {
    return seal.variant();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    hilog.warn(DOMAIN, TAG, 'the native seal variant is unknown: %{public}s', message);
    return -1;
  }
}

/**
 * 用一把封签钥匙把一段文字封起来。
 *
 * @param key 32 字节的封签钥匙
 * @param plainText 要保护的内容
 * @param aad 绑进标签的附加数据(方法 + 路径 + 时间戳)
 * @param iv 12 字节的 nonce;不给就用系统随机数
 */
export function nativeSeal(key: Uint8Array, plainText: string, aad: string,
  iv?: Uint8Array): NativeSealResult {
  if (broken) {
    throw new Error(`手机这边的加密通道用不了, 更新一下 App 再试: ${brokenReason}`);
  }
  try {
    if (iv === undefined) {
      return seal.seal(key, plainText, aad) as NativeSealResult;
    }
    return seal.seal(key, plainText, aad, iv) as NativeSealResult;
  } catch (error) {
    fail('seal', error as Error);
  }
}

/**
 * 把一段封签解开。
 *
 * @param key 32 字节的封签钥匙
 * @param iv 12 字节的 nonce
 * @param ciphertext 密文
 * @param tag 16 字节的认证标签
 * @param aad 绑进标签的附加数据
 */
export function nativeUnseal(key: Uint8Array, iv: Uint8Array, ciphertext: Uint8Array,
  tag: Uint8Array, aad: string): string {
  if (broken) {
    throw new Error(`手机这边的加密通道用不了, 更新一下 App 再试: ${brokenReason}`);
  }
  try {
    return seal.unseal(iv, ciphertext, tag, aad, key) as string;
  } catch (error) {
    fail('unseal', error as Error);
  }
}

/**
 * 封签成线上的形状:base64(iv(12B) || 密文 || tag(16B))。
 *
 * 这就是 `X-Dsh-Seal` 头的值 ✓(`bridge/src/seal.js` 的 `sealBody` 产出的正是它)✓。
 */
export function nativeSealEnvelope(key: Uint8Array, plainText: string, aad: string): string {
  const result: NativeSealResult = nativeSeal(key, plainText, aad);
  const envelope: Uint8Array = new Uint8Array(result.iv.length + result.ciphertext.length + result.tag.length);
  envelope.set(result.iv, 0);
  envelope.set(result.ciphertext, result.iv.length);
  envelope.set(result.tag, result.iv.length + result.ciphertext.length);
  return nativeToBase64(envelope);
}

/** 把线上形状的封签解开(和 `bridge/src/seal.js` 的 `unsealBody` 对面) */
export function nativeUnsealEnvelope(key: Uint8Array, envelope: string, aad: string): string {
  const raw: Uint8Array = nativeFromBase64(envelope);
  if (raw.length < SEAL_IV_SIZE + SEAL_TAG_SIZE) {
    throw new Error('密封数据不完整, 这一次的网络抖动, 不影响对话');
  }
  const iv: Uint8Array = raw.slice(0, SEAL_IV_SIZE);
  const tag: Uint8Array = raw.slice(raw.length - SEAL_TAG_SIZE);
  const ciphertext: Uint8Array = raw.slice(SEAL_IV_SIZE, raw.length - SEAL_TAG_SIZE);
  return nativeUnseal(key, iv, ciphertext, tag, aad);
}

/**
 * 用字节版的封签(和 `common/Seal.ets` 的 `encryptWith` 一个形状 —— 换 cipher 那一半时,
 * 上面的调用方一行都不用改 ✓)。
 *
 * @param key 32 字节的封签钥匙
 * @param plain 要保护的内容(字节)
 * @param aad 绑进标签的附加数据(字节)
 * @param iv 12 字节的 nonce;不给就用系统随机数
 */
export function nativeSealBytes(key: Uint8Array, plain: Uint8Array, aad: Uint8Array,
  iv?: Uint8Array): NativeSealResult {
  if (broken) {
    throw new Error(`手机这边的加密通道用不了, 更新一下 App 再试: ${brokenReason}`);
  }
  try {
    if (iv === undefined) {
      return seal.sealBytes(key, plain, aad) as NativeSealResult;
    }
    return seal.sealBytes(key, plain, aad, iv) as NativeSealResult;
  } catch (error) {
    fail('sealBytes', error as Error);
  }
}

/** 用字节版的封签把一段封签解开(和 `common/Seal.ets` 的 `decryptWith` 一个形状) */
export function nativeUnsealBytes(key: Uint8Array, iv: Uint8Array, ciphertext: Uint8Array,
  tag: Uint8Array, aad: Uint8Array): Uint8Array {
  if (broken) {
    throw new Error(`手机这边的加密通道用不了, 更新一下 App 再试: ${brokenReason}`);
  }
  try {
    return seal.unsealBytes(key, iv, ciphertext, tag, aad) as Uint8Array;
  } catch (error) {
    fail('unsealBytes', error as Error);
  }
}

/** HKDF-SHA256(原生层的那一半) */
export function nativeHkdf(ikm: string, salt: string, info: string, length: number): Uint8Array {
  try {
    return seal.hkdf(ikm, salt, info, length) as Uint8Array;
  } catch (error) {
    fail('hkdf', error as Error);
  }
}

/** 系统随机数 */
export function nativeRandom(length: number): Uint8Array {
  try {
    return seal.random(length) as Uint8Array;
  } catch (error) {
    fail('random', error as Error);
  }
}
