/**
 * 主题控制器: 把「用户偏好(跟随系统 / 日间 / 夜间)」翻译成 Palette 的当前模式,
 * 并且通知所有页面重画。
 *
 * 通知方式: AppStorage 的 `themeTick` +1。每个页面 build() 里用
 * `ForEach([this.themeTick], ...)` 包了一层(见 pages/*.ets), key 里带 tick,
 * 所以 tick 一变整页重建 ⇒ Palette 的所有 getter 重新取值 ⇒ 颜色真的换掉。
 *
 * 存的值(SettingsStore 里的 theme): 'system' | 'light' | 'dark'。
 */
import { Palette, ThemeMode } from './Theme';

/** 偏好在 AppStorage 里的 key */
export const THEME_PREF_KEY: string = 'themePref';
/** 系统当前是不是浅色(EntryAbility 在启动和配置变化时写) */
export const SYSTEM_LIGHT_KEY: string = 'systemLight';
/** 每次主题生效 +1, 页面靠它整页重建 */
export const THEME_TICK_KEY: string = 'themeTick';
/** 吉祥物背景浓度: off | light | medium | strong */
export const BG_LEVEL_KEY: string = 'bgLevel';

export class ThemeController {
  /** 当前偏好: system | light | dark */
  static pref(): string {
    const value: string | undefined = AppStorage.get<string>(THEME_PREF_KEY);
    if (value === undefined || value.length === 0) {
      return 'dark';
    }
    return value;
  }

  /** 系统当前是不是浅色 */
  static systemIsLight(): boolean {
    const value: boolean | undefined = AppStorage.get<boolean>(SYSTEM_LIGHT_KEY);
    return value === true;
  }

  /** 偏好 + 系统色 → 实际模式 */
  static modeOf(pref: string, systemLight: boolean): ThemeMode {
    if (pref === 'light') {
      return ThemeMode.LIGHT;
    }
    if (pref === 'dark') {
      return ThemeMode.DARK;
    }
    return systemLight ? ThemeMode.LIGHT : ThemeMode.DARK;
  }

  /** 启动时: 写入偏好和系统色, 然后生效一次 */
  static start(pref: string, systemLight: boolean): void {
    AppStorage.setOrCreate<string>(THEME_PREF_KEY, pref);
    AppStorage.setOrCreate<boolean>(SYSTEM_LIGHT_KEY, systemLight);
    ThemeController.applyNow();
  }

  /** 系统色变化时更新(跟随系统模式下会立刻生效) */
  static updateSystemLight(systemLight: boolean): boolean {
    AppStorage.setOrCreate<boolean>(SYSTEM_LIGHT_KEY, systemLight);
    if (ThemeController.pref() === 'system') {
      ThemeController.applyNow();
      return true;
    }
    return false;
  }

  /** 用户切主题: 存偏好 + 立刻生效(持久化由调用方异步做) */
  static change(pref: string): void {
    AppStorage.setOrCreate<string>(THEME_PREF_KEY, pref);
    ThemeController.applyNow();
  }

  /** 背景浓度(off | light | medium | strong) */
  static bgLevel(): string {
    const value: string | undefined = AppStorage.get<string>(BG_LEVEL_KEY);
    return value === undefined ? 'medium' : value;
  }

  /** 背景图不透明度(0 = 完全关掉) */
  static bgAlpha(): number {
    const level: string = ThemeController.bgLevel();
    if (level === 'off') {
      return 0;
    }
    if (level === 'light') {
      return 0.30;
    }
    if (level === 'strong') {
      return 0.85;
    }
    return 0.55;
  }

  /** 设置背景浓度(立刻生效, 持久化由调用方做) */
  static setBgLevel(level: string): void {
    AppStorage.setOrCreate<string>(BG_LEVEL_KEY, level);
    const tick: number | undefined = AppStorage.get<number>(THEME_TICK_KEY);
    AppStorage.setOrCreate<number>(THEME_TICK_KEY, (tick === undefined ? 0 : tick) + 1);
  }

  /** 生效: 算模式 → 写 Palette → tick+1 */
  static applyNow(): void {
    const mode: ThemeMode = ThemeController.modeOf(ThemeController.pref(), ThemeController.systemIsLight());
    Palette.applyMode(mode);
    const tick: number | undefined = AppStorage.get<number>(THEME_TICK_KEY);
    AppStorage.setOrCreate<number>(THEME_TICK_KEY, (tick === undefined ? 0 : tick) + 1);
  }
}
