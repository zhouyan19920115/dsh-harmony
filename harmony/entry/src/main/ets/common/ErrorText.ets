/**
 * 错误提示的中文化。
 *
 * 手机上原来直接把桌面端/中继/系统返回的原始字符串摆出来(`Unexpected Text in JSON: Invalid Token`、
 * `WebSocket 错误: `、`ECONNRESET`), 用户看不懂, 也不知道该不该管。
 * 这里把原始代码留着(方便排查), 后面补一句中文说明, 说明这到底是什么事、要不要紧。
 *
 * 三条原则:
 * - **原始代码不丢**: 原始字符串在前面, 中文说明在括号里 ⇒ 排查时还能搜到原文。
 * - **能说清楚的要说清楚**: 光说"失败"没有用, 要说清楚是"网络抖动"还是"要重新配对"。
 * - **不许漏网**: 规则表一条都没命中时, 也要按"长得像什么"猜一句中文说明,
 *   绝不能把**裸英文**原样还给用户 ✗ (这是这一版修的主要漏洞)
 *
 * 特别地: 密封通道偶尔会因为丢包解不开, 表现为 `Unexpected Text in JSON: Invalid Token`。
 * 这种**不影响对话**, 只是这一次的刷新没拿到, 所以单独给它一句话, 免得用户以为坏了。
 */

/** 一条匹配规则。 */
interface Rule {
  /** 原始文字里含有它就命中。 */
  needle: string;
  /** 命中之后的中文说明。 */
  text: string;
  /** 整段文字完全一样才算命中(默认 false = 含有即可)。 */
  whole: boolean;
}

/**
 * 规则表: 先匹配"整段相同"的, 再匹配"含有"的 ⇒ 整段相同的优先 ✓
 *
 * 排版上有两条讲究:
 * - **具体的排在泛指的前面**: `the seal key could not be unwrapped`(要重新配对)必须排在
 *   泛指的 `seal`(这一次的抖动)前面, 否则会把"要重新配对"说成"没事"。
 * - **含有匹配按数组顺序取第一条**, 所以同一个词的多条规则, 顺序就是优先级。
 */
const RULES: Rule[] = [
  // ---- 整段相同: 这些错误经常整段出现在异常里, 按"完全一样"精确匹配 ----
  { needle: 'Invalid Token', text: '密封数据校验失败, 这一次的网络抖动, 不影响对话', whole: true },
  { needle: 'ECONNRESET', text: '连接被对方强制断开, 网络抖动或线路上的盒子掐断了空闲连接', whole: true },
  { needle: 'ECONNREFUSED', text: '连不上对方, 对方没在运行或者端口没开', whole: true },
  { needle: 'ECONNABORTED', text: '连接被中断, 网络抖动', whole: true },
  { needle: 'ETIMEDOUT', text: '等对方回应等太久了, 网络慢或者对方没在运行', whole: true },
  { needle: 'EPIPE', text: '连接已经断了, 网络抖动', whole: true },
  { needle: 'EAI_AGAIN', text: '域名暂时解析不了, 网络抖动, 重试即可', whole: true },
  { needle: 'ENOTFOUND', text: '域名解析不了, 检查一下网络或者 DNS', whole: true },
  { needle: 'EHOSTUNREACH', text: '网络不通, 检查一下 WiFi 或者移动数据', whole: true },
  { needle: 'ENETUNREACH', text: '网络不通, 检查一下 WiFi 或者移动数据', whole: true },
  { needle: 'CURLE_COULDNT_CONNECT', text: '连不上, 刚换过网络, 旧连接已经失效', whole: true },
  { needle: 'CURLE_OPERATION_TIMEDOUT', text: '等对方回应等太久了, 网络慢或者对方没在运行', whole: true },
  { needle: 'Unexpected end of JSON input', text: '返回的内容少了一半, 这一次的网络抖动, 不影响对话', whole: true },
  { needle: 'Unexpected token', text: '返回的内容解析不了, 这一次的网络抖动, 不影响对话', whole: true },
  { needle: 'socket hang up', text: '连接被中途掐断了, 这一次的网络抖动, 不影响对话', whole: true },

  // ---- 密封 / 加密: 绝大多数只是"这一次的刷新没拿到" ----
  // 顺序要紧: 401 的那几条(要重新配对)排在前面, 泛指的 `seal` 排在最后。
  { needle: 'the seal key could not be unwrapped', text: '密封钥匙解不开, 令牌变了, 需要重新配对', whole: false },
  { needle: 'the wrapped seal key is too short', text: '密封钥匙不完整, 需要重新配对一次', whole: false },
  { needle: 'the seal could not be opened', text: '密封数据解不开, 令牌变了, 需要重新配对', whole: false },
  { needle: 'the sealed body is not valid JSON', text: '密封内容解析不了, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'the seal is outside the replay window', text: '密封数据过期了(超过五分钟), 重发一次就好', whole: false },
  { needle: 'the seal is too short', text: '密封数据不完整, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'the seal needs a timestamp', text: '密封数据少了时间戳, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'the seal key must be 32 bytes', text: '电脑端和 App 的加密版本对不上, 更新一下电脑端的桥接', whole: false },
  { needle: 'the bridge token is required for the seal', text: '没有令牌, 需要重新配对一次', whole: false },
  { needle: 'unable to authenticate data', text: '密封数据校验失败, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'tag mismatch', text: '密封数据校验失败, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'authenticate', text: '密封数据校验失败, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'the envelope is too short', text: '密封数据不完整, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'the native seal is not usable', text: '手机这边的加密通道用不了, 更新一下 App 再试', whole: false },
  { needle: 'the native seal failed on', text: '手机这边的加密通道出错了, 更新一下 App 再试', whole: false },
  { needle: 'GCM', text: '加密通道出了问题, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'AES', text: '加密通道出了问题, 这一次的网络抖动, 不影响对话', whole: false },

  // ---- JSON 解析: 同样是"这一次的刷新没拿到" ----
  { needle: 'Unexpected Text in JSON', text: '返回的内容不是预期的格式, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'Unexpected Number in JSON', text: '返回的内容缺了一半, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'Invalid Token', text: '密封数据校验失败, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'InvalidCharacterError', text: '返回的内容里有非法字符, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'SyntaxError', text: '返回的内容解析不了, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'JSON.parse', text: '返回的内容解析不了, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'JSON', text: '返回的内容不是预期的格式, 这一次的网络抖动, 不影响对话', whole: false },

  // ---- 网络 ----
  // Chrome 内核的网络错误: 名字很具体, 但意思就那几样 ⇒ 挨个说清楚。
  { needle: 'net::ERR_NAME_NOT_RESOLVED', text: '域名解析不了, 检查一下 WiFi 或者 DNS', whole: false },
  { needle: 'net::ERR_CONNECTION_REFUSED', text: '连不上对方, 对方没在运行或者端口没开', whole: false },
  { needle: 'net::ERR_CONNECTION_RESET', text: '连接被重置了, 网络抖动, 正在自动重连', whole: false },
  { needle: 'net::ERR_CONNECTION_CLOSED', text: '连接被关掉了, 网络抖动, 正在自动重连', whole: false },
  { needle: 'net::ERR_CONNECTION_TIMED_OUT', text: '等对方回应等太久了, 网络慢或者对方没在运行', whole: false },
  { needle: 'net::ERR_TIMED_OUT', text: '等对方回应等太久了, 网络慢或者对方没在运行', whole: false },
  { needle: 'net::ERR_EMPTY_RESPONSE', text: '对方没有回话, 这一次的网络抖动, 不影响对话', whole: false },
  { needle: 'net::ERR_INTERNET_DISCONNECTED', text: '网络断了, 检查一下 WiFi 或者移动数据', whole: false },
  { needle: 'net::ERR_PROXY', text: '代理服务器有问题, 检查一下网络设置', whole: false },
  { needle: 'net::ERR_CERT', text: '证书校验没通过', whole: false },
  { needle: 'net::ERR_', text: '网络层失败(浏览器内核的报错), 一般是网络抖动或者对方服务没起来, 重试即可', whole: false },
  { needle: 'timeout', text: '等对方回应等太久了, 网络慢或者对方没在运行', whole: false },
  { needle: 'Timeout', text: '等对方回应等太久了, 网络慢或者对方没在运行', whole: false },
  { needle: 'not connected', text: '还没连上桌面端', whole: false },
  { needle: 'Network is unreachable', text: '网络不通, 检查一下 WiFi 或者移动数据', whole: false },
  { needle: 'Unable to resolve host', text: '域名解析不了, 检查一下网络或者 DNS', whole: false },
  { needle: 'connection refused', text: '连不上对方, 对方没在运行', whole: false },
  { needle: 'reset by peer', text: '连接被对方断开, 网络抖动', whole: false },
  { needle: 'client network socket disconnected', text: '连接被掐断了, 网络抖动, 正在自动重连', whole: false },
  { needle: 'ECONNRESET', text: '连接被对方强制断开, 网络抖动, 正在自动重连', whole: false },
  { needle: 'ECONNREFUSED', text: '连不上对方, 对方没在运行或者端口没开', whole: false },
  { needle: 'ENOTFOUND', text: '域名解析不了, 检查一下网络或者 DNS', whole: false },
  { needle: 'EAI_AGAIN', text: '域名暂时解析不了, 网络抖动, 重试即可', whole: false },
  { needle: 'Network Error', text: '网络错误, 检查一下 WiFi 或者移动数据', whole: false },
  { needle: 'Failed to fetch', text: '网络断了或者对方没在运行, 检查一下网络再重试', whole: false },
  { needle: 'getaddrinfo', text: '域名解析不了, 检查一下网络或者 DNS', whole: false },
  { needle: '证书', text: '证书校验没通过', whole: false },
  { needle: 'certificate', text: '证书校验没通过', whole: false },
  { needle: 'cert', text: '证书校验没通过', whole: false },
  { needle: 'SSL', text: '加密通道出了问题', whole: false },
  { needle: 'TLS', text: '加密通道出了问题', whole: false },

  // ---- 中继 / 设备 ----
  { needle: 'device_offline', text: '桌面端不在线, 等它重新连上中继', whole: false },
  { needle: 'is offline', text: '桌面端不在线, 等它重新连上中继', whole: false },
  { needle: 'unknown_device', text: '中继上找不到这台设备', whole: false },
  { needle: 'unknown_account', text: '中继上找不到这个账号, 重新配对一次', whole: false },
  { needle: 'device_conflict', text: '设备号冲突, 需要重新配对一次', whole: false },
  { needle: 'the device token is wrong', text: '令牌不对, 需要重新配对', whole: false },
  { needle: 'the account token is wrong', text: '令牌不对, 需要重新配对', whole: false },
  { needle: 'the phone did not present a valid token', text: '令牌不对, 需要重新配对', whole: false },
  { needle: 'the desktop bridge does not announce its token', text: '电脑端的版本太旧, 认不出新令牌, 更新一下电脑端的桥接', whole: false },
  { needle: 'the device token was revoked', text: '设备令牌被吊销了, 需要重新配对', whole: false },
  { needle: 'token is required', text: '令牌不对, 需要重新配对', whole: false },
  { needle: 'too many failed device attempts', text: '试得太频繁了, 等一会儿再试', whole: false },
  { needle: 'unauthorized', text: '令牌不对, 需要重新配对', whole: false },
  { needle: 'bad token', text: '令牌不对, 需要重新配对', whole: false },
  { needle: 'token expired', text: '令牌过期了, 需要重新配对', whole: false },
  { needle: 'the bridge is not connected to an account', text: '电脑端没有连上中继账号, 在电脑上重新登录一下', whole: false },
  { needle: 'the phone did not say which device it is', text: '手机没有报出自己的设备号, 重新配对一次', whole: false },
  { needle: 'the relay is not reachable', text: '连不上中继, 检查一下网络', whole: false },
  { needle: 'the relay did not issue any credentials', text: '中继没有发凭证, 在电脑上重新登录一次', whole: false },
  { needle: 'the relay did not answer', text: '中继没回应, 网络抖动, 正在自动重连', whole: false },
  { needle: 'the relay closed the connection during the handshake', text: '中继握手中断, 网络抖动, 正在自动重连', whole: false },
  { needle: 'the relay connection failed before the handshake', text: '中继握手中断, 网络抖动, 正在自动重连', whole: false },
  { needle: 'the relay refused the stream', text: '中继拒绝了这路连接, 正在自动重连', whole: false },
  { needle: 'is not registered', text: '中继上找不到它(设备或者账号), 重新配对一次', whole: false },
  { needle: 'does not name a device', text: '这个地址里没有设备号, 检查一下地址', whole: false },
  { needle: 'does not belong to the account', text: '这台设备不属于这个账号, 重新配对一次', whole: false },
  { needle: 'exists in several accounts', text: '同一个设备号在好几个账号里, 地址要写成 /<账号>/<设备号>/… 这种', whole: false },
  { needle: 'relay', text: '中继这一段出问题了, 网络抖动或者中继没起来, 重试即可', whole: false },

  // ---- 电脑端(桥接 / DSH) ----
  { needle: 'the DSH application could not be reached', text: '连不上电脑上的 DSH, 确认它还在运行', whole: false },
  { needle: 'the DSH application is not reachable', text: '连不上电脑上的 DSH, 确认它还在运行', whole: false },
  { needle: 'DSH rejected the bridge credential', text: '电脑上的 DSH 不认这个令牌, 需要重新配对', whole: false },
  { needle: 'dsh/unauthorized', text: '电脑上的 DSH 不认这个令牌, 需要重新配对', whole: false },
  { needle: 'dsh/stream-error', text: '电脑那边的那条流断了, 网络抖动, 正在自动重连', whole: false },
  { needle: 'the browser-session secret could not be decoded', text: '电脑上的会话密钥读不出来, 重启一下电脑上的 DSH', whole: false },
  { needle: 'the request body is too large', text: '内容太大了, 电脑端一次收不下', whole: false },
  { needle: 'the request body is not valid JSON', text: '请求内容格式不对, 一般是网络截断, 重试即可', whole: false },
  { needle: 'the frame is not valid JSON', text: '协议对不上, App 和电脑端版本不一致, 更新一下电脑端的桥接', whole: false },
  { needle: 'the frame has no type', text: '协议对不上, App 和电脑端版本不一致, 更新一下电脑端的桥接', whole: false },
  { needle: 'unsupported frame type', text: '协议对不上, App 和电脑端版本不一致, 更新一下电脑端的桥接', whole: false },
  { needle: 'the first frame has to carry the token', text: '协议对不上, App 和电脑端版本不一致, 更新一下电脑端的桥接', whole: false },
  { needle: 'websocket frame exceeds the payload limit', text: '内容太大了, 电脑端一次收不下', whole: false },
  { needle: 'websocket client frames must be masked', text: '协议对不上, App 和电脑端版本不一致, 更新一下电脑端的桥接', whole: false },
  { needle: 'provider and model are required', text: '没选模型, 先在设置里选一个', whole: false },
  { needle: 'unknown session', text: '这个会话不存在了, 刷新一下列表', whole: false },
  { needle: 'the message sequence must be a number', text: '协议对不上, 更新一下电脑端的桥接', whole: false },
  { needle: 'the prompt text must not be empty', text: '没输入内容', whole: false },
  { needle: 'the command line must not be empty', text: '指令是空的', whole: false },
  { needle: 'a command line starts with a slash', text: '指令要以 / 开头', whole: false },
  { needle: 'unknown permission preset', text: '这个权限预设不认识, 更新一下电脑端的桥接', whole: false },
  { needle: 'the push token must not be empty', text: '推送令牌是空的, 重新开一次推送', whole: false },
  { needle: 'the bridge does not accept push tokens', text: '这个电脑端不收推送令牌, 更新一下电脑端的桥接', whole: false },
  { needle: 'the push token endpoint', text: '推送服务那边出问题了, 找开发者看看', whole: false },
  { needle: 'no push secret is configured', text: '电脑端没配推送密钥, 找开发者看看', whole: false },
  { needle: 'the pairing endpoint is restricted to localhost', text: '配对接口只允许在电脑上本机调用', whole: false },

  // ---- 协议里的错误码 ----
  { needle: 'bad_request', text: '请求没被看懂, 重试即可', whole: false },
  { needle: 'method_not_allowed', text: '这个地址不支持这种请求, 电脑端版本可能太旧', whole: false },
  { needle: 'not_found', text: '这个地址不存在, 电脑端版本可能太旧', whole: false },
  { needle: 'dsh_unavailable', text: '连不上电脑上的 DSH, 确认它还在运行', whole: false },

  // ---- 已经有中文的 ----
  { needle: '请求失败', text: '连不上或者等太久, 网络抖动, 重试即可', whole: false },
  { needle: '配对码', text: '配对码过期了, 重新扫一次码就好', whole: false },
  { needle: 'WebSocket', text: '实时连接断了, 正在自动重连, 不影响正在进行的对话', whole: false }
];

/**
 * 拿到一段原始错误文字, 补上中文说明。
 *
 * 返回的格式是 `原始文字(中文说明)`; 已经带过说明的就不重复加了。
 */
export function explain(raw: string): string {
  const text: string = (raw ?? '').trim();
  if (text.length === 0) {
    return '未知错误(对方没给出更多信息), 重试一次看看';
  }
  // 已经解释过了 ⇒ 原样返回。
  if (alreadyExplained(text)) {
    return text;
  }
  // "中文前缀 + 原始报错"(如 `请求失败: CURLE_COULDNT_CONNECT`) ⇒ 把后半截单独解释,
  // 这样说明就贴在**那个码**后面, 用户一眼能看到是哪个码出的问题。
  const inner: string = explainInner(text);
  if (inner !== text) {
    return inner;
  }
  return explainCore(text);
}

/**
 * 真正干活的解释: 先查规则表, 再看状态码, 最后兜底。
 *
 * 拆成两个函数是为了让"中文前缀"那条路不会无限递归 ✓
 */
function explainCore(text: string): string {
  // 先找"整段相同"的。
  for (const rule of RULES) {
    if (rule.whole && text === rule.needle) {
      return `${text}(${rule.text})`;
    }
  }
  // 再找"含有"的。
  for (const rule of RULES) {
    if (!rule.whole && text.indexOf(rule.needle) >= 0) {
      return `${text}(${rule.text})`;
    }
  }
  // HTTP 状态码(`HTTP 500` / `status 500` / 光秃秃一个 `500`)。
  const status: number = findStatusCode(text);
  if (status > 0) {
    return `${text}(${describeStatus(status)})`;
  }
  // 一条规则都没命中 ⇒ 兜底, **绝不能把裸英文原样还给用户**。
  return fallbackExplain(text);
}

/**
 * "中文前缀 + 原始报错"这一种, 把后半截单独解释一遍。
 *
 * 例如 `请求失败: CURLE_COULDNT_CONNECT` ⇒
 * `请求失败: CURLE_COULDNT_CONNECT(连不上, 刚换过网络, 旧连接已经失效)`。
 *
 * 只有**前半截含中文、后半截不含中文**时才这么做:
 * - 前半截是中文 ⇒ 它是我们自己写的中文提示(标签), 后半截才是需要解释的原始串;
 * - 后半截不含中文 ⇒ 后半截就是原始报错, 值得单独解释。
 */
function explainInner(text: string): string {
  const colon: number = text.indexOf(':');
  if (colon <= 0) {
    return text;
  }
  const head: string = text.substring(0, colon);
  const tail: string = text.substring(colon + 1).trim();
  if (tail.length === 0 || !hasChinese(head) || hasChinese(tail)) {
    return text;
  }
  const explained: string = explainCore(tail);
  if (explained === tail) {
    return text;
  }
  return `${head}: ${explained}`;
}

/**
 * 这段文字是不是已经带过中文说明了?
 *
 * 以前只看"有没有括号", 结果 `SyntaxError (foo)` 这种**原始错误自带括号**的会被误判成
 * "解释过了" ⇒ 于是再也不加中文, 用户看着还是一句英文 ✗
 *
 * 现在改成: 结尾是一段括号, 而且括号里**有中文** ⇒ 才算解释过了 ✓
 * 我们自己的说明都是中文 ⇒ 判据够用; 原始错误里的括号通常没有中文 ⇒ 不会被误判。
 */
function alreadyExplained(text: string): boolean {
  if (!text.endsWith(')')) {
    return false;
  }
  const open: number = text.lastIndexOf('(');
  if (open <= 0) {
    return false;
  }
  return hasChinese(text.substring(open + 1, text.length - 1));
}

/**
 * 这段文字里有没有中文?
 *
 * 只认基本汉字、扩展 A、中文标点和全角符号 —— 够用就行, 不必上 Unicode 大表。
 */
function hasChinese(text: string): boolean {
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code >= 0x4e00 && code <= 0x9fff) {
      return true;
    }
    if (code >= 0x3400 && code <= 0x4dbf) {
      return true;
    }
    if (code >= 0x3000 && code <= 0x303f) {
      return true;
    }
    if (code >= 0xff00 && code <= 0xffef) {
      return true;
    }
  }
  return false;
}

/** 一个字符是不是数字? */
function isDigit(ch: string): boolean {
  return ch >= '0' && ch <= '9';
}

/** 整段是不是数字? */
function isAllDigits(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  for (let i = 0; i < text.length; i++) {
    if (!isDigit(text.charAt(i))) {
      return false;
    }
  }
  return true;
}

/**
 * 从一段文字里找 HTTP 状态码。
 *
 * 找法: 先看有没有"状态码"的味道(HTTP / status / code / 错误码),
 * 有的话取第一个**独立的三位数**(前后都不是数字);
 * 没有的话, 整段就是一个三位数才算。
 *
 * 不用正则的先行/后行断言 —— ArkTS 的正则实现不一定支持 ✓ 所以自己扫。
 */
function findStatusCode(text: string): number {
  const upper: string = text.toUpperCase();
  const hasHint: boolean = upper.indexOf('HTTP') >= 0
    || upper.indexOf('STATUS') >= 0
    || upper.indexOf('CODE') >= 0
    || text.indexOf('状态码') >= 0
    || text.indexOf('错误码') >= 0
    || text.indexOf('错误代码') >= 0
    || looksLikeStatusPhrase(text);
  if (!hasHint) {
    // 光秃秃一个三位数(`404`)才算状态码。
    if (text.length === 3 && isAllDigits(text)) {
      const only: number = Number.parseInt(text, 10);
      if (only >= 400 && only <= 599) {
        return only;
      }
    }
    return 0;
  }
  const run: string = firstStandaloneThreeDigits(text);
  if (run.length !== 3) {
    return 0;
  }
  const code: number = Number.parseInt(run, 10);
  if (code >= 400 && code <= 599) {
    return code;
  }
  return 0;
}

/**
 * `403 Forbidden` / `500 Internal Server Error` 这种"状态码 + 一句话"的写法。
 *
 * 开头就是三位数, 后面跟着空格(或者冒号) ⇒ 当状态码看 ✓
 * (只看开头三位数是不够的: `12345` 的前三位也是数字, 所以后面必须跟分隔符。)
 */
function looksLikeStatusPhrase(text: string): boolean {
  if (text.length < 4) {
    return false;
  }
  if (!isAllDigits(text.substring(0, 3))) {
    return false;
  }
  const sep: string = text.charAt(3);
  return sep === ' ' || sep === ':' || sep === '\t';
}

/**
 * 找出第一个"独立的三位数"(前后都不是数字) ⇒ 状态码。
 */
function firstStandaloneThreeDigits(text: string): string {
  let i: number = 0;
  while (i < text.length) {
    if (!isDigit(text.charAt(i))) {
      i++;
      continue;
    }
    let j: number = i;
    while (j < text.length && isDigit(text.charAt(j))) {
      j++;
    }
    const beforeOk: boolean = i === 0 || !isDigit(text.charAt(i - 1));
    const afterOk: boolean = j >= text.length || !isDigit(text.charAt(j));
    if (beforeOk && afterOk && j - i === 3) {
      return text.substring(i, j);
    }
    i = j;
  }
  return '';
}

/** HTTP 状态码 → 中文说明。 */
function describeStatus(code: number): string {
  if (code === 400) {
    return '请求没被看懂, 通常是网络截断, 重试即可';
  }
  if (code === 401) {
    return '令牌不对, 需要重新配对';
  }
  if (code === 403) {
    return '没有权限, 令牌不对或者地址不对';
  }
  if (code === 404) {
    return '这个地址不存在, 电脑端版本可能太旧';
  }
  if (code === 405) {
    return '这个地址不支持这种请求, 电脑端版本可能太旧';
  }
  if (code === 408) {
    return '等对方回应等太久了, 重试即可';
  }
  if (code === 409) {
    return '两边对不上(设备号冲突之类), 重新配对一次';
  }
  if (code === 413) {
    return '内容太大了, 电脑端一次收不下';
  }
  if (code === 422) {
    return '内容格式不对, 电脑端没看懂';
  }
  if (code === 429) {
    return '试得太频繁了, 等一会儿再试';
  }
  if (code === 500) {
    return '电脑端自己报错了, 看电脑上的日志';
  }
  if (code === 501) {
    return '电脑端不支持这个请求, 版本可能太旧';
  }
  if (code === 502) {
    return '中继到电脑端这一段没打通, 稍后自动重试';
  }
  if (code === 503) {
    return '电脑端不在线, 等它重新连上中继';
  }
  if (code === 504) {
    return '等电脑端回应等太久了, 稍后自动重试';
  }
  if (code >= 500) {
    return '电脑端那边出错了, 看电脑上的日志';
  }
  if (code >= 400) {
    return '请求被电脑端拒绝了, 稍后重试';
  }
  return '这个状态码一般不该出现在错误里, 记下来给开发者看';
}

/**
 * 一条规则都没命中时的兜底。
 *
 * 原则: **不许把裸英文原样还给用户** ⇒ 宁可给一句具体点的猜测, 也不要让用户对着英文发呆。
 * 猜测的顺序: 已经是中文 ⇒ 不用管; 系统错误码 ⇒ 说清楚是系统码;
 * 内部编号 ⇒ 说清楚那不是给人看的报错; 长得像错误 ⇒ 通用错误说明;
 * 什么都不像 ⇒ 说"看不出具体原因, 一般不影响使用"。
 */
function fallbackExplain(text: string): string {
  // 已经是中文了 ⇒ 不再加一句中文(免得啰嗦)。
  if (hasChinese(text)) {
    return text;
  }
  // 纯数字: HarmonyOS 的 BusinessError 有时只给一个错误码。
  if (isAllDigits(text)) {
    return `${text}(HarmonyOS 系统错误码, 多半是网络抖动, 重试即可)`;
  }
  // `Error code: 12345` / `code=12345` / `BusinessError: 12500002` 这一类。
  if (looksLikeSystemCode(text)) {
    return `${text}(HarmonyOS 系统错误码, 多半是网络抖动或者权限不够, 重试即可)`;
  }
  // 十六进制 / UUID ⇒ 内部编号, 不是给人看的报错。
  if (looksLikeInternalId(text)) {
    return `${text}(这是一串内部编号, 不是给人看的报错, 一般不影响使用)`;
  }
  // 明显是个错误, 但规则表里没有 ⇒ 通用兜底。
  if (hasErrorWord(text)) {
    return `${text}(对方返回了一个错误, 通常是网络抖动或者对方服务没起来, 重试一次就好)`;
  }
  // 连"错误"两个字都没有 ⇒ 大概是对方漏了一句说明。
  return `${text}(对方返回了一段看不懂的英文, 看不出具体原因, 一般不影响使用, 可以先忽略)`;
}

/**
 * `Error code: 12345` / `code=12345` / `BusinessError: 12500002` 这一类:
 * 里面的数字是**系统给的错误码**, 不是 HTTP 状态码。
 */
function looksLikeSystemCode(text: string): boolean {
  const lower: string = text.toLowerCase();
  if (lower.indexOf('error code') >= 0) {
    return true;
  }
  if (lower.indexOf('code=') >= 0) {
    return true;
  }
  if (lower.indexOf('code:') >= 0) {
    return true;
  }
  if (lower.indexOf('errcode') >= 0) {
    return true;
  }
  if (lower.indexOf('businesserror') >= 0) {
    return true;
  }
  if (text.indexOf('错误码') >= 0 || text.indexOf('错误代码') >= 0) {
    return true;
  }
  return false;
}

/**
 * 看起来像一个十六进制串或者 UUID ⇒ 多半是内部编号(会话号、请求号、摘要),
 * 不是给人看的报错 ⇒ 说清楚"一般不影响使用", 免得用户紧张。
 */
function looksLikeInternalId(text: string): boolean {
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(text)) {
    return true;
  }
  if (/^0x[0-9a-f]{4,}$/iu.test(text)) {
    return true;
  }
  if (/^[0-9a-f]{8,}$/iu.test(text)) {
    return true;
  }
  return false;
}

/**
 * 文字里有没有"这是个错误"的味道?
 *
 * 用来区分两种兜底: "对方报错了"和"对方只是回了句莫名其妙的话"。
 */
function hasErrorWord(text: string): boolean {
  const lower: string = text.toLowerCase();
  const words: string[] = [
    'err_', 'error', 'failed', 'failure', 'fail', 'refused', 'denied', 'invalid',
    'unexpected', 'cannot', 'could not', 'not allowed', 'not found', 'not supported',
    'timeout', 'timed out', 'abort', 'exception', 'panic', 'unavailable', 'missing',
    'broken', 'closed', 'rejected', 'forbidden', 'unsupported', 'unknown',
    'not registered', 'not permitted', 'no such'
  ];
  for (const word of words) {
    if (lower.indexOf(word) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * 把异常变成用户看得懂的文字。
 *
 * 用法: `this.notice = \`加载消息失败: ${describeError(err)}\``
 */
export function describeError(e: Error | undefined | null): string {
  if (e !== undefined && e !== null && e.message !== undefined && e.message.length > 0) {
    return explain(e.message);
  }
  return '未知错误(对方没给出更多信息), 重试一次看看';
}

/**
 * 这一类错误"不要紧"吗?
 *
 * 密封通道偶尔会因为丢包解不开, 表现成 `Invalid Token` / `Unexpected Text in JSON`。
 * 这种情况只是**这一次**的刷新没拿到数据, 正在进行的对话不受影响 ⇒ 不必吓用户。
 *
 * 判定分三步, 顺序很重要:
 * 1. 需要重新配对的(401/403/unauthorized/令牌过期)⇒ 一定要说出来, 不能说成"没事";
 * 2. 彻底连不上的(ECONNREFUSED/域名解析不了)⇒ 也不是"丢包", 得让用户去查网络;
 * 3. 剩下的才是"这一次的抖动" ⇒ 无害。
 */
export function isTransientNoise(raw: string): boolean {
  const text: string = (raw ?? '').trim();
  if (text.length === 0) {
    return false;
  }
  if (needsPairing(text)) {
    return false;
  }
  if (isHardDown(text)) {
    return false;
  }
  return hasTransientSignal(text);
}

/**
 * 需要用户去重新配对的那种错误。
 *
 * 这些**绝不能**被说成"丢包无害" ⇒ 用户不去重新配对就一直用不了。
 */
function needsPairing(text: string): boolean {
  const lower: string = text.toLowerCase();
  if (lower.indexOf('unauthorized') >= 0) {
    return true;
  }
  if (lower.indexOf('unwrapped') >= 0) {
    return true;
  }
  if (lower.indexOf('could not be opened') >= 0) {
    return true;
  }
  if (lower.indexOf('token expired') >= 0) {
    return true;
  }
  if (lower.indexOf('expired') >= 0) {
    return true;
  }
  if (lower.indexOf('bad token') >= 0) {
    return true;
  }
  if (lower.indexOf('wrong token') >= 0) {
    return true;
  }
  if (lower.indexOf('revoked') >= 0) {
    return true;
  }
  if (text.indexOf('过期') >= 0 || text.indexOf('重新配对') >= 0 || text.indexOf('认证失败') >= 0) {
    return true;
  }
  // 401 / 403: 用"独立三位数"来找, 免得 '1401' 之类的编号误伤。
  const run: string = firstStandaloneThreeDigits(text);
  if (run === '401' || run === '403') {
    return true;
  }
  return false;
}

/**
 * 彻底连不上(对方根本没在运行 / 域名解析不了)⇒ 也不是"丢包", 得让用户去查网络。
 */
function isHardDown(text: string): boolean {
  const lower: string = text.toLowerCase();
  if (lower.indexOf('econnrefused') >= 0) {
    return true;
  }
  if (lower.indexOf('connection refused') >= 0) {
    return true;
  }
  if (lower.indexOf('enotfound') >= 0) {
    return true;
  }
  if (lower.indexOf('eai_again') >= 0) {
    return true;
  }
  if (lower.indexOf('unreachable') >= 0) {
    return true;
  }
  if (lower.indexOf('unable to resolve host') >= 0) {
    return true;
  }
  if (lower.indexOf('name not resolved') >= 0 || lower.indexOf('name_not_resolved') >= 0) {
    return true;
  }
  if (lower.indexOf('connection_refused') >= 0) {
    return true;
  }
  if (lower.indexOf('failed to fetch') >= 0) {
    return true;
  }
  if (lower.indexOf('timedout') >= 0 || lower.indexOf('timed out') >= 0 || lower.indexOf('timed_out') >= 0) {
    return true;
  }
  return false;
}

/**
 * "这一次的刷新没拿到"的信号。
 *
 * 密封通道解不开(JSON 解析失败)、连接被中途掐断(会自动重连)都算这一类。
 */
function hasTransientSignal(text: string): boolean {
  const lower: string = text.toLowerCase();
  const signals: string[] = [
    // JSON / 密封通道解析失败
    'invalid token',
    'unexpected text in json',
    'unexpected number in json',
    'unexpected token',
    'unexpected end of json input',
    'invalidcharactererror',
    'syntaxerror',
    'json.parse',
    'unable to authenticate data',
    'tag mismatch',
    'the sealed body is not valid json',
    'the seal is outside the replay window',
    'the seal is too short',
    'the seal needs a timestamp',
    // 连接被中途掐断(会自动重连)
    'econnreset',
    'epipe',
    'socket hang up',
    'client network socket disconnected',
    'reset by peer',
    'websocket'
  ];
  for (const signal of signals) {
    if (lower.indexOf(signal) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * 给"不要紧"的错误一个专门的说法。
 *
 * 只是丢包造成的 ⇒ 说「少量通讯丢包, 不影响对话操作」; 别的原因 ⇒ 老老实实说清楚。
 */
export function describeSoftly(e: Error | undefined | null): string {
  if (e !== undefined && e !== null && e.message !== undefined && isTransientNoise(e.message)) {
    return '少量通讯丢包, 不影响对话操作';
  }
  return describeError(e);
}
