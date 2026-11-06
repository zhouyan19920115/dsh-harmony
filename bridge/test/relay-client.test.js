// Zero-dependency tests for the desktop-side relay client.
//
// Run with `node test/relay-client.test.js`.
//
// The bridge's own suite lives in `test/run.js` and has its own tiny runner; this file has one of
// its own as well so the bridge suite keeps its 25 tests. The fake relay below is the mirror image
// of `src/relay-client.js`: it speaks the same protocol with the same `ws.js` helpers the bridge
// uses everywhere else.

import assert from 'node:assert/strict';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import fs from 'node:fs';
import { EventEmitter } from 'node:events';

import { loadOrCreateState } from '../src/config.js';
import { DshClient } from '../src/dsh.js';
import { Bridge, Router, createRoutes } from '../src/router.js';
import { createBridgeServer } from '../src/server.js';
import {
  MAX_DATA_PAYLOAD,
  RELAY_HEADER_SIZE,
  RELAY_TYPE,
  RelayClient,
  RelayFrameDecoder,
  buildRelayProtocolHeader,
  buildRelayUrl,
  decodeRelayFrame,
  encodeRelayFrame,
  relayPhoneUrl,
} from '../src/relay-client.js';
import { OPCODE, acceptWebSocket, encodeFrame } from '../src/ws.js';

/* ------------------------------------------------------------------ tiny test runner */

const tests = [];

function test(name, fn) {
  tests.push({ name, fn });
}

async function run() {
  let passed = 0;
  const failures = [];
  for (const entry of tests) {
    const started = Date.now();
    try {
      await entry.fn();
      passed += 1;
      process.stdout.write(`  ok   ${entry.name} (${Date.now() - started} ms)\n`);
    } catch (error) {
      failures.push({ name: entry.name, error });
      process.stdout.write(`  FAIL ${entry.name}\n`);
      process.stdout.write(`       ${error instanceof Error ? error.message : String(error)}\n`);
    }
  }
  process.stdout.write(`\n${passed} passed, ${failures.length} failed\n`);
  if (failures.length > 0) {
    for (const failure of failures) {
      process.stdout.write(`\n--- ${failure.name} ---\n${failure.error instanceof Error ? failure.error.stack : String(failure.error)}\n`);
    }
    process.exitCode = 1;
  }
}

/* ------------------------------------------------------------------------- helpers */

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** An echo server: it answers every chunk with `echo:<chunk>`. */
async function startEchoServer() {
  const sockets = [];
  const server = net.createServer((socket) => {
    sockets.push(socket);
    socket.on('error', () => {});
    socket.on('data', (chunk) => socket.write(Buffer.from(`echo:${chunk.toString('utf8')}`, 'utf8')));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  return {
    port,
    sockets,
    async close() {
      for (const socket of sockets) socket.destroy();
      await new Promise((resolve) => server.close(() => resolve()));
    },
  };
}

/** A server that collects everything it receives and answers with a fixed buffer. */
async function startSinkServer(reply) {
  const received = [];
  const server = net.createServer((socket) => {
    socket.on('error', () => {});
    socket.on('data', (chunk) => {
      received.push(chunk);
      socket.write(reply);
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  return {
    port,
    received: () => Buffer.concat(received),
    async close() {
      await new Promise((resolve) => server.close(() => resolve()));
    },
  };
}

/** A real bridge, so the relay can be tested against the actual API. */
async function startBridge() {
  const port = await freePort();
  const stateFile = path.join(os.tmpdir(), `dsh-relay-test-${crypto.randomUUID()}.json`);
  const state = loadOrCreateState(stateFile);
  const options = {
    port,
    host: '127.0.0.1',
    state: stateFile,
    adapter: 'dsh',
    allowUnauthPairing: false,
    dshUrl: 'http://127.0.0.1:10748',
  };
  const dsh = new DshClient({ baseUrl: options.dshUrl });
  const bridge = new Bridge({ options, state, dsh, log: () => {} });
  const router = new Router(createRoutes(bridge));
  const server = createBridgeServer({ bridge, router });
  await bridge.start();
  await server.listen(port, '127.0.0.1');
  return {
    port,
    state,
    async close() {
      bridge.stop();
      await server.close();
      try {
        fs.rmSync(stateFile, { force: true });
      } catch {
        // Ignore.
      }
    },
  };
}

/** Parse an HTTP response out of a byte buffer; `null` while it is incomplete. */
function parseHttpResponse(buffer) {
  const end = buffer.indexOf('\r\n\r\n');
  if (end === -1) return null;
  const lines = buffer.subarray(0, end).toString('latin1').split('\r\n');
  const match = /^HTTP\/1\.\d\s+(\d{3})/u.exec(lines[0] ?? '');
  if (match === null) return null;
  const headers = {};
  for (const line of lines.slice(1)) {
    const at = line.indexOf(':');
    if (at === -1) continue;
    headers[line.slice(0, at).trim().toLowerCase()] = line.slice(at + 1).trim();
  }
  const length = Number.parseInt(headers['content-length'] ?? '0', 10);
  const body = buffer.subarray(end + 4, end + 4 + length);
  if (body.length < length) return null;
  return { status: Number.parseInt(match[1], 10), headers, body: body.toString('utf8') };
}

/* ------------------------------------------------------------------- the fake relay */

/**
 * The relay side of the protocol: it accepts the device connection, answers the handshake and
 * opens streams towards the device. It also has a phone side (a plain TCP server) so a real HTTP
 * request can travel through it.
 */
class FakeRelay extends EventEmitter {
  constructor({ token = '0123456789abcdef', deviceId = 'dev-test' } = {}) {
    super();
    this.token = token;
    this.deviceId = deviceId;
    this.deviceTarget = `127.0.0.1:8787`;
    this.connections = [];
    this.current = null;
    this.frames = [];
    this.streams = new Map();
    this.decoder = new RelayFrameDecoder();
    this.nextStreamId = 1;
    this.phone = null;
    this.phoneServer = null;
  }

  /** A device connected to the relay. */
  attach(connection, deviceId) {
    const record = { connection, deviceId, closed: false };
    this.connections.push(record);
    this.current = record;
    connection.on('binary', (payload) => {
      for (const frame of this.decoder.push(payload)) this.#onFrame(frame);
    });
    connection.on('close', () => {
      record.closed = true;
      this.emit('device-close', record);
    });
    this.emit('device-connection', record);
  }

  #onFrame(frame) {
    this.frames.push(frame);
    switch (frame.type) {
      case RELAY_TYPE.HELLO:
        this.hello = JSON.parse(frame.payload.toString('utf8'));
        this.send(RELAY_TYPE.HELLO_OK, 0, Buffer.from(JSON.stringify({ relay: 'fake-relay', version: '1.0.0' })));
        this.emit('hello', this.hello);
        break;
      case RELAY_TYPE.OPEN_OK:
        this.emit('open-ok', frame.streamId);
        break;
      case RELAY_TYPE.OPEN_ERR:
        this.emit('open-err', frame.streamId, frame.payload.toString('utf8'));
        break;
      case RELAY_TYPE.DATA: {
        const stream = this.streams.get(frame.streamId);
        if (stream) stream.chunks.push(frame.payload);
        if (this.phone && this.phone.streamId === frame.streamId) this.phone.socket.write(frame.payload);
        this.emit('data', frame.streamId, frame.payload);
        break;
      }
      case RELAY_TYPE.CLOSE:
        this.emit('close', frame.streamId);
        if (this.phone && this.phone.streamId === frame.streamId) this.phone.socket.end();
        break;
      case RELAY_TYPE.PONG:
        this.emit('pong');
        break;
      default:
        this.emit('unknown', frame);
        break;
    }
  }

  /** Send a relay frame to the device. */
  send(type, streamId, payload = Buffer.alloc(0)) {
    const record = this.current;
    if (record === null) throw new Error('the device is not connected');
    record.connection.socket.write(encodeFrame(OPCODE.BINARY, encodeRelayFrame(streamId, type, payload)));
  }

  /** Open a stream towards the device and wait for `OPEN_OK` / `OPEN_ERR`. */
  open(target, { timeoutMs = 5000 } = {}) {
    const streamId = this.nextStreamId;
    this.nextStreamId += 1;
    const stream = { id: streamId, target, chunks: [], opened: false, error: null };
    this.streams.set(streamId, stream);

    const settled = new Promise((resolve) => {
      const onOk = (id) => {
        if (id !== streamId) return;
        cleanup();
        stream.opened = true;
        resolve(stream);
      };
      const onErr = (id, message) => {
        if (id !== streamId) return;
        cleanup();
        stream.error = message;
        resolve(stream);
      };
      const timer = setTimeout(() => {
        cleanup();
        stream.error = 'timeout';
        resolve(stream);
      }, timeoutMs);
      const cleanup = () => {
        clearTimeout(timer);
        this.off('open-ok', onOk);
        this.off('open-err', onErr);
      };
      this.on('open-ok', onOk);
      this.on('open-err', onErr);
    });

    this.send(RELAY_TYPE.OPEN, streamId, Buffer.from(target, 'utf8'));
    return settled;
  }

  /** The phone side: a plain TCP server that forwards everything through a stream. */
  async startPhone() {
    this.phoneServer = net.createServer((socket) => {
      socket.on('error', () => {});
      let buffer = Buffer.alloc(0);
      socket.on('data', (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        if (this.phone !== null) return;
        const end = buffer.indexOf('\r\n\r\n');
        if (end === -1) return;
        this.#openPhoneStream(socket, buffer.subarray(0, end + 4));
      });
    });
    await new Promise((resolve) => this.phoneServer.listen(0, '127.0.0.1', resolve));
    this.phonePort = this.phoneServer.address().port;
    return this.phonePort;
  }

  #openPhoneStream(socket, request) {
    const streamId = this.nextStreamId;
    this.nextStreamId += 1;
    const stream = { id: streamId, target: this.deviceTarget, chunks: [], opened: false, error: null };
    this.streams.set(streamId, stream);
    this.phone = { socket, streamId };

    const onOk = (id) => {
      if (id !== streamId) return;
      cleanup();
      this.send(RELAY_TYPE.DATA, streamId, request);
    };
    const onErr = (id, message) => {
      if (id !== streamId) return;
      cleanup();
      socket.write(`HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n${message}`);
      socket.end();
    };
    const timer = setTimeout(() => {
      cleanup();
      socket.destroy();
    }, 10000);
    const cleanup = () => {
      clearTimeout(timer);
      this.off('open-ok', onOk);
      this.off('open-err', onErr);
    };
    this.on('open-ok', onOk);
    this.on('open-err', onErr);

    this.send(RELAY_TYPE.OPEN, streamId, Buffer.from(this.deviceTarget, 'utf8'));
  }

  async close() {
    for (const record of this.connections) {
      try {
        record.connection.close();
      } catch {
        // The connection may already be gone.
      }
    }
    if (this.phoneServer) await new Promise((resolve) => this.phoneServer.close(() => resolve()));
  }
}

/**
 * The device token of a handshake.
 *
 * The token does not travel in the url (it would end up in the access log of every proxy), it
 * travels in the `Sec-WebSocket-Protocol` header of the handshake.
 */
function deviceTokenOf(request) {
  const header = request.headers['sec-websocket-protocol'];
  if (typeof header !== 'string') return null;
  for (const part of header.split(',')) {
    const value = part.trim();
    if (value.startsWith('dsh-device.')) return value.slice('dsh-device.'.length);
  }
  return null;
}

/** The relay server: the device WebSocket endpoint `/bridge`. */
async function startFakeRelay(options = {}) {
  const relay = new FakeRelay(options);
  const server = http.createServer((request, response) => {
    response.writeHead(404, { 'content-type': 'text/plain' });
    response.end('not found');
  });
  server.on('upgrade', (request, socket, head) => {
    const url = new URL(request.url ?? '/', 'http://relay.invalid');
    if (url.pathname !== '/bridge' || deviceTokenOf(request) !== relay.token) {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    const connection = acceptWebSocket(request, socket, head);
    if (connection === null) return;
    relay.attach(connection, url.searchParams.get('deviceId'));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  return {
    relay,
    port,
    url: `ws://127.0.0.1:${port}/bridge`,
    async close() {
      await relay.close();
      await new Promise((resolve) => server.close(() => resolve()));
    },
  };
}

/** A relay client that talks to the fake relay. */
function startRelayClient(url, targetPort, options = {}) {
  const logs = [];
  const client = new RelayClient({
    url,
    deviceToken: '0123456789abcdef',
    deviceId: 'dev-test',
    name: 'test-desktop',
    targetPort,
    log: (level, message) => logs.push(`${level}: ${message}`),
    reconnectMinMs: 100,
    reconnectMaxMs: 200,
    ...options,
  });
  client.start();
  return { client, logs };
}

/** The same relay, but with TLS: the device dials in with `wss://`. */
async function startFakeTlsRelay(options = {}) {
  const relay = new FakeRelay(options);
  const server = https.createServer({
    cert: fs.readFileSync(new URL('./fixtures/relay-test-cert.pem', import.meta.url)),
    key: fs.readFileSync(new URL('./fixtures/relay-test-key.pem', import.meta.url)),
  }, (request, response) => {
    response.writeHead(404, { 'content-type': 'text/plain' });
    response.end('not found');
  });
  server.on('upgrade', (request, socket, head) => {
    const url = new URL(request.url ?? '/', 'http://relay.invalid');
    if (url.pathname !== '/bridge' || deviceTokenOf(request) !== relay.token) {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    const connection = acceptWebSocket(request, socket, head);
    if (connection === null) return;
    relay.attach(connection, url.searchParams.get('deviceId'));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  return {
    relay,
    port,
    url: `wss://127.0.0.1:${port}/bridge`,
    async close() {
      await relay.close();
      await new Promise((resolve) => server.close(() => resolve()));
    },
  };
}

/* ------------------------------------------------------------------------- tests */

test('relay frames: the header is streamId(4B BE) | type(1B) | length(4B BE) | payload', () => {
  const frame = encodeRelayFrame(0x01020304, RELAY_TYPE.DATA, Buffer.from('hi', 'utf8'));
  assert.equal(frame.length, RELAY_HEADER_SIZE + 2);
  assert.equal(frame.readUInt32BE(0), 0x01020304);
  assert.equal(frame.readUInt8(4), RELAY_TYPE.DATA);
  assert.equal(frame.readUInt32BE(5), 2);
  assert.equal(frame.subarray(9).toString('utf8'), 'hi');
});

test('relay frames: encode and decode round-trip', () => {
  const payload = Buffer.from('GET /api/v1/health HTTP/1.1\r\n', 'utf8');
  const frame = encodeRelayFrame(7, RELAY_TYPE.DATA, payload);
  const decoded = decodeRelayFrame(frame);
  assert.notEqual(decoded, null);
  assert.equal(decoded.streamId, 7);
  assert.equal(decoded.type, RELAY_TYPE.DATA);
  assert.deepEqual(decoded.payload, payload);
  assert.equal(decodeRelayFrame(frame.subarray(0, 8)), null, 'a partial frame must not decode');
});

test('relay frames: the decoder copes with split and coalesced payloads', () => {
  const decoder = new RelayFrameDecoder();
  const one = encodeRelayFrame(1, RELAY_TYPE.DATA, Buffer.from('one'));
  const two = encodeRelayFrame(2, RELAY_TYPE.DATA, Buffer.from('two'));
  assert.deepEqual(decoder.push(one.subarray(0, 4)), [], 'an incomplete frame is buffered');
  const frames = decoder.push(Buffer.concat([one.subarray(4), two]));
  assert.equal(frames.length, 2);
  assert.equal(frames[0].payload.toString('utf8'), 'one');
  assert.equal(frames[1].payload.toString('utf8'), 'two');
});

test('relay: the device URL carries the device id and the token travels in the handshake', () => {
  const url = buildRelayUrl('ws://relay.example.com:8788/bridge', { deviceToken: 'abcd', deviceId: 'dev-8f2a' });
  assert.equal(url.searchParams.get('deviceId'), 'dev-8f2a');
  assert.equal(url.pathname, '/bridge');
  // 令牌不再走查询串(查询串会落进每个代理的访问日志), 它在握手的头里。
  assert.equal(url.searchParams.get('token'), null, 'the token must not travel in the url');
  assert.equal(buildRelayProtocolHeader({ deviceToken: 'abcd' }), 'dsh-device.abcd');
  assert.equal(
    buildRelayProtocolHeader({ deviceToken: 'abcd', accountToken: 'efgh', accountId: 'acc-1' }),
    'dsh-device.abcd, dsh-account.efgh, dsh-account-id.acc-1',
  );
  assert.equal(relayPhoneUrl('ws://relay.example.com:8788/bridge', 'dev-8f2a'), 'http://relay.example.com:8788/dev-8f2a');
});

test('relay: the device says HELLO and registers itself', async () => {
  const fake = await startFakeRelay();
  const { client, logs } = startRelayClient(fake.url, 8787);
  try {
    const hello = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('the device did not say hello')), 5000);
      fake.relay.once('hello', (payload) => {
        clearTimeout(timer);
        resolve(payload);
      });
    });
    assert.equal(hello.deviceId, 'dev-test');
    assert.equal(hello.name, 'test-desktop');
    assert.equal(hello.port, 8787, 'the device announces the port it serves on');
    await client.waitForConnection(2000);
    assert.equal(client.connected, true);
    const status = client.status();
    assert.equal(status.connected, true);
    assert.equal(status.deviceId, 'dev-test');
    assert.equal(typeof status.since, 'number');
    assert.ok(logs.some((line) => line.startsWith('info: the relay accepted the device')), logs.join('\n'));
  } finally {
    await client.stop();
    await fake.close();
  }
});

test('relay: the client stays connected while the connection is alive', async () => {
  const fake = await startFakeRelay();
  const { client } = startRelayClient(fake.url, 8787);
  try {
    await client.waitForConnection(2000);
    assert.equal(client.connected, true);
    await delay(600);
    assert.equal(client.connected, true, 'the client must stay connected');
    assert.equal(fake.relay.connections.length, 1, 'the client must not dial the relay again');
  } finally {
    await client.stop();
    await fake.close();
  }
});

test('relay: an OPEN to a forbidden target is refused with OPEN_ERR', async () => {
  const fake = await startFakeRelay();
  const { client } = startRelayClient(fake.url, 8787);
  try {
    await client.waitForConnection(2000);
    const stream = await fake.relay.open('10.0.0.5:8787');
    assert.equal(stream.opened, false, 'the stream must not be opened');
    assert.match(stream.error ?? '', /only 127\.0\.0\.1:8787 is allowed/u);

    const other = await fake.relay.open('127.0.0.1:9999');
    assert.equal(other.opened, false, 'a foreign port must not be opened');
    assert.match(other.error ?? '', /only 127\.0\.0\.1:8787 is allowed/u);
  } finally {
    await client.stop();
    await fake.close();
  }
});

test('relay: an OPEN to 127.0.0.1:<port> connects and pumps the bytes both ways', async () => {
  const echo = await startEchoServer();
  const fake = await startFakeRelay();
  const { client } = startRelayClient(fake.url, echo.port);
  try {
    await client.waitForConnection(2000);
    const stream = await fake.relay.open(`127.0.0.1:${echo.port}`);
    assert.equal(stream.opened, true, `the stream must be opened: ${stream.error ?? ''}`);

    fake.relay.send(RELAY_TYPE.DATA, stream.id, Buffer.from('ping', 'utf8'));
    const answer = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('the device sent nothing back')), 5000);
      fake.relay.once('data', (id, payload) => {
        if (id !== stream.id) return;
        clearTimeout(timer);
        resolve(payload);
      });
    });
    assert.equal(answer.toString('utf8'), 'echo:ping');
  } finally {
    await client.stop();
    await fake.close();
    await echo.close();
  }
});

test('relay: a DATA payload bigger than 256 KB is split into several frames', async () => {
  const big = Buffer.alloc(MAX_DATA_PAYLOAD + 40 * 1024, 0x61);
  const sink = await startSinkServer(big);
  const fake = await startFakeRelay();
  const { client } = startRelayClient(fake.url, sink.port);
  try {
    await client.waitForConnection(2000);
    const stream = await fake.relay.open(`127.0.0.1:${sink.port}`);
    assert.equal(stream.opened, true, `the stream must be opened: ${stream.error ?? ''}`);

    // The relay sends a small frame, the local server answers with a big one.
    fake.relay.send(RELAY_TYPE.DATA, stream.id, Buffer.from('ping', 'utf8'));
    await new Promise((resolve) => setTimeout(resolve, 500));

    assert.equal(sink.received().toString('utf8'), 'ping', 'the DATA must reach the local socket');
    const frames = fake.relay.frames.filter((frame) => frame.type === RELAY_TYPE.DATA && frame.streamId === stream.id);
    assert.ok(frames.length >= 2, `the payload must be split into several frames (got ${frames.length})`);
    for (const frame of frames) {
      assert.ok(frame.payload.length <= MAX_DATA_PAYLOAD, 'no DATA frame may exceed 256 KB');
    }
    assert.deepEqual(Buffer.concat(frames.map((frame) => frame.payload)), big, 'the bytes must arrive unchanged');
  } finally {
    await client.stop();
    await fake.close();
    await sink.close();
  }
});

test('relay: CLOSE tears the stream down', async () => {
  const echo = await startEchoServer();
  const fake = await startFakeRelay();
  const { client } = startRelayClient(fake.url, echo.port);
  try {
    await client.waitForConnection(2000);
    const stream = await fake.relay.open(`127.0.0.1:${echo.port}`);
    assert.equal(stream.opened, true, `the stream must be opened: ${stream.error ?? ''}`);
    assert.equal(echo.sockets.length, 1);

    const closed = new Promise((resolve) => echo.sockets[0].once('close', resolve));
    fake.relay.send(RELAY_TYPE.CLOSE, stream.id, Buffer.alloc(0));
    await closed;
    assert.equal(echo.sockets[0].destroyed, true, 'the local socket must be closed');
  } finally {
    await client.stop();
    await fake.close();
    await echo.close();
  }
});

test('relay: PING is answered with PONG', async () => {
  const fake = await startFakeRelay();
  const { client } = startRelayClient(fake.url, 8787);
  try {
    await client.waitForConnection(2000);
    const pong = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('the device did not pong')), 5000);
      fake.relay.once('pong', () => {
        clearTimeout(timer);
        resolve(true);
      });
    });
    fake.relay.send(RELAY_TYPE.PING, 0, Buffer.alloc(0));
    assert.equal(await pong, true);
  } finally {
    await client.stop();
    await fake.close();
  }
});

test('relay: the client reconnects after the peer dropped the connection', async () => {
  const fake = await startFakeRelay();
  const { client, logs } = startRelayClient(fake.url, 8787);
  try {
    await client.waitForConnection(2000);
    assert.equal(client.connected, true);

    const again = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('the device did not come back')), 10000);
      fake.relay.once('device-connection', (record) => {
        clearTimeout(timer);
        resolve(record);
      });
    });
    fake.relay.current.connection.close();
    await delay(50);
    assert.equal(client.connected, false, 'the client must notice the drop');

    await again;
    await client.waitForConnection(5000);
    assert.equal(client.connected, true, 'the client must be connected again');
    assert.equal(fake.relay.connections.length, 2);
    assert.ok(logs.some((line) => line.includes('the relay connection was lost')), logs.join('\n'));
  } finally {
    await client.stop();
    await fake.close();
  }
});

test('relay: an HTTP request travels through the relay and comes back 200', async () => {
  const bridge = await startBridge();
  const fake = await startFakeRelay();
  fake.relay.deviceTarget = `127.0.0.1:${bridge.port}`;
  const phonePort = await fake.relay.startPhone();
  const { client } = startRelayClient(fake.url, bridge.port);
  try {
    await client.waitForConnection(2000);

    const request = [
      'GET /api/v1/health HTTP/1.1',
      `Host: 127.0.0.1:${bridge.port}`,
      `Authorization: Bearer ${bridge.state.token}`,
      'Connection: close',
      '',
      '',
    ].join('\r\n');

    const response = await new Promise((resolve, reject) => {
      const socket = net.connect({ host: '127.0.0.1', port: phonePort }, () => socket.write(request));
      let buffer = Buffer.alloc(0);
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new Error('the phone request timed out'));
      }, 10000);
      socket.on('data', (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        const parsed = parseHttpResponse(buffer);
        if (parsed === null) return;
        clearTimeout(timer);
        socket.end();
        resolve(parsed);
      });
      socket.on('error', (error) => {
        clearTimeout(timer);
        reject(error);
      });
    });

    assert.equal(response.status, 200, `the bridge must answer 200: ${response.body}`);
    const body = JSON.parse(response.body);
    assert.equal(body.ok, true);
    assert.equal(body.name, 'dsh-harmony-bridge');
  } finally {
    await client.stop();
    await fake.close();
    await bridge.close();
  }
});

test('relay: the device dials in with wss and the certificate is verified', async () => {
  const bridge = await startBridge();
  const fake = await startFakeTlsRelay();
  fake.relay.deviceTarget = `127.0.0.1:${bridge.port}`;
  const phonePort = await fake.relay.startPhone();
  const ca = fs.readFileSync(new URL('./fixtures/relay-test-cert.pem', import.meta.url));
  const { client, logs } = startRelayClient(fake.url, bridge.port, { ca });
  try {
    await client.waitForConnection(3000);
    assert.equal(client.connected, true, 'the device must be connected over TLS');

    // The fingerprint of the relay certificate is what the phone pins.
    const certificate = client.certificate();
    assert.notEqual(certificate, null, 'the certificate of the relay must be known');
    assert.match(certificate.fingerprint, /^[0-9A-F]{64}$/u, 'the fingerprint must be the SHA256 of the certificate');
    assert.match(certificate.subject, /dsh-harmony-test-relay/u);

    // A request travels through the encrypted connection.
    const request = [
      'GET /api/v1/health HTTP/1.1',
      `Host: 127.0.0.1:${bridge.port}`,
      `Authorization: Bearer ${bridge.state.token}`,
      'Connection: close',
      '',
      '',
    ].join('\r\n');
    const response = await new Promise((resolve, reject) => {
      const socket = net.connect({ host: '127.0.0.1', port: phonePort }, () => socket.write(request));
      let buffer = Buffer.alloc(0);
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new Error('the phone request timed out'));
      }, 10000);
      socket.on('data', (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        const parsed = parseHttpResponse(buffer);
        if (parsed === null) return;
        clearTimeout(timer);
        socket.end();
        resolve(parsed);
      });
      socket.on('error', (error) => {
        clearTimeout(timer);
        reject(error);
      });
    });
    assert.equal(response.status, 200, `the bridge must answer 200: ${response.body}`);
  } finally {
    await client.stop();
    await fake.close();
    await bridge.close();
  }
});

test('relay: a self signed certificate without the trust anchor is refused', async () => {
  const fake = await startFakeTlsRelay();
  const { client, logs } = startRelayClient(fake.url, 8787);
  try {
    // The certificate is self signed: without --relay-ca the handshake must fail.
    const connected = await client.waitForConnection(1200);
    assert.equal(connected, false, 'the device must not connect to an untrusted certificate');
    assert.equal(client.connected, false);
    assert.ok(
      logs.some((line) => /certificate|self.signed|unable to verify|UNABLE_TO_VERIFY|DEPTH_ZERO/i.test(line)),
      `the log must mention the certificate problem: ${logs.join(' | ')}`,
    );
  } finally {
    await client.stop();
    await fake.close();
  }
});

await run();
