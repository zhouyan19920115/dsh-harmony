/**
 * 数据模型 —— 与 docs/PROTOCOL.md 中的 v1 协议一一对应。
 *
 * 约定:
 * - 所有时间戳都是 epoch 毫秒。
 * - role  取值: user | assistant | system | tool
 * - kind  取值: text | tool_call | tool_result
 * - status 取值: streaming | done | error
 */

/** 模型信息(可选字段) */
export interface ModelInfo {
  provider: string;
  model: string;
}

/** 会话摘要 */
export interface SessionSummary {
  id: string;
  title: string;
  cwd: string;
  createdAt: number;
  updatedAt: number;
  state: string;
  messageCount: number;
  model?: ModelInfo;
}

/** 单条消息 */
export interface BridgeMessage {
  id: string;
  sessionId: string;
  role: string;
  kind: string;
  text: string;
  /** 工具名(只有 kind === 'tool_call' 有) */
  name?: string;
  createdAt: number;
  status: string;
}

/** 列表响应 */
export interface SessionListResponse {
  sessions: SessionSummary[];
}

/**
 * 会话树里的一条话题/子任务。
 *
 * 桌面端的侧边栏是两级结构: 一级是「对话」(会话), 点开之后, 这条对话下面的
 * 「话题」和「子任务」才出现 —— 它们缩进在对话后面。
 */
export interface SessionTopic {
  id: string;
  title: string;
  state: string;
  /** topic | subagent | ... (桥接给什么就是什么) */
  kind: string;
  updatedAt?: number;
}

/** 会话树里的一条对话(一级) */
export interface ConversationNode {
  id: string;
  title: string;
  cwd: string;
  state: string;
  updatedAt?: number;
  messageCount?: number;
  /** 这条对话下面的话题/子任务 */
  topics: SessionTopic[];
}

/** GET /api/v1/session-tree 的响应 */
export interface SessionTreeResponse {
  conversations: ConversationNode[];
}

/**
 * 模式(桌面端新建任务时能选的「模式/预设」)。
 *
 * DSH 侧叫 agentPreset, 是 session/create 的一个参数。
 */
export interface AgentPreset {
  id: string;
  name: string;
  description: string;
}

/** GET /api/v1/agent-presets 的响应 */
export interface AgentPresetsResponse {
  presets: AgentPreset[];
}

/** 消息列表响应 */
export interface MessageListResponse {
  messages: BridgeMessage[];
}

/** GET /api/v1/sessions/{id}/messages/{seq}/full 的响应: 某条消息的全文 */
export interface FullMessageResponse {
  /** 全文; 桌面端拿不到时为空串 */
  text?: string;
}

/** 单会话响应 */
export interface SessionResponse {
  session: SessionSummary;
}

/** 通用错误响应 */
export interface ErrorResponse {
  error: BridgeError;
}

export interface BridgeError {
  code: string;
  message: string;
}

/** 提交指令的响应 */
export interface SubmitResponse {
  accepted: boolean;
  messageId: string;
}

/** 工作区列表 */
export interface WorkspaceEntry {
  cwd: string;
  label: string;
}

/**
 * 会话用量数据 —— 桌面端底部状态条显示的那些数字。
 * 字段都是可选的: bridge 拿不到就少几个, 不能因为缺字段就报错。
 */
export interface SessionStatsData {
  turns?: number;
  steps?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  contextTokens?: number;
  contextWindow?: number;
  model?: string;
  permission?: string;
  agentLabel?: string;
}

/** 用量数据响应 */
export interface SessionStatsResponse {
  stats?: SessionStatsData;
}

/**
 * 账号下的一台设备(桌面端或另一台手机)。
 *
 * 这是"多端同步"在手机上的可视面: 谁连着、在线与否、什么时候最后在线。
 */
export interface DeviceInfo {
  id: string;
  name: string;
  /** desktop | phone */
  role: string;
  /** 是否在线 */
  online: boolean;
  /** 最后在线时间(epoch ms) */
  lastSeen: number;
}

/** 设备列表响应 */
export interface DeviceListResponse {
  devices: DeviceInfo[];
  account?: string;
}

export interface WorkspaceListResponse {
  workspaces: WorkspaceEntry[];
}

/* ------------------------------------------------------------------ 模型与权限 */

/** 一个推理强度选项(Off / Low / High ...) */
export interface ModelEffort {
  id: string;
  name: string;
}

/** 目录里的一个模型 */
export interface ModelEntry {
  id: string;
  name: string;
  /** 可选的推理强度列表 */
  efforts: ModelEffort[];
  /** 默认的推理强度 */
  defaultEffort: string;
}

/** 一个 provider(DeepSeek Account / minimax / 本机登录 ...) */
export interface ModelProvider {
  id: string;
  name: string;
  models: ModelEntry[];
}

/** 当前选中的模型 */
export interface ModelChoice {
  provider: string;
  model: string;
  /** 推理档位: 桌面端对不支持档位的模型(如 glm-5.3-flash)不返回这个字段 */
  reasoningEffort?: string;
}

/** 模型目录 */
export interface ModelCatalogResponse {
  default: ModelChoice | null;
  providers: ModelProvider[];
}

/** 权限预设(read-only / workspace-write / danger-full-access) */
export interface PermissionOption {
  value: string;
  name: string;
  description: string;
}

/** 权限预设列表(bridge 返回的形状) */
export interface PermissionOptionsResponse {
  options: PermissionOption[];
  defaultPreset: string;
}

/** 会话当前的权限信息 */
export interface SessionPermission {
  preset: string;
  sandbox: string;
  approval: string;
}

/** 会话当前的状态(模型、权限、是否在跑) */
export interface SessionStateData {
  model: ModelChoice | null;
  permissions: SessionPermission | null;
  running: boolean;
}

/* ------------------------------------------------------------------ 队列与指令 */

/**
 * 队列里排着的一条任务。
 *
 * 桌面端把它叫"队列中排队的对话任务框": agent 在跑的时候, 手机上发出去的指令
 * 先排队, 这里能看到、能改、能删、也能插队。
 */
export interface QueueItem {
  id: string;
  text: string;
  /** next-turn(下一轮) | next-step(下一步) */
  target: string;
  /**
   * 这条任务是什么时候发出去的(毫秒时间戳)。
   *
   * 桌面端不给这个时间 ⇒ 手机自己发出去的时候记下来 ✓
   * 查不到就是 0(不是手机发出去的, 比如在桌面端排队的) ✓
   */
  at: number;
}

/** ask_user_question 里的一个选项 */
export interface AskOption {
  label: string;
  description?: string;
}

/** 桌面端问用户的一个问题 */
export interface AskQuestion {
  /** 稳定 id, 回答时要带回去 */
  id: string;
  /** 问题正文 */
  question: string;
  /** 补充说明(不放进选项标签) */
  detail?: string;
  /** 可选的小标题 */
  header?: string;
  /** 可选的选择项; 没有就是纯文字回答 */
  options?: AskOption[];
  /** 允许多选 */
  multiSelect?: boolean;
}

/** 一次 ask 调用(可含多个问题) */
export interface AskCall {
  callId: string;
  questions: AskQuestion[];
  /**
   * 能不能在手机上提交。
   *
   * DSH 的「前台正在等」提问只有当前前台客户端能作答; 桥接标记 false 时手机只展示
   * 和提醒, 不显示提交按钮(否则点了只会得到一个 409)。
   */
  answerable?: boolean;
}

/** GET /api/v1/sessions/{id}/questions 的响应 */
export interface AskQuestionsResponse {
  questions: AskCall[];
}

/** 提交回答时, 单个问题的答案 */
export interface AskAnswer {
  id: string;
  /** 选中的选项标签(可多个) */
  selected: string[];
  /** 自定义文字回答(可选) */
  custom?: string;
}

/** POST /api/v1/sessions/{id}/questions 的请求体 */
export interface AskAnswerPayload {
  callId: string;
  answers: AskAnswer[];
}

/** 桌面端内核审批(approval/request)的一条待批准请求 */
export interface ApprovalRequest {
  /** 回话时要用的事件 id */
  eventId: string;
  /**
   * 'approval' = 内核审批(允许/拒绝);
   * 'question' = 桌面弹出来的 ask 选项卡片(ABCD), 用下面 questions 渲染。
   */
  kind?: string;
  /** 哪个会话在等 */
  agentId: string;
  /** 工具名(例如 write / pwsh) */
  toolName: string;
  callId?: string;
  /** 机器可读的原因 */
  reason: string;
  /** 多语言的展示原因 */
  displayReason?: ApprovalDisplayReason;
  /** kind === 'question' 时的题目(和桌面那张弹窗一模一样) */
  questions?: AskQuestion[] | null;
  /** 剩余有效时间(毫秒) */
  remainingMs: number;
}

/** 审批原因的本地化文案 */
export interface ApprovalDisplayReason {
  zh?: string;
  en?: string;
  ja?: string;
}

/** GET /api/v1/approvals 的响应 */
export interface ApprovalsResponse {
  /** 桥接的审批流是否在线 */
  live: boolean;
  approvals: ApprovalRequest[];
}

/** 队列响应 */
export interface QueueResponse {
  nextTurn: QueueItem[];
  nextStep: QueueItem[];
}

/** 斜杠命令(桌面端的"调用指令") */
export interface CommandInfo {
  name: string;
  description: string;
  /** 参数提示, 没有就是空串 */
  hint: string;
}

/** 技能(可以当成 /name 调用的提示词包) */
export interface SkillInfo {
  name: string;
  description: string;
  path: string;
}

/** @ 补全的文件候选 */
export interface FileRefInfo {
  path: string;
  /** file | directory */
  kind: string;
}

/** 指令列表(bridge 返回的形状: { commands: [...] }) */
export interface CommandsResponse {
  commands: CommandInfo[];
}

/** 技能列表(bridge 返回的形状: { skills: [...] }) */
export interface SkillsResponse {
  skills: SkillInfo[];
}

/** 文件候选列表(bridge 返回的形状: { files: [...] }) */
export interface FilesResponse {
  files: FileRefInfo[];
}

/** 跑一条斜杠指令的请求 */
export interface CommandPayload {
  /** 整行指令, 带开头的斜杠, 例如 "/permission workspace-write" */
  line: string;
}

/** 跑一条斜杠指令的结果 */
export interface CommandResultResponse {
  ok: boolean;
  text: string;
}

/** 「+ 号」面板里的一条候选(指令 / 技能 / 文件统一成这一种) */
export interface PickItem {
  id: string;
  title: string;
  subtitle: string;
  /** 点一下往输入框里插的文本 */
  insert: string;
}

/** 服务端 -> 客户端 的 WebSocket 帧 */
export interface WsFrame {
  type: string;
  data: WsFrameData;
}

/**
 * WebSocket 帧数据体。
 * 为了兼容 ArkTS 的严格类型系统, 这里用一个"宽"接口承载所有事件负载,
 * 具体字段按 type 解释。
 */
export interface WsFrameData {
  // session.list / session.state
  sessions?: SessionSummary[];
  sessionId?: string;
  state?: string;
  title?: string;
  // message.* 事件
  message?: BridgeMessage;
  messageId?: string;
  delta?: string;
  // prompt 帧(客户端 -> 桌面端)
  text?: string;
  mode?: string;
  // subscribe 帧
  sessionIds?: string[];
  // error
  code?: string;
  // hello
  server?: string;
  version?: string;
  token?: string;
}

/**
 * 错误帧。
 * 与 WsFrame 分开声明, 是因为 error 事件的 data.message 是一个字符串,
 * 而 message.* 事件的 data.message 是一个消息对象 —— 同名不同型。
 */
export interface ErrorFrame {
  type: string;
  data: ErrorFrameData;
}

export interface ErrorFrameData {
  message: string;
  code?: string;
}
