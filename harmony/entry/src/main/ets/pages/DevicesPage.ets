/**
 * 设备页 —— 账号下的多端同步视图。
 *
 * 桌面端和手机都是同一个账号下的"设备":
 *   - 桌面端负责执行, 手机负责观察和下发指令
 *   - 这里能看到谁在线、谁是桌面端、谁是哪台手机
 *
 * 参考 Happy Coder 的"设备"概念, 但这里的账号是自建的(共享密钥 + 设备登记表),
 * 没有邮箱密码, 也没有端到端加密 —— 细节见 docs/ACCOUNT.md。
 */
import { AppState } from '../common/AppState';
import { DeviceInfo } from '../common/Models';
import { formatRelative } from '../common/TimeFmt';
import { Palette, Space, Radius, FontSize } from '../common/Theme';
import { describeError } from '../common/ErrorText';

@Entry
@Component
struct DevicesPage {
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
    if (key === 'BORDER_SOFT') { return Palette.BORDER_SOFT; }
    if (key === 'OK') { return Palette.OK; }
    if (key === 'SURFACE') { return Palette.SURFACE; }
    if (key === 'TEXT') { return Palette.TEXT; }
    if (key === 'TEXT_2') { return Palette.TEXT_2; }
    if (key === 'TEXT_3') { return Palette.TEXT_3; }
    return Palette.TEXT;
  }

  /** 当前主题的吉祥物背景图 */
  private backdropImage(): Resource {
    const tick: number = this.themeTick;
    return tick < 0 ? $r('app.media.mascot_day') : (Palette.isDark() ? $r('app.media.mascot_night') : $r('app.media.mascot_day'));
  }

  @State devices: DeviceInfo[] = [];
  @State endpoint: string = '';
  @State accountId: string = '';
  @State notice: string = '';
  @State loading: boolean = true;

  async aboutToAppear(): Promise<void> {
    this.endpoint = AppState.client.getEndpointLabel();
    this.accountId = AppState.client.getAccountId();
    await this.refresh();
  }

  private async refresh(): Promise<void> {
    this.loading = true;
    try {
      const list: DeviceInfo[] = await AppState.client.listDevices();
      this.devices = list;
      this.loading = false;
      if (list.length === 0) {
        this.notice = '这个地址还没有提供设备列表(直连模式或 bridge 版本较旧)';
      } else {
        this.notice = '';
      }
    } catch (e) {
      // 设备列表拿不到: 以前这里直接把异常甩出去(界面上什么都不显示, 一直转圈)✗
      // ⇒ 现在说清楚是什么事、要不要紧、该怎么办 ✓
      this.loading = false;
      this.devices = [];
      const err = e as Error;
      this.notice = `读不到设备列表: ${describeError(err)}`;
    }
  }

  private roleLabel(role: string): string {
    return role === 'phone' ? '手机' : '桌面端';
  }

  private roleIcon(role: string): string {
    return role === 'phone' ? '▯' : '▤';
  }

  build() {
    Column() {
      // ---------- 顶部栏 ----------
      Row({ space: Space.SM }) {
        Text('‹')
          .fontSize(28)
          .fontColor(this.pal('TEXT_2'))
          .width(28)
          .onClick(() => { this.getUIContext().getRouter().back(); })
        Column({ space: 2 }) {
          Text('设备')
            .fontSize(FontSize.TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pal('TEXT'))
          Text('同一个账号下的所有端')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('TEXT_3'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('刷新')
          .fontSize(FontSize.SMALL)
          .fontColor(this.pal('ACCENT'))
          .onClick(() => { this.refresh(); })
      }
      .width('100%')
      .padding({ left: Space.MD, right: Space.MD, top: Space.SM, bottom: Space.SM })
      .backgroundColor(this.pal('BG'))
      .border({ width: { bottom: 1 }, color: this.pal('BORDER_SOFT') })

      Column({ space: Space.MD }) {
        Text('当前连接')
          .fontSize(FontSize.SMALL)
          .fontColor(this.pal('TEXT_2'))
        Text(this.endpoint)
          .fontSize(FontSize.SMALL)
          .fontColor(this.pal('TEXT_3'))
          .width('100%')
          .padding(Space.MD)
          .backgroundColor(this.pal('SURFACE'))
          .borderRadius(Radius.MD)

        if (this.accountId.length > 0) {
          Text(`账号 ${this.accountId}`)
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('TEXT_3'))
        }

        Text('已链接的设备')
          .fontSize(FontSize.SMALL)
          .fontColor(this.pal('TEXT_2'))

        if (this.loading) {
          Row({ space: Space.SM }) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(this.pal('ACCENT'))
            Text('正在读取…')
              .fontSize(FontSize.SMALL)
              .fontColor(this.pal('TEXT_3'))
          }
        } else if (this.devices.length === 0) {
          Text(this.notice)
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('TEXT_3'))
            .width('100%')
        } else {
          ForEach(this.devices, (d: DeviceInfo) => {
            Row({ space: Space.MD }) {
              Text(this.roleIcon(d.role))
                .fontSize(21)
                .fontColor(this.pal('TEXT_2'))
                .width(24)
              Column({ space: 2 }) {
                Text(d.name.length > 0 ? d.name : d.id)
                  .fontSize(FontSize.BODY)
                  .fontColor(this.pal('TEXT'))
                Text(`${this.roleLabel(d.role)} · ${d.online ? '在线' : '离线'}` +
                  (d.online ? '' : (d.lastSeen > 0 ? ` · 最后在线 ${formatRelative(d.lastSeen)}` : '')))
                  .fontSize(FontSize.TINY)
                  .fontColor(d.online ? this.pal('OK') : this.pal('TEXT_3'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Circle({ width: 7, height: 7 })
                .fill(d.online ? this.pal('OK') : this.pal('TEXT_3'))
            }
            .width('100%')
            .padding(Space.MD)
            .backgroundColor(this.pal('SURFACE'))
            .borderRadius(Radius.MD)
          }, (d: DeviceInfo) => d.id)
        }

        Text('多端同步: 桌面端执行, 手机观察与下发指令; 多个手机可以同时连同一个账号。')
          .fontSize(FontSize.TINY)
          .fontColor(this.pal('TEXT_3'))
          .width('100%')
          .margin({ top: Space.LG })
      }
      .width('100%')
      .padding(Space.LG)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal('BG_DEEP'))
    .padding({ top: this.topSafeVp, bottom: this.bottomSafeVp })
    .backgroundImage(this.backdropImage())
    .backgroundImageSize(ImageSize.Cover)
    .backgroundImagePosition(Alignment.Center)
  }
}
