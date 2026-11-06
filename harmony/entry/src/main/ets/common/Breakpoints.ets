/**
 * 断点观察 —— 决定当前窗口是"单栏"还是"双栏"。
 *
 * 背景:
 *   - 窄屏手机(竖屏单列): 保持单栏, 列表点进去仍然走 router 跳 SessionPage。
 *   - 宽屏(三折叠展开 / 平板, 窗口宽度 >= 600vp): 并排显示, 左边会话列表, 右边会话详情,
 *     不再跳路由。
 *   - 中间宽度: 单栏 + 路由切换(和现在一样)。
 *
 * 实现要点:
 *   - 宽度以**窗口**为准(window.getLastWindow().getWindowProperties().windowRect),
 *     折叠屏折叠态下应用窗口只占一块屏, 用显示区宽度会算错。
 *   - 监听 window 的 'windowSizeChange'(展开折叠、旋转、分栏) 与 display 的
 *     'windowSizeChange'(显示区本身变化) 两路事件, 任何一路都能把断点刷新过来。
 *   - 断点变化通过订阅回调通知页面; 页面自己把它存进 @State 触发重渲染。
 */
import window from '@ohos.window';
import display from '@ohos.display';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF06;

/** 断点常量(单位 vp) */
export class BreakpointConstants {
  /** 双栏的最小窗口宽度, 达到这个宽度就并排显示 */
  static readonly WIDE_MIN_WIDTH_VP: number = 600;

  /** 常规断点(参照 HarmonyOS 栅格断点) */
  static readonly XS_MAX_WIDTH_VP: number = 320;
  static readonly SM_MAX_WIDTH_VP: number = 600;
  static readonly MD_MAX_WIDTH_VP: number = 840;
  static readonly LG_MAX_WIDTH_VP: number = 1440;
}

/** 断点变化回调: (宽度vp, 高度vp, 是否双栏) */
export type BreakpointListener = (widthVp: number, heightVp: number, isWide: boolean) => void;

/** 订阅项: 带 id 方便取消 */
interface ListenerEntry {
  id: number;
  listener: BreakpointListener;
}

/**
 * 单例断点观察者。
 *
 * 用法:
 *   const bp = BreakpointObserver.getInstance();
 *   this.wideLayout = bp.isWide();
 *   this.bpId = bp.subscribe((w, h, wide) => { this.wideLayout = wide; });
 *   // aboutToDisappear 里
 *   bp.unsubscribe(this.bpId);
 */
export class BreakpointObserver {
  private static instance: BreakpointObserver = new BreakpointObserver();

  private win: window.Window | undefined = undefined;
  private entries: ListenerEntry[] = [];
  private nextListenerId: number = 1;
  /** 当前窗口宽度(vp) */
  private widthVp: number = 0;
  /** 当前窗口高度(vp) */
  private heightVp: number = 0;
  /** 是否双栏 */
  private wide: boolean = false;
  /** window 监听是否已挂上 */
  private ready: boolean = false;

  static getInstance(): BreakpointObserver {
    return BreakpointObserver.instance;
  }

  /**
   * 同步兜底: 窗口还没拿到时先用显示区宽度估一个值。
   *
   * 折叠屏模拟器切折叠态时显示区分辨率本身会变, 所以这个值通常也是对的;
   * 真正生效的仍然是 window 的窗口尺寸(见 init)。
   */
  initSync(): void {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      this.apply(px2vp(d.width), px2vp(d.height));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'initSync 取显示区尺寸失败');
    }
  }

  /**
   * 初始化并开始监听窗口尺寸变化。重复调用是安全的。
   *
   * 说明: 本 SDK 的 display 模块没有 'windowSizeChange' 事件(只有 window 模块有),
   * 所以断点只认 window 的窗口尺寸 —— 折叠屏折叠态下应用窗口只占一块屏,
   * 用显示区宽度会把折叠态误判成宽屏。
   */
  async init(context: Context): Promise<void> {
    if (this.ready) {
      return;
    }
    try {
      this.win = await window.getLastWindow(context);
      const props: window.WindowProperties = this.win.getWindowProperties();
      this.apply(px2vp(props.windowRect.width), px2vp(props.windowRect.height));
      this.win.on('windowSizeChange', (size: window.Size): void => {
        this.apply(px2vp(size.width), px2vp(size.height));
      });
      this.ready = true;
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, 'init 断点监听失败: %{public}s', err.message ?? '');
    }
  }

  /** 窗口尺寸变化后刷新断点 */
  private apply(width: number, height: number): void {
    if (width <= 0) {
      return;
    }
    const sizeChanged: boolean = this.widthVp !== width || this.heightVp !== height;
    const wide: boolean = width >= BreakpointConstants.WIDE_MIN_WIDTH_VP;
    const wideChanged: boolean = this.wide !== wide;
    this.widthVp = width;
    this.heightVp = height;
    this.wide = wide;
    if (!sizeChanged && !wideChanged) {
      return;
    }
    hilog.info(DOMAIN, TAG, '断点 %{public}dx%{public}d vp, 双栏=%{public}s', width, height, `${wide}`);
    this.notify();
  }

  private notify(): void {
    for (const entry of this.entries) {
      try {
        entry.listener(this.widthVp, this.heightVp, this.wide);
      } catch (e) {
        const err = e as Error;
        hilog.warn(DOMAIN, TAG, '断点回调异常: %{public}s', err.message ?? '');
      }
    }
  }

  /**
   * 订阅断点变化, 返回订阅 id(用 unsubscribe 取消)。
   */
  subscribe(listener: BreakpointListener): number {
    const id: number = this.nextListenerId++;
    const entry: ListenerEntry = { id: id, listener: listener };
    this.entries.push(entry);
    // 订阅时立刻把当前状态同步给新订阅者, 避免页面停留在初始值上
    try {
      listener(this.widthVp, this.heightVp, this.wide);
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '断点首次同步异常: %{public}s', err.message ?? '');
    }
    return id;
  }

  /** 取消订阅 */
  unsubscribe(id: number): void {
    for (let i = this.entries.length - 1; i >= 0; i--) {
      if (this.entries[i].id === id) {
        this.entries.splice(i, 1);
      }
    }
  }

  /** 当前窗口宽度(vp) */
  getWidthVp(): number {
    return this.widthVp;
  }

  /** 当前窗口高度(vp) */
  getHeightVp(): number {
    return this.heightVp;
  }

  /** 现在是否应该用双栏 */
  isWide(): boolean {
    return this.wide;
  }

  /** 释放监听 */
  destroy(): void {
    if (this.win !== undefined) {
      this.win.off('windowSizeChange');
    }
    this.entries = [];
    this.ready = false;
  }
}
