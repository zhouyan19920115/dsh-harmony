// Tests for the LAN discovery and the pairing code of the desktop bridge.
//
// Run with `node test/discovery.test.js`. The tests use node:assert only; the bridge is started
// on a real port and asked over real HTTP, so the wire contract is covered end to end.
//
// What is covered:
//   * `GET /_dsh/discover` — the answer a phone gets when it scans the network;
//   * the pairing code: six digits, 60 s lifetime, single use, rotating after wrong guesses;
//   * `POST /api/v1/pair` — the wrong code gives a 400 envelope, the right one hands out the token;
//   * `GET /api/v1/remote-config` — with and without a cloud relay, and 401 without a token.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

import { loadOrCreateState } from '../src/config.js';
import { DshClient } from '../src/dsh.js';
import { Bridge, Router, createRoutes } from '../src/router.js';
import { createBridgeServer } from '../src/server.js';
import { DISCOVER_PATH, PAIR_PATH, REMOTE_CONFIG_PATH } from '../src/discovery.js';
import { ErrorCode } from '../src/protocol.js';

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
}

/* ----------------------------------------------------------------------- helpers */

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

async function request(port, pathname, { method = 'GET', token, body, headers = {} } = {}) {
  const payload = body === undefined ? null : Buffer.from(JSON.stringify(body), 'utf8');
  const requestHeaders = {
    ...headers,
    ...(token ? { authorization: `Bearer ${token}` } : {}),
    ...(payload ? { 'content-type': 'application/json', 'content-length': payload.length } : {}),
  };
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: pathname, method, headers: requestHeaders }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json = null;
        try {
          json = JSON.parse(text);
        } catch {
          json = null;
        }
        resolve({ status: res.statusCode, headers: res.headers, text, json });
      });
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

/** Start a bridge on a random port and return its handles. */
async function startBridge(extraOptions = {}) {
  const port = await freePort();
  const stateFile = path.join(os.tmpdir(), `dsh-discovery-test-${crypto.randomUUID()}.json`);
  const state = loadOrCreateState(stateFile);
  const options = {
    port,
    host: '127.0.0.1',
    state: stateFile,
    adapter: 'dsh',
    allowUnauthPairing: false,
    dshUrl: 'http://127.0.0.1:10748',
    ...extraOptions,
  };
  const logs = [];
  const bridge = new Bridge({
    options,
    state,
    dsh: new DshClient({ baseUrl: options.dshUrl }),
    log: (level, message) => logs.push(`${level}: ${message}`),
  });
  const router = new Router(createRoutes(bridge));
  const server = createBridgeServer({ bridge, router });
  await bridge.start();
  await server.listen(port, '127.0.0.1');
  return {
    port,
    state,
    bridge,
    logs,
    async close() {
      await server.close();
      await bridge.stop();
      try {
        fs.unlinkSync(stateFile);
      } catch {
        // the state file may already be gone
      }
    },
  };
}

/* ------------------------------------------------------------------------- tests */

test('discover: the answer tells the phone name, address and a six digit code', async () => {
  const harness = await startBridge({ pairingHost: '192.168.1.10', relayName: '我的台式机' });
  try {
    const response = await request(harness.port, DISCOVER_PATH);
    assert.equal(response.status, 200);
    assert.ok(response.json, 'the answer must be json');
    assert.equal(response.json.name, '我的台式机');
    assert.equal(response.json.url, 'http://192.168.1.10:' + harness.port);
    assert.equal(response.json.host, '192.168.1.10');
    assert.equal(response.json.port, harness.port);
    assert.match(response.json.code, /^\d{6}$/, 'the pairing code must be six digits');
    assert.ok(response.json.expiresAt > Date.now(), 'the code must not be expired already');
    // The discovery endpoint must work without a token: the phone is not paired yet.
    assert.equal(response.headers['content-type']?.includes('application/json'), true);
  } finally {
    await harness.close();
  }
});

test('discover: the code lives 60 seconds and then changes', async () => {
  const harness = await startBridge();
  try {
    const first = await request(harness.port, DISCOVER_PATH);
    const ttl = first.json.expiresAt - Date.now();
    assert.ok(ttl > 0 && ttl <= 60_000, `the code must live at most 60 s, got ${ttl} ms`);
    // Pretend the clock ran past the expiry: the next answer carries a new code.
    harness.bridge.discovery.code.now = () => Date.now() + 61_000;
    const second = await request(harness.port, DISCOVER_PATH);
    assert.notEqual(second.json.code, first.json.code, 'an expired code must be replaced');
    assert.match(second.json.code, /^\d{6}$/);
  } finally {
    await harness.close();
  }
});

test('pair: a wrong code is refused with a 400 envelope', async () => {
  const harness = await startBridge();
  try {
    const discovered = await request(harness.port, DISCOVER_PATH);
    const wrong = discovered.json.code === '000000' ? '111111' : '000000';
    const response = await request(harness.port, PAIR_PATH, { method: 'POST', body: { code: wrong } });
    assert.equal(response.status, 400);
    assert.ok(response.json?.error, 'the answer must be an error envelope');
    assert.equal(response.json.error.code, ErrorCode.BAD_REQUEST);
    assert.equal(typeof response.json.error.message, 'string');
    assert.equal(response.json.token, undefined, 'a wrong code must not hand out a token');
  } finally {
    await harness.close();
  }
});

test('pair: the right code hands out the token — and only once', async () => {
  const harness = await startBridge();
  try {
    const discovered = await request(harness.port, DISCOVER_PATH);
    const code = discovered.json.code;
    const response = await request(harness.port, PAIR_PATH, { method: 'POST', body: { code } });
    assert.equal(response.status, 200);
    assert.equal(response.json.ok, true);
    assert.equal(response.json.token, harness.state.token);
    // The url points at the machine the phone has to use (the LAN address by default).
    assert.equal(response.json.url, harness.bridge.discovery.url);
    assert.ok(response.json.url.startsWith('http://'), `unexpected url: ${response.json.url}`);
    assert.ok(response.json.url.endsWith(`:${harness.port}`), `unexpected url: ${response.json.url}`);
    // Single use: the same code must not work twice.
    const again = await request(harness.port, PAIR_PATH, { method: 'POST', body: { code } });
    assert.equal(again.status, 400, 'a pairing code must be single use');
    assert.equal(again.json.error.code, ErrorCode.BAD_REQUEST);
  } finally {
    await harness.close();
  }
});

test('pair: five wrong guesses replace the code', async () => {
  const harness = await startBridge();
  try {
    const discovered = await request(harness.port, DISCOVER_PATH);
    const code = discovered.json.code;
    const wrong = code === '000000' ? '111111' : '000000';
    for (let i = 0; i < 5; i++) {
      const response = await request(harness.port, PAIR_PATH, { method: 'POST', body: { code: wrong } });
      assert.equal(response.status, 400);
    }
    // The old code is dead now, and the new one is a different one.
    const after = await request(harness.port, DISCOVER_PATH);
    assert.notEqual(after.json.code, code, 'the code must be replaced after five wrong guesses');
    const retry = await request(harness.port, PAIR_PATH, { method: 'POST', body: { code } });
    assert.equal(retry.status, 400, 'the old code must not work any more');
  } finally {
    await harness.close();
  }
});

test('remote-config: without a relay the phone stays on the local network', async () => {
  const harness = await startBridge();
  try {
    const response = await request(harness.port, REMOTE_CONFIG_PATH, { token: harness.state.token });
    assert.equal(response.status, 200);
    assert.equal(response.json.available, false);
    assert.equal(typeof response.json.reason, 'string');
  } finally {
    await harness.close();
  }
});

test('remote-config: with a relay the phone gets the relay address and the token', async () => {
  const harness = await startBridge({
    relay: 'ws://relay.example.com:8788/bridge',
    account: 'acc-1a2b',
    deviceId: 'dev-8f2a',
  });
  try {
    const response = await request(harness.port, REMOTE_CONFIG_PATH, { token: harness.state.token });
    assert.equal(response.status, 200);
    assert.equal(response.json.available, true);
    assert.equal(response.json.token, harness.state.token);
    assert.equal(response.json.accountId, 'acc-1a2b');
    assert.equal(response.json.deviceId, 'dev-8f2a');
    assert.ok(response.json.relayUrl.includes('/acc-1a2b/dev-8f2a'), `unexpected relay url: ${response.json.relayUrl}`);
    assert.ok(response.json.relayUrl.startsWith('http://'), 'the phone talks http(s) to the relay');
  } finally {
    await harness.close();
  }
});

test('remote-config: without a token the answer is 401', async () => {
  const harness = await startBridge();
  try {
    const response = await request(harness.port, REMOTE_CONFIG_PATH);
    assert.equal(response.status, 401);
    assert.equal(response.json.error.code, ErrorCode.UNAUTHORIZED);
  } finally {
    await harness.close();
  }
});

test('discover and pair do not need a token, the other endpoints do', async () => {
  const harness = await startBridge();
  try {
    assert.equal((await request(harness.port, DISCOVER_PATH)).status, 200);
    const discovered = await request(harness.port, DISCOVER_PATH);
    const paired = await request(harness.port, PAIR_PATH, { method: 'POST', body: { code: discovered.json.code } });
    assert.equal(paired.status, 200);
    // The token of the pairing works on the protected endpoints.
    const sessions = await request(harness.port, '/api/v1/sessions', { token: harness.state.token });
    assert.equal(sessions.status, 200);
    // ... and without it the bridge says no.
    const denied = await request(harness.port, '/api/v1/sessions');
    assert.equal(denied.status, 401);
  } finally {
    await harness.close();
  }
});

await run();
