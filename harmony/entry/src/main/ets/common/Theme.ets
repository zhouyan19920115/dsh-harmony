/**
 * 主题 —— 两套配色: 夜间(默认, 对齐桌面端深色) / 日间(浅色)。
 *
 * 夜间颜色是从桌面端界面截图上采样出来的:
 *   侧边栏 #1B1B1C / 主内容区 #151517 / 输入框与用户气泡 #2C2C2E
 *   强调蓝 #7AAFFF(选中态) 与 #3B82F6(发送按钮)
 *
 * 现在所有颜色都走 Palette 的 static getter: 切主题时调
 * ThemeController.change(模式), 它会把 AppStorage 里的 `themeTick` +1,
 * 页面用 `@StorageLink('themeTick')` 接一下就会整体重画。
 *
 * 注意: **不要在页面里缓存 Palette.X 的值**, 每次 build 重新读 getter。
 */

/** 主题模式 */
export enum ThemeMode {
  /** 跟随系统 */
  SYSTEM = 0,
  /** 日间(浅色) */
  LIGHT = 1,
  /** 夜间(深色) */
  DARK = 2
}

/** 一套配色 */
interface PaletteSet {
  bg: string;
  bgDeep: string;
  sidebar: string;
  surface: string;
  surfaceHi: string;
  card: string;
  border: string;
  borderSoft: string;
  text: string;
  text2: string;
  text3: string;
  placeholder: string;
  accent: string;
  accentSolid: string;
  accentSoft: string;
  ok: string;
  okSoft: string;
  warn: string;
  warnSoft: string;
  error: string;
  errorSoft: string;
  tool: string;
  assistant: string;
  context: string;
}

/** 夜间(和桌面端一致, 别改这几组值) */
class DarkSet implements PaletteSet {
  bg: string = '#151517';
  bgDeep: string = '#111113';
  sidebar: string = '#1B1B1C';
  surface: string = '#2C2C2E';
  surfaceHi: string = '#34363A';
  card: string = '#D9202025';
  border: string = '#43454A';
  borderSoft: string = '#2E3034';
  text: string = '#E9EAEB';
  text2: string = '#A2A3A5';
  text3: string = '#8C8F93';
  placeholder: string = '#82858B';
  accent: string = '#7AAFFF';
  accentSolid: string = '#3B82F6';
  accentSoft: string = '#287AAFFF';
  ok: string = '#4ADE80';
  okSoft: string = '#284ADE80';
  warn: string = '#D49245';
  warnSoft: string = '#28D49245';
  error: string = '#F87171';
  errorSoft: string = '#28F87171';
  tool: string = '#DD8629';
  assistant: string = '#9474BC';
  context: string = '#59C984';
}

/** 日间: 同一套层级, 换成浅色; 对比度按 WCAG AA 挑的 */
class LightSet implements PaletteSet {
  bg: string = '#F7F8FA';
  bgDeep: string = '#EEF1F6';
  sidebar: string = '#FFFFFF';
  surface: string = '#FFFFFF';
  surfaceHi: string = '#EDF0F6';
  card: string = '#E0FFFFFF';
  border: string = '#D2D8E3';
  borderSoft: string = '#E1E6EF';
  text: string = '#1B1D22';
  text2: string = '#49505F';
  text3: string = '#767E8E';
  placeholder: string = '#98A0B0';
  accent: string = '#2F6FED';
  accentSolid: string = '#2F6FED';
  accentSoft: string = '#1A2F6FED';
  ok: string = '#17934A';
  okSoft: string = '#1A17934A';
  warn: string = '#B7791F';
  warnSoft: string = '#1AB7791F';
  error: string = '#D32F2F';
  errorSoft: string = '#1AD32F2F';
  tool: string = '#B4651A';
  assistant: string = '#7551B8';
  context: string = '#1B8F63';
}

/** 颜色: 全部是 getter, 切主题后重新 build 自动生效 */
export class Palette {
  private static mode: ThemeMode = ThemeMode.DARK;
  private static readonly dark: PaletteSet = new DarkSet();
  private static readonly light: PaletteSet = new LightSet();

  /** 直接指定模式(由 ThemeController 调, 页面别自己调) */
  static applyMode(mode: ThemeMode): void {
    Palette.mode = mode;
  }

  static currentMode(): ThemeMode {
    return Palette.mode;
  }

  /** 当前是不是深色 */
  static isDark(): boolean {
    return Palette.mode !== ThemeMode.LIGHT;
  }

  private static set(): PaletteSet {
    return Palette.isDark() ? Palette.dark : Palette.light;
  }

  /** 页面底色(主内容区) */
  static get BG(): string {
    return Palette.set().bg;
  }

  /** 最外层底色 */
  static get BG_DEEP(): string {
    return Palette.set().bgDeep;
  }

  /** 侧边栏 / 导航 */
  static get SIDEBAR(): string {
    return Palette.set().sidebar;
  }

  /** 浮起面板: 输入框、用户气泡、卡片 */
  static get SURFACE(): string {
    return Palette.set().surface;
  }

  /** 更亮一层的浮起面板 */
  static get SURFACE_HI(): string {
    return Palette.set().surfaceHi;
  }

  /** 分组卡片底色 */
  static get CARD(): string {
    return Palette.set().card;
  }

  /** 分隔线 */
  static get BORDER(): string {
    return Palette.set().border;
  }

  /** 弱分隔线 */
  static get BORDER_SOFT(): string {
    return Palette.set().borderSoft;
  }

  /** 主文字 */
  static get TEXT(): string {
    return Palette.set().text;
  }

  /** 次要文字 */
  static get TEXT_2(): string {
    return Palette.set().text2;
  }

  /** 弱化文字 */
  static get TEXT_3(): string {
    return Palette.set().text3;
  }

  /** 占位符 */
  static get PLACEHOLDER(): string {
    return Palette.set().placeholder;
  }

  /** 强调色: 选中态 */
  static get ACCENT(): string {
    return Palette.set().accent;
  }

  /** 实心强调色: 发送按钮 */
  static get ACCENT_SOLID(): string {
    return Palette.set().accentSolid;
  }

  /** 强调色的柔光底 */
  static get ACCENT_SOFT(): string {
    return Palette.set().accentSoft;
  }

  /** 成功 / 运行中 */
  static get OK(): string {
    return Palette.set().ok;
  }

  static get OK_SOFT(): string {
    return Palette.set().okSoft;
  }

  /** 警告 */
  static get WARN(): string {
    return Palette.set().warn;
  }

  static get WARN_SOFT(): string {
    return Palette.set().warnSoft;
  }

  /** 错误 */
  static get ERROR(): string {
    return Palette.set().error;
  }

  static get ERROR_SOFT(): string {
    return Palette.set().errorSoft;
  }

  /** 工具 */
  static get TOOL(): string {
    return Palette.set().tool;
  }

  /** 助手 */
  static get ASSISTANT(): string {
    return Palette.set().assistant;
  }

  /** 上下文 */
  static get CONTEXT(): string {
    return Palette.set().context;
  }
}

/** 间距( vp ) */
export class Space {
  static readonly XS: number = 4;
  static readonly SM: number = 8;
  static readonly MD: number = 12;
  static readonly LG: number = 16;
  static readonly XL: number = 24;
}

/** 圆角( vp ) */
export class Radius {
  static readonly SM: number = 8;
  static readonly MD: number = 12;
  static readonly LG: number = 18;
  static readonly PILL: number = 999;
}

/** 字号( fp ) */
export class FontSize {
  static readonly TINY: number = 10;
  static readonly SMALL: number = 12;
  static readonly BODY: number = 14;
  static readonly TITLE: number = 16;
  static readonly HEAD: number = 20;
  static readonly BIG: number = 24;
}
