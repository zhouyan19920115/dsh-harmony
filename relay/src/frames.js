// Binary frame codec of the DSH Harmony cloud relay protocol (docs/RELAY.md §3).
//
// Every payload that travels over the device WebSocket is a frame:
//
//   0                   1                   2                   3
//   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
//   +-------------------------------+---------------+---------------+
//   |         streamId (4B BE)      |    type (1B)  |  length (4B BE)|
//   +-------------------------------+---------------+---------------+
//   |                      payload (length bytes)                    |
//   +---------------------------------------------------------------+
//
// Note the field order: the type byte sits *between* the stream id and the length.
// `streamId === 0` marks a control frame that is not bound to a stream (handshake, heartbeat).

/** Frame type bytes (docs/RELAY.md §3.1). */
export const FRAME = Object.freeze({
  OPEN: 0x01,
  OPEN_OK: 0x02,
  OPEN_ERR: 0x03,
  DATA: 0x04,
  CLOSE: 0x05,
  HELLO: 0x10,
  HELLO_OK: 0x11,
  PING: 0x12,
  PONG: 0x13,
});

/** Human readable frame names, used by the logs. */
export const FRAME_NAME = Object.freeze({
  0x01: 'OPEN',
  0x02: 'OPEN_OK',
  0x03: 'OPEN_ERR',
  0x04: 'DATA',
  0x05: 'CLOSE',
  0x10: 'HELLO',
  0x11: 'HELLO_OK',
  0x12: 'PING',
  0x13: 'PONG',
});

/** Size of the frame header: 4 + 1 + 4 bytes. */
export const HEADER_SIZE = 9;

/** Maximum payload of a single frame. The spec caps `DATA` at 256 KB. */
export const MAX_PAYLOAD = 256 * 1024;

/** Control frames are not bound to a stream. */
export const CONTROL_STREAM = 0;

/**
 * Encode one frame.
 *
 * @param {number} type one of {@link FRAME}
 * @param {Buffer|string} [payload] frame body
 * @param {number} [streamId] stream the frame belongs to (0 = control frame)
 * @returns {Buffer}
 */
export function encodeFrame(type, payload = Buffer.alloc(0), streamId = 0) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload), 'utf8');
  if (body.length > MAX_PAYLOAD) {
    throw new RangeError(`frame payload of ${body.length} bytes exceeds the ${MAX_PAYLOAD} byte limit`);
  }
  const frame = Buffer.allocUnsafe(HEADER_SIZE + body.length);
  frame.writeUInt32BE(streamId >>> 0, 0);
  frame.writeUInt8(type & 0xff, 4);
  frame.writeUInt32BE(body.length, 5);
  body.copy(frame, HEADER_SIZE);
  return frame;
}

/**
 * Decode one complete frame.
 *
 * @param {Buffer} buffer a buffer that holds exactly one frame
 * @returns {{type: number, streamId: number, payload: Buffer}}
 */
export function decodeFrame(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < HEADER_SIZE) {
    throw new Error(`a frame needs at least ${HEADER_SIZE} bytes, got ${buffer?.length ?? 0}`);
  }
  const streamId = buffer.readUInt32BE(0);
  const type = buffer.readUInt8(4);
  const length = buffer.readUInt32BE(5);
  if (buffer.length < HEADER_SIZE + length) {
    throw new Error(`truncated frame: header announces ${length} payload bytes`);
  }
  return { type, streamId, payload: buffer.subarray(HEADER_SIZE, HEADER_SIZE + length) };
}

/**
 * Incremental frame parser. `push()` returns the frames that became complete; a partially
 * received frame stays in the internal buffer.
 */
export class FrameParser {
  constructor({ maxPayload = MAX_PAYLOAD } = {}) {
    this.maxPayload = maxPayload;
    this.buffer = Buffer.alloc(0);
  }

  /** @returns {{type: number, streamId: number, payload: Buffer}[]} */
  push(chunk) {
    this.buffer = this.buffer.length === 0 ? Buffer.from(chunk) : Buffer.concat([this.buffer, chunk]);
    const frames = [];
    for (;;) {
      if (this.buffer.length < HEADER_SIZE) break;
      const length = this.buffer.readUInt32BE(5);
      if (length > this.maxPayload) {
        throw new RangeError(`frame announces ${length} payload bytes, the limit is ${this.maxPayload}`);
      }
      if (this.buffer.length < HEADER_SIZE + length) break;
      const frame = decodeFrame(this.buffer.subarray(0, HEADER_SIZE + length));
      this.buffer = this.buffer.subarray(HEADER_SIZE + length);
      frames.push(frame);
    }
    return frames;
  }
}
