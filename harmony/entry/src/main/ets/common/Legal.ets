/**
 * 隐私政策 / 用户协议 —— 全文 + 勾选状态的本地存储。
 *
 * 为什么放在 common 而不是页面里:
 * - 全文要给两个页面用(设置页的「查看」、独立的协议页)⇒ 只能有一份 ✓
 * - 「勾没勾」是全局状态 ⇒ 局域网自动探测(扫网)这种动作要在
 *   **任何**入口(首屏自动配对 / 连接页手动探测)先问一句「用户同意了吗」⇒
 *   放 common 才能被统一拦住 ✓
 *
 * 存储: 单独一个 preferences 文件(和连接配置、显示设置都分开 ⇒
 * 重新配对不会把协议勾选状态清掉 ✓)
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF06;

const STORE_NAME: string = 'dsh_harmony_legal';
const KEY_PRIVACY: string = 'privacyAccepted';
const KEY_USER: string = 'userAccepted';

/** 协议文档 */
export interface LegalDoc {
  /** privacy | user */
  id: string;
  /** 标题 */
  title: string;
  /** 更新日期 */
  updated: string;
  /** 正文(段落之间用空行分开 ⇒ 页面里按 \n\n 拆段渲染) */
  body: string;
}

/** 勾选状态 */
export interface ConsentState {
  /** 隐私政策勾没勾 */
  privacy: boolean;
  /** 用户协议勾没勾 */
  user: boolean;
}

export const PRIVACY_ID: string = 'privacy';
export const USER_ID: string = 'user';

/**
 * 在线版的地址(部署在广州那台中继机上 ✓)。
 *
 * App 里的正文是离线的那一份 ⇒ 手机没网也能看;
 * 这个地址是给「想用浏览器看/想给别人看」的人用的 ✓
 *
 * 对外只用域名, 不出现服务器 IP ✓
 */
export const LEGAL_BASE_URL: string = 'https://dsh-relay.example.com/legal/';

/** 隐私政策全文 */
export const PRIVACY_POLICY: LegalDoc = {
  id: PRIVACY_ID,
  title: '隐私政策',
  updated: '2026-10-25',
  body: `一、我们是谁

DSHsync 是 DSH 的鸿蒙手机客户端, 用来让你在手机上查看和操作电脑上运行的 DSH 会话。
开发主体: 开发者(个人开发者)。DSHsync 与模型服务商无隶属、授权或合作关系, 只是 DSH 开源桌面端的一个第三方客户端。

二、我们收集什么

本 App 不收集、不上传你的个人身份信息(姓名、手机号、身份证号、位置等), 也没有广告和用户画像。
App 只在「你的设备本地」保存以下内容, 且不会主动上传:

1. 连接信息: 电脑的局域网地址 / 中继地址、配对后换到的访问令牌、设备号。
   令牌用系统 HUK(硬件密钥库)加密后存盘, 界面默认打码显示。
2. 显示偏好: 字号、主题。
3. 协议勾选状态: 你是否已阅读并同意本政策与《用户协议》。
4. 通知相关: 华为 Push 推送令牌, 以及本地通知需要的会话 id。

三、我们什么时候会访问网络

只有在你「主动使用」以下功能时才会发起网络请求:

1. 「自动探测」/ 自动配对: 手机会在「当前局域网内」扫描私有地址段, 用来找到运行着 DSH 桌面端的电脑。
   这是局域网内的扫描, 不会把扫描结果发到互联网。
2. 与电脑(或云中继)建立连接: 传输会话内容、模型列表、权限预设等, 走的是你和电脑之间的连接。
3. 接收桌面端推送: 由华为 Push 服务中转, 通知里只带会话 id, 不带会话内容。

在你勾选同意之前, 上述「自动探测」不会执行 —— 我们不会在你不知情的情况下扫你的网络。

四、权限说明

- 网络: 用于连接电脑 / 局域网探测 / 接收推送。
- 通知: 用于桌面端有任务时提醒你(可随时在系统设置里关掉)。
- 摄像头、麦克风、位置、通讯录等: 本 App 不会申请, 也不需要。

五、第三方

App 使用华为 Push Kit 推送服务; 桌面端可能使用你自建或官方的云中继服务。
除此之外没有其它第三方 SDK, 没有广告和统计 SDK。

六、你的控制权

- 随时可以在「设置 → 隐私与协议」里取消勾选; 取消后自动探测会停用。
- 卸载 App 即删除全部本地数据(含令牌与勾选状态)。
- 想彻底清数据, 可以在「设置 → 连接」里重新配对, 或直接卸载重装。

七、未成年人保护

本 App 是开发者工具的移动端, 不面向未成年人收集任何个人信息。

八、联系我们

开发者: YOUR NAME
邮箱: you@example.com
源码: github.com/zhouyan19920115/dsh-harmony`
};

/** 用户协议全文 */
export const USER_AGREEMENT: LegalDoc = {
  id: USER_ID,
  title: '用户协议',
  updated: '2026-10-25',
  body: `一、协议范围

本协议是你与开发者(下称「开发者」)之间关于「DSHsync」的使用约定。
下载、安装、勾选同意并使用本 App, 即表示你接受本协议。

二、软件功能

DSHsync 是 DSH 桌面端的「远程查看与操作端」, 它本身不是模型服务:
它把你在电脑上运行的 DSH 会话(对话、进度、审批、模型与权限设置)搬到手机上看和点。
会话的实际推理在你自己的电脑上完成, 由你自己的电脑连接你配置的模型服务。

三、你的责任

1. 你必须保证电脑端运行的是你自己信任的 DSH 桌面端, 并保管好配对码与访问令牌。
2. 局域网自动探测会在你的内网发出探测请求; 请在受信任的网络下使用。
3. 你对通过本 App 触发的所有操作负责, 包括在会话里批准的命令、修改的文件等。
4. 不得利用本 App 从事违反法律法规、侵害他人合法权益的行为。

四、开源与免责

1. 本 App 与 DSH 桌面端均为开源项目, 按其开源许可证提供, 不附带任何形式的服务承诺。
2. 软件按「现状」提供: 我们尽力保证稳定, 但不保证无错误、不中断或完全满足你的需要。
3. 在法律允许的最大范围内, 因使用或无法使用本 App 造成的间接损失、数据丢失等, 我们不承担责任。

五、协议与隐私的关系

《隐私政策》说明我们收集什么; 本协议说明你如何使用。两者冲突时, 以《隐私政策》为准。

六、协议变更

协议如有更新, 会在 App 内公告; 更新后的协议自你再次勾选同意之日起生效。

七、联系方式

开发者: YOUR NAME
邮箱: you@example.com
源码: github.com/zhouyan19920115/dsh-harmony`
};

/**
 * 协议勾选状态的本地存储。
 *
 * 和 ConfigStore 一样用 preferences, 但单独一个文件。
 * EntryAbility 负责 init(它有 context ⇒ 任何页面都能直接用 ✓)
 */
export class LegalStore {
  private static store: preferences.Preferences | null = null;
  private static context: common.Context | null = null;
  /** 内存里缓存一份 ⇒ 自动探测这种高频判断不用每次都等磁盘 */
  private static cache: ConsentState = { privacy: false, user: false };

  /** 初始化(EntryAbility.onCreate 里调一次 ✓)。 */
  static init(context: common.Context): void {
    LegalStore.context = context;
  }

  private static async ensureStore(): Promise<preferences.Preferences> {
    if (LegalStore.store !== null) {
      return LegalStore.store;
    }
    const context = LegalStore.context;
    if (context === null) {
      throw new Error('协议状态还没初始化, 重启一下 App 就好');
    }
    try {
      const store = await preferences.getPreferences(context, { name: STORE_NAME });
      LegalStore.store = store;
      return store;
    } catch (e) {
      const err = e as BusinessError;
      throw new Error(`打开协议状态失败: ${err.message ?? ''}`);
    }
  }

  /** 读勾选状态(从没存过 ⇒ 都算没勾 ✓)。 */
  static async load(): Promise<ConsentState> {
    try {
      const store = await LegalStore.ensureStore();
      const privacy = await store.get(KEY_PRIVACY, false) as boolean;
      const user = await store.get(KEY_USER, false) as boolean;
      LegalStore.cache = { privacy: privacy, user: user };
      return LegalStore.cache;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '读取协议勾选状态失败: %{public}s', err.message ?? 'unknown');
      return { privacy: false, user: false };
    }
  }

  /** 保存勾选状态。 */
  static async save(state: ConsentState): Promise<void> {
    try {
      const store = await LegalStore.ensureStore();
      await store.put(KEY_PRIVACY, state.privacy);
      await store.put(KEY_USER, state.user);
      await store.flush();
      LegalStore.cache = { privacy: state.privacy, user: state.user };
      hilog.info(DOMAIN, TAG, '协议勾选状态: privacy=%{public}s user=%{public}s',
        state.privacy, state.user);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '保存协议勾选状态失败: %{public}s', err.message ?? 'unknown');
      throw new Error(err.message ?? '保存失败');
    }
  }

  /** 两份都勾了才算同意 —— 自动探测这类动作只看这个 ✓。 */
  static accepted(state: ConsentState): boolean {
    return state.privacy && state.user;
  }

  /**
   * 现在同意了吗(走内存缓存 ⇒ 同步, 可以在热路径上问 ✓)。
   *
   * 还没 load 过缓存时是「没同意」—— 宁可拦住, 也不要偷偷扫网 ✓
   */
  static isAccepted(): boolean {
    return LegalStore.accepted(LegalStore.cache);
  }

  /** 同步一下内存缓存(页面 load 之后调一次 ✓)。 */
  static setCache(state: ConsentState): void {
    LegalStore.cache = { privacy: state.privacy, user: state.user };
  }
}

/** 按 id 取文档(取不到 ⇒ 用户协议兜底 ✓)。 */
export function legalDoc(id: string): LegalDoc {
  if (id === PRIVACY_ID) {
    return PRIVACY_POLICY;
  }
  return USER_AGREEMENT;
}
