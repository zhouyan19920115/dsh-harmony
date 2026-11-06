// Tests for the heartbeat of the two long lived WebSocket connections.
//
// Run with `node test/heartbeat.test.js`. The tests use node:assert only; a real bridge and a
// real (fake) relay are started on real ports, so the wire contract is covered end to end.
//
// What is covered:
//   * the phone → bridge direction: a `ping` frame is answered with a `pong`, and a `pong`
//     (the answer to a bridge ping) is accepted instead of being refused as an unknown frame;
//   * the bridge → relay direction: the device pings the relay, a pong keeps the connection,
//     and a relay that stops answering makes the device redial.
//
// Why it matters: an idle WebSocket looks dead to the middle boxes on the way (Cloudflare drops
// one that says nothing for a while), and a connection that is half open looks alive to both
// ends. The heartbeat keeps the connection warm and notices the dead one early.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';

import { loadOrCreateState } from '../src/config.js';
import { DshClient } from '../src/dsh.js';
import { Bridge, Router, createRoutes } from '../src/router.js';
import { createBridgeServer } from '../src/server.js';
import { WS_PATH } from '../src/protocol.js';
import { OPCODE, WebSocketClient, acceptWebSocket, encodeFrame } from '../src/ws.js';
import { RelayClient, RelayFrameDecoder, RELAY_TYPE, encodeRelayFrame } from '../src/relay-client.js';

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

function delay(ms) {
  return new Promise((resolve) => { setTimeout(resolve, ms); });
}

async function freePort() {
  const server = http.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(() => resolve()));
  return port;
}

/** Wait until `check()` is true, or give up. */
async function waitUntil(check, { timeoutMs = 5000, stepMs = 20 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (check()) return true;
    await delay(stepMs);
  }
  return check();
}

/** A real bridge on a real port. */
async function startBridge({ heartbeatIntervalMs } = {}) {
  const port = await freePort();
  const stateFile = path.join(os.tmpdir(), `dsh-heartbeat-test-${crypto.randomUUID()}.json`);
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
  const server = createBridgeServer({ bridge, router, heartbeatIntervalMs });
  await bridge.start();
  await server.listen(port, '127.0.0.1');
  return {
    port,
    state,
    token: state.token,
    instance: bridge,
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

/**
 * A phone that talks to the bridge over a real WebSocket.
 *
 * It sends the auth frame first (the first frame of a connection has to be the auth) and then
 * collects every frame the bridge sends.
 */
async function startPhone(bridge) {
  const frames = [];
  const client = new WebSocketClient(`ws://127.0.0.1:${bridge.port}${WS_PATH}`, { timeoutMs: 5000 });
  client.on('message', (text) => {
    try {
      frames.push(JSON.parse(text));
    } catch {
      frames.push({ type: 'raw', text });
    }
  });
  await client.connect();
  client.send(JSON.stringify({ type: 'auth', token: bridge.token }));
  await waitUntil(() => frames.some((frame) => frame.type === 'hello'));
  return {
    frames,
    send(frame) {
      client.send(JSON.stringify(frame));
    },
    close() {
      client.close();
    },
  };
}

/**
 * A fake relay: it answers the handshake and collects the frames of the device.
 *
 * `answerPings` decides whether the pongs come back — that is the whole point of the test.
 */
async function startFakeRelay({ answerPings = true } = {}) {
  const state = { connections: 0, frames: [], pings: 0 };
  const decoder = new RelayFrameDecoder();
  const server = http.createServer();

  server.on('upgrade', (request, socket, head) => {
    const connection = acceptWebSocket(request, socket, head);
    if (connection === null) return;
    state.connections += 1;
    connection.on('binary', (payload) => {
      for (const frame of decoder.push(payload)) {
        state.frames.push(frame);
        if (frame.type === RELAY_TYPE.HELLO) {
          connection.socket.write(encodeFrame(OPCODE.BINARY, encodeRelayFrame(
            0,
            RELAY_TYPE.HELLO_OK,
            Buffer.from(JSON.stringify({ relay: 'fake-relay', version: '1.0.0' }), 'utf8'),
          )));
        }
        if (frame.type === RELAY_TYPE.PING) {
          state.pings += 1;
          if (answerPings) {
            connection.socket.write(encodeFrame(OPCODE.BINARY, encodeRelayFrame(0, RELAY_TYPE.PONG)));
          }
        }
      }
    });
    connection.on('error', () => {});
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  return {
    port,
    state,
    url: `ws://127.0.0.1:${port}`,
    async close() {
      await new Promise((resolve) => server.close(() => resolve()));
    },
  };
}

/* -------------------------------------------------------------------------- tests */

test('the phone ping is answered with a pong', async () => {
  const bridge = await startBridge();
  const phone = await startPhone(bridge);
  try {
    phone.send({ type: 'ping', data: {} });
    const answered = await waitUntil(() => phone.frames.some((frame) => frame.type === 'pong'));
    assert.equal(answered, true, 'the bridge has to answer a ping with a pong');
  } finally {
    phone.close();
    await bridge.close();
  }
});

test('a pong from the phone is not an error', async () => {
  const bridge = await startBridge();
  const phone = await startPhone(bridge);
  try {
    // The answer to a bridge ping: it must be accepted, not refused as an unknown frame.
    phone.send({ type: 'pong', data: {} });
    await delay(120);
    const errors = phone.frames.filter((frame) => frame.type === 'error');
    assert.deepEqual(errors, [], 'a pong must not produce an error frame');
  } finally {
    phone.close();
    await bridge.close();
  }
});

test('the relay connection pings the relay and stays up', async () => {
  const relay = await startFakeRelay({ answerPings: true });
  const client = new RelayClient({
    url: relay.url,
    deviceToken: '0123456789abcdef',
    deviceId: 'dev-heartbeat',
    targetPort: 8787,
    heartbeatIntervalMs: 50,
    heartbeatMaxMisses: 3,
    log: () => {},
  });
  try {
    client.start();
    const connected = await waitUntil(() => client.connected);
    assert.equal(connected, true, 'the device has to register at the relay');
    const pinged = await waitUntil(() => relay.state.pings >= 2, { timeoutMs: 5000 });
    assert.equal(pinged, true, 'the device has to ping the relay');
    // The pongs came back, so the connection is still the same one.
    assert.equal(relay.state.connections, 1, 'a answered heartbeat must not redial');
    assert.equal(client.connected, true, 'the connection must stay up');
  } finally {
    await client.stop();
    await relay.close();
  }
});

test('the relay connection redials when the pongs stop coming', async () => {
  const relay = await startFakeRelay({ answerPings: false });
  const client = new RelayClient({
    url: relay.url,
    deviceToken: '0123456789abcdef',
    deviceId: 'dev-heartbeat',
    targetPort: 8787,
    heartbeatIntervalMs: 50,
    heartbeatMaxMisses: 2,
    log: () => {},
  });
  try {
    client.start();
    const connected = await waitUntil(() => client.connected);
    assert.equal(connected, true, 'the device has to register at the relay');
    // The relay never answers: after the misses the device has to dial again.
    const redialled = await waitUntil(() => relay.state.connections >= 2, { timeoutMs: 5000 });
    assert.equal(redialled, true, 'a silent relay has to make the device redial');
  } finally {
    await client.stop();
    await relay.close();
  }
});

test('a pong resets the miss counter', async () => {
  const relay = await startFakeRelay({ answerPings: true });
  const client = new RelayClient({
    url: relay.url,
    deviceToken: '0123456789abcdef',
    deviceId: 'dev-heartbeat',
    targetPort: 8787,
    heartbeatIntervalMs: 50,
    heartbeatMaxMisses: 2,
    log: () => {},
  });
  try {
    client.start();
    await waitUntil(() => client.connected);
    // The relay answers every ping, so the miss counter never grows and the device never
    // redials - not even after many heartbeats.
    await waitUntil(() => relay.state.pings >= 6, { timeoutMs: 5000 });
    await delay(120);
    assert.equal(relay.state.connections, 1, 'answered heartbeats must not redial');
    assert.equal(client.connected, true, 'the connection must stay up');
  } finally {
    await client.stop();
    await relay.close();
  }
});

test('a phone that never answers the heartbeat is not dropped', async () => {
  // An older app build does not know the heartbeat frame. It must not be kicked off the bus
  // for that - only a phone that answered before and then went quiet is a dead one.
  const bridge = await startBridge({ heartbeatIntervalMs: 50 });
  const phone = await startPhone(bridge);
  try {
    await delay(400);
    const stillThere = await waitUntil(() => bridge.instance.clients.size === 1, { timeoutMs: 2000 });
    assert.equal(stillThere, true, 'the phone must still be connected');
    // The bridge did send its pings, the phone just did not answer them.
    const pings = phone.frames.filter((frame) => frame.type === 'ping').length;
    assert.equal(pings > 0, true, 'the bridge has to ping the phone');
  } finally {
    phone.close();
    await bridge.close();
  }
});

await run();
