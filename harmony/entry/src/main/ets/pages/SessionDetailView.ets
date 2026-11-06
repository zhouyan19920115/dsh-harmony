/**
 * 会话详情**组件** —— 交互模型对齐桌面端 DeepSeek Harness。
 *
 * 单栏模式: 由 pages/SessionPage.ets 以 @Entry 页面承载, 路由参数从外面传进来。
 * 双栏模式: 由 pages/SessionListPage.ets 直接嵌在右栏, 左边点列表换这里的 sessionId。
 * 两种模式共用这一份实现, 行为完全一致。
 *
 * 桌面端是"深色 + 左侧会话树 + 会话页两个视图(对话 / 轨迹)",
 * 手机端保留同样的信息层级:
 *   - 顶部: 标题 + 状态徽章 + 「对话 / 轨迹」两个视图
 *   - 对话: 用户消息是一块**浮起的圆角面板**(不是彩色气泡), 时间与复制在面板下方;
 *           助手消息先给一行**状态**, 再给正文; 工具调用单独一行弱化显示
 *   - 轨迹: 一条按角色标注的步骤时间线(助手 / 工具 / 用户)
 *   - 底部: 输入区(圆角深色面板 + 一行工具条)和桌面端一样的状态条
 *
 * 实时性: 订阅 WebSocket 推送的 message.delta / message.completed,
 * 桌面端每产生一段输出, 这里就追加一段。
 */
import { pasteboard } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { AppState } from '../common/AppState';
import { BridgeListener, PromptPreview } from '../common/BridgeClient';
import {
  AskAnswer,
  AskCall,
  AskOption,
  AskQuestion,
  ApprovalRequest,
  BridgeMessage,
  CommandInfo,
  CommandResultResponse,
  FileRefInfo,
  ModelCatalogResponse,
  ModelEffort,
  ModelEntry,
  ModelProvider,
  PickItem,
  QueueItem,
  SessionStateData,
  SessionSummary,
  SessionStatsResponse,
  SkillInfo
} from '../common/Models';
import { formatTime } from '../common/TimeFmt';
import { describeError, describeSoftly, explain } from '../common/ErrorText';
import { Palette, Space, Radius, FontSize } from '../common/Theme';
import { ThemeController } from '../common/ThemeController';
import { ReadStore } from '../common/ReadStore';
import {
  markSessionState,
  notifyPendingSummary,
  notifyTaskFinished,
  PendingSummary
} from '../common/LocalNotify';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF05;
/** 「+ 号」面板一次最多摆多少条候选(桌面上装了两百多个技能, 全铺出来会把手机撑爆) */
const MAX_PICK_ITEMS: number = 60;
/**
 * 正文折叠阈值: 超过这个字数就先只渲染预览, 点「点开更多」再展开。
 *
 * 内存里(m.text)始终是**全文**, 截断只发生在渲染层(见 visibleText ✓)
 */
const PREVIEW_LIMIT: number = 1200;

/**
 * 「需要你选择」面板摊平后的一行。
 *
 * (面板里不能嵌套多层 ForEach —— 会崩; 所以先把问题/选项摊成一条数组再 ForEach)
 */
/** 一道题的「其他」文字回答(arkTS 不支持 Record, 用数组按键查) */
interface AskCustomEntry {
  /** `callId|qid` */
  key: string;
  text: string;
}

/** 头一个问题卡的分页位置(一题一页) */
interface AskPageEntry {
  eventId: string;
  index: number;
}

interface AskRow {
  /** header | qhead | q | hint | option | custom | submit */
  kind: string;
  key: string;
  text: string;
  sub: string;
  callId: string;
  qid: string;
  label: string;
  multi: boolean;
  checked: boolean;
  enabled: boolean;
}
/** 工具输出的折叠阈值: 它本来就是 3 行的紧凑块(约 3 行 × 20 字), 比正文小得多 */
const TOOL_PREVIEW_LIMIT: number = 60;

export interface SessionRouteParams {
  sessionId: string;
  title: string;
  cwd: string;
}

/** 桥接给的消息(带截断信息 ✓) */
interface DetailMessage extends BridgeMessage {
  /** 消息序号 ✓ */
  seq?: number;
  /** 正文是不是被截断了 ✓ */
  truncated?: boolean;
  /** 全文有多长 ✓ */
  totalLength?: number;
  /** 预览有多长 ✓ */
  previewLimit?: number;
}

/** 列表项需要的展示模型 */
interface DisplayMessage {
  key: string;
  role: string;
  kind: string;
  /** 工具名(只有 tool_call 有) */
  toolName: string;
  text: string;
  time: string;
  /** 原始时间戳(毫秒): 排序只能用它, 字符串比时间是错的 ✓ */
  at: number;
  streaming: boolean;
  status: string;
  /** 消息序号(桥接给的 ✓)—— 取全文要它 ✓ */
  seq: number;
  /** 正文是不是被截断了(桥接只给预览 ✓) */
  truncated: boolean;
  /** 展开了(显示全文 ✓) */
  expanded: boolean;
  /** 正在取全文 ✓ */
  loadingFull: boolean;
  /** 取全文失败的原因 ✓ */
  fullError: string;
}

/** 桌面端状态条里的用量数据 */
interface SessionStats {
  turns: number;
  steps: number;
  outputTokens: number;
  cacheReadTokens: number;
  contextTokens: number;
  contextWindow: number;
  model: string;
  permission: string;
  agentLabel: string;
}

@Component
export struct SessionDetailView {
  /** 状态栏高度(EntryAbility 量出来写进 AppStorage; 全屏后靠它让开通知栏) */
  @StorageProp('topSafeVp') topSafeVp: number = 0;
  /** 手势条高度 */
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 0;
  /** 键盘当前高度(vp): 输入框聚焦后用对话区滚动来响应, 不靠窗口平移 */
  @StorageProp('keyboardVp') keyboardVp: number = 0;

  /** 主题版本号: ThemeController 切主题时 +1; pal() 读它 ⇒ 颜色实时重算 */
  @StorageLink('themeTick') themeTick: number = 0;

  /** 当前是不是深色(读 tick 建立依赖) */
  private isDarkNow(): boolean {
    const tick: number = this.themeTick;
    return tick < 0 ? true : Palette.isDark();
  }

  /** 取当前主题颜色: 所有 Palette.X 都改走这里, 这样切主题能实时生效 */
  private pal(key: string): string {
    // 读一下 themeTick 建立依赖: 主题一变, 用到 pal() 的颜色属性都会重新求值
    const tick: number = this.themeTick;
    if (tick < 0) {
      return Palette.BG;
    }
    if (key === 'ACCENT') { return Palette.ACCENT; }
    if (key === 'ACCENT_SOLID') { return Palette.ACCENT_SOLID; }
    if (key === 'ASSISTANT') { return Palette.ASSISTANT; }
    if (key === 'BG') { return Palette.BG; }
    if (key === 'BG_DEEP') { return Palette.BG_DEEP; }
    if (key === 'BORDER') { return Palette.BORDER; }
    if (key === 'BORDER_SOFT') { return Palette.BORDER_SOFT; }
    if (key === 'CONTEXT') { return Palette.CONTEXT; }
    if (key === 'ERROR') { return Palette.ERROR; }
    if (key === 'OK') { return Palette.OK; }
    if (key === 'PLACEHOLDER') { return Palette.PLACEHOLDER; }
    if (key === 'SURFACE') { return Palette.SURFACE; }
    if (key === 'SURFACE_HI') { return Palette.SURFACE_HI; }
    if (key === 'TEXT') { return Palette.TEXT; }
    if (key === 'TEXT_2') { return Palette.TEXT_2; }
    if (key === 'TEXT_3') { return Palette.TEXT_3; }
    if (key === 'TOOL') { return Palette.TOOL; }
    if (key === 'WARN') { return Palette.WARN; }
    return Palette.TEXT;
  }

  /** 对话区半透明底(让背景图透出来又能读字) */
  private bodyScrim(): string {
    const tick: number = this.themeTick;
    return tick < 0 ? '#B3151517' : (Palette.isDark() ? '#B3151517' : '#B3F7F8FA');
  }

  /** 当前主题的吉祥物背景图 */
  private backdropImage(): Resource {
    const tick: number = this.themeTick;
    return tick < 0 ? $r('app.media.mascot_day') : (Palette.isDark() ? $r('app.media.mascot_night') : $r('app.media.mascot_day'));
  }

  /** 背景浓度(读 tick 建立依赖) */
  private bgAlpha(): number {
    const tick: number = this.themeTick;
    return tick < 0 ? 0 : ThemeController.bgAlpha();
  }

  /** 当前会话(双栏模式下由列表页切换) */
  @Prop @Watch('onSessionChanged') sessionId: string = '';
  // 只有 sessionId 变化才重新挂载: title/cwd 和它一起变, 三个都 @Watch 会重复挂 3 次
  @Prop title: string = '';
  @Prop cwd: string = '';
  @State messages: DisplayMessage[] = [];
  @State draft: string = '';
  @State sending: boolean = false;
  @State running: boolean = false;
  @State connected: boolean = false;
  /** 连接状态的说法: 「已连接」/「重连中…」/「未连接」 */
  @State connectionText: string = '未连接';
  @State notice: string = '';
  /** 0 = 对话, 1 = 轨迹 */
  @State tab: number = 0;
  @State stats: SessionStats | null = null;
  /** 双栏模式下不显示返回箭头 */
  @Prop showBack: boolean = true;
  /** 当前实际订阅的会话 id(换会话时用来退订旧的) */
  @State private boundSessionId: string = '';

  /* --- 队列(桌面端的"排队中的对话任务框") --- */
  @State queueNextTurn: QueueItem[] = [];
  @State queueNextStep: QueueItem[] = [];
  /**
   * 手机自己发出去的每条指令 → 发送时刻 ✓
   *
   * 桌面端不把队列条目的时间给我们 ⇒ 手机自己记一份 ⇒ 队列才能按时间排 ✓
   * 键是指令原文(桌面端回给我们的队列条目也只有原文 ✓)
   */
  private sentAt: Map<string, number> = new Map();
  @State queueOpen: boolean = false;
  /** 正在编辑的队列条目 */
  @State editingId: string = '';
  @State editingText: string = '';

  /* --- 输入框左边的 + 号: 指令 / 技能 / 文件 --- */
  @State plusOpen: boolean = false;
  /** 正在上传附件(避免重复点) */
  @State uploading: boolean = false;
  @State plusTab: number = 0;
  @State commands: CommandInfo[] = [];
  @State skills: SkillInfo[] = [];
  @State files: FileRefInfo[] = [];
  @State fileQuery: string = '';
  @State plusLoading: boolean = false;
  /** 「+ 号」面板里统一的那份候选列表 */
  @State pickItems: PickItem[] = [];
  @State pickEmpty: string = '';
  /** 列表下面那行提示(比如「还有 197 个技能…」) */
  @State pickMore: string = '';

  /* --- 输入框右边的模型选择 --- */
  @State modelOpen: boolean = false;
  @State catalog: ModelCatalogResponse | null = null;
  @State modelProvider: string = '';
  @State modelName: string = '';
  @State modelEffort: string = '';
  @State stateData: SessionStateData | null = null;

  private scroller: Scroller = new Scroller();
  /** 展开了哪些消息(按 seq ✓)—— 退出会话再进来还是全文 ✓ */
  private expandedSeqs: Set<number> = new Set<number>();
  /** 取过的全文(按 seq ✓)—— 重新拉列表也不丢 ✓ */
  private fullTexts: Map<number, string> = new Map<number, string>();
  /** 还没滚到底(等列表布局好了再滚 ✓)。 */
  private pendingScroll: boolean = false;
  /** 是否已经在消息最底部(不在底部时右下角浮一个「最新」按钮) */
  @State atBottom: boolean = true;

  /* --- 桌面端在等我们回答的问题(ask_user_question) --- */
  @State askCalls: AskCall[] = [];
  /** 勾选的选项: `${callId}|${qid}|${label}` */
  @State askPicked: string[] = [];
  /** 自定义文字回答(所有题共用一份; 有选项的题也可以用) */
  @State askCustom: string = '';
  /** 每道题自己的「其他」文字回答: key = `callId|qid` */
  @State askCustoms: AskCustomEntry[] = [];
  @State askBusy: boolean = false;
  private askTimer: number = -1;
  /** 桌面端在等的内核审批(approval/request): 手机也能答, 谁先答谁生效 */
  @State approvals: ApprovalRequest[] = [];
  private approvalTimer: number = -1;
  @State approvalBusy: string = '';
  /** 桌面 ask 弹窗(ABCD)在手机上的勾选: `eventId|qid|label` */
  @State interactionPicks: string[] = [];
  /** 桌面 ask 弹窗在手机上的「其他」文字: key = `eventId|qid` */
  @State interactionCustoms: AskCustomEntry[] = [];
  /** 一题一页: 每个请求当前停在第几题 */
  @State interactionPages: AskPageEntry[] = [];
  /** 明确跳过的题: `eventId|qid` */
  @State interactionSkipped: string[] = [];

  private listener: BridgeListener = new BridgeListener();

  aboutToAppear(): void {
    this.listener.onSessions = (_list: SessionSummary[]): void => {};
    this.listener.onSessionState = (id: string, state: string, title: string): void => {
      // 刚才还在跑, 现在跑完了 → 弹一条本地通知(用户不在这个会话时才弹)。
      if (markSessionState(id, state)) {
        notifyTaskFinished(id, title);
      }
      if (id === this.sessionId) {
        this.running = state === 'running';
        // 状态一变就刷新队列: agent 跑完时排着的任务会被取走
        void this.loadQueue();
      }
    };
    // 待办摘要: 别的会话跑完了 / 在等我回答 → 通知栏弹一条。
    this.listener.onPending = (summary: PendingSummary): void => {
      notifyPendingSummary(summary);
    };
    this.listener.onMessageCreated = (sid: string, message: BridgeMessage): void => {
      if (sid !== this.sessionId) {
        return;
      }
      this.appendOrMerge(message);
    };
    this.listener.onMessageDelta = (sid: string, messageId: string, delta: string): void => {
      if (sid !== this.sessionId) {
        return;
      }
      this.mergeDelta(messageId, delta);
    };
    this.listener.onMessageCompleted = (sid: string, message: BridgeMessage): void => {
      if (sid !== this.sessionId) {
        return;
      }
      this.appendOrMerge(message);
    };
    this.listener.onBridgeError = (msg: string): void => {
      // 桌面端推过来的错误: 它那边已经解释过一遍了, 这里再兜一层底
      // (有些路径是原始字符串, 不解释就会把英文摆到界面上 ✗)
      this.notice = explain(msg);
    };
    this.listener.onConnectionChanged = (value: boolean): void => {
      this.connected = value;
    };
    // 连接状态要说三种: 「已连接」/「重连中…」/「未连接」✓
    // 原来只有「已连接」两个字, 掉线重连期间这一行整个是空的 ⇒ 用户只看到它一会儿有、
    // 一会儿没有, 以为坏了 ⇒ 现在把过渡期也说出来 ✓
    this.listener.onConnectionLabel = (label: string, connected: boolean): void => {
      this.connectionText = label;
      this.connected = connected;
    };
    this.connectionText = AppState.client.connectionLabel();
    AppState.client.addListener(this.listener);
    this.attachSession();
    // 桌面端有 ask_user_question 在等回答时, 定期拉一次(漏掉推送也能补上)
    this.askTimer = setInterval(() => {
      void this.loadQuestions();
    }, 8000);
    // 内核审批来得快、留得短(桌面那边随时可能先答掉), 所以单独一路 3 秒轮询。
    void this.loadApprovals();
    this.approvalTimer = setInterval(() => {
      void this.loadApprovals();
    }, 3000);
  }

  /**
   * 订阅当前会话并把界面拉起来。
   * 双栏模式下换了会话时也走这里。
   */
  private attachSession(): void {
    if (this.sessionId.length === 0) {
      return;
    }
    this.boundSessionId = this.sessionId;
    // 必须先订阅, bridge 才会把这个会话的增量推给手机
    AppState.client.subscribeSession(this.sessionId);
    this.loadHistory();
    this.loadStats();
    this.loadQueue();
    void this.loadQuestions();
    void this.loadApprovals();
    void this.loadModelName();
    AppState.client.connect();
  }

  /**
   * 外部换了会话(双栏模式下点左边的列表)时重新挂载。
   */
  onSessionChanged(): void {
    if (this.sessionId.length === 0) {
      return;
    }
    if (this.boundSessionId.length > 0 && this.boundSessionId !== this.sessionId) {
      AppState.client.unsubscribeSession(this.boundSessionId);
      this.messages = [];
      this.notice = '';
      // 这两张表是按 seq 存的: 不清的话, 新会话里同序号的消息会显示上一个会话的全文 ✗
      this.fullTexts.clear();
      this.expandedSeqs.clear();
    }
    this.attachSession();
  }

  aboutToDisappear(): void {
    if (this.approvalTimer >= 0) {
      clearInterval(this.approvalTimer);
      this.approvalTimer = -1;
    }
    if (this.askTimer >= 0) {
      clearInterval(this.askTimer);
      this.askTimer = -1;
    }
    // 离开会话: 再标一次已读(看的过程中桌面端又写了新内容, 也不该算未读)
    if (this.sessionId.length > 0) {
      ReadStore.markRead(this.sessionId);
    }
    AppState.client.removeListener(this.listener);
    if (this.boundSessionId.length > 0) {
      AppState.client.unsubscribeSession(this.boundSessionId);
      this.boundSessionId = '';
    }
  }

  private async loadHistory(): Promise<void> {
    try {
      const list = await AppState.client.listMessages(this.sessionId, 50);
      this.messages = [];
      this.mergeMessages(list);
      // 消息加载出来就算「用户看过了」: 列表上的琥珀点和右上角待处理数会减掉这一条
      ReadStore.markRead(this.sessionId);
      this.scrollToEnd(true);
    } catch (e) {
      const err = e as Error;
      // 这里用 describeSoftly 而不是 describeError:
      // 密封通道偶尔会因为丢包解不开(表现是 `Unexpected Text in JSON: Invalid Token`),
      // 那种只是**这一次的刷新没拿到**, 正在进行的对话不受影响 ⇒ 说「少量通讯丢包」就够,
      // 别让用户以为 App 坏了 ⇒ 真正的鉴权/配置类错误走 describeError, 它会把
      // 「需要重新配对」这类要紧话说清楚 ✓
      this.notice = `加载消息失败: ${describeSoftly(err)}`;
    }
  }

  /**
   * 把拉到的消息并进列表。
   *
   * 同一个 key 覆盖(内容在变 ✓), 本地回显的那条被真消息顶掉 ✓(不然同一条出现两次 ✓),
   * 其余追加 ✓。刷新时用它, 这样正在流式输出的消息不会被冲掉 ✓
   */
  private mergeMessages(list: BridgeMessage[]): void {
    for (let i = 0; i < list.length; i++) {
      const m: BridgeMessage = list[i];
      // system 消息是运行时上下文, 体积极大且对手机端没有意义, 直接跳过
      if (m.role === 'system') {
        continue;
      }
      const detail: DetailMessage = m as DetailMessage;
      const seq: number = detail.seq ?? 0;
      const cached: string | undefined = this.fullTexts.get(seq);
      // 内存里一律留全文: 桥接真给了预览(truncated ✓)才靠「点开更多」去取, 本地不再硬截 ✓
      const text: string = cached !== undefined ? cached : m.text;
      const existing = this.messages.find((x: DisplayMessage) => x.key === m.id);
      // 同一条消息有两个 id: 流式那一行(m-live-<attemptId>, 走 WS)和
      // 正式那一行(m-<seq>, 只在 REST 列表里) ⇒ 用序号把它们对上 ✓
      // 对不上就会同一步显示两行 ⇒ 看着就像乱序 ✗
      let row: DisplayMessage | undefined = existing;
      if (row === undefined && seq > 0) {
        row = this.messages.find((x: DisplayMessage) => x.seq === seq);
      }
      if (row !== undefined) {
        // 正式消息的正文更准; 正式的是空的(这一步只调了工具)就留着流式收到的文字 ✓
        if (text.length > 0) {
          row.text = text;
        }
        row.status = m.status;
        row.streaming = m.status === 'streaming';
        // 时间取正式的: 流式那一行的时间是"流开始"的时刻, 比真正落地早几十秒 ⇒
        // 拿它排序就会插到老消息中间 ⇒ 看着就是没按时间排 ✗
        row.at = m.createdAt;
        row.time = formatTime(m.createdAt);
        row.seq = seq;
        row.truncated = cached === undefined && detail.truncated === true;
        continue;
      }
      const local = this.messages.find((x: DisplayMessage) =>
        x.key.startsWith('local-') && x.role === m.role && x.text === text);
      if (local !== undefined) {
        local.key = m.id;
        local.at = m.createdAt;
        local.time = formatTime(m.createdAt);
        local.status = m.status;
        local.streaming = m.status === 'streaming';
        // 真消息顶掉本地回显时, 序号/截断信息也要跟着真消息走,
        // 不然「点开更多」会因为 seq=0 取不到全文 ✓
        local.seq = seq;
        local.truncated = cached === undefined && detail.truncated === true;
        local.expanded = cached !== undefined;
        continue;
      }
      this.messages.push({
        key: m.id,
        role: m.role,
        kind: m.kind,
        toolName: m.name !== undefined ? m.name : '',
        text: text,
        time: formatTime(m.createdAt),
        at: m.createdAt,
        streaming: m.status === 'streaming',
        status: m.status,
        seq: seq,
        truncated: cached === undefined && detail.truncated === true,
        expanded: cached !== undefined,
        loadingFull: false,
        fullError: ''
      });
    }
    this.messages = this.messages.slice();
    this.sortMessages();
  }

  /** 取桌面端状态条用的用量数据(bridge 没提供就跳过) */
  private async loadStats(): Promise<void> {
    try {
      const raw = await AppState.client.sessionStats(this.sessionId);
      if (raw.length === 0) {
        return;
      }
      const parsed = JSON.parse(raw) as SessionStatsResponse;
      const s = parsed.stats;
      if (s === undefined || s === null) {
        return;
      }
      this.stats = {
        turns: s.turns !== undefined ? s.turns : 0,
        steps: s.steps !== undefined ? s.steps : 0,
        outputTokens: s.outputTokens !== undefined ? s.outputTokens : 0,
        cacheReadTokens: s.cacheReadTokens !== undefined ? s.cacheReadTokens : 0,
        contextTokens: s.contextTokens !== undefined ? s.contextTokens : 0,
        contextWindow: s.contextWindow !== undefined ? s.contextWindow : 0,
        model: s.model !== undefined ? s.model : '',
        permission: s.permission !== undefined ? s.permission : '',
        agentLabel: s.agentLabel !== undefined ? s.agentLabel : ''
      };
    } catch (e) {
      // 这个端点是可选的, 拿不到不影响使用
    }
  }

  /** 这条消息折叠时最多渲染多少字(工具输出本来就是紧凑块, 用小阈值 ✓) */
  private static previewLimit(m: DisplayMessage): number {
    return m.role === 'tool' ? TOOL_PREVIEW_LIMIT : PREVIEW_LIMIT;
  }

  /**
   * 这条消息要不要显示「点开更多」。
   *
   * 两种来源: 桥接只给了预览(truncated ✓), 或者本地正文本身就超过了折叠阈值
   * (流式拼起来的 / 桥接一次性给的全文 ✓)
   */
  private needsMore(m: DisplayMessage): boolean {
    return m.truncated || m.text.length > SessionDetailView.previewLimit(m);
  }

  /**
   * 渲染用的正文。
   *
   * 展开态给全文; 没展开就只取前 N 个字 —— **截断只在这一层做**,
   * m.text 永远是全文, 往正文里写「内容过长, 已截断」这种话的做法已经没有了 ✓
   */
  private visibleText(m: DisplayMessage): string {
    if (m.expanded) {
      return m.text;
    }
    const limit: number = SessionDetailView.previewLimit(m);
    if (m.text.length <= limit) {
      return m.text;
    }
    return m.text.substring(0, limit);
  }

  /**
   * 工具调用在 bridge 里存的是 "name(args)" 这种形式,
   * 手机上工具名单独一行显示, 这里把重复的名字去掉, 只留参数。
   */
  private static toolArgs(text: string, name: string): string {
    if (name.length === 0) {
      return SessionDetailView.clipLine(text);
    }
    const prefix: string = `${name}(`;
    if (text.startsWith(prefix)) {
      const body: string = text.substring(prefix.length);
      const args: string = body.endsWith(')') ? body.substring(0, body.length - 1) : body;
      return SessionDetailView.clipLine(args);
    }
    return SessionDetailView.clipLine(text);
  }

  /**
   * 工具调用的参数在这一行只是一行摘要(maxLines(1)) ⇒ 没必要把整段参数塞进 Text:
   * 几十 KB 的字符串光排版就能把列表拖卡 ✓(完整输出在同一条工具输出里看 ✓)
   */
  private static clipLine(text: string): string {
    return text.length > 400 ? text.substring(0, 400) : text;
  }

  /**
   * 排一下: 老的在上, 新的在下 ✓
   *
   * **正在流式输出的那条钉在最下面** ✓
   *
   * 它的 `at` 是「流开始」的时刻, 而它真正落地(模型答完)要晚几十秒 ——
   * 不钉住的话, 它会插到几十秒前的老消息中间去, 看着就像「没按时间排」✗
   * ⇒ 流式期间钉在最后, 等它完成了再按真时间归位 ✓
   *
   * 同一条消息的序号(seq)比时间戳还稳 ⇒ 拿它兜底 ✓
   */
  private sortMessages(): void {
    this.messages.sort((a: DisplayMessage, b: DisplayMessage) => {
      const aLive: number = a.streaming ? 1 : 0;
      const bLive: number = b.streaming ? 1 : 0;
      if (aLive !== bLive) {
        return aLive - bLive;
      }
      if (a.at !== b.at) {
        return a.at - b.at;
      }
      if (a.seq !== b.seq) {
        return a.seq - b.seq;
      }
      return a.key < b.key ? -1 : 1;
    });
  }

  private appendOrMerge(message: BridgeMessage): void {
    this.mergeMessages([message]);
    this.scrollToEnd();
  }

  private mergeDelta(messageId: string, delta: string): void {
    const existing = this.messages.find((m: DisplayMessage) => m.key === messageId);
    if (existing !== undefined) {
      // 内存里始终拼全文 —— 截断/预览交给渲染层的 visibleText ✓
      // (以前这里拼到 4000 字就裁成半句, 还往正文里塞「已截断」, 用户看到的断句就是它 ✗)
      existing.text += delta;
      existing.streaming = true;
      this.messages = this.messages.slice();
      this.scrollToEnd();
      return;
    }
    const item: DisplayMessage = {
      key: messageId,
      role: 'assistant',
      kind: 'text',
      toolName: '',
      text: delta,
      time: formatTime(Date.now()),
      at: Date.now(),
      streaming: true,
      status: 'streaming',

      seq: 0,

      truncated: false,

      expanded: false,

      loadingFull: false,

      fullError: ''
    };
    this.messages = this.messages.concat([item]);
    this.sortMessages();
    this.scrollToEnd();
  }

  /**
   * 「点开更多」/「收起」。
   *
   * 只就地展开这一条 —— 别的还是预览 ✓
   * 展开过的记下来, 重新拉列表还是全文 ✓
   */
  private async toggleFull(m: DisplayMessage): Promise<void> {
    if (m.expanded) {
      m.expanded = false;
      m.loadingFull = false;
      m.fullError = '';
      this.messages = this.messages.slice();
      return;
    }
    // 全文本来就在内存里(流式拼进来的 / 桥接一次性给的) ⇒ 直接展开, 不用去桥接取 ✓
    if (!m.truncated) {
      m.expanded = true;
      m.loadingFull = false;
      m.fullError = '';
      this.messages = this.messages.slice();
      return;
    }
    if (m.seq <= 0) {
      m.fullError = '这条消息没有序号, 取不到全文';
      this.messages = this.messages.slice();
      return;
    }
    m.loadingFull = true;
    m.fullError = '';
    this.messages = this.messages.slice();
    try {
      const full: string = await AppState.client.fullMessage(this.sessionId, m.seq);
      this.fullTexts.set(m.seq, full);
      m.text = full;
      m.truncated = false;
      m.expanded = true;
      m.loadingFull = false;
      this.expandedSeqs.add(m.seq);
    } catch (e) {
      m.loadingFull = false;
      // 跟「加载消息」同一性质: 这一次的取全文没拿到, 重试一下就行 ⇒ 说清楚别吓人 ✓
      const err = e as Error;
      m.fullError = `取不到全文, 再点一次重试: ${describeSoftly(err)}`;
    }
    this.messages = this.messages.slice();
  }

  /**
   * 这一行是不是一条**已知的**斜杠指令?
   *
   * 桌面的指令名都是小写字母/数字/下划线/连字符(`/compact`、`/permission`…),
   * 而且必须是整行 —— 所以 "/usr/bin" 这种路径不会被误当成指令 ✓
   *
   * @param text the whole line the user is about to send
   * @returns the command name, or null when the line is not a known command
   */
  private commandNameIn(text: string): string | null {
    if (!text.startsWith('/')) return null;
    const space: number = text.indexOf(' ');
    const name: string = (space === -1 ? text : text.slice(0, space)).slice(1);
    if (name.length === 0) return null;
    for (const c of this.commands) {
      if (c.name === name) return name;
    }
    return null;
  }

  /**
   * 跑一条斜杠指令。
   *
   * 指令不产生用户消息(桌面上它渲染成一个流程节点), 所以这里不回显 ✓
   */
  private async runCommand(line: string): Promise<void> {
    try {
      const result: CommandResultResponse = await AppState.client.executeCommand(this.sessionId, line);
      if (!result.ok) {
        // 桌面端给的失败说明有可能是英文 ⇒ 前面垫一句中文, 后面跟解释过的原文 ✓
        // (桌面端没给说明时, 把用户自己敲的那条指令报出来, 至少是用户认识的东西 ✓)
        const why: string = result.text.length > 0 ? explain(result.text) : '';
        this.toast(why.length > 0 ? `这条指令没跑起来: ${why}` : `这条指令没跑起来: ${line}`);
      }
    } catch (e) {
      const err = e as Error;
      this.notice = `指令没跑起来: ${describeError(err)}`;
      this.toast(`指令没跑起来: ${describeError(err)}`);
    }
    this.draft = '';
    this.scrollToEnd(true);
    // 指令跑完, 桌面端会推新状态过来 ⇒ 顺手拉一下最新的 ✓
    setTimeout(() => {
      this.refreshLatest();
      void this.loadQueue();
    }, 500);
  }

  private async send(): Promise<void> {
    const text: string = this.draft.trim();
    if (text.length === 0) {
      return;
    }
    this.sending = true;
    this.notice = '';
    try {
      // 整行就是一条斜杠指令 ⇒ 走桌面端的指令通道(commands/execute), 不是当提示词发出去。
      // 桌面端也是这么分的: 它的「/」面板把整行交给指令登记表, 由它去跑处理函数 ✓
      // (技能不一样: 技能是靠消息里的 /名字 手势被桌面端认出来的, 照常发提示词就行 ✓)
      let command: string | null = this.commandNameIn(text);
      if (command === null && text.startsWith('/') && this.commands.length === 0) {
        try {
          this.commands = await AppState.client.listCommands(this.sessionId);
          command = this.commandNameIn(text);
        } catch (e) {
          // 拿不到指令目录就当普通提示词发 ✓
        }
      }
      if (command !== null) {
        await this.runCommand(text);
        return;
      }
      // 危险动作(会话权限是 danger-full-access, 而且这条命中了危险模式)→ 手机上再确认一次。
      const allowed: boolean = await this.confirmIfDangerous(text);
      if (!allowed) {
        this.sending = false;
        return;
      }
      // 先本地回显, 随后由桌面端推送真实消息
      const local: DisplayMessage = {
        key: `local-${Date.now()}`,
        role: 'user',
        kind: 'text',
        toolName: '',
        text: text,
        time: formatTime(Date.now()),
        at: Date.now(),
        streaming: false,
        status: 'done',

        seq: 0,

        truncated: false,

        expanded: false,

        loadingFull: false,

        fullError: ''
      };
      this.messages = this.messages.concat([local]);
      this.sortMessages();
      this.draft = '';
      this.scrollToEnd(true);

      await AppState.client.submitPrompt(this.sessionId, text, 'queue');
      // 记一下这条是几点发出去的 ⇒ 队列面板能按时间排 ✓(桌面端不给时间 ✓)
      this.sentAt.set(text, Date.now());
      this.running = true;
      // 这一条可能被**排进队列**(电脑端正在跑别的活儿) ⇒ 马上把队列拉回来,
      // 否则那条绿色的队列条不会冒出来(它只在挂载和状态变化时刷新) ✓
      void this.loadQueue();
      // 后台再拉一次最新的一页: 桌面端会把这条真消息推回来, 顺便把别的新消息也补上 ✓
      setTimeout(() => {
        this.refreshLatest();
      }, 500);
    } catch (e) {
      const err = e as Error;
      this.notice = `下发失败: ${describeError(err)}`;
      this.toast(`下发失败: ${describeError(err)}`);
    } finally {
      this.sending = false;
    }
  }

  /**
   * 危险动作二次确认。
   *
   * 判定在桥接那边做(它知道会话的权限和 DSH 的工具名), 它说这条要确认, 手机就再问一次。
   * 预判接口还没上线或者临时挂了就当不用问 —— 不能因为这个接口把下发堵死。
   */
  private async confirmIfDangerous(text: string): Promise<boolean> {
    let preview: PromptPreview | null = null;
    try {
      preview = await AppState.client.getPromptPreview(this.sessionId, text);
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '危险动作预判失败, 直接下发: %{public}s', err.message ?? '');
      return true;
    }
    if (preview === null || preview.requiresConfirmation !== true) {
      return true;
    }
    const summary: string = preview.summary ?? '桌面端要执行一个危险动作';
    hilog.info(DOMAIN, TAG, '危险动作二次确认: %{public}s', summary);
    return await this.showConfirmDialog(summary);
  }

  /** 弹确认框: 「允许」返回 true, 「取消」返回 false。 */
  private showConfirmDialog(summary: string): Promise<boolean> {
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      const options: AlertDialogParamWithButtons = {
        title: '需要你确认',
        message: summary,
        primaryButton: {
          value: '允许',
          action: () => {
            resolve(true);
          }
        },
        secondaryButton: {
          value: '取消',
          action: () => {
            resolve(false);
          }
        }
      };
      this.getUIContext().showAlertDialog(options);
    });
  }

  private async cancel(): Promise<void> {
    try {
      await AppState.client.cancel(this.sessionId);
      this.running = false;
    } catch (e) {
      const err = e as Error;
      this.notice = `取消失败: ${describeError(err)}`;
    }
  }

  private async copyText(text: string): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      const board = await pasteboard.getSystemPasteboard();
      await board.setData(data);
      this.toast('已复制');
    } catch (e) {
      this.toast('复制失败');
    }
  }

  /** 拉最新的一页并进来(不清空现有的, 正在流式输出的消息不能被冲掉 ✓)。 */
  private async refreshLatest(): Promise<void> {
    try {
      const list = await AppState.client.listMessages(this.sessionId, 50);
      this.mergeMessages(list);
      this.scrollToEnd();
    } catch (e) {
      // 刷新失败就算了, 屏幕上已经有的内容不受影响 ✓
    }
  }

  /**
   * 滚到最新一条。
   *
   * @param force true = 强制滚(进会话 / 自己刚发出去 / 点了「最新」按钮);
   *              默认只在「本来就在最底部」时才滚 —— 用户翻上去看历史时不能被新消息拽下来。
   */
  private scrollToEnd(force: boolean = false): void {
    if (this.messages.length === 0) {
      return;
    }
    if (!force && !this.atBottom) {
      return;
    }
    this.atBottom = true;
    // 第一次布局还没完成时 scrollToIndex 是没用的(V1 的坑 ✓),
    // 所以先记着, 等列表区域真的变了再滚 ✓
    this.pendingScroll = true;
    this.doScrollToEnd();
    setTimeout(() => {
      this.doScrollToEnd();
    }, 150);
  }

  private doScrollToEnd(): void {
    if (this.messages.length === 0) {
      return;
    }
    try {
      this.scroller.scrollToIndex(this.messages.length - 1, true, ScrollAlign.END);
      this.pendingScroll = false;
    } catch (e) {
      // 布局还没好, 等下一次区域变化 ✓
    }
  }

  /* ---------------------------------------------------------------- 展示辅助 */

  /** 助手消息的状态行文字 */
  private statusLabel(m: DisplayMessage): string {
    if (m.streaming) {
      return '正在生成…';
    }
    if (m.status === 'error') {
      return '出错';
    }
    return '已完成';
  }

  private roleTag(role: string, kind: string): string {
    if (role === 'user') {
      return '用户';
    }
    if (role === 'tool') {
      return '工具';
    }
    if (kind === 'tool_call') {
      return '调用';
    }
    return '助手';
  }

  private roleTagColor(role: string, kind: string): string {
    if (role === 'user') {
      return this.pal('ACCENT');
    }
    if (role === 'tool' || kind === 'tool_call') {
      return this.pal('TOOL');
    }
    if (role === 'system') {
      return this.pal('CONTEXT');
    }
    return this.pal('ASSISTANT');
  }

  private formatTokens(n: number): string {
    if (n >= 1000000) {
      return `${(n / 1000000).toFixed(1)}M`;
    }
    if (n >= 1000) {
      return `${Math.round(n / 1000)}K`;
    }
    return `${n}`;
  }

  private permissionLabel(): string {
    if (this.stats === null) {
      return '';
    }
    const p: string = this.stats.permission;
    if (p.length === 0) {
      return '';
    }
    if (p === 'danger-full-access') {
      return '完全权限';
    }
    if (p === 'workspace-write') {
      return '工作区内修改';
    }
    return p;
  }

  /* ------------------------------------------------------------- 队列 */

  /* ------------------------------------------------- 需要你选择的问题 */

  /** 从桥接拉「当前在等回答的问题」 */
  private async loadQuestions(): Promise<void> {
    if (this.sessionId.length === 0) {
      return;
    }
    const calls: AskCall[] = await AppState.client.getQuestions(this.sessionId);
    const before: string = JSON.stringify(this.askCalls);
    if (JSON.stringify(calls) !== before) {
      this.askCalls = calls;
      this.prunePicks();
    }
  }

  /** 丢掉已经不存在的勾选 */
  private prunePicks(): void {
    const kept: string[] = [];
    for (let i = 0; i < this.askPicked.length; i++) {
      const item: string = this.askPicked[i];
      const parts: string[] = item.split('|');
      let alive: boolean = false;
      for (let j = 0; j < this.askCalls.length; j++) {
        if (this.askCalls[j].callId === parts[0]) {
          alive = true;
          break;
        }
      }
      if (alive) {
        kept.push(item);
      }
    }
    this.askPicked = kept;
  }

  /** 某道题已经勾了哪些选项 */
  private askLabels(callId: string, qid: string): string[] {
    const prefix: string = `${callId}|${qid}|`;
    const out: string[] = [];
    for (let i = 0; i < this.askPicked.length; i++) {
      const item: string = this.askPicked[i];
      if (item.startsWith(prefix)) {
        out.push(item.substring(prefix.length));
      }
    }
    return out;
  }

  /** 勾选/取消一个选项 */
  private toggleAsk(row: AskRow): void {
    const key: string = `${row.callId}|${row.qid}|${row.label}`;
    const prefix: string = `${row.callId}|${row.qid}|`;
    const picked: boolean = this.askPicked.indexOf(key) >= 0;
    if (picked) {
      this.askPicked = this.askPicked.filter((item: string): boolean => item !== key);
      return;
    }
    if (row.multi) {
      const next: string[] = this.askPicked.slice();
      next.push(key);
      this.askPicked = next;
    } else {
      // 单选: 先清掉同一题的其他勾选
      const rest: string[] = this.askPicked.filter((item: string): boolean => !item.startsWith(prefix));
      rest.push(key);
      this.askPicked = rest;
    }
  }

  /** 这道题是否已经回答了(选了选项, 或者写了文字) */
  private askAnswered(callId: string, qid: string): boolean {
    return this.askLabels(callId, qid).length > 0 || this.askCustomOf(callId, qid).length > 0;
  }

  /** 某道题自己的文字回答(没有就是空串)。 */
  private askCustomOf(callId: string, qid: string): string {
    const key: string = `${callId}|${qid}`;
    for (let i = 0; i < this.askCustoms.length; i++) {
      if (this.askCustoms[i].key === key) {
        return this.askCustoms[i].text.trim();
      }
    }
    return '';
  }

  /** 记下某道题的文字回答。 */
  private setAskCustom(callId: string, qid: string, value: string): void {
    const key: string = `${callId}|${qid}`;
    const next: AskCustomEntry[] = [];
    let found: boolean = false;
    for (let i = 0; i < this.askCustoms.length; i++) {
      const entry: AskCustomEntry = this.askCustoms[i];
      if (entry.key === key) {
        found = true;
        if (value.length > 0) {
          next.push({ key: key, text: value });
        }
      } else {
        next.push(entry);
      }
    }
    if (!found && value.length > 0) {
      next.push({ key: key, text: value });
    }
    this.askCustoms = next;
  }

  /** 整个 ask 调用是否可以提交(每道题都得有答案) */
  private askComplete(call: AskCall): boolean {
    for (let i = 0; i < call.questions.length; i++) {
      if (!this.askAnswered(call.callId, call.questions[i].id)) {
        return false;
      }
    }
    return true;
  }

  /** 提交一次 ask 调用的回答 */
  private async submitAsk(callId: string): Promise<void> {
    if (this.askBusy) {
      return;
    }
    let target: AskCall | null = null;
    for (let i = 0; i < this.askCalls.length; i++) {
      if (this.askCalls[i].callId === callId) {
        target = this.askCalls[i];
        break;
      }
    }
    if (target === null) {
      return;
    }
    if (!this.askComplete(target)) {
      this.toast('还有问题没回答: 选一个选项, 或在输入框写文字');
      return;
    }
    this.askBusy = true;
    try {
      const answers: AskAnswer[] = [];
      for (let i = 0; i < target.questions.length; i++) {
        const q: AskQuestion = target.questions[i];
        const labels: string[] = this.askLabels(callId, q.id);
        // 官方允许 selected 与 custom 并存(「选了 A 又补充一句」), 所以两个都带上,
        // 别再像以前那样二选一、把输入框的文字丢掉。
        const text: string = this.askCustomOf(callId, q.id);
        const answer: AskAnswer = { id: q.id, selected: labels };
        if (text.length > 0) {
          answer.custom = text;
        }
        answers.push(answer);
      }
      await AppState.client.answerQuestions(this.sessionId, callId, answers);
      this.askPicked = this.askPicked.filter((item: string): boolean => !item.startsWith(`${callId}|`));
      this.askCustoms = this.askCustoms.filter((item: AskCustomEntry): boolean => !item.key.startsWith(`${callId}|`));
      this.askCustom = '';
      this.toast('已提交回答');
      await this.loadQuestions();
    } catch (e) {
      this.toast(`提交回答失败: ${describeError(e as Error)}`);
    } finally {
      this.askBusy = false;
    }
  }

  /** 把 ask 调用摊平成一行一行(面板里只放一层 ForEach) */
  private askRows(): AskRow[] {
    const out: AskRow[] = [];
    for (let i = 0; i < this.askCalls.length; i++) {
      const call: AskCall = this.askCalls[i];
      out.push({
        kind: 'header', key: `h:${call.callId}`, text: '桌面端在等你回答',
        sub: '选好后提交; 提交会作为一条回复发给桌面端',
        callId: call.callId, qid: '', label: '', multi: false, checked: false, enabled: true
      });
      for (let j = 0; j < call.questions.length; j++) {
        const q: AskQuestion = call.questions[j];
        if (q.header !== undefined && q.header.length > 0) {
          out.push({
            kind: 'qhead', key: `qh:${call.callId}:${q.id}`, text: q.header, sub: '',
            callId: call.callId, qid: q.id, label: '', multi: false, checked: false, enabled: true
          });
        }
        out.push({
          kind: 'q', key: `q:${call.callId}:${q.id}`, text: q.question,
          sub: q.detail === undefined ? '' : q.detail,
          callId: call.callId, qid: q.id, label: '', multi: q.multiSelect === true,
          checked: false, enabled: true
        });
        const options: AskOption[] = q.options === undefined || q.options === null ? [] : q.options;
        if (options.length === 0) {
          out.push({
            kind: 'hint', key: `ht:${call.callId}:${q.id}`,
            text: '这题没有给选项 —— 在下面输入框写你的回答',
            sub: '', callId: call.callId, qid: q.id, label: '',
            multi: false, checked: false, enabled: true
          });
        } else {
          const pickedLabels: string[] = this.askLabels(call.callId, q.id);
          for (let k = 0; k < options.length; k++) {
            const option: AskOption = options[k];
            out.push({
              kind: 'option', key: `o:${call.callId}:${q.id}:${k}`,
              text: option.label,
              sub: option.description === undefined ? '' : option.description,
              callId: call.callId, qid: q.id, label: option.label,
              multi: q.multiSelect === true,
              checked: pickedLabels.indexOf(option.label) >= 0,
              enabled: true
            });
          }
        }
        // 每道题各自一个「其他」输入框(官方 custom 是每题独立的, 不能共用一个)。
        out.push({
          kind: 'custom', key: `c:${call.callId}:${q.id}`, text: '', sub: '',
          callId: call.callId, qid: q.id, label: '', multi: false,
          checked: false, enabled: true
        });
      }
      if (call.answerable === false) {
        // DSH 前台等待中的提问只有当前前台客户端能答; 手机端只提醒/展示, 不给提交按钮,
        // 免得用户点了只收到一个 409。
        out.push({
          kind: 'hint', key: `na:${call.callId}`,
          text: '这条问题正在桌面端等待回答，只能在电脑上作答（手机端只做提醒/查看）。',
          sub: '', callId: call.callId, qid: '', label: '', multi: false,
          checked: false, enabled: false
        });
        continue;
      }
      out.push({
        kind: 'submit', key: `s:${call.callId}`, text: '提交回答', sub: '',
        callId: call.callId, qid: '', label: '', multi: false,
        checked: false, enabled: this.askComplete(call)
      });
    }
    return out;
  }

  /** 读队列: agent 在跑的时候, 手机上发出去的指令先排在这儿。 */
  private async loadQueue(): Promise<void> {
    if (this.sessionId.length === 0) {
      return;
    }
    try {
      const queue = await AppState.client.getQueue(this.sessionId);
      this.queueNextTurn = this.stampQueue(queue.nextTurn);
      this.queueNextStep = this.stampQueue(queue.nextStep);
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '读取队列失败: %{public}s', err.message ?? '');
    }
  }

  /** 给队列条目补上「我什么时候发出去的」(桌面端不给, 手机自己记 ✓) */
  private stampQueue(items: QueueItem[]): QueueItem[] {
    const out: QueueItem[] = [];
    for (const item of items) {
      const sent: number = this.sentAt.get(item.text) ?? 0;
      out.push({ id: item.id, text: item.text, target: item.target, at: sent });
    }
    return out;
  }

  /**
   * 队列排成一条, 按**发出去的时间**排 ✓
   *
   * 桌面端把队列分成两个桶(next-turn 下一轮 / next-step 下一步),
   * 手机上原来也是分两块画 ⇒ 看着就不是按时间排的 ✗
   * ⇒ 这里合成一条, 按发送时间排 ✓(查不到时间的按桌面端给的次序排在前面 ✓)
   */
  private queueRows(): QueueItem[] {
    const rows: QueueItem[] = [];
    for (const item of this.queueNextTurn) {
      rows.push(item);
    }
    for (const item of this.queueNextStep) {
      rows.push(item);
    }
    rows.sort((a: QueueItem, b: QueueItem): number => {
      if (a.at !== b.at) {
        return a.at - b.at;
      }
      return a.target < b.target ? -1 : (a.target > b.target ? 1 : 0);
    });
    return rows;
  }

  /** 改一条排队中的任务: edit / remove / steer */
  private async queueAction(item: QueueItem, action: string): Promise<void> {
    if (action === 'edit') {
      // 就地编辑: 桌面端也是这么改的
      this.editingId = item.id;
      this.editingText = item.text;
      return;
    }
    try {
      await this.applyQueueAction(item, action, '');
    } catch (e) {
      const err = e as Error;
      this.toast('操作失败: ' + describeError(err));
    }
  }

  private async applyQueueAction(item: QueueItem, action: string, text: string): Promise<void> {
    try {
      await AppState.client.updateQueueItem(this.sessionId, item.id, action, text);
      await this.loadQueue();
    } catch (e) {
      const err = e as Error;
      this.toast('操作失败: ' + describeError(err));
    }
  }

  private queueCount(): number {
    return this.queueNextTurn.length + this.queueNextStep.length;
  }

  /* ------------------------------------------------------------- + 号 */

  /** 打开 + 号: 先把指令列出来, 技能在后台慢慢加载。 */
  private async openPlus(): Promise<void> {
    this.plusOpen = true;
    this.plusTab = 0;
    this.plusLoading = true;
    try {
      this.commands = await AppState.client.listCommands(this.sessionId);
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '读取指令失败: %{public}s', err.message ?? '');
    }
    this.rebuildPickItems();
    // 面板一定要转完 —— 不然它一直卡在转圈上, 看着像"没反应" ✓
    this.plusLoading = false;
    // 技能要扫一遍桌面端的技能包, 慢, 放到后台
    void this.loadSkillsInBackground();
  }

  /* ------------------------------------------------------- 附件上传 */

  /** 从相册选一张图片 → 直传电脑 → 把路径 @ 进输入框。 */
  private async pickImageToUpload(): Promise<void> {
    if (this.uploading) {
      return;
    }
    try {
      const viewPicker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result: photoAccessHelper.PhotoSelectResult = await viewPicker.select(options);
      if (result.photoUris.length === 0) {
        return;
      }
      await this.uploadUri(result.photoUris[0], `IMG_${Date.now()}.jpg`, 'image/jpeg');
    } catch (e) {
      this.toast(`选图失败: ${describeError(e as Error)}`);
    }
  }

  /** 选任意文件 → 直传电脑 → 把路径 @ 进输入框。 */
  private async pickFileToUpload(): Promise<void> {
    if (this.uploading) {
      return;
    }
    try {
      const viewPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const uris: string[] = await viewPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const uri: string = uris[0];
      const parts: string[] = uri.split('/');
      const name: string = parts.length > 0 ? parts[parts.length - 1] : `file_${Date.now()}.bin`;
      await this.uploadUri(uri, name, 'application/octet-stream');
    } catch (e) {
      this.toast(`选文件失败: ${describeError(e as Error)}`);
    }
  }

  /** 读 URI 的字节直传给桥接; 成功返回电脑上的绝对路径。 */
  private async uploadUri(uri: string, name: string, mime: string): Promise<void> {
    this.uploading = true;
    this.toast('正在上传…');
    try {
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      try {
        const stat = fileIo.statSync(file.fd);
        const buffer = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buffer);
        const remotePath: string = await AppState.client.uploadAttachment(name, mime, buffer);
        this.insertToDraft('@' + remotePath + ' ');
        this.plusOpen = false;
        this.toast('已添加文件，发送后桌面端能读到它');
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      this.toast(`上传失败: ${describeError(e as Error)}`);
    } finally {
      this.uploading = false;
    }
  }

  /** 后台加载技能与文件候选。 */
  private async loadSkillsInBackground(): Promise<void> {
    try {
      if (this.skills.length === 0) {
        this.skills = await AppState.client.listSkills(this.sessionId);
      }
      if (this.files.length === 0) {
        this.files = await AppState.client.listFiles(this.sessionId, this.fileQuery);
      }
      this.rebuildPickItems();
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '读取技能失败: %{public}s', err.message ?? '');
    }
  }

  /** 切换 + 号面板的三个标签。 */
  private setPlusTab(index: number): void {
    this.plusTab = index;
    try {
      this.rebuildPickItems();
    } catch (e) {
      // 面板自己出问题也不能把整个 App 带下去 ✓
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '重建候选列表失败: %{public}s', err.message ?? '');
      this.pickItems = [];
      this.pickEmpty = '这个列表读不出来';
      this.pickMore = '';
    }
    if (index === 1 && this.skills.length === 0) {
      this.plusLoading = true;
      void this.loadSkillsInBackground().then(() => { this.plusLoading = false; });
    }
    if (index === 2) {
      void this.searchFiles();
    }
  }

  /**
   * 把三个标签的候选合成一份列表。
   *
   * 面板里只放一个 ForEach: 同一个 ForEach 出现在 if/else 分支里会让 ArkUI 崩掉。
   */
  private rebuildPickItems(): void {
    const items: PickItem[] = [];
    if (this.plusTab === 0) {
      for (const c of this.commands) {
        items.push({
          id: 'c-' + c.name,
          title: '/' + c.name,
          subtitle: c.hint.length > 0 ? c.hint : c.description,
          insert: '/' + c.name
        });
      }
      this.pickEmpty = '这个会话没有可调用的指令';
    } else if (this.plusTab === 1) {
      // 桌面上装了两百多个技能, 描述还特别长 ⇒ 一次全铺出来会把手机撑爆,
      // 只摆前面一批, 其余的提示去电脑上用 /名字 调 ✓
      const shown = Math.min(this.skills.length, MAX_PICK_ITEMS);
      for (let i = 0; i < shown; i++) {
        const s = this.skills[i];
        items.push({
          id: 's-' + s.name,
          title: '/' + s.name,
          subtitle: s.description,
          insert: '/' + s.name
        });
      }
      this.pickEmpty = '没有找到技能';
      this.pickMore = this.skills.length > shown
        ? `还有 ${this.skills.length - shown} 个技能, 在电脑上用 /技能名 调用`
        : '';
    } else {
      for (const f of this.files) {
        items.push({
          id: 'f-' + f.path,
          title: f.path,
          subtitle: f.kind === 'directory' ? '目录' : '文件',
          insert: '@' + f.path
        });
      }
      this.pickEmpty = '没有找到文件';
      this.pickMore = '';
    }
    this.pickItems = items;
  }

  private async searchFiles(): Promise<void> {
    try {
      this.files = await AppState.client.listFiles(this.sessionId, this.fileQuery);
      this.rebuildPickItems();
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '读取文件候选失败: %{public}s', err.message ?? '');
    }
  }

  /** 把一段文字插到输入框末尾。 */
  private insertToDraft(text: string): void {
    if (this.draft.length === 0) {
      this.draft = text;
    } else if (this.draft.endsWith(' ') || this.draft.endsWith('\n')) {
      this.draft = this.draft + text;
    } else {
      this.draft = this.draft + ' ' + text;
    }
    this.plusOpen = false;
  }

  /* ------------------------------------------------------------- 模型 */

  /** 只取当前模型的名字, 给输入框右边那个小标签用。 */
  private async loadModelName(): Promise<void> {
    try {
      const state = await AppState.client.getSessionState(this.sessionId);
      this.stateData = state;
      if (state.model !== null) {
        this.modelProvider = state.model.provider;
        this.modelName = state.model.model;
        this.modelEffort = state.model.reasoningEffort;
      }
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '读取会话状态失败: %{public}s', err.message ?? '');
    }
  }

  /** 打开模型选择器。 */
  private async openModelPicker(): Promise<void> {
    this.modelOpen = true;
    try {
      if (this.catalog === null) {
        this.catalog = await AppState.client.getModels();
      }
      const state = await AppState.client.getSessionState(this.sessionId);
      this.stateData = state;
      if (state.model !== null) {
        this.modelProvider = state.model.provider;
        this.modelName = state.model.model;
        this.modelEffort = state.model.reasoningEffort;
      } else if (this.catalog !== null && this.catalog.default !== null) {
        this.modelProvider = this.catalog.default.provider;
        this.modelName = this.catalog.default.model;
        this.modelEffort = this.catalog.default.reasoningEffort;
      }
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '读取模型目录失败: %{public}s', err.message ?? '');
    }
  }

  /** 换模型。 */
  private async chooseModel(provider: string, model: string, effort: string): Promise<void> {
    this.modelProvider = provider;
    this.modelName = model;
    this.modelEffort = effort;
    try {
      await AppState.client.selectModel(this.sessionId, provider, model, effort);
      this.modelOpen = false;
      this.toast('已切换到 ' + model);
    } catch (e) {
      const err = e as Error;
      this.toast('切换失败: ' + describeError(err));
    }
  }

  /** 模型选择器上显示的名字: "MiniMax-M3.1-Flash" 这种。 */
  private modelLabel(): string {
    if (this.modelName.length > 0) {
      return this.modelName;
    }
    if (this.stateData !== null && this.stateData.model !== null) {
      return this.stateData.model.model;
    }
    return '选择模型';
  }

  /* ---------------------------------------------------------------- 构建 */

  /**
   * 消息 ForEach 的 key。
   *
   * 坑: key 不变 ForEach 就复用子组件、不重跑 itemGenerator ⇒ 流式文字、
   * 「点开更多/收起」、全文加载转圈这些**原地改字段**的更新都不会画出来。
   * 所以把渲染里读到的状态一起拼进 key。
   */
  private messageKey(m: DisplayMessage): string {
    let key: string = m.key;
    key += `|${m.text.length}|${m.streaming ? 1 : 0}|${m.expanded ? 1 : 0}`;
    key += `|${m.loadingFull ? 1 : 0}|${m.fullError.length}`;
    return key;
  }

  /** toast 失败不应该影响主流程, 这里统一吞掉异常。 */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, 'toast 失败: %{public}s', err.message ?? '');
    }
  }

  /**
   * 界面的**内容层**(不含浮层)。
   *
   * 单独拆出来是因为「+ 号」面板要盖住**整个会话详情栏**,
   * 而不是底部输入区那一小块 —— 挂在输入区里的话,
   * 面板的 100%/72% 会按输入区那点高度算, 候选列表会被压扁挤出屏幕。
   */
  @Builder
  detailBody() {
    Column() {
      // ---------- 顶部栏 ----------
      Column() {
        Row({ space: Space.SM }) {
          if (this.showBack) {
            Text('‹')
              .fontSize(28)
              .fontColor(this.pal('TEXT_2'))
              .width(28)
              .onClick(() => { this.getUIContext().getRouter().back(); })
          }

          Column({ space: 2 }) {
            Text(this.title.length > 0 ? this.title : this.sessionId)
              .fontSize(FontSize.TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.pal('TEXT'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              // 标题也能长按复制(会话 id 有点长, 手打不现实 ✓)
              .copyOption(CopyOptions.LocalDevice)
            Text(this.cwd)
              .fontSize(FontSize.TINY)
              .fontColor(this.pal('TEXT_3'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (this.running) {
            Row({ space: 4 }) {
              LoadingProgress()
                .width(12)
                .height(12)
                .color(this.pal('OK'))
              Text('执行中')
                .fontSize(FontSize.SMALL)
                .fontColor(this.pal('OK'))
            }
          } else if (this.connectionText !== '未连接') {
            // 「重连中…」是**中性**说法(数据照样能加载), 所以用黄色, 不跟红色报错混在一起 ✓
            Text(this.connectionText)
              .fontSize(FontSize.SMALL)
              .fontColor(this.connectionText === '重连中…' ? this.pal('WARN') : this.pal('TEXT_3'))
          }

          // 设置
          Text('⚙')
            .fontSize(21)
            .fontColor(this.pal('TEXT_2'))
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/SettingsPage' });
            })
        }
        .width('100%')
        .padding({ left: Space.MD, right: Space.MD, top: Space.SM, bottom: Space.SM })

        // 「对话 / 轨迹」两个视图
        Row({ space: Space.XL }) {
          this.tabButton('对话', 0)
          this.tabButton('轨迹', 1)
        }
        .width('100%')
        .padding({ left: Space.MD, right: Space.MD, bottom: Space.SM })
      }
      .width('100%')
      .backgroundColor(this.pal('BG'))
      .border({ width: { bottom: 1 }, color: this.pal('BORDER_SOFT') })

      // ---------- 主体 ----------
      Column() {
        if (this.tab === 0) {
          this.conversationView()
        } else {
          this.traceView()
        }
      }
      .layoutWeight(1)
      .width('100%')
      // 半透明: 吉祥物背景能从对话区透出来; 文字下面还有一层 70% 的底, 读起来不费劲
      .backgroundColor(this.bodyScrim())

      // ---------- 底部 ----------
      Column() {
        if (this.notice.length > 0) {
          Text(this.notice)
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('ERROR'))
            .width('100%')
            .padding({ left: Space.LG, right: Space.LG, bottom: Space.SM })
        }

        // 审批/提问/队列卡片放进限高滚动区: 卡片再多也不把输入区顶出屏幕,
        // 发送键永远可见(之前就是被这排卡片顶出去的)。
        Scroll() {
          Column({ space: Space.SM }) {
            // 桌面端的内核审批(谁先答谁生效)
            this.approvalPanel()

            // 桌面端在等我们回答的问题(ask_user_question)
            this.askPanel()

            // 队列: agent 在跑的时候排着的任务
            this.queuePanel()
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: '42%' })
        .align(Alignment.Bottom)
        .scrollBar(BarState.Off)

        // 输入区: 工具条单独一行 + 输入框(发送键悬浮在右下角)
        Column({ space: Space.SM }) {
          Row({ space: Space.SM }) {
            // 左边的 + 号: 添加文件或调用指令
            Text('+')
              .fontSize(25)
              .fontColor(this.pal('TEXT_2'))
              .width(32)
              .height(32)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.pal('SURFACE_HI'))
              .borderRadius(Radius.PILL)
              .onClick(() => { void this.openPlus(); })

            if (this.permissionLabel().length > 0) {
              Text(this.permissionLabel())
                .fontSize(FontSize.SMALL)
                .fontColor(this.pal('TEXT_2'))
                .padding({ left: Space.SM, right: Space.SM, top: 6, bottom: 6 })
                .backgroundColor(this.pal('SURFACE_HI'))
                .borderRadius(Radius.PILL)
                .onClick(() => { this.toast('权限预设在桌面端修改'); })
            }

            Blank()

            // 右边的模型选择
            Text(this.modelLabel())
              .fontSize(FontSize.SMALL)
              .fontColor(this.pal('TEXT_2'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: Space.SM, right: Space.SM, top: 6, bottom: 6 })
              .backgroundColor(this.pal('SURFACE_HI'))
              .borderRadius(Radius.PILL)
              .onClick(() => { void this.openModelPicker(); })

            if (this.running) {
              Button('停止')
                .fontSize(FontSize.SMALL)
                .fontColor(this.pal('ERROR'))
                .backgroundColor(this.pal('SURFACE_HI'))
                .borderRadius(Radius.PILL)
                .onClick(() => { this.cancel(); })
            }
          }
          .width('100%')

          Stack({ alignContent: Alignment.BottomEnd }) {
            TextArea({ placeholder: '发送消息或创建任务, / 调用指令, @ 文件或对话', text: this.draft })
              .fontSize(FontSize.BODY)
              .fontColor(this.pal('TEXT'))
              .placeholderColor(this.pal('PLACEHOLDER'))
              .backgroundColor(Color.Transparent)
              .width('100%')
              .height(84)
              // 右下留出发送键的位置, 别让文字被圆钮盖住
              .padding({ right: 52, bottom: 6 })
              .onChange((value: string) => { this.draft = value; })
              .onFocus(() => {
                // 键盘弹起: 把对话滚到底, 最新消息和输入区都在视野里
                this.scrollToEnd(true);
                setTimeout(() => { this.scrollToEnd(true); }, 350);
              })

            // 发送键悬浮在输入框右下角: 跟着输入框走, 永远点得到
            Text('↑')
              .fontSize(21)
              .fontColor(Color.White)
              .width(36)
              .height(36)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.draft.trim().length > 0 && !this.sending ? this.pal('ACCENT_SOLID') : this.pal('SURFACE_HI'))
              .borderRadius(Radius.PILL)
              .margin({ right: 6, bottom: 6 })
              .onClick(() => { this.send(); })
          }
          .width('100%')
        }
        .width('100%')
        .padding(Space.MD)
        .backgroundColor(this.pal('SURFACE'))
        .borderRadius(Radius.LG)
        this.statusStrip()
      }
      .width('100%')
      .padding({ left: Space.SM, right: Space.SM, bottom: Space.SM, top: Space.SM })
      .backgroundColor(this.pal('BG_DEEP'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal('BG_DEEP'))
  }

  build() {
    // 根容器用 Stack: 底下是内容层, 上面盖浮层。
    //
    // 「+ 号」面板挂在这个根容器上 —— 根容器就是「会话详情栏」这一栏:
    //   - 宽屏(双栏): 这一栏是**右边的会话详情栏**, 浮层只压右栏, 不碰左边的会话列表 ✓
    //   - 竖屏(单栏): 这一栏就是整屏, 浮层占满整屏 ✓
    // 所以浮层不需要自己算左边界, 也不会越界到左边那一栏。
    Stack({ alignContent: Alignment.TopStart }) {
      // 吉祥物背景(浓度跟着设置走)
      if (this.bgAlpha() > 0.01) {
        Image(this.backdropImage())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.bgAlpha())
      }
      this.detailBody()

      if (this.plusOpen) {
        this.plusOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal('BG_DEEP'))
    // 底部 padding = 手势条 + 键盘: 键盘弹起时整页抬升, 输入面板完整浮在键盘上,
    // 发送键不会再被输入法的工具条盖住(系统平移量不够, 所以自己算)。
    .padding({ top: this.topSafeVp, bottom: this.bottomSafeVp + this.keyboardVp })
    .bindSheet($$this.modelOpen, this.modelSheet(), {
      height: '72%',
      backgroundColor: this.pal('BG_DEEP'),
      dragBar: true,
      showClose: true
    })
  }

  /** 拉「桌面端在等批准」的请求(只保留本会话的)。 */
  private async loadApprovals(): Promise<void> {
    if (this.sessionId.length === 0) {
      return;
    }
    const all: ApprovalRequest[] = await AppState.client.getApprovals();
    const mine: ApprovalRequest[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].agentId === this.sessionId) {
        mine.push(all[i]);
      }
    }
    if (JSON.stringify(mine) !== JSON.stringify(this.approvals)) {
      this.approvals = mine;
    }
  }

  /** 回答一条审批: 谁先答谁生效, 电脑先答了就会失败。 */
  private async answerApproval(eventId: string, outcome: string): Promise<void> {
    if (this.approvalBusy.length > 0) {
      return;
    }
    this.approvalBusy = eventId;
    try {
      await AppState.client.answerApproval(eventId, outcome);
      this.toast(outcome === 'allowed-once' ? '已允许（桌面会继续执行）' : '已拒绝');
      await this.loadApprovals();
    } catch (e) {
      // 最常见的是「电脑已经先点了」或「已过期」——说清楚, 别让用户以为点坏了。
      this.toast(`这条已经处理过了（可能是在电脑上点的）`);
      await this.loadApprovals();
    } finally {
      this.approvalBusy = '';
    }
  }

  /* ------------------------------------------------------- 需要你选择的面板 */

  @Builder
  approvalPanel() {
    if (this.approvals.length > 0) {
      Column({ space: Space.SM }) {
        Row({ space: Space.SM }) {
          Text('桌面端在等你处理')
            .fontSize(FontSize.SMALL)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F59E0B')
          Text(`共 ${this.approvals.length} 条`)
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        ForEach(this.approvals, (item: ApprovalRequest) => {
          Column({ space: 6 }) {
            Row({ space: 6 }) {
              Text(item.kind === 'question'
                ? '桌面端在等你选择'
                : (item.toolName.length > 0 ? item.toolName : '工具调用'))
                .fontSize(FontSize.BODY)
                .fontWeight(FontWeight.Medium)
                .fontColor('#111827')
                .layoutWeight(1)
              Text(`${Math.max(0, Math.round(item.remainingMs / 1000))}s`)
                .fontSize(FontSize.TINY)
                .fontColor('#B45309')
            }
            .width('100%')

            if (item.kind === 'question') {
              // 一题一页(和桌面一致): 题目多时给下拉进度框直接跳页,
              // 选项多时这一页内部可滚动, 不会把屏幕顶爆。
              Row({ space: Space.SM }) {
                if (this.interactionTotal(item) > 2) {
                  // 下拉进度框: 第 1 题 / 第 2 题 … 点一下直接跳
                  Select(this.interactionPageOptions(item))
                    .selected(this.interactionPageOf(item.eventId))
                    .value(this.interactionPageLabel(item))
                    .font({ size: FontSize.TINY })
                    .optionFont({ size: FontSize.SMALL })
                    .selectedOptionFont({ size: FontSize.SMALL })
                    .onSelect((index: number) => {
                      this.setInteractionPage(item.eventId, index);
                    })
                } else if (this.interactionTotal(item) > 1) {
                  Text(`第 ${this.interactionPageOf(item.eventId) + 1} / ${this.interactionTotal(item)} 题`)
                    .fontSize(FontSize.TINY)
                    .fontColor('#6B7280')
                } else {
                  Text('')
                    .fontSize(FontSize.TINY)
                }
                Blank()
                Text('可跳过')
                  .fontSize(FontSize.TINY)
                  .fontColor('#9CA3AF')
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Scroll() {
                Column({ space: 6 }) {
                  ForEach(this.interactionQuestionRows(item), (row: AskRow) => {
                    if (row.kind === 'qhead') {
                      Text(row.text)
                        .fontSize(FontSize.TINY)
                        .fontColor('#6B7280')
                        .width('100%')
                    } else if (row.kind === 'q') {
                      Text(row.text)
                        .fontSize(FontSize.BODY)
                        .fontColor('#111827')
                        .width('100%')
                    } else if (row.kind === 'option') {
                      Row({ space: Space.SM }) {
                        Text(row.checked ? (row.multi ? '☑' : '●') : (row.multi ? '☐' : '○'))
                          .fontSize(FontSize.BODY)
                          .fontColor(row.checked ? '#2563EB' : '#6B7280')
                        // 选项要连说明一起显示(label + description), 只显示 "A" 是不够的。
                        Text(row.text)
                          .fontSize(FontSize.BODY)
                          .fontColor('#111827')
                          .layoutWeight(1)
                        if (row.sub.length > 0) {
                          Text(row.sub)
                            .fontSize(FontSize.SMALL)
                            .fontColor('#6B7280')
                            .layoutWeight(1)
                        }
                      }
                      .width('100%')
                      .padding({ left: Space.SM, right: Space.SM, top: 8, bottom: 8 })
                      .backgroundColor(row.checked ? '#DBEAFE' : '#FFFFFF')
                      .borderRadius(Radius.SM)
                      .border({ width: 1, color: row.checked ? '#2563EB' : '#E5E7EB' })
                      .onClick(() => { this.toggleInteractionPick(row); })
                    } else if (row.kind === 'custom') {
                      TextInput({ placeholder: '也可以自己写一句(可选)', text: this.interactionCustomOf(row.callId, row.qid) })
                        .fontSize(FontSize.SMALL)
                        .fontColor('#111827')
                        .placeholderColor('#9CA3AF')
                        .height(38)
                        .backgroundColor('#FFFFFF')
                        .borderRadius(Radius.SM)
                        .border({ width: 1, color: '#E5E7EB' })
                        .onChange((value: string) => { this.setInteractionCustom(row.callId, row.qid, value); })
                    }
                  }, (row: AskRow): string => `${row.key}|${row.checked ? 1 : 0}`)
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .constraintSize({ maxHeight: 300 })
              .scrollBar(BarState.Auto)
              .align(Alignment.TopStart)

              Row({ space: Space.SM }) {
                if (this.interactionPageOf(item.eventId) > 0) {
                  Button('上一步')
                    .type(ButtonType.Normal)
                    .height(38)
                    .layoutWeight(1)
                    .borderRadius(Radius.SM)
                    .backgroundColor('#E5E7EB')
                    .fontColor('#111827')
                    .fontSize(FontSize.SMALL)
                    .onClick(() => { this.moveInteractionPage(item.eventId, -1); })
                }
                Button('跳过这道')
                  .type(ButtonType.Normal)
                  .height(38)
                  .layoutWeight(1)
                  .borderRadius(Radius.SM)
                  .backgroundColor('#F3F4F6')
                  .fontColor('#374151')
                  .fontSize(FontSize.SMALL)
                  .enabled(this.approvalBusy.length === 0)
                  .onClick(() => { void this.skipInteractionQuestion(item); })
                if (this.interactionPageOf(item.eventId) < this.interactionTotal(item) - 1) {
                  Button('下一步')
                    .type(ButtonType.Normal)
                    .height(38)
                    .layoutWeight(1)
                    .borderRadius(Radius.SM)
                    .backgroundColor('#2563EB')
                    .fontColor('#FFFFFF')
                    .fontSize(FontSize.SMALL)
                    .onClick(() => { this.moveInteractionPage(item.eventId, 1); })
                } else {
                  Button('提交答案')
                    .type(ButtonType.Normal)
                    .height(38)
                    .layoutWeight(1)
                    .borderRadius(Radius.SM)
                    .backgroundColor('#2563EB')
                    .fontColor('#FFFFFF')
                    .fontSize(FontSize.SMALL)
                    .enabled(this.approvalBusy.length === 0)
                    .onClick(() => { void this.answerInteractionQuestion(item); })
                }
              }
              .width('100%')
            } else {
              Text(this.approvalReason(item))
                .fontSize(FontSize.SMALL)
                .fontColor('#374151')
                .width('100%')
                .maxLines(4)
                .textOverflow({ overflow: TextOverflow.Ellipsis })

              Row({ space: Space.SM }) {
                Button('允许一次')
                  .type(ButtonType.Normal)
                  .height(38)
                  .layoutWeight(1)
                  .borderRadius(Radius.SM)
                  .backgroundColor('#16A34A')
                  .fontColor('#FFFFFF')
                  .fontSize(FontSize.SMALL)
                  .enabled(this.approvalBusy.length === 0)
                  .onClick(() => { void this.answerApproval(item.eventId, 'allowed-once'); })
                Button('拒绝')
                  .type(ButtonType.Normal)
                  .height(38)
                  .layoutWeight(1)
                  .borderRadius(Radius.SM)
                  .backgroundColor('#DC2626')
                  .fontColor('#FFFFFF')
                  .fontSize(FontSize.SMALL)
                  .enabled(this.approvalBusy.length === 0)
                  .onClick(() => { void this.answerApproval(item.eventId, 'rejected'); })
              }
              .width('100%')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: Space.SM, right: Space.SM, top: 10, bottom: 10 })
          .backgroundColor(item.kind === 'question' ? '#F8FAFC' : '#FEF3C7')
          .borderRadius(Radius.SM)
          .border({ width: 1, color: item.kind === 'question' ? '#2563EB' : '#F59E0B' })
        }, (item: ApprovalRequest): string => `${item.eventId}|${item.remainingMs}|${item.kind ?? ''}`)
      }
      .width('100%')
      .padding(Space.MD)
      .backgroundColor(this.pal('SURFACE'))
      .borderRadius(Radius.MD)
      .border({ width: 1, color: '#F59E0B' })
    }
  }

  /** 审批原因: 优先中文展示文案, 其次机器原因。 */
  private approvalReason(item: ApprovalRequest): string {
    if (item.displayReason !== undefined && item.displayReason !== null) {
      const zh: string | undefined = item.displayReason.zh;
      if (zh !== undefined && zh.length > 0) {
        return zh;
      }
    }
    return item.reason.length > 0 ? item.reason : '桌面端请求更高权限执行这次操作。';
  }

  /** 桌面 ask 弹窗(ABCD)摊平成行: 题头 / 题干 / 选项。 */
  /** 这个请求一共有几道题 */
  private interactionTotal(item: ApprovalRequest): number {
    return item.questions === undefined || item.questions === null ? 0 : item.questions.length;
  }

  /** 这个请求当前停在第几题(0 起) */
  private interactionPageOf(eventId: string): number {
    for (let i = 0; i < this.interactionPages.length; i++) {
      if (this.interactionPages[i].eventId === eventId) {
        return this.interactionPages[i].index;
      }
    }
    return 0;
  }

  /** 下拉进度框的选项: 第 1 题 / 第 2 题 … */
  private interactionPageOptions(item: ApprovalRequest): SelectOption[] {
    const out: SelectOption[] = [];
    const total: number = this.interactionTotal(item);
    for (let i = 0; i < total; i++) {
      out.push({ value: `第 ${i + 1} 题` });
    }
    return out;
  }

  /** 下拉进度框当前显示的文案 */
  private interactionPageLabel(item: ApprovalRequest): string {
    return `第 ${this.interactionPageOf(item.eventId) + 1} / ${this.interactionTotal(item)} 题`;
  }

  /** 直接跳到某一页(下拉框用) */
  private setInteractionPage(eventId: string, index: number): void {
    const total: number = (() => {
      for (let i = 0; i < this.approvals.length; i++) {
        if (this.approvals[i].eventId === eventId) {
          return this.interactionTotal(this.approvals[i]);
        }
      }
      return 0;
    })();
    const next: number = Math.max(0, Math.min(index, Math.max(0, total - 1)));
    let found: boolean = false;
    const list: AskPageEntry[] = [];
    for (let i = 0; i < this.interactionPages.length; i++) {
      const entry: AskPageEntry = this.interactionPages[i];
      if (entry.eventId === eventId) {
        found = true;
        list.push({ eventId: eventId, index: next });
      } else {
        list.push(entry);
      }
    }
    if (!found) {
      list.push({ eventId: eventId, index: next });
    }
    this.interactionPages = list;
  }

  /** 翻页(翻到几就记几) */
  private moveInteractionPage(eventId: string, delta: number): void {
    const next: number = Math.max(0, this.interactionPageOf(eventId) + delta);
    let found: boolean = false;
    const list: AskPageEntry[] = [];
    for (let i = 0; i < this.interactionPages.length; i++) {
      const entry: AskPageEntry = this.interactionPages[i];
      if (entry.eventId === eventId) {
        found = true;
        list.push({ eventId: eventId, index: next });
      } else {
        list.push(entry);
      }
    }
    if (!found) {
      list.push({ eventId: eventId, index: next });
    }
    this.interactionPages = list;
  }

  /** 跳过当前这一题: 记下来, 然后翻到下一题(最后一题就直接提交)。 */
  private async skipInteractionQuestion(item: ApprovalRequest): Promise<void> {
    const questions: AskQuestion[] = item.questions === undefined || item.questions === null
      ? [] : item.questions;
    const page: number = this.interactionPageOf(item.eventId);
    const q: AskQuestion | undefined = questions.length > page ? questions[page] : undefined;
    if (q !== undefined) {
      const key: string = `${item.eventId}|${q.id}`;
      if (this.interactionSkipped.indexOf(key) < 0) {
        this.interactionSkipped = this.interactionSkipped.concat([key]);
      }
    }
    if (page < questions.length - 1) {
      this.moveInteractionPage(item.eventId, 1);
      return;
    }
    await this.answerInteractionQuestion(item);
  }

  private interactionQuestionRows(item: ApprovalRequest): AskRow[] {
    const out: AskRow[] = [];
    const questions: AskQuestion[] = item.questions === undefined || item.questions === null
      ? [] : item.questions;
    // 一题一页: 只渲染当前这一题。
    const page: number = Math.min(this.interactionPageOf(item.eventId), Math.max(0, questions.length - 1));
    for (let i = page; i < page + 1; i++) {
      if (i >= questions.length) break;
      const q: AskQuestion = questions[i];
      if (q.header !== undefined && q.header.length > 0) {
        out.push({
          kind: 'qhead', key: `ih:${item.eventId}:${q.id}`, text: q.header, sub: '',
          callId: item.eventId, qid: q.id, label: '', multi: false, checked: false, enabled: true
        });
      }
      out.push({
        kind: 'q', key: `iq:${item.eventId}:${q.id}`, text: q.question, sub: '',
        callId: item.eventId, qid: q.id, label: '', multi: false, checked: false, enabled: true
      });
      const options: AskOption[] = q.options === undefined || q.options === null ? [] : q.options;
      for (let k = 0; k < options.length; k++) {
        const option: AskOption = options[k];
        out.push({
          kind: 'option', key: `io:${item.eventId}:${q.id}:${k}`, text: option.label,
          sub: option.description === undefined ? '' : option.description,
          callId: item.eventId, qid: q.id, label: option.label,
          multi: q.multiSelect === true,
          checked: this.interactionPicks.indexOf(`${item.eventId}|${q.id}|${option.label}`) >= 0,
          enabled: true
        });
      }
      out.push({
        kind: 'custom', key: `ic:${item.eventId}:${q.id}`, text: '', sub: '',
        callId: item.eventId, qid: q.id, label: '', multi: false, checked: false, enabled: true
      });
    }
    return out;
  }

  /** 桌面 ask 弹窗: 某道题的文字回答。 */
  private interactionCustomOf(eventId: string, qid: string): string {
    const key: string = `${eventId}|${qid}`;
    for (let i = 0; i < this.interactionCustoms.length; i++) {
      if (this.interactionCustoms[i].key === key) {
        return this.interactionCustoms[i].text.trim();
      }
    }
    return '';
  }

  /** 桌面 ask 弹窗: 记下某道题的文字回答。 */
  private setInteractionCustom(eventId: string, qid: string, value: string): void {
    const key: string = `${eventId}|${qid}`;
    const next: AskCustomEntry[] = [];
    let found: boolean = false;
    for (let i = 0; i < this.interactionCustoms.length; i++) {
      const entry: AskCustomEntry = this.interactionCustoms[i];
      if (entry.key === key) {
        found = true;
        if (value.length > 0) {
          next.push({ key: key, text: value });
        }
      } else {
        next.push(entry);
      }
    }
    if (!found && value.length > 0) {
      next.push({ key: key, text: value });
    }
    this.interactionCustoms = next;
  }

  /** 勾选 / 取消勾选一个选项(单选时同题只留一个)。 */
  private toggleInteractionPick(row: AskRow): void {
    const key: string = `${row.callId}|${row.qid}|${row.label}`;
    const idx: number = this.interactionPicks.indexOf(key);
    if (idx >= 0) {
      this.interactionPicks = this.interactionPicks.filter((v: string): boolean => v !== key);
      return;
    }
    let next: string[] = this.interactionPicks;
    if (!row.multi) {
      const prefix: string = `${row.callId}|${row.qid}|`;
      next = next.filter((v: string): boolean => !v.startsWith(prefix));
    }
    next = next.concat([key]);
    this.interactionPicks = next;
  }

  /** 每道题都选了吗(没有选项的题算过, 交给文字回答)。 */
  private interactionComplete(item: ApprovalRequest): boolean {
    const questions: AskQuestion[] = item.questions === undefined || item.questions === null
      ? [] : item.questions;
    for (let i = 0; i < questions.length; i++) {
      const q: AskQuestion = questions[i];
      const options: AskOption[] = q.options === undefined || q.options === null ? [] : q.options;
      if (options.length === 0) {
        continue;
      }
      let picked: boolean = false;
      for (let k = 0; k < options.length; k++) {
        if (this.interactionPicks.indexOf(`${item.eventId}|${q.id}|${options[k].label}`) >= 0) {
          picked = true;
          break;
        }
      }
      if (!picked) {
        return false;
      }
    }
    return questions.length > 0;
  }

  /** 把勾选提交给桌面(等同在电脑上点那张 ask 弹窗)。 */
  private async answerInteractionQuestion(item: ApprovalRequest): Promise<void> {
    if (this.approvalBusy.length > 0) {
      return;
    }
    this.approvalBusy = item.eventId;
    try {
      const questions: AskQuestion[] = item.questions === undefined || item.questions === null
        ? [] : item.questions;
      const answers: AskAnswer[] = [];
      for (let i = 0; i < questions.length; i++) {
        const q: AskQuestion = questions[i];
        const selected: string[] = [];
        const prefix: string = `${item.eventId}|${q.id}|`;
        for (let k = 0; k < this.interactionPicks.length; k++) {
          const entry: string = this.interactionPicks[k];
          if (entry.startsWith(prefix)) {
            selected.push(entry.substring(prefix.length));
          }
        }
        const answer: AskAnswer = { id: q.id, selected: selected };
        const text: string = this.interactionCustomOf(item.eventId, q.id);
        if (text.length > 0) {
          answer.custom = text;
        }
        answers.push(answer);
      }
      await AppState.client.answerInteractionQuestion(item.eventId, answers);
      this.interactionPicks = this.interactionPicks.filter((v: string): boolean => !v.startsWith(`${item.eventId}|`));
      this.interactionCustoms = this.interactionCustoms.filter((e: AskCustomEntry): boolean => !e.key.startsWith(`${item.eventId}|`));
      this.interactionPages = this.interactionPages.filter((e: AskPageEntry): boolean => e.eventId !== item.eventId);
      this.interactionSkipped = this.interactionSkipped.filter((k: string): boolean => !k.startsWith(`${item.eventId}|`));
      this.toast('已提交选择');
      await this.loadApprovals();
    } catch (e) {
      this.toast('这条已经处理过了（可能是在电脑上点的）');
      await this.loadApprovals();
    } finally {
      this.approvalBusy = '';
    }
  }

  @Builder
  askPanel() {
    if (this.askCalls.length > 0) {
      Column({ space: Space.SM }) {
        Row({ space: Space.SM }) {
          Text('需要你选择')
            .fontSize(FontSize.SMALL)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal('WARN'))
          Text(`共 ${this.askCalls.length} 个等待回答`)
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column({ space: Space.XS }) {
            ForEach(this.askRows(), (row: AskRow) => {
              if (row.kind === 'header') {
                Text(row.text)
                  .fontSize(FontSize.SMALL)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.pal('TEXT'))
                  .width('100%')
                Text(row.sub)
                  .fontSize(FontSize.TINY)
                  .fontColor(this.pal('TEXT_3'))
                  .width('100%')
              } else if (row.kind === 'qhead') {
                Text(row.text)
                  .fontSize(FontSize.TINY)
                  .fontColor(this.pal('TEXT_3'))
                  .width('100%')
              } else if (row.kind === 'q') {
                Text(row.text)
                  .fontSize(FontSize.BODY)
                  .fontColor(this.pal('TEXT'))
                  .width('100%')
                if (row.sub.length > 0) {
                  Text(row.sub)
                    .fontSize(FontSize.SMALL)
                    .fontColor(this.pal('TEXT_2'))
                    .width('100%')
                }
              } else if (row.kind === 'hint') {
                Text(row.text)
                  .fontSize(FontSize.SMALL)
                  .fontColor(this.pal('TEXT_3'))
                  .width('100%')
                  .padding(Space.XS)
              } else if (row.kind === 'option') {
                Row({ space: Space.SM }) {
                  Text(row.checked ? (row.multi ? '☑' : '●') : (row.multi ? '☐' : '○'))
                    .fontSize(FontSize.BODY)
                    .fontColor(row.checked ? this.pal('ACCENT') : this.pal('TEXT_3'))
                  // 选项文字: 硬编码高对比配色(不依赖主题 token), 真机上才稳定可见。
                  Text(row.text)
                    .fontSize(FontSize.BODY)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#111827')
                    .textAlign(TextAlign.Start)
                    .layoutWeight(1)
                  if (row.sub.length > 0) {
                    Text(row.sub)
                      .fontSize(FontSize.SMALL)
                      .fontColor('#6B7280')
                      .layoutWeight(1)
                  }
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .padding({ left: Space.SM, right: Space.SM, top: 10, bottom: 10 })
                .constraintSize({ minHeight: 46 })
                .backgroundColor(row.checked ? '#DBEAFE' : '#F3F4F6')
                .borderRadius(Radius.SM)
                .border({ width: 1, color: row.checked ? this.pal('ACCENT') : this.pal('BORDER_SOFT') })
                .onClick(() => { this.toggleAsk(row); })
              } else if (row.kind === 'custom') {
                // 每题一个独立「其他」输入框(官方 custom 是每题独立的)。
                TextInput({ placeholder: '这题也可以自己写一句(可选)', text: this.askCustomOf(row.callId, row.qid) })
                  .fontSize(FontSize.SMALL)
                  .fontColor(this.pal('TEXT'))
                  .placeholderColor(this.pal('PLACEHOLDER'))
                  .height(40)
                  .backgroundColor(this.pal('CARD'))
                  .borderRadius(Radius.SM)
                  .border({ width: 1, color: this.pal('BORDER_SOFT') })
                  .onChange((value: string) => { this.setAskCustom(row.callId, row.qid, value); })
              } else {
                Row() {
                  Text(this.askBusy ? '提交中…' : row.text)
                    .fontSize(FontSize.BODY)
                    .fontColor(row.enabled ? '#FFFFFF' : this.pal('TEXT_3'))
                }
                .width('100%')
                .height(44)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(row.enabled ? this.pal('ACCENT_SOLID') : this.pal('SURFACE_HI'))
                .borderRadius(Radius.PILL)
                .onClick(() => {
                  if (row.enabled) {
                    void this.submitAsk(row.callId);
                  }
                })
              }
            }, (row: AskRow): string => `${row.key}|${row.checked ? 1 : 0}|${row.enabled ? 1 : 0}|${row.kind}`)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .constraintSize({ maxHeight: 260 })
        .scrollBar(BarState.Off)

      }
      .width('100%')
      .padding(Space.MD)
      .backgroundColor(this.pal('SURFACE'))
      .borderRadius(Radius.MD)
      .border({ width: 1, color: this.pal('WARN') })
    }
  }

  /* --------------------------------------------------------------- 队列面板 */

  @Builder
  queuePanel() {
    if (this.queueCount() > 0) {
      Column({ space: Space.SM }) {
        Row({ space: Space.SM }) {
          Text(`队列中排队的任务 · ${this.queueCount()}`)
            .fontSize(FontSize.SMALL)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pal('CONTEXT'))
          Blank()
          Text(this.queueOpen ? '收起' : '展开')
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('ACCENT'))
            .onClick(() => { this.queueOpen = !this.queueOpen; })
        }
        .width('100%')

        if (this.queueOpen) {
          Column({ space: Space.SM }) {
            ForEach(this.queueRows(), (item: QueueItem) => {
              this.queueItem(item, item.target === 'next-step' ? '下一步' : '下一轮')
            }, (item: QueueItem) => item.id)
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding(Space.MD)
      .margin({ bottom: Space.SM })
      .backgroundColor(this.pal('SURFACE'))
      .borderRadius(Radius.LG)
      .border({ width: 1, color: this.pal('BORDER_SOFT') })
    }
  }

  /** 队列里的一条任务 */
  @Builder
  queueItem(item: QueueItem, target: string) {
    Column({ space: 4 }) {
      if (this.editingId === item.id) {
        // 就地编辑
        TextArea({ placeholder: '改这条任务', text: this.editingText })
          .fontSize(FontSize.SMALL)
          .fontColor(this.pal('TEXT'))
          .placeholderColor(this.pal('PLACEHOLDER'))
          .backgroundColor(this.pal('SURFACE'))
          .width('100%')
          .height(56)
          .onChange((value: string) => { this.editingText = value; })
        Row({ space: Space.MD }) {
          Text('保存')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('ACCENT'))
            .onClick(() => {
              const text: string = this.editingText;
              this.editingId = '';
              void this.applyQueueAction(item, 'edit', text);
            })
          Text('取消')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .onClick(() => { this.editingId = ''; })
        }
        .width('100%')
      } else {
        Row({ space: Space.SM }) {
          Text(target)
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(this.pal('SURFACE_HI'))
            .borderRadius(Radius.SM)
          if (item.at > 0) {
            // 什么时候发出去的 ⇒ 队列按时间排的时候, 人也能看见这个时间 ✓
            Text(formatTime(item.at))
              .fontSize(FontSize.TINY)
              .fontColor(this.pal('TEXT_3'))
          }
          Text(item.text)
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('TEXT'))
            .layoutWeight(1)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Row({ space: Space.MD }) {
          Text('编辑')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('ACCENT'))
            .onClick(() => { void this.queueAction(item, 'edit'); })
          Text('插队')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('ACCENT'))
            .onClick(() => { void this.queueAction(item, 'steer'); })
          Text('删除')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('ERROR'))
            .onClick(() => { void this.queueAction(item, 'remove'); })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(Space.SM)
    .backgroundColor(this.pal('BG_DEEP'))
    .borderRadius(Radius.MD)
  }

  /* --------------------------------------------------------------- + 号面板 / 弹层 */

  /**
   * 「+ 号」的面板浮层。
   *
   * 不用 bindSheet —— 宽屏下它是按**整个窗口**定位的, 会压到左边的会话列表上。
   * 这里改成自己画一个, 挂在页面根容器(Stack)上:
   *   - 浮层的 100%/100% 就是**会话详情栏**这一栏 ⇒ 宽屏下只压右栏, 竖屏下占满整屏;
   *   - 面板本身底部对齐, 高 72%(和模型选择面板一致), 里面的候选列表可以滚。
   */
  @Builder
  plusOverlay() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 背景: 点一下关掉
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#00000055')
        .onClick(() => { this.plusOpen = false; })

      // 面板: 底部对齐, 高 72%
      Column() {
        this.plusSheet()
      }
      .width('100%')
      .height('72%')
      .backgroundColor(this.pal('BG_DEEP'))
      .borderRadius(Radius.LG)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  plusSheet() {
    Column({ space: Space.SM }) {
      Text('添加文件或调用指令')
        .fontSize(FontSize.TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.pal('TEXT'))
        .width('100%')

      Row({ space: Space.MD }) {
        this.plusQuickButton('图片', this.uploading ? '上传中…' : '+ 相册', () => { void this.pickImageToUpload(); })
        this.plusQuickButton('文件', '+ 文件', () => { void this.pickFileToUpload(); })
      }
      .width('100%')
      .padding({ bottom: Space.SM })

      Row({ space: Space.XL }) {
        this.plusTabButton('指令', 0)
        this.plusTabButton('技能', 1)
        this.plusTabButton('文件', 2)
      }
      .width('100%')
      .padding({ bottom: Space.SM })

      if (this.plusTab === 2) {
        // 双向绑定: text 的值和状态是同一个, 不要再用 onChange 把它写回去 ——
        // 那样每次输入都会在渲染里改状态, 轻则光标乱跳, 重则把 App 弄崩 ✓
        TextInput({ placeholder: '按路径筛选, 例如 src/ 或者 README', text: $$this.fileQuery })
          .height(40)
          .fontSize(FontSize.SMALL)
          .fontColor(this.pal('TEXT'))
          .placeholderColor(this.pal('PLACEHOLDER'))
          .backgroundColor(this.pal('BG_DEEP'))
          .border({ width: 1, color: this.pal('BORDER') })
          .borderRadius(Radius.SM)
          .onSubmit(() => { void this.searchFiles(); })
      }

      if (this.plusLoading) {
        Column() {
          LoadingProgress()
            .width(24)
            .height(24)
            .color(this.pal('ACCENT'))
        }
        .width('100%')
        .padding({ top: 40 })
      } else {
        Scroll() {
          Column({ space: Space.SM }) {
            // 三种候选统一成一份列表: ForEach 放在分支里会在 ArkUI 里崩
            ForEach(this.pickItems, (item: PickItem) => {
              this.pickRow(item.title, item.subtitle, () => { this.insertToDraft(item.insert + ' '); })
            }, (item: PickItem) => item.id)

            if (this.pickItems.length === 0) {
              Text(this.pickEmpty)
                .fontSize(FontSize.SMALL)
                .fontColor(this.pal('TEXT_3'))
            }

            if (this.pickMore.length > 0) {
              Text(this.pickMore)
                .fontSize(FontSize.TINY)
                .fontColor(this.pal('TEXT_3'))
                .margin({ top: Space.SM })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .align(Alignment.TopStart)
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    // 面板本身有确定高度 ⇒ 里面的 Scroll(layoutWeight 1)才有高度可滚, 候选列表不会被压扁
    .height('100%')
    .padding(Space.MD)
  }

  @Builder
  plusQuickButton(title: string, subtitle: string, action: () => void) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(FontSize.SMALL)
        .fontColor(this.pal('TEXT_2'))
      Text(subtitle)
        .fontSize(FontSize.TINY)
        .fontColor(this.pal('TEXT_3'))
    }
    .padding({ left: Space.MD, right: Space.MD, top: Space.SM, bottom: Space.SM })
    .backgroundColor(this.pal('SURFACE_HI'))
    .borderRadius(Radius.MD)
    .onClick(() => { action(); })
  }

  @Builder
  plusTabButton(label: string, index: number) {
    Text(label)
      .fontSize(FontSize.BODY)
      .fontWeight(this.plusTab === index ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.plusTab === index ? this.pal('TEXT') : this.pal('TEXT_3'))
      .padding({ left: Space.SM, right: Space.SM, top: 4, bottom: 4 })
      .backgroundColor(this.plusTab === index ? this.pal('SURFACE_HI') : Color.Transparent)
      .borderRadius(Radius.SM)
      .onClick(() => { this.setPlusTab(index); })
  }

  /** 一行可点的条目 */
  @Builder
  pickRow(title: string, subtitle: string, action: () => void) {
    Row() {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(FontSize.BODY)
          .fontColor(this.pal('TEXT'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(Space.SM)
    .backgroundColor(this.pal('SURFACE'))
    .borderRadius(Radius.MD)
    .onClick(action)
  }

  /* --------------------------------------------------------------- 模型面板 */

  @Builder
  modelSheet() {
    Column({ space: Space.SM }) {
      Text('选择模型')
        .fontSize(FontSize.TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.pal('TEXT'))
        .width('100%')

      Scroll() {
        Column({ space: Space.MD }) {
          if (this.catalog === null) {
            Column() {
              LoadingProgress()
                .width(24)
                .height(24)
                .color(this.pal('ACCENT'))
            }
            .width('100%')
            .padding({ top: 40 })
          } else {
            ForEach(this.catalog.providers, (p: ModelProvider) => {
              Column({ space: Space.SM }) {
                Text(p.name)
                  .fontSize(FontSize.SMALL)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.pal('TEXT_2'))
                  .width('100%')
                ForEach(p.models, (m: ModelEntry) => {
                  this.modelRow(p, m.id, m.name, m.efforts, m.defaultEffort)
                }, (m: ModelEntry) => m.id)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }, (p: ModelProvider) => p.id)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .align(Alignment.TopStart)
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding(Space.MD)
  }

  /** 一个模型 + 它的推理强度 */
  @Builder
  modelRow(provider: ModelProvider, modelId: string, modelName: string,
    efforts: ModelEffort[], defaultEffort: string) {
    Column({ space: Space.XS }) {
      Row({ space: Space.SM }) {
        Text(modelName)
          .fontSize(FontSize.BODY)
          .fontColor(this.modelName === modelId ? this.pal('ACCENT') : this.pal('TEXT'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.modelName === modelId) {
          Text('当前')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('ACCENT'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(this.pal('SURFACE_HI'))
            .borderRadius(Radius.SM)
        }
      }
      .width('100%')

      if (efforts.length > 0 && this.modelName === modelId) {
        Row({ space: Space.SM }) {
          ForEach(efforts, (e: ModelEffort) => {
            Text(e.name)
              .fontSize(FontSize.TINY)
              .fontColor(this.modelEffort === e.id ? this.pal('ACCENT') : this.pal('TEXT_3'))
              .padding({ left: Space.SM, right: Space.SM, top: 4, bottom: 4 })
              .backgroundColor(this.modelEffort === e.id ? this.pal('SURFACE_HI') : Color.Transparent)
              .borderRadius(Radius.SM)
              .onClick(() => { void this.chooseModel(provider.id, modelId, e.id); })
          }, (e: ModelEffort) => e.id)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(Space.SM)
    .backgroundColor(this.pal('SURFACE'))
    .borderRadius(Radius.MD)
    .onClick(() => {
      const effort: string = this.modelEffort.length > 0 && this.modelName === modelId
        ? this.modelEffort
        : defaultEffort;
      void this.chooseModel(provider.id, modelId, effort);
    })
  }

  /** 顶部的一个标签 */
  @Builder
  tabButton(label: string, index: number) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(FontSize.BODY)
        .fontWeight(this.tab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.tab === index ? this.pal('TEXT') : this.pal('TEXT_3'))
      Blank().height(2)
      if (this.tab === index) {
        Divider()
          .strokeWidth(2)
          .color(this.pal('ACCENT'))
          .width(22)
      }
    }
    .onClick(() => {
      this.tab = index;
    })
  }

  /** 对话视图 */
  @Builder
  conversationView() {
    if (this.messages.length === 0) {
      Column({ space: Space.SM }) {
        Text('还没有消息')
          .fontSize(FontSize.BODY)
          .fontColor(this.pal('TEXT_3'))
        Text('在下面输入一条指令, 桌面端会立刻执行')
          .fontSize(FontSize.SMALL)
          .fontColor(this.pal('TEXT_3'))
      }
      .width('100%')
      .padding({ top: 80 })
    } else {
      Stack({ alignContent: Alignment.BottomEnd }) {
        List({ scroller: this.scroller, space: Space.MD }) {
          ForEach(this.messages, (m: DisplayMessage) => {
            ListItem() {
              this.messageBlock(m)
            }
          }, (m: DisplayMessage) => this.messageKey(m))
        }
        .width('100%')
        .height('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD })
        .scrollBar(BarState.Off)
        .onScrollIndex((_first: number, last: number) => {
          // 最后一条可见 = 已经在最底 ⇒ 不需要浮按钮
          const bottom: boolean = last >= this.messages.length - 1;
          if (bottom !== this.atBottom) {
            this.atBottom = bottom;
          }
        })
        .onAreaChange(() => {
          // 布局好了才滚得动(V1 的坑 ✓): 第一次进来要停在最新那条 ✓
          if (this.pendingScroll) {
            this.doScrollToEnd();
          }
        })

        // 不在最底时: 一键回到最新消息
        if (!this.atBottom) {
          Row({ space: 4 }) {
            Text('↓')
              .fontSize(18)
              .fontColor('#FFFFFF')
            Text('最新')
              .fontSize(FontSize.SMALL)
              .fontColor('#FFFFFF')
          }
          .padding({ left: 12, right: 14, top: 8, bottom: 8 })
          .backgroundColor(this.pal('ACCENT_SOLID'))
          .borderRadius(Radius.PILL)
          .shadow({ radius: 12, color: '#66000000', offsetX: 0, offsetY: 4 })
          .margin({ right: Space.MD, bottom: Space.MD })
          .onClick(() => {
            this.atBottom = true;
            this.scrollToEnd();
          })
        }
      }
      .width('100%')
      .height('100%')
    }
  }

  /**
   * 「点开更多」/「收起」/取全文失败的提示。
   *
   * 只就地展开这一条 —— 别的还是预览 ✓
   */
  @Builder
  moreButton(m: DisplayMessage) {
    if (this.needsMore(m) && !m.expanded) {
      Row({ space: Space.XS }) {
        Text('…点开更多')
          .fontSize(FontSize.SMALL)
          .fontColor(this.pal('ACCENT'))
          .onClick(() => { this.toggleFull(m); })
        if (m.loadingFull) {
          LoadingProgress()
            .width(12)
            .height(12)
            .color(this.pal('ACCENT'))
        }
      }
    } else if (m.expanded) {
      Text('收起')
        .fontSize(FontSize.SMALL)
        .fontColor(this.pal('ACCENT'))
        .onClick(() => { this.toggleFull(m); })
    }
    if (m.fullError.length > 0) {
      Text(m.fullError)
        .fontSize(FontSize.TINY)
        .fontColor(this.pal('TEXT_3'))
    }
  }

  /** 一条消息 */
  @Builder
  messageBlock(m: DisplayMessage) {
    Column({ space: Space.XS }) {
      if (m.role === 'user') {
        // 用户消息: 浮起的圆角面板, 时间与复制在面板下面
        Text(this.visibleText(m))
          .fontSize(FontSize.BODY)
          .fontColor(this.pal('TEXT'))
          .width('100%')
          .padding(Space.MD)
          .backgroundColor(this.pal('SURFACE'))
          .borderRadius(Radius.MD)
          // 长按可选中/复制(只给正文加, 别给按钮加, 不然按钮点不动 ✓)
          .copyOption(CopyOptions.LocalDevice)

        this.moreButton(m);

        Row({ space: Space.SM }) {
          Blank()
          Text(m.time)
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
          Text('复制')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .onClick(() => { this.copyText(m.text); })
        }
        .width('100%')
      } else if (m.kind === 'tool_call') {
        // 工具调用: 桌面端那样收成一行, 前缀一个 ›
        Row({ space: Space.SM }) {
          Text('›')
            .fontSize(FontSize.BODY)
            .fontColor(this.pal('TOOL'))
          Text(m.toolName.length > 0 ? m.toolName : '工具')
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('TOOL'))
          Text(SessionDetailView.toolArgs(m.text, m.toolName))
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('TEXT_3'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
      } else if (m.role === 'tool') {
        // 工具输出
        Column({ space: 2 }) {
          Text('工具输出')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TOOL'))
          if (m.expanded) {
            // 展开态给全文, 不再用 maxLines(3) 把内容硬切掉 ✓
            Text(m.text)
              .fontSize(FontSize.SMALL)
              .fontColor(this.pal('TEXT_3'))
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
          } else {
            Text(this.visibleText(m))
              .fontSize(FontSize.SMALL)
              .fontColor(this.pal('TEXT_3'))
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
          }
          this.moreButton(m);
        }
        .width('100%')
        .padding({ left: Space.SM })
        .border({ width: { left: 1 }, color: this.pal('BORDER') })
      } else {
        // 助手消息: 先状态行, 再正文
        Row({ space: Space.SM }) {
          Text('◆')
            .fontSize(FontSize.SMALL)
            .fontColor(m.streaming ? this.pal('ACCENT') : this.pal('ASSISTANT'))
          Text(this.statusLabel(m))
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('TEXT_2'))
          Text(m.time)
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
        }
        .width('100%')

        if (m.text.length > 0) {
          Text(this.visibleText(m))
            .fontSize(FontSize.BODY)
            .fontColor(this.pal('TEXT'))
            .width('100%')
            // 长按可选中/复制(只给正文加 ✓)
            .copyOption(CopyOptions.LocalDevice)
        } else if (!m.streaming) {
          // 这一步没有可见正文(只调了工具, 或者正文只有模型的内部思考) ⇒ 说清楚,
          // 别留一条空行让人以为漏了消息 ✓
          Text('（这一步没有正文）')
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('TEXT_3'))
            .width('100%')
        }

        this.moreButton(m);
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 轨迹视图: 一步一条 */
  @Builder
  traceView() {
    if (this.messages.length === 0) {
      Column() {
        Text('暂无轨迹')
          .fontSize(FontSize.BODY)
          .fontColor(this.pal('TEXT_3'))
      }
      .width('100%')
      .padding({ top: 80 })
    } else {
      List({ space: Space.SM }) {
        ForEach(this.messages, (m: DisplayMessage) => {
          ListItem() {
            Row({ space: Space.SM }) {
              Text(this.roleTag(m.role, m.kind))
                .fontSize(FontSize.TINY)
                .fontColor(this.roleTagColor(m.role, m.kind))
                .padding({ left: Space.SM, right: Space.SM, top: 2, bottom: 2 })
                .backgroundColor(this.pal('SURFACE'))
                .borderRadius(Radius.SM)
              // 轨迹里也按预览渲染: 一条几万字的消息直接铺出来会把列表拖死,
              // 点「点开更多」再看全文 ✓
              Column({ space: 2 }) {
                Text(this.visibleText(m))
                  .fontSize(FontSize.SMALL)
                  .fontColor(this.pal('TEXT_2'))
                  .width('100%')
                  .copyOption(CopyOptions.LocalDevice)
                this.moreButton(m);
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }
        }, (m: DisplayMessage) => this.messageKey(m))
      }
      .width('100%')
      .height('100%')
      .padding({ left: Space.LG, right: Space.LG, top: Space.MD })
      .scrollBar(BarState.Off)
    }
  }

  /** 底部状态条: 和桌面端一样显示轮次 / token / 上下文 */
  @Builder
  statusStrip() {
    Row({ space: Space.MD }) {
      if (this.stats !== null) {
        Text(`${this.stats.turns} 轮 ${this.stats.steps} 步`)
          .fontSize(FontSize.TINY)
          .fontColor(this.pal('TEXT_3'))
        Text(`${this.formatTokens(this.stats.outputTokens)} tok`)
          .fontSize(FontSize.TINY)
          .fontColor(this.pal('TEXT_3'))
        if (this.stats.contextWindow > 0) {
          Text(`上下文 ${this.formatTokens(this.stats.contextTokens)}/${this.formatTokens(this.stats.contextWindow)}`)
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
        }
        if (this.stats.model.length > 0) {
          Text(this.stats.model)
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
      } else {
        Text(`${this.messages.length} 条消息`)
          .fontSize(FontSize.TINY)
          .fontColor(this.pal('TEXT_3'))
        Blank()
      }
    }
    .width('100%')
    .padding({ left: Space.SM, right: Space.SM, top: Space.XS })
  }
}
