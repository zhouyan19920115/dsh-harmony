// Zero-dependency test runner for the DSH Harmony cloud relay.
//
// Run with `node test/run.js` (or `npm test`). Every test uses node:assert only; the relay is
// exercised over real HTTP and a real WebSocket so the wire contract of docs/RELAY.md is
// covered end to end.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import https from 'node:https';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { FRAME, FrameParser, decodeFrame, encodeFrame } from '../src/frames.js';
import { constantTimeEquals, loadDeviceRegistry } from '../src/devices.js';
import {
  addDevice,
  createAccount,
  findAccount,
  findDevice,
  listDevices,
  loadAccountRegistry,
  saveAccountRegistry,
} from '../src/accounts.js';
import { RequestRewriter, splitDeviceTarget, stripDevicePrefix } from '../src/http-rewriter.js';
import { RelayServer, PHONE_ONLINE_WINDOW_MS, createTimers } from '../src/server.js';
import { parseArgs, phoneUrl } from '../src/cli.js';
import { FakeDevice, WsClient, freePort, rawRequest, startFakeBridge, waitUntil } from './helpers.js';

/* ------------------------------------------------------------------ tiny test runner */

const tests = [];
let only = null;

function test(name, fn) {
  tests.push({ name, fn });
}
function testOnly(name, fn) {
  only = name;
  tests.push({ name, fn });
}

async function run() {
  let passed = 0;
  const failures = [];
  for (const entry of tests) {
    if (only !== null && entry.name !== only) continue;
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
  // The suite must not keep the process alive: a relay that was left listening would hang the
  // test run. The diagnostic shows what is still open.
  if (typeof process.getActiveResourcesInfo === 'function') {
    const open = process.getActiveResourcesInfo()
      .filter((kind) => kind !== 'PipeWrap' && kind !== 'SimpleShutdownWrap');
    if (open.length > 0) {
      process.stdout.write(`       (still open: ${open.join(', ')})\n`);
    }
  }
  process.exit(process.exitCode ?? 0);
}

/* ----------------------------------------------------------------------- helpers */

/** Start a relay with a fake device registry. */
async function startRelay(devices, { bridgePort = 8787, timers: timerOptions = {}, deviceRateLimit } = {}) {
  const port = await freePort();
  const registry = new Map(devices.map((device) => [
    device.id,
    { id: device.id, name: device.name ?? device.id, token: device.token, port: device.port ?? bridgePort },
  ]));
  const relay = new RelayServer({
    devices: registry,
    bridgePort,
    log: () => {},
    timers: createTimers({ openTimeoutMs: 4000, streamIdleMs: 30_000, ...timerOptions }),
    ...(deviceRateLimit === undefined ? {} : { deviceRateLimit }),
  });
  await relay.listen({ port, host: '127.0.0.1' });
  return {
    port,
    relay,
    async close() {
      await relay.close();
    },
  };
}

/** Connect a fake device to a relay. */
async function connectDevice(relayPort, {  id = 'dev-1',
  token = 'token-1',
  bridgePort,
  accountId = null,
  accountToken = null,
  name = undefined,
  bridgeToken = undefined,
}) {
  const params = new URLSearchParams({ token, deviceId: id });
  if (accountId) params.set('accountId', accountId);
  if (accountToken) params.set('accountToken', accountToken);
  const url = `ws://127.0.0.1:${relayPort}/bridge?${params.toString()}`;
  const device = new FakeDevice({
    url,
    deviceId: id,
    token,
    ...(name ? { name } : {}),
    ...(bridgeToken ? { bridgeToken } : {}),
  });
  await device.connect();
  return device;
}

/**
 * Close a fake device with everything it opened.
 *
 * The device opens a TCP connection to the fake bridge for every stream. Those sockets keep
 * the event loop of the test process alive, so they have to go with the device.
 */
function closeDevice(device) {
  if (!device) return;
  for (const socket of device.sockets?.values?.() ?? []) socket.destroy();
  device.close?.();
}

/** Start a relay that knows accounts (the registry of {@link twoAccountRegistry}). */
async function startAccountRelay(registry, { bridgePort = 8787, timers: timerOptions = {}, allowJoin = true } = {}) {
  const port = await freePort();
  const relay = new RelayServer({
    registry,
    bridgePort,
    log: () => {},
    timers: createTimers({ openTimeoutMs: 4000, streamIdleMs: 30_000, ...timerOptions }),
    allowJoin,
  });
  await relay.listen({ port, host: '127.0.0.1' });
  return {
    port,
    relay,
    async close() {
      await relay.close();
    },
  };
}

/** A registry with two accounts, each of them with one desktop. */
function twoAccountRegistry(bridgePort = 8787) {
  const registry = { accounts: new Map() };
  createAccount(registry, { id: 'acc-a', name: 'account a', token: 'a'.repeat(64) });
  createAccount(registry, { id: 'acc-b', name: 'account b', token: 'b'.repeat(64) });
  addDevice(registry, 'acc-a', { id: 'dev-a', name: 'desktop a', token: 'token-a', port: bridgePort });
  addDevice(registry, 'acc-b', { id: 'dev-b', name: 'desktop b', token: 'token-b', port: bridgePort });
  return registry;
}

/** The JSON body of a raw HTTP answer. */
function jsonBody(response) {
  const index = response.indexOf('\r\n\r\n');
  assert.notEqual(index, -1, `the answer has no head: ${response}`);
  return JSON.parse(response.slice(index + 4));
}

/**
 * The JSON body of a raw HTTP answer, decoded as UTF-8.
 *
 * {@link rawRequest} collects the answer as latin1 bytes, so a body with a non ascii name
 * (a phone announces "我的手机") has to be decoded again before it can be compared.
 */
function utf8JsonBody(response) {
  const index = response.indexOf('\r\n\r\n');
  assert.notEqual(index, -1, `the answer has no head: ${response}`);
  return JSON.parse(Buffer.from(response.slice(index + 4), 'latin1').toString('utf8'));
}

/** Read HTTP responses (content length framed) from a raw socket. */
function responseReader(socket) {
  let buffer = Buffer.alloc(0);
  const waiters = [];
  socket.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      const index = buffer.indexOf('\r\n\r\n');
      if (index === -1) break;
      const head = buffer.subarray(0, index).toString('latin1');
      const match = /content-length:\s*(\d+)/iu.exec(head);
      const length = match ? Number(match[1]) : 0;
      if (buffer.length < index + 4 + length) break;
      const body = buffer.subarray(index + 4, index + 4 + length).toString('utf8');
      buffer = buffer.subarray(index + 4 + length);
      const waiter = waiters.shift();
      if (waiter) waiter({ head, body });
    }
  });
  return () => new Promise((resolve) => waiters.push(resolve));
}

/**
 * Send a JSON POST to the relay and collect the raw answer.
 *
 * @param {number} port the port of the relay
 * @param {string} path the request target
 * @param {{token?: string, body?: unknown}} options the account token and the body
 */
function postJson(port, path, { token, body } = {}) {
  const payload = body === undefined ? '' : JSON.stringify(body);
  const head = [
    `POST ${path} HTTP/1.1`,
    'Host: phone.local',
    ...(body === undefined ? [] : ['Content-Type: application/json']),
    ...(body === undefined ? [] : [`Content-Length: ${Buffer.byteLength(payload)}`]),
    ...(token ? [`Authorization: Bearer ${token}`] : []),
    'Connection: close',
    '',
    payload,
  ].join('\r\n');
  return rawRequest(port, head);
}

/** Read the presence of an account (the device list of the relay). */
async function presenceOf(port, accountId, accountToken) {
  const response = await rawRequest(port, [
    `GET /_relay/accounts/${accountId}/devices?accountToken=${accountToken} HTTP/1.1`,
    'Host: phone.local',
    'Connection: close',
    '',
    '',
  ].join('\r\n'));
  assert.match(response, /^HTTP\/1\.1 200/u, `unexpected answer: ${response}`);
  return utf8JsonBody(response).devices;
}

/* ------------------------------------------------------------------------- tests */

test('frames: a frame survives the encode/decode round trip', () => {
  const cases = [
    { type: FRAME.OPEN, payload: Buffer.from('127.0.0.1:8787', 'utf8'), streamId: 1 },
    { type: FRAME.OPEN_OK, payload: Buffer.alloc(0), streamId: 7 },
    { type: FRAME.OPEN_ERR, payload: Buffer.from('connection refused', 'utf8'), streamId: 7 },
    { type: FRAME.DATA, payload: Buffer.from([0, 1, 2, 253, 254, 255]), streamId: 65535 },
    { type: FRAME.CLOSE, payload: Buffer.alloc(0), streamId: 2 },
    { type: FRAME.HELLO, payload: Buffer.from('{"deviceId":"dev-1"}', 'utf8'), streamId: 0 },
    { type: FRAME.HELLO_OK, payload: Buffer.from('{"relay":"dsh-harmony-relay"}', 'utf8'), streamId: 0 },
    { type: FRAME.PING, payload: Buffer.alloc(0), streamId: 0 },
    { type: FRAME.PONG, payload: Buffer.alloc(0), streamId: 0 },
  ];
  for (const entry of cases) {
    const frame = encodeFrame(entry.type, entry.payload, entry.streamId);
    assert.equal(frame.length, 9 + entry.payload.length, 'the frame header is 9 bytes');
    assert.equal(frame.readUInt32BE(0), entry.streamId, 'the stream id is 4 bytes big endian');
    assert.equal(frame.readUInt8(4), entry.type, 'the type byte sits between stream id and length');
    assert.equal(frame.readUInt32BE(5), entry.payload.length, 'the length is 4 bytes big endian');
    const decoded = decodeFrame(frame);
    assert.equal(decoded.type, entry.type);
    assert.equal(decoded.streamId, entry.streamId);
    assert.deepEqual(decoded.payload, entry.payload);
  }
});

test('frames: the parser reassembles a frame that arrives in pieces', () => {
  const parser = new FrameParser();
  const first = encodeFrame(FRAME.DATA, Buffer.from('hello ', 'utf8'), 3);
  const second = encodeFrame(FRAME.DATA, Buffer.from('world', 'utf8'), 3);
  const wire = Buffer.concat([first, second]);

  const frames = [];
  for (let offset = 0; offset < wire.length; offset += 3) {
    frames.push(...parser.push(wire.subarray(offset, offset + 3)));
  }
  assert.equal(frames.length, 2);
  assert.equal(frames[0].streamId, 3);
  assert.equal(frames[0].payload.toString('utf8'), 'hello ');
  assert.equal(frames[1].payload.toString('utf8'), 'world');
});

test('frames: a frame that announces too much is rejected', () => {
  const parser = new FrameParser({ maxPayload: 16 });
  const frame = Buffer.alloc(9);
  frame.writeUInt32BE(1, 0);
  frame.writeUInt8(FRAME.DATA, 4);
  frame.writeUInt32BE(1024, 5);
  assert.throws(() => parser.push(frame), /limit/u);
});

test('devices: the token comparison is constant time and rejects a wrong token', () => {
  assert.equal(constantTimeEquals('abc', 'abc'), true);
  assert.equal(constantTimeEquals('abc', 'abd'), false);
  assert.equal(constantTimeEquals('abc', 'abcd'), false);
  assert.equal(constantTimeEquals('', ''), true);
});

test('http-rewriter: the device prefix is removed and the rest of the bytes stay untouched', () => {
  const request = [
    'POST /dev-8f2a/api/v1/sessions?x=1 HTTP/1.1',
    'Host: relay.example.com',
    'Authorization: Bearer secret',
    'Content-Type: application/json',
    'Content-Length: 7',
    '',
    '{"a":1}',
  ].join('\r\n');

  const rewriter = new RequestRewriter({ prefix: '/dev-8f2a' });
  const out = rewriter.push(Buffer.from(request, 'utf8')).toString('utf8');
  assert.ok(out.startsWith('POST /api/v1/sessions?x=1 HTTP/1.1\r\n'), `unexpected request line: ${out.slice(0, 80)}`);
  assert.ok(out.includes('Authorization: Bearer secret\r\n'), 'the Authorization header must survive');
  assert.ok(out.endsWith('{"a":1}'), 'the body must survive');
  assert.equal(rewriter.parsedRequests.length, 1);
  assert.equal(rewriter.parsedRequests[0].method, 'POST');
  assert.equal(rewriter.parsedRequests[0].target, '/api/v1/sessions?x=1');
});

test('http-rewriter: a chunked body is forwarded with its original framing', () => {
  const request = [
    'POST /dev-8f2a/api/v1/upload HTTP/1.1',
    'Host: relay.example.com',
    'Transfer-Encoding: chunked',
    '',
    '5',
    'hello',
    '6',
    ' world',
    '0',
    '',
    '',
  ].join('\r\n');

  const rewriter = new RequestRewriter({ prefix: '/dev-8f2a' });
  const out = rewriter.push(Buffer.from(request, 'utf8')).toString('utf8');
  assert.ok(out.startsWith('POST /api/v1/upload HTTP/1.1\r\n'));
  assert.ok(out.includes('Transfer-Encoding: chunked\r\n'), 'the chunked header must survive');
  assert.ok(out.includes('5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n'), `the chunk framing must survive: ${JSON.stringify(out)}`);
});

test('http-rewriter: the request target is split into the device id and the path', () => {
  assert.deepEqual(splitDeviceTarget('/dev-8f2a/api/v1/health'), { deviceId: 'dev-8f2a', rest: '/api/v1/health' });
  assert.deepEqual(splitDeviceTarget('/dev-8f2a/ws?token=abc'), { deviceId: 'dev-8f2a', rest: '/ws?token=abc' });
  assert.deepEqual(splitDeviceTarget('/dev-8f2a'), { deviceId: 'dev-8f2a', rest: '/' });
  assert.equal(stripDevicePrefix('/dev-8f2a/api', '/dev-8f2a'), '/api');
  assert.equal(stripDevicePrefix('/dev-8f2a-other/api', '/dev-8f2a'), null);
});

test('relay: a device with a wrong token is rejected with 401', async () => {
  const relay = await startRelay([{ id: 'dev-1', token: 'the-right-token' }]);
  try {
    const client = new WsClient(`ws://127.0.0.1:${relay.port}/bridge?token=wrong&deviceId=dev-1`);
    await assert.rejects(() => client.connect(), /401/u, 'the relay must answer 401');

    const unknown = new WsClient(`ws://127.0.0.1:${relay.port}/bridge?token=the-right-token&deviceId=dev-nope`);
    await assert.rejects(() => unknown.connect(), /401/u, 'an unknown device must answer 401');

    const noToken = new WsClient(`ws://127.0.0.1:${relay.port}/bridge?deviceId=dev-1`);
    await assert.rejects(() => noToken.connect(), /401/u, 'a device without a token must answer 401');

    const noDevice = new WsClient(`ws://127.0.0.1:${relay.port}/bridge?token=the-right-token`);
    await assert.rejects(() => noDevice.connect(), /401/u, 'a device without an id must answer 401');
  } finally {
    await relay.close();
  }
});

test('relay: too many failed device attempts are answered with 429', async () => {
  const relay = await startRelay([{ id: 'dev-1', token: 'the-right-token' }], { deviceRateLimit: 3 });
  try {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const client = new WsClient(`ws://127.0.0.1:${relay.port}/bridge?token=wrong&deviceId=dev-1`);
      await assert.rejects(() => client.connect(), /401/u, `the attempt ${attempt + 1} must answer 401`);
    }
    const limited = new WsClient(`ws://127.0.0.1:${relay.port}/bridge?token=wrong&deviceId=dev-1`);
    await assert.rejects(() => limited.connect(), /429/u, 'the relay must answer 429 when the budget is gone');

    // The right token does not help while the address is limited.
    const right = new WsClient(`ws://127.0.0.1:${relay.port}/bridge?token=the-right-token&deviceId=dev-1`);
    await assert.rejects(() => right.connect(), /429/u, 'the rate limit must hold for the address');
  } finally {
    await relay.close();
  }
});

test('relay: a revoked device cannot come back with its token', async () => {
  const registry = { accounts: new Map() };
  createAccount(registry, { id: 'acc-1', name: 'test', token: 'account-token' });
  addDevice(registry, 'acc-1', { id: 'dev-1', name: 'dev-1', token: 'device-token', port: 8787 });
  const port = await freePort();
  const relay = new RelayServer({ registry, bridgePort: 8787, log: () => {} });
  await relay.listen({ port, host: '127.0.0.1' });
  let device = null;
  try {
    device = await connectDevice(port, { id: 'dev-1', token: 'device-token', accountId: 'acc-1' });
    assert.equal(relay.sessions.size, 1, 'the device must be online');

    const response = await rawRequest(port, [
      'DELETE /_relay/accounts/acc-1/devices/dev-1 HTTP/1.1',
      'Host: phone.local',
      'Authorization: Bearer account-token',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    assert.match(response, /^HTTP\/1\.1 200/u, `unexpected response: ${response}`);

    // The session is closed and the token does not work any more.
    await waitUntil(() => relay.sessions.size === 0, { timeoutMs: 3000 });
    const again = new WsClient(`ws://127.0.0.1:${port}/bridge?token=device-token&deviceId=dev-1&accountId=acc-1`);
    await assert.rejects(() => again.connect(), /401/u, 'a revoked device must not be able to connect');
  } finally {
    device?.close();
    await relay.close();
  }
});

test('relay: the phone request reaches the device with the Authorization header intact', async () => {
  const bridge = await startFakeBridge();
  const relay = await startRelay([{ id: 'dev-1', token: 'token-1', port: bridge.port }]);
  const device = await connectDevice(relay.port, { id: 'dev-1', token: 'token-1' });
  try {
    const response = await rawRequest(relay.port, [
      'GET /dev-1/api/v1/health HTTP/1.1',
      'Host: phone.local',
      'Authorization: Bearer the-bridge-token',
      'X-Test: 42',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));

    assert.match(response, /^HTTP\/1\.1 200/u, `unexpected response: ${response}`);
    assert.equal(bridge.requests.length, 1, 'the device must receive exactly one request');
    const received = bridge.requests[0];
    assert.equal(received.method, 'GET');
    assert.equal(received.url, '/api/v1/health', 'the device prefix must be removed');
    assert.equal(received.headers.authorization, 'Bearer the-bridge-token', 'the Authorization header must be forwarded');
    assert.equal(received.headers['x-test'], '42', 'the other headers must be forwarded');
    assert.equal(device.targets[0], `127.0.0.1:${bridge.port}`, 'the device must open the bridge of the desktop');
  } finally {
    device.close();
    await relay.close();
    await bridge.close();
  }
});

test('relay: the bytes flow in both directions and CLOSE ends the stream', async () => {
  const bridge = await startFakeBridge();
  const relay = await startRelay([{ id: 'dev-1', token: 'token-1', port: bridge.port }]);
  const device = await connectDevice(relay.port, { id: 'dev-1', token: 'token-1' });
  try {
    const response = await rawRequest(relay.port, [
      'POST /dev-1/api/v1/echo HTTP/1.1',
      'Host: phone.local',
      'Authorization: Bearer the-bridge-token',
      'Content-Type: text/plain',
      'Content-Length: 11',
      'Connection: close',
      '',
      'hello relay',
    ].join('\r\n'));

    assert.match(response, /^HTTP\/1\.1 200/u, `unexpected response: ${response}`);
    assert.ok(response.includes('hello relay'), 'the request body must reach the device and come back');
    assert.equal(bridge.requests[0].body.toString('utf8'), 'hello relay');

    // The device closed the connection, so the relay has to close the stream as well.
    await waitUntil(() => device.closedStreams.length > 0, { timeoutMs: 3000 });
  } finally {
    device.close();
    await relay.close();
    await bridge.close();
  }
});

test('relay: a keep alive connection carries several requests', async () => {
  const bridge = await startFakeBridge();
  const relay = await startRelay([{ id: 'dev-1', token: 'token-1', port: bridge.port }]);
  const device = await connectDevice(relay.port, { id: 'dev-1', token: 'token-1' });
  try {
    const socket = net.connect({ host: '127.0.0.1', port: relay.port });
    await new Promise((resolve) => socket.once('connect', resolve));
    const nextResponse = responseReader(socket);

    socket.write([
      'GET /dev-1/api/v1/first HTTP/1.1',
      'Host: phone.local',
      'Authorization: Bearer one',
      '',
      '',
    ].join('\r\n'));
    const first = await nextResponse();
    assert.match(first.head, /^HTTP\/1\.1 200/u);

    socket.write([
      'GET /dev-1/api/v1/second HTTP/1.1',
      'Host: phone.local',
      'Authorization: Bearer two',
      '',
      '',
    ].join('\r\n'));
    const second = await nextResponse();
    assert.match(second.head, /^HTTP\/1\.1 200/u);

    assert.equal(bridge.requests.length, 2, 'both requests must reach the device');
    assert.equal(bridge.requests[0].url, '/api/v1/first');
    assert.equal(bridge.requests[1].url, '/api/v1/second', 'the prefix must be removed from every request');
    assert.equal(bridge.requests[1].headers.authorization, 'Bearer two');
    socket.destroy();
  } finally {
    device.close();
    await relay.close();
    await bridge.close();
  }
});

test('relay: a relay owned request with a body does not break the next request', async () => {
  // 这是线上踩过的坑: 桌面端用 keep-alive 的连接问中继 `/_relay/accounts/…/heartbeat`
  // (请求体是 `{}`), 中继自己回答它, 于是要把它从这条连接上丢干净。
  // 以前丢的时候: 请求体留在了缓冲区里, 而"还要丢多少字节"却按**整个**请求体算 ⇒
  // 下一个请求的头被吃掉两个字节, 剩下的字节被当成请求头转发给设备 ⇒
  // 设备的 HTTP 解析器报 "Invalid method encountered", 回一个空的 400 ⇒
  // 手机上看到的就是莫名其妙的 HTTP 400 和 "Invalid Token"。
  const bridge = await startFakeBridge();
  const relay = await startRelay([{ id: 'dev-1', token: 'token-1', port: bridge.port }]);
  const device = await connectDevice(relay.port, { id: 'dev-1', token: 'token-1' });
  try {
    const socket = net.connect({ host: '127.0.0.1', port: relay.port });
    await new Promise((resolve) => socket.once('connect', resolve));
    const nextResponse = responseReader(socket);

    // 1) 中继自己的端点, 带一个两字节的请求体。
    socket.write([
      'POST /_relay/health HTTP/1.1',
      'Host: phone.local',
      'Content-Type: application/json',
      'Content-Length: 2',
      '',
      '{}',
    ].join('\r\n'));
    const relayAnswer = await nextResponse();
    assert.match(relayAnswer.head, /^HTTP\/1\.1 200/u, `the relay must answer its own endpoint: ${relayAnswer.head}`);

    // 2) 同一条连接上, 接着问设备。
    socket.write([
      'POST /dev-1/api/v1/phone/heartbeat HTTP/1.1',
      'Host: phone.local',
      'Authorization: Bearer the-bridge-token',
      'Content-Type: application/json',
      'Content-Length: 7',
      '',
      '{"a":1}',
    ].join('\r\n'));
    const deviceAnswer = await nextResponse();
    assert.match(deviceAnswer.head, /^HTTP\/1\.1 200/u, `the device request must not be broken: ${deviceAnswer.head}`);

    assert.equal(bridge.requests.length, 1, 'the device must receive exactly the one device request');
    assert.equal(bridge.requests[0].method, 'POST');
    assert.equal(bridge.requests[0].url, '/api/v1/phone/heartbeat', 'the prefix must be removed');
    assert.equal(bridge.requests[0].body.toString('utf8'), '{"a":1}', 'the body must arrive byte for byte');
    socket.destroy();
  } finally {
    device.close();
    await relay.close();
    await bridge.close();
  }
});

test('relay: a phone WebSocket upgrade is relayed raw', async () => {
  const bridge = await startFakeBridge();
  const relay = await startRelay([{ id: 'dev-1', token: 'token-1', port: bridge.port }]);
  const device = await connectDevice(relay.port, { id: 'dev-1', token: 'token-1', bridgeToken: 'the-bridge-token' });
  try {
    const phone = new WsClient(`ws://127.0.0.1:${relay.port}/dev-1/ws?token=the-bridge-token`);
    await phone.connect({ timeoutMs: 5000 });

    assert.equal(bridge.upgrades.length, 1, 'the device must receive the upgrade request');
    assert.equal(bridge.upgrades[0].url, '/ws?token=the-bridge-token', 'the device prefix must be removed');
    assert.equal(bridge.upgrades[0].headers['sec-websocket-version'], '13', 'the handshake headers must be forwarded');

    const echoed = new Promise((resolve) => phone.once('binary', resolve));
    phone.sendBinary(Buffer.from('ping through the relay', 'utf8'));
    const answer = await echoed;
    assert.equal(answer.toString('utf8'), 'ping through the relay', 'the frames must travel through the relay');
    phone.close();
  } finally {
    device.close();
    await relay.close();
    await bridge.close();
  }
});

/** Wait a moment (a test needs a little time to let something happen). */
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test('relay: a phone without a credential does not reach the device', async () => {
  const bridge = await startFakeBridge();
  const relay = await startRelay([{ id: 'dev-1', token: 'token-1', port: bridge.port }]);
  const device = await connectDevice(relay.port, { id: 'dev-1', token: 'token-1', bridgeToken: 'the-bridge-token' });
  try {
    // The phone offers nothing: it has to authenticate itself with its first frame.
    const phone = new WsClient(`ws://127.0.0.1:${relay.port}/dev-1/ws`);
    await phone.connect({ timeoutMs: 5000 });
    // The first frame is not the authentication: the relay closes the connection.
    const closed = new Promise((resolve) => phone.once('close', resolve));
    phone.sendText(JSON.stringify({ type: 'hello', data: {} }));
    await closed;

    // The frames of a phone that has not authenticated itself never reach the device.
    const second = new WsClient(`ws://127.0.0.1:${relay.port}/dev-1/ws`);
    await second.connect({ timeoutMs: 5000 });
    const echoed = new Promise((resolve) => second.once('binary', resolve));
    second.sendBinary(Buffer.from('a secret', 'utf8'));
    const answer = await Promise.race([
      echoed.then(() => 'reached the device'),
      sleep(300).then(() => 'held back'),
    ]);
    assert.equal(answer, 'held back', 'the frames of an unauthenticated phone must not reach the device');
    second.close();
  } finally {
    device.close();
    await relay.close();
    await bridge.close();
  }
});

test('relay: a phone with a wrong credential is refused', async () => {
  const bridge = await startFakeBridge();
  const relay = await startRelay([{ id: 'dev-1', token: 'token-1', port: bridge.port }]);
  const device = await connectDevice(relay.port, { id: 'dev-1', token: 'token-1', bridgeToken: 'the-bridge-token' });
  try {
    // A wrong token in the handshake is refused right away.
    const wrong = new WsClient(`ws://127.0.0.1:${relay.port}/dev-1/ws?token=not-the-token`);
    await assert.rejects(() => wrong.connect({ timeoutMs: 5000 }), /401/u, 'a wrong token must be refused');

    // A wrong token in the first frame is refused as well.
    const phone = new WsClient(`ws://127.0.0.1:${relay.port}/dev-1/ws`);
    await phone.connect({ timeoutMs: 5000 });
    const closed = new Promise((resolve) => phone.once('close', resolve));
    phone.sendText(JSON.stringify({ type: 'auth', token: 'not-the-token' }));
    await closed;
  } finally {
    device.close();
    await relay.close();
    await bridge.close();
  }
});

test('relay: a phone with the right credential reaches the device', async () => {
  const bridge = await startFakeBridge();
  const relay = await startRelay([{ id: 'dev-1', token: 'token-1', port: bridge.port }]);
  const device = await connectDevice(relay.port, { id: 'dev-1', token: 'token-1', bridgeToken: 'the-bridge-token' });
  try {
    // The token of the handshake is enough.
    const phone = new WsClient(`ws://127.0.0.1:${relay.port}/dev-1/ws?token=the-bridge-token`);
    await phone.connect({ timeoutMs: 5000 });
    const echoed = new Promise((resolve) => phone.once('binary', resolve));
    phone.sendBinary(Buffer.from('hello device', 'utf8'));
    const answer = await echoed;
    assert.equal(answer.toString('utf8'), 'hello device', 'the frames of an authenticated phone reach the device');
    phone.close();

    // The phone may also authenticate with its first frame (that is what the phone does).
    const other = new WsClient(`ws://127.0.0.1:${relay.port}/dev-1/ws`);
    await other.connect({ timeoutMs: 5000 });
    other.sendText(JSON.stringify({ type: 'auth', token: 'the-bridge-token' }));
    const echoedOther = new Promise((resolve) => other.once('binary', resolve));
    other.sendBinary(Buffer.from('hello again', 'utf8'));
    const answerOther = await echoedOther;
    assert.equal(answerOther.toString('utf8'), 'hello again', 'the first frame authenticates the phone');
    other.close();
  } finally {
    device.close();
    await relay.close();
    await bridge.close();
  }
});

test('relay: a phone of another account is refused', async () => {
  const bridge = await startFakeBridge();
  const relay = await startAccountRelay(twoAccountRegistry(bridge.port));
  const device = await connectDevice(relay.port, {
    id: 'dev-a',
    token: 'token-a',
    accountId: 'acc-a',
    bridgeToken: 'the-bridge-token',
  });
  try {
    // The token of account b does not open the device of account a.
    const foreign = new WsClient(`ws://127.0.0.1:${relay.port}/acc-a/dev-a/ws?token=${'b'.repeat(64)}`);
    await assert.rejects(() => foreign.connect({ timeoutMs: 5000 }), /401/u, 'the token of another account must be refused');

    // The device token of another device is refused as well.
    const otherDevice = new WsClient(`ws://127.0.0.1:${relay.port}/acc-a/dev-a/ws?token=token-b`);
    await assert.rejects(() => otherDevice.connect({ timeoutMs: 5000 }), /401/u, 'the token of another device must be refused');

    // The own account token works.
    const own = new WsClient(`ws://127.0.0.1:${relay.port}/acc-a/dev-a/ws?token=${'a'.repeat(64)}`);
    await own.connect({ timeoutMs: 5000 });
    own.close();
  } finally {
    device.close();
    await relay.close();
    await bridge.close();
  }
});

test('relay: an unknown device answers 404 and an offline device answers 503', async () => {
  const relay = await startRelay([{ id: 'dev-1', token: 'token-1' }]);
  try {
    const unknown = await rawRequest(relay.port, [
      'GET /dev-nope/api/v1/health HTTP/1.1',
      'Host: phone.local',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    assert.match(unknown, /^HTTP\/1\.1 404/u, `unexpected answer: ${unknown}`);

    const offline = await rawRequest(relay.port, [
      'GET /dev-1/api/v1/health HTTP/1.1',
      'Host: phone.local',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    assert.match(offline, /^HTTP\/1\.1 503/u, `unexpected answer: ${offline}`);

    const upgrade = new WsClient(`ws://127.0.0.1:${relay.port}/dev-1/ws?token=abc`);
    await assert.rejects(() => upgrade.connect(), /503/u, 'an upgrade of an offline device must answer 503');
  } finally {
    await relay.close();
  }
});

test('relay: the heartbeat pings the device and a silent device is dropped', async () => {
  const bridge = await startFakeBridge();
  const relay = await startRelay(
    [{ id: 'dev-1', token: 'token-1', port: bridge.port }],
    { timers: { pingIntervalMs: 80, pongTimeoutMs: 400 } },
  );
  const device = await connectDevice(relay.port, { id: 'dev-1', token: 'token-1' });
  try {
    await waitUntil(() => device.frames.some((frame) => frame.type === FRAME.PING), { timeoutMs: 3000 });
    const pong = device.frames.find((frame) => frame.type === FRAME.PING);
    assert.equal(pong.streamId, 0, 'a heartbeat is a control frame without a stream');
    assert.equal(pong.payload.length, 0, 'a heartbeat has no payload');
    assert.ok(relay.relay.sessions.has('dev-1'), 'the device must stay online while it answers');

    // A device that stops answering the heartbeat is dropped.
    const silent = new FakeDevice({
      url: `ws://127.0.0.1:${relay.port}/bridge?token=token-1&deviceId=dev-1`,
      deviceId: 'dev-1',
      token: 'token-1',
      answerPing: false,
    });
    await silent.connect();
    await waitUntil(() => !relay.relay.sessions.has('dev-1'), { timeoutMs: 3000 });
    assert.equal(relay.relay.sessions.has('dev-1'), false, 'a silent device must be dropped');
    silent.close();
  } finally {
    device.close();
    await relay.close();
    await bridge.close();
  }
});

test('relay: a device that cannot open the connection answers 502', async () => {
  const relay = await startRelay([{ id: 'dev-1', token: 'token-1' }]);
  const device = new FakeDevice({
    url: `ws://127.0.0.1:${relay.port}/bridge?token=token-1&deviceId=dev-1`,
    deviceId: 'dev-1',
    token: 'token-1',
    openError: 'connect ECONNREFUSED 127.0.0.1:8787',
    bridgeToken: 'abc',
  });
  await device.connect();
  try {
    const response = await rawRequest(relay.port, [
      'GET /dev-1/api/v1/health HTTP/1.1',
      'Host: phone.local',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    assert.match(response, /^HTTP\/1\.1 502/u, `unexpected answer: ${response}`);
    assert.ok(response.includes('ECONNREFUSED'), 'the error of the device must be reported');

    // The same for a WebSocket upgrade: the answer goes into the raw socket.
    const upgrade = new WsClient(`ws://127.0.0.1:${relay.port}/dev-1/ws?token=abc`);
    await assert.rejects(() => upgrade.connect(), /502/u, 'an upgrade of a broken device must answer 502');
  } finally {
    device.close();
    await relay.close();
  }
});

test('relay: the TLS listener answers a wss handshake and an https request', async () => {
  const port = await freePort();
  const tlsPort = await freePort();
  const cert = fileURLToPath(new URL('./fixtures/relay-test-cert.pem', import.meta.url));
  const key = fileURLToPath(new URL('./fixtures/relay-test-key.pem', import.meta.url));
  const ca = fs.readFileSync(cert);
  const relay = new RelayServer({
    devices: new Map([['dev-1', { id: 'dev-1', name: 'dev-1', token: 'token-1', port: 8787 }]]),
    bridgePort: 8787,
    log: () => {},
  });
  await relay.listen({ port, host: '127.0.0.1', tlsPort, tlsCert: cert, tlsKey: key });
  let device = null;
  try {
    assert.equal(relay.tlsPort, tlsPort, 'the TLS listener must be up');

    // The desktop dials in with wss:// and gets its session.
    device = new FakeDevice({
      url: `wss://127.0.0.1:${tlsPort}/bridge?token=token-1&deviceId=dev-1`,
      deviceId: 'dev-1',
      token: 'token-1',
    });
    await device.connect();
    assert.ok(relay.sessions.has('dev-1'), 'the device must be online over TLS');

    // The phone reaches the relay over https:// and the certificate is verified.
    const answer = await new Promise((resolve, reject) => {
      const request = https.request({
        host: '127.0.0.1',
        port: tlsPort,
        path: '/_relay/health',
        method: 'GET',
        ca,
        headers: { 'Host': '127.0.0.1' },
      }, (response) => {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () => resolve({ status: response.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
      });
      request.on('error', reject);
      request.end();
    });
    assert.equal(answer.status, 200, `the relay must answer 200: ${answer.body}`);
    assert.equal(JSON.parse(answer.body).status, 'ok');
  } finally {
    device?.close();
    await relay.close();
  }
});

test('cli: the argument parser understands the documented flags', () => {
  const options = parseArgs([
    '--port', '9000',
    '--host', '127.0.0.1',
    '--device', 'relay/devices.json',
    '--tls-port', '8443',
    '--tls-cert', 'cert.pem',
    '--tls-key', 'key.pem',
    '--public-url', 'https://relay.example.com:8443',
  ]);
  assert.equal(options.port, 9000);
  assert.equal(options.host, '127.0.0.1');
  assert.equal(options.device, 'relay/devices.json');
  assert.equal(options.tlsPort, 8443);
  assert.equal(options.tlsCert, 'cert.pem');
  assert.equal(options.tlsKey, 'key.pem');
  assert.equal(options.publicUrl, 'https://relay.example.com:8443');
  assert.throws(() => parseArgs(['--port', 'abc']), /invalid --port/u);
  assert.throws(() => parseArgs(['--tls-port', '8443']), /--tls-cert/u);
  assert.equal(phoneUrl('https://relay.example.com:8443', 'dev-8f2a'), 'https://relay.example.com:8443/dev-8f2a');
});

test('devices: the shipped registry holds one example device', () => {
  // The shipped file uses the account format (the flat one is migrated into an account).
  const registry = loadAccountRegistry(fileURLToPath(new URL('../devices.json', import.meta.url)));
  const account = [...registry.accounts.values()][0];
  assert.ok(account, 'the example account must be registered');
  const device = account.devices.get('dev-8f2a');
  assert.ok(device, 'the example device must be registered');
  assert.match(device.token, /^[0-9a-f]{64}$/u, 'the token must be 32 random bytes as hex');
});

/* --------------------------------------------------------------------- accounts */

test('accounts: the legacy flat registry is migrated into exactly one account', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-relay-accounts-'));
  try {
    const file = path.join(dir, 'devices.json');
    fs.writeFileSync(file, JSON.stringify({
      devices: [{ id: 'dev-1', name: 'legacy desktop', token: 'a'.repeat(64), port: 9001 }],
    }));

    const registry = loadAccountRegistry(file);
    assert.equal(registry.format, 'devices', 'the flat registry must be recognized');
    assert.equal(registry.migrated, true, 'the flat registry must be migrated');
    assert.equal(registry.accounts.size, 1, 'the flat registry becomes exactly one account');

    const account = [...registry.accounts.values()][0];
    assert.match(account.id, /^acc-[0-9a-f]{4}$/u, 'the account id must be generated');
    assert.match(account.token, /^[0-9a-f]{64}$/u, 'the account token must be 32 random bytes as hex');
    assert.equal(account.devices.size, 1, 'the device must belong to the account');

    const device = account.devices.get('dev-1');
    assert.equal(device.name, 'legacy desktop');
    assert.equal(device.role, 'desktop', 'a migrated device is a desktop');
    assert.equal(device.port, 9001, 'the port of the device must survive the migration');
    assert.equal(device.accountId, account.id, 'the device must know its account');

    // The migrated registry is written back in the new format.
    const target = path.join(dir, 'accounts.json');
    saveAccountRegistry(target, registry);
    const reloaded = loadAccountRegistry(target);
    assert.equal(reloaded.format, 'accounts');
    assert.equal(reloaded.migrated, false);
    assert.equal(reloaded.accounts.size, 1);
    assert.equal(findDevice(reloaded, account.id, 'dev-1').token, 'a'.repeat(64));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('accounts: the shipped registry holds one account with a desktop and a phone', () => {
  // 读的是**提交进 git 的样例**而不是本机的 accounts.json: 后者会被运行时改写
  // (手机登记自己会往里加设备), 用它做断言的话, 本机跑一次测试就红一次。
  const registry = loadAccountRegistry(fileURLToPath(new URL('../accounts.example.json', import.meta.url)));
  assert.equal(registry.accounts.size, 1);
  const account = findAccount(registry, 'acc-1a2b');
  assert.ok(account, 'the example account must be registered');
  assert.match(account.token, /^[0-9a-f]{64}$/u, 'the account token must be 32 random bytes as hex');

  const desktop = findDevice(registry, 'acc-1a2b', 'dev-8f2a');
  assert.ok(desktop, 'the example desktop must be registered');
  assert.equal(desktop.role, 'desktop');
  assert.equal(desktop.port, 8787);

  const phone = findDevice(registry, 'acc-1a2b', 'dev-p3h1');
  assert.ok(phone, 'the example phone must be registered');
  assert.equal(phone.role, 'phone');
  assert.equal(phone.port, null, 'a phone has no bridge port');

  assert.equal(listDevices(registry, 'acc-1a2b').length, 2);
  assert.equal(listDevices(registry, 'acc-nope').length, 0);
});

test('relay: a device of another account is refused', async () => {
  const relay = await startAccountRelay(twoAccountRegistry());
  try {
    // The device of account b may not dial in as a member of account a.
    const wrong = new WsClient(
      `ws://127.0.0.1:${relay.port}/bridge?token=token-b&deviceId=dev-b&accountId=acc-a`,
    );
    await assert.rejects(() => wrong.connect(), /401/u, 'a foreign device must be refused');

    // An unknown account is refused as well.
    const unknown = new WsClient(
      `ws://127.0.0.1:${relay.port}/bridge?token=token-a&deviceId=dev-a&accountId=acc-nope`,
    );
    await assert.rejects(() => unknown.connect(), /401/u, 'an unknown account must be refused');

    // The right account works.
    const right = new WsClient(
      `ws://127.0.0.1:${relay.port}/bridge?token=token-a&deviceId=dev-a&accountId=acc-a`,
    );
    try {
      const client = await right.connect({ timeoutMs: 5000 });
      assert.ok(client.handshakeDone);
    } finally {
      right.close();
    }
  } finally {
    await relay.close();
  }
});

test('relay: a device that presents the account token joins the account', async () => {
  const relay = await startAccountRelay(twoAccountRegistry());
  try {
    const device = await connectDevice(relay.port, {
      id: 'dev-new',
      token: 'the-new-device-token',
      accountId: 'acc-a',
      accountToken: 'a'.repeat(64),
    });
    try {
      const account = findAccount(relay.relay.registry, 'acc-a');
      assert.ok(account.devices.has('dev-new'), 'the device must have joined the account');
      assert.equal(account.devices.get('dev-new').token, 'the-new-device-token');
    } finally {
      device.close();
    }

    // A wrong account token is refused.
    const wrong = new WsClient(
      `ws://127.0.0.1:${relay.port}/bridge?token=token-a&deviceId=dev-a&accountToken=${'c'.repeat(64)}`,
    );
    await assert.rejects(() => wrong.connect(), /401/u, 'a wrong account token must be refused');
  } finally {
    await relay.close();
  }
});

test('relay: a phone of account A cannot see the devices of account B', async () => {
  const bridge = await startFakeBridge();
  const relay = await startAccountRelay(twoAccountRegistry(bridge.port));
  const device = await connectDevice(relay.port, { id: 'dev-a', token: 'token-a', accountId: 'acc-a', name: 'a name from the client' });
  try {
    // The device of account b is not addressable through account a.
    const foreign = await rawRequest(relay.port, [
      'GET /acc-a/dev-b/api/v1/health HTTP/1.1',
      'Host: phone.local',
      'Authorization: Bearer the-bridge-token',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    assert.match(foreign, /^HTTP\/1\.1 404/u, `unexpected answer: ${foreign}`);
    assert.ok(foreign.includes('does not belong'), 'the answer must name the problem');
    assert.equal(bridge.requests.length, 0, 'the request must not reach any device');

    // The presence of account a does not mention the devices of account b.
    const presence = await rawRequest(relay.port, [
      `GET /_relay/accounts/acc-a/devices?accountToken=${'a'.repeat(64)} HTTP/1.1`,
      'Host: phone.local',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    assert.match(presence, /^HTTP\/1\.1 200/u, `unexpected answer: ${presence}`);
    const body = jsonBody(presence);
    assert.equal(body.account.id, 'acc-a');
    assert.deepEqual(body.devices.map((entry) => entry.id), ['dev-a'], 'only the own devices are listed');
  } finally {
    device.close();
    await relay.close();
    await bridge.close();
  }
});

test('relay: the presence endpoint needs the account token and reports the online devices', async () => {
  const relay = await startAccountRelay(twoAccountRegistry());
  const device = await connectDevice(relay.port, { id: 'dev-a', token: 'token-a', accountId: 'acc-a', name: 'a name from the client' });
  try {
    const anonymous = await rawRequest(relay.port, [
      'GET /_relay/accounts/acc-a/devices HTTP/1.1',
      'Host: phone.local',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    assert.match(anonymous, /^HTTP\/1\.1 401/u, 'the account token must be required');

    const wrong = await rawRequest(relay.port, [
      `GET /_relay/accounts/acc-a/devices?accountToken=${'c'.repeat(64)} HTTP/1.1`,
      'Host: phone.local',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    assert.match(wrong, /^HTTP\/1\.1 401/u, 'a wrong account token must be refused');

    const foreign = await rawRequest(relay.port, [
      `GET /_relay/accounts/acc-a/devices?accountToken=${'b'.repeat(64)} HTTP/1.1`,
      'Host: phone.local',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    assert.match(foreign, /^HTTP\/1\.1 401/u, 'the token of another account must be refused');

    const unknown = await rawRequest(relay.port, [
      `GET /_relay/accounts/acc-nope/devices?accountToken=${'a'.repeat(64)} HTTP/1.1`,
      'Host: phone.local',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    assert.match(unknown, /^HTTP\/1\.1 404/u, 'an unknown account must answer 404');

    // The account token may also travel in the Authorization header.
    const withHeader = await rawRequest(relay.port, [
      'GET /_relay/accounts/acc-a/devices HTTP/1.1',
      'Host: phone.local',
      `Authorization: Bearer ${'a'.repeat(64)}`,
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    assert.match(withHeader, /^HTTP\/1\.1 200/u, `unexpected answer: ${withHeader}`);
    const body = jsonBody(withHeader);
    assert.equal(body.devices.length, 1);
    assert.equal(body.devices[0].id, 'dev-a');
    assert.equal(body.devices[0].name, 'desktop a');
    assert.equal(body.devices[0].role, 'desktop');
    assert.equal(body.devices[0].online, true, 'the connected device must be online');
    assert.ok(body.devices[0].lastSeen > 0, 'the device must have a presence timestamp');

    // The device of the other account is offline and stays invisible for account a.
    const other = await rawRequest(relay.port, [
      `GET /_relay/accounts/acc-b/devices?accountToken=${'b'.repeat(64)} HTTP/1.1`,
      'Host: phone.local',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    assert.match(other, /^HTTP\/1\.1 200/u);
    const otherBody = jsonBody(other);
    assert.equal(otherBody.devices.length, 1);
    assert.equal(otherBody.devices[0].id, 'dev-b');
    assert.equal(otherBody.devices[0].online, false, 'the device of account b is offline');

    // The legacy device list is scoped as well: it needs the account token.
    const legacy = await rawRequest(relay.port, [
      'GET /_relay/devices HTTP/1.1',
      'Host: phone.local',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    assert.match(legacy, /^HTTP\/1\.1 401/u, 'the legacy device list must not leak the devices');
  } finally {
    device.close();
    await relay.close();
  }
});

test('relay: the account scoped phone url reaches the device and the prefix is removed', async () => {
  const bridge = await startFakeBridge();
  const relay = await startAccountRelay(twoAccountRegistry(bridge.port));
  const device = await connectDevice(relay.port, { id: 'dev-a', token: 'token-a', accountId: 'acc-a', name: 'a name from the client' });
  try {
    const response = await rawRequest(relay.port, [
      'GET /acc-a/dev-a/api/v1/health HTTP/1.1',
      'Host: phone.local',
      'Authorization: Bearer the-bridge-token',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));

    assert.match(response, /^HTTP\/1\.1 200/u, `unexpected response: ${response}`);
    assert.equal(bridge.requests.length, 1, 'the device must receive exactly one request');
    assert.equal(bridge.requests[0].url, '/api/v1/health', 'the account and the device prefix must be removed');
    assert.equal(bridge.requests[0].headers.authorization, 'Bearer the-bridge-token');
  } finally {
    device.close();
    await relay.close();
    await bridge.close();
  }
});

test('cli: the account flags are understood and the phone url carries the account', () => {
  const options = parseArgs([
    '--port', '9000',
    '--account-file', 'relay/accounts.json',
    '--account-create',
    '--account-id', 'acc-1a2b',
    '--account-name', '我的账号',
    '--no-join',
  ]);
  assert.equal(options.accountFile, 'relay/accounts.json');
  assert.equal(options.accountCreate, true);
  assert.equal(options.accountId, 'acc-1a2b');
  assert.equal(options.accountName, '我的账号');
  assert.equal(options.allowJoin, false, '--no-join must switch the join off');
  assert.equal(phoneUrl('https://relay.example.com:8443', 'dev-8f2a'), 'https://relay.example.com:8443/dev-8f2a');
  assert.equal(
    phoneUrl('https://relay.example.com:8443', 'dev-8f2a', 'acc-1a2b'),
    'https://relay.example.com:8443/acc-1a2b/dev-8f2a',
    'the phone url must carry the account',
  );
});

/* ------------------------------------------------------------- the phone registers itself */

test('relay: the requests the relay answers itself are not forwarded to the device', async () => {
  // 回归测试: 中继自己的端点(/_relay/…)是它自己回答的, 它的字节不能转发给设备。
  // 否则设备会用自己的令牌检查去回答它, 同一个连接上就多出一个 401,
  // 而手机端的 HTTP 客户端会把这个多出来的响应当成下一个请求的响应。
  const bridge = await startFakeBridge();
  const relay = await startRelay([
    { id: 'dev-1', token: 'token-1', port: bridge.port },
  ], { bridgePort: bridge.port });
  try {
    await connectDevice(relay.port, { id: 'dev-1', token: 'token-1' });
    const response = await rawRequest(relay.port, [
      'GET /_relay/health HTTP/1.1',
      'Host: 127.0.0.1',
      'Authorization: Bearer token-a',
      '',
      'GET /dev-a/api/v1/health HTTP/1.1',
      'Host: 127.0.0.1',
      'Authorization: Bearer token-a',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    // 设备只应该收到第二个请求, 而且路径里的设备前缀已经被去掉。
    await waitUntil(() => bridge.requests.length >= 1, { timeoutMs: 2000 });
    await new Promise((resolve) => setTimeout(resolve, 150));
    assert.equal(bridge.requests.length, 1, `the device must only see the data request: ${JSON.stringify(bridge.requests.map((r) => r.url))}`);
    assert.equal(bridge.requests[0].url, '/api/v1/health');
    assert.equal(bridge.requests[0].headers.authorization, 'Bearer token-a');
    // 手机端先收到中继自己的回答, 再收到设备的回答, 两个响应各一次。
    const answers = response.split('HTTP/1.1 ').filter((part) => part.length > 0);
    assert.equal(answers.length, 2, `the phone must get exactly two answers: ${response}`);
    assert.match(answers[0], /^200/, 'the first answer is the relay answer');
    assert.match(answers[1], /^200/, 'the second answer is the device answer');
  } finally {
    await relay.close();
    await bridge.close();
  }
});

test('relay: a phone registers itself in the account', async () => {
  const relay = await startAccountRelay(twoAccountRegistry(await freePort()));
  try {
    const response = await postJson(relay.port, '/_relay/accounts/acc-a/phones', {
      token: 'a'.repeat(64),
      body: { deviceId: 'dev-p3h1', name: '我的手机', token: '1'.repeat(64) },
    });
    assert.match(response, /^HTTP\/1\.1 200/u, `unexpected answer: ${response}`);
    const body = utf8JsonBody(response);
    assert.equal(body.device.id, 'dev-p3h1');
    assert.equal(body.device.name, '我的手机');
    assert.equal(body.device.role, 'phone');
    assert.equal(body.device.online, true, 'the phone is online right after the registration');
    assert.ok(body.device.lastSeen > 0, 'the phone must have a presence timestamp');

    // The registry knows the phone now.
    const account = findAccount(relay.relay.registry, 'acc-a');
    assert.ok(account.devices.has('dev-p3h1'), 'the phone must be a member of the account');
    assert.equal(account.devices.get('dev-p3h1').role, 'phone');
    assert.equal(account.devices.get('dev-p3h1').token, '1'.repeat(64));

    // The presence endpoint lists the phone of the account.
    const devices = await presenceOf(relay.port, 'acc-a', 'a'.repeat(64));
    const phone = devices.find((entry) => entry.id === 'dev-p3h1');
    assert.ok(phone, `the phone must be listed: ${JSON.stringify(devices)}`);
    assert.equal(phone.role, 'phone');
    assert.equal(phone.online, true, 'a phone that just registered is online');
  } finally {
    await relay.close();
  }
});

test('relay: a phone that registers again updates itself but may not change its token', async () => {
  const relay = await startAccountRelay(twoAccountRegistry(await freePort()));
  try {
    const first = await postJson(relay.port, '/_relay/accounts/acc-a/phones', {
      token: 'a'.repeat(64),
      body: { deviceId: 'dev-p3h1', name: '我的手机', token: '1'.repeat(64) },
    });
    assert.match(first, /^HTTP\/1\.1 200/u, `unexpected answer: ${first}`);

    // The same token is an update: the name may change, the presence is refreshed.
    const again = await postJson(relay.port, '/_relay/accounts/acc-a/phones', {
      token: 'a'.repeat(64),
      body: { deviceId: 'dev-p3h1', name: '我的新手机', token: '1'.repeat(64) },
    });
    assert.match(again, /^HTTP\/1\.1 200/u, `unexpected answer: ${again}`);
    const body = utf8JsonBody(again);
    assert.equal(body.device.name, '我的新手机', 'the name of the phone may change');
    assert.equal(body.device.role, 'phone');
    assert.equal(body.device.online, true);

    // A different token is a conflict: a phone may not take the id of another device.
    const stolen = await postJson(relay.port, '/_relay/accounts/acc-a/phones', {
      token: 'a'.repeat(64),
      body: { deviceId: 'dev-p3h1', name: '冒充的手机', token: '2'.repeat(64) },
    });
    assert.match(stolen, /^HTTP\/1\.1 409/u, `unexpected answer: ${stolen}`);
    assert.equal(jsonBody(stolen).error, 'device_conflict');

    // The registered device is untouched.
    const account = findAccount(relay.relay.registry, 'acc-a');
    assert.equal(account.devices.get('dev-p3h1').token, '1'.repeat(64), 'the token must not change');
    assert.equal(account.devices.get('dev-p3h1').name, '我的新手机');
  } finally {
    await relay.close();
  }
});

test('relay: the phone registration needs the account token and a known account', async () => {
  const relay = await startAccountRelay(twoAccountRegistry(await freePort()));
  try {
    // No token at all.
    const anonymous = await postJson(relay.port, '/_relay/accounts/acc-a/phones', {
      body: { deviceId: 'dev-p3h1', name: '我的手机', token: '1'.repeat(64) },
    });
    assert.match(anonymous, /^HTTP\/1\.1 401/u, `unexpected answer: ${anonymous}`);
    assert.equal(jsonBody(anonymous).error, 'unauthorized');

    // A wrong token.
    const wrong = await postJson(relay.port, '/_relay/accounts/acc-a/phones', {
      token: 'c'.repeat(64),
      body: { deviceId: 'dev-p3h1', name: '我的手机', token: '1'.repeat(64) },
    });
    assert.match(wrong, /^HTTP\/1\.1 401/u, `unexpected answer: ${wrong}`);
    assert.equal(jsonBody(wrong).error, 'unauthorized');

    // The token of another account does not open this account.
    const foreign = await postJson(relay.port, '/_relay/accounts/acc-a/phones', {
      token: 'b'.repeat(64),
      body: { deviceId: 'dev-p3h1', name: '我的手机', token: '1'.repeat(64) },
    });
    assert.match(foreign, /^HTTP\/1\.1 401/u, `unexpected answer: ${foreign}`);

    // An unknown account.
    const unknown = await postJson(relay.port, '/_relay/accounts/acc-nope/phones', {
      token: 'a'.repeat(64),
      body: { deviceId: 'dev-p3h1', name: '我的手机', token: '1'.repeat(64) },
    });
    assert.match(unknown, /^HTTP\/1\.1 404/u, `unexpected answer: ${unknown}`);
    assert.equal(jsonBody(unknown).error, 'unknown_account');

    // A refused registration registers nothing.
    const account = findAccount(relay.relay.registry, 'acc-a');
    assert.equal(account.devices.has('dev-p3h1'), false, 'a refused registration must not register anything');
  } finally {
    await relay.close();
  }
});

test('relay: a bad device id, device token or name is refused with 400', async () => {
  const relay = await startAccountRelay(twoAccountRegistry(await freePort()));
  try {
    const cases = [
      { what: 'the device id is missing', body: { name: '我的手机', token: '1'.repeat(64) } },
      { what: 'the device id is empty', body: { deviceId: '', name: '我的手机', token: '1'.repeat(64) } },
      { what: 'the device id has a space', body: { deviceId: 'dev p3h1', name: '我的手机', token: '1'.repeat(64) } },
      { what: 'the device id has a blank', body: { deviceId: ' dev-p3h1 ', name: '我的手机', token: '1'.repeat(64) } },
      { what: 'the device id is too long', body: { deviceId: 'a'.repeat(65), name: '我的手机', token: '1'.repeat(64) } },
      { what: 'the device token is missing', body: { deviceId: 'dev-p3h1', name: '我的手机' } },
      { what: 'the device token is too short', body: { deviceId: 'dev-p3h1', name: '我的手机', token: 'abcd' } },
      { what: 'the device token is not hex', body: { deviceId: 'dev-p3h1', name: '我的手机', token: 'z'.repeat(64) } },
      { what: 'the device token has a blank', body: { deviceId: 'dev-p3h1', name: '我的手机', token: ` ${'1'.repeat(64)}` } },
      { what: 'the name is too long', body: { deviceId: 'dev-p3h1', name: '手'.repeat(65), token: '1'.repeat(64) } },
    ];
    for (const entry of cases) {
      const response = await postJson(relay.port, '/_relay/accounts/acc-a/phones', {
        token: 'a'.repeat(64),
        body: entry.body,
      });
      assert.match(response, /^HTTP\/1\.1 400/u, `${entry.what} must be refused: ${response}`);
      assert.equal(jsonBody(response).error, 'bad_request');
    }
    // Nothing was registered.
    const account = findAccount(relay.relay.registry, 'acc-a');
    assert.equal(account.devices.size, 1, 'only the desktop of the fixture may be there');
  } finally {
    await relay.close();
  }
});

test('relay: the heartbeat of a phone refreshes its presence', async () => {
  const relay = await startAccountRelay(twoAccountRegistry(await freePort()));
  try {
    const registered = await postJson(relay.port, '/_relay/accounts/acc-a/phones', {
      token: 'a'.repeat(64),
      body: { deviceId: 'dev-p3h1', name: '我的手机', token: '1'.repeat(64) },
    });
    assert.match(registered, /^HTTP\/1\.1 200/u, `unexpected answer: ${registered}`);

    // The phone went silent: it is not online any more.
    const account = findAccount(relay.relay.registry, 'acc-a');
    account.devices.get('dev-p3h1').lastSeen = Date.now() - 10 * 60_000;
    const silent = (await presenceOf(relay.port, 'acc-a', 'a'.repeat(64)))
      .find((entry) => entry.id === 'dev-p3h1');
    assert.equal(silent.online, false, 'a phone that did not heartbeat is offline');

    // The window of the presence is 60 seconds.
    account.devices.get('dev-p3h1').lastSeen = Date.now() - (PHONE_ONLINE_WINDOW_MS - 5000);
    const fresh = (await presenceOf(relay.port, 'acc-a', 'a'.repeat(64)))
      .find((entry) => entry.id === 'dev-p3h1');
    assert.equal(fresh.online, true, 'a phone inside the window is online');
    account.devices.get('dev-p3h1').lastSeen = Date.now() - (PHONE_ONLINE_WINDOW_MS + 5000);
    const stale = (await presenceOf(relay.port, 'acc-a', 'a'.repeat(64)))
      .find((entry) => entry.id === 'dev-p3h1');
    assert.equal(stale.online, false, 'a phone outside the window is offline');

    // The heartbeat brings the phone back.
    const beat = await postJson(relay.port, '/_relay/accounts/acc-a/phones/dev-p3h1/heartbeat', {
      token: 'a'.repeat(64),
    });
    assert.match(beat, /^HTTP\/1\.1 200/u, `unexpected answer: ${beat}`);
    const body = utf8JsonBody(beat);
    assert.equal(body.device.id, 'dev-p3h1');
    assert.equal(body.device.name, '我的手机');
    assert.equal(body.device.role, 'phone');
    assert.equal(body.device.online, true, 'the phone is online right after the heartbeat');
    assert.ok(body.device.lastSeen > Date.now() - 60_000, 'the heartbeat refreshes the presence');

    const devices = await presenceOf(relay.port, 'acc-a', 'a'.repeat(64));
    const phone = devices.find((entry) => entry.id === 'dev-p3h1');
    assert.equal(phone.online, true, 'the presence endpoint reports the phone as online');

    // The heartbeat of an unknown device is a 404.
    const unknown = await postJson(relay.port, '/_relay/accounts/acc-a/phones/dev-nope/heartbeat', {
      token: 'a'.repeat(64),
    });
    assert.match(unknown, /^HTTP\/1\.1 404/u, `unexpected answer: ${unknown}`);
    assert.equal(jsonBody(unknown).error, 'unknown_device');
  } finally {
    await relay.close();
  }
});

test('relay: a phone of account B never shows up in the presence of account A', async () => {
  const relay = await startAccountRelay(twoAccountRegistry(await freePort()));
  try {
    const registered = await postJson(relay.port, '/_relay/accounts/acc-b/phones', {
      token: 'b'.repeat(64),
      body: { deviceId: 'dev-p3h1', name: '我的手机', token: '1'.repeat(64) },
    });
    assert.match(registered, /^HTTP\/1\.1 200/u, `unexpected answer: ${registered}`);

    const devices = await presenceOf(relay.port, 'acc-a', 'a'.repeat(64));
    assert.deepEqual(devices.map((entry) => entry.id), ['dev-a'], 'only the devices of account a are listed');
    assert.equal(devices.find((entry) => entry.id === 'dev-p3h1'), undefined, 'the phone of account b must be invisible');

    // The heartbeat of a foreign device is refused as well.
    const beat = await postJson(relay.port, '/_relay/accounts/acc-a/phones/dev-p3h1/heartbeat', {
      token: 'a'.repeat(64),
    });
    assert.match(beat, /^HTTP\/1\.1 404/u, `unexpected answer: ${beat}`);
    assert.equal(jsonBody(beat).error, 'unknown_device');
  } finally {
    await relay.close();
  }
});

test('relay: a device id of another account cannot be stolen', async () => {
  const relay = await startAccountRelay(twoAccountRegistry(await freePort()));
  try {
    // 'dev-a' is the desktop of account a.
    const stolenDesktop = await postJson(relay.port, '/_relay/accounts/acc-b/phones', {
      token: 'b'.repeat(64),
      body: { deviceId: 'dev-a', name: '冒充的手机', token: '1'.repeat(64) },
    });
    assert.match(stolenDesktop, /^HTTP\/1\.1 409/u, `unexpected answer: ${stolenDesktop}`);
    assert.equal(jsonBody(stolenDesktop).error, 'device_conflict');

    // A phone of account a may not be taken by account b either.
    const registered = await postJson(relay.port, '/_relay/accounts/acc-a/phones', {
      token: 'a'.repeat(64),
      body: { deviceId: 'dev-p3h1', name: '我的手机', token: '1'.repeat(64) },
    });
    assert.match(registered, /^HTTP\/1\.1 200/u, `unexpected answer: ${registered}`);
    const stolenPhone = await postJson(relay.port, '/_relay/accounts/acc-b/phones', {
      token: 'b'.repeat(64),
      body: { deviceId: 'dev-p3h1', name: '冒充的手机', token: '1'.repeat(64) },
    });
    assert.match(stolenPhone, /^HTTP\/1\.1 409/u, `unexpected answer: ${stolenPhone}`);
    assert.equal(jsonBody(stolenPhone).error, 'device_conflict');

    // The devices of account a are untouched.
    const account = findAccount(relay.relay.registry, 'acc-a');
    assert.equal(account.devices.get('dev-a').role, 'desktop', 'the desktop must stay a desktop');
    assert.equal(account.devices.get('dev-a').token, 'token-a');
    assert.equal(account.devices.get('dev-p3h1').role, 'phone');

    // …and nothing moved to account b.
    const other = findAccount(relay.relay.registry, 'acc-b');
    assert.equal(other.devices.has('dev-a'), false, 'the desktop must not move to the other account');
    assert.equal(other.devices.has('dev-p3h1'), false, 'the phone must not move to the other account');
    assert.equal(other.devices.size, 1, 'account b still has only its own desktop');
  } finally {
    await relay.close();
  }
});

await run();
