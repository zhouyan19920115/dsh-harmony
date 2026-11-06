/**
 * 局域网自动发现 + 一键切远程。
 *
 * 手机和电脑在同一 WiFi 时, 不该让用户手输 IP:
 * - 电脑上跑着的 bridge 会在 `/_dsh/discover` 上应答「我这台装了桌面端」,
 *   没装这套代码的电脑根本不响应, 所以扫到的就是那台;
 * - 扫到之后用**配对码**换令牌(配对码 60 秒一换, 控制台同时打印, 用户能核对);
 * - 要离开局域网了, 点「切到远程」, 电脑把中继地址和令牌交给手机, 手机自动切换。
 */
import { connection, http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { hasChinese, requestJson } from './Http';

const TAG: string = 'DshHarmony';
const DOMAIN: number = 0xFF06;

/** 桥接服务的默认端口。 */
const BRIDGE_PORT: number = 8787;
/**
 * 自动探测尝试的端口。
 *
 * 8787 是默认端口(插件默认值), 优先扫; 第一轮没找到时, 再兜底扫整段
 * 8787~8799(外加 8899) —— 只要桥接改端口时保持在这一段里, 手机就**不需要任何手动处理**。
 */
const BRIDGE_PORT_FIRST: number = 8787;
const BRIDGE_PORT_LAST: number = 8799;
const BRIDGE_EXTRA_PORTS: number[] = [8899];
/** 兜底端口扫描: 超时更短(先保证能扫完多轮)。 */
const ALT_PROBE_TIMEOUT: number = 200;
/** 兜底端口扫描: 并发更高。 */
const ALT_PROBE_CONCURRENCY: number = 128;
/** 兜底端口扫描: 最多花多久。 */
const ALT_SCAN_BUDGET: number = 45000;

/** 全部候选端口: 8787..8799 + 8899(去重) */
function candidatePorts(): number[] {
  const out: number[] = [];
  for (let port: number = BRIDGE_PORT_FIRST; port <= BRIDGE_PORT_LAST; port += 1) {
    out.push(port);
  }
  for (const extra of BRIDGE_EXTRA_PORTS) {
    if (out.indexOf(extra) < 0) {
      out.push(extra);
    }
  }
  return out;
}
/**
 * 扫描一个候选地址的超时(毫秒)。
 *
 * 桥接的探测是毫秒级的(30~53 ms), 所以 800 ms 足够: 慢的机器(桥接正忙着跟桌面端
 * 同步)也来得及回, 又不会让整轮扫描白等好几秒。
 */
const PROBE_TIMEOUT: number = 800;
/**
 * 前几个地址给更长的超时(毫秒)。
 *
 * 桥接刚启动的时候, 第一个探测可能要两秒(它正在扫会话列表), 800 ms 会漏掉它。
 */
const SLOW_PROBE_TIMEOUT: number = 2000;
/** 有几个地址享受这个长超时。 */
const SLOW_PROBE_COUNT: number = 3;
/** 同时探测多少个地址。 */
const PROBE_CONCURRENCY: number = 24;
/**
 * 整个扫描最多花多久(毫秒)。
 *
 * 254 个地址、并发 24, 每轮 0.8 s, 十一轮差不多 9 s —— 15 s 够用。
 */
const SCAN_BUDGET: number = 15000;

/** 桌面上的一台电脑。 */
export interface DesktopInfo {
  /** 电脑名, 例如「我的台式机」 */
  name: string;
  /** 手机能访问到的地址 */
  url: string;
  /** 桥接服务的主机名 */
  host: string;
  /** 桥接服务的端口 */
  port: number;
  /** 短时配对码 */
  code: string;
  /** 配对码的过期时间(毫秒时间戳) */
  expiresAt: number;
}

/** 配对结果。 */
export interface PairResult {
  token: string;
  url: string;
  name: string;
}

/** 远程(云中继)配置。 */
export interface RemoteConfig {
  available: boolean;
  relayUrl: string;
  /** 中继侧的 WebSocket 地址(桥接给的, 手机不要自己拼)✓ */
  wsUrl: string;
  /** 兜底地址(直连 IP, 主地址超时的时候用; 可能为空 = 没有兜底)✓ */
  fallbackRelayUrl: string;
  fallbackWsUrl: string;
  token: string;
  accountId: string;
  deviceId: string;
  reason: string;
}

/** 发现接口的返回(只取用得到的字段)。 */
interface DiscoverResponse {
  name?: string;
  url?: string;
  host?: string;
  port?: number;
  code?: string;
  expiresAt?: number;
}

/** 配对接口的返回。 */
interface PairResponse {
  token?: string;
  url?: string;
  name?: string;
}

/** 远程配置的返回。 */
interface RemoteResponse {
  available?: boolean;
  relayUrl?: string;
  /** 中继侧的 WebSocket 地址(桥接给的, 手机不要自己拼)✓ */
  wsUrl?: string;
  /** 兜底: 直连 IP 的 REST / WS 地址(主地址走 Cloudflare 隧道超时时用)✓ */
  fallbackRelayUrl?: string;
  fallbackWsUrl?: string;
  token?: string;
  accountId?: string;
  deviceId?: string;
  reason?: string;
}

/**
 * 手机自己的局域网地址。
 *
 * 拿不到就返回空字符串, 调用方会退回到常见的 192.168.x.x 网段。
 */
export async function localIPv4(): Promise<string> {
  try {
    const net = await connection.getDefaultNetSync();
    const addresses = await net.getAddressesByName('localhost');
    for (const address of addresses) {
      if (address.address.includes(':')) continue;
      if (address.address.startsWith('127.')) continue;
      return address.address;
    }
  } catch (e) {
    hilog.warn(DOMAIN, TAG, '拿不到本机地址: %{public}s', (e as Error).message ?? '');
  }
  return '';
}

/**
 * 手机自己的局域网地址(从网卡列表里挑)。
 *
 * {@link localIPv4} 是「用 localhost 反查」, 在模拟器上只能查回环地址;
 * 这里直接读网卡属性, 拿一个真的能被别的机器访问到的 IPv4。
 * 局域网共享(把安装包发给电脑)用这个地址。
 */
export async function localIPv4FromLinks(): Promise<string> {
  try {
    const handles: connection.NetHandle[] = connection.getAllNetsSync();
    for (const handle of handles) {
      const properties: connection.ConnectionProperties = connection.getConnectionPropertiesSync(handle);
      const links: connection.LinkAddress[] = properties.linkAddresses;
      for (const link of links) {
        const address: string = link.address.address;
        if (address.length === 0) continue;
        if (address.includes(':')) continue; // IPv6
        if (address.startsWith('127.')) continue; // 回环
        return address;
      }
    }
  } catch (e) {
    hilog.warn(DOMAIN, TAG, '拿不到网卡地址: %{public}s', (e as Error).message ?? '');
  }
  return '';
}

/**
 * 手机自己的局域网地址(按网卡挑, 无线优先)。
 *
 * 这台手机上同时有: lo、rmnet_ims00/rmnet_ims10(蜂窝)、wlan0(真正的 WiFi)、
 * p2p0、chba0、ancowlan0(172.17.x.x)—— 挑错网卡就会扫到错的网段, 一个都扫不到。
 * 所以: 无线(wlan*)优先, 蜂窝(rmnet*)和虚拟网卡(p2p0/chba0/ancowlan*)直接排除。
 */
export async function localIPv4s(): Promise<string[]> {
  const out: string[] = [];
  try {
    const handles: connection.NetHandle[] = connection.getAllNetsSync();
    const ranked: RankedAddress[] = [];
    for (const handle of handles) {
      const properties: connection.ConnectionProperties = connection.getConnectionPropertiesSync(handle);
      const rank: number = interfaceRank(properties.interfaceName ?? '');
      if (rank >= 9) {
        continue;
      }
      for (const link of properties.linkAddresses) {
        const address: string = link.address.address;
        if (address.length === 0) continue;
        if (address.includes(':')) continue; // IPv6
        if (address.startsWith('127.')) continue; // 回环
        ranked.push({ address: address, rank: rank });
      }
    }
    ranked.sort((a: RankedAddress, b: RankedAddress) => a.rank - b.rank);
    for (const item of ranked) {
      if (!out.includes(item.address)) {
        out.push(item.address);
      }
    }
  } catch (e) {
    hilog.warn(DOMAIN, TAG, '拿不到网卡地址: %{public}s', (e as Error).message ?? '');
  }
  return out;
}

/** 网卡名 → 优先级(越小越优先, 9 表示不要)。 */
function interfaceRank(name: string): number {
  const n: string = name.toLowerCase();
  if (n.startsWith('wlan')) return 0; // 无线 ✓
  if (n.startsWith('eth')) return 1; // 有线 ✓
  if (n.startsWith('rmnet')) return 9; // 蜂窝 ✓
  if (n === 'p2p0' || n === 'chba0' || n.startsWith('ancowlan')) return 9; // 虚拟网卡 ✓
  if (n === 'lo') return 9;
  return 2;
}

/** 带优先级的网卡地址。 */
interface RankedAddress {
  address: string;
  rank: number;
}

/**
 * 默认网关的地址。
 *
 * 桥接常常和网关在同一段(192.168.1.1 这种), 扫网关所在的网段不会错。
 */
export async function defaultGateway(): Promise<string> {
  try {
    const handle: connection.NetHandle = connection.getDefaultNetSync();
    const properties: connection.ConnectionProperties = connection.getConnectionPropertiesSync(handle);
    for (const route of properties.routes) {
      if (route.isDefaultRoute && route.hasGateway) {
        const address: string = route.gateway.address;
        if (address.length > 0 && !address.includes(':')) {
          return address;
        }
      }
    }
  } catch (e) {
    hilog.warn(DOMAIN, TAG, '拿不到默认网关: %{public}s', (e as Error).message ?? '');
  }
  return '';
}

/** 本机地址所在网段的候选主机(最多 254 个)。 */
export function subnetCandidates(local: string): string[] {
  const parts = local.split('.');
  if (parts.length !== 4) return [];
  const prefix = `${parts[0]}.${parts[1]}.${parts[2]}`;
  const hosts: string[] = [];
  for (let i = 1; i <= 254; i++) {
    hosts.push(`${prefix}.${i}`);
  }
  // 模拟器(QEMU)的宿主机固定是 10.0.2.2, 不在它自己的网段里。
  if (local.startsWith('10.0.2.')) {
    hosts.unshift('10.0.2.2');
  }
  return hosts;
}

/**
 * 扫一遍局域网, 找出所有装了桌面端的电脑。
 *
 * @param onProgress 每探完一批回调一次(已探数量, 已找到数量), 用来给用户进度提示
 */
export async function discoverDesktops(onProgress?: (scanned: number, found: number) => void): Promise<DesktopInfo[]> {
  // 扫哪些网段: 自己的网卡(无线优先) + 默认网关那一段 + 兜底的常见网段 ✓
  const locals: string[] = await localIPv4s();
  const candidates: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (const local of locals) {
    for (const host of subnetCandidates(local)) {
      if (!seen.has(host)) {
        seen.add(host);
        candidates.push(host);
      }
    }
  }
  const gateway: string = await defaultGateway();
  if (gateway.length > 0) {
    for (const host of subnetCandidates(gateway)) {
      if (!seen.has(host)) {
        seen.add(host);
        candidates.push(host);
      }
    }
  }
  if (candidates.length === 0) {
    // 网卡地址都拿不到: 扫几个最常见的网段, 免得直接放弃 ✓
    const prefixes: string[] = ['192.168.0', '192.168.1', '10.0.0', '10.0.1'];
    for (const prefix of prefixes) {
      for (let i = 1; i <= 254; i += 1) {
        const host: string = `${prefix}.${i}`;
        if (!seen.has(host)) {
          seen.add(host);
          candidates.push(host);
        }
      }
    }
  }
  if (candidates.length === 0) {
    return [];
  }
  hilog.info(DOMAIN, TAG, '开始扫描: %{public}d 个地址(网卡 %{public}s)',
    candidates.length, locals.join(','));
  const found: DesktopInfo[] = [];
  const seenUrl: Set<string> = new Set<string>();
  let scanned: number = 0;

  // 第一轮: 默认端口 8787
  const firstDeadline: number = Date.now() + SCAN_BUDGET;
  scanned += await scanHosts(candidates, BRIDGE_PORT, PROBE_CONCURRENCY, PROBE_TIMEOUT,
    SLOW_PROBE_TIMEOUT, SLOW_PROBE_COUNT, firstDeadline, found, seenUrl, onProgress, scanned);

  // 第二轮: 没找到时才兜底扫 8788..8799 + 8899(给自定义端口的桥接/插件用)
  if (found.length === 0) {
    const altDeadline: number = Date.now() + ALT_SCAN_BUDGET;
    const ports: number[] = candidatePorts();
    for (let k = 0; k < ports.length; k += 1) {
      const port: number = ports[k];
      if (port === BRIDGE_PORT) {
        continue;   // 第一轮扫过了
      }
      if (Date.now() >= altDeadline) break;
      hilog.info(DOMAIN, TAG, '默认端口没找到, 试端口 %{public}d', port);
      scanned += await scanHosts(candidates, port, ALT_PROBE_CONCURRENCY, ALT_PROBE_TIMEOUT,
        0, 0, altDeadline, found, seenUrl, onProgress, scanned);
      if (found.length > 0) break;
    }
  }
  hilog.info(DOMAIN, TAG, '扫描结束: 探了 %{public}d 个, 找到 %{public}d 个', scanned, found.length);
  found.sort((a, b) => a.name.localeCompare(b.name));
  return found;
}

/**
 * 在**一个端口**上扫一遍候选地址。
 *
 * @returns 这一轮实际探了多少个地址(供进度提示累计)
 */
async function scanHosts(candidates: string[], port: number, concurrency: number,
  timeoutMs: number, slowTimeoutMs: number, slowCount: number, deadline: number,
  found: DesktopInfo[], seenUrl: Set<string>, onProgress?: (scanned: number, found: number) => void,
  scannedBefore: number = 0): Promise<number> {
  let scanned: number = 0;
  for (let i = 0; i < candidates.length && Date.now() < deadline; i += concurrency) {
    const batch: string[] = candidates.slice(i, i + concurrency);
    const results: (DesktopInfo | null)[] = await Promise.all(batch.map((host: string, index: number) => {
      // 前几个地址给更长时间: 桥接刚启动时第一枪要两秒左右 ✓
      const timeout: number = slowCount > 0 && (i + index) < slowCount ? slowTimeoutMs : timeoutMs;
      return probeHost(host, port, timeout);
    }));
    for (const result of results) {
      if (result === null) continue;
      if (seenUrl.has(result.url)) continue;
      seenUrl.add(result.url);
      found.push(result);
    }
    scanned += batch.length;
    if (onProgress) onProgress(scannedBefore + scanned, found.length);
  }
  return scanned;
}

/** 探一个地址, 是桌面端就返回它的信息, 否则 null。 */
async function probeHost(host: string, port: number, timeoutMs: number): Promise<DesktopInfo | null> {
  const url = `http://${host}:${port}/_dsh/discover`;
  try {
    const result = await requestJson(http.RequestMethod.GET, url, '', '', timeoutMs);
    if (result.code !== 200 || result.body.length === 0) return null;
    const parsed = JSON.parse(result.body) as DiscoverResponse;
    if (parsed === undefined || parsed === null) return null;
    const address = parsed.url ?? `http://${host}:${port}`;
    return {
      name: parsed.name ?? host,
      url: address,
      host: parsed.host ?? host,
      port: parsed.port ?? port,
      code: parsed.code ?? '',
      expiresAt: parsed.expiresAt ?? 0
    };
  } catch (e) {
    return null;
  }
}

/**
 * 拿一个地址当前的配对码(拿不到就空串)。
 *
 * 走的是发现接口 —— 它不要令牌, 只回答「现在的码是多少」。
 */
async function fetchPairingCode(url: string, timeoutMs: number): Promise<string> {
  try {
    const result = await requestJson(http.RequestMethod.GET, `${url}/_dsh/discover`, '', '', timeoutMs);
    if (result.code !== 200 || result.body.length === 0) return '';
    const parsed = JSON.parse(result.body) as DiscoverResponse;
    return parsed?.code ?? '';
  } catch (e) {
    return '';
  }
}

/**
 * 配对之前, 把手里这个码刷新成**当前**那个码。
 *
 * 配对码只活一小会儿(桥接那边默认 60 秒), 而「拿到码」到「用户点下连接」之间可能隔着
 * 一次扫描、一次确认、一次手慢 —— 那一刻码早就换了, 于是必然报「配对码已经过期」。
 * 所以真正去配对之前, 再问一次桌面端要当前的码 ✓
 *
 * 码还有 5 秒以上才过期时不折腾: 同一个码还有效, 多跑一趟往返没有意义。
 */
export async function freshPairingCode(desktop: DesktopInfo): Promise<string> {
  const expiresAt = desktop.expiresAt ?? 0;
  if (expiresAt > 0 && Date.now() < expiresAt - 5000) return desktop.code;
  const fresh = await fetchPairingCode(desktop.url, 5000);
  return fresh.length > 0 ? fresh : desktop.code;
}

/**
 * 用配对码换令牌。
 *
 * 配对码由电脑在控制台打印, 一小会儿就换 —— 同网段的人即使看到了发现响应,
 * 也不能拿它直接换令牌(除非他正好在有效期内看到控制台)。
 */
export async function pairWith(url: string, code: string): Promise<PairResult> {
  const result = await requestJson(http.RequestMethod.POST, `${url}/api/v1/pair`, '',
    JSON.stringify({ code: code }), 8000);
  if (result.code !== 200) {
    // requestJson 已经把非 2xx 换成一句人话了 ⇒ 直接报出去 ✓
    // (桥接那边说的中文也在里面, 比如「配对码无效或已过期」✓)
    // 提示语里刻意不写「配对码」三个字: 连接页靠这个词判断"是不是码过期了",
    // 这里一说, 它就会把话说得更准 ✓
    const why: string = result.body.length > 0 ? result.body : '配对码没被认出来';
    throw new Error(`配对失败: ${why}, 重新扫一次码就好`);
  }
  const parsed = JSON.parse(result.body) as PairResponse;
  if (parsed === undefined || parsed === null || parsed.token === undefined) {
    throw new Error('配对失败: 电脑没有返回令牌, 重新扫一次码就好');
  }
  return {
    token: parsed.token,
    url: parsed.url ?? url,
    name: parsed.name ?? '桌面端'
  };
}

/**
 * 取远程(云中继)配置, 手机据此自动切到中继地址。
 */
export async function fetchRemoteConfig(url: string, token: string): Promise<RemoteConfig> {
  const result = await requestJson(http.RequestMethod.GET, `${url}/api/v1/remote-config`, token, '', 8000);
  if (result.code !== 200) {
    // 非 2xx 的回答已经是人话了 ⇒ 直接报出去 ✓ (原来这里只报一个「HTTP 502」, 用户看不懂)
    const why: string = result.body.length > 0 ? result.body : `服务端返回 ${result.code}`;
    throw new Error(`取远程配置失败: ${why}`);
  }
  const parsed = JSON.parse(result.body) as RemoteResponse;
  if (parsed === undefined || parsed === null) {
    throw new Error('取远程配置失败: 返回为空, 稍后重试');
  }
  // reason 是直接摆给用户看的一行字 ⇒ 英文的换成中文, 别让用户看到天书 ✓
  const reason: string = parsed.reason ?? '';
  return {
    available: parsed.available === true,
    relayUrl: parsed.relayUrl ?? '',
    wsUrl: parsed.wsUrl ?? '',
    fallbackRelayUrl: parsed.fallbackRelayUrl ?? '',
    fallbackWsUrl: parsed.fallbackWsUrl ?? '',
    token: parsed.token ?? '',
    accountId: parsed.accountId ?? '',
    deviceId: parsed.deviceId ?? '',
    reason: reason.length > 0 && hasChinese(reason) ? reason : '桌面端没有配置云中继'
  };
}
