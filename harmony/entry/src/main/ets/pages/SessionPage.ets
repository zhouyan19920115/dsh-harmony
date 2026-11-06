/**
 * 会话详情**路由页** —— 薄壳, 真正的界面在 SessionDetailView.ets 里。
 *
 * 为什么拆开:
 *   - 单栏(窄屏): 这里作为 @Entry 页面承载, 列表点进去还是 router.pushUrl 跳过来,
 *     行为和以前完全一样;
 *   - 双栏(宽屏 >= 600vp): SessionListPage.ets 把 SessionDetailView 直接嵌在右栏,
 *     不跳路由。
 * 两边共用 SessionDetailView 这一份实现, 不会出现"两套会话详情"。
 */
import { SessionDetailView } from './SessionDetailView';

export interface SessionRouteParams {
  sessionId: string;
  title: string;
  cwd: string;
}

@Entry
@Component
struct SessionPage {
  @State private sessionId: string = '';
  @State private title: string = '';
  @State private cwd: string = '';

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as SessionRouteParams;
    if (params !== undefined && params !== null) {
      this.sessionId = params.sessionId;
      this.title = params.title;
      this.cwd = params.cwd;
    }
  }

  build() {
    Column() {
      SessionDetailView({
        sessionId: this.sessionId,
        title: this.title,
        cwd: this.cwd,
        showBack: true
      })
    }
    .width('100%')
    .height('100%')
  }
}
