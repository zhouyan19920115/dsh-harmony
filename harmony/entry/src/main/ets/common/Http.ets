/**
 * HTTP 请求层。
 *
 * ArkTS 运行时没有 fetch / Response / RequestInit, 因此使用 @kit.NetworkKit 的
 * `@ohos.net.http`(ohosHttp)。它与 fetch 的主要差异:
 * - 响应是 HttpResponse, 状态码在 `responseCode`, 文本在 `result`;
 * - 需要显式 `destroy()` 释放底层连接, 否则连接池会堆积。
 *
 * ## 这一层还管一件事: 非 2xx 的回答不许原样往上传
 *
 * 桥接那边回错误的时候用的是 `{"error":"unauthorized","message":"a valid bearer token is
 * required"}` 这种英文信封; 中继/网关回错误的时候更干脆, 给你一整页 HTML。
 * 这些东西原样抛上去, 用户看到的就是「裸英文 + 一坨 HTML」✗
 * ⇒ **在这一层就把非 2xx 换成一句人话**: `服务端返回 401(令牌不对, 需要重新配对)` ✓
 * 调用方拿到的是能直接显示的句子, 不用再去 parse 一坨 HTML(省得炸成
 * `Unexpected Text in JSON: Invalid Token` 那种天书)✓
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { describeError as describeErrorText, explain } from './ErrorText';
import { scrubSecrets } from './Seal';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF03;

export interface HttpResult {
  code: number;
  body: string;
}

const DEFAULT_TIMEOUT: number = 15000;

/** 错误信封里的那一块: `{ code: 'bad_request', message: '…' }`。 */
interface ErrorInfo {
  code?: string;
  message?: string;
}

/**
 * 桥接那边的错误信封: `{ error: { code: 'bad_request', message: '…' } }`。
 *
 * 也认扁平的 `{ message: '…' }` —— 别的服务不一定照这个形状回 ✓
 */
interface ErrorEnvelope {
  error?: ErrorInfo;
  message?: string;
}

/**
 * 一段文字里有没有中文。
 *
 * 用来判断「这句能不能直接摆给用户看」: 桥接那边有时候回中文
 * (比如 `配对码无效或已过期`), 那就直接给用户看 ✓; 回英文的就不给看 ✗
 */
export function hasChinese(text: string): boolean {
  return /[\u4e00-\u9fff]/u.test(text);
}

/**
 * 状态码翻译成人话。
 *
 * 说清楚三件事: **这是什么状态 / 要不要紧 / 该怎么办** ✓
 */
export function explainHttpCode(code: number): string {
  if (code === 400) {
    return '请求没被看懂, 通常是内容写错了或者网络被截断';
  }
  if (code === 401) {
    return '令牌不对, 需要重新配对';
  }
  if (code === 403) {
    return '没有权限, 令牌不对或者地址不对';
  }
  if (code === 404) {
    return '这个地址不存在, 桌面端版本可能太旧';
  }
  if (code === 405) {
    return '这个地址不接受这种请求, 桌面端版本可能太旧';
  }
  if (code === 408) {
    return '等对方回应等太久了, 网络慢或者对方没在运行';
  }
  if (code === 413) {
    return '内容太长发不过去, 少发一点试试';
  }
  if (code === 429) {
    return '请求太频繁了, 稍等一会儿再试';
  }
  if (code === 500) {
    return '桌面端自己报错了, 看电脑上的日志';
  }
  if (code === 502) {
    return '网关错误, 中继到桌面端没打通, 稍后自动重试';
  }
  if (code === 503) {
    return '桌面端不在线, 等它重新连上中继';
  }
  if (code === 504) {
    return '等桌面端回应等太久了, 稍后自动重试';
  }
  if (code >= 500) {
    return '服务端出错了, 稍后自动重试';
  }
  if (code >= 400) {
    return '请求没被接受, 稍后重试';
  }
  return '状态正常';
}

/**
 * 从错误信封里抠出那一句人话。
 *
 * 抠不出来就返回空串 —— 调用方自己决定怎么补一句中文 ✓
 *
 * **只带中文**: 桥接那边的 `message` 有时候是英文(`a valid bearer token is required`),
 * 那种直接摆给用户看等于没汉化 ✗
 */
export function errorDetail(body: string): string {
  const text: string = (body ?? '').trim();
  // 不是 JSON 信封就别硬抠了(HTML 错误页之类)✓
  if (!text.startsWith('{')) {
    return '';
  }
  try {
    const parsed: ErrorEnvelope = JSON.parse(text) as ErrorEnvelope;
    // 桥接那边是套着的: `{ error: { code, message } }` ⇒ 先看里层, 再看平铺的那层 ✓
    const inner: ErrorInfo | undefined = parsed.error;
    const message: string = inner?.message ?? parsed.message ?? '';
    if (message.length > 0 && message.length <= 120 && hasChinese(message)) {
      return message;
    }
  } catch (e) {
    // 压根不是能解析的 JSON ⇒ 抠不出来, 返回空串 ✓
  }
  return '';
}

/**
 * 把非 2xx 的回答换成一句人话。
 *
 * 返回的形状有两种:
 * - 对方自己给的是中文(比如「配对码无效或已过期」)⇒ `配对码无效或已过期(服务端返回 400)`
 *   —— 先说真正的原因, 状态码放后面 ✓
 * - 没有中文可说 ⇒ `服务端返回 401(令牌不对, 需要重新配对)`
 *
 * 共同的规矩:
 * - **状态码留着**(排查的时候还能搜到)✓
 * - 后面跟一句中文, 说清楚要不要紧、该怎么办 ✓
 * - **英文原文不往上传**: 用户看不懂, 排查的话日志里有 ✓
 */
export function humanizeHttpError(code: number, body: string): string {
  const detail: string = errorDetail(body);
  if (detail.length > 0) {
    return `${detail}(服务端返回 ${code})`;
  }
  return `服务端返回 ${code}(${explainHttpCode(code)})`;
}

/**
 * 发起一次 JSON 请求。失败时以异常抛出, 由调用方处理。
 *
 * **断网换网之后重试一次** ✓
 *
 * 踩过的坑: 手机从 WiFi 切到 5G 之后, 连接池里那条到中继的连接已经废了
 * (还绑在旧网络上)⇒ 第一个请求会直接失败(CURLE_COULDNT_CONNECT) ✗
 * 重试一次就会新建连接 ⇒ 好了 ✓
 */
export async function requestJson(method: http.RequestMethod, url: string, token: string,
  body?: string, timeout: number = 0): Promise<HttpResult> {
  let lastError: Error = new Error(explain('请求失败'));
  for (let attempt = 1; attempt <= 2; attempt++) {
    const client = http.createHttp();
    const effective: number = timeout > 0 ? timeout : DEFAULT_TIMEOUT;
    const header: Record<string, string> = {
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'application/json'
    };
    if (token.length > 0) {
      header['Authorization'] = `Bearer ${token}`;
    }
    const options: http.HttpRequestOptions = {
      method: method,
      header: header,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: effective,
      readTimeout: effective,
      usingCache: false
    };
    if (body !== undefined && body.length > 0) {
      // The body goes out as **bytes**, not as a string. A string is measured in characters, a
      // Chinese name is three bytes per character — the client then announces a body that is
      // eight bytes too short, the server reads a truncated request and answers "400 Bad
      // Request" with an empty body. The registration of the phone (the one request with a
      // Chinese name in it) never arrived because of that.
      options.extraData = util.TextEncoder.create('utf-8').encodeInto(body).buffer;
    }
    try {
      const response = await client.request(url, options);
      let text: string = '';
      if (typeof response.result === 'string') {
        text = response.result;
      } else if (response.result instanceof ArrayBuffer) {
        text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(response.result));
      }
      const code: number = response.responseCode;
      if (code < 200 || code >= 300) {
        // 非 2xx ⇒ 换成一句人话再交出去, 调用方不用去 parse 一坨 HTML/英文信封 ✓
        // 原文留一条日志: 排查的时候还能看到对方到底说了什么 ✓
        // (日志里也不能有完整令牌 ⇒ 洗一遍 ✓; 错误页可能很长 ⇒ 截一段 ✓)
        const brief: string = text.length > 200 ? text.substring(0, 200) : text;
        hilog.warn(DOMAIN, TAG, 'HTTP %{public}d: %{public}s', code, scrubSecrets(brief));
        return { code: code, body: humanizeHttpError(code, text) };
      }
      return { code: code, body: text };
    } catch (e) {
      const err = e as BusinessError;
      lastError = new Error(`请求失败: ${explain(err.message ?? '')}`);
      if (attempt < 2) {
        // 换网之后第一次失败很正常 ⇒ 重试一次(会新建连接 ✓)
        hilog.warn(DOMAIN, TAG, '请求失败, 重试一次: %{public}s', err.message ?? '');
      }
    } finally {
      client.destroy();
    }
  }
  throw lastError;
}

/**
 * 把一段回答安全地解析成 JSON。
 *
 * 直接 `JSON.parse` 失败时抛的是引擎原话(`Unexpected Text in JSON: Invalid Token`),
 * 那是给程序员看的 ✗ ⇒ 这里包一层, 抛出来的是能直接显示的中文 ✓
 * 并且原始报错保留在后面(排查的时候还能搜到)✓
 */
export function parseJsonSafe(text: string): Object {
  try {
    return JSON.parse(text) as Object;
  } catch (e) {
    const err = e as Error;
    throw new Error(`返回的内容解析不了: ${explain(err.message ?? '')}`);
  }
}

/** 把异常转换成可读文本(带中文说明)。 */
export function describeError(e: Error): string {
  return describeErrorText(e);
}
