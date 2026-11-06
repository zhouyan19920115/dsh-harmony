/**
 * 应用入口 Ability。
 *
 * 负责: 初始化配置存储, 根据是否已配对决定首屏(连接页 / 会话列表页),
 * 以及接收华为 Push Kit 的通知消息(桌面端有待办时推过来)。
 *
 * 另外还管**本地通知**的入口: 用户点通知栏里那条通知时, 系统带着
 * `sessionId` 启动/唤醒这个 Ability, 这里把它记下来, 页面加载完之后直接跳到那个对话。
 */
import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router, window } from '@kit.ArkUI';
import { pushService, pushCommon } from '@kit.PushKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ConfigStore } from '../common/Config';
import { AppState } from '../common/AppState';
import { LegalStore } from '../common/Legal';
import { SettingsStore } from '../common/SettingsStore';
import { ThemeController } from '../common/ThemeController';
import { WindowChrome } from '../common/WindowChrome';
import { ReadStore } from '../common/ReadStore';
import { SESSION_PARAM, initLocalNotify, setPendingSessionId, takePendingSessionId } from '../common/LocalNotify';

const TAG: string = 'DSHsync';
const DOMAIN: number = 0xFF01;

/** 跳到会话详情页时带的参数(和 SessionPage 的 SessionRouteParams 一致)。 */
interface SessionRouteParams {
  sessionId: string;
  title: string;
  cwd: string;
}

export default class EntryAbility extends UIAbility {
  /** 主窗口: 切主题时要重设系统栏颜色 */
  private mainWindow: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    ConfigStore.init(this.context);
    // 显示设置(主题/字号)要单独初始化: 首帧之前至少先按深色画出来, 读盘之后再切 ✓
    SettingsStore.init(this.context);
    // 已读状态(右上角「待处理」和列表上的琥珀点都靠它)
    ReadStore.init(this.context);
    void ReadStore.load();
    ThemeController.start('dark', this.systemIsLight());
    // 隐私政策 / 用户协议的勾选状态也在这份配置里 ⇒ 顺手初始化一下 ✓
    LegalStore.init(this.context);
    // 本地通知要靠包名把本 App 拉起来, 先记下包名。
    initLocalNotify(this.context.abilityInfo.bundleName);
    // 通知点进来时带着 sessionId, 先记下来。
    this.handleWant(want);
    // 通知消息的接收必须在这里同步注册(onCreate 是同步接口, 不能 await 别的)。
    try {
      pushService.receiveMessage('DEFAULT', this, (data: pushCommon.PushPayload) => {
        hilog.info(DOMAIN, TAG, '收到推送');
        this.onPushMessage(data);
      });
    } catch (error) {
      // 模拟器 / 没有开通推送服务的设备会走到这里, 不影响 App 的其它功能。
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, '注册推送监听失败: %{public}s', err?.message ?? '');
    }
  }

  /**
   * 按设置把屏幕点亮着(常亮 ✓)。
   *
   * 真机几十秒就自动锁 ⇒ `aa start` 被拒(10106102 ✓)⇒ 自动化全做不了 ✓
   * ⇒ 开着它, 无人值守的验收才成立 ✓
   *
   * 失败**不影响 App 运行** ✓(某些形态不支持 ✓)
   */
  /** 系统现在是浅色还是深色(跟随系统模式用) */
  private systemIsLight(): boolean {
    try {
      return this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } catch (e) {
      return false;
    }
  }

  /** 系统切了深/浅色: 跟随系统模式下立刻跟着变, 并重设系统栏颜色 */
  onConfigurationUpdate(newConfig: Configuration): void {
    try {
      const light: boolean = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      const changed: boolean = ThemeController.updateSystemLight(light);
      if (changed) {
        WindowChrome.apply(this.mainWindow as window.Window);
      }
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '处理系统外观变化失败: %{public}s', err.message ?? '');
    }
  }

  /** 拿主窗口 + 按当前主题设置系统栏(全屏但不压通知栏) */
  private applyWindowChrome(windowStage: window.WindowStage): void {
    windowStage.getMainWindow().then((win: window.Window) => {
      this.mainWindow = win;
      WindowChrome.apply(win);
      this.publishSafeInsets(win);
      // 布局全屏: 系统不再自动平移窗口避让键盘, 改为应用全权处理 ——
      // 键盘高度经 keyboardHeightChange 写进 AppStorage, 会话页把它加进底部
      // padding, 输入面板(含发送键)永远完整浮在键盘上方。
      win.setWindowLayoutFullScreen(true).then(() => {
        hilog.info(DOMAIN, TAG, '布局全屏开启, 键盘避让改由应用处理');
        this.publishSafeInsets(win);
      }).catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, '布局全屏设置失败(回退系统避让): %{public}s', e.message ?? '');
      });
      // 监听键盘高度: 键盘弹起时抬升底部 padding, 并把对话滚到底。
      try {
        win.on('keyboardHeightChange', (px: number) => {
          AppStorage.setOrCreate<number>('keyboardVp', px2vp(px));
        });
      } catch (e) {
        hilog.warn(DOMAIN, TAG, '键盘高度监听失败(不影响使用): %{public}s', (e as Error).message ?? '');
      }
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, '取主窗口失败: %{public}s', e.message ?? '');
    });
  }

  /**
   * 全屏之后内容会钻到状态栏/手势条下面 ⇒ 把两个高度量出来写进 AppStorage,
   * 页面在自己的根容器上留出这段 padding, 标题就不会被通知栏压住。
   */
  /** 页面加载完之后再应用一次窗口外观(系统栏颜色/窗口底色) */
  private reapplyChrome(): void {
    if (this.mainWindow !== null) {
      WindowChrome.apply(this.mainWindow);
    }
  }

  /** 重新量一遍安全区(页面加载完之后窗口尺寸才稳定) */
  private refreshSafeInsets(): void {
    if (this.mainWindow !== null) {
      this.publishSafeInsets(this.mainWindow);
    }
  }

  private publishSafeInsets(win: window.Window): void {
    try {
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      let top: number = px2vp(sys.topRect.height);
      let bottom: number = px2vp(nav.bottomRect.height);
      // 刚 windowStageCreate 时可能还是 0 ⇒ 用常见值兜底, 等 avoidAreaChange 再校正
      if (top <= 0) {
        top = 36;
      }
      if (bottom <= 0) {
        bottom = 16;
      }
      AppStorage.setOrCreate<number>('topSafeVp', top);
      AppStorage.setOrCreate<number>('bottomSafeVp', bottom);
      hilog.info(DOMAIN, TAG, '安全区: top=%{public}d bottom=%{public}d',
        Math.round(top), Math.round(bottom));
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '读取安全区失败: %{public}s', err.message ?? '');
    }
  }

  /** 读本地显示设置, 把主题真正应用起来 */
  private loadThemePref(): void {
    SettingsStore.load().then((settings) => {
      ThemeController.start(settings.theme, this.systemIsLight());
      ThemeController.setBgLevel(settings.bgLevel);
      if (this.mainWindow !== null) {
        WindowChrome.apply(this.mainWindow);
      }
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, '读取主题偏好失败: %{public}s', e.message ?? '');
    });
  }

  private applyKeepScreenOn(): void {
    ConfigStore.loadKeepScreenOn().then((keep: boolean): Promise<void> => {
      return window.getLastWindow(this.context).then((win: window.Window): Promise<void> => {
        return win.setWindowKeepScreenOn(keep);
      });
    }).catch((error: BusinessError) => {
      hilog.warn(DOMAIN, TAG, '屏幕常亮设不了(不影响使用): %{public}s', error?.message ?? '');
    });
  }

  /** App 已经在跑的时候, 用户又点了一条通知。 */
  onNewWant(want: Want): void {
    hilog.info(DOMAIN, TAG, 'onNewWant');
    this.handleWant(want);
    this.openPendingSession();
  }

  /**
   * 通知点进来时带过来的 want。
   *
   * 本地通知里带的是 sessionId(哪个会话跑完了 / 在等我回答),
   * 记下来, 页面好了之后直接跳过去。
   */
  private handleWant(want: Want): void {
    try {
      const parameters = want?.parameters;
      if (parameters === undefined || parameters === null) {
        return;
      }
      const raw = parameters[SESSION_PARAM];
      if (!raw) {
        return;
      }
      const sessionId: string = raw as string;
      if (sessionId.length === 0) {
        return;
      }
      hilog.info(DOMAIN, TAG, '通知点进来, 会话 %{public}s', sessionId);
      setPendingSessionId(sessionId);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, '读取通知参数失败: %{public}s', err?.message ?? '');
    }
  }

  /**
   * 跳到"从通知点进来"的那个会话。
   *
   * 拿不到 UI 上下文时(页面还没加载完)就把会话 id 放回去,
   * 让会话列表页在 aboutToAppear 里兜底。
   */
  private openPendingSession(): void {
    const sessionId: string = takePendingSessionId();
    if (sessionId.length === 0) {
      return;
    }
    const params: SessionRouteParams = {
      sessionId: sessionId,
      title: '',
      cwd: ''
    };
    try {
      router.pushUrl({ url: 'pages/SessionPage', params: params }).catch(() => {
        hilog.warn(DOMAIN, TAG, '从通知跳转失败, 交给会话列表页兜底');
        setPendingSessionId(sessionId);
      });
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, '从通知跳转失败: %{public}s', err?.message ?? '');
      setPendingSessionId(sessionId);
    }
  }

  /**
   * 桌面端推来的通知。
   *
   * 通知消息(`payload.notification`)由**系统**直接弹出, 这里只记日志;
   * 真正需要自己处理的是自定义数据消息(`payload.data`)。
   */
  private onPushMessage(data: pushCommon.PushPayload): void {
    try {
      hilog.info(DOMAIN, TAG, '收到桌面端推送');
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, '处理推送失败: %{public}s', err?.message ?? '');
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');
    // 屏幕常亮(调试用 ✓): 真机几十秒就自动锁 ⇒ 自动化全被打断 ✓
    this.applyKeepScreenOn();
    // 全屏 + 系统栏透明(消除上下白边), 并按本地偏好把主题应用起来
    this.applyWindowChrome(windowStage);
    this.loadThemePref();
    // AppState.restore() 会同时把配置写进全局状态和 BridgeClient 的端点,
    // 否则从"已配对"直接进入会话列表页时, 客户端还停留在默认的 127.0.0.1:8787。
    AppState.restore().then((config) => {
      hilog.info(DOMAIN, TAG, '恢复到 %{public}s', config.endpoint);
      const entry: string = config.paired ? 'pages/SessionListPage' : 'pages/ConnectPage';
      windowStage.loadContent(entry, (err) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, '加载页面失败: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, TAG, '页面加载完成: %{public}s', entry);
        this.refreshSafeInsets();
        // 窗口就绪之后再设一次底色: 太早调 setWindowBackgroundColor 会报窗口状态异常
        this.reapplyChrome();
        // 通知权限必须在 loadContent 的回调里申请(不能在 onCreate 里)。
        this.requestNotificationPermission();
        // 从通知点进来的话, 直接进那个对话。
        this.openPendingSession();
      });
      // 什么可用的都没有(没令牌 / 地址也解不开)⇒ 后台自动配对一次,
      // **用户什么都不用点** ✓
      if (AppState.needsPairing()) {
        AppState.autoPair();
      }
    }).catch(() => {
      windowStage.loadContent('pages/ConnectPage', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, '加载页面失败: %{public}s', JSON.stringify(err));
        } else {
          this.requestNotificationPermission();
        }
      });
    });
  }

  /** 申请通知权限(弹窗由系统给出)。失败不影响 App 的其它功能。 */
  private requestNotificationPermission(): void {
    try {
      notificationManager.requestEnableNotification(this.context).then(() => {
        hilog.info(DOMAIN, TAG, '通知权限已开启');
      }).catch((error: BusinessError) => {
        hilog.warn(DOMAIN, TAG, '通知权限未开启: %{public}s', error?.message ?? '');
      });
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, '申请通知权限失败: %{public}s', err?.message ?? '');
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }
}
