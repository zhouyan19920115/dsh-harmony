/**
 * 用 HUKS(系统的硬件钥匙服务)把桥接令牌加密后存起来。
 *
 * 规矩: **令牌明文绝不落盘** —— preferences 里只有密文。
 * 密钥只存在于本机的 HUKS 里, 永远不出手机。
 *
 * HUKS 跟 cryptoFramework 是两套 API, 不走那个「参数对象传不进 native」的坑。
 * 如果 HUKS 用不了, **不要静默退回明文**: 直接报错, 让调用方明确知道。
 *
 * ## 落盘格式(自己说了算, 但写死)
 *
 * `base64( iv(12) ‖ 密文 ‖ AEAD tag(16) )` ✓
 *
 * ## 这台机器上踩过的坑(都写在注释里了, 别再踩)
 *
 * 1. GCM 的 nonce 要用 **`HUKS_TAG_NONCE`**, 不是 `HUKS_TAG_IV` ⇒
 *    传错的话 HUKS 收不到 nonce, 解密一律 401(参数非法) ✗
 * 2. GCM 的 **AEAD tag 是会话属性(`HUKS_TAG_AE_TAG`)**, 不是正文的一部分 ✓
 *    解密时: 属性里给 nonce + ae_tag, 正文只喂密文(不带 tag) ✓
 *    (把 tag 塞进正文、或者塞进 finish 的 inData, 都不对 ⇒ 401 ✗)
 * 3. 加密的输出**分两段**: `updateSession` 给密文主体, `finishSession` 给 AEAD ✓
 *    以前只拼了 finish 那段 ⇒ 存下去的"密文"里根本没有明文 ⇒ 解不开 ✗
 * 4. `isKeyItemExist` 在钥匙不存在时是**抛异常 12000011**, 不是返回 false ✓
 * 5. `generateKeyItem` 对已存在的别名**不报错, 直接把钥匙重生** ⇒ 老密文当场作废 ✗
 *    所以一定要先问在不在 ✓
 */
import { huks } from '@kit.UniversalKeystoreKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fromBase64, randomBytes, toBase64, utf8, utf8ToString } from './Seal';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF05;

/**
 * 钥匙的别名(一把就够了, 专门用来加密桥接令牌)。
 *
 * **v2**: v1 那把是本机早期版本用错标签建的(收不到 nonce)⇒ 老密文本来就解不开,
 * 换新别名才是对的 ✓
 * 换别名的规矩: **先解密 → 用新钥匙重加密 → 落盘 → 确认盘上没有老密文 → 最后才删老钥匙**
 * (所以这里**不删**老钥匙 ✓ 别把老数据判死刑 ✓)
 */
const KEY_ALIAS: string = 'dsh_harmony_token_key_v2';
/** 老的那把(留着, 别乱删 —— 删了老密文就永远解不开了 ✓) */
const OLD_KEY_ALIAS: string = 'dsh_harmony_token_key';
/** GCM 的 nonce 长度。 */
const IV_SIZE: number = 12;
/** GCM 的 AEAD tag 长度。 */
const TAG_SIZE: number = 16;

/**
 * 附加认证数据: 密文不能被搬到别的用途上去。
 *
 * **现在两边都不带 AAD** ✓ —— GCM 的 tag 把 AAD 算进去,
 * 一边空一边非空必挂 ⇒ 加解密两边必须一致 ✓
 * 用途绑定改成写在**明文前缀**里(`用途|密文`), 一样能互相解不开 ✓
 */
function aadOf(purpose: string): string {
  return `dsh-harmony-${purpose}-v1`;
}

/** 两段字节接起来。 */
function concatBytes(first: Uint8Array, second: Uint8Array): Uint8Array {
  const out: Uint8Array = new Uint8Array(first.length + second.length);
  out.set(first, 0);
  out.set(second, first.length);
  return out;
}

/**
 * **加密**会话的属性。
 *
 * 官方规格: 加密时 NONCE、AAD 都是可选的 ✓
 * 我们指定 NONCE(12 字节随机)⇒ HUKS 就不会自己再生成一个,
 * 输出也就只有 `密文 ‖ AEAD` ✓(不指定的话它会返回 `密文 ‖ AEAD ‖ NONCE` ✓)
 */
function encryptParams(purpose: number, nonce: Uint8Array): huks.HuksParam[] {
  return [
    { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
    { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
    { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: 256 },
    { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
    { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
    { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce }
  ];
}

/**
 * **解密**会话的属性(官方形状 ✓)。
 *
 * **关键**: GCM 的 AEAD tag 是**会话属性**(`HUKS_TAG_AE_TAG`), 不是正文的一部分 ✓
 * 官方规格: 解密时 NONCE、AEAD 必填, AAD 可选 ✓
 */
function decryptParams(nonce: Uint8Array, tag: Uint8Array): huks.HuksParam[] {
  return [
    { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
    { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
    { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: 256 },
    { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
    { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
    { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce },
    { tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag }
  ];
}

/** 钥匙的公共属性(加密解密一把够)。 */
function keyProperties(): huks.HuksParam[] {
  const props: huks.HuksParam[] = [
    { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
    { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: 256 },
    {
      tag: huks.HuksTag.HUKS_TAG_PURPOSE,
      value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT
    }
  ];
  return props;
}

/**
 * 钥匙在的话就别动它。
 *
 * **踩过的坑**: 这台机器(Mate 80 / HarmonyOS 6)上 `generateKeyItem` 对**已存在**的别名
 * **不报错**, 而是**把钥匙重生** —— 于是「加密 → 再加密 → 解密」里, 先前那段密文
 * 当场作废(解密报 401), 令牌永远存不住 ✓
 *
 * 所以这里**先问在不在**: 在就直接用, 只有真的没有才建 ✓
 * (`isKeyItemExist` 在钥匙不存在时抛 12000011, 那也是「不在」✓)
 */
async function ensureKey(): Promise<void> {
  const opts: huks.HuksOptions = {};
  try {
    const exists: boolean = await huks.isKeyItemExist(KEY_ALIAS, opts);
    if (exists) {
      return;
    }
  } catch (e) {
    // 钥匙不存在的时候 HUKS 是抛异常(12000011), 不是返回 false ✓
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, '钥匙不在(按新建处理): code %{public}d', err.code ?? -1);
  }
  try {
    await huks.generateKeyItem(KEY_ALIAS, { properties: keyProperties() });
    hilog.info(DOMAIN, TAG, '钥匙已建好: %{public}s', KEY_ALIAS);
  } catch (e) {
    // 已经存在的时候 HUKS 会报错, 那正是我们要的
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, '钥匙已存在(或建不了): code %{public}d %{public}s',
      err.code ?? -1, err.message ?? '');
  }
}

/** 前 12 个字节是不是这个 nonce ✓ */
function startsWithIv(bytes: Uint8Array, iv: Uint8Array): boolean {
  if (bytes.length < iv.length) {
    return false;
  }
  for (let i = 0; i < iv.length; i++) {
    if (bytes[i] !== iv[i]) {
      return false;
    }
  }
  return true;
}

/**
 * HUKS 报错的说法(给界面看的那一份)。
 *
 * 系统的原文是英文(`Parameter invalid.` 之类), 用户看不懂 ⇒ 只把**错误码**带出去
 * —— 那是排查时最有用的一把钥匙(12000011 = 钥匙不存在, 之类)✓
 * 英文原文留在 hilog 里, 不往界面上摆 ✓
 */
function huksErrorText(err: BusinessError): string {
  const code: number = err.code ?? -1;
  return `错误码 ${code}`;
}

/** 结尾是不是这个 nonce ✓ */
function endsWithIv(bytes: Uint8Array, iv: Uint8Array): boolean {
  if (bytes.length < iv.length) {
    return false;
  }
  const offset: number = bytes.length - iv.length;
  for (let i = 0; i < iv.length; i++) {
    if (bytes[offset + i] !== iv[i]) {
      return false;
    }
  }
  return true;
}

/**
 * 把 HUKS 那两段整理成 `密文 ‖ AEAD` ✓
 *
 * HUKS 有时候会把 nonce 也还回来(out = 密文 ‖ AEAD ‖ NONCE)⇒ 把那个重复的 nonce 摘掉,
 * 只留 AEAD ✓
 */
function normalize(cipher: Uint8Array, finish: Uint8Array, nonce: Uint8Array): Uint8Array {
  let tail: Uint8Array = finish;
  if (startsWithIv(finish, nonce)) {
    tail = finish.slice(IV_SIZE);
  } else if (endsWithIv(finish, nonce)) {
    tail = finish.slice(0, finish.length - IV_SIZE);
  }
  return concatBytes(cipher, tail);
}

/**
 * 加密一段明文, 返回 base64(iv ‖ 密文 ‖ AEAD)。
 *
 * **用途写进明文里**(前缀 `用途|`): 不依赖 HUKS 的 aad 参数,
 * 不同用途的密文照样互相解不开 ✓
 *
 * @param plain 明文
 * @param purpose 用途(令牌 / 远端地址…)
 */
export async function encrypt(plain: string, purpose: string = 'token'): Promise<string> {
  await ensureKey();
  const nonce: Uint8Array = await randomBytes(IV_SIZE);
  const options: huks.HuksOptions = {
    properties: encryptParams(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, nonce)
  };
  const payload: string = `${purpose}|${plain}`;
  const plainBytes: Uint8Array = utf8(payload);
  const session: huks.HuksSessionHandle = await huks.initSession(KEY_ALIAS, options);
  const handle: number = session.handle;
  const middle: huks.HuksReturnResult = await huks.updateSession(handle, { inData: plainBytes });
  const result: huks.HuksReturnResult = await huks.finishSession(handle, {});
  const cipher: Uint8Array = normalize(middle?.outData ?? new Uint8Array(0),
    result?.outData ?? new Uint8Array(0), nonce);
  if (cipher.length === 0) {
    throw new Error('HUKS 没有返回密文, 这台机器的硬件钥匙服务不给用, 需要重新配对一次');
  }
  const packed: Uint8Array = new Uint8Array(nonce.length + cipher.length);
  packed.set(nonce, 0);
  packed.set(cipher, nonce.length);
  hilog.info(DOMAIN, TAG, '秘密已加密(用途 %{public}s, %{public}d 字节; 明文 %{public}d 字节, 密文 %{public}d 字节)',
    purpose, packed.length, plainBytes.length, cipher.length);
  return toBase64(packed);
}

/**
 * 解密 base64(iv ‖ 密文 ‖ AEAD)。
 *
 * **官方形状** ✓: 属性里给 nonce + ae_tag, 正文只喂密文(不带 tag)✓
 */
export async function decrypt(blob: string, purpose: string = 'token'): Promise<string> {
  await ensureKey();
  const packed: Uint8Array = fromBase64(blob);
  if (packed.length <= IV_SIZE + TAG_SIZE) {
    throw new Error('密文不对: 太短了, 存着的密文已经坏了, 需要重新配对一次');
  }
  const nonce: Uint8Array = packed.slice(0, IV_SIZE);
  const tag: Uint8Array = packed.slice(packed.length - TAG_SIZE);
  const body: Uint8Array = packed.slice(IV_SIZE, packed.length - TAG_SIZE);
  const props: huks.HuksParam[] = decryptParams(nonce, tag);
  hilog.info(DOMAIN, TAG, '解密调试: 密文 %{public}d 字节, nonce %{public}d 字节, 正文 %{public}d 字节, tag %{public}d 字节',
    packed.length, nonce.length, body.length, tag.length);
  let session: huks.HuksSessionHandle;
  try {
    session = await huks.initSession(KEY_ALIAS, { properties: props });
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'HUKS 解密会话开不起来: code %{public}d %{public}s', err.code ?? -1, err.message ?? '');
    throw new Error(`HUKS 解密失败(${huksErrorText(err)}), 存着的密文解不开了, 需要重新配对一次`);
  }
  const handle: number = session.handle;
  let middle: huks.HuksReturnResult;
  try {
    // 正文只有密文, tag 在属性里 ✓
    middle = await huks.updateSession(handle, { inData: body });
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'HUKS 解密失败: code %{public}d %{public}s', err.code ?? -1, err.message ?? '');
    throw new Error(`HUKS 解密失败(${huksErrorText(err)}), 存着的密文解不开了, 需要重新配对一次`);
  }
  let result: huks.HuksReturnResult;
  try {
    // 同一份属性再给一次(官方示例是这么传的 ✓), inData 留空 ✓
    result = await huks.finishSession(handle, { properties: props });
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'HUKS 解密收尾失败: code %{public}d %{public}s', err.code ?? -1, err.message ?? '');
    throw new Error(`HUKS 解密失败(${huksErrorText(err)}), 存着的密文解不开了, 需要重新配对一次`);
  }
  const midOut: Uint8Array = middle?.outData ?? new Uint8Array(0);
  const resOut: Uint8Array = result?.outData ?? new Uint8Array(0);
  const out: Uint8Array = midOut.length > 0 ? midOut : resOut;
  if (out.length === 0) {
    throw new Error('HUKS 解密失败: 没有明文, 存着的密文已经坏了, 需要重新配对一次');
  }
  const text: string = utf8ToString(out);
  const sep: number = text.indexOf('|');
  if (sep > 0) {
    const used: string = text.slice(0, sep);
    if (used !== purpose) {
      throw new Error('用途不对: 这段密文是别的用途的, 需要重新配对一次');
    }
    hilog.info(DOMAIN, TAG, 'HUKS 解密成功(用途 %{public}s)', purpose);
    return text.slice(sep + 1);
  }
  // 老格式(没写用途前缀)⇒ 认了, 但说明一声 ✓
  hilog.warn(DOMAIN, TAG, 'HUKS 解密成功, 但是老格式(没有用途前缀)');
  return text;
}

/** 这个设备到底能不能用 HUKS(给界面/日志用的)。 */
export async function probe(): Promise<string> {
  try {
    const cipher: string = await encrypt('dsh-harmony-probe');
    const plain: string = await decrypt(cipher);
    if (plain !== 'dsh-harmony-probe') {
      return 'HUKS 往返对不上, 这台机器的硬件钥匙服务有问题';
    }
    return 'ok';
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'HUKS 自检失败: code %{public}d %{public}s', err.code ?? -1, err.message ?? '');
    // 这句话是给界面看的 ⇒ 说人话; 错误码带出去, 英文原文留在日志里 ✓
    return `HUKS 用不了(${huksErrorText(err)}), 需要重新配对一次`;
  }
}
