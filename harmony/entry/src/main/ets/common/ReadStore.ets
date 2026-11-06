/**
 * 已读状态: 记录「手机上次看到每个会话的更新时间」。
 *
 * 用途: 会话跑完之后桌面端会更新这一行的 mtime; 上次看到的时间更早 ⇒ 这条就是
 * 「已完成但还没看过」, 列表上给一个琥珀色小点, 右上角的红色待处理数也会算上它。
 *
 * 存储: 单独的 preferences 文件, 和显示设置分开(清配对不应该清掉已读状态)。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'DSHsync';
const DOMAIN: number = 0xFF07;
const STORE_NAME: string = 'dsh_harmony_read';

/** 存盘形状 */
/** 会话结束之后又过了这么久还有新动静 ⇒ 认为桌面端已经接着处理过(自动消待看) ✓ */
const READ_ADVANCED_GAP_MS: number = 2000;

interface ReadSnapshot {
  /** 是不是已经建立了基线(第一次同步时把所有会话标成已读, 否则一装就 1000 条未读) */
  initialized: boolean;
  /** sessionId -> 上次看到的时间(epoch ms) */
  read: Record<string, number>;
  /** sessionId -> 观察到「从运行中结束」的时间(epoch ms) —— 只有真正跑完过才算待看 */
  finished: Record<string, number>;
}

export class ReadStore {
  private static store: preferences.Preferences | null = null;
  private static context: common.Context | null = null;
  private static readMap: Map<string, number> = new Map<string, number>();
  /** 观察到「running -> 非 running」的时刻; 后台任务/流式写入不会产生这个事件 */
  private static finishedMap: Map<string, number> = new Map<string, number>();
  private static initialized: boolean = false;
  private static loaded: boolean = false;
  private static saving: boolean = false;

  /** EntryAbility 启动时调一次 */
  static init(context: common.Context): void {
    ReadStore.context = context;
  }

  static isReady(): boolean {
    return ReadStore.loaded;
  }

  /**
   * 会话是不是「真的跑完了、但还没看过」。
   *
   * 严格版(用户要求):
   * - 必须观察到过「running -> 非 running」的结束事件(后台任务只改 mtime, 不会产生这个事件);
   * - 结束之后必须安静一段时间(还在流式生成/写消息的不算);
   * - 结束事件必须晚于上次读过的时间。
   *
   * 「还在生成的消息」不算未读, 只有桌面端在等选择/回答(questions)才算。
   */
  static isUnread(sessionId: string, updatedAt: number): boolean {
    if (!ReadStore.initialized || !ReadStore.loaded) {
      return false;
    }
    const finishedAt: number | undefined = ReadStore.finishedMap.get(sessionId);
    if (finishedAt === undefined || finishedAt <= 0) {
      return false;
    }
    const seen: number | undefined = ReadStore.readMap.get(sessionId);
    if (seen !== undefined && seen >= finishedAt) {
      return false;
    }
    // **桌面端处理过的近似**: 会话「跑完」之后又有了新动静(新消息 / 又跑起来 / 在桌面端发了指令),
    // 说明已经有人在桌面端接着处理了 ⇒ 手机上这条旧的「待看」直接消失, 不再堆着。
    if (updatedAt > finishedAt + READ_ADVANCED_GAP_MS) {
      ReadStore.markRead(sessionId);
      return false;
    }
    return true;
  }

  /** 记录一次「会话跑完了」(由列表页状态迁移/桥接 finished 帧调用) */
  static markFinished(sessionId: string): void {
    if (sessionId.length === 0) {
      return;
    }
    const seen: number | undefined = ReadStore.readMap.get(sessionId);
    const now: number = Date.now();
    // 用户正看着这个会话时结束的, 不算未读
    if (seen !== undefined && seen >= now - 5000) {
      return;
    }
    ReadStore.finishedMap.set(sessionId, now);
    void ReadStore.persist();
  }

  /** 打开会话时调: 记成「已看到现在」 */
  static markRead(sessionId: string): void {
    if (sessionId.length === 0) {
      return;
    }
    ReadStore.readMap.set(sessionId, Date.now());
    void ReadStore.persist();
  }

  /**
   * 第一次同步时建基线: 当前所有会话都算已读。
   * 之后新增/更新的会话才会变未读。
   */
  static baseline(sessions: Map<string, number>): void {
    if (ReadStore.initialized || !ReadStore.loaded) {
      return;
    }
    sessions.forEach((updatedAt: number, id: string) => {
      ReadStore.readMap.set(id, updatedAt);
    });
    ReadStore.initialized = true;
    void ReadStore.persist();
    hilog.info(DOMAIN, TAG, '已读基线建立: %{public}d 个会话', ReadStore.readMap.size);
  }

  /** 读盘 */
  static async load(): Promise<void> {
    if (ReadStore.loaded) {
      return;
    }
    try {
      const ctx = ReadStore.context;
      if (ctx === null) {
        ReadStore.loaded = true;
        return;
      }
      const store = await preferences.getPreferences(ctx, { name: STORE_NAME });
      ReadStore.store = store;
      const raw: string = await store.get('snapshot', '') as string;
      if (raw.length > 0) {
        const snapshot: ReadSnapshot = JSON.parse(raw) as ReadSnapshot;
        ReadStore.initialized = snapshot.initialized === true;
        const read: Record<string, number> = snapshot.read === undefined || snapshot.read === null ? {} : snapshot.read;
        Object.keys(read).forEach((id: string) => {
          ReadStore.readMap.set(id, read[id]);
        });
        const finished: Record<string, number> = snapshot.finished === undefined || snapshot.finished === null
          ? {} : snapshot.finished;
        Object.keys(finished).forEach((id: string) => {
          ReadStore.finishedMap.set(id, finished[id]);
        });
      }
      ReadStore.loaded = true;
      hilog.info(DOMAIN, TAG, '已读取已读状态: %{public}d 个会话', ReadStore.readMap.size);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, '读取已读状态失败: %{public}s', err.message ?? '');
      ReadStore.loaded = true;
    }
  }

  /** 存盘(合并多次调用: 正在存就跳过, 下一次 markRead 再存) */
  static async persist(): Promise<void> {
    if (ReadStore.saving || ReadStore.store === null) {
      return;
    }
    ReadStore.saving = true;
    try {
      const read: Record<string, number> = {};
      ReadStore.readMap.forEach((ts: number, id: string) => {
        read[id] = ts;
      });
      const finished: Record<string, number> = {};
      ReadStore.finishedMap.forEach((ts: number, id: string) => {
        finished[id] = ts;
      });
      const snapshot: ReadSnapshot = {
        initialized: ReadStore.initialized,
        read: read,
        finished: finished
      };
      const store = ReadStore.store;
      await store.put('snapshot', JSON.stringify(snapshot));
      await store.flush();
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, '保存已读状态失败: %{public}s', err.message ?? '');
    } finally {
      ReadStore.saving = false;
    }
  }
}
