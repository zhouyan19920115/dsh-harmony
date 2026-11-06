// The cloud relay itself: the server that the desktop device dials into and that the phone
// dials into.
//
// Two roles, one process:
//
//   * the **device** side is a WebSocket server on `/bridge`
//     (`ws://host:8788/bridge?token=<deviceToken>&deviceId=<deviceId>`). The desktop dials out,
//     so the relay never needs an inbound port on the desktop.
//
//   * the **phone** side is an HTTP server that accepts `/<deviceId>/api/v1/...` and
//     `/<deviceId>/ws?token=...`. Every request is mirrored by a *stream* on the device
//     connection; the relay only moves bytes.
//
// The relay is a dumb pipe: it never parses the bridge business protocol, it does not decide
// who is allowed to talk to the device (`Authorization` is forwarded verbatim and the bridge
// decides) and it never answers a WebSocket upgrade itself (the device answers with its own
// `101 Switching Protocols`).

import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';

import { DeviceSession } from './device-session.js';
import { constantTimeEquals } from './devices.js';
import {
  ACCOUNT_ID_PREFIX,
  ROLE_DESKTOP,
  ROLE_PHONE,
  addDevice,
  createAccount,
  deviceOwners,
  findAccount,
  findAccountByToken,
  findDevice,
  generateAccountToken,
  generateDeviceToken,
  hashSecret,
  listDevices,
  saveAccountRegistry,
  touchDevice,
} from './accounts.js';
import { FRAME } from './frames.js';
import { PHONE_WS_PATH, offeredRelayProtocols } from './relay-protocol.js';
import { RequestRewriter, rewriteHead } from './http-rewriter.js';
import { OPCODE, acceptWebSocket, WsFrameParser } from './ws.js';

const EMPTY = Buffer.alloc(0);
const CRLFCRLF = Buffer.from('\r\n\r\n');

/** Maximum number of bytes that are buffered while the phone request is still being parsed. */
const MAX_CAPTURE_BYTES = 256 * 1024;

/** Maximum number of bytes that may wait for the phone socket when it applies back pressure. */
const MAX_OUT_QUEUE_BYTES = 8 * 1024 * 1024;

/**
 * How long a phone is still reported as `online` after its last heartbeat.
 *
 * A desktop is online while its device WebSocket is connected. A phone has no such connection:
 * it only calls the heartbeat every ~30 s, so its presence is a timestamp and the relay calls
 * it online while the timestamp is younger than this window.
 */
export const PHONE_ONLINE_WINDOW_MS = 60_000;

/** The shape of a phone chosen device id: `dev-p3h1`. */
const PHONE_DEVICE_ID_PATTERN = /^[A-Za-z0-9._-]{1,64}$/u;

/** The shape of a phone device token: 32 bytes as hex (64 characters). */
const PHONE_TOKEN_PATTERN = /^[0-9a-f]{64}$/iu;

/** The longest device name a phone may announce. */
const MAX_DEVICE_NAME_LENGTH = 64;

/** The biggest request body the relay reads for its own endpoints. */
const MAX_RELAY_BODY_BYTES = 64 * 1024;

/** The path the desktop bridge dials in with. */
export const DEVICE_PATH = '/bridge';

/**
 * How many failed device attempts one client address may make per window.
 *
 * A wrong token is answered with 401; when a client burns through its budget the relay stops
 * answering with "wrong token" and answers with 429, so guessing a token gets expensive for
 * the attacker and cheap for the relay.
 */
export const DEFAULT_DEVICE_RATE_LIMIT = 10;
/** The length of the rate limit window in milliseconds (one minute). */
export const DEFAULT_DEVICE_RATE_WINDOW_MS = 60_000;

/**
 * How many registration attempts one client address may make per window.
 *
 * Unlike the device limiter (which counts the *failed* attempts only) the registration limiter
 * counts every attempt: a registration that succeeds creates an account, so an endless stream of
 * them is exactly what has to be stopped.
 */
export const DEFAULT_REGISTRATION_RATE_LIMIT = 10;
/** How many registration attempts one account may see per window. */
export const DEFAULT_REGISTRATION_ACCOUNT_RATE_LIMIT = 5;
/** The length of the registration rate limit window in milliseconds (one minute). */
export const DEFAULT_REGISTRATION_RATE_WINDOW_MS = 60_000;

/**
 * The path a desktop bridge registers itself at (docs/PROTOCOL.md, chapter 8).
 *
 * The relay is the trust boundary here: it issues the credentials, the bridge only proves that
 * it is the same machine as the last time.
 */
export const REGISTER_PATH = '/_relay/accounts/register';

/** The shape of the device id of a registration: `dev-1a2b3c4d`. */
const REGISTER_DEVICE_ID_PATTERN = /^[A-Za-z0-9._-]{1,64}$/u;
/** The shape of the account id of a registration: `acc-5e6f7a8b`. */
const REGISTER_ACCOUNT_ID_PATTERN = /^[A-Za-z0-9._-]{1,64}$/u;
/** The shape of the secret of a machine: at least 16 bytes as hex. */
const REGISTER_SECRET_PATTERN = /^[0-9a-f]{32,128}$/iu;

/** Relay owned endpoints (they are answered before any device is addressed). */
const RELAY_PATHS = new Set(['/_relay/health', '/_relay/devices']);
/** The prefix of the account scoped relay endpoints. */
const RELAY_ACCOUNTS_PREFIX = '/_relay/accounts/';

/**
 * The path the phone downloads the desktop package from.
 *
 * The package is a public file (the desktop bridge, no secret in it), so this endpoint needs no
 * token. The operator can switch it off — then the phone falls back to the copy inside the app.
 */
export const DESKTOP_PACKAGE_PATH = '/_dsh/desktop-package';

/**
 * The privacy policy and the user agreement.
 *
 * They are public pages (no secret in them), so the relay can serve them itself:
 *   GET /legal/                    -> index.html      (the privacy policy)
 *   GET /legal/user-agreement.html -> user-agreement.html
 *
 * The operator points at the directory with `--legal-dir`; without it the endpoint stays off.
 * Serving them here (instead of in nginx) means the pages are reachable through **every**
 * address of the relay: the IP, the domain and the Cloudflare tunnel ✓
 */
export const LEGAL_PATH_PREFIX = '/legal';

/**
 * Is this request target one of the relay's own endpoints?
 *
 * The relay answers them itself, so their bytes must not be forwarded to the device: the device
 * would answer them with its own token check and the extra answer on the connection would be read
 * by the phone as the answer to its next request.
 */
export function isRelayOwnTarget(target) {
  const raw = String(target ?? '');
  const queryIndex = raw.indexOf('?');
  const path = queryIndex === -1 ? raw : raw.slice(0, queryIndex);
  return RELAY_PATHS.has(path)
    || path === DESKTOP_PACKAGE_PATH
    || path === LEGAL_PATH_PREFIX
    || path.startsWith(`${LEGAL_PATH_PREFIX}/`)
    || path.startsWith(RELAY_ACCOUNTS_PREFIX);
}

/**
 * The account the legacy flat device map is folded into.
 *
 * The old constructor only knew a list of devices; they become the members of one implicit
 * account, so the legacy behaviour (a device is found by its id alone) stays exactly the same.
 */
export const LEGACY_ACCOUNT_ID = 'acc-legacy';

/**
 * Normalize the constructor input into one account registry.
 *
 * @param {{accounts?: Map<string, object>, devices?: Map<string, object>, defaultPort?: number}} input
 * @returns {{accounts: Map<string, object>}}
 */
function buildRegistry({ accounts, devices, defaultPort = 8787 }) {
  const registry = { accounts: new Map() };
  if (accounts instanceof Map) {
    for (const [id, account] of accounts) {
      const deviceMap = account.devices instanceof Map ? account.devices : new Map();
      registry.accounts.set(id, {
        id,
        name: account.name ?? id,
        token: account.token ?? '',
        createdAt: account.createdAt ?? Date.now(),
        devices: deviceMap,
      });
    }
    return registry;
  }
  if (devices instanceof Map && devices.size > 0) {
    const deviceMap = new Map();
    for (const [id, device] of devices) {
      deviceMap.set(id, {
        id,
        name: device.name ?? id,
        token: device.token ?? '',
        role: device.role ?? ROLE_DESKTOP,
        port: device.port ?? defaultPort,
        lastSeen: device.lastSeen ?? 0,
        accountId: LEGACY_ACCOUNT_ID,
      });
    }
    registry.accounts.set(LEGACY_ACCOUNT_ID, {
      id: LEGACY_ACCOUNT_ID,
      name: 'legacy',
      // The legacy account has no secret: an empty token can never be presented.
      token: '',
      createdAt: Date.now(),
      devices: deviceMap,
    });
    return registry;
  }
  return registry;
}

/**
 * The timers of the relay. They are injectable so that the tests can run with short timeouts.
 */
export function createTimers({
  pingIntervalMs = 20_000,
  pongTimeoutMs = 60_000,
  maxMissedPings = 3,
  streamIdleMs = 60_000,
  openTimeoutMs = 10_000,
  phoneAuthTimeoutMs = 20_000,
} = {}) {
  return {
    pingIntervalMs,
    pongTimeoutMs,
    maxMissedPings,
    streamIdleMs,
    openTimeoutMs,
    phoneAuthTimeoutMs,
    setTimeout: (fn, ms) => {
      const handle = setTimeout(fn, ms);
      handle.unref?.();
      return handle;
    },
    clearTimeout: (handle) => clearTimeout(handle),
    setInterval: (fn, ms) => {
      const handle = setInterval(fn, ms);
      handle.unref?.();
      return handle;
    },
    clearInterval: (handle) => clearInterval(handle),
  };
}

/**
 * One phone connection. It captures the raw bytes of the socket, rewrites the request targets
 * (the device prefix is removed) and pipes the bytes to the device and back.
 */
class PhoneLink {
  constructor({ server, socket }) {
    this.server = server;
    this.socket = socket;
    this.buffer = EMPTY;
    this.rewriter = null;
    this.stream = null;
    this.deviceId = null;
    this.routed = false;
    this.closed = false;
    this.paused = false;
    this.outQueue = [];
    this.outBytes = 0;
    /** 中继自己回答过的请求的请求体还剩多少字节要丢。 */
    this.discardRemaining = 0;
    /**
     * The phone has to prove that it is the phone of this device before anything reaches the
     * device. `null` means "no gate": the connection is a plain byte pipe.
     */
    this.gate = null;
    /** The bytes of the phone that wait for the gate. */
    this.gateBytes = EMPTY;
    /** The WebSocket frame parser of the gate (the phone masks its frames). */
    this.gateParser = null;
    /** The timer that closes a phone that does not authenticate in time. */
    this.gateTimer = null;
    /** This connection is a WebSocket (a byte pipe), not an HTTP request stream. */
    this.webSocket = false;

    socket.setTimeout(0);
    socket.setNoDelay(true);
    this.onData = (chunk) => this.#onData(chunk);
    this.onEnd = () => this.destroy();
    this.onError = () => this.destroy();
    this.onClose = () => this.destroy();
    socket.on('data', this.onData);
    socket.on('end', this.onEnd);
    socket.on('error', this.onError);
    socket.on('close', this.onClose);
  }

  /**
   * Give up the phone side of this connection **without** closing the socket.
   *
   * A device session takes the socket over: the relay's own WebSocket server reads the
   * handshake and from then on the socket carries binary frames. The raw capture has to stop
   * right here, otherwise the device's frames pile up in the phone buffer and the connection is
   * killed as an "oversized request head" (the device would drop every few seconds).
   */
  release() {
    if (this.closed) return;
    this.closed = true;
    this.buffer = EMPTY;
    this.rewriter = null;
    this.socket.removeListener('data', this.onData);
    this.socket.removeListener('end', this.onEnd);
    this.socket.removeListener('error', this.onError);
    this.socket.removeListener('close', this.onClose);
  }

  /**
   * 把 socket 从 Node 的 HTTP 服务器手里接管过来。
   *
   * HTTP 服务器靠 socket 的 'data' 事件喂自己的解析器。一旦这条连接变成字节管道,
   * 设备的回答就会被那个解析器当成"新的请求"解析, 于是中继自己写在同一条连接上的
   * 回答会被挤在后面(连接上同时只允许一个响应在飞), 手机端就会读错。
   *
   * 只摘掉别人的监听, 本连接自己的监听要留着。
   */
  detachHttpParser() {
    for (const event of ['data', 'end']) {
      for (const listener of this.socket.listeners(event)) {
        if (listener === this.onData || listener === this.onEnd) {
          continue;
        }
        this.socket.removeListener(event, listener);
      }
    }
  }

  #onData(chunk) {
    if (this.closed) return;
    // 中继自己回答过的请求, 它的请求体字节也不能转发给设备。
    if (this.discardRemaining > 0) {
      const drop = Math.min(this.discardRemaining, chunk.length);
      this.discardRemaining -= drop;
      chunk = chunk.subarray(drop);
      if (chunk.length === 0) return;
    }
    if (this.rewriter) {
      let out;
      try {
        out = this.rewriter.push(chunk);
      } catch (error) {
        this.server.log('warn', `the phone request could not be parsed: ${error.message}`);
        this.destroy();
        return;
      }
      if (out.length > 0) this.#forward(out);
      return;
    }
    if (this.webSocket) {
      // The WebSocket path is a byte pipe: the frames either wait for the gate or go to the
      // device right away.
      if (this.gate !== null) {
        this.#gateData(chunk);
        return;
      }
      this.#forward(chunk);
      return;
    }
    this.buffer = Buffer.concat([this.buffer, chunk]);
    if (this.buffer.length > MAX_CAPTURE_BYTES) {
      this.server.log('warn', 'the phone sent a request head that is too large');
      this.destroy();
    }
  }

  /**
   * 丢弃当前请求的原始字节。
   *
   * 中继自己回答的请求(`/_relay/…`)不能转发给设备: 设备会用自己的令牌检查去回答它,
   * 于是同一个连接上会多出一个 401, 而手机端的 HTTP 客户端会把这个多出来的响应
   * 当成下一个请求的响应 —— 于是"设备列表"接口莫名其妙地收到 401。
   *
   * 丢弃的粒度是"这一个请求": 请求头 + 请求体。请求体可能分片到达, 所以剩下的字节
   * 由 `discardRemaining` 继续丢。
   */
  discardRequest() {
    const index = this.buffer.indexOf(CRLFCRLF);
    if (index === -1) {
      // 头部还没收全: 保守起见全部丢掉。
      this.buffer = EMPTY;
      this.discardRemaining = 0;
      return;
    }
    const head = this.buffer.subarray(0, index).toString('latin1');
    const lengthMatch = /content-length:\s*(\d+)/iu.exec(head);
    const chunked = /transfer-encoding:\s*chunked/iu.test(head);
    this.buffer = this.buffer.subarray(index + CRLFCRLF.length);
    if (chunked) {
      // chunked 的请求体我们不解析: 整个缓冲区丢掉, 并把后续字节也丢掉一小段,
      // 以免请求体被当成下一个请求转发出去。实践中这里的请求都是 Content-Length。
      this.buffer = EMPTY;
      this.discardRemaining = 0;
      return;
    }
    const length = lengthMatch ? Number.parseInt(lengthMatch[1], 10) : 0;
    // 只有"还没到达"的请求体字节才能留给后面的分片去丢。已经在缓冲区里的那部分必须现在
    // 就清掉: 否则它会被当成下一个请求的头转发给设备, 设备的 HTTP 解析器就会报
    // "Invalid method encountered" 并回一个空的 400, 同时 discardRemaining 还会把下一个
    // 请求的头吃掉几个字节, 整个字节流就错位了。
    const available = Math.min(length, this.buffer.length);
    this.buffer = this.buffer.subarray(available);
    this.discardRemaining = length - available;
    this.server.log('info', `a relay owned request was discarded: ${head.split('\r\n')[0]} (body ${length} bytes, ${available} already here)`);
  }

  /** Bind the connection to a device and start forwarding. */
  route({ deviceId, prefix, singleRequest }) {
    this.routed = true;
    this.deviceId = deviceId;
    // 从这里开始这条连接就是一条字节管道: 设备的回答会被直接写进 socket,
    // 而 Node 的 HTTP 解析器会把这些字节当成"下一个请求"来解析 —— 于是中继自己的
    // 回答会被设备多出来的回答挤掉, 手机端就会把错的响应当成自己请求的响应。
    // 所以这里把 socket 从 Node 的 HTTP 服务器手里接管过来(只摘掉它的 data/end 监听,
    // 本连接自己的监听要留着)。
    this.detachHttpParser();
    this.rewriter = new RequestRewriter({ prefix, singleRequest, dropTarget: isRelayOwnTarget });
    const out = this.rewriter.push(this.buffer);
    this.buffer = EMPTY;
    if (out.length > 0) this.#forward(out);
  }

  /**
   * The phone's WebSocket: the request head goes to the device right away (the device answers
   * with its own `101 Switching Protocols`), the frames wait for the gate.
   *
   * The gate is what keeps an unauthenticated client away from the device: as long as it is
   * open, not a single byte of the phone reaches the device.
   *
   * @param {{deviceId: string, prefix: string, gate?: {verify: (token: string) => boolean}|null}} options
   */
  routeWebSocket({ deviceId, prefix, gate = null }) {
    this.routed = true;
    this.webSocket = true;
    this.deviceId = deviceId;
    // 从这里开始这条连接就是一条字节管道: 设备的回答会被直接写进 socket,
    // 而 Node 的 HTTP 解析器会把这些字节当成"下一个请求"来解析 —— 于是中继自己的
    // 回答会被设备多出来的回答挤掉, 手机端就会把错的响应当成自己请求的响应。
    // 所以这里把 socket 从 Node 的 HTTP 服务器手里接管过来(只摘掉它的 data/end 监听,
    // 本连接自己的监听要留着)。
    this.detachHttpParser();
    const captured = this.buffer;
    this.buffer = EMPTY;
    const index = captured.indexOf(CRLFCRLF);
    if (index === -1) {
      this.server.log('warn', 'the phone sent a WebSocket upgrade without a complete head');
      this.destroy();
      return;
    }
    const head = captured.subarray(0, index + CRLFCRLF.length);
    const rest = captured.subarray(index + CRLFCRLF.length);
    let rewritten;
    try {
      rewritten = rewriteHead(head, prefix);
    } catch (error) {
      this.server.log('warn', `the phone request could not be parsed: ${error.message}`);
      this.destroy();
      return;
    }
    this.#forward(rewritten.head);
    if (gate === null) {
      this.#forward(rest);
      return;
    }
    this.gate = gate;
    this.gateParser = new WsFrameParser({ requireMask: true, maxPayload: 1024 * 1024 });
    this.gateTimer = this.server.timers.setTimeout(() => {
      this.server.log('warn', `the phone of ${this.deviceId ?? 'an unknown device'} did not authenticate in time`);
      this.closeSocket();
    }, this.server.timers.phoneAuthTimeoutMs);
    if (rest.length > 0) this.#gateData(rest);
  }

  /**
   * The bytes of the phone that wait for the gate.
   *
   * The first frame of the phone has to be the authentication (`{"type":"auth","token":…}`) —
   * the same way the phone authenticates itself against the bridge. The frames are held back
   * until the token has been checked; a wrong one closes the connection.
   */
  #gateData(chunk) {
    if (this.closed || this.gate === null) return;
    this.gateBytes = Buffer.concat([this.gateBytes, chunk]);
    // A phone that does not authenticate itself must not be able to fill the memory of the
    // relay while it waits.
    if (this.gateBytes.length > MAX_CAPTURE_BYTES) {
      this.server.log('warn', 'the phone sent too much data before it authenticated itself');
      this.closeSocket();
      return;
    }
    let frames;
    try {
      frames = this.gateParser.push(chunk);
    } catch (error) {
      this.server.log('warn', `the phone sent a broken frame: ${error.message}`);
      this.closeSocket();
      return;
    }
    if (frames.length === 0) return;
    const frame = frames[0];
    if (frame.opcode !== OPCODE.TEXT) {
      this.server.log('warn', 'the first frame of the phone is not the authentication');
      this.closeSocket();
      return;
    }
    let parsed = null;
    try {
      parsed = JSON.parse(frame.payload.toString('utf8'));
    } catch {
      parsed = null;
    }
    const token = typeof parsed?.token === 'string' ? parsed.token : '';
    if (token.length === 0 || !this.gate.verify(token)) {
      this.server.log('warn', `the phone of ${this.deviceId ?? 'an unknown device'} presented a wrong token`);
      this.closeSocket();
      return;
    }
    // The gate is open: everything the phone sent so far goes to the device.
    this.#openGate();
    this.#forward(this.gateBytes);
    this.gateBytes = EMPTY;
  }

  /** The gate is open (or the connection is over): the phone may talk to the device. */
  #openGate() {
    if (this.gateTimer !== null) {
      this.server.timers.clearTimeout(this.gateTimer);
      this.gateTimer = null;
    }
    this.gate = null;
    this.gateParser = null;
  }

  /** Close the connection to the phone (the device stream dies with it). */
  closeSocket() {
    if (this.closed) return;
    this.#openGate();
    this.destroy();
  }

  #forward(bytes) {
    if (this.stream) {
      this.stream.writeToDevice(bytes);
      return;
    }
    // 没有流可用了还硬发, 手机的请求就凭空消失了, 而且手机等不到回答 —— 这种事必须喊出来,
    // 不然线上只能看到"手机说没连上", 却不知道是哪一环把字节吞了。
    this.server.log('warn', 'the phone sent bytes but the stream to the device is gone, the connection is closed');
    this.closeSocket();
  }

  /** Device → phone. */
  writeFromDevice(bytes) {
    if (this.closed || this.socket.destroyed) return;
    if (this.paused) {
      this.outQueue.push(bytes);
      this.outBytes += bytes.length;
      if (this.outBytes > MAX_OUT_QUEUE_BYTES) {
        this.server.log('warn', 'the phone is too slow, the stream is dropped');
        this.destroy();
      }
      return;
    }
    if (!this.socket.write(bytes)) {
      this.paused = true;
      this.socket.once('drain', () => this.#resume());
    }
  }

  #resume() {
    if (this.closed) return;
    this.paused = false;
    while (this.outQueue.length > 0 && !this.paused) {
      const chunk = this.outQueue.shift();
      this.outBytes -= chunk.length;
      if (!this.socket.write(chunk)) {
        this.paused = true;
        this.socket.once('drain', () => this.#resume());
      }
    }
  }

  /** The stream ended: the phone connection ends as well. */
  endSocket() {
    if (this.closed || this.socket.destroyed) return;
    this.socket.end();
  }

  /** Write an HTTP error into a raw socket (the phone asked for a WebSocket upgrade). */
  writeRawError(status, text, message) {
    if (this.closed || this.socket.destroyed) return;
    const body = JSON.stringify({ error: message });
    try {
      this.socket.write([
        `HTTP/1.1 ${status} ${text}`,
        'Content-Type: application/json',
        `Content-Length: ${Buffer.byteLength(body)}`,
        'Connection: close',
        '',
        body,
      ].join('\r\n'));
      this.socket.end();
    } catch {
      // The phone may have vanished already.
    }
  }

  destroy() {
    if (this.closed) return;
    this.closed = true;
    this.outQueue = [];
    this.outBytes = 0;
    if (this.gateTimer !== null) {
      this.server.timers.clearTimeout(this.gateTimer);
      this.gateTimer = null;
    }
    this.gate = null;
    if (this.stream) {
      this.stream.close('the phone disconnected');
      this.stream = null;
    }
    if (!this.socket.destroyed) this.socket.destroy();
  }
}

/**
 * The relay.
 *
 * ```js
 * const relay = new RelayServer({ devices });
 * await relay.listen({ port: 8788, host: '0.0.0.0' });
 * ```
 */
export class RelayServer extends EventEmitter {
  constructor({
    accounts,
    devices,
    registry,
    bridgePort = 8787,
    log = () => {},
    timers = createTimers(),
    allowJoin = true,
    registryFile = null,
    deviceRateLimit = DEFAULT_DEVICE_RATE_LIMIT,
    deviceRateWindowMs = DEFAULT_DEVICE_RATE_WINDOW_MS,
    desktopPackageFile = null,
    desktopPackageUrl = null,
    desktopPackageVersion = null,
    legalDir = null,
    publicUrl = null,
    registrationCode = null,
    registrationRateLimit = DEFAULT_REGISTRATION_RATE_LIMIT,
    registrationAccountRateLimit = DEFAULT_REGISTRATION_ACCOUNT_RATE_LIMIT,
    registrationRateWindowMs = DEFAULT_REGISTRATION_RATE_WINDOW_MS,
  } = {}) {
    super();
    this.registry = registry ?? buildRegistry({ accounts, devices, defaultPort: bridgePort });
    this.bridgePort = bridgePort;
    this.log = log;
    this.timers = timers;
    this.allowJoin = allowJoin;
    this.registryFile = registryFile;
    this.deviceRateLimit = deviceRateLimit;
    this.deviceRateWindowMs = deviceRateWindowMs;
    // The public address of this relay (the answer of the registration endpoint repeats it).
    this.publicUrl = publicUrl;
    // The invite code of the relay: when it is set, a registration has to present it.
    this.registrationCode = registrationCode;
    this.registrationRateLimit = registrationRateLimit;
    this.registrationAccountRateLimit = registrationAccountRateLimit;
    this.registrationRateWindowMs = registrationRateWindowMs;
    /** The registration attempts per client address (ip -> { count, first }). */
    this.registrationAttempts = new Map();
    /** The registration attempts per account (accountId -> { count, first }). */
    this.registrationAccountAttempts = new Map();
    // The desktop package: the file to serve and the public address it is served under.
    // Without the address the endpoint stays off and the phone uses the copy inside the app.
    this.desktopPackageFile = desktopPackageFile;
    this.desktopPackageUrl = desktopPackageUrl;
    this.desktopPackageVersion = desktopPackageVersion;
    /** The directory with the privacy policy / user agreement (null = the endpoint is off). */
    this.legalDir = legalDir;
    /** The digest of the served package (computed once, on the first request). */
    this.desktopPackageSha256Value = null;
    this.sessions = new Map(); // deviceId -> DeviceSession
    this.links = new Map(); // socket -> PhoneLink
    this.httpServer = null;
    this.tlsServer = null;
    this.stats = { requests: 0, upgrades: 0, streams: 0, bytesToDevice: 0, bytesToPhone: 0 };
    /** The failed device attempts per client address (ip -> { count, first }). */
    this.failedAttempts = new Map();
    this.#rebuildDeviceIndex();
  }

  /**
   * The address of the client that made the request.
   *
   * The socket address is used, not `X-Forwarded-For`: a header can be forged by anyone, and a
   * forged address would let an attacker walk around the rate limit.
   */
  #clientAddress(req) {
    return req.socket?.remoteAddress ?? 'unknown';
  }

  /** Is this client address over its budget of failed device attempts? */
  #isRateLimited(address) {
    if (this.deviceRateLimit <= 0) return false;
    const record = this.failedAttempts.get(address);
    if (!record) return false;
    if (Date.now() - record.first >= this.deviceRateWindowMs) {
      this.failedAttempts.delete(address);
      return false;
    }
    return record.count >= this.deviceRateLimit;
  }

  /** Remember a failed device attempt of this client address. */
  #noteFailedAttempt(address) {
    const now = Date.now();
    const record = this.failedAttempts.get(address);
    if (!record || now - record.first >= this.deviceRateWindowMs) {
      this.failedAttempts.set(address, { count: 1, first: now });
      return;
    }
    record.count += 1;
  }

  /** Forget the failed attempts of a client that authenticated successfully. */
  #clearFailedAttempts(address) {
    this.failedAttempts.delete(address);
  }

  /**
   * The flat device index (`deviceId -> device`) that the legacy code paths use.
   *
   * A device id may exist under several accounts; the index keeps the first one, the routing
   * uses {@link deviceOwners} to detect the ambiguous case.
   */  #rebuildDeviceIndex() {
    this.devices = new Map();
    for (const account of this.registry.accounts.values()) {
      for (const device of account.devices.values()) {
        if (!this.devices.has(device.id)) this.devices.set(device.id, device);
      }
    }
  }

  /** Write the registry back to disk (the join and the presence timestamps are persistent). */
  #persist() {
    if (!this.registryFile) return;
    try {
      saveAccountRegistry(this.registryFile, this.registry);
    } catch (error) {
      this.log('warn', `the account registry could not be written: ${error.message}`);
    }
  }

  /** Attach the relay to an HTTP server (plain or TLS). */
  attach(server, { secure = false } = {}) {
    server.on('connection', (socket) => {
      // For a TLS server the raw socket carries encrypted bytes, the decrypted bytes arrive on
      // the TLSSocket of the `secureConnection` event.
      if (!secure) this.#registerLink(socket);
    });
    if (secure) {
      server.on('secureConnection', (socket) => this.#registerLink(socket));
    }
    server.on('request', (req, res) => this.handleRequest(req, res));
    server.on('checkContinue', (req, res) => this.handleRequest(req, res));
    server.on('upgrade', (req, socket, head) => this.handleUpgrade(req, socket, head));
    server.on('clientError', (error, socket) => {
      this.log('warn', `a client sent a broken request: ${error?.message ?? error}`);
      if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
      socket.destroy();
    });
    // The relay implements its own timeouts, Node must not cut a hijacked connection.
    server.requestTimeout = 0;
    server.headersTimeout = 0;
    server.keepAliveTimeout = 0;
    server.timeout = 0;
    return server;
  }

  #registerLink(socket) {
    const link = new PhoneLink({ server: this, socket });
    this.links.set(socket, link);
    socket.once('close', () => this.links.delete(socket));
  }

  /* ------------------------------------------------------------------ device side */

  /**
   * A device dials in: `ws://host:8788/bridge?deviceId=<deviceId>`.
   *
   * The **token does not travel through the url**: a query string ends up in the access log of
   * every proxy on the way, and the relay is the one place that must not see the secrets in the
   * clear. The device therefore offers it with the `Sec-WebSocket-Protocol` header of the
   * handshake (`dsh-device.<token>` and `dsh-account.<accountToken>`), which no log writes down.
   * A device that still puts the token into the url is accepted as well (the old clients).
   *
   * With an account the handshake carries the account as well:
   *
   *   * `accountId` — the account has to exist and the device has to be one of its members;
   *   * `accountToken` — the account token *is* the account: a known device has to match its own
   *     device token, an unknown device joins the account (unless the relay runs with `--no-join`).
   */
  handleDeviceUpgrade(req, socket, head) {
    const url = new URL(req.url, 'http://relay.invalid');
    const deviceId = url.searchParams.get('deviceId') ?? '';
    const offered = offeredRelayProtocols(req);
    // The token belongs in the `Sec-WebSocket-Protocol` subprotocol (the current protocol).
    // The query parameters are the **compatibility path for old clients** — a token in a url
    // ends up in the access log of every proxy on the way, so it is not recommended.
    const token = offered.deviceToken || (url.searchParams.get('token') ?? '');
    const accountId = offered.accountId || (url.searchParams.get('accountId') ?? '');
    const accountToken = offered.accountToken || (url.searchParams.get('accountToken') ?? '');

    // Too many failed attempts from this address: stop answering with "wrong token".
    const address = this.#clientAddress(req);
    if (this.#isRateLimited(address)) {
      this.log('warn', `a device connection from ${address} was rate limited`);
      this.#rejectUpgrade(socket, 429, 'Too Many Requests', 'too many failed device attempts, try again later');
      return;
    }

    const outcome = this.#authorizeDevice({ deviceId, token, accountId, accountToken });
    if (!outcome.ok) {
      this.#noteFailedAttempt(address);
      this.log('warn', `a device connection with the token of "${deviceId}" was rejected: ${outcome.reason}`);
      this.#rejectUpgrade(socket, 401, 'Unauthorized', outcome.reason);
      return;
    }
    this.#clearFailedAttempts(address);

    const { device, account, joined } = outcome;
    if (joined) {
      this.log('info', `the device ${device.id} joined the account ${account.id}`);
      this.#rebuildDeviceIndex();
      this.#persist();
    }

    const previous = this.sessions.get(device.id);
    if (previous) {
      previous.close('the device connected again');
      previous.connection?.destroy?.();
    }

    // The connection becomes a device session: the phone side of this socket has to let go,
    // the raw capture would otherwise collect the device's own frames.
    const link = this.links.get(socket);
    if (link) {
      link.release();
      this.links.delete(socket);
    }

    const connection = acceptWebSocket(req, socket, head, { subprotocol: offered.raw });
    if (!connection) return;

    // The heartbeat proves that the device is alive: refresh its presence timestamp.
    connection.on('binary', (payload) => {
      if (payload.length >= 5 && payload.readUInt8(4) === FRAME.PONG) {
        touchDevice(this.registry, account.id, device.id, Date.now());
      }
    });

    const session = new DeviceSession({ device, connection, timers: this.timers, log: this.log });
    this.sessions.set(device.id, session);
    touchDevice(this.registry, account.id, device.id, Date.now());
    session.on('close', () => {
      if (this.sessions.get(device.id) === session) this.sessions.delete(device.id);
      this.log('info', `the device ${device.id} went offline`);
    });
    session.on('hello', (hello) => {
      // The device introduces itself: keep its friendly name in the registry.
      // 已经登记过的设备以登记表里的名字为准 —— 客户端不能随便改自己的名字;
      // 只有还没有名字的设备(刚加入账号的)才用 HELLO 里的名字补上。
      if (typeof hello?.name === 'string' && hello.name.length > 0
        && (device.name === undefined || device.name.length === 0)) {
        device.name = hello.name;
        this.#persist();
      }
      touchDevice(this.registry, account.id, device.id, Date.now());
      this.log('info', `the device ${device.id} said hello${hello?.name ? ` (${hello.name})` : ''}`);
    });
    session.start();
    this.log('info', `the device ${device.id} is online (account ${account.id})`);
    this.emit('device-online', session);
  }

  /**
   * Check a device handshake against the account registry.
   *
   * The rules (docs/ACCOUNT.md §4):
   *
   *   1. `accountToken` — the account token identifies the account. A known device has to match
   *      its own device token, an unknown device *joins* the account (unless `--no-join`).
   *   2. `accountId` — the account has to exist and the device has to be one of its members.
   *   3. neither — the legacy flat registry: the device id has to exist and to be unique, the
   *      device token has to match.
   *
   * @returns {{ok: true, device: object, account: object, joined: boolean}|{ok: false, reason: string}}
   */
  #authorizeDevice({ deviceId, token, accountId, accountToken }) {
    if (deviceId.length === 0) return { ok: false, reason: 'the device id is missing' };

    // 1) the account token identifies the account
    if (accountToken.length > 0) {
      const account = findAccountByToken(this.registry, accountToken);
      if (!account) return { ok: false, reason: 'the account token is wrong' };
      const device = account.devices.get(deviceId) ?? null;
      if (device) {
        if (!constantTimeEquals(token, device.token)) {
          return { ok: false, reason: 'the device token is wrong' };
        }
        return { ok: true, device, account, joined: false };
      }
      if (!this.allowJoin) {
        return { ok: false, reason: `the device "${deviceId}" is not registered in the account ${account.id}` };
      }
      const created = addDevice(this.registry, account.id, {
        id: deviceId,
        name: deviceId,
        token,
        role: ROLE_DESKTOP,
      });
      return { ok: true, device: created, account, joined: true };
    }

    // 2) the account is named, the device has to be a member of it
    if (accountId.length > 0) {
      const account = findAccount(this.registry, accountId);
      if (!account) return { ok: false, reason: `the account "${accountId}" is not registered` };
      const device = findDevice(this.registry, account.id, deviceId);
      if (!device) {
        return { ok: false, reason: `the device "${deviceId}" does not belong to the account "${account.id}"` };
      }
      if (!constantTimeEquals(token, device.token)) {
        return { ok: false, reason: 'the device token is wrong' };
      }
      return { ok: true, device, account, joined: false };
    }

    // 3) the legacy flat registry
    const owners = deviceOwners(this.registry, deviceId);
    if (owners.length === 0) return { ok: false, reason: `the device "${deviceId}" is not registered` };
    if (owners.length > 1) {
      return { ok: false, reason: `the device "${deviceId}" exists in several accounts` };
    }
    const device = owners[0].devices.get(deviceId);
    if (!constantTimeEquals(token, device.token)) {
      return { ok: false, reason: 'the device token is wrong' };
    }
    return { ok: true, device, account: owners[0], joined: false };
  }

  #rejectUpgrade(socket, status, text, message) {
    const body = JSON.stringify({ error: message });
    socket.write([
      `HTTP/1.1 ${status} ${text}`,
      'Content-Type: application/json',
      `Content-Length: ${Buffer.byteLength(body)}`,
      'Connection: close',
      '',
      body,
    ].join('\r\n'));
    socket.destroy();
  }

  /**
   * Answer a WebSocket upgrade with a plain text error.
   *
   * The phone's WebSocket client only reads the status line of a refused handshake, so the body
   * is a short sentence instead of a json envelope.
   */
  #rejectUpgradeText(socket, status, text, message) {
    const body = `${message}\n`;
    try {
      socket.write([
        `HTTP/1.1 ${status} ${text}`,
        'Content-Type: text/plain; charset=utf-8',
        `Content-Length: ${Buffer.byteLength(body)}`,
        'Connection: close',
        '',
        body,
      ].join('\r\n'));
    } catch {
      // The phone may have vanished already.
    }
    socket.destroy();
  }

  /* ------------------------------------------------------------------- phone side */

  /** A normal HTTP request of the phone. */
  handleRequest(req, res) {
    const link = this.links.get(req.socket);
    if (!link) {
      this.#sendError(res, 400, 'bad_request', 'the connection is not known');
      return;
    }
    // 中继自己的端点必须由中继来回答, 哪怕这条连接已经被路由到设备上了。
    // (手机端会在同一条连接上既问设备又问中继: 登记自己、查在线状态。)
    let pathname = '';
    try {
      pathname = new URL(req.url ?? '/', 'http://relay.invalid').pathname;
    } catch {
      pathname = '';
    }
    if (isRelayOwnTarget(pathname)) {
      setImmediate(() => {
        // 这些字节不能转发给设备: 设备会用自己的令牌检查去回答它们, 多出来的回答会被手机端
        // 当成下一个请求的响应。连接还没路由时它们还在缓冲区里, 直接丢掉; 已经路由时由重写器丢弃。
        if (!link.routed) {
          link.discardRequest();
        }
        this.#sendRelayInfo(req, res, pathname).catch((error) => {
          this.log('warn', `the relay request could not be answered: ${error?.message ?? error}`);
          if (!res.headersSent) {
            this.#sendError(res, 500, 'internal_error', 'the relay could not answer the request');
          }
        });
      });
      return;
    }
    if (link.routed) {
      // The connection is already a raw pipe: the bytes of a second request are forwarded to
      // the device as they are, there is nothing to do here.
      return;
    }
    // Node emits the request event from inside its parser, the raw capture of the socket lags
    // behind by one chunk. Wait for the next tick so that the capture is complete.
    setImmediate(() => this.#routeRequest(link, req, res));
  }

  #routeRequest(link, req, res) {
    if (link.routed || link.closed) return;
    const url = new URL(req.url, 'http://relay.invalid');
    if (isRelayOwnTarget(url.pathname)) {
      // 中继自己的端点(正常情况下已经在 handleRequest 里处理了)。
      if (!link.routed) {
        link.discardRequest();
      }
      this.#sendRelayInfo(req, res, url.pathname).catch((error) => {
        this.log('warn', `the relay request could not be answered: ${error?.message ?? error}`);
        if (!res.headersSent) {
          this.#sendError(res, 500, 'internal_error', 'the relay could not answer the request');
        }
      });
      return;
    }
    const resolved = this.#resolvePhoneTarget(req.url);
    if (resolved.error) {
      this.#sendError(res, resolved.error.status, resolved.error.code, resolved.error.message);
      return;
    }
    const { device, prefix } = resolved;
    const session = this.sessions.get(device.id);
    if (!session) {
      this.#sendError(res, 503, 'device_offline', `the device "${device.id}" is offline`);
      return;
    }

    this.stats.requests += 1;
    this.#openStream(link, session, device, res);
    link.route({ deviceId: device.id, prefix, singleRequest: false });
  }

  /**
   * Resolve the device a phone request is addressed to.
   *
   * Two url shapes are understood:
   *
   *   * `/<accountId>/<deviceId>/…` — the **account scoped** shape. The device has to belong to
   *     the account, otherwise the relay answers 404. This is the shape the phone app uses.
   *   * `/<deviceId>/…` — the **legacy** shape. The device id has to be unique across all
   *     accounts; an ambiguous id is refused instead of guessed.
   *
   * @param {string} rawUrl the request target as the phone sent it
   * @returns {{device: object, account: object, prefix: string}|{error: {status: number, code: string, message: string}}}
   */
  #resolvePhoneTarget(rawUrl) {
    const url = new URL(rawUrl, 'http://relay.invalid');
    const segments = url.pathname.split('/').filter((segment) => segment.length > 0);
    if (segments.length === 0) {
      return { error: { status: 404, code: 'unknown_device', message: 'the url does not name a device' } };
    }

    let first;
    try {
      first = decodeURIComponent(segments[0]);
    } catch {
      first = segments[0];
    }

    // The account scoped shape.
    const account = this.registry.accounts.get(first);
    if (account) {
      if (segments.length < 2) {
        return { error: { status: 404, code: 'unknown_device', message: `the account "${first}" does not name a device` } };
      }
      let deviceId;
      try {
        deviceId = decodeURIComponent(segments[1]);
      } catch {
        deviceId = segments[1];
      }
      const device = account.devices.get(deviceId) ?? null;
      if (!device) {
        return {
          error: {
            status: 404,
            code: 'unknown_device',
            message: `the device "${deviceId}" does not belong to the account "${first}"`,
          },
        };
      }
      return { device, account, prefix: `/${segments[0]}/${segments[1]}` };
    }

    // The legacy shape.
    const deviceId = first;
    const owners = deviceOwners(this.registry, deviceId);
    if (owners.length === 0) {
      if (deviceId.startsWith(ACCOUNT_ID_PREFIX)) {
        return { error: { status: 404, code: 'unknown_account', message: `the account "${deviceId}" is not registered` } };
      }
      return { error: { status: 404, code: 'unknown_device', message: `the device "${deviceId}" is not registered` } };
    }
    if (owners.length > 1) {
      return {
        error: {
          status: 409,
          code: 'ambiguous_device',
          message: `the device "${deviceId}" exists in several accounts — use /<accountId>/${deviceId}/…`,
        },
      };
    }
    return { device: owners[0].devices.get(deviceId), account: owners[0], prefix: `/${segments[0]}` };
  }

  /** A WebSocket upgrade: either a device that dials in or the phone that talks to a device. */
  handleUpgrade(req, socket, head) {
    const url = new URL(req.url, 'http://relay.invalid');
    if (url.pathname === DEVICE_PATH) {
      this.handleDeviceUpgrade(req, socket, head);
      return;
    }
    // The phone connects with a plain WebSocket handshake. The route below used to demand that
    // the socket already was a known HTTP link — a standard WebSocket client never is, so the
    // phone could not connect at all. This is the way out of that dead end.
    if (isPhoneWsPath(url.pathname)) {
      this.handlePhoneDirectUpgrade(req, socket, head);
      return;
    }
    const link = this.links.get(socket);
    if (!link) {
      this.#rejectUpgrade(socket, 400, 'Bad Request', 'the connection is not known');
      return;
    }
    if (link.routed) return;
    // Node stops the data flow of a socket when it hands it over for an upgrade
    // (`socket.readableFlowing = null`). The relay owns the socket now, so the flow has to
    // start again - otherwise the WebSocket frames of the phone would never arrive.
    socket.resume();
    // Without a token in the handshake the phone has to authenticate with its first frame; the
    // relay holds its frames back until the token has been checked.
    const gate = credential.present
      ? null
      : { verify: (token) => this.#verifyPhoneToken(token, session, device, account) };
    this.#openStream(link, session, device, null);
    link.routeWebSocket({ deviceId: device.id, prefix, gate });
  }

  #routeUpgrade(link, req, socket) {
    if (link.routed || link.closed) return;
    const resolved = this.#resolvePhoneTarget(req.url);
    if (resolved.error) {
      this.#rejectUpgrade(socket, resolved.error.status, resolved.error.status === 409 ? 'Conflict' : 'Not Found', resolved.error.message);
      return;
    }
    const { device, prefix } = resolved;
    const session = this.sessions.get(device.id);
    if (!session) {
      this.#rejectUpgrade(socket, 503, 'Service Unavailable', `the device "${device.id}" is offline`);
      return;
    }

    this.stats.upgrades += 1;
    // The upgrade request is written into a fresh stream *verbatim* (only the device prefix is
    // removed from the request target). The device answers with its own `101`, the relay only
    // moves the bytes.
    this.#openStream(link, session, device, null);
    link.route({ deviceId: device.id, prefix, singleRequest: true });
  }

  /** Open the stream that mirrors the phone connection on the device. */
  #openStream(link, session, device, res) {
    const port = session.devicePort ?? device.port ?? this.bridgePort;
    const target = `127.0.0.1:${port}`;
    const stream = session.openStream(target);
    this.stats.streams += 1;
    link.stream = stream;

    stream.on('data', (bytes) => {
      this.stats.bytesToPhone += bytes.length;
      link.writeFromDevice(bytes);
    });
    stream.on('open', () => {
      this.log('info', `the stream ${stream.id} of ${device.id} is open (${target})`);
    });
    stream.on('open-error', (message) => {
      this.log('warn', `the device ${device.id} could not open ${target}: ${message}`);
      if (res && !res.headersSent) {
        this.#sendError(res, 502, 'bad_gateway', message);
      } else {
        // The phone asked for a WebSocket upgrade: the answer goes into the raw socket.
        link.writeRawError(502, 'Bad Gateway', message);
      }
      link.stream = null;
    });
    stream.on('closed', () => {
      link.stream = null;
      link.endSocket();
    });

    const openTimer = this.timers.setTimeout(() => {
      if (stream.state === 'opening') {
        this.log('warn', `the device ${device.id} did not open ${target} in time`);
        if (res && !res.headersSent) {
          this.#sendError(res, 504, 'gateway_timeout', 'the device did not open the connection');
        } else {
          link.writeRawError(504, 'Gateway Timeout', 'the device did not open the connection');
        }
        stream.close('open timeout');
      }
    }, this.timers.openTimeoutMs);
    stream.on('open', () => this.timers.clearTimeout(openTimer));
    stream.on('closed', () => this.timers.clearTimeout(openTimer));
  }

  #sendError(res, status, code, message) {
    const body = JSON.stringify({ error: code, message });
    try {
      res.writeHead(status, {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(body),
      });
      res.end(body);
    } catch {
      // The phone may have vanished already.
    }
  }

  /**
   * The account token the caller presented, either as `?accountToken=…` or as
   * `Authorization: Bearer …`.
   */
  #presentedAccountToken(req) {
    const url = new URL(req.url, 'http://relay.invalid');
    const fromQuery = url.searchParams.get('accountToken') ?? '';
    if (fromQuery.length > 0) return fromQuery;
    const header = req.headers?.authorization ?? '';
    const match = /^Bearer\s+(.+)$/iu.exec(header.trim());
    return match ? match[1].trim() : '';
  }

  /** The presence of every device of an account. */
  #deviceStates(account) {
    return listDevices(this.registry, account.id).map((device) => this.#deviceState(device));
  }

  /**
   * The state of one device: the same shape the presence endpoints answer with.
   *
   * @param {object} device the device of the registry
   * @returns {{id: string, name: string, role: string, online: boolean, lastSeen: number, port?: number}}
   */
  #deviceState(device) {
    // The effective port: the device announces it in its HELLO, the registry is the fallback.
    const session = this.sessions.get(device.id);
    const port = session?.devicePort ?? device.port ?? null;
    return {
      id: device.id,
      name: device.name,
      role: device.role,
      online: this.#isDeviceOnline(device),
      lastSeen: device.lastSeen ?? 0,
      ...(port ? { port } : {}),
    };
  }

  /**
   * Is the device online?
   *
   * A desktop is online while its device WebSocket is connected. A phone has no WebSocket to
   * the relay, it only heartbeats: it is online while its `lastSeen` is younger than
   * {@link PHONE_ONLINE_WINDOW_MS}.
   */
  #isDeviceOnline(device) {
    if (device.role === ROLE_PHONE) {
      const lastSeen = device.lastSeen ?? 0;
      return lastSeen > 0 && Date.now() - lastSeen <= PHONE_ONLINE_WINDOW_MS;
    }
    return this.sessions.has(device.id);
  }

  /**
   * The SHA-256 of the served package (the phone checks it after the download).
   *
   * It is computed once and kept: the file does not change while the relay runs.
   *
   * @returns {Promise<string>} the digest in lower case hex
   */
  async #desktopPackageSha256() {
    if (this.desktopPackageSha256Value !== null) {
      return this.desktopPackageSha256Value;
    }
    const hash = crypto.createHash('sha256');
    await new Promise((resolve, reject) => {
      const stream = fs.createReadStream(this.desktopPackageFile);
      stream.on('error', reject);
      stream.on('data', (chunk) => hash.update(chunk));
      stream.on('end', () => resolve());
    });
    this.desktopPackageSha256Value = hash.digest('hex');
    return this.desktopPackageSha256Value;
  }

  /**
   * Serve the desktop package: the file the phone hands to the computer ("send the desktop to
   * the computer").
   *
   * It is a public file (the desktop bridge itself, no secret in it), so no token is needed.
   * The operator switches it off by leaving `desktopPackageUrl` unset — then the phone falls
   * back to the copy that is built into the app.
   */
  async #sendDesktopPackage(req, res) {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      this.#sendError(res, 405, 'method_not_allowed', 'this endpoint needs a GET');
      return;
    }
    if (!this.desktopPackageUrl || !this.desktopPackageFile) {
      this.#sendError(res, 404, 'not_found', 'this relay does not serve the desktop package');
      return;
    }
    let stat;
    try {
      stat = fs.statSync(this.desktopPackageFile);
    } catch {
      this.#sendError(res, 404, 'not_found', 'the desktop package is not on this relay');
      return;
    }
    const version = String(this.desktopPackageVersion ?? stat.mtimeMs);
    let sha256 = '';
    try {
      sha256 = await this.#desktopPackageSha256();
    } catch {
      // 算不出来就少给一个头(手机上就只校验字节数 ✓)
      sha256 = '';
    }
    try {
      res.writeHead(200, {
        'content-type': 'application/zip',
        'content-length': stat.size,
        'content-disposition': 'attachment; filename="dsh-harmony-desktop.zip"',
        'cache-control': 'public, max-age=3600',
        'x-dsh-package-version': version,
        'x-dsh-package-sha256': sha256,
      });
      if (req.method === 'HEAD') {
        res.end();
        return;
      }
      const stream = fs.createReadStream(this.desktopPackageFile);
      stream.on('error', () => res.destroy());
      stream.pipe(res);
    } catch (error) {
      if (!res.headersSent) {
        this.#sendError(res, 500, 'internal_error', 'the desktop package could not be served');
      } else {
        res.destroy();
      }
    }
  }

  /**
   * The privacy policy and the user agreement.
   *
   * They are static html files in `legalDir`:
   *   /legal/                    -> index.html
   *   /legal/<name>.html         -> that file
   *
   * Only plain file names are allowed (no `..`, no directories) ⇒ the path can never leave
   * the directory ✓
   */
  #sendLegalPage(req, res, pathname) {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      this.#sendError(res, 405, 'method_not_allowed', 'this endpoint needs a GET');
      return;
    }
    if (!this.legalDir) {
      this.#sendError(res, 404, 'not_found', 'this relay does not serve the legal pages');
      return;
    }
    let name = 'index.html';
    const tail = pathname.slice(LEGAL_PATH_PREFIX.length).replace(/^\/+/u, '');
    if (tail.length > 0) {
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]*\.html$/.test(tail)) {
        this.#sendError(res, 404, 'not_found', 'there is no such legal page');
        return;
      }
      name = tail;
    }
    const file = path.join(this.legalDir, name);
    let stat;
    try {
      stat = fs.statSync(file);
    } catch {
      this.#sendError(res, 404, 'not_found', 'there is no such legal page');
      return;
    }
    if (!stat.isFile()) {
      this.#sendError(res, 404, 'not_found', 'there is no such legal page');
      return;
    }
    try {
      res.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'content-length': stat.size,
        'cache-control': 'public, max-age=3600',
      });
      if (req.method === 'HEAD') {
        res.end();
        return;
      }
      const stream = fs.createReadStream(file);
      stream.on('error', () => res.destroy());
      stream.pipe(res);
    } catch {
      if (!res.headersSent) {
        this.#sendError(res, 500, 'internal_error', 'the legal page could not be served');
      } else {
        res.destroy();
      }
    }
  }

  /**
   * The relay owned endpoints.
   *
   *   * `GET /_relay/health` — the liveness probe. The device list is empty unless the caller
   *     presents an account token: the presence of a device belongs to its account.
   *   * `GET /_relay/devices` — the devices of the account of the presented account token.
   *   * `GET /_relay/accounts/<accountId>/devices` — the devices of that account. The account
   *     token is required.
   *   * `POST /_relay/accounts/<accountId>/phones` — the phone registers itself as a device of
   *     the account.
   *   * `POST /_relay/accounts/<accountId>/phones/<deviceId>/heartbeat` — the phone refreshes
   *     its presence.
   *   * `DELETE /_relay/accounts/<accountId>/devices/<deviceId>` — the device is revoked: its
   *     token stops working at once.
   *   * `POST /_relay/accounts/register` — the desktop bridge registers itself and gets its
   *     credentials (see {@link #registerAccount}).
   */
  async #sendRelayInfo(req, res, pathname) {
    const token = this.#presentedAccountToken(req);
    const account = token.length > 0 ? findAccountByToken(this.registry, token) : null;

    if (pathname === DESKTOP_PACKAGE_PATH) {
      this.#sendDesktopPackage(req, res).catch((error) => {
        this.log('warn', `the desktop package could not be answered: ${error?.message ?? error}`);
        if (!res.headersSent) {
          this.#sendError(res, 500, 'internal_error', 'the desktop package could not be served');
        }
      });
      return;
    }

    // The privacy policy / the user agreement.
    if (pathname === LEGAL_PATH_PREFIX || pathname.startsWith(`${LEGAL_PATH_PREFIX}/`)) {
      this.#sendLegalPage(req, res, pathname);
      return;
    }

    if (pathname === '/_relay/health') {
      this.#sendJson(res, 200, {
        status: 'ok',
        relay: 'dsh-harmony-relay',
        version: '1.0.0',
        uptime: Math.round(process.uptime()),
        accounts: this.registry.accounts.size,
        // Scoped: without an account token the caller learns nothing about the devices.
        devices: account ? this.#deviceStates(account) : [],
      });
      return;
    }

    if (pathname === '/_relay/devices') {
      if (!account) {
        this.#sendError(res, 401, 'unauthorized', 'the account token is required');
        return;
      }
      this.#sendJson(res, 200, {
        relay: 'dsh-harmony-relay',
        version: '1.0.0',
        account: { id: account.id, name: account.name },
        devices: this.#deviceStates(account),
      });
      return;
    }

    // The registration of a desktop bridge (docs/PROTOCOL.md, chapter 8). It has to be answered
    // before the account branch below: "register" is not an account id.
    if (pathname === REGISTER_PATH) {
      await this.#registerAccount(req, res);
      return;
    }
    if (pathname.startsWith(`${REGISTER_PATH}/`)) {
      this.#sendRegisterError(res, 404, 'unknown_route', 'there is no such relay endpoint');
      return;
    }

    // /_relay/accounts/<accountId>/…
    const parts = pathname.split('/').filter((part) => part.length > 0);
    const accountId = this.#decodeSegment(parts[2] ?? '');
    const wanted = findAccount(this.registry, accountId);
    if (!wanted) {
      this.#sendError(res, 404, 'unknown_account', `the account "${accountId}" is not registered`);
      return;
    }
    if (!account || account.id !== wanted.id) {
      this.#sendError(res, 401, 'unauthorized', 'the account token is required');
      return;
    }

    // The phone endpoints of the account.
    const rest = parts.slice(3);
    if (rest[0] === 'phones') {
      await this.#sendPhoneInfo(req, res, wanted, rest);
      return;
    }

    // The revocation of a device: DELETE /_relay/accounts/<accountId>/devices/<deviceId>
    if (rest[0] === 'devices' && rest.length >= 2) {
      this.#revokeDevice(req, res, wanted, this.#decodeSegment(rest[1]));
      return;
    }

    // /_relay/accounts/<accountId>/devices
    this.#sendJson(res, 200, {
      relay: 'dsh-harmony-relay',
      version: '1.0.0',
      account: { id: wanted.id, name: wanted.name },
      devices: this.#deviceStates(wanted),
    });
  }

  /**
   * Revoke a device of an account.
   *
   * The device token stops working at once: the device is removed from the registry, its live
   * session is closed and the registry is written back to disk. A device that was revoked
   * cannot come back with the same token.
   */
  #revokeDevice(req, res, account, deviceId) {
    if (req.method !== 'DELETE') {
      this.#sendError(res, 405, 'method_not_allowed', 'this endpoint needs a DELETE');
      return;
    }
    const device = account.devices.get(deviceId);
    if (!device) {
      this.#sendError(res, 404, 'unknown_device', `the device "${deviceId}" is not registered`);
      return;
    }
    account.devices.delete(deviceId);
    this.#rebuildDeviceIndex();
    this.#persist();
    const session = this.sessions.get(deviceId);
    if (session) {
      this.sessions.delete(deviceId);
      session.close('the device token was revoked');
      // The socket has to go as well: a revoked device must not keep its session.
      session.connection?.close(1008, 'revoked');
      session.connection?.destroy?.();
    }
    this.log('info', `the device ${deviceId} was revoked`);
    this.#sendJson(res, 200, {
      relay: 'dsh-harmony-relay',
      version: '1.0.0',
      revoked: deviceId,
    });
  }

  /**
   * The registration endpoint: a desktop bridge asks the relay for its credentials.
   *
   * The relay is the trust boundary (docs/PROTOCOL.md, chapter 8): it issues the account token
   * and the device token, the bridge only proves that it is the same machine as the last time.
   * The rules:
   *
   *   * a registration for a **new** account creates that account — the first registration of a
   *     machine is anonymous, the user has no credential yet;
   *   * a registration for a **known** account with a **new** device id needs an invitation: the
   *     token of that account or the invite code of the relay, otherwise the relay answers 503;
   *   * a registration for a **known** device id with the **same** secret gets the **same**
   *     credentials back (the machine is the same one); with another secret it is a conflict and
   *     the client generates a new device id;
   *   * the secret of the machine is stored as a hash, never in the clear;
   *   * every attempt is counted per address and per account — too many attempts are 429.
   *
   * @param {object} req the request of the bridge
   * @param {object} res the answer
   */
  async #registerAccount(req, res) {
    if (req.method !== 'POST') {
      this.#sendRegisterError(res, 404, 'unknown_route', 'the registration endpoint needs a POST');
      return;
    }

    // The budget of this address is checked before the body is read: a flood of registrations
    // must not cost the relay anything.
    const address = this.#registrationAddress(req);
    if (this.#countRegistrationAttempt(this.registrationAttempts, address, this.registrationRateLimit)) {
      this.#sendRegisterError(res, 429, 'rate_limited', 'too many registrations from this address');
      return;
    }

    // The operator closed the door: nobody registers itself any more.
    if (!this.allowJoin) {
      this.#sendRegisterError(res, 503, 'registration_closed', 'this relay does not accept new registrations');
      return;
    }

    const body = await this.#readJsonBody(req);
    if (body.error) {
      this.#sendRegisterError(res, 400, 'bad_request', body.error);
      return;
    }
    const payload = (body.value && typeof body.value === 'object' && !Array.isArray(body.value)) ? body.value : {};
    const name = typeof payload.deviceName === 'string' ? payload.deviceName.trim() : '';
    const deviceId = typeof payload.deviceId === 'string' ? payload.deviceId.trim() : '';
    const accountId = typeof payload.accountId === 'string' ? payload.accountId.trim() : '';
    const secret = typeof payload.secret === 'string' ? payload.secret.trim() : '';
    const platform = typeof payload.platform === 'string' ? payload.platform.trim() : '';
    const version = typeof payload.version === 'string' ? payload.version.trim() : '';

    if (name.length === 0) {
      this.#sendRegisterError(res, 400, 'bad_request', 'the device name is missing');
      return;
    }
    if (name.length > MAX_DEVICE_NAME_LENGTH) {
      this.#sendRegisterError(res, 400, 'bad_request', `the device name must be at most ${MAX_DEVICE_NAME_LENGTH} characters`);
      return;
    }
    if (!REGISTER_DEVICE_ID_PATTERN.test(deviceId)) {
      this.#sendRegisterError(res, 400, 'bad_request', 'the device id must match /^[A-Za-z0-9._-]{1,64}$/');
      return;
    }
    if (!REGISTER_ACCOUNT_ID_PATTERN.test(accountId)) {
      this.#sendRegisterError(res, 400, 'bad_request', 'the account id must match /^[A-Za-z0-9._-]{1,64}$/');
      return;
    }
    if (!REGISTER_SECRET_PATTERN.test(secret)) {
      this.#sendRegisterError(res, 400, 'bad_request', 'the secret must be 32 to 128 hex characters');
      return;
    }
    if (platform.length === 0 || platform.length > 32) {
      this.#sendRegisterError(res, 400, 'bad_request', 'the platform is missing or too long');
      return;
    }
    if (version.length === 0 || version.length > 32) {
      this.#sendRegisterError(res, 400, 'bad_request', 'the version is missing or too long');
      return;
    }

    // The budget of this account is checked once the account id is known.
    if (this.#countRegistrationAttempt(this.registrationAccountAttempts, accountId, this.registrationAccountRateLimit)) {
      this.#sendRegisterError(res, 429, 'rate_limited', 'too many registrations for this account');
      return;
    }

    const secretHash = hashSecret(secret);
    const owners = deviceOwners(this.registry, deviceId);
    if (owners.length > 1) {
      this.#sendRegisterError(res, 409, 'device_conflict', `the device "${deviceId}" belongs to more than one account`);
      return;
    }
    if (owners.length === 1) {
      // The device id is known: the secret of the machine decides whether it is the same one.
      const account = owners[0];
      const device = account.devices.get(deviceId);
      if (!device.secretHash || !constantTimeEquals(device.secretHash, secretHash)) {
        this.#sendRegisterError(res, 409, 'device_conflict', `the device "${deviceId}" is known with another secret`);
        return;
      }
      // The same machine: it gets the same credentials back.
      this.log('info', `the device ${deviceId} registered again at the account ${account.id}`);
      this.#sendJson(res, 201, this.#registrationAnswer(account, device));
      return;
    }

    let account = findAccount(this.registry, accountId);
    if (account) {
      // A new device of an account that exists: that needs an invitation. The owner of the
      // account hands out its token, the operator of the relay hands out its invite code.
      if (!this.#hasInvitation(req, payload, account)) {
        this.#sendRegisterError(res, 503, 'registration_closed', `the account "${accountId}" needs an invitation`);
        return;
      }
    } else {
      // A new account: the relay only asks for the invite code when the operator set one.
      if (this.registrationCode && !this.#presentedRegistrationCode(req, payload)) {
        this.#sendRegisterError(res, 503, 'registration_closed', 'this relay needs an invite code');
        return;
      }
      account = createAccount(this.registry, {
        id: accountId,
        name: name,
        token: generateAccountToken(),
        createdAt: Date.now(),
      });
    }

    const device = addDevice(this.registry, account.id, {
      id: deviceId,
      name,
      token: generateDeviceToken(),
      role: ROLE_DESKTOP,
      port: this.bridgePort,
      secretHash,
      registeredAt: Date.now(),
    });
    this.#rebuildDeviceIndex();
    this.#persist();
    this.log('info', `the device ${deviceId} registered itself at the account ${account.id}`);
    this.emit('registered', { account, device, publicUrl: this.publicUrl });
    this.#sendJson(res, 201, this.#registrationAnswer(account, device));
  }

  /** The answer of the registration endpoint. */
  #registrationAnswer(account, device) {
    return {
      accountId: account.id,
      accountToken: account.token,
      deviceId: device.id,
      deviceToken: device.token,
      // The address the phone has to use. The bridge falls back to its own --relay-public-url.
      publicUrl: this.publicUrl ?? null,
      registeredAt: device.registeredAt || Date.now(),
    };
  }

  /**
   * Is the caller invited to add a device to that account?
   *
   * Two ways to be invited: the token of the account itself (the owner hands it out) or the
   * invite code of the relay (the operator hands it out).
   */
  #hasInvitation(req, payload, account) {
    const token = this.#presentedAccountToken(req);
    if (token.length > 0 && constantTimeEquals(token, account.token)) return true;
    if (this.registrationCode) {
      const code = this.#presentedRegistrationCode(req, payload);
      if (code.length > 0 && constantTimeEquals(code, this.registrationCode)) return true;
    }
    return false;
  }

  /**
   * The invite code the caller presented.
   *
   * It is read from the body (`registrationCode`) or from the header `X-Registration-Code`, so
   * a client that cannot change the body can still use it.
   */
  #presentedRegistrationCode(req, payload) {
    const header = req.headers?.['x-registration-code'];
    if (typeof header === 'string' && header.trim().length > 0) return header.trim();
    const fromBody = payload?.registrationCode;
    if (typeof fromBody === 'string' && fromBody.trim().length > 0) return fromBody.trim();
    return '';
  }

  /**
   * The address of the client of a registration.
   *
   * The socket address is the truth, but behind a reverse proxy it is the address of the proxy
   * itself — then every client of the relay would share one budget. `X-Real-IP` (and the last
   * entry of `X-Forwarded-For`) is only trusted when the socket address is the loopback
   * interface: then the proxy runs on this machine and it wrote the header itself.
   */
  #registrationAddress(req) {
    const peer = req.socket?.remoteAddress ?? 'unknown';
    const loopback = peer === '127.0.0.1' || peer === '::1' || peer === '::ffff:127.0.0.1';
    if (loopback) {
      const real = req.headers?.['x-real-ip'];
      if (typeof real === 'string' && real.trim().length > 0) return real.trim();
      const forwarded = req.headers?.['x-forwarded-for'];
      const last = String(forwarded ?? '')
        .split(',')
        .map((part) => part.trim())
        .filter((part) => part.length > 0)
        .pop();
      if (last) return last;
    }
    return peer;
  }

  /**
   * Count one registration attempt and tell whether the caller is over its budget.
   *
   * Unlike the device limiter (which counts the *failed* attempts only) every attempt counts
   * here: a registration that succeeds creates an account, so a stream of them is exactly what
   * has to be stopped.
   *
   * @returns {boolean} true when the caller is over its budget
   */
  #countRegistrationAttempt(store, key, limit) {
    if (limit <= 0) return false;
    const now = Date.now();
    const record = store.get(key);
    if (!record || now - record.first >= this.registrationRateWindowMs) {
      store.set(key, { count: 1, first: now });
      return false;
    }
    record.count += 1;
    return record.count > limit;
  }

  /**
   * The error of the registration endpoint.
   *
   * The body is nested (`{ "error": { "code", "message" } }`) — the client of
   * docs/PROTOCOL.md, chapter 8, reads the code out of it. The older endpoints of the relay
   * still answer with the flat shape.
   */
  #sendRegisterError(res, status, code, message) {
    const body = JSON.stringify({ error: { code, message } });
    try {
      res.writeHead(status, {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(body),
      });
      res.end(body);
    } catch {
      // The client may have vanished already.
    }
  }

  /**
   * The phone endpoints of one account.
   *
   *   * `POST /_relay/accounts/<accountId>/phones` — the phone registers itself.
   *   * `POST /_relay/accounts/<accountId>/phones/<deviceId>/heartbeat` — the phone says that
   *     it is still alive.
   *
   * @param {object} account the account of the path (the caller is already authenticated)
   * @param {string[]} rest the path segments behind `<accountId>`
   */
  async #sendPhoneInfo(req, res, account, rest) {
    if (req.method !== 'POST') {
      this.#sendError(res, 405, 'method_not_allowed', 'this endpoint needs a POST');
      return;
    }
    if (rest.length === 1) {
      await this.#registerPhone(req, res, account);
      return;
    }
    if (rest.length === 3 && rest[2] === 'heartbeat') {
      this.#heartbeatPhone(res, account, this.#decodeSegment(rest[1]));
      return;
    }
    this.#sendError(res, 404, 'unknown_endpoint', 'there is no such relay endpoint');
  }

  /**
   * Register a phone: `POST /_relay/accounts/<accountId>/phones`.
   *
   * The phone chooses its own device id and its own device token (both live in the private
   * storage of the phone), so the relay validates the shape of the two and never moves a
   * device id from one account to another:
   *
   *   * an unknown device id becomes a `phone` of the account (200);
   *   * a known device id with the **same** token is an update: the name may change and the
   *     presence is refreshed (200);
   *   * a known device id with a **different** token is a conflict (409) — a phone may not
   *     take the id of another device;
   *   * a device id of **another** account is a conflict (409) as well.
   */
  async #registerPhone(req, res, account) {
    const body = await this.#readJsonBody(req);
    if (body.error) {
      this.#sendError(res, 400, 'bad_request', body.error);
      return;
    }
    const payload = (body.value && typeof body.value === 'object') ? body.value : {};
    // The device id and the token are used exactly as they were sent: the relay does not
    // "repair" them, a shape that is not the documented one is a 400.
    const deviceId = typeof payload.deviceId === 'string' ? payload.deviceId : '';
    // The token is hex, so the case does not matter: it is stored in lower case.
    const token = typeof payload.token === 'string' ? payload.token.toLowerCase() : '';
    const name = typeof payload.name === 'string' ? payload.name.trim() : '';

    if (!PHONE_DEVICE_ID_PATTERN.test(deviceId)) {
      this.#sendError(res, 400, 'bad_request', 'the device id must match /^[A-Za-z0-9._-]{1,64}$/');
      return;
    }
    if (!PHONE_TOKEN_PATTERN.test(token)) {
      this.#sendError(res, 400, 'bad_request', 'the device token must be 64 hex characters');
      return;
    }
    if (name.length > MAX_DEVICE_NAME_LENGTH) {
      this.#sendError(res, 400, 'bad_request', `the device name must be at most ${MAX_DEVICE_NAME_LENGTH} characters`);
      return;
    }

    // A device id belongs to one account: it is never moved to another one.
    const owners = deviceOwners(this.registry, deviceId).filter((owner) => owner.id !== account.id);
    if (owners.length > 0) {
      this.#sendError(res, 409, 'device_conflict', `the device "${deviceId}" already belongs to the account "${owners[0].id}"`);
      return;
    }

    const existing = account.devices.get(deviceId) ?? null;
    if (existing) {
      if (existing.role !== ROLE_PHONE) {
        this.#sendError(res, 409, 'device_conflict', `the device "${deviceId}" is already registered as a "${existing.role}"`);
        return;
      }
      if (!constantTimeEquals(existing.token, token)) {
        this.#sendError(res, 409, 'device_conflict', `the device "${deviceId}" is registered with a different token`);
        return;
      }
      // The same phone comes again: the name may change, the presence is refreshed.
      if (name.length > 0) existing.name = name;
      touchDevice(this.registry, account.id, deviceId, Date.now());
      this.#persist();
      this.#sendJson(res, 200, { device: this.#deviceState(existing) });
      return;
    }

    const device = addDevice(this.registry, account.id, {
      id: deviceId,
      name: name.length > 0 ? name : deviceId,
      token,
      role: ROLE_PHONE,
      lastSeen: Date.now(),
    });
    this.#rebuildDeviceIndex();
    this.#persist();
    this.log('info', `the phone ${device.id} joined the account ${account.id}`);
    this.#sendJson(res, 200, { device: this.#deviceState(device) });
  }

  /**
   * The heartbeat of a phone: `POST /_relay/accounts/<accountId>/phones/<deviceId>/heartbeat`.
   *
   * A phone has no WebSocket to the relay, so this call is what proves that it is alive: it
   * refreshes the `lastSeen` of the device.
   */
  #heartbeatPhone(res, account, deviceId) {
    const device = account.devices.get(deviceId) ?? null;
    if (!device) {
      this.#sendError(res, 404, 'unknown_device', `the device "${deviceId}" does not belong to the account "${account.id}"`);
      return;
    }
    touchDevice(this.registry, account.id, deviceId, Date.now());
    this.#sendJson(res, 200, { device: this.#deviceState(device) });
  }

  /**
   * Read the JSON body of one of the relay endpoints.
   *
   * @param {import('node:http').IncomingMessage} req the request
   * @param {number} [maxBytes] the biggest body that is read
   * @returns {Promise<{value?: unknown, error?: string}>}
   */
  #readJsonBody(req, maxBytes = MAX_RELAY_BODY_BYTES) {
    return new Promise((resolve) => {
      const chunks = [];
      let size = 0;
      let tooLarge = false;
      let settled = false;
      const finish = (result) => {
        if (settled) return;
        settled = true;
        resolve(result);
      };
      req.on('data', (chunk) => {
        size += chunk.length;
        if (size > maxBytes) {
          tooLarge = true;
          return;
        }
        chunks.push(chunk);
      });
      req.on('end', () => {
        if (tooLarge) {
          finish({ error: `the request body is larger than ${maxBytes} bytes` });
          return;
        }
        const raw = Buffer.concat(chunks).toString('utf8');
        if (raw.trim().length === 0) {
          finish({ error: 'the request body is empty' });
          return;
        }
        try {
          finish({ value: JSON.parse(raw) });
        } catch (error) {
          finish({ error: `the request body is not valid JSON: ${error.message}` });
        }
      });
      req.on('error', () => finish({ error: 'the request body could not be read' }));
      req.on('aborted', () => finish({ error: 'the request was aborted' }));
    });
  }

  /** One path segment, percent decoded (an invalid escape stays as it is). */
  #decodeSegment(segment) {
    try {
      return decodeURIComponent(segment);
    } catch {
      return segment;
    }
  }

  /** Answer with a JSON body. */
  #sendJson(res, status, payload) {
    const body = JSON.stringify(payload);
    try {
      res.writeHead(status, {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(body),
      });
      res.end(body);
    } catch {
      // Ignore.
    }
  }

  /* ---------------------------------------------------------------------- serving */

  /**
   * Start the relay.
   *
   * @param {{port: number, host?: string, tlsPort?: number, tlsCert?: string, tlsKey?: string}} options
   */
  async listen({ port, host = '0.0.0.0', tlsPort = 0, tlsCert, tlsKey } = {}) {
    this.httpServer = http.createServer();
    this.attach(this.httpServer, { secure: false });
    await new Promise((resolve, reject) => {
      this.httpServer.once('error', reject);
      this.httpServer.listen(port, host, () => {
        this.httpServer.removeListener('error', reject);
        resolve();
      });
    });

    if (tlsPort > 0) {
      if (!tlsCert || !tlsKey) {
        throw new Error('a TLS listener needs --tls-cert and --tls-key');
      }
      this.tlsServer = https.createServer({
        cert: fs.readFileSync(tlsCert),
        key: fs.readFileSync(tlsKey),
      });
      this.attach(this.tlsServer, { secure: true });
      await new Promise((resolve, reject) => {
        this.tlsServer.once('error', reject);
        this.tlsServer.listen(tlsPort, host, () => {
          this.tlsServer.removeListener('error', reject);
          resolve();
        });
      });
    }
    return this;
  }

  /** The port the plain listener is bound to. */
  get port() {
    return this.httpServer?.address()?.port ?? null;
  }

  /** The port the TLS listener is bound to. */
  get tlsPort() {
    return this.tlsServer?.address()?.port ?? null;
  }

  /** Stop the relay. */
  async close() {
    for (const session of [...this.sessions.values()]) {
      session.close('the relay shuts down');
      // The socket of a device is not owned by the HTTP server any more, it has to be closed
      // by hand — otherwise the server waits for it forever.
      session.connection?.destroy?.();
    }
    this.sessions.clear();
    for (const link of [...this.links.values()]) link.destroy();
    this.links.clear();
    const closers = [];
    for (const server of [this.httpServer, this.tlsServer]) {
      if (!server) continue;
      closers.push(new Promise((resolve) => {
        server.close(() => resolve());
        server.closeAllConnections?.();
      }));
    }
    await Promise.all(closers);
    this.httpServer = null;
    this.tlsServer = null;
  }
}
