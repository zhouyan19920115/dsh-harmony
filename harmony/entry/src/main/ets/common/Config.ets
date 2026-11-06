/**
 * 本地配置持久化。
 *
 * 使用 @ohos.data.preferences 保存 "桌面端地址 + 令牌", 让用户只配对一次。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { decrypt, encrypt } from './HukStore';
import { maskEndpoint } from './Seal';
import { explain } from './ErrorText';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF02;

const STORE_NAME: string = 'dsh_harmony_bridge';
const KEY_ENDPOINT: string = 'endpoint';
/** 远端/中继地址的密文(局域网的地址不敏感, 留在明文那一栏)。 */
const KEY_ENDPOINT_ENC: string = 'endpointEncrypted';
const KEY_HOST: string = 'host';
const KEY_PORT: string = 'port';
const KEY_TOKEN: string = 'token';
const KEY_TOKEN_ENC: string = 'tokenEncrypted';
const KEY_PAIRED: string = 'paired';
const KEY_DEVICE_ID: string = 'deviceId';
const KEY_DEVICE_TOKEN: string = 'deviceToken';
/** 本机设备令牌的密文(它也是凭据 ⇒ 跟桥接令牌一样加密存 ✓)。 */
const KEY_DEVICE_TOKEN_ENC: string = 'deviceTokenEncrypted';
const KEY_KEEP_SCREEN_ON: string = 'keepScreenOn';
const KEY_CERT_HOST: string = 'certHost';
const KEY_CERT_SHA256: string = 'certSha256';

/** HUKS 里加密远端地址时用的用途(决定 AAD)。 */
const PURPOSE_ENDPOINT: string = 'endpoint';
/** HUKS 里加密本机设备令牌时用的用途。 */
const PURPOSE_DEVICE: string = 'device';

export interface BridgeConfig {
  /** 桌面端地址, 可以是完整 URL(支持云中继的路径前缀) */
  endpoint: string;
  token: string;
  paired: boolean;
  /** 本机(手机)在账号里的设备号, 第一次登记时生成 */
  deviceId: string;
  /** 本机(手机)在账号里的设备令牌, 第一次登记时生成 */
  deviceToken: string;
}

export class ConfigStore {
  private static store: preferences.Preferences | null = null;
  private static context: common.UIAbilityContext | null = null;

  /** 初始化(在 EntryAbility.onCreate 里调用)。 */
  static init(context: common.UIAbilityContext): void {
    ConfigStore.context = context;
  }

  private static async ensureStore(): Promise<preferences.Preferences> {
    if (ConfigStore.store !== null) {
      return ConfigStore.store;
    }
    const context = ConfigStore.context;
    if (context === null) {
      throw new Error('本地配置还没初始化, 重启一下 App 就好');
    }
    hilog.info(DOMAIN, TAG, 'ensureStore: getPreferences %{public}s', STORE_NAME);
    try {
      const store = await preferences.getPreferences(context, { name: STORE_NAME });
      ConfigStore.store = store;
      return store;
    } catch (e) {
      const err = e as BusinessError;
      // 系统的报错是英文 ⇒ 解释一遍 ✓
      throw new Error(`打开本地配置失败: ${explain(err.message ?? '')}`);
    }
  }

  /**
   * 这个 host 是不是局域网的。
   *
   * 局域网地址不是秘密 —— 用户要能一眼看出自己连的是哪台电脑 ⇒ 留在明文那一栏 ✓
   */
  private static isPrivateHost(hostPort: string): boolean {
    let host: string = hostPort;
    const colon: number = hostPort.lastIndexOf(':');
    if (colon > 0 && /^\d+$/.test(hostPort.substring(colon + 1))) {
      host = hostPort.substring(0, colon);
    }
    const lower: string = host.toLowerCase();
    if (lower === 'localhost' || lower.endsWith('.local')) {
      return true;
    }
    if (lower === '10.0.2.2') {
      // 模拟器里宿主机就是这个别名 ⇒ 算局域网
      return true;
    }
    if (lower.startsWith('127.') || lower.startsWith('10.') || lower.startsWith('192.168.')) {
      return true;
    }
    if (lower.startsWith('172.')) {
      const parts: string[] = lower.split('.');
      if (parts.length >= 2) {
        const second: number = Number.parseInt(parts[1], 10);
        if (second >= 16 && second <= 31) {
          return true;
        }
      }
    }
    return false;
  }

  /**
   * 这个地址是不是「远端/中继」那一类。
   *
   * 判据: 带路径作用域(账号/设备号)的都是中继地址; 或者 host 不在局域网里。
   * 这两类地址里藏着账号号/设备号 ⇒ **和令牌一样用 HUKS 加密存** ✓
   */
  private static isRelayEndpoint(endpoint: string): boolean {
    const text: string = (endpoint ?? '').trim();
    if (text.length === 0) {
      return false;
    }
    const withoutScheme: string = text.replace(/^[a-z][a-z0-9+.-]*:\/\//iu, '');
    const slash: number = withoutScheme.indexOf('/');
    if (slash >= 0 && slash < withoutScheme.length - 1) {
      return true;
    }
    return !ConfigStore.isPrivateHost(withoutScheme.split('/')[0]);
  }

  /** 读取配置; 未配置过时返回默认值。 */
  static async load(): Promise<BridgeConfig> {
    try {
      const store = await ConfigStore.ensureStore();
      const stored: string = await store.get(KEY_TOKEN, '') as string;
      const encrypted: boolean = await store.get(KEY_TOKEN_ENC, false) as boolean;
      const paired = await store.get(KEY_PAIRED, false) as boolean;
      let token: string = stored;
      if (stored.length > 0) {
        if (encrypted) {
          // 新版本: preferences 里只有密文 ✓
          try {
            token = await decrypt(stored);
          } catch (e) {
            // 钥匙没了(重装/换机/密钥失效)⇒ 密文解不开。
            // 这时候**不能退回明文**, 也不能假装还配着: 清掉, 让用户重新配对 ✓
            const err = e as BusinessError;
            hilog.warn(DOMAIN, TAG, '令牌解不开(钥匙没了?), 需要重新配对: code %{public}d %{public}s',
              err.code ?? -1, err.message ?? '');
            await store.put(KEY_TOKEN, '');
            await store.put(KEY_TOKEN_ENC, false);
            await store.put(KEY_PAIRED, false);
            await store.flush();
            token = '';
          }
        } else {
          // 老版本存的是明文 —— 顺手用 HUKS 加密回写 ✓
          // **不挡着启动**: 令牌这一轮照常用, 加密在后台跑 ✓
          token = stored;
          ConfigStore.migrateToken(store, stored).catch((error: BusinessError) => {
            hilog.error(DOMAIN, TAG, '令牌加密失败, 这一轮先用明文: %{public}s', error?.message ?? 'unknown');
          });
        }
      }
      // 地址: 远端/中继的那一份是密文, 局域网的那一份是明文 ✓
      let endpoint: string = await ConfigStore.loadEndpoint(store);
      if (endpoint.length === 0) {
        const oldHost: string = await store.get(KEY_HOST, '') as string;
        const oldPort: number = await store.get(KEY_PORT, 0) as number;
        if (oldHost.length > 0 && oldPort > 0) {
          endpoint = `${oldHost}:${oldPort}`;
        }
      }
      if (endpoint.length === 0) {
        endpoint = '127.0.0.1:8787';
      }
      hilog.info(DOMAIN, TAG, 'ConfigStore.load -> %{public}s paired=%{public}s', maskEndpoint(endpoint), `${paired}`);
      const deviceId: string = await store.get(KEY_DEVICE_ID, '') as string;
      const deviceToken: string = await ConfigStore.loadDeviceToken(store);
      return {
        endpoint: endpoint,
        token: token,
        paired: paired,
        deviceId: deviceId,
        deviceToken: deviceToken
      };
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'ConfigStore.load failed: %{public}s', err.message ?? 'unknown');
      return {
        endpoint: '127.0.0.1:8787',
        token: '',
        paired: false,
        deviceId: '',
        deviceToken: ''
      };
    }
  }

  /**
   * 读本机的设备令牌。
   *
   * 它也是凭据(手机用它在中继/桥接面前证明自己) ⇒ 跟桥接令牌一样加密存 ✓
   * 老版本存的是明文 ⇒ 读的时候顺手加密回写 ✓
   */
  private static async loadDeviceToken(store: preferences.Preferences): Promise<string> {
    const cipher: string = await store.get(KEY_DEVICE_TOKEN_ENC, '') as string;
    if (cipher.length > 0) {
      try {
        return await decrypt(cipher, PURPOSE_DEVICE);
      } catch (e) {
        // 钥匙没了 ⇒ 这台设备得重新登记, 但**不退回明文** ✓
        const err = e as BusinessError;
        hilog.warn(DOMAIN, TAG, '设备令牌解不开(钥匙没了?), 需要重新登记: %{public}s', err.message ?? '');
        await store.put(KEY_DEVICE_TOKEN_ENC, '');
        await store.flush();
        return '';
      }
    }
    const plain: string = await store.get(KEY_DEVICE_TOKEN, '') as string;
    if (plain.length > 0) {
      // 加密在后台跑 —— 别挡着启动 ✓
      ConfigStore.migrateDeviceToken(store, plain).catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, '设备令牌加密失败, 这一轮先用明文: %{public}s', error?.message ?? 'unknown');
      });
    }
    return plain;
  }

  /** 把明文的设备令牌换成密文(老数据迁移 ✓)。 */
  private static async migrateDeviceToken(store: preferences.Preferences, plain: string): Promise<void> {
    try {
      const migrated: string = await encrypt(plain, PURPOSE_DEVICE);
      await store.put(KEY_DEVICE_TOKEN_ENC, migrated);
      await store.put(KEY_DEVICE_TOKEN, '');
      await store.flush();
      hilog.info(DOMAIN, TAG, '设备令牌已用 HUKS 加密回写(老数据迁移)');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '设备令牌加密失败, 不落明文: %{public}s', err.message ?? 'unknown');
      throw new Error(`设备令牌加密失败: ${explain(err.message ?? '')}`);
    }
  }

  /**
   * 把明文令牌换成密文(老数据迁移 ✓)。
   *
   * HUKS 用不了就报错 —— **不静默退回明文** ✓
   */
  private static async migrateToken(store: preferences.Preferences, plain: string): Promise<void> {
    try {
      const cipher: string = await encrypt(plain);
      await store.put(KEY_TOKEN, cipher);
      await store.put(KEY_TOKEN_ENC, true);
      await store.flush();
      hilog.info(DOMAIN, TAG, '令牌已用 HUKS 加密回写(老数据迁移)');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '令牌加密失败, 不落明文: %{public}s', err.message ?? 'unknown');
      throw new Error(`令牌加密失败: ${explain(err.message ?? '')}`);
    }
  }

  /**
   * 把明文远端地址换成密文(老数据迁移 ✓)。
   *
   * 规矩跟令牌一样: HUKS 用不了就报错, **不静默退回明文** ✓
   */
  private static async migrateEndpoint(store: preferences.Preferences, plain: string): Promise<void> {
    try {
      const cipher: string = await encrypt(plain, PURPOSE_ENDPOINT);
      await store.put(KEY_ENDPOINT_ENC, cipher);
      await store.put(KEY_ENDPOINT, '');
      await store.flush();
      hilog.info(DOMAIN, TAG, '远端地址已用 HUKS 加密回写(老数据迁移)');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '远端地址加密失败, 不落明文: %{public}s', err.message ?? 'unknown');
      throw new Error(`远端地址加密失败: ${explain(err.message ?? '')}`);
    }
  }

  /**
   * 读地址。
   *
   * 远端/中继地址在密文那一栏(KEY_ENDPOINT_ENC); 局域网地址在明文那一栏。
   * 老版本把中继地址写在明文那一栏 ⇒ 读的时候顺手加密回写 ✓
   */
  private static async loadEndpoint(store: preferences.Preferences): Promise<string> {
    const cipher: string = await store.get(KEY_ENDPOINT_ENC, '') as string;
    if (cipher.length > 0) {
      try {
        return await decrypt(cipher, PURPOSE_ENDPOINT);
      } catch (e) {
        // 钥匙没了 ⇒ 密文解不开。清掉, 让用户重新配对(**不退回明文**) ✓
        const err = e as BusinessError;
        hilog.warn(DOMAIN, TAG, '远端地址解不开(钥匙没了?), 需要重新配对: %{public}s', err.message ?? '');
        await store.put(KEY_ENDPOINT_ENC, '');
        await store.flush();
        return '';
      }
    }
    const plain: string = await store.get(KEY_ENDPOINT, '') as string;
    if (plain.length > 0 && ConfigStore.isRelayEndpoint(plain)) {
      // 老版本把中继地址写在明文那一栏 ⇒ 顺手加密回写。
      // **但别挡着启动**: HUKS 在慢机器/模拟器上可能磨好几秒, 首屏等不起 ✓
      // 地址照常用(这一轮还是内存里的明文), 迁移在后台跑; 下次 save() 时也是密文 ✓
      ConfigStore.migrateEndpoint(store, plain).catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, '远端地址加密失败, 这一轮先用明文: %{public}s', error?.message ?? 'unknown');
      });
    }
    return plain;
  }

  /** 保存配置。 */
  static async save(config: BridgeConfig): Promise<void> {
    try {
      const store = await ConfigStore.ensureStore();
      hilog.info(DOMAIN, TAG, 'save: put endpoint=%{public}s', maskEndpoint(config.endpoint));
      // 远端/中继地址和令牌一样用 HUKS 加密存 ✓
      // 局域网地址留明文 —— 用户要能一眼看出自己连的是哪台电脑, 它不是秘密 ✓
      if (ConfigStore.isRelayEndpoint(config.endpoint)) {
        const cipher: string = config.endpoint.length > 0 ? await encrypt(config.endpoint, PURPOSE_ENDPOINT) : '';
        await store.put(KEY_ENDPOINT_ENC, cipher);
        await store.put(KEY_ENDPOINT, '');
      } else {
        await store.put(KEY_ENDPOINT, config.endpoint);
        await store.put(KEY_ENDPOINT_ENC, '');
      }
      // 令牌一律加密存 ✓ —— 明文不落盘 ✓
      const cipher: string = config.token.length > 0 ? await encrypt(config.token) : '';
      await store.put(KEY_TOKEN, cipher);
      await store.put(KEY_TOKEN_ENC, config.token.length > 0);
      await store.put(KEY_PAIRED, config.paired);
      await store.put(KEY_DEVICE_ID, config.deviceId);
      // 本机设备令牌也是凭据 ⇒ 加密存 ✓
      const deviceCipher: string = config.deviceToken.length > 0
        ? await encrypt(config.deviceToken, PURPOSE_DEVICE) : '';
      await store.put(KEY_DEVICE_TOKEN_ENC, deviceCipher);
      await store.put(KEY_DEVICE_TOKEN, '');
      await store.flush();
      const readBack: string = await store.get(KEY_ENDPOINT, '') as string;
      const readBackEnc: string = await store.get(KEY_ENDPOINT_ENC, '') as string;
      hilog.info(DOMAIN, TAG, 'save: flushed, 明文地址=%{public}s, 密文地址=%{public}d 字节',
        maskEndpoint(readBack), readBackEnc.length);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'ConfigStore.save failed: %{public}s', err.message ?? 'unknown');
      // 系统的报错是英文 ⇒ 解释一遍, 别把英文直接甩给用户 ✓
      throw new Error(`保存配置失败: ${explain(err.message ?? '')}`);
    }
  }

  /**
   * 记住某个 host 的证书指纹(用户第一次核对通过之后)。
   *
   * 存的是指纹, 不是钥匙 ✓ —— 换机/重装之后可以直接重新核对 ✓
   */
  /**
   * 屏幕常亮(调试用 ✓)。
   *
   * 真机几十秒就自动锁屏 ⇒ `aa start` 直接被拒(10106102 ✓)⇒ 自动化全做不了 ✓
   * ⇒ 开着它, 无人值守的验收才成立 ✓
   */
  static async loadKeepScreenOn(): Promise<boolean> {
    try {
      const store = await ConfigStore.ensureStore();
      return await store.get(KEY_KEEP_SCREEN_ON, true) as boolean;
    } catch (e) {
      return true;
    }
  }

  /** 存屏幕常亮开关 ✓。 */
  static async saveKeepScreenOn(value: boolean): Promise<void> {
    try {
      const store = await ConfigStore.ensureStore();
      await store.put(KEY_KEEP_SCREEN_ON, value);
      await store.flush();
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, '常亮开关存不了: %{public}s', err.message ?? 'unknown');
    }
  }

  static async saveCertificateFingerprint(host: string, sha256: string): Promise<void> {
    const store = await ConfigStore.ensureStore();
    try {
      await store.put(KEY_CERT_HOST, host);
      await store.put(KEY_CERT_SHA256, sha256);
      await store.flush();
      // 指纹本身不是秘密(公钥摘要), 但 host 可能是远端地址 ⇒ 打码 ✓
      hilog.info(DOMAIN, TAG, '证书指纹已记住: %{public}s', maskEndpoint(host));
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, '保存证书指纹失败: %{public}s', err.message ?? '');
    }
  }

  /**
   * 记住过的证书指纹。
   *
   * @param host 主机名(带端口)
   * @returns 指纹; 没记住过就是空串
   */
  static async loadCertificateFingerprint(host: string): Promise<string> {
    const store = await ConfigStore.ensureStore();
    try {
      const knownHost: string = await store.get(KEY_CERT_HOST, '') as string;
      if (knownHost !== host) {
        return '';
      }
      return await store.get(KEY_CERT_SHA256, '') as string;
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, '读证书指纹失败: %{public}s', err.message ?? '');
      return '';
    }
  }

  /** 清除配对信息。 */
  static async clear(): Promise<void> {
    const store = await ConfigStore.ensureStore();
    try {
      await store.put(KEY_TOKEN, '');
      await store.put(KEY_TOKEN_ENC, false);
      await store.put(KEY_PAIRED, false);
      await store.put(KEY_ENDPOINT_ENC, '');
      await store.put(KEY_DEVICE_TOKEN_ENC, '');
      await store.flush();
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'clear 失败: %{public}s', err.message ?? '');
    }
  }
}
