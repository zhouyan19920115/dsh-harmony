/**
 * 连接页 —— 首次配对 / 修改桌面端地址。
 *
 * 用户在桌面端运行 bridge 后, 会得到一个局域网地址和一个令牌(或一张二维码),
 * 在这里填入即可完成配对, 之后会被记住。
 *
 * 界面配色与桌面端 DeepSeek Harness 保持一致(深色)。
 */
import { AppState } from '../common/AppState';
import { BridgeListener, HealthInfo, parseEndpoint } from '../common/BridgeClient';
import { Palette, Space, Radius, FontSize } from '../common/Theme';
import { DesktopInfo, discoverDesktops, fetchRemoteConfig, freshPairingCode, pairWith } from '../common/Discovery';
import {
  DesktopPackage,
  DesktopPackageInfo,
  LanShareInfo,
  LanShareServer,
  PACKAGE_FILE_NAME
} from '../common/DesktopPackage';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { http } from '@kit.NetworkKit';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ConfigStore } from '../common/Config';
import { window } from '@kit.ArkUI';
import { HttpResult, requestJson } from '../common/Http';
import { describeError } from '../common/ErrorText';
import { LegalStore, ConsentState } from '../common/Legal';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF03;

/** 切远程的总重试预算: 隧道抽风时一直换通道重试, 10 分钟内不放弃 ✓ */
const REMOTE_SWITCH_BUDGET_MS: number = 10 * 60 * 1000;
/** 每轮重试之间的间隔 */
const REMOTE_RETRY_GAP_MS: number = 3000;

/** 远程连接的一个候选地址(双通道) */
interface RemoteEndpoint {
  label: string;
  relayUrl: string;
  wsUrl: string;
}

/** 证书指纹单独存一份(和连接配置分开, 免得互相覆盖)。 */
const CERT_STORE_NAME: string = 'dsh_harmony_certs';

/** 证书信息: `GET /api/v1/relay/certificate` 的返回。 */
interface CertInfo {
  /** 证书的 SHA256 指纹 */
  sha256: string;
  /** 证书对应的地址 */
  host: string;
  /** 端口 */
  port: number;
  /** 是不是自签证书 */
  selfSigned: boolean;
}

/** 证书接口的原始返回(字段都可能没有, 所以都当可选)。 */
interface CertResponse {
  sha256?: string;
  host?: string;
  port?: number;
  selfSigned?: boolean;
}

/** 取证书信息。拿不到就抛异常。 */
async function fetchCertificate(endpoint: string, token: string): Promise<CertInfo | null> {
  let base: string = endpoint.trim().replace(/\/+$/, '');
  // 用户手填的地址常常不带协议头(只有 host:port), 补上再问。
  if (!base.startsWith('http://') && !base.startsWith('https://')) {
    base = `http://${base}`;
  }
  const path: string = `${base}/api/v1/relay/certificate`;
  let result: HttpResult;
  try {
    result = await requestJson(http.RequestMethod.GET, path, token, '', 6000);
  } catch (e) {
    // 自签证书的 https 请求会被系统拦下来, 这时退回明文再问一次
    // (有些中继的证书信息是挂在明文端口上的)。
    if (!path.startsWith('https://')) {
      throw new Error(`证书接口请求失败: ${describeError(e as Error)}`);
    }
    result = await requestJson(http.RequestMethod.GET, path.replace('https://', 'http://'), token, '', 6000);
  }
  if (result.code !== 200) {
    throw new Error(`证书接口返回 HTTP ${result.code}`);
  }
  const parsed = JSON.parse(result.body) as CertResponse;
  if (parsed === undefined || parsed === null) {
    throw new Error('证书接口返回为空');
  }
  const sha: string = parsed.sha256 ?? '';
  if (sha.length === 0) {
    throw new Error('证书接口没有给指纹');
  }
  return {
    sha256: sha.toUpperCase(),
    host: parsed.host ?? '',
    port: parsed.port ?? 0,
    selfSigned: parsed.selfSigned === true
  };
}

/** 从地址里抠出 host:port。 */
function hostPortOf(endpoint: string): string {
  const bare: string = endpoint.replace(/^[a-zA-Z]+:\/\//, '').split('/')[0];
  return bare.toLowerCase();
}

/** 读存过的指纹(一个地址一条)。 */
async function loadCertFingerprint(context: common.Context, key: string): Promise<string> {
  try {
    const store: preferences.Preferences = await preferences.getPreferences(context, { name: CERT_STORE_NAME });
    const value = await store.get(key, '') as string;
    return value ?? '';
  } catch (e) {
    hilog.warn(DOMAIN, TAG, '读证书指纹失败: %{public}s', (e as Error).message ?? '');
    return '';
  }
}

/** 把指纹存进 preferences。 */
async function saveCertFingerprint(context: common.Context, key: string, sha: string): Promise<void> {
  const store: preferences.Preferences = await preferences.getPreferences(context, { name: CERT_STORE_NAME });
  await store.put(key, sha);
  await store.flush();
}

/**
 * 这一页**不摆地址, 也不摆令牌** ✓
 *
 * - 配对靠「自动探测」+ 配对码, 用户不用手输任何东西 ✓
 * - 令牌只活在内存里(要落盘就密文落盘), **屏幕上永远看不见** ✓
 * - 界面上只回答一件事: 「连上了没有」 —— 绿点 + 已连接 ✓
 */

@Entry

@Component
struct ConnectPage {
  /** 状态栏高度(EntryAbility 量出来写进 AppStorage; 全屏后靠它让开通知栏) */
  @StorageProp('topSafeVp') topSafeVp: number = 0;
  /** 手势条高度 */
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 0;

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
    if (key === 'ACCENT_SOFT') { return Palette.ACCENT_SOFT; }
    if (key === 'CARD') { return Palette.CARD; }
    if (key === 'BORDER_SOFT') { return Palette.BORDER_SOFT; }
    if (key === 'WARN_SOFT') { return Palette.WARN_SOFT; }
    if (key === 'ERROR_SOFT') { return Palette.ERROR_SOFT; }
    if (key === 'ACCENT_SOLID') { return Palette.ACCENT_SOLID; }
    if (key === 'BG_DEEP') { return Palette.BG_DEEP; }
    if (key === 'BORDER') { return Palette.BORDER; }
    if (key === 'ERROR') { return Palette.ERROR; }
    if (key === 'OK') { return Palette.OK; }
    if (key === 'SURFACE') { return Palette.SURFACE; }
    if (key === 'SURFACE_HI') { return Palette.SURFACE_HI; }
    if (key === 'TEXT') { return Palette.TEXT; }
    if (key === 'TEXT_2') { return Palette.TEXT_2; }
    if (key === 'TEXT_3') { return Palette.TEXT_3; }
    if (key === 'WARN') { return Palette.WARN; }
    return Palette.TEXT;
  }

  /** 当前主题的吉祥物背景图 */
  private backdropImage(): Resource {
    const tick: number = this.themeTick;
    return tick < 0 ? $r('app.media.mascot_day') : (Palette.isDark() ? $r('app.media.mascot_night') : $r('app.media.mascot_day'));
  }

  /**
   * 桌面端地址 —— **内部用, 不摆到界面上** ✓
   * (地址和令牌都不用手输: 自动探测 + 配对码就够了 ✓)
   */
  private host: string = '';
  /** 令牌 —— **内部用, 不摆到界面上** ✓ */
  private token: string = '';
  /** 局域网那条地址(切回局域网时用 ✓) */
  private lanEndpoint: string = '';
  /** 桌面的名字(「我的台式机」) */
  @State desktopName: string = '';
  /** 现在连的是不是远程(云中继) */
  @State remote: boolean = false;
  /** 已经登录了(手里有令牌 ✓)⇒ 「切到远程」可点 ✓ */
  @State paired: boolean = false;
  /** 刚才那一次健康检查通不通(别报假的「已连接」✓) */
  @State online: boolean = false;
  /**
   * 连接状态的说法: 「已连接」/「重连中…」/「未连接」✓
   *
   * **三态, 和别的页面一个口径**: 这一页原来只认「已连接 / 未连接」两个值,
   * 于是隧道掐连接的那几秒它直接从「已连接」跳到「未连接」⇒ 用户以为坏了 ⇒
   * 现在统一走 `connectionLabel()`(会话列表页也是它)✓
   */
  @State connectionText: string = '未连接';
  /** 屏幕常亮(调试用 ✓)—— 真机几十秒就自动锁, 自动化全做不了 ✓ */
  @State keepScreenOn: boolean = true;
  /** 高级设置是否展开(默认收起, 平时用不到) */
  @State advancedOpen: boolean = false;
  /** 令牌要不要明文显示(默认打码 ✓)。 */
  /** 从地址里解析出来的账号 id */
  @State accountId: string = '';
  @State busy: boolean = false;
  @State status: string = '';
  @State statusOk: boolean = false;
  /** 扫描到的桌面端 */
  @State desktops: DesktopInfo[] = [];
  @State scanning: boolean = false;
  /** 「把桌面端交给电脑」面板里的方案: 0 = DSH 装插件, 1 = 发送文件 */
  @State sendScheme: number = 0;
  @State scanProgress: string = '';
  /** 弹层是否打开 */
  @State sheetOpen: boolean = false;
  /** 弹层内容: 0 = 附近的桌面端, 1 = 把桌面端发到电脑 */
  @State sheetMode: number = 0;
  /** 发送面板的状态说明 */
  @State sendStatus: string = '';
  @State sendOk: boolean = false;
  /** 安装包的名字与大小 */
  @State packageSize: string = '';
  /** 局域网下载地址 */
  @State lanUrl: string = '';
  /** 局域网共享是不是还在跑 */
  @State lanRunning: boolean = false;
  /** 「保存到手机」之后的沙箱路径 */
  @State savedPath: string = '';
  /** 存到公共目录之后的 uri(分享 / 文件管理都指着它) */
  @State publicUri: string = '';
  /** 局域网共享服务器(是对象, 不用 @State) */
  private lanServer: LanShareServer = new LanShareServer();
  /** 两份协议都勾了没有(界面上要显示状态 ✓) */
  @State consentOk: boolean = false;
  /**
   * 订阅连接状态的变化。
   *
   * 这一页原来只看健康检查(REST), 不知道实时通道在重连 ⇒ 状态灯跟真实情况脱节。
   * 订阅上以后, 实时通道掉线/重连/恢复都会反映到界面 ✓
   */
  private listener: BridgeListener = new BridgeListener();
  /** 这一页订阅过了吗(防止重复订阅 ⇒ 回调触发两遍 ✓) */
  private listening: boolean = false;

  /**
   * 每次页面回到前台都重新读一次协议勾选状态。
   *
   * aboutToAppear 只在页面**第一次**创建时跑 ⇒ 用户在设置里勾完之后再返回,
   * 这一页还是「没同意」的旧样子 ⇒ onPageShow 才是每次都会跑的那个 ✓
   */
  onPageShow(): void {
    this.consentGranted();
  }

  async aboutToAppear(): Promise<void> {
    // 连接状态先订阅上 —— 不然页面上看到的是"打开那一刻"的状态, 之后就不动了 ✓
    if (!this.listening) {
      this.listening = true;
      this.listener.onConnectionLabel = (_label: string, _connected: boolean): void => {
        this.connectionText = this.pickConnectionText();
      };
      AppState.client.addListener(this.listener);
    }
    // **令牌以内存里的那份为准** —— 盘上那份解不开也不慌, 内存里这份还能用 ✓
    const config = await AppState.restore();
    this.host = config.endpoint;
    this.token = config.token;
    this.paired = config.token.length > 0;
    this.accountId = parseEndpoint(config.endpoint).accountId;
    // 带账号号/设备号的地址就是中继地址 ⇒ 远程 ✓
    this.remote = this.accountId.length > 0;
    if (!this.remote) {
      this.lanEndpoint = config.endpoint;
    }
    this.keepScreenOn = await ConfigStore.loadKeepScreenOn();
    // 协议勾没勾(界面上要显示状态, 自动探测也要靠它拦住 ✓)
    await this.consentGranted();
    await this.refreshState();
    // 什么可用的都没有 ⇒ 自动配对一次(用户什么都不用点 ✓)
    if (AppState.needsPairing()) {
      this.autoPair();
    }
  }

  /**
   * 这一页显示的连接状态: 三态 ✓
   *
   * 客户端说的是"实时通道"的状态; 这一页还额外知道 REST 能不能通(健康检查 ✓)——
   * 实时通道在重连、但 REST 还能通 ⇒ **对话数据照样加载** ⇒ 显示「重连中…」,
   * 千万别显示「未连接」吓人 ✓ (这正是用户抱怨的那个"以为坏了")
   */
  private pickConnectionText(): string {
    const label: string = AppState.client.connectionLabel();
    if (label === '已连接') {
      return '已连接';
    }
    // 实时通道没连上, 但 REST 还能通 ⇒ 数据链路是好的 ⇒ 说「重连中…」
    if (this.online) {
      return '重连中…';
    }
    return label;
  }

  /** 状态灯的颜色: 连上了是绿的, 重连中是黄的, 没连上是灰的 ✓ */
  private connectionColor(): string {
    const label: string = this.connectionText;
    if (label === '已连接') {
      return this.pal('OK');
    }
    if (label === '重连中…') {
      return this.pal('WARN');
    }
    return this.pal('TEXT_3');
  }

  /** 状态文字的颜色(比状态灯亮一点, 免得太淡看不清 ✓) */
  private connectionTextColor(): string {
    const label: string = this.connectionText;
    if (label === '已连接') {
      return this.pal('OK');
    }
    if (label === '重连中…') {
      return this.pal('WARN');
    }
    return this.pal('TEXT_2');
  }

  /** 状态下面那行说明: 三种状态各说一句 ✓ */
  private connectionDescription(): string {
    const label: string = this.connectionText;
    if (label === '已连接') {
      return this.remote ? '手机已经在走云中继, 离开局域网也能用。' : '手机已经连上这台电脑。';
    }
    if (label === '重连中…') {
      // 用户抱怨的就是这个: 状态跳来跳去像坏了 ⇒ 明确说"数据照常加载, 不影响看进度" ✓
      return '实时通道正在重连, 对话数据照常加载, 不影响看进度。';
    }
    return '还没连上电脑。点「自动探测」, 手机自己找电脑并配对, 不用手输地址和令牌。';
  }

  /**
   * 刷新界面上的连接状态。
   *
   * 「已连接」= 手上有令牌 **而且** 真的连得上 ✓
   */
  private async refreshState(): Promise<void> {
    if (this.token.length === 0) {
      this.desktopName = '';
      this.connectionText = this.pickConnectionText();
      return;
    }
    try {
      const info: HealthInfo = await AppState.client.health();
      if (info.ok) {
        this.desktopName = info.name;
        this.paired = true;
        this.online = true;
        this.status = this.remote ? `已连接(远程) ${info.name}` : `已连接 ${info.name}`;
        this.statusOk = true;
      } else {
        this.online = false;
        this.status = '桌面端没有接受这个令牌';
        this.statusOk = false;
      }
    } catch (e) {
      const err = e as Error;
      this.online = false;
      // 原来直接把系统的英文原文摆出来 ⇒ 用户看不懂 ⇒ 走 describeError 补一句中文说明 ✓
      this.status = `连不上桌面端: ${describeError(err)}`;
      this.statusOk = false;
    }
    // 健康检查的结果也会影响显示的说法 ⇒ 这里重算一次 ✓
    this.connectionText = this.pickConnectionText();
  }

  /**
   * 自动配对: 自己找到电脑换令牌 —— **用户不用管地址和令牌** ✓
   *
   * 盘上的令牌解不开(钥匙没了)时用这个自救 ✓
   */
  private async autoPair(): Promise<void> {
    // 没勾协议 ⇒ 不扫网, 直接说清楚 ✓
    if (!await this.consentGranted()) {
      this.status = '还没同意《隐私政策》和《用户协议》, 自动配对(局域网扫描)不能开。';
      this.statusOk = false;
      this.askConsent();
      return;
    }
    this.busy = true;
    this.status = '正在找电脑并自动配对…';
    this.statusOk = false;
    const ok: boolean = await AppState.autoPair();
    this.busy = false;
    if (ok) {
      const config = AppState.config;
      this.host = config.endpoint;
      this.token = config.token;
      this.paired = true;
      this.accountId = parseEndpoint(config.endpoint).accountId;
      this.remote = this.accountId.length > 0;
      if (!this.remote) {
        this.lanEndpoint = config.endpoint;
      }
      await this.refreshState();
    } else {
      this.status = '没找到能配对的电脑, 确认电脑上的桌面端已经启动';
      this.statusOk = false;
    }
  }

  /** 改常亮开关: 存起来 + 马上生效 ✓。 */
  private async setKeepScreenOn(value: boolean): Promise<void> {
    this.keepScreenOn = value;
    await ConfigStore.saveKeepScreenOn(value);
    try {
      const win = await window.getLastWindow(getContext(this));
      await win.setWindowKeepScreenOn(value);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, '常亮开关不生效(不影响别的): %{public}s', err?.message ?? '');
    }
  }


  /**
   * 离开页面时把局域网共享关掉(别一直占着端口)。
   *
   * **但是不能在这里停共享** —— 用法就是「手机上点开始共享 → 切到电脑的浏览器 →
   * 输入那个地址下载」, 用户一定要切走这个 App。如果这时候把共享停了、地址也清了,
   * 电脑那边就下不到了 ⇒ 所以共享留着, 只退订连接状态 ✓
   */
  aboutToDisappear(): void {
    // 退订连接状态 ⇒ 免得这一页没了还在收回调 ✓
    if (this.listening) {
      this.listening = false;
      AppState.client.removeListener(this.listener);
    }
  }

  /**
   * 用户同意了吗(两份协议都勾了才算 ✓)。
   */
  private async consentGranted(): Promise<boolean> {
    try {
      const state: ConsentState = await LegalStore.load();
      this.consentOk = LegalStore.accepted(state);
      return this.consentOk;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '读协议状态失败, 按「没同意」处理');
      this.consentOk = false;
      return false;
    }
  }

  /** 去设置页(勾协议的地方 ✓)。 */
  private openSettings(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/SettingsPage' }).catch(() => {
      hilog.error(DOMAIN, TAG, 'pushUrl SettingsPage 失败');
    });
  }

  /** 没同意 ⇒ 弹窗让用户去设置里勾 ✓ */
  private async askConsent(): Promise<void> {
    try {
      const result: promptAction.ShowDialogSuccessResponse =
        await this.getUIContext().getPromptAction().showDialog({
          title: '需要先同意协议',
          message: '「自动探测」会在当前局域网里扫描, 找出运行着桌面端的电脑。\n'
            + '按《隐私政策》和《用户协议》, 这需要你先勾选同意。',
          buttons: [
            { text: '取消', color: '#8A8A8F' },
            { text: '去设置里同意', color: '#2E6BE6' }
          ]
        });
      if (result.index === 1) {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/SettingsPage' }).catch(() => {
          hilog.error(DOMAIN, TAG, 'pushUrl SettingsPage 失败');
        });
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '协议提示弹窗失败: %{public}s', (e as Error).message ?? '');
    }
  }

  /**
   * 在局域网里找装了桌面端的电脑。
   *
   * 电脑上的 bridge 会在 `/_dsh/discover` 上应答, 没装这套代码的电脑根本不响应,
   * 所以扫到的就是那台; 模拟器里的 10.0.2.2 也在候选里(那是宿主机)。
   *
   * **扫网之前先问一句「用户同意了吗」** —— 没勾《隐私政策》和《用户协议》
   * 就不扫 ⇒ 免得用户不知情的时候手机在自己扫局域网 ✓
   */
  private async discover(): Promise<void> {
    if (this.scanning) {
      return;
    }
    if (!await this.consentGranted()) {
      this.status = '还没同意《隐私政策》和《用户协议》, 自动探测(局域网扫描)不能开。';
      this.statusOk = false;
      this.askConsent();
      return;
    }
    this.scanning = true;
    this.busy = true;
    this.status = '正在扫描同一 WiFi 下的电脑…';
    this.statusOk = false;
    this.scanProgress = '';
    this.desktops = [];
    try {
      const found: DesktopInfo[] = await discoverDesktops((scanned: number, hits: number) => {
        this.scanProgress = `已扫描 ${scanned} 个地址, 找到 ${hits} 台`;
      });
      this.desktops = found;
      if (found.length > 0) {
        this.status = `找到 ${found.length} 台桌面端, 点一下就能连`;
        this.statusOk = true;
        this.sheetMode = 0;
        this.sheetOpen = true;
      } else {
        this.status = '没找到桌面端。确认电脑上的 bridge 已经启动, 并且手机和电脑在同一个 WiFi(路由器没开「AP 隔离」)';
        this.statusOk = false;
      }
    } catch (e) {
      const err = e as Error;
      this.status = `扫描失败: ${describeError(err)}`;
      this.statusOk = false;
    } finally {
      this.scanning = false;
      this.busy = false;
      this.scanProgress = '';
    }
  }

  /**
   * 连上刚发现的那台电脑。
   *
   * 发现响应里带着短时配对码, 手机直接拿它换令牌 —— 用户不用手输。
   */
  private async connectTo(desktop: DesktopInfo): Promise<void> {
    this.sheetOpen = false;
    this.busy = true;
    this.status = `正在与 ${desktop.name} 配对…`;
    this.statusOk = false;
    try {
      // 自动发现的地址多半是局域网的 http, 自签证书(https/wss)才要核对。
      if (desktop.url.startsWith('https://') || desktop.url.startsWith('wss://')) {
        if (!await this.verifyCertificate(desktop.url, true)) {
          return;
        }
      }
      let token: string = this.token.trim();
      if (desktop.code.length > 0) {
        try {
          // 拿码和点连接之间可能隔了很久 ⇒ 先把码刷新成当前那个 ✓
          const paired = await pairWith(desktop.url, await freshPairingCode(desktop));
          token = paired.token;
          this.token = token;
          this.paired = true;
        } catch (e) {
          const err = e as Error;
          // 码还是被换掉了(有人重扫了一次) —— 说清楚要怎么做 ✓
          if ((err.message ?? '').indexOf('配对码') >= 0) {
            throw new Error('配对码已经过期, 请再点一次「自动探测」');
          }
          throw err;
        }
      }
      this.host = desktop.url;
      this.lanEndpoint = desktop.url;
      this.remote = false;
      this.accountId = parseEndpoint(desktop.url).accountId;
      AppState.client.setWsUrl('');
      AppState.client.setEndpoint(desktop.url, token);
      const info: HealthInfo = await AppState.client.health();
      if (!info.ok) {
        throw new Error('桌面端没有接受这个令牌');
      }
      await AppState.apply(desktop.url, token);
      AppState.client.connect();
      this.status = `已连接 ${desktop.name}`;
      this.statusOk = true;
      this.backToSessions();
    } catch (e) {
      const err = e as Error;
      this.status = `连接 ${desktop.name} 失败: ${describeError(err)}`;
      this.statusOk = false;
    } finally {
      this.busy = false;
    }
  }

  /**
   * 切到远程(云中继)。
   *
   * 电脑把中继地址和令牌交给手机, 手机自己换过去, 用户不用来回改地址。
   */
  private async switchToRemote(): Promise<void> {
    this.busy = true;
    this.status = '正在取远程连接配置…';
    this.statusOk = false;
    try {
      await this.doSwitchToRemote();
    } catch (e) {
      const err = e as Error;
      const message: string = err.message ?? '未知错误';
      if (message.indexOf('401') >= 0) {
        // 本地这个桥接令牌过期了(桥接那边轮换过令牌 ✓)
        // ⇒ **不要只弹个错误了事** ⇒ 自动重新配对一次 ✓
        this.status = '本地令牌已失效, 正在自动重新配对…';
        this.statusOk = false;
        const repaired: boolean = await this.repairLocalToken();
        if (!repaired) {
          this.status = '本地令牌已失效, 请点「自动探测」重新配对后再切远程';
          this.statusOk = false;
          // 自动触发一次探测 ✓ —— 用户什么都不用点 ✓
          this.discover();
          return;
        }
        try {
          await this.doSwitchToRemote();
          return;
        } catch (e2) {
          const err2 = e2 as Error;
          this.status = `切换远程失败: ${describeError(err2)}`;
          this.statusOk = false;
          return;
        }
      }
      this.status = `切换远程失败: ${describeError(err)}`;
      this.statusOk = false;
      if (message.indexOf('connect') >= 0 || message.indexOf('连接') >= 0) {
        // 连不上电脑 ⇒ 多半是不在同一个 WiFi 了 ⇒ 说清楚怎么办 ✓
        this.status = '连不上电脑(不在同一个 WiFi?), 回到同一个 WiFi 后会自动接着连';
      }
    } finally {
      this.busy = false;
    }
  }

  /**
   * 本地那个桥接令牌过期了 ⇒ 自动重新配对一次 ✓。
   *
   * 桥接轮换过令牌的话, 手机手里那个就废了 ⇒ 重新走一遍
   * 「自动探测 → 配对码换新令牌」✓(用户不用手输 ✓)
   *
   * @returns 拿到新令牌了吗
   */
  private async repairLocalToken(): Promise<boolean> {
    // 没同意协议 ⇒ 不扫网(这一段本来就要扫局域网 ✓)
    if (!await this.consentGranted()) {
      return false;
    }
    let found: DesktopInfo[] = [];
    try {
      found = await discoverDesktops((scanned: number, hits: number) => {
        this.scanProgress = `已扫描 ${scanned} 个地址, 找到 ${hits} 台`;
      });
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '自动重新配对: 扫不到电脑: %{public}s', err.message ?? '');
      return false;
    }
    this.desktops = found;
    for (const desktop of found) {
      if (desktop.code.length === 0) {
        continue;
      }
      const fresh: string = await this.pairQuietly(desktop);
      if (fresh.length > 0) {
        this.host = desktop.url;
        this.token = fresh;
        this.paired = true;
        this.lanEndpoint = desktop.url;
        this.remote = false;
        this.accountId = parseEndpoint(desktop.url).accountId;
        return true;
      }
    }
    return false;
  }

  /** 安静地配对一次: 拿不到就返回空串 ✓(不往上抛 ✓)。 */
  private async pairQuietly(desktop: DesktopInfo): Promise<string> {
    try {
      // 码可能已经换了 ⇒ 先刷新成当前那个 ✓
      const paired = await pairWith(desktop.url, await freshPairingCode(desktop));
      return paired.token;
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '配对码用不了: %{public}s', err.message ?? '');
      return '';
    }
  }

  /** 切远程的正活儿(401 自愈那边会再调一次 ✓)。 */
  private async doSwitchToRemote(): Promise<void> {
    this.status = '正在取远程连接配置…';
    this.statusOk = false;
    const config = await fetchRemoteConfig(this.host.trim(), this.token.trim());
    if (!config.available) {
      this.status = config.reason.length > 0 ? config.reason : '桌面端没有配置云中继';
      this.statusOk = false;
      return;
    }
    if (config.relayUrl.length === 0 || config.token.length === 0) {
      this.status = '桌面端返回的远程配置不完整';
      this.statusOk = false;
      return;
    }
    // 远程走的是云中继, 自签证书一样要核对:
    // 指纹从电脑那边问(桥接是明文 http, 问得到), 按证书自己的 host:port 存。
    if (!await this.verifyCertificate(this.host.trim(), false)) {
      return;
    }
    // **双通道**: 主地址(域名隧道, 藏源站 IP) + 兜底地址(直连 IP, 稳)。
    // 主地址超时就自动试兜底, 循环到连上或者 10 分钟预算用完 —— 用户不用手点。
    const candidates: RemoteEndpoint[] = [
      { label: '云中继(域名)', relayUrl: config.relayUrl, wsUrl: config.wsUrl }
    ];
    if (config.fallbackRelayUrl.length > 0 && config.fallbackWsUrl.length > 0) {
      candidates.push({
        label: '云中继(直连)',
        relayUrl: config.fallbackRelayUrl,
        wsUrl: config.fallbackWsUrl
      });
    }
    // **局域网那条地址记着** —— 用户想切回来的时候用得上 ✓
    const lanEndpoint: string = this.lanEndpoint.length > 0 ? this.lanEndpoint : this.host;
    const deadline: number = Date.now() + REMOTE_SWITCH_BUDGET_MS;
    let attempt: number = 0;
    let lastError: string = '';
    while (Date.now() < deadline) {
      attempt += 1;
      for (const candidate of candidates) {
        if (Date.now() >= deadline) {
          break;
        }
        this.status = `正在连接${candidate.label}(第 ${attempt} 次)…`;
        this.statusOk = false;
        try {
          // 中继的 WebSocket 路径跟 REST 不一样, 用桥接给的那个 ✓
          AppState.client.setWsUrl(candidate.wsUrl);
          await AppState.apply(candidate.relayUrl, config.token);
          AppState.client.setEndpoint(candidate.relayUrl, config.token);
          // 连上了才算切过去: 连不上就换下一个通道
          const info: HealthInfo = await AppState.client.health();
          if (!info.ok) {
            lastError = '中继连不上: 桌面端没有接受这个令牌';
            continue;
          }
          this.host = candidate.relayUrl;
          this.token = config.token;
          this.lanEndpoint = lanEndpoint;
          this.remote = true;
          this.accountId = config.accountId;
          this.paired = true;
          AppState.client.connect();
          this.status = `已切换到远程连接(${candidate.label}): ${candidate.relayUrl}`;
          this.statusOk = true;
          this.toast('已切换到远程连接');
          this.backToSessions();
          return;
        } catch (e) {
          lastError = describeError(e as Error);
        }
      }
      await this.sleep(REMOTE_RETRY_GAP_MS);
    }
    this.status = `切换远程失败: ${lastError.length > 0 ? lastError : '隧道和直连都连不上'}` +
      `(已重试 ${Math.round(REMOTE_SWITCH_BUDGET_MS / 60000)} 分钟)`;
    this.statusOk = false;
    this.remote = false;
  }

  /** 等一会儿(重试用)。 */
  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
  /**
   * 第一次连某个地址时核对证书指纹(TOFU: 第一次见, 让用户核对)。
   *
   * 指纹是**从电脑那边问来的**: `GET <source>/api/v1/relay/certificate`。
   * 局域网那个桥接是明文 http, 问得到; 中继自签证书的指纹由电脑显示在窗口里,
   * 用户拿手机上的这串跟电脑上那串肉眼比对。
   *
   * - 问不到(接口还没实现 / 连不上) → 不在这里拦, 让连接自己报错;
   * - 不是自签证书(公网真证书) → 不用管, 走系统信任链;
   * - 没存过指纹 → 弹窗把 SHA256 给用户核对, 确认后存进 preferences;
   * - 存过且一致 → 直接连;
   * - 存过但不一致 → 拒绝连, 提示用户。
   *
   * @param source 去哪儿问指纹(电脑的地址, 或者中继自己的地址)
   * @param own 只认这个地址自己的证书(false: 问到的可能是中继的证书, 由调用方决定要不要用)
   */
  private async verifyCertificate(source: string, own: boolean): Promise<boolean> {
    if (source.length === 0) {
      return true;
    }
    let info: CertInfo | null = null;
    try {
      // 证书接口在桥接上, 是要令牌的(跟别的 /api/v1 一个样)。
      info = await fetchCertificate(source, this.token.trim());
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '拿不到证书信息: %{public}s', (e as Error).message ?? '');
      return true;
    }
    if (info === null || !info.selfSigned) {
      return true;
    }
    // 问到的证书不一定属于这个地址(桥接会报中继的证书), 对不上就不在这儿核对。
    if (own && info.host.length > 0) {
      const certKey: string = `${info.host.toLowerCase()}:${info.port}`;
      if (certKey !== hostPortOf(source)) {
        hilog.info(DOMAIN, TAG, '证书是别的主机的, 这儿不核对: %{public}s', certKey);
        return true;
      }
    }
    const key: string = info.host.length > 0
      ? `${info.host.toLowerCase()}:${info.port}` : source.toLowerCase();
    const known: string = await loadCertFingerprint(this.appContext(), key);
    if (known.length > 0) {
      if (known === info.sha256) {
        return true;
      }
      this.status = '证书指纹和上次对不上, 已拒绝连接(可能被中间人换掉了)。';
      this.statusOk = false;
      this.toast('证书指纹和上次对不上, 已拒绝连接');
      return false;
    }
    const confirmed: boolean = await this.askFingerprint(info);
    if (!confirmed) {
      this.status = '证书指纹没有确认, 已取消连接。';
      this.statusOk = false;
      return false;
    }
    await saveCertFingerprint(this.appContext(), key, info.sha256);
    hilog.info(DOMAIN, TAG, '证书指纹已记住: %{public}s', key);
    return true;
  }

  /** 弹窗让用户核对 SHA256 指纹。 */
  private async askFingerprint(info: CertInfo): Promise<boolean> {
    const where: string = info.host.length > 0 ? `${info.host}:${info.port}` : '这个地址';
    const message: string = `${where} 用的是自签证书。\n`
      + `请核对下面的 SHA256 指纹, 和电脑上显示的是否一致:\n\n${info.sha256}\n\n`
      + `一致点「确认并记住」, 不一致点「取消」。`;
    try {
      const result: promptAction.ShowDialogSuccessResponse = await this.getUIContext().getPromptAction().showDialog({
        title: '核对证书指纹',
        message: message,
        buttons: [
          { text: '取消', color: '#8A8A8F' },
          { text: '确认并记住', color: '#2E6BE6' }
        ]
      });
      return result.index === 1;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '弹窗失败: %{public}s', (e as Error).message ?? '');
      return false;
    }
  }

  /**
   * 切回局域网(直连电脑)—— 远程用腻了、回到同一个 WiFi 时用 ✓
   */
  private async switchBackToLan(): Promise<void> {
    if (this.lanEndpoint.length === 0) {
      this.status = '没有记住局域网的地址, 点「自动探测」重连一次';
      this.statusOk = false;
      return;
    }
    this.busy = true;
    this.status = '正在切回局域网…';
    this.statusOk = false;
    try {
      AppState.client.setWsUrl('');
      AppState.client.setEndpoint(this.lanEndpoint, this.token.trim());
      const info: HealthInfo = await AppState.client.health();
      if (!info.ok) {
        throw new Error('桌面端没有接受这个令牌');
      }
      await AppState.apply(this.lanEndpoint, this.token.trim());
      AppState.client.connect();
      this.host = this.lanEndpoint;
      this.remote = false;
      this.accountId = parseEndpoint(this.host).accountId;
      this.status = `已切回局域网: ${this.desktopName.length > 0 ? this.desktopName : '桌面端'}`;
      this.statusOk = true;
      this.toast('已切回局域网');
    } catch (e) {
      const err = e as Error;
      this.status = `切回局域网失败: ${describeError(err)}`;
      this.statusOk = false;
    } finally {
      this.busy = false;
    }
  }

  /** 退回会话列表(已经在栈里就 back, 不在就 push ✓)。 */
  private backToSessions(): void {
    if (this.getUIContext().getRouter().getStackSize() > 1) {
      this.getUIContext().getRouter().back();
    } else {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/SessionListPage' });
    }
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

  /* ------------------------------------------------- 把桌面端发到电脑(蓝牙 / 局域网) */

  /** 拿到应用上下文(要沙箱路径、资源管理器和 startAbility)。 */
  private appContext(): common.UIAbilityContext {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (context === undefined) {
      throw new Error('拿不到应用上下文');
    }
    return context;
  }

  /** 打开「把桌面端发到电脑」面板。 */
  private async openSendPanel(): Promise<void> {
    this.sheetMode = 1;
    this.sheetOpen = true;
    this.sendStatus = '';
    this.sendOk = false;
    this.savedPath = '';
    this.publicUri = '';
    // **别在这里读那个四十兆的包** —— 打开面板不许付这个代价 ✓
    // (以前这里 rawSize() 会同步打开 App 资源里的大文件 ⇒ 首屏被拖死 ✓ ✓)
    const cached = DesktopPackage.cached(this.appContext());
    this.packageSize = cached !== null
      ? `${PACKAGE_FILE_NAME} · ${cached.sizeText}(已经准备好了)`
      : `${PACKAGE_FILE_NAME} · App 内置的那份(点下面的按钮就开始)`;
    // 方案一的地址先摆出来, 不用先点按钮。
    if (!this.lanRunning) {
      this.startLan();
    }
  }

  /**
   * 准备好安装包(**按需** —— 只有用户真的要用它时才付这个代价 ✓)。
   *
   * 来源是 **App 内置的那份**(跟着 App 一起装的几百 KB)⇒ 不用联网、不用等下载 ✓
   */
  private async ensurePackage(): Promise<DesktopPackageInfo> {
    return DesktopPackage.prepareOnDemand(this.appContext(), {
      onProgress: (text: string) => {
        this.sendStatus = text;
        this.sendOk = false;
      }
    });
  }

  /** 起局域网共享(方案一)。 */
  private startLan(): void {
    this.sendStatus = '正在准备安装包…';
    this.sendOk = false;
    this.ensurePackage().then((info: DesktopPackageInfo) => {
      return this.lanServer.start(info.path, info.size);
    }).then((share: LanShareInfo) => {
      this.lanUrl = share.url;
      this.lanRunning = true;
      this.sendStatus = '电脑浏览器打开上面的地址就能下载。传输期间请让 App 留在前台。';
      this.sendOk = true;
    }).catch((e: Error) => {
      this.sendStatus = `局域网共享失败: ${describeError(e)}`;
      this.sendOk = false;
    });
  }

  /** 起一个局域网 HTTP 服务, 电脑用浏览器下载。 */
  private async sendByLan(): Promise<void> {
    this.startLan();
  }

  /**
   * 方案二的第一步: 把安装包存进手机的「文件」。
   *
   * 走系统的「保存文件」面板(选择路径), 存到公共目录(一般是「下载」)——
   * 存完这个文件就不再是 App 私有的了, 「文件」App 里翻得到它,
   * 用户在文件管理里长按 → 分享, 走的是系统文件管理自己的分享面板
   * (微信 / 蓝牙 / 无线分享 / 星闪 都在里面)。
   *
   * 存完顺手把文件管理拉起来, 定位到刚存的那个文件。
   */
  private async saveToPhone(): Promise<void> {
    this.sendStatus = '正在保存…';
    this.sendOk = false;
    try {
      const context: common.UIAbilityContext = this.appContext();
      // 按需准备(App 内置那份), 完了再存到公共目录 ✓
      await this.ensurePackage();
      const bytes: Uint8Array = DesktopPackage.readSandbox(context);
      const uri: string = await DesktopPackage.saveToPublic(context, bytes);
      this.publicUri = uri;
      this.savedPath = uri;
      this.sendStatus = '已经存到手机的「文件」里了。在文件管理里找到它, 长按 → 分享 → 选微信 / 蓝牙 / 无线分享 / 星闪 → 选那台电脑。';
      this.sendOk = true;
      // 打开文件管理定位它(打不开也不影响, 用户自己翻也行)。
      DesktopPackage.locateInFileManager(context, uri).then(() => {
        hilog.info(DOMAIN, TAG, '已经在文件管理里打开: %{public}s', uri);
      }).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, '文件管理没打开: %{public}s', e.message ?? '');
      });
    } catch (e) {
      const err = e as Error;
      this.sendStatus = `保存失败: ${describeError(err)}`;
      this.sendOk = false;
    }
  }

  /** 停止局域网共享。 */
  private stopLan(): void {
    // 不看 lanRunning: 上一次启动失败时服务器可能还挂着(那种状态下 lanRunning 是 false),
    // 只看它的话旧服务器永远清不掉 ⇒ 每次「开始共享」都报「已经在共享了」✓
    this.lanServer.stop().then(() => {
      hilog.info(DOMAIN, TAG, '局域网共享已停止');
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, '停止共享失败: %{public}s', e.message ?? '');
    });
    this.lanRunning = false;
    this.lanUrl = '';
  }

  build() {
    Scroll() {
      Column({ space: Space.LG }) {
        if (this.getUIContext().getRouter().getStackSize() > 1) {
          Row() {
            Text('‹ 返回')
              .fontSize(FontSize.BODY)
              .fontColor(this.pal('ACCENT'))
              .onClick(() => { this.getUIContext().getRouter().back(); })
          }
          .width('100%')
        }

        Column({ space: 6 }) {
          Text('DSHsync')
            .fontSize(FontSize.BIG)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pal('TEXT'))
          Text('连接桌面端, 在手机上查看会话并下发指令')
            .fontSize(FontSize.BODY)
            .fontColor(this.pal('TEXT_3'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        // ---- 提醒: 先在电脑的插件市场装插件 ----
        Column({ space: 6 }) {
          Text('电脑端装一个 DSH 插件就能用')
            .fontSize(FontSize.SMALL)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal('ACCENT'))
            .width('100%')
          Text('dsh-harmony-bridge')
            .fontSize(FontSize.BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal('ACCENT'))
            .width('100%')
            .copyOption(CopyOptions.LocalDevice)
          Text('在 DSH 插件市场搜索并安装它, 启用后重启一次 DSH; 桥接会随 DSH 自动启动。'
            + '手机点「自动探测」即可, 不用填地址或令牌。')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_2'))
            .width('100%')
            .lineHeight(17)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(Space.MD)
        .backgroundColor(this.pal('ACCENT_SOFT'))
        .border({ width: 1, color: this.pal('ACCENT') })
        .borderRadius(Radius.MD)

        // ---- 连接状态 ----
        Column({ space: Space.MD }) {
          Row({ space: Space.MD }) {
            Circle()
              .width(10)
              .height(10)
              .fill(this.connectionColor())
            Text(this.connectionText)
              .fontSize(FontSize.BIG)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.connectionTextColor())
            Blank()
            Text(this.remote ? '远程(云中继)' : '局域网')
              .fontSize(FontSize.SMALL)
              .fontColor(this.pal('TEXT_2'))
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor(this.pal('SURFACE_HI'))
              .borderRadius(Radius.PILL)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (this.desktopName.length > 0) {
            Text(this.desktopName)
              .fontSize(FontSize.BODY)
              .fontColor(this.pal('TEXT'))
          }

          Text(this.connectionDescription())
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('TEXT_3'))
            .lineHeight(18)

          // 账号作用域的地址说明: 手机会自己登记到账号下, 不需要额外的令牌。
          if (this.accountId.length > 0) {
            Text(`账号 ${this.accountId} · 这台手机会自动登记到账号下, 桌面端能看到「我的手机 在线」`)
              .fontSize(FontSize.TINY)
              .fontColor(this.pal('TEXT_3'))
          }

          Button(this.paired ? '重新配对' : '自动探测')
            .type(ButtonType.Normal)
            .width('100%')
            .height(40)
            .borderRadius(Radius.SM)
            .backgroundColor(this.pal('SURFACE_HI'))
            .fontColor(this.pal('TEXT'))
            .fontSize(FontSize.BODY)
            .enabled(!this.busy)
            .onClick(() => { this.discover(); })

          // 协议没勾 ⇒ 自动探测按不了 ⇒ 这里给个入口(去设置里勾) ✓
          Row({ space: Space.SM }) {
            Text(this.consentOk ? '已同意《用户协议》和《隐私政策》' : '未同意协议, 自动探测不可用')
              .fontSize(FontSize.TINY)
              .fontColor(this.consentOk ? this.pal('TEXT_3') : this.pal('WARN'))
              .layoutWeight(1)
            Text('去设置')
              .fontSize(FontSize.TINY)
              .fontColor(this.pal('ACCENT'))
              .onClick(() => { this.openSettings(); })
          }
          .width('100%')
          .padding({ top: Space.SM })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(Space.LG)
        .backgroundColor(this.pal('SURFACE'))
        .border({ width: 1, color: this.pal('BORDER') })
        .borderRadius(Radius.LG)

        // 已连接时卡片里已经有绿点 + 大字「已连接」⇒ 这里不再重复一行; 只在
        // 未连接/出错/进行中时显示状态说明, 免得同屏两行"已连接 xxx"。
        if (this.status.length > 0 && !(this.statusOk && this.status.startsWith('已连接'))) {
          Text(this.status)
            .fontSize(FontSize.SMALL)
            .fontColor(this.statusOk ? this.pal('OK') : this.pal('ERROR'))
            .width('100%')
        }

        // ---- 主操作: 切到远程 ----
        Column({ space: Space.SM }) {
          Button(this.remote ? '当前已是远程连接' : '切到远程(经云中继)')
            .type(ButtonType.Normal)
            .width('100%')
            .height(52)
            .borderRadius(Radius.SM)
            .backgroundColor(this.remote ? this.pal('SURFACE_HI') : this.pal('ACCENT_SOLID'))
            .fontColor(this.remote ? this.pal('TEXT_2') : '#FFFFFF')
            .fontSize(FontSize.TITLE)
            .enabled(!this.busy && this.paired && !this.remote)
            .onClick(() => { this.switchToRemote(); })
          Text('离开局域网时用: 点一下, 电脑会把中继地址和令牌自动交给手机。')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .lineHeight(18)
          if (this.remote && this.lanEndpoint.length > 0) {
            Button('切回局域网')
              .type(ButtonType.Normal)
              .width('100%')
              .height(40)
              .borderRadius(Radius.SM)
              .backgroundColor(this.pal('SURFACE_HI'))
              .fontColor(this.pal('TEXT'))
              .fontSize(FontSize.SMALL)
              .enabled(!this.busy)
              .onClick(() => { this.switchBackToLan(); })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(Space.LG)
        .backgroundColor(this.pal('SURFACE'))
        .border({ width: 1, color: this.pal('BORDER') })
        .borderRadius(Radius.LG)

        Column({ space: 8 }) {
          Text('不想装插件? 按下面步骤手动运行桌面端')
            .fontSize(FontSize.SMALL)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal('TEXT_2'))
          Text('把桌面端程序发到电脑运行')
            .fontSize(FontSize.TINY)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal('ACCENT'))
            .padding({ top: 2 })
          Text('1. 在 App 里把「桌面端程序」发到电脑, 解压\n2. 双击「双击我-开始.cmd」运行(电脑需要 Node.js 22+, 没有会自动装)\n3. 窗口里会显示地址和令牌(或二维码)\n4. 回到手机点「自动探测」, 自动找到这台电脑')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .lineHeight(18)
          Text('需要跨网络时再点「切到远程」, 电脑会把中继地址和令牌交给手机')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .lineHeight(18)
            .padding({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(Space.LG)
        .backgroundColor(this.pal('SURFACE'))
        .border({ width: 1, color: this.pal('BORDER') })
        .borderRadius(Radius.LG)

        // 别人只装了 App, 电脑上什么都没有 —— 这里把「电脑那一份」发过去。
        Column({ space: 8 }) {
          Text('电脑上还没有这份东西?')
            .fontSize(FontSize.SMALL)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal('TEXT_2'))
          Text('不想装插件? 用方案二: 把安装包发到电脑, 解压后双击「双击我-开始.cmd」就能跑(电脑要有 Node.js 22 或更高版本)。')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .lineHeight(18)
          Button('把桌面端发到电脑')
            .type(ButtonType.Normal)
            .width('100%')
            .height(40)
            .borderRadius(Radius.SM)
            .backgroundColor(this.pal('SURFACE_HI'))
            .fontColor(this.pal('TEXT'))
            .fontSize(FontSize.SMALL)
            .onClick(() => { this.openSendPanel(); })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(Space.LG)
        .backgroundColor(this.pal('SURFACE'))
        .border({ width: 1, color: this.pal('BORDER') })
        .borderRadius(Radius.LG)

        // ---- 高级(默认收起): 调试/自动化时才用得到的东西 ----
        Column({ space: Space.SM }) {
          Row() {
            Text('高级')
              .fontSize(FontSize.SMALL)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.pal('TEXT_2'))
              .layoutWeight(1)
            Text(this.advancedOpen ? '收起' : '展开')
              .fontSize(FontSize.TINY)
              .fontColor(this.pal('ACCENT'))
          }
          .width('100%')
          .padding({ left: Space.MD, right: Space.MD, top: Space.SM, bottom: Space.SM })
          .backgroundColor(this.pal('SURFACE_HI'))
          .borderRadius(Radius.SM)
          .onClick(() => { this.advancedOpen = !this.advancedOpen; })

          if (this.advancedOpen) {
            Column({ space: 6 }) {
              Row() {
                Text('屏幕常亮')
                  .fontSize(FontSize.SMALL)
                  .fontColor(this.pal('TEXT_2'))
                Blank()
                Text(this.keepScreenOn ? '开' : '关')
                  .fontSize(FontSize.SMALL)
                  .fontColor(this.keepScreenOn ? this.pal('ACCENT') : this.pal('TEXT_3'))
                  .onClick(() => { this.setKeepScreenOn(!this.keepScreenOn); })
              }
              .width('100%')
              .height(40)
              .padding({ left: Space.MD, right: Space.MD })
              .backgroundColor(this.pal('SURFACE'))
              .border({ width: 1, color: this.pal('BORDER') })
              .borderRadius(Radius.SM)

              Text('调试用: 自动化测试时防止手机自动锁屏, 平时可以关掉省电。')
                .fontSize(FontSize.TINY)
                .fontColor(this.pal('TEXT_3'))
                .lineHeight(17)
                .width('100%')

            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(Space.LG)
        .backgroundColor(this.pal('SURFACE'))
        .border({ width: 1, color: this.pal('BORDER') })
        .borderRadius(Radius.LG)
      }
      .width('100%')
      .padding(Space.LG)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .backgroundColor(Color.Transparent)
    .bindSheet($$this.sheetOpen, this.sheetContent(), {
      height: this.sheetMode === 1 ? '75%' : '60%',
      backgroundColor: this.pal('BG_DEEP'),
      dragBar: true,
      showClose: true,
      onWillDismiss: (action: DismissSheetAction) => {
        // **这里不停局域网共享**: 用法就是「点开始共享 → 关掉这个弹层 → 切到电脑的
        // 浏览器 → 输入那个地址下载」。在这儿停了, 电脑那边就下不到了 ✓
        // 不调 dismiss() 的话弹层不会真的关掉。
        action.dismiss();
      }
    })
  }

  /** 弹层内容: 两个模式共用一个弹层(一个节点只能有一个 bindSheet)。 */
  @Builder
  sheetContent() {
    if (this.sheetMode === 1) {
      this.sendSheetContent()
    } else {
      this.foundSheetContent()
    }
  }

  /** 扫到的桌面端列表。 */
  @Builder
  foundSheetContent() {
    Column({ space: Space.SM }) {
      Text('附近的桌面端')
        .fontSize(FontSize.TITLE)
        .fontColor(this.pal('TEXT'))
        .width('100%')
      if (this.desktops.length === 0) {
        Text('还没找到。确认电脑上的 bridge 启动了, 并且和手机在同一个 WiFi。')
          .fontSize(FontSize.SMALL)
          .fontColor(this.pal('TEXT_3'))
          .width('100%')
      } else {
        ForEach(this.desktops, (desktop: DesktopInfo) => {
          Row({ space: Space.MD }) {
            Column({ space: 2 }) {
              Text(desktop.name)
                .fontSize(FontSize.BODY)
                .fontColor(this.pal('TEXT'))
              Text(desktop.url)
                .fontSize(FontSize.TINY)
                .fontColor(this.pal('TEXT_3'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button('连接')
              .type(ButtonType.Normal)
              .height(32)
              .borderRadius(Radius.SM)
              .backgroundColor(this.pal('ACCENT_SOLID'))
              .fontColor('#FFFFFF')
              .fontSize(FontSize.SMALL)
              .onClick(() => { this.connectTo(desktop); })
          }
          .width('100%')
          .padding(Space.MD)
          .backgroundColor(this.pal('SURFACE'))
          .border({ width: 1, color: this.pal('BORDER') })
          .borderRadius(Radius.SM)
        }, (desktop: DesktopInfo) => desktop.url)
      }
    }
    .padding(Space.LG)
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 方案选择的小胶囊 */
  @Builder
  sendSchemeChip(title: string, value: number) {
    Text(title)
      .fontSize(FontSize.SMALL)
      .fontColor(this.sendScheme === value ? '#FFFFFF' : this.pal('TEXT_2'))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(36)
      .backgroundColor(this.sendScheme === value ? this.pal('ACCENT_SOLID') : this.pal('SURFACE_HI'))
      .borderRadius(Radius.PILL)
      .onClick(() => { this.sendScheme = value; })
  }

  /** 「把桌面端发到电脑」面板。 */
  @Builder
  sendSheetContent() {
    Scroll() {
      Column({ space: Space.MD }) {
        Text('把桌面端发到电脑')
          .fontSize(FontSize.TITLE)
          .fontColor(this.pal('TEXT'))
          .width('100%')
        Text('电脑上还没有这份东西? 两种办法: 装 DSH 插件(推荐, 一次搞定), 或把安装包发到电脑手动启动。')
          .fontSize(FontSize.SMALL)
          .fontColor(this.pal('TEXT_3'))
          .width('100%')
          .lineHeight(18)
        Text(this.packageSize.length > 0 ? `安装包: ${this.packageSize}` : '安装包: App 内置的那份')
          .fontSize(FontSize.TINY)
          .fontColor(this.pal('TEXT_3'))
          .width('100%')
          .lineHeight(16)

        Row({ space: Space.SM }) {
          this.sendSchemeChip('方案一 · 装 DSH 插件', 0)
          this.sendSchemeChip('方案二 · 发送文件', 1)
        }
        .width('100%')

        if (this.sendScheme === 0) {
          Text('在电脑的 DeepSeek Harness 里装一次插件 —— 以后换电脑也不用再传文件。')
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('TEXT_2'))
            .width('100%')
            .lineHeight(18)
          Text('1. 电脑打开 DeepSeek Harness → 设置 → 插件市场\n'
            + '2. 搜索 dsh-harmony-bridge → 安装 → 重启 DSH\n'
            + '3. 装好后桥接随 DSH 自动启动, 回到手机点「自动发现」')
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('TEXT'))
            .width('100%')
            .lineHeight(20)
            .padding(Space.MD)
            .backgroundColor(this.pal('CARD'))
            .borderRadius(Radius.SM)
            .border({ width: 1, color: this.pal('BORDER_SOFT') })
          Text('没有插件市场 / 想离线装: 在插件管理器里选「从本地文件安装」, 选 dsh-harmony-bridge-0.1.0.tgz。')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .width('100%')
            .lineHeight(17)
          Text('插件开源地址(长按复制):')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .width('100%')
          Text('https://github.com/zhouyan19920115/dsh-harmony')
            .fontSize(FontSize.BODY)
            .fontColor(this.pal('ACCENT'))
            .width('100%')
            .copyOption(CopyOptions.LocalDevice)
          Text('插件内容: LAN 自动发现 + 带令牌的 HTTP/WebSocket + 可选云中继, 零第三方依赖。')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .width('100%')
            .lineHeight(17)
        } else {
          Text('方式 2.1 · 局域网发送')
          .fontSize(FontSize.SMALL)
          .fontColor(this.pal('ACCENT'))
          .width('100%')
        Text('电脑浏览器打开下面的地址下载, 解压后双击「双击我-开始.cmd」。')
          .fontSize(FontSize.TINY)
          .fontColor(this.pal('TEXT_3'))
          .width('100%')
          .lineHeight(16)
        if (this.lanUrl.length > 0) {
          Text(this.lanUrl)
            .fontSize(FontSize.BODY)
            .fontColor(this.pal('ACCENT'))
            .width('100%')
            .copyOption(CopyOptions.LocalDevice)
          Text('长按这行可以复制地址')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .width('100%')
            .lineHeight(16)
        }
        Row({ space: Space.SM }) {
          Button(this.lanRunning ? '重新开始共享' : '开始共享')
            .type(ButtonType.Normal)
            .layoutWeight(1)
            .height(40)
            .borderRadius(Radius.SM)
            .backgroundColor(this.pal('ACCENT_SOLID'))
            .fontColor('#FFFFFF')
            .fontSize(FontSize.SMALL)
            .onClick(() => { this.startLan(); })
          Button('停止共享')
            .type(ButtonType.Normal)
            .layoutWeight(1)
            .height(40)
            .borderRadius(Radius.SM)
            .backgroundColor(this.pal('SURFACE_HI'))
            .fontColor(this.pal('TEXT'))
            .fontSize(FontSize.SMALL)
            .enabled(this.lanRunning)
            .onClick(() => { this.stopLan(); })
        }
        .width('100%')

          Text('方式 2.2 · 保存到手机 → 文件管理 → 分享给电脑')
          .fontSize(FontSize.SMALL)
          .fontColor(this.pal('ACCENT'))
          .width('100%')
        Text('1. 保存到手机: 把安装包存进手机的「文件」\n2. 在文件管理里找到它\n3. 长按 → 分享 → 选 微信 / 蓝牙 / 无线分享 / 星闪 → 选那台电脑')
          .fontSize(FontSize.TINY)
          .fontColor(this.pal('TEXT_3'))
          .width('100%')
          .lineHeight(18)
        Button('保存到手机')
          .type(ButtonType.Normal)
          .width('100%')
          .height(44)
          .borderRadius(Radius.SM)
          .backgroundColor(this.pal('SURFACE_HI'))
          .fontColor(this.pal('TEXT'))
          .fontSize(FontSize.BODY)
          .onClick(() => { this.saveToPhone(); })
        Text('存完就打开文件管理, 在里面长按这个文件就能分享给电脑。')
          .fontSize(FontSize.TINY)
          .fontColor(this.pal('TEXT_3'))
          .width('100%')
          .lineHeight(16)

        if (this.savedPath.length > 0) {
          Text(`已保存: ${this.savedPath}`)
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .width('100%')
            .lineHeight(16)
        }

        if (this.publicUri.length > 0) {
          Text(`已存到手机的「文件」: ${this.publicUri}`)
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
            .width('100%')
            .lineHeight(16)
        }

        if (this.sendStatus.length > 0) {
          Text(this.sendStatus)
            .fontSize(FontSize.SMALL)
            .fontColor(this.sendOk ? this.pal('OK') : this.pal('ERROR'))
            .width('100%')
            .lineHeight(18)
        }

        }

        Text('装好之后: 手机点「自动发现」→ 选中这台电脑 → 不用输令牌。')
          .fontSize(FontSize.SMALL)
          .fontColor(this.pal('TEXT_2'))
          .width('100%')
          .lineHeight(18)
          .padding({ top: Space.SM })
          .border({ width: { top: 1 }, color: this.pal('BORDER') })
      }
      .padding(Space.LG)
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .backgroundImage(this.backdropImage())
    .backgroundImageSize(ImageSize.Cover)
    .backgroundImagePosition(Alignment.Bottom)
    .padding({ top: this.topSafeVp, bottom: this.bottomSafeVp })
  }
}
