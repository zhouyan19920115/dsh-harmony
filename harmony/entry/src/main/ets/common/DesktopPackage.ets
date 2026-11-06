/**
 * 桌面端安装包 —— 把「电脑那一份」从手机上交给电脑。
 *
 * 别人只装了 App, 电脑上什么都没有; 这份 zip 就是电脑要跑的东西, 解压后
 * 双击里面的「双击我-开始.cmd」就能跑。
 *
 * **包本体只有 App 内置的一个来源**: `resources/rawfile/dsh-harmony-desktop.zip`(约 260 KB)。
 * 它跟着 App 一起装 ⇒
 *   - 不用联网, 不用等下载;
 *   - 永远是跟 App 同一个版本(不会拿到中继上那份旧的);
 *   - App 不用带几十兆 ⇒ 首屏不会被它拖死 ✓
 *
 * 曾经还有一条「从云中继按需下载」的路(中继上摆的是 42 MB 的单文件版), 已删掉:
 * 手机为了把一份安装包交给电脑, 要先从云上拉 42 MB —— 慢、费流量, 而且拿到的
 * 是服务器上那份(可能过期)。内置那份几百 KB 就够。
 *
 * 三条路(面板里按成功率排):
 *
 *   1. **通过局域网发送**(推荐): 手机起一个极简 HTTP 服务, 电脑浏览器直接下载;
 *   2. **通过文件发送**: 弹系统的分享面板, 用户自己选微信 / 蓝牙 / 无线分享 / 星闪;
 *   3. **在文件管理中定位**: 把文件存到手机的公共目录(「下载」), 在文件管理里找到它再分享。
 *
 * 电脑那端需要 **Node.js 22 或更高版本**。「双击我-开始.cmd」会先找:
 *   1. 这个包里自带的那份(runtime\node.exe);
 *   2. 系统 PATH 上的 Node;
 *   3. 都没有 ⇒ **联网下载一个装到 runtime\ 里**(免管理员、免改系统 PATH, 等一会儿即可)。
 */
import { common, Want } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { http, socket } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { resourceManager } from '@kit.LocalizationKit';
import { localIPv4s } from './Discovery';
import { explain } from './ErrorText';
import { explainHttpCode, hasChinese } from './Http';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF05;

/** 传到电脑上的文件名(电脑上下载到的就是这个名)。 */
export const PACKAGE_FILE_NAME: string = 'dsh-harmony-desktop.zip';
/** 局域网下载用的路径。 */
export const PACKAGE_DOWNLOAD_PATH: string = '/dsh-harmony-desktop.zip';
/** 云中继上那个下载路径(桌面端包放在中继上 ⇒ App 不用带四十兆 ✓)。 */
export const REMOTE_PACKAGE_PATH: string = '/_dsh/desktop-package';

/** 装好的那份包的版本号记在哪儿(跟别的配置不混在一起 ✓)。 */
const PACKAGE_STATE_STORE: string = 'dsh_desktop_package';
const KEY_VERSION: string = 'version';
const KEY_SHA256: string = 'sha256';

/** zip 的 MIME 类型(分享面板靠它挑接收方)。 */
export const PACKAGE_MIME: string = 'application/zip';

/** 局域网共享的起始端口, 被占了就往后找。 */
const PORT_START: number = 8899;

/** 最多试几个端口。 */
const PORT_TRIES: number = 8;

/** 一次最多发多少字节(避免一次 send 太大)。 */
const CHUNK_SIZE: number = 1024 * 1024;

/** 一次最多写多少字节(系统的单次写入有上限, 分批写才稳)。 */
const WRITE_CHUNK: number = 4 * 1024 * 1024;

/** 桌面端安装包的信息。 */
export interface DesktopPackageInfo {
  /** 沙箱里的绝对路径 */
  path: string;
  /** 分享用的 uri(公共目录里的; 没有就用沙箱里的) */
  uri: string;
  /** 沙箱(bundle 作用域)里的 uri */
  sandboxUri: string;
  /** 文件名 */
  name: string;
  /** 字节数 */
  size: number;
  /** 人话大小, 例如 "41.3 MB" */
  sizeText: string;
}

/** 局域网共享的信息。 */
export interface LanShareInfo {
  /** 电脑上要打开的地址 */
  url: string;
  /** 用的端口 */
  port: number;
}

/** 从回答的头里取一个值(ArkTS 里 header 的类型是 Object, 得先转成字符串再解析 ✓)。 */
function headerValue(response: http.HttpResponse, name: string): string {
  const text: string = JSON.stringify(response.header);
  if (text.length === 0) {
    return '';
  }
  const parsed: Record<string, string> = JSON.parse(text) as Record<string, string>;
  const value: string | undefined = parsed[name];
  return value === undefined ? '' : value;
}

/** 中继上那份安装包的样子(HEAD 问来的 ✓)。 */
export interface RemotePackageInfo {
  /** 版本号(变了就重下 ✓) */
  version: string;
  /** SHA-256(小写十六进制; 空 = 中继没给, 那就只校验字节数) */
  sha256: string;
  /** 字节数 */
  size: number;
}

/** 准备安装包时可以给的东西。 */
export interface DesktopPackageOptions {
  /** 从哪儿下载(云中继上的那个地址; 空 = 只用 App 内置的那份) */
  downloadUrl?: string;
  /** 进度回调(把当前这一步告诉用户) */
  onProgress?: (text: string) => void;
}

/** 取包 + 分享。 */
export class DesktopPackage {
  /**
   * 把安装包复制进沙箱。
   *
   * 沙箱里这份是自己用的(局域网共享从磁盘读它); 分享给别的应用要靠公共目录里那份。
   */
  static async writeToSandbox(context: common.UIAbilityContext, bytes: Uint8Array): Promise<DesktopPackageInfo> {
    if (bytes === undefined || bytes === null || bytes.byteLength === 0) {
      throw new Error('安装包是空的');
    }
    const name: string = PACKAGE_FILE_NAME;
    const path: string = `${context.filesDir}/${name}`;
    let fd: number = -1;
    try {
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fd = file.fd;
      DesktopPackage.writeAll(fd, bytes);
    } catch (e) {
      const err = e as BusinessError;
      // 系统的报错是英文 ⇒ 解释一遍 ✓
      throw new Error(`写文件失败: ${explain(err.message ?? '')}`);
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, '关文件失败: %{public}s', (e as BusinessError).message ?? '');
        }
      }
    }
    // 写完对一下大小: 系统一次不一定写得下, 少写了自己是不知道的。
    const stat = fileIo.statSync(path);
    if (stat.size !== bytes.byteLength) {
      throw new Error(`写文件不完整: 写了 ${stat.size} 字节, 应该 ${bytes.byteLength} 字节`);
    }
    // bundle 作用域的 uri: file://<包名>/<文件名>。
    // fileUri.getUriFromPath 给的是 file://docs/... 那种, 别的应用读不到。
    const bundleName: string = context.abilityInfo.bundleName;
    const sandboxUri: string = `file://${bundleName}/${name}`;
    hilog.info(DOMAIN, TAG, '安装包就绪: %{public}s (%{public}d 字节, uri=%{public}s)',
      path, stat.size, sandboxUri);
    return {
      path: path,
      uri: sandboxUri,
      sandboxUri: sandboxUri,
      name: name,
      size: stat.size,
      sizeText: DesktopPackage.humanSize(stat.size)
    };
  }

  /**
   * 把一段字节写进 fd, 写完为止。
   *
   * 系统的单次写入有上限, 一次写 40 多兆会只写进去一部分 —— 所以要分批写,
   * 还得看返回值(写进去多少算多少)。
   */
  private static writeAll(fd: number, bytes: Uint8Array): void {
    const total: number = bytes.byteLength;
    let done: number = 0;
    while (done < total) {
      const length: number = Math.min(WRITE_CHUNK, total - done);
      const chunk: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset + done, bytes.byteOffset + done + length);
      const written: number = fileIo.writeSync(fd, chunk);
      if (written <= 0) {
        throw new Error(`写文件只写进去 ${done} 字节`);
      }
      done += written;
    }
  }

  /** 沙箱里那份安装包的路径。 */
  static sandboxPath(context: common.UIAbilityContext): string {
    return `${context.filesDir}/${PACKAGE_FILE_NAME}`;
  }

  /**
   * 沙箱里已经有一份准备好了的安装包吗。
   *
   * 有就直接用 —— 第二次点「发送到电脑」是秒开的, 不用再下四十兆 ✓
   */
  static cached(context: common.UIAbilityContext): DesktopPackageInfo | null {
    const path: string = DesktopPackage.sandboxPath(context);
    try {
      const stat = fileIo.statSync(path);
      if (!stat.isFile() || stat.size <= 0) {
        return null;
      }
      const bundleName: string = context.abilityInfo.bundleName;
      const sandboxUri: string = `file://${bundleName}/${PACKAGE_FILE_NAME}`;
      return {
        path: path,
        uri: sandboxUri,
        sandboxUri: sandboxUri,
        name: PACKAGE_FILE_NAME,
        size: stat.size,
        sizeText: DesktopPackage.humanSize(stat.size)
      };
    } catch (e) {
      // 还没有这份文件(正常情况)✓
      return null;
    }
  }

  /**
   * 读 App 内置的那份安装包(resources/rawfile 里那个 zip)。
   *
   * 它跟着 App 一起装 ⇒ 不用联网、不会过期、也不会去云上拉几十兆 ✓
   */
  static async readEmbedded(context: common.UIAbilityContext): Promise<Uint8Array> {
    try {
      const manager: resourceManager.ResourceManager = context.resourceManager;
      const bytes: Uint8Array = await manager.getRawFileContent(PACKAGE_FILE_NAME);
      if (bytes === undefined || bytes === null || bytes.byteLength === 0) {
        throw new Error('内置的安装包是空的');
      }
      hilog.info(DOMAIN, TAG, '读到 App 内置的安装包: %{public}d 字节', bytes.byteLength);
      return bytes;
    } catch (e) {
      const err = e as BusinessError;
      // 英文原文只进 hilog, 用户看到的是人话 ✓
      hilog.error(DOMAIN, TAG, '读内置安装包失败: %{public}s', err.message ?? '');
      throw new Error(DesktopPackage.NO_PACKAGE_HINT);
    }
  }

  /**
   * 中继上那份安装包的下载地址(从当前地址推出来)。
   *
   * 中继地址可能带账号作用域(`/acc-x/dev-y`) ⇒ 真正的中继地址是 scheme + 主机 ✓
   *
   * 什么时候才去中继下:
   *   - 地址带账号作用域(那是中继)✓
   *   - 或者地址是 https(中继对外都是 https)✓
   * 局域网的桥接(纯 http、没有作用域)⇒ 不去下(桥接不提供这个文件)⇒
   * 直接用 App 内置的那份 ✓
   */
  static remoteUrl(endpoint: string): string {
    const text: string = (endpoint ?? '').trim();
    if (!text.startsWith('http://') && !text.startsWith('https://')) {
      return '';
    }
    const afterScheme: number = text.indexOf('://') + 3;
    const slash: number = text.indexOf('/', afterScheme);
    const base: string = slash < 0 ? text : text.slice(0, slash);
    const path: string = slash < 0 ? '' : text.slice(slash + 1);
    const scoped: boolean = path.startsWith('acc-') && path.indexOf('/dev-') > 0;
    if (!scoped && !text.startsWith('https://')) {
      // 局域网里的桥接: 它不发这个文件 ⇒ 别白跑一趟 ✓
      return '';
    }
    return `${base}${REMOTE_PACKAGE_PATH}`;
  }

  /**
   * 问中继: 那份安装包现在是哪一版、多大、校验值是多少。
   *
   * 只发一个 HEAD 请求(几十字节)⇒ 沙箱里那份是不是最新的, 一次就问清了 ✓
   */
  static async probe(url: string): Promise<RemotePackageInfo> {
    const request = http.createHttp();
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.HEAD,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 15000,
      });
      if (response.responseCode !== 200) {
        // 状态码翻译成人话: 用户看到的是「桌面端版本可能太旧」, 不是光秃秃一个 404 ✓
        throw new Error(`中继没有提供安装包: ${explainHttpCode(response.responseCode)}`);
      }
      const version: string = headerValue(response, 'x-dsh-package-version');
      const sha256: string = headerValue(response, 'x-dsh-package-sha256').toLowerCase();
      const size: number = Number.parseInt(headerValue(response, 'content-length'), 10);
      return { version: version, sha256: sha256, size: Number.isNaN(size) ? 0 : size };
    } catch (e) {
      const err = e as BusinessError;
      const raw: string = err.message ?? '';
      // 自己抛的中文错误原样往上抛(别套两层车轱辘话)✓
      // 系统/网络的英文错误才解释一遍 ✓
      if (hasChinese(raw)) {
        throw new Error(raw);
      }
      throw new Error(`问不到中继的安装包: ${explain(raw)}`);
    } finally {
      request.destroy();
    }
  }

  /**
   * 从中继下载安装包, 写进沙箱。
   *
   * 手机按需下载 ⇒ App 不用带四十兆的安装包 ⇒ 首屏不被它拖死 ✓
   * 下完**校验字节数和 SHA-256** —— 传坏了要能发现 ✓
   * (SHA-256 是分块算落盘之后那个文件的, 不占内存 ✓)
   */
  static async download(context: common.UIAbilityContext, url: string,
    expected: RemotePackageInfo, onProgress?: (text: string) => void): Promise<DesktopPackageInfo> {
    if (onProgress) {
      onProgress('正在从云中继下载安装包…');
    }
    const request = http.createHttp();
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 180000,
      });
      if (response.responseCode !== 200) {
        // 状态码翻译成人话 ✓
        throw new Error(`下载失败: ${explainHttpCode(response.responseCode)}`);
      }
      const data = response.result as ArrayBuffer;
      if (data === undefined || data === null || data.byteLength === 0) {
        throw new Error('下载到的安装包是空的, 稍后重试');
      }
      const bytes: Uint8Array = new Uint8Array(data);
      // 字节数对不上 ⇒ 传了一半/传坏了 ✓
      if (expected.size > 0 && bytes.byteLength !== expected.size) {
        throw new Error(`下载不完整: 收到 ${bytes.byteLength} 字节, 应该 ${expected.size} 字节, 稍后重试`);
      }
      const info: DesktopPackageInfo = await DesktopPackage.writeToSandbox(context, bytes);
      // SHA-256 对不上 ⇒ 内容坏了(落盘之后算那个文件, 分块算不占内存 ✓)
      if (expected.sha256.length === 64) {
        const digest: string = await DesktopPackage.sha256OfFile(info.path);
        if (digest !== expected.sha256) {
          DesktopPackage.removeQuietly(info.path);
          throw new Error(`校验不对: SHA-256 是 ${digest}, 应该是 ${expected.sha256}`);
        }
      }
      await DesktopPackage.rememberVersion(context, expected.version, expected.sha256);
      hilog.info(DOMAIN, TAG, '安装包从中继下载好了: %{public}s (%{public}d 字节, 版本 %{public}s)',
        info.path, info.size, expected.version);
      return info;
    } catch (e) {
      const err = e as BusinessError;
      const raw: string = err.message ?? '';
      // 自己抛的中文错误原样往上抛 ✓ 系统/网络的英文错误才解释一遍 ✓
      if (hasChinese(raw)) {
        throw new Error(raw);
      }
      throw new Error(`下载不到安装包: ${explain(raw)}`);
    } finally {
      request.destroy();
    }
  }

  /** 删掉一个文件(失败了也别慌 ✓)。 */
  private static removeQuietly(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '删不掉那个文件: %{public}s', (e as BusinessError).message ?? '');
    }
  }

  /** 一个文件的 SHA-256(分块算, 不占内存 ✓)。 */
  static async sha256OfFile(path: string): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    const stat = fileIo.statSync(path);
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const buffer: ArrayBuffer = new ArrayBuffer(WRITE_CHUNK);
      let offset: number = 0;
      while (offset < stat.size) {
        const length: number = Math.min(WRITE_CHUNK, stat.size - offset);
        const read: number = fileIo.readSync(file.fd, buffer, { offset: offset, length: length });
        if (read <= 0) {
          break;
        }
        const chunk: Uint8Array = new Uint8Array(buffer.slice(0, read));
        md.update({ data: chunk });
        offset += read;
      }
    } finally {
      try {
        fileIo.closeSync(file.fd);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, '关文件失败: %{public}s', (e as BusinessError).message ?? '');
      }
    }
    const digest = await md.digest();
    let hex: string = '';
    for (let i = 0; i < digest.data.length; i++) {
      hex += digest.data[i].toString(16).padStart(2, '0');
    }
    return hex;
  }

  /**
   * 准备好安装包(**按需** —— 启动路径上绝不碰它 ✓)。
   *
   * 来源只有 **App 内置的那一份**(resources/rawfile/dsh-harmony-desktop.zip, 约 260 KB):
   *   - 不用联网, 不用等下载 ✓
   *   - 永远跟 App 同一个版本(不会拿到中继上那份旧的)✓
   * 沙箱里已经有同一份(上次用过)⇒ 直接复用, 秒开 ✓
   */
  static async prepareOnDemand(context: common.UIAbilityContext,
    options?: DesktopPackageOptions): Promise<DesktopPackageInfo> {
    const bytes: Uint8Array = await DesktopPackage.readEmbedded(context);
    // 沙箱里那份跟内置的同一个大小 ⇒ 就是同一份 ⇒ 不用重写 ✓
    const cached: DesktopPackageInfo | null = DesktopPackage.cached(context);
    if (cached !== null && cached.size === bytes.byteLength) {
      hilog.info(DOMAIN, TAG, '用沙箱里已有的安装包: %{public}s (%{public}d 字节)',
        cached.path, cached.size);
      if (options?.onProgress) {
        options.onProgress(`安装包已经准备好了: ${cached.sizeText}`);
      }
      return cached;
    }
    return DesktopPackage.writeToSandbox(context, bytes);
  }

  /** App 里没有内置安装包时, 给用户的话(怎么办写清楚 ✓)。 */
  static readonly NO_PACKAGE_HINT: string =
    '这个 App 里没有内置桌面端安装包。请把 App 更新到最新版本; 或者在电脑上打开 <中继地址>/_dsh/desktop-package 手动下载, 解压后双击「双击我-开始.cmd」。';

  /** 记住装好的那一版(版本号变了就重下 ✓)。 */
  private static async rememberVersion(context: common.UIAbilityContext,
    version: string, sha256: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PACKAGE_STATE_STORE);
      await store.put(KEY_VERSION, version);
      await store.put(KEY_SHA256, sha256);
      await store.flush();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '版本号没记住: %{public}s', (e as BusinessError).message ?? '');
    }
  }

  /** 记住的那一版是多少。 */
  private static async storedVersion(context: common.UIAbilityContext): Promise<string> {
    try {
      const store = await preferences.getPreferences(context, PACKAGE_STATE_STORE);
      return await store.get(KEY_VERSION, '') as string;
    } catch (e) {
      return '';
    }
  }

  /** 这段字节的 SHA-256(小写十六进制)。 */
  static async sha256Hex(bytes: Uint8Array): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    md.update({ data: bytes });
    const digest = await md.digest();
    let hex: string = '';
    for (let i = 0; i < digest.data.length; i++) {
      hex += digest.data[i].toString(16).padStart(2, '0');
    }
    return hex;
  }

  /** 读沙箱里那份安装包的字节(分享/存到公共目录时用)。 */
  static readSandbox(context: common.UIAbilityContext): Uint8Array {
    const path: string = DesktopPackage.sandboxPath(context);
    const stat = fileIo.statSync(path);
    const bytes: Uint8Array = new Uint8Array(stat.size);
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      let done: number = 0;
      while (done < stat.size) {
        const length: number = Math.min(WRITE_CHUNK, stat.size - done);
        const read: number = fileIo.readSync(file.fd, bytes.buffer.slice(done, done + length), {
          offset: done,
          length: length
        });
        if (read <= 0) {
          break;
        }
        done += read;
      }
      if (done !== stat.size) {
        throw new Error(`读文件不完整: 读了 ${done} 字节, 应该 ${stat.size} 字节`);
      }
      return bytes;
    } finally {
      try {
        fileIo.closeSync(file.fd);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, '关文件失败: %{public}s', (e as BusinessError).message ?? '');
      }
    }
  }

  /** 人话大小。 */
  static humanSize(size: number): string {
    if (size < 1024) {
      return `${size} B`;
    }
    if (size < 1024 * 1024) {
      return `${(size / 1024).toFixed(1)} KB`;
    }
    return `${(size / 1024 / 1024).toFixed(1)} MB`;
  }

  /**
   * 存到手机的公共目录(系统的「保存文件」面板, 用户选个位置, 一般是「下载」)。
   *
   * 存完之后这份文件就是公共的了:
   *   - 文件管理里能翻到它, 可以再分享给别人;
   *   - 系统分享面板读得到它(能显示大小和图标), 弹出来的是「分享 1 项」那种面板。
   *
   * 返回保存后的 uri。
   */
  static async saveToPublic(context: common.UIAbilityContext, bytes: Uint8Array): Promise<string> {
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [PACKAGE_FILE_NAME];
    // 格式是「说明|后缀」, 写反了系统会拿说明当后缀用(存出来叫 "xxxzip 压缩包")。
    options.fileSuffixChoices = ['zip 压缩包|.zip'];
    const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
    const uris: string[] = await viewPicker.save(options);
    if (uris === undefined || uris.length === 0) {
      throw new Error('没有选保存位置');
    }
    const uri: string = uris[0];
    DesktopPackage.writeToUri(uri, bytes);
    hilog.info(DOMAIN, TAG, '已存到公共目录: %{public}s', uri);
    return uri;
  }

  /** 把内容写进一个 uri(保存面板给回来的那种)。 */
  private static writeToUri(uri: string, bytes: Uint8Array): void {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      DesktopPackage.writeAll(file.fd, bytes);
    } finally {
      try {
        fileIo.closeSync(file.fd);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, '关文件失败: %{public}s', (e as BusinessError).message ?? '');
      }
    }
  }

  /**
   * 用文件管理器打开这个文件(在文件管理里定位它)。
   *
   * 沙箱里的文件文件管理器打不开, 所以要先存到公共目录。
   */
  static async locateInFileManager(context: common.UIAbilityContext, uri: string): Promise<void> {
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.content'],
      type: PACKAGE_MIME,
      uri: uri
    };
    try {
      await context.startAbility(want);
    } catch (e) {
      const err = e as BusinessError;
      // 系统的报错是英文 ⇒ 解释一遍(能命中规则就带上中文说明)✓
      throw new Error(`文件管理器打不开这个文件: ${explain(err.message ?? '')}`);
    }
  }

  /**
   * 调起系统分享面板, 用户在里面选微信 / 蓝牙 / 无线分享 / 星闪。
   *
   * 电脑要**先打开蓝牙并允许接收文件**, 否则分享面板里选不到它。
   */
  static async shareViaSystem(context: common.UIAbilityContext, uri: string): Promise<void> {
    const want: Want = {
      action: 'ohos.want.action.sendData',
      entities: ['entity.content'],
      type: PACKAGE_MIME,
      uri: uri
    };
    hilog.info(DOMAIN, TAG, '调起系统分享: %{public}s', uri);
    try {
      await context.startAbility(want);
    } catch (e) {
      const err = e as BusinessError;
      const reason: string = err.message ?? '';
      if (reason.includes('No matching ability')) {
        throw new Error('打不开分享面板(可能已经开着了), 关掉再试一次');
      }
      // 其它的系统报错是英文 ⇒ 解释一遍 ✓
      throw new Error(`打不开分享面板: ${explain(reason)}`);
    }
  }
}

/**
 * 局域网共享: 手机把安装包当静态文件发出去, 电脑用浏览器下载。
 *
 * 只有一个文件、一个路径, 所以不用完整的 HTTP 服务:
 * `GET /<包名>` 给 zip, `GET /` 给一个只有下载链接的小页面。
 */
export class LanShareServer {
  private server: socket.TCPSocketServer | null = null;
  private port: number = 0;
  private filePath: string = '';
  private fileSize: number = 0;

  /** 共享是不是还在跑。 */
  isRunning(): boolean {
    return this.server !== null;
  }

  /**
   * 起服务。返回电脑上要打开的地址。
   *
   * 端口从 8899 开始, 被占了就往后找(8899 → 8900 → …)。
   * 文件从磁盘分块读, 不用整个塞进内存。
   */
  async start(filePath: string, fileSize: number): Promise<LanShareInfo> {
    if (this.server !== null) {
      // 已经有一个共享在跑 —— 但那个服务器可能早就死了(手机切到后台被系统回收、
      // 或者上一次启动失败时没清干净)。直接报错会把用户**永久卡住**: 之后每次点
      // 「开始共享」都只说「已经在共享了」, 下载地址再也出不来 ⇒ 所以先关掉旧的再重开 ✓
      hilog.info(DOMAIN, TAG, '已经有一个共享在跑, 先把它关掉再重开');
      await this.stop();
    }
    // 以磁盘上真实的字节数为准(写文件的时候系统不一定一次写全)。
    const stat = fileIo.statSync(filePath);
    this.filePath = filePath;
    this.fileSize = stat.size;
    hilog.info(DOMAIN, TAG, '共享的文件: %{public}s (%{public}d 字节)', filePath, this.fileSize);
    let lastError: string = '';
    for (let i = 0; i < PORT_TRIES; i++) {
      const port: number = PORT_START + i;
      const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      server.on('connect', (connection: socket.TCPSocketConnection) => {
        this.onConnection(connection);
      });
      try {
        await server.listen({ address: '0.0.0.0', port: port });
        const ip: string = await this.hostAddress();
        if (ip.length === 0) {
          // 拿不到 WiFi 地址就明说, 别给一个手机自己都访问不到的地址 ✓
          lastError = '拿不到本机的 WiFi 地址, 请用方案二(扫码或复制链接)';
          throw new Error(lastError);
        }
        // **只有真的起来了才记下来**: 记早了的话, 上面那一抛就会把这个功能永久卡死
        // (this.server 一直非空, 之后每次「开始共享」都报「已经在共享了」) ✓
        this.server = server;
        this.port = port;
        const host: string = ip;
        hilog.info(DOMAIN, TAG, '局域网共享起来了: %{public}s', `${host}:${port}`);
        return { url: `http://${host}:${port}${PACKAGE_DOWNLOAD_PATH}`, port: port };
      } catch (e) {
        const err = e as BusinessError;
        lastError = err.message ?? '';
        hilog.warn(DOMAIN, TAG, '端口 %{public}d 用不了: %{public}s', port, lastError);
        try {
          await server.close();
        } catch (e2) {
          hilog.warn(DOMAIN, TAG, '关掉失败的监听: %{public}s', (e2 as BusinessError).message ?? '');
        }
      }
    }
    throw new Error(`${PORT_START} 起的端口都占着, 稍后重试或者用方案二(扫码或复制链接): ${explain(lastError)}`);
  }

  /** 关掉服务。 */
  async stop(): Promise<void> {
    const server: socket.TCPSocketServer | null = this.server;
    this.server = null;
    this.port = 0;
    if (server === null) {
      return;
    }
    try {
      await server.close();
      hilog.info(DOMAIN, TAG, '局域网共享已停止');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '停止共享失败: %{public}s', (e as BusinessError).message ?? '');
    }
  }

  /** 电脑上要访问的地址: 优先用网卡上的真实地址。 */
  private async hostAddress(): Promise<string> {
    const addresses: string[] = await localIPv4s();
    if (addresses.length > 0) {
      return addresses[0];
    }
    return '';
  }

  /** 一个连接: 读完请求头, 回一个响应。 */
  private onConnection(connection: socket.TCPSocketConnection): void {
    let buffer: string = '';
    let answered: boolean = false;
    connection.on('message', (message: socket.SocketMessageInfo) => {
      if (answered) {
        return;
      }
      try {
        buffer += util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(message.message));
      } catch (e) {
        hilog.warn(DOMAIN, TAG, '读请求失败: %{public}s', (e as BusinessError).message ?? '');
        return;
      }
      const index: number = buffer.indexOf('\r\n\r\n');
      if (index < 0) {
        return;
      }
      answered = true;
      const requestLine: string = buffer.substring(0, index).split('\r\n')[0];
      const parts: string[] = requestLine.split(' ');
      const method: string = parts.length > 0 ? parts[0].toUpperCase() : '';
      const path: string = parts.length > 1 ? parts[1] : '/';
      this.respond(connection, method, path);
    });
    connection.on('error', () => {
      hilog.warn(DOMAIN, TAG, '连接出错');
    });
  }

  /** 回一个响应。 */
  private async respond(connection: socket.TCPSocketConnection, method: string, path: string): Promise<void> {
    try {
      if (method === 'GET' || method === 'HEAD') {
        if (path === PACKAGE_DOWNLOAD_PATH || path.indexOf(`${PACKAGE_DOWNLOAD_PATH}?`) === 0) {
          await this.sendPackage(connection, method === 'HEAD');
          return;
        }
        if (path === '/' || path.length === 0) {
          await this.sendPage(connection);
          return;
        }
      }
      await this.sendText(connection, 404, 'text/plain; charset=utf-8', '没有这个文件');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '回应失败: %{public}s', (e as BusinessError).message ?? '');
      try {
        await connection.close();
      } catch (e2) {
        hilog.warn(DOMAIN, TAG, '关连接失败: %{public}s', (e2 as BusinessError).message ?? '');
      }
    }
  }

  /** 把安装包发出去(从磁盘分块读)。 */
  private async sendPackage(connection: socket.TCPSocketConnection, headOnly: boolean): Promise<void> {
    const head: string = [
      'HTTP/1.1 200 OK',
      `Content-Type: ${PACKAGE_MIME}`,
      `Content-Length: ${this.fileSize}`,
      `Content-Disposition: attachment; filename="${PACKAGE_FILE_NAME}"`,
      'Cache-Control: no-store',
      'Connection: close',
      '',
      ''
    ].join('\r\n');
    await connection.send({ data: head });
    if (headOnly) {
      await connection.close();
      return;
    }
    const file: fileIo.File = fileIo.openSync(this.filePath, fileIo.OpenMode.READ_ONLY);
    const fd: number = file.fd;
    try {
      let sent: number = 0;
      while (sent < this.fileSize) {
        const length: number = Math.min(CHUNK_SIZE, this.fileSize - sent);
        const buffer: ArrayBuffer = new ArrayBuffer(length);
        const read: number = fileIo.readSync(fd, buffer);
        if (read <= 0) {
          break;
        }
        await connection.send({ data: buffer.slice(0, read) });
        sent += read;
      }
    } finally {
      try {
        fileIo.closeSync(fd);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, '关文件失败: %{public}s', (e as BusinessError).message ?? '');
      }
    }
    await connection.close();
  }

  /** 一个只有下载链接的小页面(用户只输入主机名时也能点到)。 */
  private async sendPage(connection: socket.TCPSocketConnection): Promise<void> {
    const html: string = `<!doctype html><html><head><meta charset="utf-8">`
      + `<title>DSH 桌面端</title></head><body style="font-family:sans-serif;background:#151517;color:#E9EAEB">`
      + `<h2>DSH 桌面端安装包</h2>`
      + `<p><a style="color:#7AAFFF" href="${PACKAGE_DOWNLOAD_PATH}">${PACKAGE_FILE_NAME}</a>`
      + ` (${DesktopPackage.humanSize(this.fileSize)})</p>`
      + `<p>下载完解压, 双击 <code>双击我-开始.cmd</code>。</p>`
      + `<p>这台电脑需要 <b>Node.js 22 或更高版本</b>(没有的话启动脚本会自己下载安装一个, 要联网)。</p></body></html>`;
    await this.sendText(connection, 200, 'text/html; charset=utf-8', html);
  }

  /** 回一段文本。 */
  private async sendText(connection: socket.TCPSocketConnection, code: number,
    contentType: string, body: string): Promise<void> {
    const head: string = [
      `HTTP/1.1 ${code} OK`,
      `Content-Type: ${contentType}`,
      `Content-Length: ${body.length}`,
      'Connection: close',
      '',
      ''
    ].join('\r\n');
    await connection.send({ data: head + body });
    await connection.close();
  }
}
