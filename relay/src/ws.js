// Minimal RFC 6455 WebSocket *server* side, zero dependencies.
//
// The relay only needs one thing from the WebSocket layer: a reliable binary message channel
// towards the desktop device. Everything else (the DSH Harmony relay frames) lives in
// `frames.js`. The implementation deliberately stays close to `bridge/src/ws.js` so that the
// desktop client can reuse the same expectations (binary messages, fragmentation, ping/pong).

import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

export const OPCODE = Object.freeze({
  CONTINUATION: 0x0,
  TEXT: 0x1,
  BINARY: 0x2,
  CLOSE: 0x8,
  PING: 0x9,
  PONG: 0xa,
});

const CLOSE_NORMAL = 1000;
const CLOSE_PROTOCOL_ERROR = 1002;
const CLOSE_TOO_LARGE = 1009;

/** Compute the `Sec-WebSocket-Accept` value for a client key. */
export function acceptKey(key) {
  return crypto.createHash('sha1').update(`${key}${GUID}`, 'utf8').digest('base64');
}

/** Encode one WebSocket frame (server → client, never masked). */
export function encodeWsFrame(opcode, payload = Buffer.alloc(0), { fin = true } = {}) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload), 'utf8');
  let header;
  if (data.length < 126) {
    header = Buffer.alloc(2);
    header[1] = data.length;
  } else if (data.length < 65536) {
    header = Buffer.alloc(4);
    header[1] = 126;
    header.writeUInt16BE(data.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(data.length), 2);
  }
  header[0] = (fin ? 0x80 : 0x00) | (opcode & 0x0f);
  return Buffer.concat([header, data]);
}

/** Build a close frame payload. */
export function encodeClosePayload(code, reason = '') {
  const reasonBytes = Buffer.from(String(reason), 'utf8');
  const payload = Buffer.allocUnsafe(2 + reasonBytes.length);
  payload.writeUInt16BE(code, 0);
  reasonBytes.copy(payload, 2);
  return payload;
}

/** Incremental WebSocket frame parser (client → server, masked frames expected). */
export class WsFrameParser {
  constructor({ requireMask = true, maxPayload = 4 * 1024 * 1024 } = {}) {
    this.requireMask = requireMask;
    this.maxPayload = maxPayload;
    this.buffer = Buffer.alloc(0);
    this.fragments = [];
    this.fragmentOpcode = null;
  }

  /** @returns {{fin: boolean, opcode: number, payload: Buffer}[]} */
  push(chunk) {
    this.buffer = this.buffer.length === 0 ? Buffer.from(chunk) : Buffer.concat([this.buffer, chunk]);
    const frames = [];
    for (;;) {
      const frame = this.#readOne();
      if (frame === null) break;
      frames.push(frame);
    }
    return frames;
  }

  #readOne() {
    const buffer = this.buffer;
    if (buffer.length < 2) return null;
    const fin = (buffer[0] & 0x80) !== 0;
    const opcode = buffer[0] & 0x0f;
    const masked = (buffer[1] & 0x80) !== 0;
    let length = buffer[1] & 0x7f;
    let offset = 2;

    if (length === 126) {
      if (buffer.length < offset + 2) return null;
      length = buffer.readUInt16BE(offset);
      offset += 2;
    } else if (length === 127) {
      if (buffer.length < offset + 8) return null;
      const big = buffer.readBigUInt64BE(offset);
      if (big > BigInt(this.maxPayload)) throw new RangeError('websocket frame is too large');
      length = Number(big);
      offset += 8;
    }
    if (length > this.maxPayload) throw new RangeError('websocket frame is too large');

    let maskKey = null;
    if (masked) {
      if (buffer.length < offset + 4) return null;
      maskKey = buffer.subarray(offset, offset + 4);
      offset += 4;
    } else if (this.requireMask) {
      throw new Error('a client frame must be masked');
    }
    if (buffer.length < offset + length) return null;

    const payload = Buffer.from(buffer.subarray(offset, offset + length));
    if (maskKey) {
      for (let i = 0; i < payload.length; i += 1) payload[i] ^= maskKey[i & 3];
    }
    this.buffer = buffer.subarray(offset + length);
    return { fin, opcode, payload };
  }
}

/**
 * A live WebSocket connection. Emits `binary` (complete binary messages), `text`, `close` and
 * `error`.
 */
export class WebSocketConnection extends EventEmitter {
  constructor(socket, { maxPayload = 4 * 1024 * 1024 } = {}) {
    super();
    this.socket = socket;
    this.parser = new WsFrameParser({ maxPayload });
    this.closed = false;
    this.closeSent = false;

    socket.on('data', (chunk) => this.#onData(chunk));
    socket.on('error', (error) => this.#onError(error));
    socket.on('close', () => this.#onClose());
  }

  /** Send a binary message. */
  sendBinary(payload) {
    this.#write(encodeWsFrame(OPCODE.BINARY, payload));
  }

  /** Send a text message. */
  sendText(text) {
    this.#write(encodeWsFrame(OPCODE.TEXT, Buffer.from(String(text), 'utf8')));
  }

  /** Send a ping. */
  ping(payload = Buffer.alloc(0)) {
    this.#write(encodeWsFrame(OPCODE.PING, payload));
  }

  /** Close the connection. */
  close(code = CLOSE_NORMAL, reason = '') {
    if (this.closed) return;
    if (!this.closeSent) {
      this.closeSent = true;
      this.#write(encodeWsFrame(OPCODE.CLOSE, encodeClosePayload(code, reason)));
    }
    try {
      this.socket.end();
    } catch {
      // The socket may already be gone.
    }
  }

  /** Destroy the underlying socket without a close handshake. */
  destroy() {
    if (this.closed) return;
    try {
      this.socket.destroy();
    } catch {
      // Ignore.
    }
  }

  #write(buffer) {
    if (this.closed || this.socket.destroyed) return;
    try {
      this.socket.write(buffer);
    } catch (error) {
      this.#onError(error);
    }
  }

  /** Feed bytes that were already read from the socket (the `head` of an upgrade) into the parser. */
  push(chunk) {
    if (chunk && chunk.length > 0) this.#onData(chunk);
  }

  #onData(chunk) {
    let frames;
    try {
      frames = this.parser.push(chunk);
    } catch (error) {
      this.emit('error', error);
      this.close(CLOSE_PROTOCOL_ERROR, 'protocol error');
      return;
    }
    for (const frame of frames) {
      switch (frame.opcode) {
        case OPCODE.PING:
          this.#write(encodeWsFrame(OPCODE.PONG, frame.payload));
          break;
        case OPCODE.PONG:
          break;
        case OPCODE.CLOSE:
          this.close(CLOSE_NORMAL, '');
          this.#onClose();
          break;
        case OPCODE.CONTINUATION:
        case OPCODE.TEXT:
        case OPCODE.BINARY: {
          if (frame.opcode !== OPCODE.CONTINUATION) {
            this.parser.fragments = [];
            this.parser.fragmentOpcode = frame.opcode;
          }
          this.parser.fragments.push(frame.payload);
          if (!frame.fin) break;
          const complete = Buffer.concat(this.parser.fragments);
          this.parser.fragments = [];
          const opcodeUsed = this.parser.fragmentOpcode ?? OPCODE.TEXT;
          this.parser.fragmentOpcode = null;
          if (opcodeUsed === OPCODE.TEXT) this.emit('text', complete.toString('utf8'));
          else this.emit('binary', complete);
          break;
        }
        default:
          this.close(CLOSE_PROTOCOL_ERROR, `unsupported opcode ${frame.opcode}`);
          break;
      }
    }
  }

  #onError(error) {
    if (this.closed) return;
    this.closed = true;
    this.emit('error', error);
    this.emit('close');
  }

  #onClose() {
    if (this.closed) return;
    this.closed = true;
    this.emit('close');
  }
}

/**
 * Complete the server side of the WebSocket handshake and return the connection.
 * Returns `null` when the request is not a valid upgrade (the socket is closed by the caller).
 */
export function acceptWebSocket(req, socket, head, { maxPayload, subprotocol = '' } = {}) {
  const key = req.headers['sec-websocket-key'];
  const upgrade = String(req.headers.upgrade ?? '').toLowerCase();
  const version = String(req.headers['sec-websocket-version'] ?? '');
  if (upgrade !== 'websocket' || typeof key !== 'string' || key.length === 0 || version !== '13') {
    socket.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
    socket.destroy();
    return null;
  }

  socket.setNoDelay(true);
  const lines = [
    'HTTP/1.1 101 Switching Protocols',
    'Upgrade: websocket',
    'Connection: Upgrade',
    `Sec-WebSocket-Accept: ${acceptKey(key)}`,
  ];
  // The client offered a subprotocol (that is how it carries its token): the server has to
  // name the one it picked, otherwise the client rejects the handshake.
  if (typeof subprotocol === 'string' && subprotocol.length > 0) {
    lines.push(`Sec-WebSocket-Protocol: ${subprotocol}`);
  }
  lines.push('\r\n');
  socket.write(lines.join('\r\n'));

  const connection = new WebSocketConnection(socket, { maxPayload });
  if (head && head.length > 0) connection.push(head);
  return connection;
}
