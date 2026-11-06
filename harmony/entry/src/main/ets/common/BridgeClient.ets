/**
 * 桌面端桥接服务客户端。
 *
 * 负责两件事:
 * 1. REST —— 拉取会话列表 / 消息历史 / 工作区, 提交指令, 取消当前任务;
 * 2. WebSocket —— 接收桌面端的实时推送(会话状态、消息增量、消息完成)。
 *
 * 协议详见 docs/PROTOCOL.md。
 */
import { webSocket } from '@kit.NetworkKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { requestJson, HttpResult, errorDetail, explainHttpCode, hasChinese } from './Http';
import { explain } from './ErrorText';
import {
  SEAL_HEADER,
  SEAL_ID_HEADER,
  SEAL_KEY_HEADER,
  SEAL_TIMESTAMP_HEADER,
  deriveWrapKey,
  maskEndpoint,
  newSealKey,
  probeCrypto,
  sealRequestBody,
  scrubSecrets,
  unsealResponseBody,
  wrapSealKey
} from './Seal';
import { PendingSession, PendingSummary } from './LocalNotify';
import {
  AgentPreset,
  AgentPresetsResponse,
  BridgeMessage,
  CommandInfo,
  CommandsResponse,
  CommandPayload,
  CommandResultResponse,
  ConversationNode,
  DeviceInfo,
  DeviceListResponse,
  ErrorFrame,
  FileRefInfo,
  FilesResponse,
  FullMessageResponse,
  ModelCatalogResponse,
  PermissionOption,
  PermissionOptionsResponse,
  AskAnswer,
  AskAnswerPayload,
  AskCall,
  AskQuestionsResponse,
  ApprovalRequest,
  ApprovalsResponse,
  QueueItem,
  QueueResponse,
  SessionListResponse,
  MessageListResponse,
  SessionResponse,
  SessionStateData,
  SessionSummary,
  SessionTreeResponse,
  SkillInfo,
  SkillsResponse,
  SubmitResponse,
  WorkspaceEntry,
  WorkspaceListResponse,
  WsFrame,
  WsFrameData
} from './Models';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF04;

/** 桥接认证通过之后发来的第一帧(hello)。 */
interface HelloFrame {
  type: string;
  data?: HelloData;
}

/** hello 帧的内容。 */
interface HelloData {
  /** 桥接自己的令牌: 跟手机里的对不上就是配错了桌面 ✓ */
  token?: string;
  server?: string;
  version?: string;
}

/** 首帧认证的帧: `{ "type": "auth", "token": "…" }` ✓ */
interface AuthFrame {
  type: string;
  token: string;
}

/** 桌桥/中继的证书信息(GET /api/v1/relay/certificate)。 */
export interface RelayCertificate {
  /** 证书的 SHA256 指纹(大写十六进制) */
  sha256: string;
  host: string;
  port: number;
  selfSigned: boolean;
}

/**
 * 证书指纹的核对结果。
 *
 * - `unknown`: 第一次连这个主机 → 要弹窗让用户核对 ✓
 * - `match`: 和记住的指纹一样 → 继续连 ✓
 * - `mismatch`: 不一样 → 拒绝连(可能有人中间人)✓
 */
export type CertificateVerdict = 'unknown' | 'match' | 'mismatch';

/** 待办数量的响应体(GET /api/v1/pending)。 */
export interface PendingCountResponse {
  count?: number;
}
export interface PromptPreviewAction {
  /** 动作类型: command(执行命令) / delete(删文件) / write(写文件) / config(改配置) ... */
  kind?: string;
  /** 命令原文 */
  text?: string;
  /** 涉及的文件或目录 */
  path?: string;
}

/**
 * 危险动作预判的结果(GET /api/v1/sessions/{id}/prompt-preview)。
 *
 * `requiresConfirmation` 为 true 时, 手机上要再问一次用户才发。
 */
export interface PromptPreview {
  /** 要不要在手机上二次确认 */
  requiresConfirmation?: boolean;
  /** 判定依据(例如 danger-full-access) */
  reason?: string;
  /** 给人看的一句话(例如「桌面端要执行: 在 D:\\项目 里运行 npm install」) */
  summary?: string;
  /** 命中了哪些危险动作 */
  actions?: PromptPreviewAction[];
}

/**
 * 待办摘要(桥接服务广播的 `pending` 帧)。
 *
 * 桌面端在待办发生变化时广播它: 跑完了哪些会话、哪些会话在等用户回答。
 * 手机拿它弹本地通知(规则在 common/LocalNotify.ets 里, 两边共用一份类型)。
 */

/** `pending` 帧的完整形状。 */
export interface PendingFrame {
  type: string;
  data: PendingSummary;
}

/**
 * 实时事件回调。
 *
 * 注意: 这里刻意用"类 + 函数字段"而不是"接口 + 方法"——
 * ArkTS 的 arkts-no-untyped-obj-literals 规则不允许把对象字面量直接赋给
 * 含方法成员的接口, 用类可以既保留类型安全又能自由组装。
 */
export class BridgeListener {
  onSessions: (sessions: SessionSummary[]) => void = (_sessions: SessionSummary[]): void => {};
  onSessionState: (sessionId: string, state: string, title: string) => void =
    (_sessionId: string, _state: string, _title: string): void => {};
  onMessageCreated: (sessionId: string, message: BridgeMessage) => void =
    (_sessionId: string, _message: BridgeMessage): void => {};
  onMessageDelta: (sessionId: string, messageId: string, delta: string) => void =
    (_sessionId: string, _messageId: string, _delta: string): void => {};
  onMessageCompleted: (sessionId: string, message: BridgeMessage) => void =
    (_sessionId: string, _message: BridgeMessage): void => {};
  onBridgeError: (message: string) => void = (_message: string): void => {};
  onConnectionChanged: (connected: boolean) => void = (_connected: boolean): void => {};
  /**
   * 连接状态变了 —— **带三态的说法**(「已连接」/「重连中…」/「未连接」)✓
   *
   * 老回调 `onConnectionChanged` 只给"连上了没有"这个布尔 ⇒ 界面自己拼不出「重连中…」,
   * 于是每个页面各写各的二值判断(有的写「已连接」有的写「未连接」)⇒ 说法对不上、
   * 还会闪。这个回调直接给一句话, 界面照抄就行 ⇒ 所有页面一个口径 ✓
   */
  onConnectionLabel: (label: string, connected: boolean) => void =
    (_label: string, _connected: boolean): void => {};
  /** 待办摘要变了(任务跑完了 / 有问题等着回答)。 */
  onPending: (summary: PendingSummary) => void = (_summary: PendingSummary): void => {};
  /**
   * 首帧认证没过(令牌没了/过期了)⇒ 提醒外面去重新配对 ✓
   *
   * 不是「连不上」, 是「令牌不对」—— 重连多少次都一样 ⇒ 交给 AppState 自愈 ✓
   */
  onAuthFailed: () => void = (): void => {};
}

/** 提交指令的请求体 */
export interface SubmitPromptPayload {
  text: string;
  mode: string;
}

/** 新建会话的请求体 */
export interface CreateSessionPayload {
  cwd: string;
  title: string;
  /** 模式(桌面端的 agent preset); 空串表示用默认 */
  agentPreset?: string;
  /** 权限预设(read-only / workspace-write / danger-full-access) */
  permission?: string;
}

/** 换模型的请求体 */
export interface SelectModelPayload {
  provider: string;
  model: string;
  reasoningEffort: string;
}

/** 改队列里一条任务的请求体 */
export interface QueueActionPayload {
  itemId: string;
  /** edit | remove | steer */
  action: QueueAction;
}

/** 队列动作(桌面端 DSH 的形状) */
export interface QueueAction {
  kind: string;
  /** 只有 edit 用得上: 新的正文 */
  content?: QueueContentPart[];
}

/** 队列里一段文字 */
export interface QueueContentPart {
  type: string;
  text: string;
}

/** 桥接服务健康状态 */
export interface DshHealth {
  webUrl: string;
  reachable: boolean;
}

export interface HealthInfo {
  ok: boolean;
  name: string;
  version: string;
  dsh: DshHealth;
  now: number;
}

/**
 * 桌面端地址解析结果。
 *
 * 地址可以写成完整 URL, 以便支持云中继:
 *   - `192.168.1.10:8787`              局域网直连(省略协议)
 *   - `http://10.0.2.2:8787`            模拟器访问宿主机
 *   - `https://relay.example.com:8443/dev-8f2a`  云中继(带设备号前缀)
 */
/** 上传附件的返回体 */
export interface UploadResponse {
  ok?: boolean;
  path?: string;
  name?: string;
  size?: number;
  mime?: string;
}

export interface BridgeEndpoint {
  restScheme: string;
  wsScheme: string;
  host: string;
  port: number;
  /** 是否显式写了端口 */
  hasPort: boolean;
  /** 路径前缀, 例如 `/dev-8f2a`; 没有则是空串 */
  pathPrefix: string;
  /** 原始输入 */
  raw: string;
  /**
   * 账号 id。
   *
   * 云中继的账号作用域地址是 `<中继>/<accountId>/<deviceId>`, 第一段以 `acc-` 开头时
   * 它就是账号 id; 局域网的直连地址没有这一段。
   */
  accountId: string;
  /** 设备号(账号作用域地址的第二段) */
  deviceId: string;
}

/**
 * 解析桌面端地址。
 *
 * 规则:
 * 1. 不写协议时默认 `http://`;
 * 2. `http`/`ws` 走明文, `https`/`wss` 走 TLS, 两两对应;
 * 3. 端口省略时按协议取默认(80 / 443);
 * 4. 路径部分原样保留, 作为 API 与 WebSocket 的共同前缀。
 */
export function parseEndpoint(input: string): BridgeEndpoint {
  const raw: string = input.trim();
  let rest: string = raw;
  let scheme: string = 'http';
  const schemeAt: number = raw.indexOf('://');
  if (schemeAt > 0) {
    scheme = raw.substring(0, schemeAt).toLowerCase();
    rest = raw.substring(schemeAt + 3);
  }
  let restScheme: string = 'http';
  let wsScheme: string = 'ws';
  if (scheme === 'https' || scheme === 'wss') {
    restScheme = 'https';
    wsScheme = 'wss';
  }

  // 拆出路径前缀
  let pathPrefix: string = '';
  const slashAt: number = rest.indexOf('/');
  if (slashAt >= 0) {
    pathPrefix = rest.substring(slashAt);
    rest = rest.substring(0, slashAt);
    while (pathPrefix.length > 1 && pathPrefix.endsWith('/')) {
      pathPrefix = pathPrefix.substring(0, pathPrefix.length - 1);
    }
    if (pathPrefix === '/') {
      pathPrefix = '';
    }
  }

  // 拆出 host / port
  let host: string = rest;
  let port: number = restScheme === 'https' ? 443 : 80;
  let hasPort: boolean = false;
  const colonAt: number = rest.lastIndexOf(':');
  if (colonAt > 0 && rest.indexOf(']') < colonAt) {
    const portText: string = rest.substring(colonAt + 1);
    const parsed: number = Number.parseInt(portText, 10);
    if (portText.length > 0 && !Number.isNaN(parsed)) {
      host = rest.substring(0, colonAt);
      port = parsed;
      hasPort = true;
    }
  }
  if (host.length === 0) {
    host = '127.0.0.1';
  }

  // 账号作用域: <中继>/<accountId>/<deviceId>
  let accountId: string = '';
  let deviceId: string = '';
  if (pathPrefix.length > 1) {
    const segments: string[] = pathPrefix.substring(1).split('/');
    if (segments.length >= 2 && segments[0].startsWith('acc-')) {
      accountId = segments[0];
      deviceId = segments[1];
    }
  }

  return {
    restScheme: restScheme,
    wsScheme: wsScheme,
    host: host,
    port: port,
    hasPort: hasPort,
    pathPrefix: pathPrefix,
    raw: raw,
    accountId: accountId,
    deviceId: deviceId
  };
}

/**
 * 从回答的头里取一个值。
 *
 * ArkTS 里 `HttpResponse.header` 的类型是 Object, 不能直接下标取; 先转成字符串再解析成
 * Record<string, string> 就干净了(头都是字符串)。
 *
 * **头的名字是不区分大小写的**(RFC 7230)⇒ 必须做一次不区分大小写的查找 ✓
 *
 * 踩过的坑: 桥接那边用的头名是小写 `x-dsh-seal`, 手机这边写的是 `X-Dsh-Seal` ⇒
 * 按原样去查永远查不到 ⇒ **密封的回答根本没解开** ⇒ 手上剩下一坨 base64 信封,
 * 拿去 JSON.parse 就成了「Unexpected Text in JSON: Invalid Token」✗
 * —— 看起来像网络抖动, 其实是查头名查错了 ⇒ 这就是那个报错的真正原因 ✓
 */
function responseHeader(response: http.HttpResponse, name: string): string {
  const text: string = JSON.stringify(response.header);
  if (text.length === 0) {
    return '';
  }
  const parsed: Record<string, string> = JSON.parse(text) as Record<string, string>;
  const direct: string | undefined = parsed[name];
  if (direct !== undefined) {
    return direct;
  }
  const wanted: string = name.toLowerCase();
  const keys: string[] = Object.keys(parsed);
  for (const key of keys) {
    if (key.toLowerCase() === wanted) {
      return parsed[key];
    }
  }
  return '';
}

/**
 * 密封请求连续失败几次之后,就把整条密封通道关掉。
 *
 * 一次失败不能说明整条通道坏了 —— 桌面端把**密文回答放在响应头**里,回答一大就装不下
 * (nginx 的响应头上限是 8k,node 的客户端是 16k)⇒ 那种失败只跟**那个地址**有关,
 * 不该把别的地址也一起拖下水 ⇒ 连续失败才关 ✓。
 */
const SEAL_FAILURES_LIMIT: number = 3;

/**
 * 同一个地址连着密封失败几次之后, 这个地址就不再用密封了。
 *
 * 为什么是「按地址」而不是整条通道: 会话树那种大回答装不进响应头 ⇒ 每次刷新都失败,
 * 但别的地址(待办数量、推送 token)照样走得通密封 ⇒ 别因为一个地址把整条通道关掉 ✓
 *
 * 取 2: 一次失败可能是网络抖动, 连着两次才是真的装不下 ⇒ 宁可多试一次, 也别误伤 ✓
 */
const SEAL_PATH_FAILURES_LIMIT: number = 2;

/**
 * 掉线之后「先不改状态」的缓冲期(毫秒)。
 *
 * **为什么要有这个缓冲期**: 走隧道/中继的时候, 线路上的盒子每隔 20~30 秒就把空闲连接
 * 掐断一次, 而重连只要 3 秒 ⇒ 用户其实什么都没感觉到, 但状态灯每分钟闪一次
 * 「未连接 / 重连中」看着像坏了 —— 这正是用户报的那个抖动。
 * 缓冲期内状态灯保持不动, 重连上了就当什么都没发生 ⇒ 状态灯不闪 ✓
 *
 * **为什么是 8 秒**: 比重连间隔(3 秒)宽裕, 覆盖得到"重连退避重试"这一轮;
 * 又短到"真的连不上了"时用户很快就能看见「重连中…」, 不会以为一切正常 ✓
 */
const RECONNECT_GRACE_MS: number = 8000;

/**
 * WebSocket 错误分了哪几类。
 *
 * 分类不是为了好看, 是为了让用户知道**要不要紧、该做什么**:
 * - `auth`:      令牌不对 ⇒ 重连多少次都没用 ⇒ 得重新配对
 * - `network`:   网不通 ⇒ 看一眼 WiFi / 移动数据
 * - `tls`:       证书对不上 ⇒ 线路上的盒子换了证书
 * - `transient`: 瞬时抖动 ⇒ 自动重连, 不影响正在进行的对话
 */
type WsErrorKind = 'auth' | 'network' | 'tls' | 'transient';

/**
 * 这段文字里有没有中文。
 *
 * 用来判断"是不是已经解释过了" —— `ErrorText.explain()` 命中规则时会补上中文说明,
 * 没命中时可能原样返回英文 ⇒ 这里再兜一层, 保证**每一条给用户看的错误都有中文** ✓
 *
 * (名字叫 `containsChinese` 而不是 `hasChinese`, 免得跟 `Http.ets` 里那个重名 ✓)
 */
function containsChinese(text: string): boolean {
  return /[\u4e00-\u9fa5]/u.test(text ?? '');
}

/**
 * 看一段原始错误文字, 判断它是哪一类。
 *
 * **判别顺序有讲究**: 认证、证书、网络这三类先判, 因为它们的处置完全相反
 * (重新配对 / 换证书 / 看 WiFi) ⇒ 放前面才不会被后面宽泛的规则抢走 ✓
 */
function classifyWsError(raw: string): WsErrorKind {
  const text: string = (raw ?? '').toLowerCase();
  if (text.length === 0) {
    return 'transient';
  }
  // ---- 密封通道的"Invalid Token"不是认证问题(那是丢包解不开), 别归错类 ✓
  if (text.indexOf('invalid token') >= 0) {
    return 'transient';
  }
  // ---- 认证: 令牌不对, 重连没用, 得重新配对 ----
  // **强特征先判**(401/403/unauthorized/forbidden/auth)—— 它们不会有歧义 ✓
  if (text.indexOf('401') >= 0
    || text.indexOf('403') >= 0
    || text.indexOf('unauthorized') >= 0
    || text.indexOf('forbidden') >= 0
    || text.indexOf('auth') >= 0
    || text.indexOf('配对') >= 0) {
    return 'auth';
  }
  // ---- URL 里带令牌(ws://host/ws?token=xxx)那只是地址的一部分, 不是认证失败 ✓
  const tokenInUrl: boolean = text.indexOf('?token=') >= 0 || text.indexOf('&token=') >= 0;
  // ---- 弱特征: 光一个"token"字样 ⇒ 也算认证问题
  // (桥接的提示原文就是 "the first frame has to carry the token" ✓)
  if (!tokenInUrl && (text.indexOf('token') >= 0 || text.indexOf('permission') >= 0)) {
    return 'auth';
  }
  // ---- 证书 / 加密通道 ----
  if (text.indexOf('cert') >= 0
    || text.indexOf('ssl') >= 0
    || text.indexOf('tls') >= 0
    || text.indexOf('handshake') >= 0
    || text.indexOf('证书') >= 0) {
    return 'tls';
  }
  // ---- 网络不通 / 域名解析不了 / 对方不接 ----
  if (text.indexOf('network') >= 0
    || text.indexOf('unreachable') >= 0
    || text.indexOf('resolve') >= 0
    || text.indexOf('dns') >= 0
    || text.indexOf('refused') >= 0
    || text.indexOf('econnrefused') >= 0
    || text.indexOf('enotfound') >= 0
    || text.indexOf('enetunreach') >= 0
    || text.indexOf('ehostunreach') >= 0
    || text.indexOf('offline') >= 0) {
    return 'network';
  }
  // ---- 剩下的都当瞬时抖动: 连接被掐断 / 超时 / 心跳没回应 ----
  return 'transient';
}

/**
 * 每一类错误该怎么跟用户说。
 *
 * **一定要说清楚"是什么错、要不要紧"** —— 用户抱怨的就是"没有说明是什么错误"✓
 */
function wsErrorAdvice(kind: WsErrorKind): string {
  if (kind === 'auth') {
    return '令牌不对, 需要重新配对; 这种错不会自动重连, 重配一次就好';
  }
  if (kind === 'network') {
    return '网络不通, 检查一下 WiFi 或者移动数据';
  }
  if (kind === 'tls') {
    return '加密通道校验没通过, 可能是中间盒子换了证书, 重新配对一次就好';
  }
  return '实时连接断了, 正在自动重连, 不影响正在进行的对话';
}

/**
 * 把一段 WebSocket 错误原文变成「原文(中文说明)」✓
 *
 * - 原文保留 ⇒ 用户截图给我们的时候还能搜到原文 ✓
 * - 中文说明**必带** ⇒ 绝不会出现「WebSocket 错误: 」后面什么都没有的情况 ✓
 *
 * **中文说明自己判, 不靠 `ErrorText.explain()`**: 那张表是通用关键词表,
 * 分不出 WebSocket 的"认证失败"和"网络不通"—— 而这两类的处置完全相反
 * (一个要重新配对, 一个要看 WiFi) ⇒ 说错了比不说还糟 ✓
 * (表里那条 `WebSocket → 实时连接断了` 的宽泛规则尤其会掩盖真正的错误 ✓)
 */
function explainWsError(raw: string): string {
  const detail: string = (raw ?? '').trim();
  if (detail.length === 0) {
    // 系统有时只给一个空消息 ⇒ 自己写清楚是什么事, 别让用户看着一个空白的错误 ✓
    return wsErrorAdvice('transient');
  }
  return `${detail}(${wsErrorAdvice(classifyWsError(detail))})`;
}

/**
 * 桌面端/中继主动发来的错误 ⇒ 也要有中文说明 ✓
 *
 * `explain()` 命中规则时会自己补中文; 万一没命中(那张表以后还会加新规则),
 * 这里再兜一层, 保证用户看到的每一条错误都有中文 ✓
 */
function describePeerError(raw: string): string {
  const detail: string = (raw ?? '').trim();
  if (detail.length === 0) {
    return '桌面端返回了未知错误(看电脑上的日志)';
  }
  const explained: string = explain(detail);
  if (containsChinese(explained)) {
    return explained;
  }
  return `${detail}(桌面端报的错误, 看电脑上的日志)`;
}

export class BridgeClient {
  private endpoint: BridgeEndpoint = parseEndpoint('127.0.0.1:8787');
  private token: string = '';
  private socket: webSocket.WebSocket | null = null;
  private listeners: BridgeListener[] = [];
  private connected: boolean = false;
  /**
   * 正在重连吗。
   *
   * 走隧道的时候, 线路上的盒子每隔一两分钟就会把空闲连接掐断一次, 于是手机会短暂地
   * "断开→重连"。这时候界面如果直接写「未连接」, 用户会以为坏了 —— 其实它正在自己接上
   * ⇒ 用「重连中」把这段过渡期说出来 ✓
   */
  private reconnecting: boolean = false;
  /**
   * 掉线后的「缓冲期」定时器(-1 = 没有在等)。
   *
   * 走隧道的时候, 线路上的盒子每隔 20~30 秒就把空闲连接掐断一次, 而重连只要 3 秒。
   * 用户其实什么都没感觉到, 但状态灯每分钟闪一次看着像坏了 ⇒
   * 缓冲期里状态灯保持不动, 重连上了就当什么都没发生 ✓
   */
  private graceTimer: number = -1;
  /**
   * 这一轮故障里已经报过的瞬时错误。
   *
   * 连上了就清空 ⇒ 下一轮故障还能再报一次 ✓ (所以只压"同一轮"的重复, 不压真的新问题)
   */
  private reportedTransient: string = '';
  /**
   * 缓冲期里先压着、还没告诉用户的瞬时错误。
   *
   * 缓冲期内连接自己好了 ⇒ 这条错误就没意思了(用户什么都没感觉到)⇒ 悄悄丢掉 ✓
   * 缓冲期过了还没好 ⇒ 才弹出来 ✓
   */
  private pendingTransient: string = '';
  private reconnectTimer: number = -1;
  private heartbeatTimer: number = -1;
  /** 心跳: 上一次 ping 还没等到 pong */
  private heartbeatPending: boolean = false;
  /** 连续几次心跳没有回应 */
  private heartbeatMisses: number = 0;
  private subscriptions: Set<string> = new Set<string>();
  /** 本机在账号里的设备号 */
  private deviceId: string = '';
  /** 本机在账号里的设备令牌 */
  private deviceToken: string = '';
  /** 本机在账号里的显示名 */
  private phoneName: string = '我的手机';
  /** 是否已经登记过一次 */
  private phoneRegistered: boolean = false;
  /** 在线状态心跳 */
  private presenceTimer: number = -1;

  /** 设置桌面端地址(可以是完整 URL) */
  setEndpoint(endpoint: string, token: string): void {
    const next: BridgeEndpoint = parseEndpoint(endpoint);
    const changed: boolean = next.raw !== this.endpoint.raw;
    this.endpoint = next;
    this.token = token.trim();
    // 换了地址或令牌就重新来一遍: 首帧认证的状态和失败标记都要清掉 ✓
    this.wsAuthenticated = false;
    this.authFailed = false;
    // 地址变了就掐掉旧连接: 否则 connect() 会因为 socket 还活着而直接返回,
    // 手机上会表现为"配对成功但一直未连接"(连的还是旧地址)。
    if (changed) {
      this.disconnect();
    }
  }

  /** 兼容旧的 (host, port) 调用 */
  setEndpointByHost(host: string, port: number, token: string): void {
    this.setEndpoint(`${host}:${port}`, token);
  }

  getEndpoint(): BridgeEndpoint {
    return this.endpoint;
  }

  getEndpointHost(): string {
    return this.endpoint.host;
  }

  getEndpointPort(): number {
    return this.endpoint.port;
  }

  /**
   * 给用户看的地址。
   *
   * 局域网地址原样显示(用户要一眼看出自己连的是哪台电脑, 它不是秘密) ✓
   * 远端/中继地址打码 —— 里面带着账号号/设备号, 不该出现在屏幕上 ✓
   */
  getEndpointLabel(): string {
    if (this.endpoint.pathPrefix.length > 0) {
      return maskEndpoint(this.endpoint.raw);
    }
    return this.endpoint.raw;
  }

  getToken(): string {
    return this.token;
  }

  isConnected(): boolean {
    return this.connected;
  }

  /** 正在自动重连吗(界面拿它显示「重连中…」)。 */
  isReconnecting(): boolean {
    return this.reconnecting;
  }

  /**
   * 连接状态的说法: 「已连接」/「重连中…」/「未连接」✓
   *
   * 界面直接用这一句, 三种状态就不会各写各的、说法还不一样 ✓
   *
   * **「重连中…」不是「未连接」**: 隧道掐连接是常事, 重连只要几秒,
   * 这段时间里数据链路(REST)是通的 ⇒ 对话照样能看 ⇒ 别拿「未连接」吓人 ✓
   */
  connectionLabel(): string {
    if (this.connected) {
      return '已连接';
    }
    if (this.reconnecting) {
      // 刚掉线、还在缓冲期里 ⇒ 还按「连着」显示, 免得状态灯闪一下 ✓
      if (this.graceTimer !== -1) {
        return '已连接';
      }
      return '重连中…';
    }
    return '未连接';
  }

  /**
   * 连接状态的一句话说明(给状态灯旁边那行小字用)✓
   *
   * 用户抱怨的是"状态一直跳, 以为坏了" ⇒ 光给一个「重连中…」他也不知道要不要紧 ⇒
   * 这里明确说一声: **对话数据照常加载, 不影响看进度** ✓
   */
  connectionHint(): string {
    const label: string = this.connectionLabel();
    if (label === '已连接') {
      return '实时消息会自己过来, 对话数据照常加载。';
    }
    if (label === '重连中…') {
      return '实时通道正在重连, 对话数据照常加载, 不影响看进度。';
    }
    return '还没连上电脑, 连上之后对话数据才能加载。';
  }

  get baseUrl(): string {
    const e: BridgeEndpoint = this.endpoint;
    const portPart: string = e.hasPort ? `:${e.port}` : '';
    return `${e.restScheme}://${e.host}${portPart}${e.pathPrefix}`;
  }

  get wsUrl(): string {
    // 中继的 WebSocket 路径跟 REST 不一样, 所以桥接会直接把地址给我们 ✓
    // 没给的话才自己拼(局域网直连的情况 ✓)✓
    if (this.wsUrlOverride.length > 0) {
      return this.wsUrlOverride;
    }
    const e: BridgeEndpoint = this.endpoint;
    const portPart: string = e.hasPort ? `:${e.port}` : '';
    // 令牌不在 query 里(query 会进中继/服务器的访问日志), 首帧认证的时候再发 ✓
    return `${e.wsScheme}://${e.host}${portPart}${e.pathPrefix}/ws`;
  }

  /**
   * 指定 WebSocket 地址(中继给的那个 ✓)。
   *
   * 传空串就是回到「按 REST 地址自己拼」的模式(局域网直连 ✓)✓
   */
  setWsUrl(url: string): void {
    const next: string = url.trim();
    if (next === this.wsUrlOverride) {
      return;
    }
    this.wsUrlOverride = next;
    // 换地址就要换连接: 先把旧的关掉, 新的连上时重新认证 ✓
    this.disconnect();
  }

  /**
   * 握手时带的 Sec-WebSocket-Protocol。
   *
   * **不带了** —— 以前远程模式下会带 `dsh-device.<令牌>`,
   * 但**桥接那边不一定回显子协议**(老版本就不回显 ✗),
   * 而严格的客户端在「客户端提了、服务端没回」时直接判握手失败(close 1006)⇒
   * 远程根本连不上 ✓
   *
   * 令牌改由**首帧**送过去(`{"type":"auth","token":...}` ✓ 桥接认这个 ✓),
   * 中继那边也不靠子协议鉴权(它认的是路径 ✓)⇒ 不带也一样通 ✓
   */
  private wsProtocol(): string {
    return '';
  }

  /** 账号 id(云中继的账号作用域地址才有)。 */
  getAccountId(): string {
    return this.endpoint.accountId;
  }

  /** 中继本身的根地址(去掉账号/设备路径前缀)。 */
  getRelayRoot(): string {
    const e: BridgeEndpoint = this.endpoint;
    const portPart: string = e.hasPort ? `:${e.port}` : '';
    return `${e.restScheme}://${e.host}${portPart}`;
  }

  /**
   * 把自己登记成账号下的一台手机设备。
   *
   * 手机不直接问中继: 手机与桌面之间是字节管道, 中继自己的回答会和桌面的回答混在同一条
   * 连接上。手机问 bridge, bridge 用自己的账号令牌去问中继。
   */
  async registerPhone(deviceId: string, deviceToken: string, name: string): Promise<string> {
    const body: string = JSON.stringify({ deviceId: deviceId, name: name, token: deviceToken });
    const result = await this.call(http.RequestMethod.POST, '/api/v1/phone/register', body);
    return result.body;
  }

  /** 续一次心跳, 让中继知道这台手机还在线。 */
  async phoneHeartbeat(deviceId: string): Promise<void> {
    const body: string = JSON.stringify({ deviceId: deviceId });
    await this.call(http.RequestMethod.POST, '/api/v1/phone/heartbeat', body);
  }

  /**
   * 把华为推送 token 报给桥接服务。
   *
   * 桥接服务收到之后, 桌面端有"待办"时就能推一条通知给这台手机。
   */
  async registerPushToken(token: string): Promise<void> {
    const body: string = JSON.stringify({ token: token });
    await this.call(http.RequestMethod.POST, '/api/v1/phone/push-token', body);
  }

  /**
   * 桌面端的待办数量(右上角角标)。
   *
   * 口径 = 正在跑的会话数 + 队列里排队未执行的任务数 + 待确认的问题数。
   */
  async getPendingCount(): Promise<number> {
    const result = await this.call(http.RequestMethod.GET, '/api/v1/pending');
    const parsed = JSON.parse(result.body) as PendingCountResponse;
    if (parsed.count === undefined || parsed.count === null) {
      return 0;
    }
    return parsed.count;
  }

  addListener(listener: BridgeListener): void {
    this.listeners.push(listener);
  }

  removeListener(listener: BridgeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  private emitError(message: string): void {
    this.listeners.forEach((l: BridgeListener) => l.onBridgeError(message));
  }

  /**
   * 报一条**已经拼好的**瞬时错误(缓冲期里先压着)✓
   *
   * 心跳没回应这种"自己会好"的错, 不用立刻弹红条 ⇒ 用户什么都感觉不到才是最好的 ✓
   */
  private reportTransientMessage(message: string): void {
    if (this.reportedTransient === message) {
      return;
    }
    if (this.graceTimer !== -1) {
      this.pendingTransient = message;
      return;
    }
    this.reportedTransient = message;
    this.emitError(message);
  }

  /**
   * 报一条 WebSocket 错误 ✓
   *
   * **瞬时错误要等一等再报**: 隧道掐连接是常事, 而重连只要 3 秒 ⇒
   * 现在就弹红条 ⇒ 每隔二十几秒闪一次, 那又变成"闪烁"了, 还是干扰 ✓
   * ⇒ 缓冲期里先压着, 等到缓冲期过了还没连上, 才告诉用户 ✓
   *
   * **同一轮故障里只报一次**: 重连每 3 秒试一次, 不去重的话红条反复出现 ✓
   * (认证 / 网络 / 证书这三类要用户动手, 每次都报 ✓)
   */
  private reportWsError(raw: string, prefix: string): void {
    const detail: string = (raw ?? '').trim();
    const key: string = explainWsError(detail);
    const kind: WsErrorKind = detail.length > 0 ? classifyWsError(detail) : 'transient';
    const message: string = `${prefix}${key}`;
    if (kind === 'transient') {
      if (this.reportedTransient === message) {
        // 同一轮故障里已经报过了 ⇒ 只记日志, 不再打扰界面 ✓
        hilog.warn(DOMAIN, TAG, '%{public}s', message);
        return;
      }
      if (this.graceTimer !== -1) {
        // **还在缓冲期里** ⇒ 先压着, 缓冲期过了还没好再说 ✓
        this.pendingTransient = message;
        return;
      }
      this.reportedTransient = message;
    }
    this.emitError(message);
  }

  /**
   * 改连接状态 —— **一次改完再通知界面** ✓
   *
   * **为什么不能分两次改**: 先 `reconnecting = true` 再 `setConnected(false)` 那种写法,
   * 中间会有一瞬间是「没连上、也没在重连」⇒ 界面拿到的就是「未连接」⇒ 闪一下 ⇒
   * 用户以为坏了。**这正是用户报的那个抖动的根因** ✓
   *
   * 一次改完 ⇒ 界面只看到「已连接 → 重连中…」, 不会经过「未连接」✓
   */
  private applyConnectionState(connected: boolean, reconnecting: boolean): void {
    const wasConnected: boolean = this.connected;
    const wasReconnecting: boolean = this.reconnecting;
    const changed: boolean = wasConnected !== connected || wasReconnecting !== reconnecting;
    this.connected = connected;
    this.reconnecting = reconnecting;
    if (reconnecting && !wasReconnecting && wasConnected) {
      // **刚掉线**(之前是连着的)⇒ 开缓冲期, 这几秒状态灯保持不动 ✓
      this.startGrace();
    } else if (!reconnecting) {
      // 连上了 / 明确断了 ⇒ 缓冲期结束
      this.clearGrace();
    }
    if (changed) {
      this.notifyState();
    }
  }

  /**
   * 缓冲期: 刚掉线的那几秒, 状态灯先别动 ✓
   *
   * 缓冲期内界面继续显示「已连接」, 重连上了就当什么都没发生(一个字都不改)✓
   */
  private startGrace(): void {
    if (this.graceTimer !== -1) {
      return;
    }
    this.graceTimer = setTimeout(() => {
      this.graceTimer = -1;
      // 缓冲期过了还是没连上 ⇒ 这时候才让界面知道:「重连中…」✓
      this.notifyState();
      // 缓冲期里压着的瞬时错误, 现在也该告诉用户了 ✓
      const pending: string = this.pendingTransient;
      this.pendingTransient = '';
      if (pending.length > 0) {
        this.reportedTransient = pending;
        this.emitError(pending);
      }
    }, RECONNECT_GRACE_MS);
  }

  /** 缓冲期结束(连上了, 或者明确断了)。 */
  private clearGrace(): void {
    if (this.graceTimer !== -1) {
      clearTimeout(this.graceTimer);
      this.graceTimer = -1;
    }
    // 连上了 ⇒ 这次掉线自己好了 ⇒ 压着的瞬时错误没意义了, 悄悄丢掉 ✓
    this.pendingTransient = '';
  }

  // ---------------------------------------------------------------- 端到端加密

  /** 本机自己的封签钥匙(桥接是无状态的,每次启动换一把也行)。 */
  private sealKey: Uint8Array | null = null;
  /** 密封这条路解不开(协议对不上或者桥接不支持)→ 之后一直走明文。 */
  private sealBroken: boolean = false;
  /** 密封请求连续失败了几次(连续失败才说明整条通道坏了)。 */
  private sealFailures: number = 0;
  /** 这些地址的密封回答桌面端装不下(它把密文放在响应头里)→ 这些地址直接走明文。 */
  private sealPlainPaths: Set<string> = new Set<string>();
  /** 每个地址密封失败了几次(连着几次就说明那个地址的密封回答装不下)。 */
  private sealPathFailures: Map<string, number> = new Map<string, number>();
  /** WebSocket 首帧认证过了吗(认证之前不算连上)。 */
  private wsAuthenticated: boolean = false;
  /** 首帧认证没过 → 不自动重连, 等用户重新配对。 */
  private authFailed: boolean = false;
  /** 中继给的 WebSocket 地址(空 = 按 REST 地址自己拼 ✓)。 */
  private wsUrlOverride: string = '';

  /** 能不能密封: 要有桥接令牌和本机的设备号。 */
  private canSeal(): boolean {
    return this.token.length > 0 && this.deviceId.length > 0;
  }

  /** 账号号: 地址的路径前缀里带着(直连没有就是空串)。 */
  private accountId(): string {
    return this.endpoint.accountId;
  }

  /** 拿到(没有就生成一把)封签钥匙。 */
  private async getSealKey(): Promise<Uint8Array> {
    if (this.sealKey === null) {
      this.sealKey = await newSealKey();
    }
    return this.sealKey;
  }

  /**
   * 走密封通道发一次请求。
   *
   * 令牌和请求体都在信封里, 中继看不到; 头里只有密文、时间戳、盐和包起来的封签钥匙。
   */
  private async sealedCall(method: http.RequestMethod, path: string, body?: string,
    timeout: number = 0): Promise<HttpResult> {
    const accountId: string = this.accountId();
    const deviceId: string = this.deviceId;
    const sealKey: Uint8Array = await this.getSealKey();
    const wrapKey: Uint8Array = await deriveWrapKey(this.token, accountId, deviceId);
    const wrapped: string = await wrapSealKey(wrapKey, sealKey, accountId, deviceId);
    const timestamp: number = Date.now();
    const empty: Record<string, Object> = {};
    const inner: Object = body === undefined || body.length === 0 ? empty : JSON.parse(body) as Object;
    const payload: string = JSON.stringify({ token: this.token, body: inner });
    const methodText: string = method;
    // AAD 里的 path 只用 pathname: 桥接那边用的是 url.pathname(不带 query)✓
    const sealPath: string = path.split('?')[0];
    const seal: string = await sealRequestBody(sealKey, payload, methodText, sealPath, timestamp);

    const client = http.createHttp();
    const effective: number = timeout > 0 ? timeout : 15000;
    const header: Record<string, string> = {
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'application/json'
    };
    // 密封相关的头是运行时算出来的, 逐个加(对象字面量里不能写计算属性名)。
    header[SEAL_HEADER] = seal;
    header[SEAL_TIMESTAMP_HEADER] = `${timestamp}`;
    header[SEAL_ID_HEADER] = `${accountId}:${deviceId}`;
    header[SEAL_KEY_HEADER] = wrapped;
    const options: http.HttpRequestOptions = {
      method: method,
      header: header,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: effective,
      readTimeout: effective,
      usingCache: false,
      // 按字节发出去: 字符串是按字符算长度的, 中文字符三个字节, 长度对不上,
      // 服务器读到半截请求就回一个空的 400。
      extraData: util.TextEncoder.create('utf-8').encodeInto(seal).buffer
    };
    try {
      const response = await client.request(`${this.baseUrl}${path}`, options);
      // 留一条日志:证明这次走的是密封通道,头里没有明文令牌。
      hilog.info(DOMAIN, TAG, 'sealed %{public}s %{public}s -> %{public}d (no Authorization header)',
        methodText, path, response.responseCode);
      let text: string = '';
      if (typeof response.result === 'string') {
        text = response.result;
      } else if (response.result instanceof ArrayBuffer) {
        text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(response.result));
      }
      // 密封过的回答要解开; 出错的时候桌桥回的是明文, 原样留着。
      const answerSeal: string = responseHeader(response, SEAL_HEADER);
      if (answerSeal.length > 0) {
        const answerTs: number = Number.parseInt(responseHeader(response, SEAL_TIMESTAMP_HEADER), 10);
        text = await unsealResponseBody(sealKey, answerSeal, methodText, sealPath, answerTs);
      } else if (response.responseCode < 400 && text.length > 0) {
        // 成功的密封回答**一定**带着密封头 ⇒ 现在没有 ⇒ 手上这坨是信封本身, 不是 JSON ⇒
        // 抛出去, 让上层改走明文 ✓
        // (不抛的话, 上面那坨 base64 会一路走到 JSON.parse ⇒ 「Unexpected Text in JSON」✗)
        throw new Error('密封回答没解开, 这次改走明文');
      }
      return { code: response.responseCode, body: text };
    } catch (e) {
      const err = e as BusinessError;
      // 错误消息/堆栈里可能夹着 URL(带 query 令牌) ⇒ 洗一遍再记 ✓
      // **把是哪个地址记上** —— 不然日志里只有一句没头没尾的 "Internal error",
      // 根本看不出是哪条请求出的问题 ⇒ 排查时等于没有 ✓
      hilog.error(DOMAIN, TAG, 'sealed call failed: %{public}s %{public}s (code %{public}d): %{public}s | %{public}s',
        methodText, sealPath, err.code ?? -1,
        scrubSecrets(err.message ?? ''), scrubSecrets(err.stack ?? ''));
      // 原始英文后面补一句中文说明, 用户才看得懂这是什么错 ✓
      throw new Error(`请求失败: ${explain(scrubSecrets(err.message ?? ''))}`);
    } finally {
      client.destroy();
    }
  }

  // ---------------------------------------------------------------- REST

  /**
   * 把一次失败的 HTTP 回答变成**一句人话**。
   *
   * 以前这里直接甩 `HTTP 401: {"error":{"code":"unauthorized","message":"a valid bearer
   * token is required"}}` —— 一坨英文 JSON, 用户完全看不懂 ✗
   * 现在:
   * - 明文通道的 body 已经被 `requestJson` 换成了中文 ⇒ 直接用 ✓
   * - 密封通道的 body 还是原始信封 ⇒ 抠出对方给的中文说明 ✓
   * - 都没有 ⇒ 用状态码自己的说法 ✓
   *
   * 状态码由调用方拼在前面(`HTTP 401: ...`)⇒ 排查时还能搜到原文 ✓
   */
  private httpErrorText(code: number, body: string): string {
    const text: string = (body ?? '').trim();
    if (text.length > 0 && hasChinese(text)) {
      return text;
    }
    const detail: string = errorDetail(text);
    if (detail.length > 0) {
      return detail;
    }
    return explainHttpCode(code);
  }

  private async call(method: http.RequestMethod, path: string, body?: string,
    timeout: number = 0): Promise<HttpResult> {
    // 有令牌和设备号就走密封通道: 中继只能看见密文, 令牌也不在明文头里。
    // 密封是增强, 不是前提: 密封这条路出任何错, 就自动用明文再试一次, App 立刻能用。
    if (!this.sealBroken && this.canSeal() && !this.sealPlainPaths.has(path)) {
      let reason: string = '';
      try {
        const sealed: HttpResult = await this.sealedCall(method, path, body, timeout);
        this.sealFailures = 0;
        this.sealPathFailures.delete(path);
        if (sealed.code >= 400) {
          throw new Error(`HTTP ${sealed.code}: ${this.httpErrorText(sealed.code, sealed.body)}`);
        }
        return sealed;
      } catch (error) {
        const err = error as Error;
        reason = err.message ?? 'unknown';
        this.sealFailures += 1;
        // **按地址记失败次数**: 同一个地址连着失败几次, 就别再用密封了 ✓
        //
        // 为什么要按地址记: 桌面端把**密文回答放在响应头**里, 回答一大就装不下
        // (会话树那种几百 KB 的回答装不下 ⇒ HarmonyOS 直接把整个请求判成
        // `Internal error`(code 2300999), 压根不把回答交给我们)⇒
        // 这种失败只跟**那个地址**有关, 别的地址还走密封 ⇒ 别把整条通道关掉 ✓
        const pathFailures: number = (this.sealPathFailures.get(path) ?? 0) + 1;
        this.sealPathFailures.set(path, pathFailures);
        if (reason.startsWith('HTTP 502') || reason.startsWith('HTTP 504')
          || pathFailures >= SEAL_PATH_FAILURES_LIMIT) {
          // 这个地址的密封回答桌面端装不下(它把密文放在响应头里), 这个地址走明文 ✓
          this.sealPlainPaths.add(path);
          hilog.warn(DOMAIN, TAG,
            '这个地址的密封回答桌面端装不下(它把密文放在响应头里), 这个地址走明文: %{public}s',
            path);
        } else {
          hilog.warn(DOMAIN, TAG, '密封请求失败, 这次改走明文: %{public}s | %{public}s',
            reason, err.stack ?? '');
        }
      }
      const plain: HttpResult = await requestJson(method, `${this.baseUrl}${path}`, this.token, body,
        timeout > 0 ? timeout : 0);
      if (plain.code >= 400) {
        throw new Error(`HTTP ${plain.code}: ${this.httpErrorText(plain.code, plain.body)}`);
      }
      // 连续失败才说明整条密封通道解不开(协议对不上) ⇒ 之后一直走明文 ✓
      if (this.sealFailures >= SEAL_FAILURES_LIMIT) {
        this.sealBroken = true;
        hilog.warn(DOMAIN, TAG, '密封通道连续失败 %{public}d 次, 之后走明文', this.sealFailures);
      }
      return plain;
    }
    const result = await requestJson(method, `${this.baseUrl}${path}`, this.token, body,
      timeout > 0 ? timeout : 0);
    if (result.code >= 400) {
      // 回答里可能带着服务器回显的令牌 ⇒ 洗一遍再往外抛 ✓
      throw new Error(`HTTP ${result.code}: ${this.httpErrorText(result.code, scrubSecrets(result.body))}`);
    }
    return result;
  }

  /**
   * 上传附件(图片 / 文件 / 录音): 原始字节直传, 不走 base64。
   *
   * 桥接把文件写到电脑上, 返回绝对路径 —— 调用方把路径 `@` 进 prompt 即可。
   * 注意: 目前只有局域网直连支持上传; 远程(云中继)模式会收到 501, 提示用户切回局域网。
   */
  async uploadAttachment(name: string, mime: string, data: ArrayBuffer): Promise<string> {
    const client = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(`${this.baseUrl}/api/v1/upload`, {
        method: http.RequestMethod.POST,
        header: {
          'Authorization': `Bearer ${this.token}`,
          'Content-Type': 'application/octet-stream',
          'x-file-name': encodeURIComponent(name),
          'x-file-type': mime
        },
        extraData: data,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 120000
      });
      if (response.responseCode !== 200) {
        throw new Error(explainHttpCode(response.responseCode));
      }
      const parsed = JSON.parse(String(response.result)) as UploadResponse;
      if (parsed.path === undefined || parsed.path === null || parsed.path.length === 0) {
        throw new Error('上传失败: 服务端没有返回文件路径');
      }
      return parsed.path;
    } finally {
      client.destroy();
    }
  }

  /** 健康检查 */
  async health(): Promise<HealthInfo> {
    const result = await this.call(http.RequestMethod.GET, '/api/v1/health');
    const parsed = JSON.parse(result.body) as HealthInfo;
    return parsed;
  }

  /** 会话列表 */
  async listSessions(): Promise<SessionSummary[]> {
    const result = await this.call(http.RequestMethod.GET, '/api/v1/sessions');
    const parsed = JSON.parse(result.body) as SessionListResponse;
    if (parsed.sessions === undefined || parsed.sessions === null) {
      return [];
    }
    return parsed.sessions;
  }

  /**
   * 会话树(桌面端侧边栏的那种两级结构)。
   *
   * 一级是「对话」, 它的「话题/子任务」在 topics 里 —— 桥接那边还没上线这个端点时
   * 会直接抛错, 由调用方退回平铺列表。
   */
  async getSessionTree(): Promise<ConversationNode[]> {
    // 冷启动时桌面端要几十秒才把会话列出来, 这里给一个宽的超时(桥接有缓存, 第二次就快了)。
    const result = await this.call(http.RequestMethod.GET, '/api/v1/session-tree', undefined, 90000);
    const parsed = JSON.parse(result.body) as SessionTreeResponse;
    if (parsed === undefined || parsed === null || parsed.conversations === undefined
      || parsed.conversations === null) {
      return [];
    }
    const list: ConversationNode[] = parsed.conversations;
    for (let i = 0; i < list.length; i++) {
      if (list[i].topics === undefined || list[i].topics === null) {
        list[i].topics = [];
      }
    }
    return list;
  }

  /** 某个会话的消息历史 */
  async listMessages(sessionId: string, limit: number = 200): Promise<BridgeMessage[]> {
    // 会话越长, 桌面端解析越慢, 这里给一个比默认更宽的超时
    const result = await this.call(http.RequestMethod.GET,
      `/api/v1/sessions/${encodeURIComponent(sessionId)}/messages?limit=${limit}`, undefined, 60000);
    const parsed = JSON.parse(result.body) as MessageListResponse;
    if (parsed.messages === undefined || parsed.messages === null) {
      return [];
    }
    return parsed.messages;
  }

  /**
   * 取一条消息的全文。
   *
   * 列表里只给预览(truncated ✓), 全文要走这个接口 ✓
   */
  async fullMessage(sessionId: string, seq: number): Promise<string> {
    const result = await this.call(http.RequestMethod.GET,
      `/api/v1/sessions/${encodeURIComponent(sessionId)}/messages/${seq}/full`, undefined, 20000);
    if (result.code !== 200) {
      throw new Error(`HTTP ${result.code}`);
    }
    const parsed = JSON.parse(result.body) as FullMessageResponse;
    return parsed.text ?? '';
  }

  /**
   * 桌面端当前在等用户回答的问题(ask_user_question 的投影)。
   *
   * 没有问题时返回空数组; 桌面端老版本没有这个端点时也返回空。
   */
  async getQuestions(sessionId: string): Promise<AskCall[]> {
    try {
      const result = await this.call(http.RequestMethod.GET,
        `/api/v1/sessions/${encodeURIComponent(sessionId)}/questions`);
      const parsed = JSON.parse(result.body) as AskQuestionsResponse;
      if (parsed === undefined || parsed === null || parsed.questions === undefined
        || parsed.questions === null) {
        return [];
      }
      return parsed.questions;
    } catch (e) {
      return [];
    }
  }

  /** 把选择结果提交给桌面端(桌面端会把它作为一条用户消息交给 agent) */
  async answerQuestions(sessionId: string, callId: string, answers: AskAnswer[]): Promise<void> {
    const payload: AskAnswerPayload = { callId: callId, answers: answers };
    await this.call(http.RequestMethod.POST,
      `/api/v1/sessions/${encodeURIComponent(sessionId)}/questions`, JSON.stringify(payload));
  }

  /** 桌面端正在等批准的请求(内核审批, 谁先答谁生效)。 */
  async getApprovals(): Promise<ApprovalRequest[]> {
    try {
      const result = await this.call(http.RequestMethod.GET, '/api/v1/approvals');
      const parsed = JSON.parse(result.body) as ApprovalsResponse;
      if (parsed === undefined || parsed === null || parsed.approvals === undefined
        || parsed.approvals === null) {
        return [];
      }
      return parsed.approvals;
    } catch (e) {
      return [];
    }
  }

  /**
   * 回答一条桌面审批。
   *
   * outcome: 'allowed-once' | 'rejected'
   * 如果电脑已经先答了, 桥接会回 409/400 ⇒ 抛错, 界面提示「已由电脑处理」。
   */
  async answerApproval(eventId: string, outcome: string): Promise<void> {
    const payload = JSON.stringify({ outcome: outcome });
    await this.call(http.RequestMethod.POST,
      `/api/v1/approvals/${encodeURIComponent(eventId)}`, payload);
  }

  /**
   * 回答「桌面弹出来的 ask 选项卡片」(ABCD)。
   *
   * 走的还是同一个事件通道(user-questions/request waterfall), 只是回的是 answers。
   */
  async answerInteractionQuestion(eventId: string, answers: AskAnswer[]): Promise<void> {
    const payload = JSON.stringify({ answers: answers });
    await this.call(http.RequestMethod.POST,
      `/api/v1/approvals/${encodeURIComponent(eventId)}`, payload);
  }

  /** 会话详情 */
  async getSession(sessionId: string): Promise<SessionSummary> {
    const result = await this.call(http.RequestMethod.GET, `/api/v1/sessions/${encodeURIComponent(sessionId)}`);
    const parsed = JSON.parse(result.body) as SessionResponse;
    return parsed.session;
  }

  /**
   * 会话用量数据(桌面端状态条的那些数字)。
   * 这个端点是可选的, 拿不到时返回空串, 不抛异常。
   */
  async sessionStats(sessionId: string): Promise<string> {
    try {
      const result = await this.call(http.RequestMethod.GET,
        `/api/v1/sessions/${encodeURIComponent(sessionId)}/stats`);
      return result.body;
    } catch (e) {
      return '';
    }
  }

  /** 账号下的设备列表(桌面端 + 其它手机), 拿不到时返回空数组 */
  async listDevices(): Promise<DeviceInfo[]> {
    try {
      const result = await this.call(http.RequestMethod.GET, '/api/v1/devices');
      // 设备列表只记条数 —— 回答里可能有账号/设备号, 不整段往外倒 ✓
      hilog.info(DOMAIN, TAG, 'listDevices -> %{public}d 字节', result.body.length);
      const parsed = JSON.parse(result.body) as DeviceListResponse;
      if (parsed.devices === undefined || parsed.devices === null) {
        hilog.warn(DOMAIN, TAG, 'listDevices -> the response has no devices field');
        return [];
      }
      return parsed.devices;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'listDevices 失败: %{public}s', err.message ?? 'unknown');
      return [];
    }
  }

  /**
   * 新建会话。
   *
   * `agentPreset` 是桌面端的「模式」, `permission` 是权限预设;
   * 都留空就不带这两个字段, 老桥接也能用。
   */
  async createSession(cwd: string, title: string, agentPreset: string = '',
    permission: string = ''): Promise<SessionSummary> {
    const payload: CreateSessionPayload = { cwd: cwd, title: title };
    if (agentPreset.length > 0) {
      payload.agentPreset = agentPreset;
    }
    if (permission.length > 0) {
      payload.permission = permission;
    }
    const result = await this.call(http.RequestMethod.POST, '/api/v1/sessions', JSON.stringify(payload));
    const parsed = JSON.parse(result.body) as SessionResponse;
    return parsed.session;
  }

  /** 提交一条指令, 让桌面端执行 */
  async submitPrompt(sessionId: string, text: string, mode: string = 'queue'): Promise<SubmitResponse> {
    const payload: SubmitPromptPayload = { text: text, mode: mode };
    const result = await this.call(http.RequestMethod.POST,
      `/api/v1/sessions/${encodeURIComponent(sessionId)}/messages`, JSON.stringify(payload));
    return JSON.parse(result.body) as SubmitResponse;  }

  /**
   * 危险动作预判: 这条指令要不要在手机上再确认一次。
   *
   * 桥接那边知道会话的权限和 DSH 的工具名, 能把「这一条要做成什么」翻译成人话。
   * 只有会话权限是 danger-full-access 且命中危险模式(执行命令/写删文件/改配置)才会
   * 返回 `requiresConfirmation: true`; read-only 和 workspace-write 一律 false。
   *
   * 这个接口还不一定上线(或者临时挂了), 所以调用方要能兜底: 拿不到就直接发。
   */
  async getPromptPreview(sessionId: string, text: string): Promise<PromptPreview> {
    const result = await this.call(http.RequestMethod.GET,
      `/api/v1/sessions/${encodeURIComponent(sessionId)}/prompt-preview?text=${encodeURIComponent(text)}`);
    return JSON.parse(result.body) as PromptPreview;
  }

  /* ------------------------------------------------------------- 模型与权限 */

  /** 模型目录(桌面端模型选择器里的那些) */
  async getModels(): Promise<ModelCatalogResponse> {
    const result = await this.call(http.RequestMethod.GET, '/api/v1/models');
    const parsed = JSON.parse(result.body) as ModelCatalogResponse;
    if (parsed.providers === undefined || parsed.providers === null) {
      parsed.providers = [];
    }
    return parsed;
  }

  /** 给当前会话换一个模型 */
  async selectModel(sessionId: string, provider: string, model: string,
    reasoningEffort: string): Promise<void> {
    const payload: SelectModelPayload = {
      provider: provider,
      model: model,
      reasoningEffort: reasoningEffort
    };
    await this.call(http.RequestMethod.POST,
      `/api/v1/sessions/${encodeURIComponent(sessionId)}/model`, JSON.stringify(payload));
  }

  /** 权限预设(只读列表; 要改还是得去桌面端) */
  async getPermissionOptions(): Promise<PermissionOption[]> {
    const result = await this.call(http.RequestMethod.GET, '/api/v1/permissions');
    // 桌面端给的是 { options: [...], defaultPreset }
    const parsed = JSON.parse(result.body) as PermissionOptionsResponse;
    if (parsed === undefined || parsed === null || parsed.options === undefined) {
      return [];
    }
    return parsed.options;
  }

  /** 权限预设目录(带默认项; 新建会话时要用) */
  async getPermissionCatalog(): Promise<PermissionOptionsResponse> {
    const result = await this.call(http.RequestMethod.GET, '/api/v1/permissions');
    const parsed = JSON.parse(result.body) as PermissionOptionsResponse;
    if (parsed === undefined || parsed === null) {
      return { options: [], defaultPreset: '' };
    }
    if (parsed.options === undefined || parsed.options === null) {
      parsed.options = [];
    }
    return parsed;
  }

  /**
   * 模式清单(桌面端新建任务时的「模式」)。
   *
   * 桥接还没上线这个端点时返回空数组, 由调用方显示「默认」。
   */
  async getAgentPresets(): Promise<AgentPreset[]> {
    try {
      const result = await this.call(http.RequestMethod.GET, '/api/v1/agent-presets');
      const parsed = JSON.parse(result.body) as AgentPresetsResponse;
      if (parsed === undefined || parsed === null || parsed.presets === undefined
        || parsed.presets === null) {
        return [];
      }
      return parsed.presets;
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'getAgentPresets 失败: %{public}s', err.message ?? 'unknown');
      return [];
    }
  }

  /** 会话当前的状态: 模型、权限、是否在跑 */
  async getSessionState(sessionId: string): Promise<SessionStateData> {
    const result = await this.call(http.RequestMethod.GET,
      `/api/v1/sessions/${encodeURIComponent(sessionId)}/state`);
    return JSON.parse(result.body) as SessionStateData;
  }

  /* ------------------------------------------------------------- 队列与指令 */

  /** 队列中排队的任务 */
  async getQueue(sessionId: string): Promise<QueueResponse> {
    const result = await this.call(http.RequestMethod.GET,
      `/api/v1/sessions/${encodeURIComponent(sessionId)}/queue`);
    const parsed = JSON.parse(result.body) as QueueResponse;
    if (parsed.nextTurn === undefined || parsed.nextTurn === null) {
      parsed.nextTurn = [];
    }
    if (parsed.nextStep === undefined || parsed.nextStep === null) {
      parsed.nextStep = [];
    }
    // 桌面端不给条目的时间 ⇒ 补成 0(未知) ✓ 不然排序里会算出 NaN ⇒ 顺序乱掉 ✗
    parsed.nextTurn = this.withQueueTime(parsed.nextTurn);
    parsed.nextStep = this.withQueueTime(parsed.nextStep);
    return parsed;
  }

  /** 给队列条目补上 at 字段(桌面端没给的话就是 0 = 未知 ✓) */
  private withQueueTime(items: QueueItem[]): QueueItem[] {
    const out: QueueItem[] = [];
    for (const item of items) {
      const at: number = typeof item.at === 'number' && Number.isFinite(item.at) ? item.at : 0;
      out.push({ id: item.id, text: item.text, target: item.target, at: at });
    }
    return out;
  }

  /**
   * 改一条排队中的任务。
   * action: 'edit' | 'remove' | 'steer'
   */
  async updateQueueItem(sessionId: string, itemId: string, action: string,
    text: string = ''): Promise<void> {
    let payload: QueueActionPayload;
    if (action === 'edit') {
      const part: QueueContentPart = { type: 'text', text: text };
      payload = { itemId: itemId, action: { kind: 'edit', content: [part] } };
    } else if (action === 'steer') {
      payload = { itemId: itemId, action: { kind: 'steer' } };
    } else {
      payload = { itemId: itemId, action: { kind: 'remove' } };
    }
    await this.call(http.RequestMethod.POST,
      `/api/v1/sessions/${encodeURIComponent(sessionId)}/queue`, JSON.stringify(payload));
  }

  /** 斜杠命令(桌面端的"调用指令") */
  async listCommands(sessionId: string): Promise<CommandInfo[]> {
    const result = await this.call(http.RequestMethod.GET,
      `/api/v1/sessions/${encodeURIComponent(sessionId)}/commands`);
    // 桌面端给的是 { commands: [...] } —— 直接当数组解, 列表就永远是空的 ✓
    const parsed = JSON.parse(result.body) as CommandsResponse;
    if (parsed === undefined || parsed === null || parsed.commands === undefined) {
      return [];
    }
    return parsed.commands;
  }

  /** 技能(可以当成 /name 调用) */
  async listSkills(sessionId: string): Promise<SkillInfo[]> {
    // 桌面端列技能要扫一遍所有技能包, 冷启动时可能好几秒, 这里给得宽松一点
    const result = await this.call(http.RequestMethod.GET,
      `/api/v1/sessions/${encodeURIComponent(sessionId)}/skills`, undefined, 60000);
    // 桌面端给的是 { skills: [...] } ✓
    const parsed = JSON.parse(result.body) as SkillsResponse;
    if (parsed === undefined || parsed === null || parsed.skills === undefined) {
      return [];
    }
    return parsed.skills;
  }

  /** @ 补全的文件候选 */
  async listFiles(sessionId: string, query: string): Promise<FileRefInfo[]> {
    const result = await this.call(http.RequestMethod.GET,
      `/api/v1/sessions/${encodeURIComponent(sessionId)}/files?query=${encodeURIComponent(query)}`);
    // 桌面端给的是 { files: [...] } ✓
    const parsed = JSON.parse(result.body) as FilesResponse;
    if (parsed === undefined || parsed === null || parsed.files === undefined) {
      return [];
    }
    return parsed.files;
  }

  /**
   * 跑一条斜杠指令(桌面端的「/」面板走的就是这条路)。
   *
   * **不是**把 "/plan" 当提示词发出去 —— 桌面端是把整行交给桌面的指令登记表,
   * 由它去解析名字、跑处理函数(`/permission <preset>` 换权限、`/plan` 进计划模式…),
   * 当成提示词发出去只会变成模型看到的一行字。
   */
  async executeCommand(sessionId: string, line: string): Promise<CommandResultResponse> {
    const payload: CommandPayload = { line: line };
    const result = await this.call(http.RequestMethod.POST,
      `/api/v1/sessions/${encodeURIComponent(sessionId)}/command`, JSON.stringify(payload));
    const parsed = JSON.parse(result.body) as CommandResultResponse;
    return parsed;
  }

  /** 取消当前正在执行的任务 */
  async cancel(sessionId: string): Promise<void> {
    await this.call(http.RequestMethod.POST, `/api/v1/sessions/${encodeURIComponent(sessionId)}/cancel`, '{}');
  }

  /** 工作区列表 */
  async listWorkspaces(): Promise<WorkspaceEntry[]> {
    const result = await this.call(http.RequestMethod.GET, '/api/v1/workspaces');
    const parsed = JSON.parse(result.body) as WorkspaceListResponse;
    if (parsed.workspaces === undefined || parsed.workspaces === null) {
      return [];
    }
    return parsed.workspaces;
  }

  // ----------------------------------------------------------- WebSocket

  /** 建立实时连接 */
  connect(): void {
    if (this.socket !== null) {
      return;
    }
    // 令牌不对的时候不自动重连: 等用户重新配对 ✓
    if (this.authFailed) {
      return;
    }
    const ws = webSocket.createWebSocket();
    this.socket = ws;
    ws.on('open', () => {
      // 第一帧只能是认证: 认证通过之前什么都不发 ✓
      this.sendAuthFrame();
    });
    ws.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
      if (err !== undefined && err !== null) {
        return;
      }
      let text: string = '';
      if (typeof data === 'string') {
        text = data;
      } else if (data instanceof ArrayBuffer) {
        text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(data));
      }
      this.handleFrame(text);
    });
    ws.on('close', () => {
      this.socket = null;
      this.stopHeartbeat();
      if (this.authFailed) {
        // 令牌不对: 不自动重连, 等用户重新配对 ✓
        this.applyConnectionState(false, false);
        hilog.warn(DOMAIN, TAG, 'WebSocket 已关闭(认证没过, 不再自动重连)');
        return;
      }
      // 一次把状态改完 ⇒ 界面直接显示「重连中…」, 不会闪一下「未连接」✓
      this.applyConnectionState(false, true);
      this.scheduleReconnect();
    });
    ws.on('error', (err: BusinessError) => {
      this.socket = null;
      this.stopHeartbeat();
      if (this.authFailed) {
        this.applyConnectionState(false, false);
        // **一定要说清楚是什么错**: 用户抱怨的就是"没有说明是什么错误"——
        // 光甩一句干巴巴的「WebSocket 错误: 」谁也看不懂 ⇒ 按类别给一句人话 ✓
        // (原文照样留着, 用户截图给我们的时候还能搜到 ✓)
        this.reportWsError(err?.message ?? '', 'WebSocket 错误: ');
        return;
      }
      // 先把状态改完(缓冲期也就起来了), 再决定这条错误要不要现在报 ✓
      this.applyConnectionState(false, true);
      this.scheduleReconnect();
      this.reportWsError(err?.message ?? '', 'WebSocket 错误: ');
    });
    // 中继认 Sec-WebSocket-Protocol: dsh-device.<令牌> ✓; 局域网直连不带 ✓
    // 系统层的 WebSocket 心跳: 空闲连接会被中间的盒子掐掉。
    // 走 CDN/隧道时, 链路上的盒子大约 20~30 秒就把"没动静"的连接掐了, 25 秒的心跳刚好
    // 踩在边上 —— 表现为手机每隔一两分钟就重连一次。10 秒一次, 线路上的盒子永远看不到
    // 一条空闲的连接 ✓ (应用层的 ping 帧是第二道保险)
    const options: webSocket.WebSocketRequestOptions = {
      protocol: this.wsProtocol(),
      pingInterval: 10000,
      pongTimeout: 25000
    };
    ws.connect(this.wsUrl, options, (err: BusinessError, value: boolean) => {
      if (err !== undefined && err !== null) {
        this.socket = null;
        // 先改状态(缓冲期起来了), 再决定这条错误要不要现在报 ✓
        this.applyConnectionState(false, true);
        this.scheduleReconnect();
        // 连不上 ⇒ 也要说清楚是"网络不通"还是"证书不对"还是"令牌不对" ✓
        this.reportWsError(err.message ?? '', '无法连接桌面端代理服务: ');
      }
    });
  }

  /**
   * 主动断开这条连接。
   *
   * 心跳连续没有回应时用: 桌面端的进程可能已经没了, 但没来得及发 RST, 这条连接就成了
   * 半开状态。这里主动关掉它, 关掉之后走的是和"对端断开"一样的路径(标记未连接 + 重连) ✓
   */
  private dropConnection(): void {
    const socket = this.socket;
    this.socket = null;
    this.stopHeartbeat();
    if (socket !== null) {
      try {
        socket.close();
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(DOMAIN, TAG, '关闭连接失败: %{public}s', err.message ?? '');
      }
    }
    // 一次改完 ⇒ 界面看到的是「重连中…」, 不会先闪一下「未连接」✓
    this.applyConnectionState(false, true);
    this.scheduleReconnect();
  }

  /**
   * 掉线后自动重连。
   *
   * 桌面端重启、中继重连、WiFi 抖动都会让连接断掉, 没有重连的话手机上会一直停在「未连接」。
   */
  private scheduleReconnect(): void {
    // 先把状态改成「正在重连」再排队重连 —— 界面才知道这段时间不是「未连接」✓
    // (状态是一次改完的, 界面不会闪一下「未连接」✓)
    this.applyConnectionState(false, true);
    if (this.reconnectTimer !== -1) {
      return;
    }
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      if (this.socket === null) {
        this.connect();
      }
    }, 3000);
  }

  /** 告诉界面"连接状态变了"(重连中也要说, 不然界面不会重画)。 */
  private notifyState(): void {
    const label: string = this.connectionLabel();
    this.listeners.forEach((l: BridgeListener) => {
      l.onConnectionChanged(this.connected);
      // 三态的说法也给出去 ⇒ 界面照抄就行, 不用自己拼「已连接/未连接」✓
      l.onConnectionLabel(label, this.connected);
    });
  }

  /** 断开实时连接 */
  disconnect(): void {
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.stopHeartbeat();
    if (this.presenceTimer !== -1) {
      clearInterval(this.presenceTimer);
      this.presenceTimer = -1;
    }
    this.phoneRegistered = false;
    if (this.socket !== null) {
      try {
        this.socket.close();
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(DOMAIN, TAG, '关闭连接失败: %{public}s', err.message ?? '');
      }
      this.socket = null;
    }
    // 明确断开了 ⇒ 缓冲期结束, 状态回到「未连接」✓
    this.applyConnectionState(false, false);
  }

  /**
   * 订阅某个会话的实时事件。
   *
   * bridge 只把「订阅过」的会话的增量推给手机, 不订阅就只会收到列表级的全局事件,
   * 会话页会一直停在「执行中」而看不到桌面端的回复。
   */
  subscribeSession(sessionId: string): void {
    if (sessionId.length === 0) {
      return;
    }
    this.subscriptions.add(sessionId);
    const data: WsFrameData = { sessionIds: [sessionId] };
    this.sendFrame('subscribe', data);
  }

  /** 取消订阅 */
  unsubscribeSession(sessionId: string): void {
    this.subscriptions.delete(sessionId);
    const data: WsFrameData = { sessionIds: [] };
    this.sendFrame('subscribe', data);
  }

  /**
   * 心跳: 让 bridge 知道手机还在。
   *
   * 空闲的 WebSocket 会被中间的盒子(Cloudflare 之类)当成死连接掐掉, 所以每隔 25 秒
   * ping 一次, 对方回 pong。
   *
   * 连续两次没有回应 ⇒ 这条连接已经是半开状态了(桌面端进程没了但没来得及发 RST),
   * 这时候主动断开并重连 —— 比等对端把我们掐掉快得多。
   */
  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      this.heartbeatTick();
    }, 10000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
    this.heartbeatPending = false;
    this.heartbeatMisses = 0;
  }

  private heartbeatTick(): void {
    if (this.socket === null) {
      return;
    }
    if (this.heartbeatPending) {
      // 上一次 ping 的 pong 没回来。
      this.heartbeatMisses += 1;
      this.heartbeatPending = false;
      if (this.heartbeatMisses >= 2) {
        hilog.warn(DOMAIN, TAG, '连续 %{public}d 次心跳没有回应, 断开重连', this.heartbeatMisses);
        // 先断连接(缓冲期就起来了)再报 ⇒ 这条瞬时错误会被压着, 不立刻弹红条 ✓
        // 说清楚"要不要紧": 实时通道断了, 但对话数据照常加载 ⇒ 用户不用慌 ✓
        this.dropConnection();
        this.reportTransientMessage('桌面端没有回应, 实时连接断了, 正在自动重连, 不影响正在进行的对话');
        return;
      }
    }
    const data: WsFrameData = {};
    this.sendFrame('ping', data);
    this.heartbeatPending = true;
  }

  /**
   * 这台手机在账号里的身份。
   *
   * 手机自己生成设备号与设备令牌(存在应用私有目录里), 通过 bridge 登记到账号下 ——
   * 所以手机里**不需要**账号令牌, 只需要桌面端那一个访问令牌。
   */
  setAccount(deviceId: string, deviceToken: string, phoneName: string): void {
    this.deviceId = deviceId;
    this.deviceToken = deviceToken;
    this.phoneName = phoneName;
    this.phoneRegistered = false;
  }

  /** 登记自己, 然后按 30 秒一次的节奏续心跳。 */
  private ensurePhonePresence(): void {
    if (this.deviceId.length === 0 || this.deviceToken.length === 0) {
      return;
    }
    if (this.endpoint.accountId.length === 0) {
      // 不是账号作用域的地址(局域网直连), 没有账号可登记
      return;
    }
    void this.reportPresence();
    if (this.presenceTimer !== -1) {
      clearInterval(this.presenceTimer);
    }
    this.presenceTimer = setInterval(() => {
      void this.reportPresence();
    }, 30000);
  }

  private async reportPresence(): Promise<void> {
    try {
      if (this.phoneRegistered) {
        await this.phoneHeartbeat(this.deviceId);
      } else {
        await this.registerPhone(this.deviceId, this.deviceToken, this.phoneName);
        this.phoneRegistered = true;
      }
    } catch (e) {
      const err = e as BusinessError;
      // 中继暂时不可达不影响主流程, 下一次心跳会再试
      hilog.warn(DOMAIN, TAG, '登记手机设备失败: %{public}s', err.message ?? '');
    }
  }

  /**
   * 发首帧认证。
   *
   * 新协议: 握手不带令牌, 第一帧必须是 `{ "type": "auth", "token": "…" }` ✓
   * 桥接认证通过之后才会发 hello ✓ —— 所以认证之前不能发别的帧 ✓
   */
  private sendAuthFrame(): void {
    if (this.socket === null) {
      return;
    }
    const frame: AuthFrame = { type: 'auth', token: this.token };
    try {
      this.socket.send(JSON.stringify(frame));
      hilog.info(DOMAIN, TAG, 'WebSocket 首帧认证已发出');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, '发送认证帧失败: %{public}s', err.message ?? '');
    }
  }

  /** 认证通过之后才做的事: 订阅、心跳、登记在线 ✓ */
  private afterAuth(): void {
    this.wsAuthenticated = true;
    // 连上了 ⇒ 缓冲期结束, 状态灯回到「已连接」✓
    this.applyConnectionState(true, false);
    // 连上了 ⇒ 这一轮故障结束 ⇒ 下次再断还能重新报一次瞬时错误 ✓
    this.reportedTransient = '';
    this.subscriptions.forEach((id: string) => {
      const data: WsFrameData = { sessionIds: [id] };
      this.sendFrame('subscribe', data);
    });
    this.startHeartbeat();
    // 把自己登记成账号下的手机设备, 桌面端就能看到"我的手机 在线"
    this.ensurePhonePresence();
  }

  /**
   * 首帧认证没过: 令牌不对, 要重新配对 ✓
   *
   * 不自动重连 —— 重连多少次都是一样的结果, 只会刷日志。
   */
  private onAuthFailed(text: string): void {
    let message: string = '桌面端拒绝了认证';
    try {
      const errFrame: ErrorFrame = JSON.parse(text) as ErrorFrame;
      message = errFrame.data?.message ?? message;
    } catch {
      // 不是 JSON, 用默认的说明 ✓
    }
    this.authFailed = true;
    hilog.error(DOMAIN, TAG, 'WebSocket 首帧认证失败: %{public}s', message);
    // 认证失败 ⇒ 说清楚"令牌不对、要重新配对", 并且说明这种错**不会自动重连** ✓
    const detail: string = message.trim();
    this.emitError(detail.length > 0
      ? `桌面端拒绝了认证: ${detail}(令牌不对, 需要重新配对, 这种错不会自动重连)`
      : '桌面端拒绝了认证: 令牌不对, 需要重新配对, 这种错不会自动重连');
    // **令牌不行了 ⇒ 让外面自动重新配对一次**(AppState 会接这个回调 ✓)
    this.listeners.forEach((l: BridgeListener) => l.onAuthFailed());
    const socket = this.socket;
    this.socket = null;
    this.applyConnectionState(false, false);
    if (socket !== null) {
      try {
        socket.close();
      } catch {
        // 关不掉就算了, 桥接那边也会断开 ✓
      }
    }
  }

  /**
   * 拿桌桥/中继的证书指纹。
   *
   * 第一次连一个自签证书的主机时, 要把指纹弹给用户核对 ✓ —— 这个接口就是给 UI 用的 ✓
   * (还没配对的时候也能调: 没有令牌就不带 Authorization 头 ✓)
   */
  async fetchCertificate(): Promise<RelayCertificate> {
    const result = await requestJson(http.RequestMethod.GET, `${this.baseUrl}/api/v1/relay/certificate`,
      this.token, undefined, 8000);
    if (result.code >= 400) {
      throw new Error(`HTTP ${result.code}: ${scrubSecrets(result.body)}`);
    }
    return JSON.parse(result.body) as RelayCertificate;
  }

  /**
   * 核对证书指纹。
   *
   * @param expected 记住过的指纹(没有就是空串)
   * @param actual 这次拿到的指纹
   */
  static checkFingerprint(expected: string, actual: string): CertificateVerdict {
    const want: string = expected.trim().toUpperCase();
    const got: string = actual.trim().toUpperCase();
    if (want.length === 0 || got.length === 0) {
      return 'unknown';
    }
    return want === got ? 'match' : 'mismatch';
  }

  /** 发送一个客户端帧 */
  sendFrame(type: string, data: WsFrameData): void {
    if (this.socket === null) {
      return;
    }
    const frame: WsFrame = { type: type, data: data };
    try {
      this.socket.send(JSON.stringify(frame));
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, '发送帧失败: %{public}s', err.message ?? '');
    }
  }

  /** 提交指令(实时通道) */
  sendPrompt(sessionId: string, text: string, mode: string = 'queue'): void {
    const data: WsFrameData = { sessionId: sessionId, text: text, mode: mode };
    this.sendFrame('prompt', data);
  }

  /** 取消任务(实时通道) */
  sendCancel(sessionId: string): void {
    const data: WsFrameData = { sessionId: sessionId };
    this.sendFrame('cancel', data);
  }

  private handleFrame(text: string): void {
    if (text.length === 0) {
      return;
    }
    let frame: WsFrame;
    try {
      frame = JSON.parse(text) as WsFrame;
    } catch (e) {
      return;
    }
    const data = frame.data;
    if (!this.wsAuthenticated) {
      // 还没认证: 桥接只会回两种东西 —— 认证失败的 error 帧, 或者认证通过的 hello ✓
      if (frame.type === 'error') {
        this.onAuthFailed(text);
        return;
      }
      this.afterAuth();
    }
    if (data === undefined || data === null) {
      return;
    }
    switch (frame.type) {
      case 'session.list':
        if (data.sessions !== undefined) {
          this.listeners.forEach((l: BridgeListener) => l.onSessions(data.sessions as SessionSummary[]));
        }
        break;
      case 'session.state':
        this.listeners.forEach((l: BridgeListener) =>
          l.onSessionState(data.sessionId ?? '', data.state ?? '', data.title ?? ''));
        break;
      case 'pending': {
        // 待办摘要: 手机拿它弹本地通知(任务跑完了 / 有问题等着回答)。
        const pendingFrame: PendingFrame = JSON.parse(text) as PendingFrame;
        this.listeners.forEach((l: BridgeListener) => l.onPending(pendingFrame.data));
        break;
      }
      case 'message.created':
        if (data.message !== undefined) {
          this.listeners.forEach((l: BridgeListener) =>
            l.onMessageCreated(data.sessionId ?? '', data.message as BridgeMessage));
        }
        break;
      case 'message.delta':
        this.listeners.forEach((l: BridgeListener) =>
          l.onMessageDelta(data.sessionId ?? '', data.messageId ?? '', data.delta ?? ''));
        break;
      case 'message.completed':
        if (data.message !== undefined) {
          this.listeners.forEach((l: BridgeListener) =>
            l.onMessageCompleted(data.sessionId ?? '', data.message as BridgeMessage));
        }
        break;
      case 'error': {
        const errFrame = JSON.parse(text) as ErrorFrame;
        // 对端主动发来的错误 ⇒ 它的 message 也要有中文说明 ✓
        this.emitError(describePeerError(errFrame.data?.message ?? ''));
        break;
      }
      case 'pong': {
        // 心跳回应: 这条连接是活的 ✓
        this.heartbeatPending = false;
        this.heartbeatMisses = 0;
        break;
      }
      case 'ping': {
        // 桥接发来的心跳: 回一个 pong ✓ (这是控制帧, 不进正文, 也不写日志)
        const pongData: WsFrameData = {};
        this.sendFrame('pong', pongData);
        break;
      }
      case 'hello': {
        // 桥接在 hello 里把它自己的令牌也带回来了: 对不上就是配到了另一台桌面 ✓
        const hello: HelloFrame = JSON.parse(text) as HelloFrame;
        const serverToken: string = hello.data?.token ?? '';
        if (serverToken.length > 0 && serverToken !== this.token) {
          hilog.warn(DOMAIN, TAG, '桌面端的令牌和手机里的不一样, 需要重新配对');
          this.emitError('配对信息对不上, 请重新配对');
        }
        break;
      }
      default:
        break;
    }
  }
}
