/**
 * 本地通知 —— **纯本地**, 不需要 AGConnect / Push Kit / 任何云端。
 *
 * 用户要的是: 桌面端的任务跑完了, 或者需要我做决策, 手机的通知栏弹一条,
 * 点进去直接进那个对话。这条通知是 App 自己发的(`notificationManager.publish()`),
 * 所以 App 在前台、连着桥接服务的时候就能收到; App 被杀掉之后还想收到, 那是另一件事
 * (云端推送, 本文件不负责)。
 *
 * 两个"不吵"的原则:
 *   1. 同一个会话 5 分钟内只提醒一次(`shouldNotify`);
 *   2. 用户正在看的那个会话不提醒(`setCurrentSessionId`)。
 */
import { notificationManager } from '@kit.NotificationKit';
import { Want, wantAgent as newWantAgent } from '@kit.AbilityKit';
// 通知服务认的是「老」wantAgent 模块造出来的对象(@ohos.app.ability.wantAgent 那个不行,
// publish 会报 "Constructor is false"), 所以这里用 @ohos.wantAgent。
import legacyWantAgent from '@ohos.wantAgent';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF06;

/** 通知点开时带回来的参数名(EntryAbility 读的就是它)。 */
export const SESSION_PARAM: string = 'sessionId';

/** 同一个会话多久之内不重复提醒(毫秒)。 */
export const NOTIFY_COOLDOWN_MS: number = 5 * 60 * 1000;

/** 通知点开时, 多久之内还认(超过就不拉着用户跳了)。 */
export const NOTIFY_FRESH_MS: number = 30 * 60 * 1000;

/** 上一次提醒的时间(按 key 分组),用来去重。 */
const notifiedAt: Map<string, number> = new Map();

/** 用户当前正在看的会话(正在看的不提醒)。 */
let currentSessionId: string = '';

/** 从通知点进来时, 要打开的会话(还没被打开的那一个)。 */
let pendingSessionId: string = '';

/** 本 App 的包名(通知点开时系统要靠它把本 App 拉起来)。 */
let bundleName: string = '';

/** 每个会话最后一次知道的状态(用来发现「刚刚跑完」)。 */
const sessionStates: Map<string, string> = new Map();

/** 待办摘要里的一个会话。 */
export interface PendingSession {
  sessionId?: string;
  title?: string;
}

/** 待办摘要(桥接服务广播的 `pending` 帧)。 */
export interface PendingSummary {
  /** 待办总数(在跑的 + 排队的 + 待确认的) */
  count?: number;
  /** 正在跑的会话 id */
  running?: string[];
  /** 上一轮在跑、这一轮跑完的会话 */
  finished?: PendingSession[];
  /** 在等用户回答的会话 */
  questions?: PendingSession[];
  /** 排队中的任务数(桥接新版本会带; 老版本没有) */
  queued?: number;
}

/**
 * 初始化(在 EntryAbility.onCreate 里调用)。
 *
 * 通知点开时系统靠「包名 + Ability 名」把 App 拉起来, 所以这里先记住包名。
 */
export function initLocalNotify(bundle: string): void {
  // 拿不到包名就用固定的这个(通知点开时系统要靠它定位本 App 的 Ability)。
  bundleName = bundle.length > 0 ? bundle : 'com.example.dshsync';
  hilog.info(DOMAIN, TAG, '本地通知模块就绪, 包名 %{public}s', bundleName);
}

/**
 * 记下会话的新状态。
 *
 * @returns true 表示「刚刚跑完」(之前在跑, 现在跑完了) —— 这时候该弹通知。
 */
export function markSessionState(sessionId: string, state: string): boolean {
  if (sessionId.length === 0) {
    return false;
  }
  const previous: string = sessionStates.get(sessionId) ?? '';
  sessionStates.set(sessionId, state);
  return previous === 'running' && (state === 'idle' || state === 'done');
}

/** 记住还没见过的会话状态(列表刷新时用, 别把已知的覆盖掉)。 */
export function rememberSessionState(sessionId: string, state: string): void {
  if (sessionId.length === 0) return;
  if (!sessionStates.has(sessionId)) {
    sessionStates.set(sessionId, state);
  }
}

/**
 * 「任务跑完了」的本地通知。
 *
 * 用户正在看这个会话 → 不打扰他; 5 分钟内同一个会话只提醒一次。
 */
export function notifyTaskFinished(sessionId: string, title: string): void {
  if (sessionId.length === 0) return;
  if (sessionId === getCurrentSessionId()) return;
  if (!shouldNotify(`${sessionId}:done`)) return;
  notifyLocal('任务完成', title.length > 0 ? title : sessionId, sessionId);
}

/**
 * 「桌面端需要我做决策」的本地通知。
 */
export function notifyNeedsDecision(sessionId: string, title: string): void {
  if (sessionId.length === 0) return;
  if (sessionId === getCurrentSessionId()) return;
  if (!shouldNotify(`${sessionId}:question`)) return;
  notifyLocal('桌面端需要你确认', title.length > 0 ? title : sessionId, sessionId);
}

/**
 * 待办摘要变了 → 弹本地通知。
 *
 * 列表页和会话页都调它(用户在哪个页面都要能收到提醒), 去重是全局的, 不会重复弹。
 */
export function notifyPendingSummary(summary: PendingSummary): void {
  const finished: PendingSession[] = summary.finished ?? [];
  for (let i = 0; i < finished.length; i++) {
    notifyTaskFinished(finished[i].sessionId ?? '', finished[i].title ?? '');
  }
  const questions: PendingSession[] = summary.questions ?? [];
  for (let i = 0; i < questions.length; i++) {
    notifyNeedsDecision(questions[i].sessionId ?? '', questions[i].title ?? '');
  }
}

/**
 * 通知 id 由会话 id 派生。
 *
 * 同一个 id 会覆盖旧通知, 所以同一个会话不会在通知栏里堆一串。
 */
function notificationId(sessionId: string): number {
  let hash: number = 0;
  for (let index = 0; index < sessionId.length; index++) {
    hash = ((hash << 5) - hash + sessionId.charCodeAt(index)) & 0x7fffffff;
  }
  return hash === 0 ? 1 : hash;
}

/**
 * 该不该再提醒一次。
 *
 * @param key 去重的分组(例如 `session-1:done`)
 */
export function shouldNotify(key: string): boolean {
  const now: number = Date.now();
  const last: number = notifiedAt.get(key) ?? 0;
  if (now - last < NOTIFY_COOLDOWN_MS) return false;
  notifiedAt.set(key, now);
  return true;
}

/** 记住用户当前正在看的会话。 */
export function setCurrentSessionId(sessionId: string): void {
  currentSessionId = sessionId;
}

/** 用户当前正在看的会话(空串 = 没在看任何会话)。 */
export function getCurrentSessionId(): string {
  return currentSessionId;
}

/** 记下"从通知点进来要打开的会话"。 */
export function setPendingSessionId(sessionId: string): void {
  pendingSessionId = sessionId;
}

/**
 * 取走"从通知点进来要打开的会话"。
 *
 * 取走之后就没了, 所以不会重复跳转。
 */
export function takePendingSessionId(): string {
  const sessionId: string = pendingSessionId;
  pendingSessionId = '';
  return sessionId;
}

/**
 * 通知里记的会话 id。
 *
 * 格式是 `<会话 id>#<发通知的时间戳>`: 带上时间戳, App 起来时才能判断
 * 「这是刚点的通知」还是「很久以前的那条」。
 */
function messageIdOf(sessionId: string, at: number): string {
  return `${sessionId}#${at}`;
}

/**
 * 通知栏里点的那条通知, 记着是哪个会话。
 *
 * 系统的 wantAgent 在这台机器上造不出来(报 "Constructor is false"),
 * 所以换一条路: 通知里带 `appMessageId`(会话 id + 时间), App 起来时
 * 问系统「我还有哪些通知没被划掉」, 从里面找出刚才点的那条 ✓。
 *
 * @returns 会话 id(没有就是空串)
 */
export async function takeNotifiedSessionId(): Promise<string> {
  try {
    const list: notificationManager.NotificationRequest[] = await notificationManager.getActiveNotifications();
    let sessionId: string = '';
    let at: number = 0;
    let id: number = 0;
    for (let i = 0; i < list.length; i++) {
      const raw: string = list[i].appMessageId ?? '';
      const sep: number = raw.indexOf('#');
      if (sep <= 0) {
        continue;
      }
      const time: number = Number(raw.substring(sep + 1));
      if (isNaN(time)) {
        continue;
      }
      if (time > at) {
        at = time;
        sessionId = raw.substring(0, sep);
        id = list[i].id ?? 0;
      }
    }
    if (sessionId.length === 0) {
      return '';
    }
    // 太早的通知(比如半小时前的)就别拉着用户跳了。
    if (Date.now() - at > NOTIFY_FRESH_MS) {
      return '';
    }
    // 读到了就把这条通知撤掉, 免得它一直挂在通知栏里。
    try {
      await notificationManager.cancel(id);
    } catch (e) {
      // 撤不掉也没关系。
    }
    return sessionId;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, '查通知列表失败: %{public}s', err.message ?? 'unknown');
    return '';
  }
}

/**
 * 弹一条本地通知。
 *
 * 点通知会用 `sessionId` 启动 EntryAbility, 由它跳到对应的对话。
 *
 * @param title 通知标题(例如「任务完成」)
 * @param body 通知正文(会话标题)
 * @param sessionId 点通知要去的会话
 */
export async function notifyLocal(title: string, body: string, sessionId: string): Promise<void> {
  try {
    // ArkTS 的严格模式: 对象字面量必须能对上显式声明的接口, 所以先声明再赋值。
    const normal: notificationManager.NotificationBasicContent = {
      title: title,
      text: body
    };
    const content: notificationManager.NotificationContent = {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: normal
    };
    const request: notificationManager.NotificationRequest = {
      id: notificationId(sessionId),
      content: content,
      // 会话 id + 发通知的时间: App 被拉起时靠它知道「用户点的是哪条通知」。
      appMessageId: messageIdOf(sessionId, Date.now()),
      // 点过之后先不自动清掉: App 起来后读到它, 跳到那个对话, 再由 App 撤掉。
      tapDismissed: false,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION
    };
    // 点通知要能直达那个对话, 就得带上 wantAgent(系统会用它把 App 拉起来)。
    // 各系统版本认的写法不一样, 所以挨个试; 都不认就退一步: 弹一条不带跳转的通知。
    let agents: Object[] = [];
    try {
      agents = await buildWantAgents(sessionId);
    } catch (e) {
      // 有的系统版本对 want 的写法挑剔(报 "Constructor is false") ⇒ 别让整条通知黄掉,
      // 退一步发一条不带跳转的通知就好。
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, '生成通知跳转失败(改为不带跳转): %{public}s', err.message ?? '');
    }
    for (let i = 0; i < agents.length; i++) {
      const withAgent: notificationManager.NotificationRequest = {
        id: request.id,
        content: content,
        appMessageId: request.appMessageId,
        tapDismissed: false,
        wantAgent: agents[i],
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION
      };
      if (await publishQuietly(withAgent)) {
        hilog.info(DOMAIN, TAG, '本地通知: %{public}s / %{public}s (带跳转=是)', title, body);
        return;
      }
    }
    // 退一步: 不带 wantAgent 也能弹, 只是点进去不会自动跳到那个对话。
    if (await publishQuietly(request)) {
      hilog.info(DOMAIN, TAG, '本地通知: %{public}s / %{public}s (带跳转=否)', title, body);
      return;
    }
    // 再退一步: 有的系统对多余的字段挑剔, 只留内容再试一次。
    const bare: notificationManager.NotificationRequest = { content: content };
    if (await publishQuietly(bare)) {
      hilog.info(DOMAIN, TAG, '本地通知: %{public}s / %{public}s (带跳转=否, 精简)', title, body);
      return;
    }
    hilog.warn(DOMAIN, TAG, '本地通知发不出去: %{public}s', title);
  } catch (e) {
    // 通知发不出去不该让 App 崩: 没权限、模拟器不支持等等都只记一条日志。
    // **这些报错只进 hilog, 不往界面上抛** ⇒ 系统的英文报错留在日志里就行 ✓
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, '本地通知失败(code %{public}d): %{public}s', err.code ?? -1, err.message ?? 'unknown');
  }
}

/** 发一条通知; 系统不认就记一条日志并返回 false(不往上抛)。 */
async function publishQuietly(request: notificationManager.NotificationRequest): Promise<boolean> {
  try {
    await notificationManager.publish(request);
    return true;
  } catch (e) {
    // 同上: 只记日志, 不给用户看 ⇒ 英文报错不用汉化 ✓
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, '通知被系统拒了(code %{public}d): %{public}s', err.code ?? -1, err.message ?? 'unknown');
    return false;
  }
}

/**
 * 造几个候选的 wantAgent。
 *
 * 系统的通知服务对 want 的写法挑得很厉害(写法不对会报 "Constructor is false"),
 * 所以「新旧两个模块 × 两种 want 写法」挨个试, 都不行就返回空数组
 * (那样通知照样能弹, 只是点进去不会自动跳到那个对话)。
 */
async function buildWantAgents(sessionId: string): Promise<Object[]> {
  // 写法一: 包名 + Ability 名 + 参数(点开就能拿到 sessionId)。
  // 注意: Want 是类型/接口, 不是 class ⇒ 不能 `new Want()`(运行时会报
  // "Constructor is false"), 必须用字面量。
  const full: Want = {
    bundleName: bundleName,
    abilityName: 'EntryAbility',
    parameters: { sessionId: sessionId }
  };
  // 写法二: 只留包名和 Ability 名(有的系统不认 parameters)。
  const simple: Want = {
    bundleName: bundleName,
    abilityName: 'EntryAbility'
  };

  const candidates: Object[] = [];
  const modernFull: Object | null = await tryModernAgent(full);
  if (modernFull !== null) {
    candidates.push(modernFull);
  }
  const modernSimple: Object | null = await tryModernAgent(simple);
  if (modernSimple !== null) {
    candidates.push(modernSimple);
  }
  const legacyFull: Object | null = await tryLegacyAgent(full);
  if (legacyFull !== null) {
    candidates.push(legacyFull);
  }
  const legacySimple: Object | null = await tryLegacyAgent(simple);
  if (legacySimple !== null) {
    candidates.push(legacySimple);
  }
  return candidates;
}

/** 用新模块(@ohos.app.ability.wantAgent)造 wantAgent; 系统不认就返回 null。 */
async function tryModernAgent(want: Want): Promise<Object | null> {
  try {
    const agent = await newWantAgent.getWantAgent({
      wants: [want],
      requestCode: 0,
      operationType: newWantAgent.OperationType.START_ABILITY,
      wantAgentFlags: [newWantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    if (agent === null || agent === undefined) {
      return null;
    }
    return agent;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'wantAgent(新模块)造不出来: %{public}s', err.message ?? 'unknown');
    return null;
  }
}

/** 用老模块(@ohos.wantAgent)造 wantAgent; 系统不认就返回 null。 */
async function tryLegacyAgent(want: Want): Promise<Object | null> {
  try {
    const agent = await legacyWantAgent.getWantAgent({
      wants: [want],
      requestCode: 0,
      operationType: legacyWantAgent.OperationType.START_ABILITY,
      wantAgentFlags: [legacyWantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    if (agent === null || agent === undefined) {
      return null;
    }
    return agent;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'wantAgent(老模块)造不出来: %{public}s', err.message ?? 'unknown');
    return null;
  }
}
