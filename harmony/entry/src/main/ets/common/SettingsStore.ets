/**
 * 本地显示设置(字号 / 主题)。
 *
 * 和 common/Config.ets 一样用 @ohos.data.preferences, 但单独一个存储文件:
 * 重新配对(清令牌)不应该把显示偏好一起清掉。
 *
 * 用法:
 *   SettingsStore.init(context);        // 页面用 getUIContext().getHostContext() 传进来
 *   const s = await SettingsStore.load();
 *   await SettingsStore.save({ fontScale: 'large', theme: 'dark' });
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { explain } from './ErrorText';

const TAG: string = 'DSHsync';
const DOMAIN: number = 0xFF04;

const STORE_NAME: string = 'dsh_harmony_settings';
const KEY_FONT_SCALE: string = 'fontScale';
const KEY_THEME: string = 'theme';
const KEY_BG_LEVEL: string = 'bgLevel';

/** 显示设置 */
export interface DisplaySettings {
  /** 字号: small | standard | large */
  fontScale: string;
  /** 主题: dark | light | system */
  theme: string;
  /** 吉祥物背景浓度: off | light | medium | strong */
  bgLevel: string;
}

export class SettingsStore {
  private static store: preferences.Preferences | null = null;
  private static context: common.Context | null = null;

  /**
   * 初始化。
   *
   * EntryAbility 只初始化了 ConfigStore, 所以这里由页面自己把上下文传进来。
   */
  static init(context: common.Context): void {
    SettingsStore.context = context;
  }

  private static async ensureStore(): Promise<preferences.Preferences> {
    if (SettingsStore.store !== null) {
      return SettingsStore.store;
    }
    const context = SettingsStore.context;
    if (context === null) {
      throw new Error('本地设置还没初始化, 重启一下 App 就好');
    }
    try {
      const store = await preferences.getPreferences(context, { name: STORE_NAME });
      SettingsStore.store = store;
      return store;
    } catch (e) {
      const err = e as BusinessError;
      // 系统的原文是英文 ⇒ 补一句中文说明, 用户才知道是怎么回事 ✓
      throw new Error(`打开本地设置失败: ${explain(err.message ?? '')}`);
    }
  }

  /** 读取显示设置; 没存过就用默认值。 */
  static async load(): Promise<DisplaySettings> {
    try {
      const store = await SettingsStore.ensureStore();
      const fontScale = await store.get(KEY_FONT_SCALE, 'standard') as string;
      const theme = await store.get(KEY_THEME, 'dark') as string;
      const bgLevel = await store.get(KEY_BG_LEVEL, 'medium') as string;
      return {
        fontScale: fontScale,
        theme: theme,
        bgLevel: bgLevel
      };
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'SettingsStore.load failed: %{public}s', err.message ?? 'unknown');
      return {
        fontScale: 'standard',
        theme: 'dark',
        bgLevel: 'medium'
      };
    }
  }

  /** 保存显示设置。 */
  static async save(settings: DisplaySettings): Promise<void> {
    try {
      const store = await SettingsStore.ensureStore();
      await store.put(KEY_FONT_SCALE, settings.fontScale);
      await store.put(KEY_THEME, settings.theme);
      await store.put(KEY_BG_LEVEL, settings.bgLevel);
      await store.flush();
      hilog.info(DOMAIN, TAG, 'SettingsStore.save: fontScale=%{public}s theme=%{public}s',
        settings.fontScale, settings.theme);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'SettingsStore.save failed: %{public}s', err.message ?? 'unknown');
      throw new Error(err.message ?? '保存设置失败');
    }
  }
}
