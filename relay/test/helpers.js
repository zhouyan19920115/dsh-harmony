// Test helpers of the relay: a minimal WebSocket client, a fake desktop device and a fake
// desktop bridge. Everything is built on `node:` builtins only.

import crypto from 'node:crypto';
import net from 'node:net';
import tls from 'node:tls';
import http from 'node:http';
import { EventEmitter } from 'node:events';

import { FRAME, decodeFrame, encodeFrame } from '../src/frames.js';
import { acceptWebSocket } from '../src/ws.js';

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/** Compute the `Sec-WebSocket-Accept` of a client key. */
export function acceptKey(key) {
  return crypto.createHash('sha1').update(`${key}${GUID}`, 'utf8').digest('base64');
}

/** A free TCP port. */
export function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

/** A tiny RFC 6455 client (text and binary, no extensions). */
export class WsClient extends EventEmitter {
  constructor(url, { headers = {} } = {}) {
    super();
    this.url = new URL(url);
    this.key = crypto.randomBytes(16).toString('base64');
    this.headers = headers;
    this.socket = null;
    this.buffer = Buffer.alloc(0);
    this.fragments = [];
    this.handshakeDone = false;
    this.closed = false;
  }

  connect({ timeoutMs = 5000 } = {}) {
    return new Promise((resolve, reject) => {
      const secure = this.url.protocol === 'wss:';
      const socket = secure
        ? tls.connect({ host: this.url.hostname, port: Number(this.url.port || 443), rejectUnauthorized: false })
        : net.connect({ host: this.url.hostname, port: Number(this.url.port || 80) });
      this.socket = socket;
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new Error(`the websocket handshake to ${this.url.href} timed out`));
      }, timeoutMs);

      socket.on('error', (error) => {
        if (!this.handshakeDone) {
          clearTimeout(timer);
          reject(error);
        }
      });
      socket.on('close', () => {
        this.closed = true;
        this.emit('close');
      });
      socket.on('data', (chunk) => this.#onData(chunk, resolve, reject, timer));

      const target = `${this.url.pathname}${this.url.search}`;
      const lines = [
        `GET ${target} HTTP/1.1`,
        `Host: ${this.url.host}`,
        'Upgrade: websocket',
        'Connection: Upgrade',
        `Sec-WebSocket-Key: ${this.key}`,
        'Sec-WebSocket-Version: 13',
      ];
      for (const [name, value] of Object.entries(this.headers)) lines.push(`${name}: ${value}`);
      lines.push('', '');
      socket.write(lines.join('\r\n'));
    });
  }

  #onData(chunk, resolve, reject, timer) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    if (!this.handshakeDone) {
      const index = this.buffer.indexOf('\r\n\r\n');
      if (index === -1) return;
      const head = this.buffer.subarray(0, index).toString('latin1');
      this.buffer = this.buffer.subarray(index + 4);
      const status = head.split('\r\n')[0] ?? '';
      if (!/ 101 /u.test(status)) {
        clearTimeout(timer);
        this.socket.destroy();
        const error = new Error(`the websocket handshake failed: ${status.trim()}`);
        error.status = status;
        error.head = head;
        reject(error);
        return;
      }
      const accept = /sec-websocket-accept:\s*(\S+)/iu.exec(head)?.[1];
      if (accept !== acceptKey(this.key)) {
        clearTimeout(timer);
        this.socket.destroy();
        reject(new Error('the websocket handshake failed: wrong Sec-WebSocket-Accept'));
        return;
      }
      this.handshakeDone = true;
      clearTimeout(timer);
      resolve(this);
    }
    this.#parseFrames();
  }

  #parseFrames() {
    for (;;) {
      if (this.buffer.length < 2) return;
      const fin = (this.buffer[0] & 0x80) !== 0;
      const opcode = this.buffer[0] & 0x0f;
      let length = this.buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (this.buffer.length < 4) return;
        length = this.buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (this.buffer.length < 10) return;
        length = Number(this.buffer.readBigUInt64BE(2));
        offset = 10;
      }
      if (this.buffer.length < offset + length) return;
      const payload = this.buffer.subarray(offset, offset + length);
      this.buffer = this.buffer.subarray(offset + length);
      if (opcode === 0x2) {
        this.fragments.push(payload);
        if (fin) {
          const complete = Buffer.concat(this.fragments);
          this.fragments = [];
          this.emit('binary', complete);
        }
      } else if (opcode === 0x1) {
        this.fragments.push(payload);
        if (fin) {
          const complete = Buffer.concat(this.fragments);
          this.fragments = [];
          this.emit('text', complete.toString('utf8'));
        }
      } else if (opcode === 0x8) {
        this.emit('close');
      } else if (opcode === 0x9) {
        this.#write(0xa, payload);
      }
    }
  }

  #write(opcode, payload) {
    if (!this.socket || this.socket.destroyed) return;
    const data = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload), 'utf8');
    const maskKey = crypto.randomBytes(4);
    let header;
    if (data.length < 126) {
      header = Buffer.alloc(2);
      header[1] = 0x80 | data.length;
    } else if (data.length < 65536) {
      header = Buffer.alloc(4);
      header[1] = 0x80 | 126;
      header.writeUInt16BE(data.length, 2);
    } else {
      header = Buffer.alloc(10);
      header[1] = 0x80 | 127;
      header.writeBigUInt64BE(BigInt(data.length), 2);
    }
    header[0] = 0x80 | opcode;
    const masked = Buffer.allocUnsafe(data.length);
    for (let i = 0; i < data.length; i += 1) masked[i] = data[i] ^ maskKey[i & 3];
    this.socket.write(Buffer.concat([header, maskKey, masked]));
  }

  sendBinary(payload) {
    this.#write(0x2, payload);
  }

  sendText(text) {
    this.#write(0x1, Buffer.from(String(text), 'utf8'));
  }

  close() {
    if (!this.socket || this.socket.destroyed) return;
    this.#write(0x8, Buffer.alloc(0));
    this.socket.end();
  }
}

/**
 * A fake desktop device: it dials into the relay, says hello and opens a TCP connection to the
 * fake bridge whenever the relay asks for one.
 */
export class FakeDevice extends EventEmitter {
  constructor({ url, deviceId, token, name = 'fake device', answerPing = true, openError = null, bridgeToken = null }) {
    super();
    this.url = url;
    this.deviceId = deviceId;
    this.token = token;
    this.name = name;
    this.answerPing = answerPing;
    /** When set, the device answers an OPEN frame with OPEN_ERR instead of connecting. */
    this.openError = openError;
    /**
     * The token the phone of this device holds. The device announces it in its HELLO frame; the
     * relay keeps only its hash and uses it to authenticate the phone.
     */
    this.bridgeToken = bridgeToken;
    this.ws = null;
    this.sockets = new Map();
    this.openedStreams = [];
    this.closedStreams = [];
    this.targets = [];
    this.frames = [];
    this.receivedCloses = [];
  }

  async connect({ timeoutMs = 5000 } = {}) {
    const ws = new WsClient(this.url);
    await ws.connect({ timeoutMs });
    this.ws = ws;
    ws.on('binary', (payload) => this.#onFrame(payload));
    ws.on('close', () => this.emit('close'));

    this.send(FRAME.HELLO, Buffer.from(JSON.stringify({
      deviceId: this.deviceId,
      name: this.name,
      ...(this.bridgeToken ? { bridgeToken: this.bridgeToken } : {}),
    }), 'utf8'), 0);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('the relay did not answer the HELLO')), timeoutMs);
      this.once('hello-ok', () => {
        clearTimeout(timer);
        resolve();
      });
    });
    return this;
  }

  send(type, payload = Buffer.alloc(0), streamId = 0) {
    this.ws.sendBinary(encodeFrame(type, payload, streamId));
  }

  #onFrame(payload) {
    let frame;
    try {
      frame = decodeFrame(payload);
    } catch {
      return;
    }
    this.frames.push({ type: frame.type, streamId: frame.streamId, payload: frame.payload });
    switch (frame.type) {
      case FRAME.HELLO_OK:
        this.emit('hello-ok', frame.payload);
        break;
      case FRAME.OPEN: {
        const target = frame.payload.toString('utf8');
        this.targets.push(target);
        this.openedStreams.push(frame.streamId);
        if (this.openError) {
          this.send(FRAME.OPEN_ERR, Buffer.from(this.openError, 'utf8'), frame.streamId);
          break;
        }
        const [host, port] = target.split(':');
        const socket = net.connect({ host, port: Number(port) });
        this.sockets.set(frame.streamId, socket);
        socket.on('connect', () => {
          this.send(FRAME.OPEN_OK, Buffer.alloc(0), frame.streamId);
        });
        socket.on('data', (chunk) => this.send(FRAME.DATA, chunk, frame.streamId));
        socket.on('close', () => {
          this.closedStreams.push(frame.streamId);
          this.send(FRAME.CLOSE, Buffer.alloc(0), frame.streamId);
        });
        socket.on('error', () => {
          this.send(FRAME.OPEN_ERR, Buffer.from(`cannot reach ${target}`, 'utf8'), frame.streamId);
        });
        break;
      }
      case FRAME.DATA: {
        const socket = this.sockets.get(frame.streamId);
        if (socket && !socket.destroyed) socket.write(frame.payload);
        break;
      }
      case FRAME.CLOSE: {
        const socket = this.sockets.get(frame.streamId);
        this.receivedCloses.push(frame.streamId);
        if (socket) socket.destroy();
        break;
      }
      case FRAME.PING:
        if (this.answerPing) this.send(FRAME.PONG, Buffer.alloc(0), 0);
        break;
      default:
        break;
    }
  }

  close() {
    this.ws?.close();
    // The device opened a TCP connection to the fake bridge for every stream. Those sockets
    // keep the event loop of the test process alive, so they have to go with the device.
    for (const socket of this.sockets.values()) socket.destroy();
    this.sockets.clear();
  }
}

/**
 * A fake desktop bridge: the HTTP server the device opens when the relay sends an OPEN frame.
 * It records every request and answers with a JSON echo.
 */
export async function startFakeBridge() {
  const requests = [];
  const upgrades = [];
  const sockets = new Set();
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const body = Buffer.concat(chunks);
      requests.push({
        method: req.method,
        url: req.url,
        headers: req.headers,
        rawHeaders: req.rawHeaders,
        body,
      });
      const payload = JSON.stringify({
        ok: true,
        method: req.method,
        url: req.url,
        authorization: req.headers.authorization ?? null,
        body: body.toString('utf8'),
      });
      res.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) });
      res.end(payload);
    });
  });

  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  });

  server.on('upgrade', (req, socket, head) => {
    upgrades.push({ url: req.url, headers: req.headers, rawHeaders: req.rawHeaders });
    const connection = acceptWebSocket(req, socket, head);
    if (!connection) return;
    connection.on('binary', (payload) => connection.sendBinary(payload));
  });

  const port = await freePort();
  await new Promise((resolve) => server.listen(port, '127.0.0.1', resolve));

  return {
    port,
    requests,
    upgrades,
    close: () => new Promise((resolve) => {
      for (const socket of sockets) socket.destroy();
      sockets.clear();
      server.close(() => resolve());
      server.closeAllConnections?.();
    }),
  };
}

/** Send raw bytes to a port and collect the raw answer. */
export function rawRequest(port, text, { timeoutMs = 5000 } = {}) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    const socket = net.connect({ host: '127.0.0.1', port }, () => socket.write(text));
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error('the request timed out'));
    }, timeoutMs);
    socket.on('data', (chunk) => chunks.push(chunk));
    socket.on('end', () => {
      clearTimeout(timer);
      resolve(Buffer.concat(chunks).toString('latin1'));
    });
    socket.on('close', () => {
      clearTimeout(timer);
      resolve(Buffer.concat(chunks).toString('latin1'));
    });
    socket.on('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

/** Wait until `predicate()` is true. */
export async function waitUntil(predicate, { timeoutMs = 5000, stepMs = 20 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return true;
    await new Promise((resolve) => setTimeout(resolve, stepMs));
  }
  throw new Error('the condition was not met in time');
}
