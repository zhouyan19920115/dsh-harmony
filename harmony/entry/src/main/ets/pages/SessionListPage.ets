/**
 * 会话列表页 —— 与桌面端 DeepSeek Harness 的深色界面保持一致。
 *
 * 桌面端的结构是: 侧边栏(工作区 -> 会话树) + 主内容区。
 * 手机上把侧边栏的信息压成一张列表: 顶部是标题栏, 下面按工作区(cwd)分组,
 * 组内是会话, 右侧是相对时间, 运行中的会话带一个转圈指示器。
 *
 * 数据来源:
 * - 首屏用 REST 拉一次全量;
 * - 之后由 WebSocket 推送 session.list / session.state 实时刷新。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppState } from '../common/AppState';
import { ApprovalRequest } from '../common/Models';
import { BridgeListener } from '../common/BridgeClient';
import {
  AgentPreset,
  BridgeMessage,
  ConversationNode,
  PermissionOption,
  QueueItem,
  QueueResponse,
  SessionSummary,
  SessionTopic,
  WorkspaceEntry
} from '../common/Models';
import { formatRelative } from '../common/TimeFmt';
import { describeError, describeSoftly } from '../common/ErrorText';
import { Palette, Space, Radius, FontSize } from '../common/Theme';
import { ThemeController } from '../common/ThemeController';
import { ReadStore } from '../common/ReadStore';
import { registerPushToken, setBadgeNumber } from '../common/Push';
import {
  markSessionState,
  notifyPendingSummary,
  notifyTaskFinished,
  PendingSession,
  PendingSummary,
  rememberSessionState,
  setCurrentSessionId,
  takeNotifiedSessionId,
  takePendingSessionId
} from '../common/LocalNotify';
import { BreakpointObserver } from '../common/Breakpoints';
import { SessionDetailView } from './SessionDetailView';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF03;

export interface SessionRouteParams {
  sessionId: string;
  title: string;
  cwd: string;
}

/**
 * 一条对话(把会话树和平铺列表统一成同一个形状)。
 *
 * 桌面端的侧边栏是两级结构: 一级是「对话」, 点开之后它下面的
 * 「话题/子任务」才出现。所以手机上也照这个来:
 * 工作区 -> 对话 -> (点开) 话题/子任务。
 */
interface ConversationLike {
  id: string;
  title: string;
  cwd: string;
  state: string;
  updatedAt: number;
  topics: SessionTopic[];
}

/** 活动面板里的一条(header 是小节标题, hint 是占位说明) */
interface ActivityItem {
  /** header | running | subagent | queue | question | hint */
  kind: string;
  key: string;
  title: string;
  subtitle: string;
  sessionId: string;
  cwd: string;
}

/** 活动面板里的一条排队任务 */
interface QueueActivityItem {
  sessionId: string;
  sessionTitle: string;
  text: string;
}

/**
 * 列表里的一行。
 *
 * 整个列表先摊平成一个数组再 ForEach —— 分支里放 ForEach 会让 App 崩。
 */
interface ListRow {
  /** workspace | conversation | topic */
  kind: string;
  /** 唯一 key */
  key: string;
  title: string;
  state: string;
  updatedAt: number;
  /** 缩进层级: 0 工作区, 1 对话, 2 话题 */
  depth: number;
  /** 能不能展开 */
  expandable: boolean;
  expanded: boolean;
  /** 点这一行要打开的会话 id */
  sessionId: string;
  /** 这条会话的工作目录 */
  cwd: string;
  /** 工作区行的会话数 */
  count: number;
  /** 是不是所在分组的第 1 行(卡片圆角靠它) */
  firstOfGroup: boolean;
  /** 是不是所在分组的最后 1 行(卡片圆角靠它) */
  lastOfGroup: boolean;
  /** 已完成但还没看过(琥珀色小点 + 「待看」) */
  unread: boolean;
  /** 桌面端在等用户回答(红点 + 「待确认」) */
  needsAnswer: boolean;
}

@Entry
@Component
struct SessionListPage {
  /** 状态栏高度(EntryAbility 量出来写进 AppStorage; 全屏后靠它让开通知栏) */
  @StorageProp('topSafeVp') topSafeVp: number = 0;
  /** 手势条高度 */
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 0;

  /** 主题版本号: ThemeController 切主题时 +1, build 里靠它整页重建 */
  @StorageLink('themeTick') themeTick: number = 0;

  /** 当前主题的吉祥物背景图 */
  private backdropImage(): Resource {
    return Palette.isDark() ? $r('app.media.mascot_night') : $r('app.media.mascot_day');
  }

  @State sessions: SessionSummary[] = [];
  /** 桌面端会话树(一级=对话, 二级=话题/子任务); 桥接还没上线时为空 */
  @State conversations: ConversationNode[] = [];
  /** 桥接是否支持 session-tree 端点(不支持就退回平铺列表) */
  @State treeSupported: boolean = false;
  @State connected: boolean = false;
  /** 连接状态的说法: 「已连接」/「重连中…」/「未连接」(自己存一份, 变了才会重画 ✓) */
  @State connectionText: string = '未连接';
  @State loading: boolean = true;
  @State message: string = '';
  @State showNew: boolean = false;
  /** 正在创建会话(防连点建两条) */
  @State creating: boolean = false;
  /** 非空 ⇒ 这次新建是「某个工作区的 ＋」点进来的, 工作区已经锁死, 不用再找 */
  @State newCwdLocked: string = '';
  @State newCwd: string = '';
  @State newTitle: string = '';
  @State workspaces: string[] = [];
  /** 工作区候选项(带标题) */
  @State workspaceEntries: WorkspaceEntry[] = [];
  /** 可选的模式(桌面端的 agent preset) */
  @State agentPresets: AgentPreset[] = [];
  /** 可选的权限预设 */
  @State permissionOptions: PermissionOption[] = [];
  /** 新建会话时选中的模式 */
  @State newPreset: string = '';
  /** 新建会话时选中的权限 */
  @State newPermission: string = '';
  /** 顶部显示的桌面端地址(改了地址后要重新取, 否则显示的还是旧值) */
  @State endpointLabel: string = '';
  /** 折叠起来的工作区(cwd) */
  @State collapsedKeys: string[] = [];
  /** 展开了话题的对话 id */
  @State expandedIds: string[] = [];
  /** 桌面端的待办数量(右上角角标): 正在跑的会话 + 排队中的任务 + 待确认的问题 */
  @State pendingCount: number = 0;
  /** 桥接推来的实时状态: 正在跑的会话 id */
  @State liveRunning: string[] = [];
  /** 桥接推来的实时状态: 在等用户回答的会话 */
  @State liveQuestions: PendingSession[] = [];
  /** 桌面端在等批准(内核审批): 独立于 ask 卡片, 谁先答谁生效 */
  @State liveApprovals: ApprovalRequest[] = [];
  private approvalTimer: number = -1;
  /** 桥接推来的待办总数 = 在跑 + 排队 + 待确认 */
  @State liveTotal: number = 0;
  /** 桥接直接给的排队数(>=0 就用它; -1 = 老桥接没给, 退回减法估算) */
  @State liveQueued: number = -1;
  /** 活动面板(点「运行中」那一格/右上角待办进入) */
  @State activityOpen: boolean = false;
  /** 排队任务明细(打开面板时按需拉) */
  @State queueItems: QueueActivityItem[] = [];
  @State queueLoading: boolean = false;

  /** 宽屏(窗口 >= 600vp)时用双栏: 左边列表, 右边详情, 不再跳路由 */
  @State wideLayout: boolean = false;
  /** 双栏模式下右栏当前显示的会话 */
  @State selectedId: string = '';
  @State selectedTitle: string = '';
  @State selectedCwd: string = '';
  /** 断点订阅 id */
  private bpListenerId: number = 0;

  private listener: BridgeListener = new BridgeListener();
  /** 上一轮每个会话的状态(running/idle), 用来识别「真正跑完了」 */
  private prevStates: Map<string, string> = new Map<string, string>();

  /**
   * 状态灯的颜色: 连上了是绿的, 重连中是黄的, 真没连上才是红的 ✓
   *
   * **为什么「重连中」不是红的**: 用户抱怨的就是"状态跳来跳去, 一会绿一会红, 以为坏了"。
   * 隧道掐连接是常事 ⇒ 重连中用黄色(中性的"正在处理")⇒ 红色只留给真的连不上 ✓
   */
  private connectionDotColor(): string {
    if (this.connectionText === '已连接') {
      return Palette.OK;
    }
    if (this.connectionText === '重连中…') {
      return Palette.WARN;
    }
    return Palette.ERROR;
  }

  /**
   * 状态旁边那行小字 ✓
   *
   * 明确说"对话数据照常加载, 不影响看进度" —— 这是用户最在意的那句话 ✓
   */
  private connectionHintText(): string {
    return AppState.client.connectionHint();
  }

  /** 窄屏时用户点开的那个会话(正在看它就不提醒)。 */
  private openedSessionId: string = '';

  async aboutToAppear(): Promise<void> {
    // 先把断点定下来: 宽屏双栏, 窄屏保持原来的单栏 + 路由跳转。
    // init() 是异步的, 这里不 await —— 页面要先出来, 断点到了再切布局。
    const bp = BreakpointObserver.getInstance();
    bp.initSync();
    this.wideLayout = bp.isWide();
    this.bpListenerId = bp.subscribe((_widthVp: number, _heightVp: number, isWide: boolean): void => {
      this.wideLayout = isWide;
      if (!isWide) {
        // 变回窄屏就清掉右栏的选中, 回到"点列表跳路由"的老行为
        this.selectedId = '';
        this.selectedTitle = '';
        this.selectedCwd = '';
      }
    });
    const host = this.getUIContext().getHostContext();
    if (host !== undefined) {
      bp.init(host as Context).then((): void => {
        this.wideLayout = bp.isWide();
      }).catch((err: Error): void => {
        hilog.warn(DOMAIN, TAG, '断点初始化失败: %{public}s', err.message ?? '');
      });
    }

    this.endpointLabel = AppState.client.getEndpointLabel();
    // 连接状态要**先读一次**现在的值: 这个页面可能是在 WebSocket 认证通过之后才打开的,
    // 那一次「已连接」的事件早就发过了 —— 只听事件的话, 界面会一直停在「未连接」,
    // 而实际上手机是连着的 ✓
    this.connected = AppState.client.isConnected();
    this.connectionText = AppState.client.connectionLabel();
    this.listener.onSessions = (list: SessionSummary[]): void => {
      this.sessions = list;
      this.loading = false;
      // 记住每个会话的状态, 后面才知道它是「刚刚跑完」的。
      for (let i = 0; i < list.length; i++) {
        rememberSessionState(list[i].id, list[i].state);
      }
      // 会话树模式下, 平铺列表只用来更新状态和标题。
      if (this.treeSupported) {
        this.applyFlatState();
      }
    };
    this.listener.onSessionState = (id: string, state: string, title: string): void => {
      // 刚才还在跑, 现在跑完了 → 弹一条本地通知。
      const justFinished: boolean = markSessionState(id, state);
      this.refresh();
      // 桌面端的状态变了, 待办数量多半也变了。
      this.refreshPending();
      if (justFinished) {
        notifyTaskFinished(id, title);
      }
    };
    this.listener.onPending = (summary: PendingSummary): void => {
      notifyPendingSummary(summary);
      // 顺带把实时状态存下来: 概览里的「运行中/子 Agent/排队/待确认」就靠它
      this.applyPendingSummary(summary);
    };
    this.listener.onMessageCreated = (_sid: string, _m: BridgeMessage): void => {};
    this.listener.onMessageDelta = (_sid: string, _mid: string, _d: string): void => {};
    this.listener.onMessageCompleted = (_sid: string, _m: BridgeMessage): void => {};
    this.listener.onBridgeError = (msg: string): void => {
      this.message = msg;
    };
    // 连接状态用**三态**的说法(客户端给什么就显示什么)⇒ 和别的页面一个口径 ✓
    // (以前这一页自己拼"已连接/未连接", 隧道掐连接时会闪一下"未连接" ⇒ 用户以为坏了 ✓)
    this.listener.onConnectionLabel = (label: string, connected: boolean): void => {
      this.connectionText = label;
      this.connected = connected;
      this.endpointLabel = AppState.client.getEndpointLabel();
      if (connected) {
        this.refresh();
      }
    };
    AppState.client.addListener(this.listener);
    await this.refresh();
    this.refreshPending();
    void this.loadApprovals();
    if (this.approvalTimer < 0) {
      this.approvalTimer = setInterval(() => { void this.loadApprovals(); }, 4000);
    }
    // 从通知点进来的时候, 直接进那个对话。
    await this.openPendingSession();
    // 把华为推送 token 报给桥接服务(拿不到就跳过, 模拟器上一定会失败)。
    registerPushToken().catch((err: Error): void => {
      hilog.warn(DOMAIN, TAG, '上报推送 token 失败: %{public}s', err.message ?? '');
    });
    AppState.client.connect();
  }

  aboutToDisappear(): void {
    AppState.client.removeListener(this.listener);
    if (this.bpListenerId > 0) {
      BreakpointObserver.getInstance().unsubscribe(this.bpListenerId);
      this.bpListenerId = 0;
    }
  }

  /** 回到列表页: 用户已经不在刚才那个会话里了。 */
  onPageShow(): void {
    // 连接状态再读一次: 页面可能在后台待了很久, 期间 WebSocket 断过又连上,
    // 那两次事件都已经过去了 —— 只靠事件的话, 界面会一直停在旧的状态上 ✓
    this.connected = AppState.client.isConnected();
    this.connectionText = AppState.client.connectionLabel();
    this.endpointLabel = AppState.client.getEndpointLabel();
    this.openedSessionId = '';
    setCurrentSessionId(this.wideLayout ? this.selectedId : '');
    // 从通知栏点进来(App 被系统拉起来), 或者从后台被拉回前台: 直达那个对话。
    this.openPendingSession();
    // 从会话页回来: 该会话已读, 刷新一下列表(琥珀点/待处理数)
    void this.refresh();
    void this.loadApprovals();
  }

  /**
   * 拉会话列表。
   *
   * 先问桥接要「会话树」(桌面端侧边栏那种两级结构); 桥接还没上线这个端点时
   * 退回平铺列表, 界面照旧能看, 只是没有话题/子任务那层。
   */
  private async refresh(): Promise<void> {
    try {
      const conversations: ConversationNode[] = await AppState.client.getSessionTree();
      this.conversations = conversations;
      this.treeSupported = true;
      this.loading = false;
      this.message = '';
      this.detectFinished(conversations);
      void this.prepareReadState();
      this.syncBadge();
      return;
    } catch (e) {
      const err = e as Error;
      hilog.info(DOMAIN, TAG, 'session-tree 不可用, 退回平铺列表: %{public}s', err.message ?? '');
      this.treeSupported = false;
    }
    try {
      const list = await AppState.client.listSessions();
      this.sessions = list;
      this.loading = false;
      this.message = '';
      this.detectFlatFinished(list);
      void this.prepareReadState();
      this.syncBadge();
    } catch (e) {
      const err = e as Error;
      this.loading = false;
      this.message = `同步失败: ${describeSoftly(err)}`;
    }
  }

  /** 把平铺列表里的状态/标题同步到会话树上。 */
  private applyFlatState(): void {
    let changed: boolean = false;
    const next: ConversationNode[] = [];
    for (let i = 0; i < this.conversations.length; i++) {
      const node: ConversationNode = this.conversations[i];
      const flat: SessionSummary | null = this.findSession(node.id);
      if (flat !== null) {
        if (flat.state !== node.state) {
          node.state = flat.state;
          changed = true;
        }
        if (flat.title.length > 0 && flat.title !== node.title) {
          node.title = flat.title;
          changed = true;
        }
        if (flat.updatedAt > 0 && flat.updatedAt !== node.updatedAt) {
          node.updatedAt = flat.updatedAt;
          changed = true;
        }
      }
      next.push(node);
    }
    if (changed) {
      this.conversations = next;
    }
  }

  /** 在平铺列表里找一条会话。 */
  private findSession(id: string): SessionSummary | null {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === id) {
        return this.sessions[i];
      }
    }
    return null;
  }

  /**
   * 刷新右上角的待办角标。
   *
   * 同时同步系统角标(App 图标上的数量)。拿不到就保持原样, 不打扰用户。
   */
  private async refreshPending(): Promise<void> {
    try {
      const count = await AppState.client.getPendingCount();
      this.pendingCount = count;
      this.liveTotal = count;
      if (count === 0) {
        this.liveRunning = [];
        this.liveQuestions = [];
      }
      await this.syncBadge();
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '刷新待办数量失败: %{public}s', err.message ?? '');
    }
  }

  /**
   * 从通知点进来: 直接打开那个会话。
   *
   * 两条路:
   * 1. 通知里带了 sessionId(want 传进来的)—— Ability 存好了, 这里取走;
   * 2. 通知的 wantAgent 在有些系统上造不出来 —— 那就问系统「通知栏里还剩哪些通知」,
   *    从通知里带的会话 id 反查出来(见 common/LocalNotify.ets)。
   */
  private async openPendingSession(): Promise<void> {
    let sessionId: string = takePendingSessionId();
    if (sessionId.length === 0) {
      sessionId = await takeNotifiedSessionId();
    }
    if (sessionId.length === 0) return;
    const found: SessionSummary | null = this.findSession(sessionId);
    this.openSessionById(sessionId, found?.title ?? '', found?.cwd ?? '');
  }

  private async loadWorkspaces(): Promise<void> {
    try {
      const entries = await AppState.client.listWorkspaces();
      this.workspaceEntries = entries;
      this.workspaces = entries.map((e) => e.cwd);
      if (this.newCwd.length === 0 && this.workspaces.length > 0) {
        this.newCwd = this.workspaces[0];
      }
    } catch (e) {
      this.workspaces = [];
      this.workspaceEntries = [];
    }
  }

  /**
   * 模式清单(桌面端新建任务时的「模式」)。
   *
   * 桥接还没上线 /api/v1/agent-presets 时是空数组, 这时只显示「默认」。
   */
  private async loadAgentPresets(): Promise<void> {
    try {
      const presets = await AppState.client.getAgentPresets();
      this.agentPresets = presets;
    } catch (e) {
      this.agentPresets = [];
    }
  }

  /** 权限预设(手机上要能选, 不能只显示「去桌面端改」)。 */
  private async loadPermissions(): Promise<void> {
    try {
      const catalog = await AppState.client.getPermissionCatalog();
      this.permissionOptions = catalog.options;
      if (this.newPermission.length === 0 && catalog.defaultPreset.length > 0) {
        this.newPermission = catalog.defaultPreset;
      }
    } catch (e) {
      this.permissionOptions = [];
    }
  }

  // ------------------------------------------------------------ 分组

  /** 取路径的最后一段, 例如 D:\APP\AINative -> AINative */
  private workspaceLabel(cwd: string): string {
    let path: string = cwd.trim();
    while (path.length > 0 && (path.endsWith('/') || path.endsWith('\\'))) {
      path = path.substring(0, path.length - 1);
    }
    if (path.length === 0) {
      return '未命名工作区';
    }
    const slash: number = path.lastIndexOf('/');
    const back: number = path.lastIndexOf('\\');
    const cut: number = slash > back ? slash : back;
    if (cut < 0 || cut >= path.length - 1) {
      return path;
    }
    return path.substring(cut + 1);
  }

  /**
   * 把会话树(或者平铺列表)统一成「对话」的形状。
   *
   * 桥接支持 session-tree 时, 对话下面带着话题/子任务; 不支持时, 每条会话就是一条对话。
   */
  private conversationEntries(): ConversationLike[] {
    const out: ConversationLike[] = [];
    if (this.treeSupported) {
      for (let i = 0; i < this.conversations.length; i++) {
        const node: ConversationNode = this.conversations[i];
        const topics: SessionTopic[] = (node.topics === undefined || node.topics === null)
          ? [] : node.topics;
        out.push({
          id: node.id,
          title: node.title,
          cwd: node.cwd,
          state: node.state,
          updatedAt: node.updatedAt ?? 0,
          topics: topics
        });
      }
      return out;
    }
    for (let i = 0; i < this.sessions.length; i++) {
      const item: SessionSummary = this.sessions[i];
      out.push({
        id: item.id,
        title: item.title,
        cwd: item.cwd,
        state: item.state,
        updatedAt: item.updatedAt,
        topics: []
      });
    }
    return out;
  }

  /**
   * 把列表摊平成一行行的: 工作区 / 对话 / 话题。
   *
   * 桌面端的排法: 工作区下面是对话, 点开对话之后, 它的话题/子任务缩进在后面。
   * 手机上照搬, 只是缩进小一点。
   */
  private buildRows(): ListRow[] {
    const entries: ConversationLike[] = this.conversationEntries();
    const order: string[] = [];
    const buckets: Map<string, ConversationLike[]> = new Map<string, ConversationLike[]>();
    for (let i = 0; i < entries.length; i++) {
      const item: ConversationLike = entries[i];
      const raw: string = item.cwd.trim();
      const key: string = raw.length > 0 ? raw : '未分组';
      const bucket: ConversationLike[] | undefined = buckets.get(key);
      if (bucket === undefined) {
        const fresh: ConversationLike[] = [item];
        buckets.set(key, fresh);
        order.push(key);
      } else {
        bucket.push(item);
      }
    }

    // 排序: 按「最近有运行过任务」排 ——
    //   1) 组里有在跑的会话/子 Agent ⇒ 当作「现在」, 直接置顶;
    //   2) 否则取组内最大的 updatedAt(桌面端每次跑任务都会更新这一行, 它就是最近活动时间);
    //   3) 组内也一样: 在跑的排最前, 其余按 updatedAt 倒序。
    const now: number = Date.now();
    const latest: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < order.length; i++) {
      const key: string = order[i];
      const items: ConversationLike[] | undefined = buckets.get(key);
      if (items === undefined) {
        continue;
      }
      let newest: number = 0;
      let hasRunning: boolean = false;
      for (let j = 0; j < items.length; j++) {
        const item: ConversationLike = items[j];
        if (item.updatedAt > newest) {
          newest = item.updatedAt;
        }
        if (item.state === 'running' || this.isLiveRunning(item.id)) {
          hasRunning = true;
        }
        for (let k = 0; k < item.topics.length; k++) {
          if (item.topics[k].state === 'running') {
            hasRunning = true;
          }
        }
      }
      latest.set(key, hasRunning ? now : newest);
      items.sort((a: ConversationLike, b: ConversationLike): number => {
        const ra: number = (a.state === 'running' || this.isLiveRunning(a.id)) ? 1 : 0;
        const rb: number = (b.state === 'running' || this.isLiveRunning(b.id)) ? 1 : 0;
        if (ra !== rb) {
          return rb - ra;
        }
        return b.updatedAt - a.updatedAt;
      });
    }
    order.sort((a: string, b: string): number => {
      const la: number = latest.get(a) ?? 0;
      const lb: number = latest.get(b) ?? 0;
      return lb - la;
    });

    const rows: ListRow[] = [];
    for (let i = 0; i < order.length; i++) {
      const groupKey: string = order[i];
      const items: ConversationLike[] | undefined = buckets.get(groupKey);
      if (items === undefined) {
        continue;
      }
      const collapsed: boolean = this.isCollapsed(groupKey);
      const groupRow: ListRow = {
        kind: 'workspace',
        key: `w:${groupKey}`,
        title: this.workspaceLabel(groupKey),
        state: '',
        updatedAt: latest.get(groupKey) ?? 0,
        depth: 0,
        expandable: true,
        expanded: !collapsed,
        sessionId: '',
        cwd: groupKey,
        count: items.length,
        firstOfGroup: true,
        lastOfGroup: false,
        unread: false,
        needsAnswer: false
      };
      rows.push(groupRow);
      if (collapsed) {
        // 折叠起来 ⇒ 整个分组只有标题这一行, 四角都是圆的
        rows[rows.length - 1].lastOfGroup = true;
        continue;
      }
      for (let j = 0; j < items.length; j++) {
        const item: ConversationLike = items[j];
        const hasTopics: boolean = item.topics.length > 0;
        const open: boolean = this.isExpanded(item.id);
        const convoRow: ListRow = {
          kind: 'conversation',
          key: `c:${item.id}`,
          title: item.title.length > 0 ? item.title : item.id,
          state: item.state,
          updatedAt: item.updatedAt,
          depth: 1,
          expandable: hasTopics,
          expanded: open,
          sessionId: item.id,
          cwd: item.cwd,
          count: item.topics.length,
          firstOfGroup: false,
          lastOfGroup: false,
          unread: item.state !== 'running' && !this.isLiveRunning(item.id)
            && this.isSettled(item.updatedAt) && ReadStore.isUnread(item.id, item.updatedAt),
          needsAnswer: this.isWaitingAnswer(item.id)
        };
        rows.push(convoRow);
        if (!hasTopics || !open) {
          continue;
        }
        for (let k = 0; k < item.topics.length; k++) {
          const topic: SessionTopic = item.topics[k];
          const topicRow: ListRow = {
            kind: 'topic',
            key: `t:${topic.id}`,
            title: topic.title.length > 0 ? topic.title : topic.id,
            state: topic.state,
            updatedAt: topic.updatedAt ?? 0,
            depth: 2,
            expandable: false,
            expanded: false,
            sessionId: topic.id,
            cwd: item.cwd,
            count: 0,
            firstOfGroup: false,
            lastOfGroup: false,
            unread: false,
            needsAnswer: false
          };
          rows.push(topicRow);
        }
      }
      // 这一组到上一行为止 ⇒ 给最后一行加上下方圆角
      rows[rows.length - 1].lastOfGroup = true;
    }
    return rows;
  }

  /**
   * 对话行的三角: 展开/收起它的话题子树。
   *
   * 点它只折叠, 不进详情 —— 所以点击区跟标题是分开的两个兄弟节点。
   */
  private toggleRow(row: ListRow): void {
    if (!row.expandable) {
      return;
    }
    this.toggleConversation(row.sessionId);
  }

  private isExpanded(id: string): boolean {
    return this.expandedIds.indexOf(id) >= 0;
  }

  private toggleConversation(id: string): void {
    const next: string[] = this.expandedIds.slice();
    const index: number = next.indexOf(id);
    if (index >= 0) {
      next.splice(index, 1);
    } else {
      next.push(id);
    }
    this.expandedIds = next;
  }

  private isCollapsed(key: string): boolean {
    return this.collapsedKeys.indexOf(key) >= 0;
  }

  private toggleGroup(key: string): void {
    const next: string[] = this.collapsedKeys.slice();
    const index: number = next.indexOf(key);
    if (index >= 0) {
      next.splice(index, 1);
    } else {
      next.push(key);
    }
    this.collapsedKeys = next;
  }

  // ------------------------------------------------------------ 概览

  /** 会话总数(对话层, 不含话题) */
  private totalCount(): number {
    return this.conversationEntries().length;
  }


  /**
   * 「运行中」格: 数字 + 子 Agent/排队的小字, 点开看明细。
   */
  @Builder
  runningTile() {
    Column({ space: 2 }) {
      Row({ space: 4 }) {
        Text(`${this.runningSessionCount()}`)
          .fontSize(FontSize.BIG)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.OK)
        if (this.runningSessionCount() > 0) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(Palette.OK)
        }
      }
      .alignItems(VerticalAlign.Center)

      Text('运行中')
        .fontSize(FontSize.TINY)
        .fontColor(Palette.TEXT_3)
      Text(this.runningHint())
        .fontSize(FontSize.TINY)
        .fontColor(Palette.TEXT_3)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Space.MD, right: Space.MD, top: Space.MD, bottom: Space.MD })
    .backgroundColor(Palette.OK_SOFT)
    .borderRadius(Radius.MD)
    .border({ width: 1, color: Palette.BORDER_SOFT })
    .onClick(() => { this.openActivity(); })
  }

  /** 桥接推来的待办摘要: 存下来, 用来算细分数字 */
  private applyPendingSummary(summary: PendingSummary): void {
    const running: string[] = summary.running === undefined || summary.running === null ? [] : summary.running;
    const finished: PendingSession[] = summary.finished === undefined || summary.finished === null
      ? [] : summary.finished;
    for (let i = 0; i < finished.length; i++) {
      ReadStore.markFinished(finished[i].sessionId ?? '');
    }
    const questions: PendingSession[] = summary.questions === undefined || summary.questions === null
      ? [] : summary.questions;
    this.liveRunning = running;
    this.liveQuestions = questions;
    const total: number = summary.count === undefined || summary.count === null ? 0 : summary.count;
    this.liveTotal = total;
    this.liveQueued = summary.queued === undefined || summary.queued === null ? -1 : summary.queued;
    if (total > 0) {
      this.pendingCount = total;
    }
  }

  /**
   * 当前「真正在跑」的会话 id。
   *
   * 三个来源取并集: 桥接 pending 帧里的 running(桌面端 live 行, 最准) +
   * 会话树里 state=running 的对话 + 会话树里 state=running 的话题(子 Agent)。
   */
  private runningIds(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.liveRunning.length; i++) {
      const id: string = this.liveRunning[i];
      if (id.length > 0 && out.indexOf(id) < 0) {
        out.push(id);
      }
    }
    const entries: ConversationLike[] = this.conversationEntries();
    for (let i = 0; i < entries.length; i++) {
      const item: ConversationLike = entries[i];
      if (item.state === 'running' && out.indexOf(item.id) < 0) {
        out.push(item.id);
      }
      for (let k = 0; k < item.topics.length; k++) {
        const tid: string = item.topics[k].id;
        if (item.topics[k].state === 'running' && out.indexOf(tid) < 0) {
          out.push(tid);
        }
      }
    }
    return out;
  }

  private runningSessionCount(): number {
    return this.runningIds().length;
  }

  /**
   * 识别「真正跑完了」的会话: 上一轮 running、这一轮不是 running。
   *
   * 只有这种事件才可能变成「待看」; 后台任务/流式写入只会改 mtime, 不会触发它。
   */
  private detectFinished(conversations: ConversationNode[]): void {
    for (let i = 0; i < conversations.length; i++) {
      const node: ConversationNode = conversations[i];
      const before: string | undefined = this.prevStates.get(node.id);
      if (before === 'running' && node.state !== 'running') {
        ReadStore.markFinished(node.id);
      }
      this.prevStates.set(node.id, node.state);
    }
  }

  /** 平铺列表(没有树)时的同一套检测 */
  private detectFlatFinished(list: SessionSummary[]): void {
    for (let i = 0; i < list.length; i++) {
      const item: SessionSummary = list[i];
      const before: string | undefined = this.prevStates.get(item.id);
      if (before === 'running' && item.state !== 'running') {
        ReadStore.markFinished(item.id);
      }
      this.prevStates.set(item.id, item.state);
    }
  }

  /** 会话安静了(不是还在流式生成/写消息) */
  private isSettled(updatedAt: number): boolean {
    return updatedAt > 0 && Date.now() - updatedAt >= 15000;
  }

  /** 这个会话桌面端是不是在等用户回答 */
  private isWaitingAnswer(id: string): boolean {
    for (let i = 0; i < this.liveQuestions.length; i++) {
      const q: PendingSession = this.liveQuestions[i];
      if (q.sessionId === id) {
        return true;
      }
    }
    return false;
  }

  /** 已完成但还没看过的会话(不含在跑的) */
  private unreadSessions(): ConversationLike[] {
    const out: ConversationLike[] = [];
    const entries: ConversationLike[] = this.conversationEntries();
    for (let i = 0; i < entries.length; i++) {
      const item: ConversationLike = entries[i];
      if (item.state === 'running' || this.isLiveRunning(item.id)) {
        continue;
      }
      if (!this.isSettled(item.updatedAt)) {
        continue;
      }
      if (ReadStore.isUnread(item.id, item.updatedAt)) {
        out.push(item);
      }
    }
    return out;
  }

  /** 需要用户关注的数量 = 已完成待看 + 待确认问题 + 待批准 */
  private attentionCount(): number {
    return this.unreadSessions().length + this.liveQuestions.length + this.liveApprovals.length;
  }

  /** 拉「桌面端在等批准」的请求(全局, 列表页要用它做角标和分组)。 */
  private async loadApprovals(): Promise<void> {
    const all: ApprovalRequest[] = await AppState.client.getApprovals();
    if (JSON.stringify(all) !== JSON.stringify(this.liveApprovals)) {
      this.liveApprovals = all;
      void this.syncBadge();
    }
  }

  /** 同步 App 图标角标(和标题旁的红标同一个数) */
  private async syncBadge(): Promise<void> {
    try {
      await setBadgeNumber(this.attentionCount());
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '同步图标角标失败: %{public}s', (e as Error).message ?? '');
    }
  }

  /** 第一次同步时建立已读基线, 之后每次刷新都读一遍已读状态 */
  private async prepareReadState(): Promise<void> {
    await ReadStore.load();
    const map: Map<string, number> = new Map<string, number>();
    const entries: ConversationLike[] = this.conversationEntries();
    for (let i = 0; i < entries.length; i++) {
      map.set(entries[i].id, entries[i].updatedAt);
    }
    ReadStore.baseline(map);
  }

  /** 这个会话是不是在桥接的实时 running 列表里 */
  private isLiveRunning(id: string): boolean {
    return this.liveRunning.indexOf(id) >= 0;
  }

  /** 运行中的子 Agent(= 状态是 running 的话题) */
  private runningSubagentCount(): number {
    let n: number = 0;
    const entries: ConversationLike[] = this.conversationEntries();
    for (let i = 0; i < entries.length; i++) {
      const topics: SessionTopic[] = entries[i].topics;
      for (let k = 0; k < topics.length; k++) {
        if (topics[k].state === 'running') {
          n++;
        }
      }
    }
    return n;
  }

  /** 排队中的任务数 = 待办总数 - 在跑 - 待确认(桥接就是这么算的) */
  private queuedCount(): number {
    if (this.liveQueued >= 0) {
      return this.liveQueued;
    }
    const rest: number = this.liveTotal - this.runningSessionCount() - this.liveQuestions.length;
    return rest > 0 ? rest : 0;
  }

  private runningHint(): string {
    const sub: number = this.runningSubagentCount();
    const queued: number = this.queuedCount();
    if (sub === 0 && queued === 0) {
      return '点开看详情';
    }
    // 格子只有三分之一屏宽, 用最短的说法, 别被省略号吃掉关键数字
    return `子${sub} · 队${queued}`;
  }

  /** 按 id 找一条对话/话题(标题 + 父会话标题 + cwd) */
  private findActivityNode(id: string): ActivityItem | null {
    const entries: ConversationLike[] = this.conversationEntries();
    for (let i = 0; i < entries.length; i++) {
      const item: ConversationLike = entries[i];
      if (item.id === id) {
        return {
          kind: 'running',
          key: `c:${id}`,
          title: item.title,
          subtitle: item.cwd,
          sessionId: id,
          cwd: item.cwd
        };
      }
      for (let k = 0; k < item.topics.length; k++) {
        if (item.topics[k].id === id) {
          return {
            kind: 'subagent',
            key: `t:${id}`,
            title: item.topics[k].title,
            subtitle: `父会话: ${item.title}`,
            sessionId: id,
            cwd: item.cwd
          };
        }
      }
    }
    return null;
  }

  private openActivity(): void {
    this.activityOpen = true;
    void this.loadQueues();
  }

  /**
   * 打开面板时按需拉「排队中的任务」明细。
   *
   * 桥接的待办总数把**所有会话**的 inbox 都算进去了, 但手机上只有一个会话一个会话地问;
   * 所以这里取「在跑的 + 最近 12 个会话」, 覆盖绝大多数排队任务, 剩下的在提示里说明。
   */
  private async loadQueues(): Promise<void> {
    this.queueLoading = true;
    const ids: string[] = [];
    const running: string[] = this.runningIds();
    for (let i = 0; i < running.length; i++) {
      ids.push(running[i]);
    }
    const entries: ConversationLike[] = this.conversationEntries();
    for (let i = 0; i < entries.length && i < 12; i++) {
      if (ids.indexOf(entries[i].id) < 0) {
        ids.push(entries[i].id);
      }
    }
    const limit: number = ids.length > 16 ? 16 : ids.length;
    const items: QueueActivityItem[] = [];
    for (let i = 0; i < limit; i++) {
      try {
        const res: QueueResponse = await AppState.client.getQueue(ids[i]);
        const node: ActivityItem | null = this.findActivityNode(ids[i]);
        const title: string = node !== null ? node.title : ids[i];
        const all: QueueItem[] = res.nextTurn.concat(res.nextStep);
        for (let k = 0; k < all.length; k++) {
          items.push({ sessionId: ids[i], sessionTitle: title, text: all[k].text });
        }
      } catch (e) {
        // 单个会话取不到就跳过, 不影响别的
        hilog.warn(DOMAIN, TAG, '取队列失败: %{public}s', (e as Error).message ?? '');
      }
    }
    this.queueItems = items;
    this.queueLoading = false;
  }

  /** 活动面板的行(小节标题也算一行, 这样 ForEach 只有一层) */
  private activityItems(): ActivityItem[] {
    const out: ActivityItem[] = [];
    const running: string[] = this.runningIds();
    if (running.length > 0) {
      out.push({
        kind: 'header', key: 'h-running', title: `正在执行 (${running.length})`,
        subtitle: '', sessionId: '', cwd: ''
      });
      for (let i = 0; i < running.length; i++) {
        const node: ActivityItem | null = this.findActivityNode(running[i]);
        out.push({
          kind: 'running',
          key: `run:${running[i]}`,
          title: node !== null ? node.title : running[i],
          subtitle: node !== null ? node.subtitle : '会话',
          sessionId: running[i],
          cwd: node !== null ? node.cwd : ''
        });
      }
    }

    // 已完成待看: 跑完/有更新但还没点开过的会话
    const unread: ConversationLike[] = this.unreadSessions();
    if (unread.length > 0) {
      out.push({
        kind: 'header', key: 'h-unread', title: `已完成待看 (${unread.length})`,
        subtitle: '', sessionId: '', cwd: ''
      });
      for (let i = 0; i < unread.length; i++) {
        const item: ConversationLike = unread[i];
        out.push({
          kind: 'unread',
          key: `un:${item.id}`,
          title: item.title,
          subtitle: `更新于 ${formatRelative(item.updatedAt)} · 点开算已读`,
          sessionId: item.id,
          cwd: item.cwd
        });
      }
    }

    const subs: ActivityItem[] = [];
    const entries: ConversationLike[] = this.conversationEntries();
    for (let i = 0; i < entries.length; i++) {
      const item: ConversationLike = entries[i];
      for (let k = 0; k < item.topics.length; k++) {
        const topic: SessionTopic = item.topics[k];
        if (topic.state === 'running') {
          subs.push({
            kind: 'subagent',
            key: `sub:${topic.id}`,
            title: topic.title,
            subtitle: `父会话: ${item.title}`,
            sessionId: topic.id,
            cwd: item.cwd
          });
        }
      }
    }
    if (subs.length > 0) {
      out.push({
        kind: 'header', key: 'h-sub', title: `子 Agent (${subs.length})`,
        subtitle: '', sessionId: '', cwd: ''
      });
      for (let i = 0; i < subs.length; i++) {
        out.push(subs[i]);
      }
    }

    if (this.queueLoading) {
      out.push({
        kind: 'header', key: 'h-queue-loading', title: '排队任务 (加载中…)',
        subtitle: '', sessionId: '', cwd: ''
      });
    } else if (this.queueItems.length > 0) {
      const totalQueued: number = this.queuedCount();
      out.push({
        kind: 'header', key: 'h-queue', title: `排队任务 (${totalQueued})`,
        subtitle: '', sessionId: '', cwd: ''
      });
      for (let i = 0; i < this.queueItems.length; i++) {
        const q: QueueActivityItem = this.queueItems[i];
        out.push({
          kind: 'queue',
          key: `q:${q.sessionId}:${i}`,
          title: q.text,
          subtitle: `在「${q.sessionTitle}」里排队`,
          sessionId: q.sessionId,
          cwd: ''
        });
      }
      if (this.queueItems.length < totalQueued) {
        out.push({
          kind: 'hint', key: 'h-queue-rest',
          title: `另外 ${totalQueued - this.queueItems.length} 条在更早的会话里; 进对应会话后看底部队列条。`,
          subtitle: '', sessionId: '', cwd: ''
        });
      }
    } else if (this.queuedCount() > 0) {
      out.push({
        kind: 'header', key: 'h-queue', title: `排队任务 (${this.queuedCount()})`,
        subtitle: '', sessionId: '', cwd: ''
      });
      out.push({
        kind: 'hint', key: 'h-queue-hint',
        title: '桌面端有排队任务, 但手机没拉到明细; 点一条会话进去后可以在底部队列条里看。',
        subtitle: '', sessionId: '', cwd: ''
      });
    }

    if (this.liveApprovals.length > 0) {
      out.push({
        kind: 'header', key: 'h-appr', title: `待批准 (${this.liveApprovals.length})`,
        subtitle: '', sessionId: '', cwd: ''
      });
      for (let i = 0; i < this.liveApprovals.length; i++) {
        const ap: ApprovalRequest = this.liveApprovals[i];
        const node: ActivityItem | null = this.findActivityNode(ap.agentId);
        out.push({
          kind: 'question',
          key: `apr:${ap.eventId}:${i}`,
          title: node !== null ? node.title : (ap.toolName.length > 0 ? ap.toolName : ap.agentId),
          subtitle: `桌面端在等批准: ${ap.toolName}（${Math.max(0, Math.round(ap.remainingMs / 1000))}s）`,
          sessionId: ap.agentId,
          cwd: node !== null ? node.cwd : ''
        });
      }
    }

    if (this.liveQuestions.length > 0) {
      out.push({
        kind: 'header', key: 'h-q', title: `待确认问题 (${this.liveQuestions.length})`,
        subtitle: '', sessionId: '', cwd: ''
      });
      for (let i = 0; i < this.liveQuestions.length; i++) {
        const q: PendingSession = this.liveQuestions[i];
        const qid: string = q.sessionId === undefined ? '' : q.sessionId;
        const qtitle: string = q.title === undefined ? '' : q.title;
        const node: ActivityItem | null = this.findActivityNode(qid);
        out.push({
          kind: 'question',
          key: `qst:${qid}:${i}`,
          title: node !== null ? node.title : (qtitle.length > 0 ? qtitle : qid),
          subtitle: '桌面端在等你回答',
          sessionId: qid,
          cwd: node !== null ? node.cwd : ''
        });
      }
    }

    return out;
  }

  /** 活动面板 */
  @Builder
  activitySheet() {
    Column() {
      Column({ space: Space.SM }) {
        Row() {
          Text('活动与待处理')
            .fontSize(FontSize.TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.TEXT)
            .layoutWeight(1)
          Text('关闭')
            .fontSize(FontSize.SMALL)
            .fontColor(Palette.TEXT_3)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(Palette.SURFACE_HI)
            .borderRadius(Radius.PILL)
            .onClick(() => { this.activityOpen = false; })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text('待看 = 跑完/有新进展但你没点开过; 点一条进对应会话并标已读')
          .fontSize(FontSize.TINY)
          .fontColor(Palette.TEXT_3)
          .width('100%')

        Scroll() {
          Column({ space: Space.XS }) {
            ForEach(this.activityItems(), (item: ActivityItem) => {
              if (item.kind === 'header') {
                Text(item.title)
                  .fontSize(FontSize.TINY)
                  .fontColor(Palette.TEXT_3)
                  .width('100%')
                  .padding({ top: Space.MD, bottom: Space.XS })
              } else if (item.kind === 'hint') {
                Text(item.title)
                  .fontSize(FontSize.SMALL)
                  .fontColor(Palette.TEXT_3)
                  .width('100%')
                  .padding(Space.SM)
              } else {
                Row({ space: Space.SM }) {
                  Circle({ width: 7, height: 7 })
                    .fill(item.kind === 'running' ? Palette.OK
                      : (item.kind === 'queue' || item.kind === 'unread' ? Palette.WARN : Palette.ACCENT))
                  Column({ space: 2 }) {
                    Text(item.title)
                      .fontSize(FontSize.BODY)
                      .fontColor(Palette.TEXT)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (item.subtitle.length > 0) {
                      Text(item.subtitle)
                        .fontSize(FontSize.TINY)
                        .fontColor(Palette.TEXT_3)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Text('›')
                    .fontSize(18)
                    .fontColor(Palette.TEXT_3)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .padding(Space.SM)
                .backgroundColor(Palette.CARD)
                .borderRadius(Radius.SM)
                .onClick(() => {
                  this.activityOpen = false;
                  this.openSessionById(item.sessionId, item.title, item.cwd);
                })
              }
            }, (item: ActivityItem): string => `${item.kind}|${item.key}`)
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: '62%' })
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .padding(Space.LG)
      .backgroundColor(Palette.SURFACE)
      .border({ width: 1, color: Palette.BORDER })
      .borderRadius(Radius.LG)
    }
    .width('100%')
    .height('100%')
    .padding(Space.LG)
    .backgroundColor('#99000000')
    .justifyContent(FlexAlign.Center)
  }

  /** 正在执行的对话数 */
  private runningCount(): number {
    const entries: ConversationLike[] = this.conversationEntries();
    let n: number = 0;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].state === 'running') {
        n++;
      }
    }
    return n;
  }

  /** 工作区个数(按 cwd 去重) */
  private workspaceCount(): number {
    const entries: ConversationLike[] = this.conversationEntries();
    const seen: string[] = [];
    for (let i = 0; i < entries.length; i++) {
      const raw: string = entries[i].cwd.trim();
      const key: string = raw.length > 0 ? raw : '未分组';
      if (seen.indexOf(key) < 0) {
        seen.push(key);
      }
    }
    return seen.length;
  }

  /** 是不是有工作区被折叠了(决定按钮叫「展开全部」还是「收起全部」) */
  private anyCollapsed(): boolean {
    const entries: ConversationLike[] = this.conversationEntries();
    for (let i = 0; i < entries.length; i++) {
      const raw: string = entries[i].cwd.trim();
      const key: string = raw.length > 0 ? raw : '未分组';
      if (this.isCollapsed(key)) {
        return true;
      }
    }
    return false;
  }

  /** 一键展开/收起所有工作区 */
  private toggleAllGroups(): void {
    if (this.anyCollapsed()) {
      this.collapsedKeys = [];
      return;
    }
    const entries: ConversationLike[] = this.conversationEntries();
    const keys: string[] = [];
    for (let i = 0; i < entries.length; i++) {
      const raw: string = entries[i].cwd.trim();
      const key: string = raw.length > 0 ? raw : '未分组';
      if (keys.indexOf(key) < 0) {
        keys.push(key);
      }
    }
    this.collapsedKeys = keys;
  }

  // ------------------------------------------------------------ 状态

  private stateColor(state: string): string {
    if (state === 'running') {
      return Palette.OK;
    }
    if (state === 'error') {
      return Palette.ERROR;
    }
    return Palette.TEXT_3;
  }

  private stateLabel(state: string): string {
    if (state === 'running') {
      return '执行中';
    }
    if (state === 'error') {
      return '异常';
    }
    return '空闲';
  }

  /**
   * ForEach 的 key。
   *
   * 坑: ForEach 按 key 复用子组件, key 相同就不会重新走子组件里的 if 分支。
   * 所以状态(转圈/异常)、选中态、展开态都必须拼进 key, 否则它们变了界面也不动。
   */
  private rowKey(row: ListRow): string {
    let key: string = `${row.kind}|${row.key}`;
    if (row.expanded) {
      key += '|open';
    }
    if (row.sessionId.length > 0 && this.selectedId === row.sessionId) {
      key += '|sel';
    }
    key += `|${row.state}`;
    // 下面这些字段界面里都读了, 不拼进 key 的话 ForEach 按 key 复用 ⇒ 值变了界面不动:
    // 会话数(新建一条后组上的数字)、标题(桌面端改名)、相对时间、组首/组尾圆角。
    key += `|${row.title}|${row.updatedAt}|${row.count}`;
    key += row.firstOfGroup ? '|f' : '';
    key += row.lastOfGroup ? '|l' : '';
    key += row.unread ? '|u' : '';
    key += row.needsAnswer ? '|q' : '';
    return key;
  }

  // ------------------------------------------------------------ 行为

  private openSession(session: SessionSummary): void {
    this.openSessionById(session.id, session.title, session.cwd);
  }

  /** 打开一个会话(列表行和新建成功后都走这里)。 */
  private openSessionById(id: string, title: string, cwd: string): void {
    hilog.info(DOMAIN, TAG, 'openSession %{public}s', id);
    // 记住用户在看哪个会话: 正在看的会话不弹通知。
    this.openedSessionId = id;
    setCurrentSessionId(id);
    // 打开就算看过了(琥珀点消失, 待处理数减少)
    ReadStore.markRead(id);
    if (this.wideLayout) {
      // 双栏: 不跳路由, 右栏直接显示这个会话
      this.selectedId = id;
      this.selectedTitle = title;
      this.selectedCwd = cwd;
      return;
    }
    const params: SessionRouteParams = {
      sessionId: id,
      title: title,
      cwd: cwd
    };
    this.getUIContext().getRouter().pushUrl({ url: 'pages/SessionPage', params: params }).catch(() => {
      hilog.error(DOMAIN, TAG, 'pushUrl SessionPage 失败');
    });
  }

  /**
   * 点一条对话: 打开它, 同时把它的话题/子任务展开。
   *
   * 桌面端点开一条对话, 它的「话题」就跟在后面 —— 手机上照做。
   */
  private openConversationRow(row: ListRow): void {
    if (row.expandable && !row.expanded) {
      this.toggleConversation(row.sessionId);
    }
    this.openSessionById(row.sessionId, row.title, row.cwd);
  }

  private async createSession(): Promise<void> {
    if (this.creating) {
      return;
    }
    if (this.newCwd.trim().length === 0) {
      this.toast('请填写工作目录');
      return;
    }
    const targetCwd: string = this.newCwd.trim();
    this.creating = true;
    try {
      const session = await AppState.client.createSession(this.newCwd.trim(), this.newTitle.trim(),
        this.newPreset, this.newPermission);
      this.showNew = false;
      this.newTitle = '';
      this.newCwdLocked = '';
      // 这个工作区如果是折叠的, 先展开 —— 否则从详情返回列表会看不到刚建的会话 ✓
      this.expandWorkspace(targetCwd);
      await this.refresh();
      this.openSession(session);
    } catch (e) {
      const err = e as Error;
      this.toast(`创建失败: ${describeError(err)}`);
    } finally {
      this.creating = false;
    }
  }

  /** 把某个工作区从折叠集合里去掉。 */
  private expandWorkspace(cwd: string): void {
    const next: string[] = [];
    for (let i = 0; i < this.collapsedKeys.length; i++) {
      if (this.collapsedKeys[i] !== cwd) {
        next.push(this.collapsedKeys[i]);
      }
    }
    this.collapsedKeys = next;
  }

  /**
   * 打开「新建会话」面板。
   *
   * @param cwd 从某个工作区的 ＋ 点进来时传它的路径 ⇒ 面板里工作区直接锁定,
   *            用户不用再从一串最近工作区里找(这就是这次要改的痛点)。
   */
  private openNewSession(cwd: string): void {
    this.newCwdLocked = cwd;
    if (cwd.length > 0) {
      this.newCwd = cwd;
    } else {
      // 从 FAB / 左栏按钮打开时不要带上一次残留的标题和路径
      this.newCwd = '';
      this.newTitle = '';
    }
    this.showNew = true;
    this.loadWorkspaces();
    this.loadAgentPresets();
    this.loadPermissions();
  }

  // ------------------------------------------------------------ 布局

  /** toast 失败不应该影响主流程, 这里统一吞掉异常。 */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, 'toast 失败: %{public}s', err.message ?? '');
    }
  }

  /** 概览里的一格数字 */
  @Builder
  statTile(label: string, value: string, color: string, bg: string) {
    Column({ space: 4 }) {
      Text(value)
        .fontSize(FontSize.BIG)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
      Text(label)
        .fontSize(FontSize.TINY)
        .fontColor(Palette.TEXT_3)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Space.MD, right: Space.MD, top: Space.MD, bottom: Space.MD })
    .backgroundColor(bg)
    .borderRadius(Radius.MD)
    .border({ width: 1, color: Palette.BORDER_SOFT })
  }

  /**
   * 会话列表(窄屏时铺满整屏, 宽屏时占左栏)。
   *
   * 结构从「一堆纯文字行」升级成三层:
   *   1. 概览三格(会话 / 运行中 / 工作区) —— 一眼看到现在有多少活;
   *   2. 每个工作区是一张卡片(图标 + 名字 + 完整路径 + 会话数);
   *   3. 卡片里的对话带状态点/话题数/相对时间, 话题缩进在对话下面。
   *
   * 每个工作区标题右边有一个 ＋: 直接**在这个工作区里**建会话,
   * 不用再走「先点新会话、再去最近工作区里翻」那一步。
   */
  @Builder
  sessionListBody() {
    if (this.loading) {
      Column({ space: Space.MD }) {
        LoadingProgress()
          .width(30)
          .height(30)
          .color(Palette.ACCENT)
        Text('正在同步桌面会话…')
          .fontSize(FontSize.SMALL)
          .fontColor(Palette.TEXT_3)
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
    } else if (this.conversationEntries().length === 0) {
      // 空状态: 画个文件夹当图标, 给一句人话, 再给一个能直接点的动作
      Column({ space: Space.LG }) {
        Row() {
          Column({ space: 2 }) {
            Rect({ width: 12, height: 4, radius: 2 })
              .fill(Palette.ACCENT)
            Rect({ width: 30, height: 20, radius: 4 })
              .fill(Palette.ACCENT)
          }
          .alignItems(HorizontalAlign.Start)
        }
        .width(76)
        .height(76)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Palette.CARD)
        .borderRadius(24)
        .border({ width: 1, color: Palette.BORDER_SOFT })

        Column({ space: Space.SM }) {
          Text('还没有会话')
            .fontSize(FontSize.TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.TEXT)
          Text('在桌面端开始一个任务, 或点下面的按钮在这里新建')
            .fontSize(FontSize.SMALL)
            .fontColor(Palette.TEXT_3)
            .textAlign(TextAlign.Center)
        }

        Row({ space: 6 }) {
          Text('+')
            .fontSize(18)
            .fontColor('#FFFFFF')
          Text('新建会话')
            .fontSize(FontSize.BODY)
            .fontColor('#FFFFFF')
        }
        .padding({ left: 20, right: 20, top: 10, bottom: 10 })
        .backgroundColor(Palette.ACCENT_SOLID)
        .borderRadius(Radius.PILL)
        .onClick(() => { this.openNewSession(''); })
      }
      .layoutWeight(1)
      .width('100%')
      .padding(Space.XL)
      .justifyContent(FlexAlign.Center)
    } else {
      Scroll() {
        Column({ space: 0 }) {
          // ---- 概览: 三格数字 ----
          Row({ space: Space.SM }) {
            this.statTile('会话', `${this.totalCount()}`, Palette.ACCENT, Palette.ACCENT_SOFT)
            this.runningTile()
            this.statTile('工作区', `${this.workspaceCount()}`, Palette.CONTEXT, Palette.OK_SOFT)
          }
          .width('100%')
          .padding({ left: Space.MD, right: Space.MD, top: Space.SM })

          // ---- 工作区分区标题 + 全部展开/收起 ----
          Row() {
            Text('工作区')
              .fontSize(FontSize.TINY)
              .fontColor(Palette.TEXT_3)
              .letterSpacing(1)
            Blank()
            Text(this.anyCollapsed() ? '展开全部' : '收起全部')
              .fontSize(FontSize.TINY)
              .fontColor(Palette.ACCENT)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor(Palette.ACCENT_SOFT)
              .borderRadius(Radius.PILL)
              .onClick(() => { this.toggleAllGroups(); })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: Space.LG, right: Space.MD, top: Space.LG, bottom: Space.XS })

          // 整个列表摊平成一行行再 ForEach:
          // 工作区 -> 对话 -> (点开) 话题/子任务。
          // 同一组的行拼成一张卡片: 组首圆上角、组尾圆下角, 靠 ListRow 的
          // firstOfGroup / lastOfGroup 决定 —— ForEach 里不能套 ForEach/分支容器。
          ForEach(this.buildRows(), (row: ListRow) => {
            if (row.kind === 'workspace') {
              // 工作区卡片标题: 三角 + 图标 + 名字/路径 + 会话数 + ＋
              Row({ space: Space.SM }) {
                Row() {
                  Text(row.expanded ? '▾' : '▸')
                    .fontSize(16)
                    .fontColor(Palette.TEXT_3)
                }
                .width(24)
                .height(36)
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
                .hitTestBehavior(HitTestMode.Block)
                .onClick(() => { this.toggleGroup(row.cwd); })

                // 文件夹图标(圆角底座 + 纯图形, 不用 emoji)
                Row() {
                  Column({ space: 1 }) {
                    Rect({ width: 7, height: 3, radius: 1 })
                      .fill(Palette.ACCENT)
                    Rect({ width: 14, height: 9, radius: 2 })
                      .fill(Palette.ACCENT)
                  }
                  .alignItems(HorizontalAlign.Start)
                }
                .width(30)
                .height(30)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(Palette.ACCENT_SOFT)
                .borderRadius(Radius.SM)

                // 名字 + 完整路径(桌面端侧边栏里也是这两行)
                Column({ space: 1 }) {
                  Text(row.title)
                    .fontSize(FontSize.BODY)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Palette.TEXT)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(row.cwd)
                    .fontSize(FontSize.TINY)
                    .fontColor(Palette.TEXT_3)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .onClick(() => { this.toggleGroup(row.cwd); })

                // 最近活动时间(排序就是按它; 在跑的工作区这里显示「刚刚」)
                Text(formatRelative(row.updatedAt))
                  .fontSize(FontSize.TINY)
                  .fontColor(Palette.TEXT_3)

                Text(`${row.count}`)
                  .fontSize(FontSize.TINY)
                  .fontColor(Palette.TEXT_2)
                  .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                  .backgroundColor(Palette.SURFACE_HI)
                  .borderRadius(Radius.PILL)

                // ＋: 就在这个工作区里建会话(这次要加的那个按钮)
                Row() {
                  Text('+')
                    .fontSize(19)
                    .fontColor(Palette.ACCENT)
                }
                .width(30)
                .height(30)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(Palette.ACCENT_SOFT)
                .borderRadius(Radius.PILL)
                .hitTestBehavior(HitTestMode.Block)
                // 空 cwd 的会话归到「未分组」这一组, 它的 groupKey 是个假路径 ——
                // 不能拿它当 cwd 建会话, 否则会建出一个叫「未分组」的工作区。
                .onClick(() => {
                  this.openNewSession(row.cwd === '未分组' ? '' : row.cwd);
                })
                // 视觉 30vp, 但把可点区域撑到 40vp(手指点得中)
                .responseRegion({ x: -5, y: -4, width: 40, height: 38 })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ left: Space.SM, right: Space.SM, top: Space.SM, bottom: Space.SM })
              .margin({
                left: Space.MD,
                right: Space.MD,
                top: row.firstOfGroup ? Space.MD : 0,
                bottom: row.lastOfGroup ? Space.SM : 0
              })
              .backgroundColor(Palette.CARD)
              .borderRadius({
                topLeft: Radius.MD,
                topRight: Radius.MD,
                bottomLeft: row.lastOfGroup ? Radius.MD : 0,
                bottomRight: row.lastOfGroup ? Radius.MD : 0
              })
              .border({ width: { bottom: row.lastOfGroup ? 0 : 1 }, color: Palette.BORDER_SOFT })
            } else if (row.kind === 'conversation') {
              // 对话: 状态点 + 标题(有空就带话题数) + 相对时间 + 运行中转圈
              Row({ space: Space.SM }) {
                Row() {
                  Text(row.expanded ? '▾' : (row.expandable ? '▸' : ''))
                    .fontSize(15)
                    .fontColor(Palette.TEXT_3)
                }
                .width(24)
                .height(44)
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
                .hitTestBehavior(HitTestMode.Block)
                .onClick(() => {
                  hilog.info(DOMAIN, TAG, '对话三角被点了: %{public}s', row.sessionId);
                  this.toggleRow(row);
                })

                if (this.selectedId.length > 0 && this.selectedId === row.sessionId) {
                  Rect({ width: 3, height: 18, radius: 2 })
                    .fill(Palette.ACCENT)
                }

                Circle({ width: 7, height: 7 })
                  .fill(row.state === 'running' ? Palette.OK
                    : (row.needsAnswer ? Palette.ERROR
                      : (row.state === 'error' ? Palette.ERROR
                        : (row.unread ? Palette.WARN : Palette.BORDER))))

                Column({ space: 1 }) {
                  Text(row.title)
                    .fontSize(FontSize.BODY)
                    .fontColor(this.selectedId === row.sessionId ? Palette.TEXT : Palette.TEXT_2)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (row.count > 0) {
                    Text(`${row.count} 个话题`)
                      .fontSize(FontSize.TINY)
                      .fontColor(Palette.TEXT_3)
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .onClick(() => { this.openConversationRow(row); })

                if (row.needsAnswer) {
                  Text('待确认')
                    .fontSize(FontSize.TINY)
                    .fontColor(Palette.ERROR)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .backgroundColor(Palette.ERROR_SOFT)
                    .borderRadius(Radius.PILL)
                } else if (row.unread) {
                  Text('待看')
                    .fontSize(FontSize.TINY)
                    .fontColor(Palette.WARN)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .backgroundColor(Palette.WARN_SOFT)
                    .borderRadius(Radius.PILL)
                } else {
                  Text(formatRelative(row.updatedAt))
                    .fontSize(FontSize.TINY)
                    .fontColor(Palette.TEXT_3)
                }

                if (row.state === 'running') {
                  LoadingProgress()
                    .width(13)
                    .height(13)
                    .color(Palette.ACCENT)
                } else if (row.state === 'error') {
                  Text(this.stateLabel(row.state))
                    .fontSize(FontSize.TINY)
                    .fontColor(this.stateColor(row.state))
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ left: Space.SM, right: Space.MD, top: Space.SM, bottom: Space.SM })
              .backgroundColor(this.selectedId === row.sessionId ? Palette.SURFACE : Palette.CARD)
              .border({ width: { bottom: row.lastOfGroup ? 0 : 1 }, color: Palette.BORDER_SOFT })
              .borderRadius({
                bottomLeft: row.lastOfGroup ? Radius.MD : 0,
                bottomRight: row.lastOfGroup ? Radius.MD : 0
              })
              .margin({ left: Space.MD, right: Space.MD })
            } else {
              // 话题/子任务: 缩进在它所属的那条对话后面, 左边一根短横线
              Row({ space: Space.SM }) {
                Row() {
                  Rect({ width: 10, height: 1 })
                    .fill(Palette.BORDER)
                }
                .width(34)
                .padding({ left: 10 })
                .justifyContent(FlexAlign.Start)

                Row() {
                  Circle({ width: 5, height: 5 })
                    .fill(Palette.TOOL)
                }
                .width(10)
                .justifyContent(FlexAlign.Center)

                Text(row.title)
                  .fontSize(FontSize.SMALL)
                  .fontColor(Palette.TEXT_2)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)

                if (row.state === 'running') {
                  LoadingProgress()
                    .width(12)
                    .height(12)
                    .color(Palette.ACCENT)
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ left: Space.SM, right: Space.MD, top: Space.XS, bottom: Space.SM })
              .backgroundColor(Palette.CARD)
              .border({ width: { bottom: row.lastOfGroup ? 0 : 1 }, color: Palette.BORDER_SOFT })
              .borderRadius({
                bottomLeft: row.lastOfGroup ? Radius.MD : 0,
                bottomRight: row.lastOfGroup ? Radius.MD : 0
              })
              .margin({ left: Space.MD, right: Space.MD })
              .onClick(() => { this.openSessionById(row.sessionId, row.title, row.cwd); })
            }
          }, (row: ListRow): string => this.rowKey(row))
        }
        .width('100%')
        .padding({ bottom: 96 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
  }

  /**
   * 双栏: 左边会话列表, 右边会话详情(宽屏 >= 600vp 时用, 不跳路由)。
   */
  @Builder
  twoColumnBody() {
    Row() {
      // 左: 会话列表
      Column() {
        this.sessionListBody()

        // 双栏时"新会话"放在列表栏底部, 免得浮在右栏的输入区上面
        Row({ space: 6 }) {
          Text('+')
            .fontSize(18)
            .fontColor('#FFFFFF')
          Text('新会话')
            .fontSize(FontSize.SMALL)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
        }
        .width('100%')
        .height(40)
        .justifyContent(FlexAlign.Center)
        .borderRadius(Radius.PILL)
        .backgroundColor(Palette.ACCENT_SOLID)
        .margin({ left: Space.LG, right: Space.LG, bottom: Space.MD })
        .onClick(() => { this.openNewSession(''); })
      }
      .layoutWeight(0.38)
      .height('100%')
      .backgroundColor(Palette.SIDEBAR)

      Rect({ width: 1, height: '100%' })
        .fill(Palette.BORDER_SOFT)

      // 右: 会话详情
      Column() {
        this.sessionDetailPane()
      }
      .layoutWeight(0.62)
      .height('100%')
      .backgroundColor(Palette.BG)
    }
    .width('100%')
    .layoutWeight(1)
  }

  /**
   * 右栏内容: 选中的会话, 或者一句提示。
   */
  @Builder
  sessionDetailPane() {
    if (this.selectedId.length > 0) {
      SessionDetailView({
        sessionId: this.selectedId,
        title: this.selectedTitle,
        cwd: this.selectedCwd,
        showBack: false
      })
    } else {
      Column({ space: Space.MD }) {
        Row() {
          Column({ space: 2 }) {
            Rect({ width: 10, height: 4, radius: 2 })
              .fill(Palette.ACCENT)
            Rect({ width: 26, height: 18, radius: 4 })
              .fill(Palette.ACCENT)
          }
          .alignItems(HorizontalAlign.Start)
        }
        .width(64)
        .height(64)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Palette.CARD)
        .borderRadius(20)
        .border({ width: 1, color: Palette.BORDER_SOFT })

        Text('选择一个会话')
          .fontSize(FontSize.TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_2)
        Text('在左边的列表里挑一个会话, 这里会显示完整对话')
          .fontSize(FontSize.SMALL)
          .fontColor(Palette.TEXT_3)
        Text('想开新的? 点左边工作区右边那个 +')
          .fontSize(FontSize.TINY)
          .fontColor(Palette.ACCENT)
      }
      .width('100%')
      .height('100%')
      .padding(Space.XL)
      .justifyContent(FlexAlign.Center)
    }
  }
  build() {
    // 主题切换: key 里带 themeTick ⇒ tick 变了整块重建, Palette 的 getter 才会重新取值
    Stack({ alignContent: Alignment.TopStart }) {
      // 吉祥物背景(浓度可在 设置 → 背景 里调; off 时整张图不画)
      if (this.bgAlpha() > 0.01) {
        Image(this.backdropImage())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.bgAlpha())
      }
      ForEach([this.themeTick], (tick: number) => {
        this.pageBody()
      }, (tick: number): string => `theme-${tick}`)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.paletteBgDeep())
    .padding({ top: this.topSafeVp, bottom: this.bottomSafeVp })
  }

  /** 背景浓度(读 tick 建立依赖, 改浓度时自动重画) */
  private bgAlpha(): number {
    const tick: number = this.themeTick;
    return tick < 0 ? 0 : ThemeController.bgAlpha();
  }

  /** 主题底色 */
  private paletteBgDeep(): string {
    const tick: number = this.themeTick;
    return tick < 0 ? Palette.BG_DEEP : Palette.BG_DEEP;
  }

  /** 页面主体(每次切主题整块重建) */
  @Builder
  pageBody() {
      Stack({ alignContent: Alignment.Center }) {
        Column() {
          // ---------- 顶部栏 ----------
          Row() {
            Column({ space: 3 }) {
              Row({ space: Space.SM }) {
                Text('会话')
                  .fontSize(FontSize.HEAD)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Palette.TEXT)
                // 红色待处理 = 「已完成但没看」+「桌面端在等你回答」——这才是要你关注的;
                // 只有排队任务时才是黄底的「排队 N」。点它都打开活动明细。
                if (this.attentionCount() > 0) {
                  Row({ space: 4 }) {
                    Circle({ width: 5, height: 5 })
                      .fill('#FFFFFF')
                    Text(this.attentionCount() > 99 ? '待处理 99+' : `待处理 ${this.attentionCount()}`)
                      .fontSize(FontSize.TINY)
                      .fontColor('#FFFFFF')
                  }
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .backgroundColor(Palette.ERROR)
                  .borderRadius(Radius.PILL)
                  .onClick(() => { this.openActivity(); })
                } else if (this.queuedCount() > 0) {
                  // 只有「真的有排队任务」才显示黄标; 只有会话在跑时不占视觉(运行中那格已经说了)
                  Text(this.queuedCount() > 99 ? '排队 99+' : `排队 ${this.queuedCount()}`)
                    .fontSize(FontSize.TINY)
                    .fontColor(Palette.WARN)
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .backgroundColor(Palette.WARN_SOFT)
                    .border({ width: 1, color: Palette.WARN })
                    .borderRadius(Radius.PILL)
                    .onClick(() => { this.openActivity(); })
                }
              }
              .alignItems(VerticalAlign.Center)

              Text(this.endpointLabel.length > 0 ? this.endpointLabel : '未配置桌面端')
                .fontSize(FontSize.TINY)
                .fontColor(Palette.TEXT_3)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Row({ space: Space.SM }) {
              // 连接状态: 点 + 三态说法, 做成一枚胶囊, 比散着的纯文字清楚
              Row({ space: 5 }) {
                Circle({ width: 7, height: 7 })
                  .fill(this.connectionDotColor())
                Text(this.connectionText)
                  .fontSize(FontSize.TINY)
                  .fontColor(Palette.TEXT_2)
              }
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor(Palette.SURFACE)
              .borderRadius(Radius.PILL)

              // 刷新
              Row() {
                Text('↻')
                  .fontSize(17)
                  .fontColor(Palette.TEXT_2)
              }
              .width(34)
              .height(34)
              .justifyContent(FlexAlign.Center)
              .backgroundColor(Palette.SURFACE)
              .borderRadius(Radius.PILL)
              .responseRegion({ x: -3, y: -3, width: 40, height: 40 })
              .onClick(() => { this.refresh(); })

              // 设备
              Row() {
                Text('▤')
                  .fontSize(15)
                  .fontColor(Palette.TEXT_2)
              }
              .width(34)
              .height(34)
              .justifyContent(FlexAlign.Center)
              .backgroundColor(Palette.SURFACE)
              .borderRadius(Radius.PILL)
              .responseRegion({ x: -3, y: -3, width: 40, height: 40 })
              .onClick(() => {
                this.getUIContext().getRouter().pushUrl({ url: 'pages/DevicesPage' });
              })

              // 设置
              Row() {
                Text('⚙')
                  .fontSize(16)
                  .fontColor(Palette.TEXT_2)
              }
              .width(34)
              .height(34)
              .justifyContent(FlexAlign.Center)
              .backgroundColor(Palette.SURFACE)
              .borderRadius(Radius.PILL)
              .responseRegion({ x: -3, y: -3, width: 40, height: 40 })
              .onClick(() => {
                this.getUIContext().getRouter().pushUrl({ url: 'pages/ConnectPage' });
              })
            }
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: Space.LG, right: Space.MD, top: Space.MD, bottom: Space.MD })
          .backgroundColor(Palette.SIDEBAR)

          Rect({ width: '100%', height: 1 })
            .fill(Palette.BORDER_SOFT)

          // 重连中的提示条: 用户抱怨"状态跳来跳去以为坏了" ⇒ 说清楚数据照常加载 ✓
          if (this.connectionText === '重连中…') {
            Text(this.connectionHintText())
              .fontSize(FontSize.TINY)
              .fontColor(Palette.WARN)
              .width('100%')
              .padding({ left: Space.LG, right: Space.LG, top: Space.SM, bottom: Space.SM })
              .backgroundColor(Palette.SURFACE)
          }

          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(FontSize.SMALL)
              .fontColor(Palette.ERROR)
              .width('100%')
              .padding({ left: Space.LG, right: Space.LG, top: Space.SM, bottom: Space.SM })
              .backgroundColor(Palette.SURFACE)
          }

          // ---------- 主体: 宽屏双栏, 窄屏还是原来那一套 ----------
          if (this.wideLayout) {
            this.twoColumnBody()
          } else {
            this.sessionListBody()
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)

        // ---------- 右下角新建会话(双栏时列表栏底部已经有了, 这里不再浮一层) ----------
        if (!this.wideLayout) {
          Column() {
            Row({ space: 6 }) {
              Text('+')
                .fontSize(20)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
              Text('新会话')
                .fontSize(FontSize.SMALL)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
            }
            .padding({ left: Space.LG, right: 18, top: 10, bottom: 10 })
            .backgroundColor(Palette.ACCENT_SOLID)
            .borderRadius(Radius.PILL)
            .shadow({ radius: 18, color: '#66000000', offsetX: 0, offsetY: 6 })
            .onClick(() => { this.openNewSession(''); })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.End)
          .alignItems(HorizontalAlign.End)
          .padding({ right: Space.LG, bottom: Space.XL })
          .hitTestBehavior(HitTestMode.Transparent)
        }

        // ---------- 活动面板(点「运行中」/右上角待办打开) ----------

        if (this.activityOpen) {

          this.activitySheet()

        }


        // ---------- 新建会话浮层 ----------
        // 桌面端新建任务时能选「工作区 / 模式 / 权限」, 手机上这三项都要有。
        if (this.showNew) {
          Column() {
            Scroll() {
              Column({ space: Space.MD }) {
                Text(this.newCwdLocked.length > 0
                  ? `在 ${this.workspaceLabel(this.newCwdLocked)} 里新建会话`
                  : '新建会话')
                  .fontSize(FontSize.TITLE)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Palette.TEXT)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                // ---- 工作区 ----
                // 从某个工作区的 ＋ 进来时, 这块是**锁定的**一张卡片(路径已经填好),
                // 不会再让用户去列表里找; 想看别的就点「更换」。
                if (this.newCwdLocked.length > 0) {
                  Row({ space: Space.SM }) {
                    Row() {
                      Column({ space: 1 }) {
                        Rect({ width: 7, height: 3, radius: 1 })
                          .fill(Palette.ACCENT)
                        Rect({ width: 14, height: 9, radius: 2 })
                          .fill(Palette.ACCENT)
                      }
                      .alignItems(HorizontalAlign.Start)
                    }
                    .width(30)
                    .height(30)
                    .justifyContent(FlexAlign.Center)
                    .backgroundColor(Palette.ACCENT_SOFT)
                    .borderRadius(Radius.SM)

                    Column({ space: 2 }) {
                      Text(this.workspaceLabel(this.newCwdLocked))
                        .fontSize(FontSize.BODY)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Palette.TEXT)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(this.newCwdLocked)
                        .fontSize(FontSize.TINY)
                        .fontColor(Palette.TEXT_3)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Text('更换')
                      .fontSize(FontSize.SMALL)
                      .fontColor(Palette.ACCENT)
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .backgroundColor(Palette.ACCENT_SOFT)
                      .borderRadius(Radius.PILL)
                      .onClick(() => {
                        this.newCwdLocked = '';
                        this.newCwd = '';
                      })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)
                  .padding(Space.SM)
                  .backgroundColor(Palette.BG_DEEP)
                  .border({ width: 1, color: Palette.BORDER })
                  .borderRadius(Radius.MD)
                } else {
                  Text('工作区(桌面端项目路径)')
                    .fontSize(FontSize.SMALL)
                    .fontColor(Palette.TEXT_2)
                  TextInput({ placeholder: 'D:\\work\\project', text: this.newCwd })
                    .onChange((value: string) => { this.newCwd = value; })
                    .height(44)
                    .fontSize(FontSize.BODY)
                    .fontColor(Palette.TEXT)
                    .placeholderColor(Palette.PLACEHOLDER)
                    .backgroundColor(Palette.BG_DEEP)
                    .border({ width: 1, color: Palette.BORDER })
                    .borderRadius(Radius.SM)
                }

                // 最近的工作区(不套 if 分支 —— 分支里放 ForEach 会让 App 崩;
                // 锁定了就传空数组, ForEach 自己什么都不画)
                ForEach(this.newCwdLocked.length === 0 ? this.workspaceEntries.slice(0, 4) : this.workspaceEntries.slice(0, 0),
                  (entry: WorkspaceEntry) => {
                  Row({ space: Space.SM }) {
                    Row() {
                      Column({ space: 1 }) {
                        Rect({ width: 6, height: 3, radius: 1 })
                          .fill(Palette.TEXT_3)
                        Rect({ width: 12, height: 8, radius: 2 })
                          .fill(Palette.TEXT_3)
                      }
                      .alignItems(HorizontalAlign.Start)
                    }
                    .width(24)
                    .height(24)
                    .justifyContent(FlexAlign.Center)
                    .backgroundColor(Palette.SURFACE_HI)
                    .borderRadius(Radius.SM)

                    Column({ space: 1 }) {
                      Text(entry.label.length > 0 ? entry.label : entry.cwd)
                        .fontSize(FontSize.SMALL)
                        .fontColor(this.newCwd === entry.cwd ? Palette.ACCENT : Palette.TEXT_2)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(entry.cwd)
                        .fontSize(FontSize.TINY)
                        .fontColor(Palette.TEXT_3)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)
                  .padding({ left: 10, right: 10, top: 7, bottom: 7 })
                  .backgroundColor(this.newCwd === entry.cwd ? Palette.SURFACE_HI : Color.Transparent)
                  .borderRadius(Radius.SM)
                  .onClick(() => { this.newCwd = entry.cwd; })
                }, (entry: WorkspaceEntry): string => entry.cwd)

                // ---- 模式 ----
                Text('模式')
                  .fontSize(FontSize.SMALL)
                  .fontColor(Palette.TEXT_2)
                Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row }) {
                  Text('默认')
                    .fontSize(FontSize.SMALL)
                    .fontColor(this.newPreset.length === 0 ? Palette.BG_DEEP : Palette.TEXT_2)
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .backgroundColor(this.newPreset.length === 0 ? Palette.ACCENT : Color.Transparent)
                    .border({ width: 1, color: this.newPreset.length === 0 ? Palette.ACCENT : Palette.BORDER })
                    .borderRadius(Radius.PILL)
                    .margin({ right: Space.SM, bottom: Space.SM })
                    .onClick(() => { this.newPreset = ''; })
                  ForEach(this.agentPresets, (preset: AgentPreset) => {
                    Text(preset.name.length > 0 ? preset.name : preset.id)
                      .fontSize(FontSize.SMALL)
                      .fontColor(this.newPreset === preset.id ? Palette.BG_DEEP : Palette.TEXT_2)
                      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                      .backgroundColor(this.newPreset === preset.id ? Palette.ACCENT : Color.Transparent)
                      .border({ width: 1, color: this.newPreset === preset.id ? Palette.ACCENT : Palette.BORDER })
                      .borderRadius(Radius.PILL)
                      .margin({ right: Space.SM, bottom: Space.SM })
                      .onClick(() => { this.newPreset = preset.id; })
                  }, (preset: AgentPreset): string => preset.id)
                }
                .width('100%')

                // ---- 权限 ----
                Text('权限')
                  .fontSize(FontSize.SMALL)
                  .fontColor(Palette.TEXT_2)
                Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row }) {
                  ForEach(this.permissionOptions, (option: PermissionOption) => {
                    Text(option.name.length > 0 ? option.name : option.value)
                      .fontSize(FontSize.SMALL)
                      .fontColor(this.newPermission === option.value ? Palette.BG_DEEP : Palette.TEXT_2)
                      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                      .backgroundColor(this.newPermission === option.value ? Palette.ACCENT : Color.Transparent)
                      .border({ width: 1, color: this.newPermission === option.value ? Palette.ACCENT : Palette.BORDER })
                      .borderRadius(Radius.PILL)
                      .margin({ right: Space.SM, bottom: Space.SM })
                      .onClick(() => { this.newPermission = option.value; })
                  }, (option: PermissionOption): string => option.value)
                }
                .width('100%')

                // ---- 标题 ----
                Text('标题(可选)')
                  .fontSize(FontSize.SMALL)
                  .fontColor(Palette.TEXT_2)
                TextInput({ placeholder: '例如 修复登录页', text: this.newTitle })
                  .onChange((value: string) => { this.newTitle = value; })
                  .height(44)
                  .fontSize(FontSize.BODY)
                  .fontColor(Palette.TEXT)
                  .placeholderColor(Palette.PLACEHOLDER)
                  .backgroundColor(Palette.BG_DEEP)
                  .border({ width: 1, color: Palette.BORDER })
                  .borderRadius(Radius.SM)

                Row({ space: Space.MD }) {
                  Button('取消')
                    .type(ButtonType.Normal)
                    .layoutWeight(1)
                    .height(44)
                    .borderRadius(Radius.SM)
                    .backgroundColor(Color.Transparent)
                    .fontColor(Palette.TEXT_2)
                    .fontSize(FontSize.BODY)
                    .border({ width: 1, color: Palette.BORDER })
                    .onClick(() => {
                      this.showNew = false;
                      this.newCwdLocked = '';
                      this.newCwd = '';
                      this.newTitle = '';
                    })
                  Button(this.creating ? '创建中…' : '创建')
                    .type(ButtonType.Normal)
                    .layoutWeight(1)
                    .height(44)
                    .borderRadius(Radius.SM)
                    .backgroundColor(this.creating ? Palette.SURFACE_HI : Palette.ACCENT_SOLID)
                    .fontColor(this.creating ? Palette.TEXT_3 : '#FFFFFF')
                    .fontSize(FontSize.BODY)
                    .enabled(!this.creating)
                    .onClick(() => { this.createSession(); })
                }
                .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding(Space.LG)
            }
            .width('100%')
            .constraintSize({ maxHeight: '88%' })
            .scrollBar(BarState.Off)
            .backgroundColor(Palette.SURFACE)
            .border({ width: 1, color: Palette.BORDER })
            .borderRadius(Radius.LG)
          }
          .width('100%')
          .height('100%')
          .padding(Space.LG)
          .backgroundColor('#99000000')
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundImage(this.backdropImage())
      .backgroundImageSize(ImageSize.Cover)
      .backgroundImagePosition(Alignment.Bottom)

  }
}
