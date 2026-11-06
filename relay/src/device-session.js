// The device side of the relay: one WebSocket connection of the desktop bridge, the streams that
// run on top of it and the heartbeat.
//
// Wire protocol (docs/RELAY.md §3):
//
//   device ──HELLO {deviceId,name}──► relay
//   device ◄──HELLO_OK {relay,version}── relay
//   relay  ──OPEN  streamId "127.0.0.1:8787"──► device
//   device ──OPEN_OK streamId──► relay
//   device ──OPEN_ERR streamId "message"──► relay
//   both   ──DATA streamId <raw bytes>──►
//   both   ──CLOSE streamId──►
//   relay  ──PING (streamId 0)──► device        every 20 s
//   device ──PONG (streamId 0)──► relay

import { EventEmitter } from 'node:events';

import { FRAME, decodeFrame, encodeFrame } from './frames.js';
import { hashSecret } from './accounts.js';
import { constantTimeEquals } from './devices.js';

export const RELAY_NAME = 'dsh-harmony-relay';
export const RELAY_VERSION = '1.0.0';

/** Maximum number of phone bytes that are buffered while the stream is still opening. */
const MAX_PENDING_BYTES = 1024 * 1024;

/**
 * One stream: a phone connection that is mirrored by a TCP connection of the device.
 *
 * The stream is a byte pipe, it never looks into the payload.
 */
export class RelayStream extends EventEmitter {
  constructor({ id, session, target, timers, log }) {
    super();
    this.id = id;
    this.session = session;
    this.target = target;
    this.timers = timers;
    this.log = log;
    this.state = 'opening'; // opening | open | closed
    this.pending = [];
    this.pendingBytes = 0;
    this.closeSent = false;
    this.idleTimer = null;
  }

  /** Ask the device to open the TCP connection of this stream. */
  open() {
    this.session.send(FRAME.OPEN, this.target, this.id);
    this.#armIdleTimer();
  }

  /** The device confirmed the connection: everything that piled up can be forwarded now. */
  handleOpenOk() {
    if (this.state !== 'opening') return;
    this.state = 'open';
    const queued = this.pending;
    this.pending = [];
    this.pendingBytes = 0;
    for (const chunk of queued) this.session.send(FRAME.DATA, chunk, this.id);
    this.emit('open');
  }

  /** The device could not open the connection. */
  handleOpenErr(message) {
    if (this.state === 'closed') return;
    this.state = 'closed';
    this.#clearIdleTimer();
    this.emit('open-error', message);
  }

  /** Phone → device. */
  writeToDevice(bytes) {
    if (this.state === 'closed' || bytes.length === 0) return;
    this.#touch();
    if (this.state !== 'open') {
      this.pending.push(bytes);
      this.pendingBytes += bytes.length;
      if (this.pendingBytes > MAX_PENDING_BYTES) {
        this.close('the device did not open the stream in time');
      }
      return;
    }
    this.session.send(FRAME.DATA, bytes, this.id);
  }

  /** Device → phone. */
  writeToPhone(bytes) {
    if (this.state === 'closed' || bytes.length === 0) return;
    this.#touch();
    this.emit('data', bytes);
  }

  /** The device closed the stream. */
  handleClose() {
    this.#finish('closed by the device');
  }

  /** Close the stream, both sides. */
  close(reason = 'closed') {
    if (this.state === 'closed') return;
    this.#finish(reason);
  }

  #finish(reason) {
    if (this.state === 'closed') return;
    this.state = 'closed';
    this.#clearIdleTimer();
    if (!this.closeSent) {
      this.closeSent = true;
      try {
        this.session.send(FRAME.CLOSE, Buffer.alloc(0), this.id);
      } catch {
        // The device is gone anyway.
      }
    }
    this.emit('closed', reason);
  }

  #touch() {
    this.#armIdleTimer();
  }

  #armIdleTimer() {
    if (this.idleTimer) this.timers.clearTimeout(this.idleTimer);
    this.idleTimer = this.timers.setTimeout(() => {
      this.close('the stream was idle for too long');
    }, this.timers.streamIdleMs);
  }

  #clearIdleTimer() {
    if (this.idleTimer) {
      this.timers.clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
  }
}

/**
 * A device that dialed in: the WebSocket connection, the streams that run on it and the
 * heartbeat.
 */
export class DeviceSession extends EventEmitter {
  constructor({ device, connection, timers, log }) {
    super();
    this.device = device;
    this.id = device.id;
    this.name = device.name;
    this.connection = connection;
    this.timers = timers;
    this.log = log;
    this.streams = new Map();
    this.nextStreamId = 1;
    this.helloReceived = false;
    /** The bridge port of the device (it may announce it in the HELLO frame). */
    this.devicePort = device.port ?? null;
    /**
     * The hash of the **bridge token** — the token the phone of this device holds.
     *
     * The desktop bridge announces it in its HELLO frame. Only the hash is kept: the relay has
     * to compare a token the phone presents, it never needs the token itself.
     */
    this.bridgeTokenHash = null;
    this.closed = false;
    this.pongTimer = null;
    /** Number of heartbeats the device did not answer yet. */
    this.pendingPings = 0;
    this.pingTimer = null;
  }

  /** Start the heartbeat and listen to the frames of the device. */
  start() {
    this.connection.on('binary', (payload) => this.#onFrame(payload));
    this.connection.on('close', () => this.close('the device disconnected'));
    this.connection.on('error', () => this.close('the device connection failed'));

    this.pingTimer = this.timers.setInterval(() => this.#ping(), this.timers.pingIntervalMs);
    this.#armPongTimer();
  }

  /** Send a frame to the device. */
  send(type, payload = Buffer.alloc(0), streamId = 0) {
    if (this.closed) return;
    this.connection.sendBinary(encodeFrame(type, payload, streamId));
  }

  /**
   * Is this the token the phone of this device holds?
   *
   * The device announces its bridge token in the HELLO frame; only its hash is kept. A device
   * that does not announce one (an older bridge) cannot be checked this way.
   *
   * @param {string} token the token a phone presented
   * @returns {boolean} true when the token is the bridge token of this device
   */
  matchesBridgeToken(token) {
    if (typeof token !== 'string' || token.length === 0) return false;
    if (this.bridgeTokenHash === null) return false;
    return constantTimeEquals(hashSecret(token), this.bridgeTokenHash);
  }

  /** Did the device announce the token its phone holds? */
  get hasBridgeToken() {
    return this.bridgeTokenHash !== null;
  }

  /**
   * Open a new stream towards `host:port` on the device.
   *
   * @param {string} target the address the device has to connect to, e.g. `127.0.0.1:8787`
   * @returns {RelayStream}
   */
  openStream(target) {
    const id = this.nextStreamId;
    this.nextStreamId += 1;
    const stream = new RelayStream({ id, session: this, target, timers: this.timers, log: this.log });
    this.streams.set(id, stream);
    stream.on('closed', () => this.streams.delete(id));
    stream.open();
    return stream;
  }

  /** The phone side went away: drop every stream of this device. */
  close(reason = 'closed') {
    if (this.closed) return;
    this.closed = true;
    if (this.pingTimer) this.timers.clearInterval(this.pingTimer);
    if (this.pongTimer) this.timers.clearTimeout(this.pongTimer);
    this.pingTimer = null;
    this.pongTimer = null;
    for (const stream of [...this.streams.values()]) {
      stream.close(reason);
    }
    this.streams.clear();
    this.emit('close', reason);
  }

  #ping() {
    if (this.closed) return;
    this.send(FRAME.PING, Buffer.alloc(0), 0);
    this.pendingPings += 1;
    if (this.pendingPings >= this.timers.maxMissedPings) {
      this.close('the device did not answer the heartbeat');
      return;
    }
    this.#armPongTimer();
  }

  #armPongTimer() {
    if (this.pongTimer) return;
    this.pongTimer = this.timers.setTimeout(() => {
      this.close('the device did not answer the heartbeat');
    }, this.timers.pongTimeoutMs);
  }

  #onFrame(payload) {
    if (this.closed) return;
    let frame;
    try {
      frame = decodeFrame(payload);
    } catch (error) {
      this.log('warn', `the device ${this.id} sent a broken frame: ${error.message}`);
      this.close('protocol error');
      return;
    }

    switch (frame.type) {
      case FRAME.HELLO: {
        let hello = null;
        try {
          hello = JSON.parse(frame.payload.toString('utf8'));
        } catch {
          hello = null;
        }
        const deviceId = typeof hello?.deviceId === 'string' ? hello.deviceId : '';
        if (deviceId && deviceId !== this.id) {
          this.log('warn', `the device ${this.id} announced the id ${deviceId} — dropping the connection`);
          this.close('the announced device id does not match the connection');
          return;
        }
        if (typeof hello?.name === 'string' && hello.name.length > 0) this.name = hello.name;
        if (Number.isInteger(hello?.port) && hello.port > 0) this.devicePort = hello.port;
        // The token the phone of this device holds. The relay keeps only its hash: it has to
        // compare a token the phone presents, it never needs the token itself.
        if (typeof hello?.bridgeToken === 'string' && hello.bridgeToken.length > 0) {
          this.bridgeTokenHash = hashSecret(hello.bridgeToken);
        }
        this.helloReceived = true;
        this.send(FRAME.HELLO_OK, Buffer.from(JSON.stringify({ relay: RELAY_NAME, version: RELAY_VERSION }), 'utf8'), 0);
        this.emit('hello', hello);
        break;
      }
      case FRAME.OPEN_OK: {
        const stream = this.streams.get(frame.streamId);
        if (stream) stream.handleOpenOk();
        break;
      }
      case FRAME.OPEN_ERR: {
        const stream = this.streams.get(frame.streamId);
        const message = frame.payload.toString('utf8') || 'the device could not open the connection';
        if (stream) stream.handleOpenErr(message);
        break;
      }
      case FRAME.DATA: {
        const stream = this.streams.get(frame.streamId);
        if (stream) stream.writeToPhone(frame.payload);
        break;
      }
      case FRAME.CLOSE: {
        const stream = this.streams.get(frame.streamId);
        if (stream) stream.handleClose();
        break;
      }
      case FRAME.PONG: {
        this.pendingPings = 0;
        if (this.pongTimer) {
          this.timers.clearTimeout(this.pongTimer);
          this.pongTimer = null;
        }
        break;
      }
      case FRAME.PING: {
        // A device may ping the relay as well; answer so that it does not time out.
        this.send(FRAME.PONG, Buffer.alloc(0), 0);
        break;
      }
      default:
        this.log('warn', `the device ${this.id} sent the unknown frame type 0x${frame.type.toString(16)}`);
        break;
    }
  }
}
