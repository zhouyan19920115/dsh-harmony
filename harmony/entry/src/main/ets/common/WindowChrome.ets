/**
 * 窗口外观: 全屏(内容铺到状态栏/导航栏下面) + 系统栏透明 + 系统栏图标颜色跟主题。
 *
 * 原来的问题是: 状态栏和底部导航栏各自带着系统默认的**白底** ⇒ 深色 App 上下各一条白边。
 * 这里把系统栏底色设成透明、窗口底色设成当前主题的底色, 再把系统栏图标颜色按主题切换,
 * 于是通知栏还是能看清, 但看起来和 App 是一整块。
 */
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Palette } from './Theme';

const TAG: string = 'DSHsync';
const DOMAIN: number = 0xFF06;

export class WindowChrome {
  /** 把当前主题应用到窗口(全屏 + 系统栏配色)。失败只记日志, 不影响 App。 */
  static async apply(win: window.Window): Promise<void> {
    const dark: boolean = Palette.isDark();
    try {
      // 真·全屏: 页面内容铺到状态栏/手势条下面(页面自己用 topSafeVp 把标题让开)
      await win.setWindowLayoutFullScreen(true);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen 失败: %{public}s', (e as Error).message ?? '');
    }
    try {
      await win.setWindowSystemBarProperties({
        statusBarColor: Palette.BG_DEEP,
        navigationBarColor: Palette.BG_DEEP,
        // 深色主题用浅色图标, 浅色主题用深色图标
        isStatusBarLightIcon: dark,
        isNavigationBarLightIcon: dark
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties 失败: %{public}s', (e as Error).message ?? '');
    }
    try {
      // 系统栏透明之后, 露出来的是窗口底色 ⇒ 跟当前主题一致就不会有白边。
      await win.setWindowBackgroundColor(Palette.BG_DEEP);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setWindowBackgroundColor 失败: %{public}s', (e as Error).message ?? '');
    }
  }
}
