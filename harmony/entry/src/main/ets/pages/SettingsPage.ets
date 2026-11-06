/**
 * 设置页 —— 与桌面端 DSH 的设置面板对齐。
 *
 * 桌面端的设置是分组式的: 连接 / 模型 / 权限 / 显示 / 关于。
 * 手机上按同样的层级排版, 配色走 common/Theme.ets 的深色主题,
 * 组内条目之间用一条细线(BORDER_SOFT)隔开。
 *
 * 数据来源:
 * - 连接信息来自本地配置(AppState.config);
 * - 模型 / 权限来自桌面端 bridge(getModels / getPermissionOptions / getSessionState);
 * - 显示偏好存在本地(common/SettingsStore)。
 */
import { router, promptAction, window } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppState } from '../common/AppState';
import { BridgeListener } from '../common/BridgeClient';
import { SettingsStore, DisplaySettings } from '../common/SettingsStore';
import { LegalStore, ConsentState, PRIVACY_ID, USER_ID, LEGAL_BASE_URL } from '../common/Legal';
import { ModelCatalogResponse, PermissionOption, SessionStateData } from '../common/Models';
import { Palette, Space, Radius, FontSize } from '../common/Theme';
import { ThemeController } from '../common/ThemeController';
import { WindowChrome } from '../common/WindowChrome';
import { maskSecret } from '../common/Seal';
import { describeError } from '../common/ErrorText';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF05;

const APP_NAME: string = 'DSHsync';
const APP_VERSION: string = '2.0.3';
const REPO_URL: string = 'github.com/zhouyan19920115/dsh-harmony';
const DEVELOPER: string = '开发者';
const CONTACT_EMAIL: string = 'you@example.com';

/** 推理强度选项(Off / Low / High ...) */
interface EffortRow {
  id: string;
  name: string;
}

/** 模型目录里的一个模型 */
interface ModelRow {
  /** providerId/modelId */
  key: string;
  providerId: string;
  providerName: string;
  modelId: string;
  modelName: string;
  efforts: EffortRow[];
  defaultEffort: string;
  /** 当前选中的推理强度 */
  selectedEffort: string;
}

/** 列表里的一行: provider 标题行 / 模型行 */
interface SettingsRow {
  /** provider | model */
  kind: string;
  key: string;
  providerId: string;
  providerName: string;
  modelId: string;
  modelName: string;
  efforts: EffortRow[];
  /** 是否是当前选中的模型 */
  selected: boolean;
  /** 当前选中的推理强度 */
  selectedEffort: string;
  /** 是否展开了推理强度 */
  expanded: boolean;
}

/**
 * 权限预设的响应体。
 *
 * 新版 bridge 返回 { options: [...], defaultPreset: "..." },
 * 老版本直接返回一个数组, 所以这里两种形状都认。
 */
interface PermissionOptionsHolder {
  options?: PermissionOption[];
  defaultPreset?: string;
}

@Entry
@Component
struct SettingsPage {
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
    if (key === 'BG') { return Palette.BG; }
    if (key === 'BG_DEEP') { return Palette.BG_DEEP; }
    if (key === 'BORDER') { return Palette.BORDER; }
    if (key === 'BORDER_SOFT') { return Palette.BORDER_SOFT; }
    if (key === 'ERROR') { return Palette.ERROR; }
    if (key === 'OK') { return Palette.OK; }
    if (key === 'SIDEBAR') { return Palette.SIDEBAR; }
    if (key === 'SURFACE') { return Palette.SURFACE; }
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

  /** 桌面端那边还在读 */
  @State loading: boolean = true;
  /** 桌面端没开 / 地址不对 */
  @State error: string = '';
  /** 桌面端地址 */
  @State endpoint: string = '';
  /** 访问令牌(明文, 只在复制的时候用) */
  @State token: string = '';
  /** 默认模型(provider / model) */
  @State defaultModel: string = '';
  /** 模型列表(渲染用) */
  @State modelRows: SettingsRow[] = [];
  /** 权限预设 */
  @State permissionOptions: PermissionOption[] = [];
  /** 当前会话用的权限预设 */
  @State currentPreset: string = '';
  /** 字号: small | standard | large */
  @State fontScale: string = 'standard';
  /** 主题: dark | light | system */
  @State theme: string = 'dark';
  /** 吉祥物背景浓度: off | light | medium | strong */
  @State bgLevel: string = 'medium';
  /** 切换模型用的会话(最近更新的那个) */
  @State sessionId: string = '';
  /** 正在切换的模型 */
  @State busyModel: string = '';
  /** 当前选中的模型 */
  @State currentModelKey: string = '';
  /** 展开了推理强度的模型 */
  @State expandedKey: string = '';
  /** 隐私政策勾没勾 */
  @State privacyAccepted: boolean = false;
  /** 用户协议勾没勾 */
  @State userAccepted: boolean = false;

  /** 模型目录原始数据 */
  private rawModels: ModelRow[] = [];
  /** 连接状态的说法: 「已连接」/「重连中…」/「未连接」 */
  @State connectionText: string = '未连接';
  /** 听连接状态变化用(只关心状态, 不关心别的推送) */
  private listener: BridgeListener = new BridgeListener();

  async aboutToAppear(): Promise<void> {
    this.initStore();
    await this.loadDisplay();
    await this.loadConsent();
    await this.loadBridge();
    // 连接状态要**先读一次**现在的值(这个页面可能是在认证通过之后才打开的,
    // 那一次「已连接」的事件早就发过了)⇒ 只听事件的话这里会一直停在「未连接」✓
    this.connectionText = AppState.connectionLabel();
    this.listener.onConnectionLabel = (label: string, connected: boolean): void => {
      this.connectionText = label;
    };
    AppState.client.addListener(this.listener);
  }

  aboutToDisappear(): void {
    AppState.client.removeListener(this.listener);
  }

  /**
   * 连接状态那一行显示的话。
   *
   * 原来只看「手里有没有令牌」⇒ 令牌在就算「已连接」, 哪怕根本没连上 ⇒ 用户被骗 ✓
   * 现在走三态: 「已连接 · 远程(云中继)」/「已连接 · 局域网」/「重连中…」/「未连接」✓
   */
  private connectionDisplay(): string {
    const label: string = this.connectionText;
    if (label === '未连接') {
      return '未连接';
    }
    if (label === '重连中…') {
      // 「重连中」是**中性**说法: 数据照样能加载 ⇒ 说清楚, 别让用户以为坏了 ✓
      return '重连中… · 数据照常加载';
    }
    return this.isRemote() ? `${label} · 远程(云中继)` : `${label} · 局域网`;
  }

  // ------------------------------------------------------------ 本地设置

  private initStore(): void {
    try {
      const host = this.getUIContext().getHostContext();
      if (host !== undefined) {
        SettingsStore.init(host);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'SettingsStore 初始化失败');
    }
  }

  private async loadDisplay(): Promise<void> {
    try {
      const settings: DisplaySettings = await SettingsStore.load();
      this.fontScale = settings.fontScale;
      this.theme = settings.theme;
      this.bgLevel = settings.bgLevel;
      // 冷启动/进设置页时把主题应用起来(EntryAbility 里也会做一次, 这里兜底)
      ThemeController.start(settings.theme, ThemeController.systemIsLight());
      this.applyThemeChrome();
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '读取显示设置失败: %{public}s', err.message ?? '');
      this.fontScale = 'standard';
      this.theme = 'dark';
    }
  }

  private async saveDisplay(): Promise<void> {
    const settings: DisplaySettings = {
      fontScale: this.fontScale,
      theme: this.theme,
      bgLevel: this.bgLevel
    };
    try {
      await SettingsStore.save(settings);
    } catch (e) {
      const err = e as Error;
      promptAction.showToast({ message: `保存失败: ${describeError(err)}` });
    }
  }

  private async setFontScale(value: string): Promise<void> {
    if (this.fontScale === value) {
      return;
    }
    this.fontScale = value;
    await this.saveDisplay();
  }

  private async setTheme(value: string): Promise<void> {
    if (this.theme === value) {
      return;
    }
    this.theme = value;
    // 立刻生效: 写 Palette + tick+1 ⇒ 所有页面重画; 同时把系统栏颜色换成新主题
    ThemeController.change(value);
    this.applyThemeChrome();
    await this.saveDisplay();
    promptAction.showToast({
      message: value === 'dark' ? '已切到夜间' : (value === 'light' ? '已切到日间' : '跟随系统外观')
    });
  }

  /** 背景浓度: 立刻生效(0/30%/55%/85%) + 存盘 */
  private async setBgLevel(value: string): Promise<void> {
    if (this.bgLevel === value) {
      return;
    }
    this.bgLevel = value;
    ThemeController.setBgLevel(value);
    await this.saveDisplay();
    promptAction.showToast({
      message: value === 'off' ? '已关掉吉祥物背景' : '背景浓度已调整'
    });
  }

  /** 系统栏透明 + 图标颜色跟主题(失败不影响页面) */
  private applyThemeChrome(): void {
    try {
      const host = this.getUIContext().getHostContext();
      if (host === undefined) {
        return;
      }
      window.getLastWindow(host).then((win: window.Window) => {
        WindowChrome.apply(win);
      }).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, '应用窗口外观失败: %{public}s', e.message ?? '');
      });
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '应用窗口外观失败: %{public}s', err.message ?? '');
    }
  }

  // ------------------------------------------------------------ 隐私与协议

  /** 读一下两份协议的勾选状态。 */
  private async loadConsent(): Promise<void> {
    try {
      const state: ConsentState = await LegalStore.load();
      this.privacyAccepted = state.privacy;
      this.userAccepted = state.user;
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, '读取协议勾选状态失败: %{public}s', err.message ?? '');
      this.privacyAccepted = false;
      this.userAccepted = false;
    }
  }

  /** 保存勾选状态(两份都勾了才算同意 ✓)。 */
  private async saveConsent(): Promise<void> {
    const state: ConsentState = {
      privacy: this.privacyAccepted,
      user: this.userAccepted
    };
    try {
      await LegalStore.save(state);
      // 内存缓存也同步一份 ⇒ 自动探测那边立刻就能问出来 ✓
      LegalStore.setCache(state);
      if (LegalStore.accepted(state)) {
        promptAction.showToast({ message: '已同意, 现在可以用「自动探测」了' });
      }
    } catch (e) {
      const err = e as Error;
      promptAction.showToast({ message: `保存失败: ${describeError(err)}` });
    }
  }

  /** 隐私政策的勾选框 */
  private async setPrivacyAccepted(value: boolean): Promise<void> {
    if (this.privacyAccepted === value) {
      return;
    }
    this.privacyAccepted = value;
    await this.saveConsent();
  }

  /** 用户协议的勾选框 */
  private async setUserAccepted(value: boolean): Promise<void> {
    if (this.userAccepted === value) {
      return;
    }
    this.userAccepted = value;
    await this.saveConsent();
  }

  /** 打开协议全文 */
  private openLegal(id: string): void {
    router.pushUrl({ url: 'pages/LegalPage', params: { id: id } }).catch(() => {
      hilog.error(DOMAIN, TAG, 'pushUrl LegalPage 失败');
    });
  }

  /** 把在线版地址复制到剪贴板 ✓ */
  private copyLegalUrl(): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, LEGAL_BASE_URL);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: '在线版地址已复制' });
      }).catch(() => {
        promptAction.showToast({ message: '复制失败' });
      });
    } catch (e) {
      promptAction.showToast({ message: '复制失败' });
    }
  }

  // ------------------------------------------------------------ 桌面端数据

  private async loadBridge(): Promise<void> {
    this.loading = true;
    this.error = '';
    try {
      await AppState.restore();
    } catch (e) {
      hilog.error(DOMAIN, TAG, '恢复连接配置失败');
    }
    this.endpoint = AppState.config.endpoint;
    this.token = AppState.config.token;

    try {
      const sessionId: string = await this.resolveSessionId();
      this.sessionId = sessionId;

      const catalog: ModelCatalogResponse = await AppState.client.getModels();
      this.defaultModel = this.readDefaultModel(catalog);
      this.applyCatalog(catalog);

      const options: PermissionOption[] = await AppState.client.getPermissionOptions();
      this.permissionOptions = this.normalizePermissions(options);

      if (sessionId.length > 0) {
        const state: SessionStateData = await AppState.client.getSessionState(sessionId);
        this.applySessionState(state);
      }
      this.rebuildRows();
      this.loading = false;
    } catch (e) {
      const err = e as Error;
      this.loading = false;
      this.error = `读取桌面端设置失败: ${describeError(err)}`;
    }
  }

  /** 最近更新的那个会话 —— 用来改模型 / 看权限 */
  private async resolveSessionId(): Promise<string> {
    const list = await AppState.client.listSessions();
    let id: string = '';
    let latest: number = 0;
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (item.updatedAt > latest) {
        latest = item.updatedAt;
        id = item.id;
      }
    }
    return id;
  }

  /**
   * 权限预设的两种响应形状都认。
   *
   * bridge 的 getPermissionOptions() 声明返回 PermissionOption[],
   * 但实际 body 是 { options: [...], defaultPreset } —— 这里再解一次,
   * 免得拿到对象却当数组用。
   */
  private normalizePermissions(raw: PermissionOption[]): PermissionOption[] {
    try {
      const text: string = JSON.stringify(raw);
      const holder = JSON.parse(text) as PermissionOptionsHolder;
      const list = holder.options;
      if (list !== undefined && list !== null) {
        return list;
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, '解析权限预设失败');
    }
    return raw;
  }

  private readDefaultModel(catalog: ModelCatalogResponse): string {
    try {
      const def = catalog.default;
      if (def === null) {
        return '未设置';
      }
      return `${def.provider} / ${def.model}`;
    } catch (e) {
      return '未设置';
    }
  }

  private applyCatalog(catalog: ModelCatalogResponse): void {
    const raws: ModelRow[] = [];
    try {
      const providers = catalog.providers;
      for (let i = 0; i < providers.length; i++) {
        const provider = providers[i];
        const models = provider.models;
        for (let j = 0; j < models.length; j++) {
          const model = models[j];
          const efforts: EffortRow[] = [];
          const list = model.efforts;
          if (list !== undefined && list !== null) {
            for (let k = 0; k < list.length; k++) {
              efforts.push({ id: list[k].id, name: list[k].name });
            }
          }
          // defaultEffort 可能是 null(某些 provider 没有默认值), 这时退回第一个
          let effort: string = '';
          const rawEffort = model.defaultEffort;
          if (rawEffort !== undefined && rawEffort !== null) {
            effort = rawEffort;
          }
          if (effort.length === 0 && efforts.length > 0) {
            effort = efforts[0].id;
          }
          raws.push({
            key: `${provider.id}/${model.id}`,
            providerId: provider.id,
            providerName: provider.name,
            modelId: model.id,
            modelName: model.name,
            efforts: efforts,
            defaultEffort: effort,
            selectedEffort: effort
          });
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, '解析模型目录失败');
    }
    this.rawModels = raws;
    this.rebuildRows();
  }

  private applySessionState(state: SessionStateData): void {
    try {
      const model = state.model;
      if (model !== null && model !== undefined) {
        this.currentModelKey = `${model.provider}/${model.model}`;
        // reasoningEffort 有时候不返回
        const effort = model.reasoningEffort;
        if (effort !== undefined && effort !== null && effort.length > 0) {
          for (let i = 0; i < this.rawModels.length; i++) {
            if (this.rawModels[i].key === this.currentModelKey) {
              this.rawModels[i].selectedEffort = effort;
            }
          }
        }
      }
      const permissions = state.permissions;
      if (permissions !== null && permissions !== undefined) {
        this.currentPreset = permissions.preset;
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, '解析会话状态失败');
    }
  }

  /** 把原始目录摊平成渲染用的行 */
  private rebuildRows(): void {
    const rows: SettingsRow[] = [];
    let lastProvider: string = '';
    for (let i = 0; i < this.rawModels.length; i++) {
      const model = this.rawModels[i];
      if (model.providerId !== lastProvider) {
        lastProvider = model.providerId;
        rows.push({
          kind: 'provider',
          key: `provider:${model.providerId}`,
          providerId: model.providerId,
          providerName: model.providerName,
          modelId: '',
          modelName: '',
          efforts: [],
          selected: false,
          selectedEffort: '',
          expanded: false
        });
      }
      rows.push({
        kind: 'model',
        key: model.key,
        providerId: model.providerId,
        providerName: model.providerName,
        modelId: model.modelId,
        modelName: model.modelName,
        efforts: model.efforts,
        selected: model.key === this.currentModelKey,
        selectedEffort: model.selectedEffort,
        expanded: model.key === this.expandedKey
      });
    }
    this.modelRows = rows;
  }

  // ------------------------------------------------------------ 动作

  private async chooseModel(row: SettingsRow): Promise<void> {
    if (this.sessionId.length === 0) {
      promptAction.showToast({ message: '还没有会话, 无法切换模型' });
      return;
    }
    this.currentModelKey = row.key;
    this.expandedKey = row.key;
    this.busyModel = row.key;
    this.rebuildRows();
    try {
      await AppState.client.selectModel(this.sessionId, row.providerId, row.modelId, row.selectedEffort);
    } catch (e) {
      const err = e as Error;
      promptAction.showToast({ message: `切换模型失败: ${describeError(err)}` });
    } finally {
      this.busyModel = '';
    }
  }

  private async chooseEffort(row: SettingsRow, effort: EffortRow): Promise<void> {
    if (this.sessionId.length === 0) {
      return;
    }
    for (let i = 0; i < this.rawModels.length; i++) {
      if (this.rawModels[i].key === row.key) {
        this.rawModels[i].selectedEffort = effort.id;
      }
    }
    this.currentModelKey = row.key;
    this.busyModel = row.key;
    this.rebuildRows();
    try {
      await AppState.client.selectModel(this.sessionId, row.providerId, row.modelId, effort.id);
    } catch (e) {
      const err = e as Error;
      promptAction.showToast({ message: `切换推理强度失败: ${describeError(err)}` });
    } finally {
      this.busyModel = '';
    }
  }

  /**
   * 现在是不是走远程(中继地址带路径 ✓)。
   *
   * 局域网地址形如 `192.168.1.10:8787`(没有路径);
   * 中继地址形如 `https://中继/acc-xxxx/dev-xxxx`(带路径) ✓
   */
  private isRemote(): boolean {
    const scheme: number = this.endpoint.indexOf('://');
    if (scheme < 0) {
      return false;
    }
    return this.endpoint.indexOf('/', scheme + 3) > 0;
  }

  // ------------------------------------------------------------ 小工具

  /**
   * 令牌只露头尾。
   *
   * 打码规则全仓只有一份(common/Seal.ets 的 maskSecret) —— 连接页、设置页、
   * 宽屏变体都用它, 免得各写各的、漏了哪一处 ✓
   */
  private maskedToken(): string {
    const token: string = this.token;
    if (token.length === 0) {
      return '未设置';
    }
    return maskSecret(token);
  }

  /** 当前权限预设的名字 */
  private presetName(): string {
    if (this.currentPreset.length === 0) {
      return '未设置';
    }
    for (let i = 0; i < this.permissionOptions.length; i++) {
      if (this.permissionOptions[i].value === this.currentPreset) {
        return this.permissionOptions[i].name;
      }
    }
    return this.currentPreset;
  }

  /**
   * 展开的模型才给推理强度。
   *
   * 用空数组而不是 if 分支, 这样 ForEach 的数据源一变, 子节点就会重建。
   */
  private effortsOf(row: SettingsRow): EffortRow[] {
    if (row.expanded) {
      return row.efforts;
    }
    return [];
  }

  /**
   * ForEach 的 key。
   *
   * ArkUI 的 ForEach 会按 key 复用子组件, 复用时不会重新走 if 分支,
   * 所以把"选中/展开"这些会改变结构的状态也塞进 key 里,
   * 状态一变 key 就变, 子组件会被重建, 展开的推理强度才画得出来。
   */
  private rowKey(row: SettingsRow): string {
    let key: string = row.key;
    if (row.selected) {
      key += '|selected';
    }
    if (row.expanded) {
      key += '|open';
    }
    if (this.busyModel === row.key) {
      key += '|busy';
    }
    key += `|${row.selectedEffort}`;
    return key;
  }

  /** 字号倍率 */
  private fontScaleFactor(): number {
    if (this.fontScale === 'small') {
      return 0.9;
    }
    if (this.fontScale === 'large') {
      return 1.15;
    }
    return 1;
  }

  /** 按当前字号设置缩放 */
  private fs(base: number): number {
    return Math.round(base * this.fontScaleFactor() * 10) / 10;
  }

  // ------------------------------------------------------------ 布局

  @Builder
  sectionTitle(title: string, hint: string) {
    Row({ space: Space.SM }) {
      Text(title)
        .fontSize(FontSize.TINY)
        .fontColor(this.pal('TEXT_3'))
        .layoutWeight(1)
      if (hint.length > 0) {
        Text(hint)
          .fontSize(FontSize.TINY)
          .fontColor(this.pal('TEXT_3'))
      }
    }
    .width('100%')
    .padding({ left: Space.LG, right: Space.LG, top: Space.XL, bottom: Space.SM })
  }

  @Builder
  hairline() {
    Rect({ width: '100%', height: 1 })
      .fill(this.pal('BORDER_SOFT'))
  }

  build() {
    Scroll() {
      Column({ space: 0 }) {
        // ---------- 顶部栏 ----------
        Row({ space: Space.MD }) {
          Text('‹ 返回')
            .fontSize(FontSize.BODY)
            .fontColor(this.pal('ACCENT'))
            .onClick(() => { router.back(); })
          Text('设置')
            .fontSize(FontSize.HEAD)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pal('TEXT'))
            .layoutWeight(1)
          Text('刷新')
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('TEXT_3'))
            .padding({ left: 6, right: 6, top: 5, bottom: 5 })
            .onClick(() => { this.loadBridge(); })
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })
        .backgroundColor(this.pal('SIDEBAR'))

        this.hairline()

        if (this.error.length > 0) {
          Text(this.error)
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('ERROR'))
            .width('100%')
            .padding({ left: Space.LG, right: Space.LG, top: Space.SM, bottom: Space.SM })
            .backgroundColor(this.pal('SURFACE'))
        }

        // ---------- 连接 ----------
        this.sectionTitle('连接', '')

        Row({ space: Space.MD }) {
          Text('连接状态')
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT_2'))
            .width(84)
          Text(this.connectionDisplay())
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.connectionText === '已连接'
              ? this.pal('OK')
              : (this.connectionText === '重连中…' ? this.pal('WARN') : this.pal('TEXT_3')))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('连接设置')
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('ACCENT'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .border({ width: 1, color: this.pal('BORDER') })
            .borderRadius(Radius.SM)
            .onClick(() => {
              router.pushUrl({ url: 'pages/ConnectPage' }).catch(() => {
                hilog.error(DOMAIN, TAG, 'pushUrl ConnectPage 失败');
              });
            })
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

        this.hairline()

        Text('地址和令牌都不用手输: 配对一次就记住了, 界面上也不显示。')
          .fontSize(FontSize.TINY)
          .fontColor(this.pal('TEXT_3'))
          .width('100%')
          .padding({ left: Space.LG, right: Space.LG, bottom: Space.MD })

        this.hairline()

        Row() {
          Button('重新配对')
            .type(ButtonType.Normal)
            .height(38)
            .borderRadius(Radius.SM)
            .backgroundColor(this.pal('SURFACE'))
            .fontColor(this.pal('TEXT'))
            .fontSize(this.fs(FontSize.BODY))
            .border({ width: 1, color: this.pal('BORDER') })
            .onClick(() => {
              router.pushUrl({ url: 'pages/ConnectPage' }).catch(() => {
                hilog.error(DOMAIN, TAG, 'pushUrl ConnectPage 失败');
              });
            })
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, bottom: Space.MD })

        // ---------- 模型 / 权限(桌面端那边) ----------
        if (this.loading) {
          Column({ space: Space.MD }) {
            LoadingProgress()
              .width(28)
              .height(28)
              .color(this.pal('ACCENT'))
            Text('正在读取桌面端设置…')
              .fontSize(FontSize.SMALL)
              .fontColor(this.pal('TEXT_3'))
          }
          .width('100%')
          .padding({ top: Space.XL, bottom: Space.XL })
          .justifyContent(FlexAlign.Center)
        } else {
          if (this.modelRows.length > 0) {
            this.sectionTitle('模型', this.sessionId.length > 0 ? '' : '没有会话')

            Row({ space: Space.MD }) {
              Text('默认模型')
                .fontSize(this.fs(FontSize.BODY))
                .fontColor(this.pal('TEXT_2'))
                .width(84)
              Text(this.defaultModel)
                .fontSize(this.fs(FontSize.BODY))
                .fontColor(this.pal('TEXT'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

            this.hairline()

            ForEach(this.modelRows, (row: SettingsRow) => {
              Column({ space: 0 }) {
                if (row.kind === 'provider') {
                  Text(row.providerName)
                    .fontSize(FontSize.SMALL)
                    .fontColor(this.pal('TEXT_3'))
                    .width('100%')
                    .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.SM })
                } else {
                  Row({ space: Space.SM }) {
                    Text(row.modelName)
                      .fontSize(this.fs(FontSize.BODY))
                      .fontColor(row.selected ? this.pal('TEXT') : this.pal('TEXT_2'))
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (this.busyModel === row.key) {
                      LoadingProgress()
                        .width(14)
                        .height(14)
                        .color(this.pal('ACCENT'))
                    }
                    if (row.efforts.length > 0) {
                      Text(row.expanded ? '▾' : '▸')
                        .fontSize(FontSize.SMALL)
                        .fontColor(this.pal('TEXT_3'))
                        .width(12)
                    }
                  }
                  .width('100%')
                  .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })
                  .onClick(() => { this.chooseModel(row); })

                  if (row.expanded && row.efforts.length > 0) {
                    Row({ space: Space.SM }) {
                      ForEach(this.effortsOf(row), (effort: EffortRow) => {
                        Text(effort.name)
                          .fontSize(FontSize.SMALL)
                          .fontColor(row.selectedEffort === effort.id ? this.pal('BG_DEEP') : this.pal('TEXT_2'))
                          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                          .backgroundColor(row.selectedEffort === effort.id ? this.pal('ACCENT') : Color.Transparent)
                          .border({ width: 1, color: this.pal('BORDER') })
                          .borderRadius(Radius.PILL)
                          .onClick(() => { this.chooseEffort(row, effort); })
                      }, (effort: EffortRow): string => effort.id)
                    }
                    .width('100%')
                    .padding({ left: Space.LG, right: Space.LG, bottom: Space.MD })
                  }
                }
              }
              .width('100%')
            }, (row: SettingsRow): string => this.rowKey(row))
          }

          if (this.permissionOptions.length > 0) {
            this.sectionTitle('权限', '在桌面端修改')

            Row({ space: Space.MD }) {
              Text('当前预设')
                .fontSize(this.fs(FontSize.BODY))
                .fontColor(this.pal('TEXT_2'))
                .width(84)
              Text(this.presetName())
                .fontSize(this.fs(FontSize.BODY))
                .fontColor(this.pal('TEXT'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

            this.hairline()

            ForEach(this.permissionOptions, (option: PermissionOption) => {
              Row({ space: Space.MD }) {
                Column({ space: 2 }) {
                  Text(option.name)
                    .fontSize(this.fs(FontSize.BODY))
                    .fontColor(option.value === this.currentPreset ? this.pal('TEXT') : this.pal('TEXT_2'))
                  Text(option.description)
                    .fontSize(FontSize.TINY)
                    .fontColor(this.pal('TEXT_3'))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                if (option.value === this.currentPreset) {
                  Text('当前')
                    .fontSize(FontSize.TINY)
                    .fontColor(this.pal('ACCENT'))
                }
              }
              .width('100%')
              .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })
            }, (option: PermissionOption): string =>
              `${option.value}|${option.value === this.currentPreset ? 'on' : 'off'}`)
          }
        }

        // ---------- 显示 ----------
        this.sectionTitle('显示', '')

        Row({ space: Space.MD }) {
          Text('字号')
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT_2'))
            .width(84)
          Row({ space: Space.SM }) {
            Text('小')
              .fontSize(FontSize.SMALL)
              .fontColor(this.fontScale === 'small' ? this.pal('BG_DEEP') : this.pal('TEXT_2'))
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .backgroundColor(this.fontScale === 'small' ? this.pal('ACCENT') : Color.Transparent)
              .border({ width: 1, color: this.fontScale === 'small' ? this.pal('ACCENT') : this.pal('BORDER') })
              .borderRadius(Radius.PILL)
              .onClick(() => { this.setFontScale('small'); })
            Text('标准')
              .fontSize(FontSize.SMALL)
              .fontColor(this.fontScale === 'standard' ? this.pal('BG_DEEP') : this.pal('TEXT_2'))
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .backgroundColor(this.fontScale === 'standard' ? this.pal('ACCENT') : Color.Transparent)
              .border({ width: 1, color: this.fontScale === 'standard' ? this.pal('ACCENT') : this.pal('BORDER') })
              .borderRadius(Radius.PILL)
              .onClick(() => { this.setFontScale('standard'); })
            Text('大')
              .fontSize(FontSize.SMALL)
              .fontColor(this.fontScale === 'large' ? this.pal('BG_DEEP') : this.pal('TEXT_2'))
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .backgroundColor(this.fontScale === 'large' ? this.pal('ACCENT') : Color.Transparent)
              .border({ width: 1, color: this.fontScale === 'large' ? this.pal('ACCENT') : this.pal('BORDER') })
              .borderRadius(Radius.PILL)
              .onClick(() => { this.setFontScale('large'); })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

        this.hairline()

        Row({ space: Space.MD }) {
          Text('主题')
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT_2'))
            .width(84)
          Row({ space: Space.SM }) {
            Text('夜间')
              .fontSize(FontSize.SMALL)
              .fontColor(this.theme === 'dark' ? this.pal('BG_DEEP') : this.pal('TEXT_2'))
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .backgroundColor(this.theme === 'dark' ? this.pal('ACCENT') : Color.Transparent)
              .border({ width: 1, color: this.theme === 'dark' ? this.pal('ACCENT') : this.pal('BORDER') })
              .borderRadius(Radius.PILL)
              .onClick(() => { this.setTheme('dark'); })
            Text('日间')
              .fontSize(FontSize.SMALL)
              .fontColor(this.theme === 'light' ? this.pal('BG_DEEP') : this.pal('TEXT_2'))
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .backgroundColor(this.theme === 'light' ? this.pal('ACCENT') : Color.Transparent)
              .border({ width: 1, color: this.theme === 'light' ? this.pal('ACCENT') : this.pal('BORDER') })
              .borderRadius(Radius.PILL)
              .onClick(() => { this.setTheme('light'); })
            Text('跟随系统')
              .fontSize(FontSize.SMALL)
              .fontColor(this.theme === 'system' ? this.pal('BG_DEEP') : this.pal('TEXT_2'))
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .backgroundColor(this.theme === 'system' ? this.pal('ACCENT') : Color.Transparent)
              .border({ width: 1, color: this.theme === 'system' ? this.pal('ACCENT') : this.pal('BORDER') })
              .borderRadius(Radius.PILL)
              .onClick(() => { this.setTheme('system'); })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

        Row({ space: Space.MD }) {
          Text('背景')
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT_2'))
            .width(84)
          Row({ space: Space.SM }) {
            Text('关')
              .fontSize(FontSize.SMALL)
              .fontColor(this.bgLevel === 'off' ? this.pal('BG_DEEP') : this.pal('TEXT_2'))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.bgLevel === 'off' ? this.pal('ACCENT') : Color.Transparent)
              .border({ width: 1, color: this.bgLevel === 'off' ? this.pal('ACCENT') : this.pal('BORDER') })
              .borderRadius(Radius.PILL)
              .onClick(() => { this.setBgLevel('off'); })
            Text('淡')
              .fontSize(FontSize.SMALL)
              .fontColor(this.bgLevel === 'light' ? this.pal('BG_DEEP') : this.pal('TEXT_2'))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.bgLevel === 'light' ? this.pal('ACCENT') : Color.Transparent)
              .border({ width: 1, color: this.bgLevel === 'light' ? this.pal('ACCENT') : this.pal('BORDER') })
              .borderRadius(Radius.PILL)
              .onClick(() => { this.setBgLevel('light'); })
            Text('中')
              .fontSize(FontSize.SMALL)
              .fontColor(this.bgLevel === 'medium' ? this.pal('BG_DEEP') : this.pal('TEXT_2'))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.bgLevel === 'medium' ? this.pal('ACCENT') : Color.Transparent)
              .border({ width: 1, color: this.bgLevel === 'medium' ? this.pal('ACCENT') : this.pal('BORDER') })
              .borderRadius(Radius.PILL)
              .onClick(() => { this.setBgLevel('medium'); })
            Text('浓')
              .fontSize(FontSize.SMALL)
              .fontColor(this.bgLevel === 'strong' ? this.pal('BG_DEEP') : this.pal('TEXT_2'))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.bgLevel === 'strong' ? this.pal('ACCENT') : Color.Transparent)
              .border({ width: 1, color: this.bgLevel === 'strong' ? this.pal('ACCENT') : this.pal('BORDER') })
              .borderRadius(Radius.PILL)
              .onClick(() => { this.setBgLevel('strong'); })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

        this.hairline()

        // ---------- 隐私与协议 ----------
        this.sectionTitle('隐私与协议', '自动探测前必须同意')

        Row({ space: Space.MD }) {
          Text(this.userAccepted ? '☑' : '☐')
            .fontSize(this.fs(FontSize.TITLE))
            .fontColor(this.userAccepted ? this.pal('ACCENT') : this.pal('TEXT_3'))
            .width(24)
            .onClick(() => { this.setUserAccepted(!this.userAccepted); })
          Text('我已阅读并同意《用户协议》')
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT'))
            .layoutWeight(1)
            .onClick(() => { this.openLegal(USER_ID); })
          Text('查看全文')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('ACCENT'))
            .onClick(() => { this.openLegal(USER_ID); })
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

        this.hairline()

        Row({ space: Space.MD }) {
          Text(this.privacyAccepted ? '☑' : '☐')
            .fontSize(this.fs(FontSize.TITLE))
            .fontColor(this.privacyAccepted ? this.pal('ACCENT') : this.pal('TEXT_3'))
            .width(24)
            .onClick(() => { this.setPrivacyAccepted(!this.privacyAccepted); })
          Text('我已阅读并同意《隐私政策》')
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT'))
            .layoutWeight(1)
            .onClick(() => { this.openLegal(PRIVACY_ID); })
          Text('查看全文')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('ACCENT'))
            .onClick(() => { this.openLegal(PRIVACY_ID); })
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

        this.hairline()

        Row({ space: Space.MD }) {
          Text('在线版')
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT_2'))
            .width(84)
          Text(LEGAL_BASE_URL)
            .fontSize(this.fs(FontSize.SMALL))
            .fontColor(this.pal('ACCENT'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick(() => { this.copyLegalUrl(); })
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

        this.hairline()

        Text('两份都勾上之后, 「自动探测」(局域网扫描找电脑)才允许执行; 取消勾选即刻停用。')
          .fontSize(FontSize.TINY)
          .fontColor(this.pal('TEXT_3'))
          .width('100%')
          .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

        // ---------- 关于 ----------
        this.sectionTitle('关于', '')

        Row({ space: Space.MD }) {
          Text('应用名称')
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT_2'))
            .width(84)
          Text(APP_NAME)
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

        this.hairline()

        Row({ space: Space.MD }) {
          Text('版本')
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT_2'))
            .width(84)
          Text(`v${APP_VERSION}`)
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

        this.hairline()

        Row({ space: Space.MD }) {
          Text('开源协议')
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT_2'))
            .width(84)
          Text('MIT')
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

        this.hairline()

        Row({ space: Space.MD }) {
          Text('开发者')
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT_2'))
            .width(84)
          Text(DEVELOPER)
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

        this.hairline()

        Row({ space: Space.MD }) {
          Text('联系邮箱')
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT_2'))
            .width(84)
          Text(CONTACT_EMAIL)
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })

        this.hairline()

        Row({ space: Space.MD }) {
          Text('仓库')
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('TEXT_2'))
            .width(84)
          Text(REPO_URL)
            .fontSize(this.fs(FontSize.BODY))
            .fontColor(this.pal('ACCENT'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })
      }
      .width('100%')
      .padding({ bottom: Space.XL })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .backgroundColor(this.pal('BG'))
    .padding({ top: this.topSafeVp, bottom: this.bottomSafeVp })
    .backgroundImage(this.backdropImage())
    .backgroundImageSize(ImageSize.Cover)
    .backgroundImagePosition(Alignment.Center)
  }
}
