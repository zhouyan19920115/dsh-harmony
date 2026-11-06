/**
 * 消息推送 —— 华为 Push Kit。
 *
 * 手机拿到推送 token 之后交给桥接服务(desktop), 桌面端有"待办"时就能把手机叫醒:
 *   1. pushService.getToken() 取推送 token;
 *   2. 把 token 报给桥接服务 POST /api/v1/phone/push-token;
 *   3. 用 notificationManager.setBadgeNumber() 设置系统角标(App 图标上的数量)。
 *
 * 模拟器上这三件事都会失败(没有 HMS 账号、没有开通推送服务、角标不被支持),
 * 所以**任何一步失败都只记日志、绝不抛出去** —— 拿不到推送 token 不应该让 App 起不来。
 */
import { pushService } from '@kit.PushKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppState } from './AppState';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF05;

/** 取推送 token 并报给桥接服务。 */
export async function registerPushToken(): Promise<void> {
  try {
    const token: string = await pushService.getToken();
    hilog.info(DOMAIN, TAG, '拿到推送 token, 长度 %{public}d', token.length);
    await AppState.client.registerPushToken(token);
    hilog.info(DOMAIN, TAG, '推送 token 已报给桥接服务');
  } catch (e) {
    // 模拟器 / 未开通推送服务 / 未登录 HMS 账号: 记一条日志就跳过。
    // **这一步的错误只进 hilog, 不往界面上抛** ⇒ 系统的英文报错留在日志里就行,
    // 不需要汉化(汉化了反而不好排查)✓
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, '拿不到推送 token(code %{public}d): %{public}s', err.code ?? -1, err.message ?? 'unknown');
  }
}

/** 设置系统角标(App 图标上的待办数量)。失败就跳过。 */
export async function setBadgeNumber(count: number): Promise<void> {
  try {
    await notificationManager.setBadgeNumber(count);
  } catch (e) {
    // 同上: 只记日志, 不给用户看 ⇒ 英文报错不用汉化 ✓
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, '设置角标失败(code %{public}d): %{public}s', err.code ?? -1, err.message ?? 'unknown');
  }
}
