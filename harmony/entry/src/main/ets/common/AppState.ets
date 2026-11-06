/**
 * 全局共享状态。
 *
 * 只有一个 BridgeClient 实例, 页面之间共享它, 避免重复建连。
 *
 * **令牌以内存里的为准** —— 盘上那份可能被 HUKS 的钥匙问题废掉,
 * 但这一轮进程里它明明还能用 ⇒ 别用空的把它盖掉 ✓
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BridgeClient, BridgeListener } from './BridgeClient';
import { ConfigStore, BridgeConfig } from './Config';
import { DesktopInfo, discoverDesktops, freshPairingCode, pairWith } from './Discovery';
import { LegalStore, ConsentState } from './Legal';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF00;

export class AppState {
  static readonly client: BridgeClient = new BridgeClient();
  static config: BridgeConfig = {
    endpoint: '127.0.0.1:8787',
    token: '',
    paired: false,
    deviceId: '',
    deviceToken: ''
  };
  /** 正在跑的那次自动配对(别重复跑 ✓) */
  private static pairing: Promise<boolean> | null = null;

  /**
   * 从本地配置恢复连接参数。
   *
   * **盘上的令牌可能解不开**(HUKS 那边的钥匙没了), 但这一轮进程里它明明还能用 ⇒
   * **别用空的把它盖掉** ✓ —— 否则每回一次连接页, 好端端的登录态就没了 ✗
   */
  static async restore(): Promise<BridgeConfig> {
    AppState.ensureWired();
    let stored: BridgeConfig;
    try {
      stored = await ConfigStore.load();
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, '读配置失败, 用内存里的: %{public}s', err?.message ?? '');
      stored = AppState.config;
    }
    const memory: BridgeConfig = AppState.config;
    const merged: BridgeConfig = {
      endpoint: stored.endpoint.length > 0 ? stored.endpoint : memory.endpoint,
      token: stored.token.length > 0 ? stored.token : memory.token,
      paired: stored.paired || memory.token.length > 0,
      deviceId: stored.deviceId.length > 0 ? stored.deviceId : memory.deviceId,
      deviceToken: stored.deviceToken.length > 0 ? stored.deviceToken : memory.deviceToken
    };
    AppState.config = merged;
    AppState.client.setEndpoint(merged.endpoint, merged.token);
    AppState.client.setAccount(merged.deviceId, merged.deviceToken, '我的手机');
    return merged;
  }

  /** 现在是不是「已经登录」了(手里有令牌 ✓)。 */
  static isLoggedIn(): boolean {
    return AppState.config.token.length > 0;
  }

  /**
   * 连接状态的说法: 「已连接」/「重连中…」/「未连接」✓
   *
   * **所有页面都从这里拿**(客户端那一份是唯一真源)⇒
   * 不会再出现"连接页说已连接、会话列表页说未连接"这种自相矛盾 ✓
   *
   * 用户抱怨的"状态一会已连接一会未连接"就是各页面各写各的二值判断造成的,
   * 现在统一成三态, 而且「重连中…」是一个**中性说法**(数据照样能加载)✓
   */
  static connectionLabel(): string {
    return AppState.client.connectionLabel();
  }

  /** 连接状态的一句话说明(给状态旁边那行小字用)✓ */
  static connectionHint(): string {
    return AppState.client.connectionHint();
  }

  /**
   * 是不是「什么可用的都没有」⇒ 得重新配对一次 ✓
   *
   * 两种情况都算:
   * - 手里没令牌(没配过, 或者盘上那份解不开——HUKS 的钥匙没了 ✓)
   * - 连地址都没有(盘上存的是加密的中继地址, 解不开就落回默认的 127.0.0.1:8787 ✓)
   */
  static needsPairing(): boolean {
    if (!AppState.isLoggedIn()) {
      return true;
    }
    return AppState.config.endpoint === '127.0.0.1:8787';
  }

  /** 保存并应用新的连接参数。 */
  static async apply(endpoint: string, token: string): Promise<void> {
    AppState.ensureWired();
    const trimmedEndpoint: string = endpoint.trim();
    const trimmedToken: string = token.trim();
    // 设备号与设备令牌是手机自己的身份, 第一次用的时候生成一次就固定下来。
    let deviceId: string = AppState.config.deviceId;
    let deviceToken: string = AppState.config.deviceToken;
    if (deviceId.length === 0 || deviceToken.length === 0) {
      deviceId = AppState.newDeviceId();
      deviceToken = AppState.newDeviceToken();
    }
    const config: BridgeConfig = {
      endpoint: trimmedEndpoint,
      token: trimmedToken,
      paired: true,
      deviceId: deviceId,
      deviceToken: deviceToken
    };
    AppState.config = config;
    AppState.client.setEndpoint(config.endpoint, config.token);
    AppState.client.setAccount(config.deviceId, config.deviceToken, '我的手机');
    try {
      await ConfigStore.save(config);
    } catch (e) {
      // **存盘失败不影响这一轮使用** —— 令牌在内存里照样能连 ✓
      // (盘上那份存的是密文, 存不上就等下次自动配对再写 ✓)
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '令牌存盘失败(这轮仍能用): %{public}s', err?.message ?? '');
    }
  }

  /**
   * 自愈: 令牌不行了就自动重新配对一次, 然后重连 ✓
   *
   * 触发时机: 首帧认证没过(401 / "the first frame has to carry the token") ✓
   */
  private static async repair(): Promise<void> {
    if (AppState.repairing) {
      return;
    }
    AppState.repairing = true;
    try {
      hilog.warn(DOMAIN, TAG, '令牌不行了, 自动重新配对一次');
      const ok: boolean = await AppState.autoPair(true);
      if (ok) {
        AppState.client.connect();
        hilog.info(DOMAIN, TAG, '自动重新配对成功, 已重连');
      } else {
        hilog.warn(DOMAIN, TAG, '自动重新配对失败, 等用户自己来连');
      }
    } finally {
      AppState.repairing = false;
    }
  }

  /** 正在自愈(别重复来 ✓) */
  private static repairing: boolean = false;
  /** 自愈的回调有没有接上 ✓ */
  private static wired: boolean = false;
  /** 看门狗的定时器 ✓ */
  private static watchdog: number = -1;

  /**
   * 看门狗: 每 30 秒看一眼自己是不是「什么可用的都没有」⇒ 再配一次 ✓
   *
   * **为什么需要它**: 手机启动的时候电脑不在同一个网(或者用户还没回到 WiFi),
   * 那一次自动配对就失败了; 等人回到 WiFi 之后没人再叫它一声 ⇒
   * 一直卡在 127.0.0.1:8787 上 ✗
   *
   * 该配就配, 有令牌就保证连接活着 ✓ —— 用户什么都不用点 ✓
   */
  private static tick(): void {
    if (AppState.pairing !== null) {
      return;
    }
    if (AppState.needsPairing()) {
      hilog.info(DOMAIN, TAG, '看门狗: 还没有可用的连接, 再自动配对一次');
      AppState.autoPair();
      return;
    }
    // 正在重连就别插手了 —— 客户端自己会退避重试, 这里再插一脚只是两边抢,
    // 反而把重连的节奏搅乱(状态灯才会来回跳)✓
    if (!AppState.client.isConnected() && !AppState.client.isReconnecting()) {
      AppState.client.connect();
    }
  }

  /**
   * 把「首帧认证失败 ⇒ 自动重新配对」这条线接上 ✓
   *
   * 只能接一次(客户端是全局单例 ✓)。
   */
  static ensureWired(): void {
    if (AppState.wired) {
      return;
    }
    AppState.wired = true;
    const listener: BridgeListener = new BridgeListener();
    listener.onAuthFailed = (): void => {
      AppState.repair();
    };
    AppState.client.addListener(listener);
    // 看门狗: 网络回来以后没人叫它 ⇒ 自己叫自己 ✓
    if (AppState.watchdog < 0) {
      AppState.watchdog = setInterval((): void => {
        AppState.tick();
      }, 30000);
    }
  }

  /**
   * 用户同意了吗(隐私政策 + 用户协议都勾了才算 ✓)。
   *
   * 自动探测要在**扫网之前**问一句 —— 没同意就不扫 ✓
   */
  static async hasConsent(): Promise<boolean> {
    try {
      const state: ConsentState = await LegalStore.load();
      return LegalStore.accepted(state);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, '读协议状态失败, 按「没同意」处理: %{public}s', err?.message ?? '');
      return false;
    }
  }

  /**
   * 自动配对: 自己找到电脑, 拿配对码换令牌 —— **用户不用管地址和令牌** ✓
   *
   * 盘上的令牌解不开时(钥匙没了)就用这个自救: App 启动时自动跑一次,
   * 或者用户在连接页点「自动探测」✓
   *
   * 已经在配对的话就**等它配完** —— 别重复扫一遍网 ✓
   *
   * @param force 手里那个令牌已经不管用了 ⇒ 把它扔掉重配 ✓
   * @returns 配上了吗
   */
  static async autoPair(force: boolean = false): Promise<boolean> {
    // 用户还没勾协议 ⇒ 不许自动扫网 ✓ (手动输入地址不受影响)
    if (!await AppState.hasConsent()) {
      hilog.warn(DOMAIN, TAG, '还没同意隐私政策/用户协议, 跳过自动配对');
      return false;
    }
    const running: Promise<boolean> | null = AppState.pairing;
    if (running !== null) {
      // 已经在配对了 ⇒ 等它配完(别重复扫一遍网 ✓)
      return await running;
    }
    const task: Promise<boolean> = AppState.doAutoPair(force);
    AppState.pairing = task;
    try {
      return await task;
    } finally {
      AppState.pairing = null;
    }
  }

  /** 真正去配对的那段活儿。 */
  private static async doAutoPair(force: boolean): Promise<boolean> {
    if (!force && AppState.isLoggedIn()) {
      return true;
    }
    if (force) {
      // 手里这个令牌已经被拒绝了 ⇒ 先扔掉, 不然配完还是用它 ✓
      AppState.config.token = '';
      AppState.client.setEndpoint(AppState.config.endpoint, '');
    }
    try {
      const found: DesktopInfo[] = await discoverDesktops(() => {});
      for (const desktop of found) {
        if (desktop.code.length === 0) {
          continue;
        }
        try {
          // 扫描本身就要好几秒 ⇒ 码可能已经换了, 先刷新成当前那个 ✓
          const paired = await pairWith(desktop.url, await freshPairingCode(desktop));
          await AppState.apply(desktop.url, paired.token);
          AppState.client.connect();
          hilog.info(DOMAIN, TAG, '自动配对成功: %{public}s', desktop.name);
          return true;
        } catch (e) {
          const err = e as BusinessError;
          hilog.warn(DOMAIN, TAG, '自动配对失败(%{public}s): %{public}s', desktop.name, err?.message ?? '');
        }
      }
      hilog.warn(DOMAIN, TAG, '自动配对失败: 没找到能配对的电脑');
      return false;
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, '自动配对失败: %{public}s', err?.message ?? '');
      return false;
    }
  }

  /** 随机的设备号: dev- + 6 位十六进制。 */
  private static newDeviceId(): string {
    let suffix: string = '';
    for (let i = 0; i < 6; i++) {
      suffix += Math.floor(Math.random() * 16).toString(16);
    }
    return `dev-${suffix}`;
  }

  /** 随机的设备令牌: 32 字节的十六进制。 */
  private static newDeviceToken(): string {
    let token: string = '';
    for (let i = 0; i < 64; i++) {
      token += Math.floor(Math.random() * 16).toString(16);
    }
    return token;
  }
}
