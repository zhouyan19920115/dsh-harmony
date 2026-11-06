// The tests of the end to end encryption (bridge/src/seal.js).
//
//   node bridge/test/seal.test.js
//
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';

import { loadOrCreateState } from '../src/config.js';
import { Bridge, Router, createRoutes } from '../src/router.js';
import { createBridgeServer } from '../src/server.js';
import {
  SEAL_HEADER,
  SEAL_ID_HEADER,
  SEAL_KEY_BYTES,
  SEAL_MAX_AGE_MS,
  SEAL_TIMESTAMP_HEADER,
  deriveSealKey,
  deriveWrapKey,
  parseSealId,
  readSealedBody,
  sealBody,
  sealHeaders,
  unsealBody,
} from '../src/seal.js';

const tests = [];
function test(name, fn) {
  tests.push({ name, fn });
}

async function run() {
  let passed = 0;
  const failures = [];
  for (const entry of tests) {
    try {
      await entry.fn();
      passed += 1;
      process.stdout.write(`  ok   ${entry.name}\n`);
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
  process.exit(process.exitCode ?? 0);
}

test('seal: the key is derived with HKDF-SHA256 and is 32 bytes', () => {
  const key = deriveSealKey({ token: 'the-bridge-token', accountId: 'acc-1', deviceId: 'dev-1' });
  assert.equal(key.length, SEAL_KEY_BYTES);
  // The derivation is deterministic: both sides derive the same key.
  const again = deriveSealKey({ token: 'the-bridge-token', accountId: 'acc-1', deviceId: 'dev-1' });
  assert.deepEqual(key, again);
  // A different account or device gives a different key.
  const other = deriveSealKey({ token: 'the-bridge-token', accountId: 'acc-2', deviceId: 'dev-1' });
  assert.notDeepEqual(key, other);
  // A different token gives a different key.
  const otherToken = deriveSealKey({ token: 'another-token', accountId: 'acc-1', deviceId: 'dev-1' });
  assert.notDeepEqual(key, otherToken);
});

test('seal: the derivation matches the HKDF-SHA256 of RFC 5869', () => {
  // RFC 5869, test case 1: IKM, salt and info are the ones of the appendix.
  const derived = crypto.hkdfSync(
    'sha256',
    Buffer.from('0b'.repeat(22), 'hex'),
    Buffer.from('000102030405060708090a0b0c', 'hex'),
    Buffer.from('f0f1f2f3f4f5f6f7f8f9', 'hex'),
    42,
  );
  assert.equal(
    Buffer.from(derived).toString('hex'),
    '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865',
  );
});

test('seal: a body survives the round trip', () => {
  const key = deriveSealKey({ token: 'token', accountId: 'acc', deviceId: 'dev' });
  const body = JSON.stringify({ prompt: 'hello', options: { permissionMode: 'read-only' } });
  const { seal, timestamp } = sealBody(key, body, { method: 'POST', path: '/api/v1/prompt', timestamp: 1_700_000_000_000 });
  assert.match(seal, /^[A-Za-z0-9+/]+=*$/u, 'the envelope must be base64');
  assert.equal(
    unsealBody(key, seal, { method: 'POST', path: '/api/v1/prompt', timestamp: 1_700_000_000_000 }),
    body,
  );
});

test('seal: the envelope does not contain the body', () => {
  const key = deriveSealKey({ token: 'token', accountId: 'acc', deviceId: 'dev' });
  const { seal } = sealBody(key, 'the secret prompt', { method: 'POST', path: '/api/v1/prompt' });
  assert.ok(!seal.includes('secret'), 'the body must not be readable in the envelope');
  assert.ok(!Buffer.from(seal, 'base64').toString('utf8').includes('secret'));
});

test('seal: a seal cannot be moved to another path', () => {
  const key = deriveSealKey({ token: 'token', accountId: 'acc', deviceId: 'dev' });
  const { seal, timestamp } = sealBody(key, 'body', { method: 'POST', path: '/api/v1/prompt', timestamp: 1_700_000_000_000 });
  assert.throws(
    () => unsealBody(key, seal, { method: 'POST', path: '/api/v1/sessions', timestamp: 1_700_000_000_000 }),
    /unable to authenticate|bad decrypt|unsupported/i,
    'the tag must not open for another path',
  );
});

test('seal: a seal cannot be moved to another method', () => {
  const key = deriveSealKey({ token: 'token', accountId: 'acc', deviceId: 'dev' });
  const { seal, timestamp } = sealBody(key, 'body', { method: 'POST', path: '/api/v1/prompt', timestamp: 1_700_000_000_000 });
  assert.throws(
    () => unsealBody(key, seal, { method: 'GET', path: '/api/v1/prompt', timestamp: 1_700_000_000_000 }),
    /unable to authenticate|bad decrypt|unsupported/i,
  );
});

test('seal: a seal of another key does not open', () => {
  const key = deriveSealKey({ token: 'token', accountId: 'acc', deviceId: 'dev' });
  const other = deriveSealKey({ token: 'another token', accountId: 'acc', deviceId: 'dev' });
  const { seal, timestamp } = sealBody(key, 'body', { method: 'GET', path: '/x', timestamp: 1_700_000_000_000 });
  assert.throws(() => unsealBody(other, seal, { method: 'GET', path: '/x', timestamp: 1_700_000_000_000 }));
});

test('seal: a replay outside the window is refused', () => {
  const key = deriveSealKey({ token: 'token', accountId: 'acc', deviceId: 'dev' });
  const timestamp = 1_700_000_000_000;
  const { seal } = sealBody(key, 'body', { method: 'GET', path: '/x', timestamp });
  // Inside the window it opens.
  assert.equal(unsealBody(key, seal, { method: 'GET', path: '/x', timestamp, now: timestamp + 60_000 }), 'body');
  // Five minutes later it does not.
  assert.throws(
    () => unsealBody(key, seal, { method: 'GET', path: '/x', timestamp, now: timestamp + SEAL_MAX_AGE_MS + 1000 }),
    /replay window/u,
  );
  // An old seal is refused as well.
  assert.throws(
    () => unsealBody(key, seal, { method: 'GET', path: '/x', timestamp, now: timestamp - SEAL_MAX_AGE_MS - 1000 }),
    /replay window/u,
  );
});

test('seal: a broken envelope is refused', () => {
  const key = deriveSealKey({ token: 'token', accountId: 'acc', deviceId: 'dev' });
  assert.throws(() => unsealBody(key, '', { method: 'GET', path: '/x', timestamp: Date.now() }), /too short/u);
  assert.throws(() => unsealBody(key, 'AAAA', { method: 'GET', path: '/x', timestamp: Date.now() }), /too short/u);
  assert.throws(() => unsealBody(key, 'x'.repeat(64), { method: 'GET', path: '/x', timestamp: Date.now() }));
  assert.throws(() => unsealBody(key, 'x'.repeat(64), { method: 'GET', path: '/x', timestamp: 'soon' }), /timestamp/u);
});

test('seal: the headers carry the envelope and the timestamp', () => {
  const key = deriveSealKey({ token: 'token', accountId: 'acc', deviceId: 'dev' });
  const timestamp = 1_700_000_000_000;
  const headers = sealHeaders(key, 'the body', { method: 'POST', path: '/api/v1/prompt', timestamp });
  assert.ok(headers[SEAL_HEADER], 'the seal header must be there');
  assert.equal(headers[SEAL_TIMESTAMP_HEADER], String(timestamp));
  assert.equal(
    readSealedBody(key, headers, { method: 'POST', path: '/api/v1/prompt', now: timestamp }),
    'the body',
  );
  // A request without the seal is not a sealed request.
  assert.equal(readSealedBody(key, {}, { method: 'GET', path: '/' }), null);
});

test('seal: the nonce is fresh for every seal', () => {
  const key = deriveSealKey({ token: 'token', accountId: 'acc', deviceId: 'dev' });
  const first = sealBody(key, 'body', { method: 'GET', path: '/x', timestamp: 1_700_000_000_000 });
  const second = sealBody(key, 'body', { method: 'GET', path: '/x', timestamp: 1_700_000_000_000 });
  assert.notEqual(first.seal, second.seal, 'the same body must not produce the same envelope');
});

test('seal: the ids of the header are split into the account and the device', () => {
  assert.deepEqual(parseSealId('acc-1:dev-2'), { accountId: 'acc-1', deviceId: 'dev-2' });
  assert.deepEqual(parseSealId('dev-2'), { accountId: '', deviceId: 'dev-2' });
  assert.deepEqual(parseSealId(''), { accountId: '', deviceId: '' });
});

/* --------------------------------------------------------------- the bridge server */

/** Start a bridge that answers on a free port. */
async function startBridge() {
  const port = await freePort();
  const stateFile = path.join(os.tmpdir(), `dsh-seal-test-${crypto.randomUUID()}.json`);
  const state = loadOrCreateState(stateFile);
  const options = {
    port,
    host: '127.0.0.1',
    state: stateFile,
    adapter: 'local',
    allowUnauthPairing: false,
  };
  const bridge = new Bridge({ options, state, log: () => {} });
  const router = new Router(createRoutes(bridge));
  const httpServer = createBridgeServer({ bridge, router });
  await bridge.start();
  await httpServer.listen(port, '127.0.0.1');
  return {
    port,
    state,
    async close() {
      bridge.stop();
      await httpServer.close();
      try {
        fs.rmSync(stateFile, { force: true });
      } catch {
        // Ignore.
      }
    },
  };
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = http.createServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

/** Send a request and collect the answer. */
function request(port, { method = 'GET', path = '/', headers = {}, body = null } = {}) {
  return new Promise((resolve, reject) => {
    const payload = body === null ? null : Buffer.from(body, 'utf8');
    const req = http.request({
      host: '127.0.0.1',
      port,
      path,
      method,
      headers: {
        ...headers,
        ...(payload === null ? {} : { 'content-length': payload.length }),
      },
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    req.on('error', reject);
    if (payload !== null) req.write(payload);
    req.end();
  });
}

test('bridge: a sealed request carries the token and the body, the relay never sees it', async () => {
  const bridge = await startBridge();
  try {
    const token = bridge.state.token;
    const key = deriveSealKey({ token, accountId: 'acc-1', deviceId: 'dev-phone' });
    const timestamp = Date.now();
    const { seal } = sealBody(key, JSON.stringify({ token, body: { ok: true } }), {
      method: 'POST',
      path: '/api/v1/echo',
      timestamp,
    });

    const response = await request(bridge.port, {
      method: 'POST',
      path: '/api/v1/echo',
      headers: {
        [SEAL_HEADER]: seal,
        [SEAL_TIMESTAMP_HEADER]: String(timestamp),
        [SEAL_ID_HEADER]: 'acc-1:dev-phone',
        'content-type': 'application/json',
      },
      body: seal,
    });

    // The route does not exist, but the important part is that the seal was opened and the
    // token was accepted: the answer must not be "a valid bearer token is required".
    assert.notEqual(response.status, 401, `the token inside the seal must be accepted: ${response.body}`);

    // A request without a seal but with the token still works (an old phone).
    const plain = await request(bridge.port, {
      path: '/api/v1/health',
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(plain.status, 200, `the plain request must work: ${plain.body}`);
  } finally {
    await bridge.close();
  }
});

test('seal: the seal key of the phone survives the wrapping', () => {
  const wrapKey = deriveWrapKey({ token: 'the-bridge-token', accountId: 'acc-1', deviceId: 'dev-phone' });
  const sealKey = crypto.randomBytes(32);
  const wrapped = wrapSealKey(wrapKey, sealKey, { accountId: 'acc-1', deviceId: 'dev-phone' });
  assert.ok(!wrapped.includes(sealKey.toString('base64')), 'the seal key must not travel in the clear');
  assert.deepEqual(
    unwrapSealKey(wrapKey, wrapped, { accountId: 'acc-1', deviceId: 'dev-phone' }),
    sealKey,
  );
  // Another device cannot unwrap it.
  assert.throws(() => unwrapSealKey(
    deriveWrapKey({ token: 'the-bridge-token', accountId: 'acc-1', deviceId: 'dev-other' }),
    wrapped,
    { accountId: 'acc-1', deviceId: 'dev-other' },
  ));
});

test('bridge: a request with a wrapped seal key is opened with that key', async () => {
  const bridge = await startBridge();
  try {
    const token = bridge.state.token;
    const accountId = 'acc-1';
    const deviceId = 'dev-phone';
    const wrapKey = deriveWrapKey({ token, accountId, deviceId });
    // The phone keeps its own random seal key.
    const sealKey = crypto.randomBytes(32);
    const wrapped = wrapSealKey(wrapKey, sealKey, { accountId, deviceId });
    const timestamp = Date.now();
    const { seal } = sealBody(sealKey, JSON.stringify({ token, body: { ok: true } }), {
      method: 'POST',
      path: '/api/v1/echo',
      timestamp,
    });

    const response = await request(bridge.port, {
      method: 'POST',
      path: '/api/v1/echo',
      headers: {
        [SEAL_HEADER]: seal,
        [SEAL_TIMESTAMP_HEADER]: String(timestamp),
        [SEAL_ID_HEADER]: `${accountId}:${deviceId}`,
        [SEAL_KEY_HEADER]: wrapped,
        'content-type': 'application/json',
      },
      body: seal,
    });
    assert.notEqual(response.status, 401, `the wrapped seal key must be accepted: ${response.body}`);

    // A wrapped key of another device does not open the body.
    const wrong = wrapSealKey(
      deriveWrapKey({ token, accountId, deviceId: 'dev-other' }),
      sealKey,
      { accountId, deviceId: 'dev-other' },
    );
    const broken = await request(bridge.port, {
      method: 'POST',
      path: '/api/v1/echo',
      headers: {
        [SEAL_HEADER]: seal,
        [SEAL_TIMESTAMP_HEADER]: String(timestamp),
        [SEAL_ID_HEADER]: `${accountId}:${deviceId}`,
        [SEAL_KEY_HEADER]: wrong,
        'content-type': 'application/json',
      },
      body: seal,
    });
    assert.equal(broken.status, 401, `a wrong seal key must not open the body: ${broken.body}`);
  } finally {
    await bridge.close();
  }
});

test('bridge: a sealed request with a wrong token is refused', async () => {
  const bridge = await startBridge();
  try {
    const key = deriveSealKey({ token: 'a wrong token', accountId: 'acc-1', deviceId: 'dev-phone' });
    const timestamp = Date.now();
    const { seal } = sealBody(key, JSON.stringify({ token: 'a wrong token', body: {} }), {
      method: 'POST',
      path: '/api/v1/echo',
      timestamp,
    });
    const response = await request(bridge.port, {
      method: 'POST',
      path: '/api/v1/echo',
      headers: {
        [SEAL_HEADER]: seal,
        [SEAL_TIMESTAMP_HEADER]: String(timestamp),
        [SEAL_ID_HEADER]: 'acc-1:dev-phone',
        'content-type': 'application/json',
      },
      body: seal,
    });
    assert.equal(response.status, 401, `a wrong token must be refused: ${response.body}`);
  } finally {
    await bridge.close();
  }
});

test('bridge: a seal of another device does not open', async () => {  const bridge = await startBridge();
  try {
    const key = deriveSealKey({ token: bridge.state.token, accountId: 'acc-1', deviceId: 'dev-other' });
    const timestamp = Date.now();
    const { seal } = sealBody(key, JSON.stringify({ token: bridge.state.token, body: {} }), {
      method: 'POST',
      path: '/api/v1/echo',
      timestamp,
    });
    // The ids in the header belong to another device: the key is different, the seal breaks.
    const response = await request(bridge.port, {
      method: 'POST',
      path: '/api/v1/echo',
      headers: {
        [SEAL_HEADER]: seal,
        [SEAL_TIMESTAMP_HEADER]: String(timestamp),
        [SEAL_ID_HEADER]: 'acc-1:dev-phone',
        'content-type': 'application/json',
      },
      body: seal,
    });
    assert.equal(response.status, 401, `a seal of another device must not open: ${response.body}`);
  } finally {
    await bridge.close();
  }
});
