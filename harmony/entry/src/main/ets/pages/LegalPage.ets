/**
 * 协议全文页 —— 隐私政策 / 用户协议。
 *
 * 设置页点「查看」跳过来, 路由参数带文档 id:
 *   router.pushUrl({ url: 'pages/LegalPage', params: { id: 'privacy' } })
 */
import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { legalDoc, LegalDoc, PRIVACY_ID, LEGAL_BASE_URL } from '../common/Legal';
import { Palette, Space, FontSize } from '../common/Theme';

/** 路由参数 */
interface LegalRouteParams {
  id: string;
}

@Entry
@Component
struct LegalPage {
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
    if (key === 'SIDEBAR') { return Palette.SIDEBAR; }
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

  /** 文档 id */
  @State docId: string = PRIVACY_ID;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as LegalRouteParams;
    if (params !== undefined && params !== null && params.id.length > 0) {
      this.docId = params.id;
    }
  }

  /** 当前文档 */
  private doc(): LegalDoc {
    return legalDoc(this.docId);
  }

  /** 正文按空行拆段 ⇒ 一段一个 Text, 排版比一整坨好读 ✓ */
  private paragraphs(): string[] {
    const body: string = this.doc().body;
    return body.split('\n\n');
  }

  /** 在线版的地址(隐私政策 / 用户协议 各一个 ✓)。 */
  private onlineUrl(): string {
    if (this.docId === PRIVACY_ID) {
      return `${LEGAL_BASE_URL}index.html`;
    }
    return `${LEGAL_BASE_URL}user-agreement.html`;
  }

  /** 把在线版地址复制到剪贴板。 */
  private copyOnlineUrl(): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.onlineUrl());
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: '在线版地址已复制' });
      }).catch(() => {
        promptAction.showToast({ message: '复制失败, 长按上面那行地址也行' });
      });
    } catch (e) {
      promptAction.showToast({ message: '复制失败, 长按上面那行地址也行' });
    }
  }

  build() {
    Scroll() {
      Column({ space: Space.MD }) {
        // ---------- 顶部栏 ----------
        Row({ space: Space.MD }) {
          Text('‹ 返回')
            .fontSize(FontSize.BODY)
            .fontColor(this.pal('ACCENT'))
            .onClick(() => { router.back(); })
          Text(this.doc().title)
            .fontSize(FontSize.HEAD)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pal('TEXT'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, top: Space.MD, bottom: Space.MD })
        .backgroundColor(this.pal('SIDEBAR'))

        Text(`更新日期: ${this.doc().updated}`)
          .fontSize(FontSize.TINY)
          .fontColor(this.pal('TEXT_3'))
          .width('100%')
          .padding({ left: Space.LG, right: Space.LG, top: Space.LG })

        ForEach(this.paragraphs(), (para: string) => {
          Text(para)
            .fontSize(FontSize.SMALL)
            .fontColor(this.pal('TEXT_2'))
            .lineHeight(20)
            .width('100%')
            .padding({ left: Space.LG, right: Space.LG })
        }, (para: string): string => para.substring(0, 24))

        Text('勾选同意在「设置 → 隐私与协议」里。')
          .fontSize(FontSize.TINY)
          .fontColor(this.pal('TEXT_3'))
          .width('100%')
          .padding({ left: Space.LG, right: Space.LG, top: Space.XL, bottom: Space.SM })

        Row({ space: Space.SM }) {
          Text(`在线版: ${LEGAL_BASE_URL}`)
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('ACCENT'))
            .layoutWeight(1)
          Text('复制链接')
            .fontSize(FontSize.TINY)
            .fontColor(this.pal('ACCENT'))
            .onClick(() => { this.copyOnlineUrl(); })
        }
        .width('100%')
        .padding({ left: Space.LG, right: Space.LG, bottom: Space.XL })
      }
      .width('100%')
      .align(Alignment.TopStart)
      .backgroundColor(this.pal('BG'))
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
