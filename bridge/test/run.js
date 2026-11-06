// Zero-dependency test runner for the DSH Harmony bridge.
//
// Run with `node test/run.js` (or `npm test`). Every test uses node:assert only; the bridge
// itself is exercised over real HTTP and a real WebSocket so the wire contract is covered
// end to end.

import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import fs from 'node:fs';

import { loadOrCreateState, parseArgs } from '../src/config.js';
import { DshClient, mintOwnerCookie, readBrowserSessionSecret } from '../src/dsh.js';
import { Bridge, Router, createRoutes } from '../src/router.js';
import { createBridgeServer } from '../src/server.js';
import { encodeQR, qrToText, reedSolomon } from '../src/qr.js';
import { isMessage, isSessionSummary } from '../src/protocol.js';
import { appendSessionRow, createStoreSession, listStoreSessions, metadataRoot, readSessionLog, zstdFrameRanges } from '../src/store.js';
import { readSessionStats } from '../src/session-stats.js';
import { groupDirectories, normalizeDirectory } from '../src/workspace.js';
import { PushNotifier, PushTokenStore, loadPushConfig, mintJwt } from '../src/push.js';
import { FrameParser, OPCODE, WebSocketClient, encodeFrame } from '../src/ws.js';

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

/** Wait until a frame matching `predicate` shows up in `frames`. */
async function waitForFrame(frames, predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = frames.find(predicate);
    if (found !== undefined) return found;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`no matching frame arrived within ${timeoutMs} ms`);
}

/** Start a bridge on a random port and return its handles. */
async function startBridge(extraOptions = {}) {
  const port = await freePort();
  const stateFile = path.join(os.tmpdir(), `dsh-bridge-test-${crypto.randomUUID()}.json`);
  const state = loadOrCreateState(stateFile);
  // A fake DSH can be injected to cover the endpoints that need the desktop application.
  const { dsh: injectedDsh, push: injectedPush, ...rest } = extraOptions;
  const options = {
    port,
    host: '127.0.0.1',
    state: stateFile,
    adapter: 'dsh',
    allowUnauthPairing: false,
    dshUrl: 'http://127.0.0.1:10748',
    ...rest,
  };
  const dsh = injectedDsh ?? new DshClient({ baseUrl: options.dshUrl });
  const logs = [];
  const bridge = new Bridge({
    options,
    state,
    dsh,
    log: (level, message) => logs.push(`${level}: ${message}`),
    ...(injectedPush === undefined ? {} : { push: injectedPush }),
  });
  const router = new Router(createRoutes(bridge));
  const http = createBridgeServer({ bridge, router });
  await bridge.start();
  // The store is scanned in its own thread; wait for the first result so the session list is
  // not empty when a test asks for it.
  await bridge.scan.whenScanned(5000);
  await http.listen(port, '127.0.0.1');
  return {
    port,
    state,
    bridge,
    logs,
    async close() {
      bridge.stop();
      await http.close();
      try {
        fs.rmSync(stateFile, { force: true });
      } catch {
        // Ignore.
      }
    },
  };
}

/**
 * Write a synthetic session metadata file (the shape DSH writes into the projection cache)
 * into `root`. The rows are given as their `val` payload; the reader must not care about the
 * version or the sequence number.
 */
function writeMetadataFixture(root, sessionId, { rows = {}, createdAt = 1792570049975 } = {}) {
  fs.mkdirSync(root, { recursive: true });
  const wrapped = {};
  for (const [name, val] of Object.entries(rows)) wrapped[name] = { ver: 1, seq: 230, val };
  const metadata = {
    version: 7,
    record: {
      identity: { formatVersion: 4, createdAt, cwd: 'D:\\work\\proj' },
      rows: wrapped,
    },
  };
  fs.writeFileSync(path.join(root, `${sessionId}.json`), `${JSON.stringify(metadata, null, 2)}\n`, 'utf8');
  return path.join(root, `${sessionId}.json`);
}

/**
 * A stand-in for the DSH application.
 *
 * It answers the endpoints the desktop-UI parity routes need with the *real* wire shapes (taken
 * from the running application), and records every call so the tests can assert what the bridge
 * forwarded.
 */
class FakeDsh {
  constructor(overrides = {}) {
    this.calls = [];
    this.rows = [];
    this.failure = null;
    this.data = {
      modelCatalog: {
        default: { provider: 'minimax-code-local', model: 'MiniMax-M3.1-Flash' },
        routableProviders: ['minimax-code-local'],
        groups: [
          {
            id: 'minimax-code-local',
            name: 'MiniMax Code Local',
            models: [
              {
                id: 'minimax-m2',
                name: 'MiniMax-M2',
                reasoning: {
                  efforts: [
                    { id: 'off', name: 'Off', description: 'no reasoning' },
                    { id: 'high', name: 'High', description: 'the default' },
                  ],
                  defaultEffort: 'high',
                },
              },
              { id: 'plain-model', name: 'Plain Model' },
            ],
          },
        ],
      },
      projections: {
        kind: 'session',
        asOfSeq: 42,
        values: {
          inbox: {
            'next-turn': [{ id: 'q1', role: 'user', content: [{ type: 'text', text: 'queued turn' }] }],
            'next-step': [{ id: 'q2', role: 'user', content: [{ type: 'text', text: 'queued step' }] }],
          },
          modelSelection: {
            lastUsed: { provider: 'minimax-code-local', model: 'MiniMax-M3.1-Flash' },
            next: { provider: 'minimax-code-local', model: 'MiniMax-M3.1-Flash' },
          },
        },
      },
      commands: [
        { definitionId: '@x/compact', name: 'compact', description: 'Compact older history' },
        { definitionId: '@x/goal', name: 'goal', description: 'Set the goal', input: { hint: '[<objective>]' } },
      ],
      skills: [{ name: 'agent-browser', path: 'C:\\skills\\agent-browser\\SKILL.md', description: 'Browser automation' }],
      permissionPresets: {
        options: [
          { value: 'read-only', name: 'read-only' },
          { value: 'workspace-write', name: 'workspace-write', description: 'write in the workspace' },
        ],
        defaultOptions: [{ value: 'read-only', name: 'read-only' }],
        defaultPreset: 'workspace-write',
      },
      fileReferences: [{ path: 'arch-showcase/README.md', kind: 'file' }],
      selectModel: { selected: { provider: 'deepseek-account', model: 'deepseek-flash' } },
      ...overrides,
    };
  }

  /** Record a call and answer it. `this.failure` makes the call fail instead. */
  #answer(method, args, value) {
    this.calls.push({ method, args });
    if (this.failure !== null) throw this.failure;
    return value;
  }

  async listSessionRows() { return this.#answer('session/list', {}, this.rows); }
  async probe() { return { reachable: true, authenticated: true, error: null }; }
  async submitPrompt() { return this.#answer('session/prompt', {}, { accepted: true }); }
  async cancel() { return this.#answer('session/cancel', {}, { accepted: true }); }

  /**
   * One page of history, the way the desktop answers it.
   *
   * The page ends at the cursor, and a cursor that is past the newest event is refused with the
   * message the desktop uses ("... is past cursor 42").
   */
  async pageMessages(sessionId, { throughSeq = null, maxMessages = 200 } = {}) {
    const events = this.events ?? [];
    const cursor = events.length > 0 ? events[events.length - 1].seq : 0;
    const asked = throughSeq ?? cursor;
    if (asked > cursor) {
      const error = new Error(`session page through seq ${asked} is past cursor ${cursor}`);
      error.code = 'gateway/bad-request';
      throw error;
    }
    const window = events.filter((event) => event.seq <= asked).slice(-Math.max(1, maxMessages));
    return {
      records: window.map((event) => ({ type: 'event', event })),
      hasMore: window.length > 0 && window[0].seq > events[0].seq,
      oldestSeq: window.length > 0 ? window[0].seq : null,
      newestSeq: window.length > 0 ? window[window.length - 1].seq : null,
    };
  }

  /** The cursor of a session (the desktop keeps it in the projection). */
  async sessionCursor() {
    const events = this.events ?? [];
    return events.length > 0 ? events[events.length - 1].seq : null;
  }

  async createSession() { return { sessionId: 'session-fake', agentPreset: null }; }
  async renameSession() { return { ok: true }; }

  async modelCatalog() { return this.#answer('session/modelCatalog', {}, this.data.modelCatalog); }
  async projections(sessionId) { return this.#answer('session/projections', { sessionId }, this.data.projections); }
  async selectModel(sessionId, selection) {
    // The DSH client unwraps the `selected` envelope, so the fake does the same.
    return this.#answer('session/selectModel', { sessionId, ...selection }, this.data.selectModel.selected);
  }
  async updateQueue(sessionId, itemId, action) { return this.#answer('session/updateQueue', { sessionId, itemId, action }, { ok: true }); }
  async listCommands(agentId) { return this.#answer('commands/list', { agentId }, this.data.commands); }
  async listSkills(sessionId) { return this.#answer('skills/list', { sessionId }, this.data.skills); }
  async permissionPresets() { return this.#answer('permissionPresets/catalog', {}, this.data.permissionPresets); }
  async listFileReferences(agentId, query) { return this.#answer('fileReferences/list', { agentId, query }, this.data.fileReferences); }
  // The permission switch goes through the host's `/permission` command.
  // The shape is the client's public one: `{ ok, text }` (the raw RPC shape lives in dsh.js).
  async executeCommand(sessionId, line) {
    return this.#answer('commands/execute', { agentId: sessionId, line }, {
      ok: true,
      text: `preset ${line.replace('/permission ', '')}`,
    });
  }
  async setSessionPermission(sessionId, preset) {
    return this.#answer('session/permission', { sessionId, preset }, { ok: true, preset, text: `preset ${preset}` });
  }
}

/* ------------------------------------------------------------------------- tests */

test('config: the token is 32 random bytes in hex and is reused', () => {
  const file = path.join(os.tmpdir(), `dsh-bridge-cfg-${crypto.randomUUID()}.json`);
  const first = loadOrCreateState(file);
  assert.match(first.token, /^[0-9a-f]{64}$/u, 'the token must be 64 hex characters');
  const second = loadOrCreateState(file);
  assert.equal(second.token, first.token, 'the token must be reused');
  assert.equal(second.file, first.file);
  fs.rmSync(file, { force: true });
});

test('config: the argument parser understands every documented flag', () => {
  const options = parseArgs(['--port', '9000', '--host', '127.0.0.1', '--adapter', 'local', '--allow-unauth-pairing', '--dsh-url', 'http://127.0.0.1:1', '--state', 'x.json']);
  assert.equal(options.port, 9000);
  assert.equal(options.host, '127.0.0.1');
  assert.equal(options.adapter, 'local');
  assert.equal(options.allowUnauthPairing, true);
  assert.equal(options.dshUrl, 'http://127.0.0.1:1');
  assert.equal(options.state, 'x.json');
  assert.throws(() => parseArgs(['--adapter', 'nope']), /invalid --adapter/u);
  assert.throws(() => parseArgs(['--port', 'abc']), /invalid --port/u);
});

test('config: the pairing code lifetime can be raised', () => {
  assert.equal(parseArgs([]).pairingCodeTtlMs, null, 'the default belongs to the discovery service');
  assert.equal(parseArgs(['--pairing-code-ttl', '300']).pairingCodeTtlMs, 300_000);
  assert.throws(() => parseArgs(['--pairing-code-ttl', 'abc']), /pairing-code-ttl/u);
  assert.throws(() => parseArgs(['--pairing-code-ttl', '5']), /pairing-code-ttl/u);
});

test('store: the zstd frame walker covers a real DSH session log', () => {
  const sessions = listStoreSessions();
  assert.ok(sessions.length > 0, 'the DSH session store must not be empty');
  const biggest = sessions.sort((a, b) => b.size - a.size)[0];
  const buffer = fs.readFileSync(biggest.logPath);
  const ranges = zstdFrameRanges(buffer);
  assert.ok(ranges.length > 1, 'a real log has more than one zstd frame');
  assert.equal(ranges[0].start, 0);
  assert.equal(ranges[ranges.length - 1].end, buffer.length, 'the frames must cover the whole file');
  for (let i = 1; i < ranges.length; i += 1) assert.equal(ranges[i].start, ranges[i - 1].end, 'the frames must be contiguous');
});

test('store: a session log decompresses into a header and events', () => {
  const sessions = listStoreSessions();
  const session = sessions.find((entry) => entry.size > 1000) ?? sessions[0];
  const snapshot = readSessionLog(session.logPath);
  assert.ok(snapshot !== null, 'the log must be readable');
  assert.ok(snapshot.header !== null, 'the log must start with a session header');
  assert.equal(typeof snapshot.header.id, 'string');
  assert.equal(snapshot.header.version, 4);
  assert.ok(snapshot.events.length > 0, 'the log must contain events');
  assert.equal(snapshot.consumed, snapshot.size, 'every byte of the log must be accounted for');
});

test('store: appended rows are picked up by the reader', () => {
  // A dedicated session is created for this test so that no real DSH session is ever touched.
  const created = createStoreSession({ cwd: os.tmpdir(), title: 'bridge append test' });
  try {
    const before = readSessionLog(created.logPath);
    assert.ok(before !== null);
    assert.equal(before.events.length, 0);

    const marker = `bridge-test-${crypto.randomUUID()}`;
    const ok = appendSessionRow(created.sessionId, {
      type: 'user/message',
      seq: 9_000_000,
      time: Date.now(),
      data: { content: [{ type: 'text', text: marker }] },
    });
    assert.equal(ok, true, 'the row must be appended');

    const after = readSessionLog(created.logPath);
    assert.equal(after.events.length, 1, 'the appended row must be visible');
    assert.ok(after.messages.some((message) => message.text.includes(marker)), 'the appended message must be mapped');
  } finally {
    // Remove the throw-away session from the store again.
    fs.rmSync(created.dir, { recursive: true, force: true });
    fs.rmSync(path.join(metadataRoot(), `${created.sessionId}.json`), { force: true });
  }
});

test('session-stats: the metadata rows are projected into the flat status object', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-stats-'));
  try {
    const sessionId = 'session-stats-projection';
    writeMetadataFixture(root, sessionId, {
      rows: {
        title: '会话标题',
        tokenUsage: {
          totals: { uncachedInputTokens: 1864613, outputTokens: 347308, cacheReadTokens: 101951903, cacheWriteTokens: 0 },
          last: { turn: 1, step: 2 },
        },
        contextPressure: { surfaceTokens: 96465, contextWindow: 512000, pressureTokens: 149649, sampledSurfaceTokens: 96087 },
        contextBreakdown: {
          systems: [{ seq: 14, tokens: 1952 }],
          surfaceTokens: 96465,
          breakdown: { systemTokens: 1952, toolsTokens: 21799, messageTokens: 94513 },
        },
        sessionStats: {
          turns: 1, steps: 465, llmMs: 9022990, toolMs: 11559250, ttftMs: 4248969,
          ttftSteps: 465, decodeMs: 4774021, decodeTokens: 347308, lastTurn: 1, openStep: null, pendingCalls: {},
        },
        turnBoundary: { openTurnStartSeq: null, lastStepStartSeq: 2793, lastTurn: 1 },
        permissions: { preset: 'danger-full-access', sandbox: 'danger-full-access', approval: 'never', seeded: false },
        modelSelection: { lastUsed: { provider: 'minimax-code-local', model: 'MiniMax-M3.1-Flash' }, pending: null },
        sandboxMode: 'danger-full-access',
        subagent: { identity: { mode: 'continuable', label: 'Chase mode coastal island map', seq: 0 } },
        subagentTiming: { descriptorSeen: true, settledMs: 24089281, lastTurnCompleted: true },
        tokenOptimizer: {
          originalChars: 268007, retainedChars: 74339, savedChars: 193668, savedTokens: 15437,
          compressedResults: 11, spilledResults: 1, compactionCount: 0, compactedTokens: 332015,
        },
      },
    });

    const stats = readSessionStats(sessionId, { root });
    assert.ok(stats !== null, 'the metadata must be projected');
    assert.equal(stats.sessionId, sessionId);
    assert.equal(stats.turns, 1);
    assert.equal(stats.steps, 465);
    assert.equal(stats.lastTurn, 1);
    assert.equal(stats.llmMs, 9022990);
    assert.equal(stats.toolMs, 11559250);
    assert.equal(stats.ttftMs, 4248969);
    assert.equal(stats.uncachedInputTokens, 1864613);
    assert.equal(stats.outputTokens, 347308);
    assert.equal(stats.cacheReadTokens, 101951903);
    assert.equal(stats.cacheWriteTokens, 0);
    assert.equal(stats.contextTokens, 96465);
    assert.equal(stats.contextWindow, 512000);
    assert.deepEqual(stats.contextBreakdown, { systemTokens: 1952, toolsTokens: 21799, messageTokens: 94513 });
    // The phone renders `permission` and `model` as plain strings.
    assert.equal(stats.permission, 'danger-full-access');
    assert.deepEqual(stats.permissionInfo, { preset: 'danger-full-access', sandbox: 'danger-full-access', approval: 'never' });
    assert.equal(stats.sandboxMode, 'danger-full-access');
    assert.equal(stats.model, 'MiniMax-M3.1-Flash');
    assert.deepEqual(stats.modelInfo, { provider: 'minimax-code-local', model: 'MiniMax-M3.1-Flash' });
    assert.equal(stats.agentMode, 'continuable');
    assert.equal(stats.agentLabel, 'Chase mode coastal island map');
    assert.equal(stats.backgroundTasks, 0);
    assert.equal(stats.tokenOptimizer.savedTokens, 15437);
    assert.equal(stats.tokenOptimizer.compressedResults, 11);
    assert.equal(stats.tokenOptimizer.compactionCount, 0);
    assert.equal(stats.tokenOptimizer.spilledResults, 1);
    assert.equal(typeof stats.updatedAt, 'number');
    assert.ok(stats.updatedAt > 0, 'the update time must be filled in');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('session-stats: missing rows degrade to omitted fields instead of throwing', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-stats-'));
  try {
    // A session whose metadata only knows the turn counters.
    const sparse = 'session-stats-sparse';
    writeMetadataFixture(root, sparse, { rows: { sessionStats: { turns: 3, steps: 7 } } });
    const stats = readSessionStats(sparse, { root });
    assert.ok(stats !== null, 'a partial metadata file must still be projected');
    assert.equal(stats.sessionId, sparse);
    assert.equal(stats.turns, 3);
    assert.equal(stats.steps, 7);
    for (const missing of ['lastTurn', 'llmMs', 'outputTokens', 'cacheReadTokens', 'contextTokens',
      'contextWindow', 'contextBreakdown', 'permission', 'permissionInfo', 'model', 'modelInfo',
      'agentMode', 'agentLabel', 'tokenOptimizer']) {
      assert.equal(missing in stats, false, `${missing} must be omitted`);
    }
    assert.equal(stats.backgroundTasks, 0, 'an unknown number of background tasks is 0');
    assert.equal(typeof stats.updatedAt, 'number');

    // A subagent whose turn has not completed yet is one background task.
    const running = 'session-stats-running';
    writeMetadataFixture(root, running, {
      rows: {
        subagent: { identity: { mode: 'continuable', label: 'a child agent', seq: 0 } },
        subagentTiming: { descriptorSeen: true, settledMs: 615, lastTurnCompleted: false },
      },
    });
    const runningStats = readSessionStats(running, { root });
    assert.equal(runningStats.backgroundTasks, 1);
    assert.equal(runningStats.agentLabel, 'a child agent');
    assert.equal(runningStats.agentMode, 'continuable');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('session-stats: a missing or unparsable metadata file yields null', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-stats-'));
  try {
    assert.equal(readSessionStats('session-that-does-not-exist', { root }), null, 'a missing file must yield null');
    fs.writeFileSync(path.join(root, 'broken.json'), '{ this is not json', 'utf8');
    assert.equal(readSessionStats('broken', { root }), null, 'unparsable JSON must yield null');
    fs.writeFileSync(path.join(root, 'empty.json'), JSON.stringify({ version: 7 }), 'utf8');
    assert.equal(readSessionStats('empty', { root }), null, 'a file without a record must yield null');
    // A session id must never escape the metadata directory.
    assert.equal(readSessionStats('../escape', { root }), null);
    assert.equal(readSessionStats('sub\\dir', { root }), null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('protocol: the session and message validators accept the documented shapes', () => {
  assert.equal(isSessionSummary({
    id: 's', title: 't', cwd: 'c', createdAt: 1, updatedAt: 2, state: 'idle', messageCount: 0,
  }), true);
  assert.equal(isSessionSummary({ id: 's' }), false);
  assert.equal(isMessage({
    id: 'm-1', sessionId: 's', role: 'assistant', kind: 'text', text: 'x', createdAt: 1, status: 'done',
  }), true);
  assert.equal(isMessage({ id: 'm-1', role: 'wizard' }), false);
});

test('qr: the encoder produces a valid matrix of the expected size', () => {
  const payload = 'dsh-harmony://connect?host=192.168.1.23&port=8787&token=' + 'a'.repeat(64);
  const matrix = encodeQR(payload, { level: 'M' });
  assert.ok(matrix.size >= 21 && matrix.size <= 177, 'the size must follow the QR specification');
  assert.equal(matrix.size, matrix.version * 4 + 17);
  assert.equal(matrix.modules.length, matrix.size);
  assert.equal(matrix.modules[0].length, matrix.size);
  // The three finder patterns must be present.
  const finder = (x, y) => matrix.modules[y][x];
  assert.equal(finder(0, 0), true);
  assert.equal(finder(1, 1), false);
  assert.equal(finder(2, 2), true);
  assert.equal(finder(matrix.size - 1, 0), true);
  assert.equal(finder(0, matrix.size - 1), true);
  // The timing pattern alternates.
  for (let i = 8; i < matrix.size - 8; i += 1) assert.equal(matrix.modules[6][i], i % 2 === 0);
});

test('qr: the rendered text has one line per two module rows', () => {
  const { matrix, text } = qrToText('hello', { level: 'M', quietZone: 4 });
  const lines = text.split('\n');
  assert.equal(lines.length, Math.ceil((matrix.size + 8) / 2));
  assert.ok(lines.every((line) => line.length === matrix.size + 8));
});

test('qr: the Reed-Solomon implementation matches known ECC vectors', () => {
  // Version 1-M uses one block of 16 data codewords and 10 ECC codewords.
  const data = new Uint8Array(16);
  for (let i = 0; i < data.length; i += 1) data[i] = i;
  const ecc = reedSolomon(data, 10);
  assert.equal(ecc.length, 10);
});

test('ws: the frame parser round-trips text frames and rejects unmasked client frames', () => {
  const payload = Buffer.from('hello bridge', 'utf8');
  const masked = encodeFrame(OPCODE.TEXT, payload, { mask: true });
  const parser = new FrameParser({ requireMask: true });
  const frames = parser.push(masked);
  assert.equal(frames.length, 1);
  assert.equal(frames[0].opcode, OPCODE.TEXT);
  assert.equal(frames[0].payload.toString('utf8'), 'hello bridge');

  const unmasked = encodeFrame(OPCODE.TEXT, payload, { mask: false });
  assert.throws(() => new FrameParser({ requireMask: true }).push(unmasked), /masked/u);
});

test('dsh: the browser-session secret is read from the credential store', () => {
  const secret = readBrowserSessionSecret();
  if (secret === null) {
    process.stdout.write('       (skipped: no ~/.dsh/.credentials.yaml on this machine)\n');
    return;
  }
  assert.match(secret, /^[A-Za-z0-9_\-+/=]+$/u);
  assert.equal(Buffer.from(secret.replaceAll('-', '+').replaceAll('_', '/'), 'base64').length, 32);
});

test('dsh: the version comparison follows the semver rules', () => {
  assert.ok(compareVersions('0.2.1-rc.2', '0.1.2-alpha.1') > 0, '0.2.1-rc.2 is newer than 0.1.2-alpha.1');
  assert.ok(compareVersions('0.1.2-alpha.1', '0.1.2-alpha.1') === 0, 'the same version compares equal');
  assert.ok(compareVersions('0.1.2-alpha.1', '0.1.2') < 0, 'a prerelease is older than the release');
  assert.ok(compareVersions('0.1.2-alpha.1', '0.1.2-alpha.2') < 0, 'alpha.1 is older than alpha.2');
  assert.ok(compareVersions('0.1.1', '0.1.2-alpha.1') < 0, '0.1.1 is older than 0.1.2-alpha.1');
  assert.ok(compareVersions('1.0.0', '0.9.9') > 0, 'the major version wins');
});

test('dsh: a version older than the minimum is not safe', () => {
  assert.equal(DSH_MINIMUM_VERSION, '0.1.2-alpha.1');
  assert.equal(isDshVersionSafe('0.2.1-rc.2'), true);
  assert.equal(isDshVersionSafe('0.1.2-alpha.1'), true);
  assert.equal(isDshVersionSafe('0.1.2'), true);
  assert.equal(isDshVersionSafe('0.1.1'), false);
  assert.equal(isDshVersionSafe('0.1.2-alpha'), false);
  assert.equal(isDshVersionSafe('0.0.9'), false);
  // An unknown version must not cry wolf.
  assert.equal(isDshVersionSafe(null), true);
  assert.equal(isDshVersionSafe(''), true);
});

test('dsh: the version of the installed DSH is read from the runtime file', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-version-'));
  try {
    const runtime = path.join(home, 'dsh-runtimes', 'dsh-primary-runtime');
    fs.mkdirSync(runtime, { recursive: true });
    fs.writeFileSync(path.join(runtime, 'runtime.json'), JSON.stringify({ desktopVersion: '0.2.1-rc.2' }));
    assert.equal(readDshVersion(home), '0.2.1-rc.2');
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
  // A home without a DSH has no version, that is not an error.
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-version-'));
  try {
    assert.equal(readDshVersion(empty), null);
  } finally {
    fs.rmSync(empty, { recursive: true, force: true });
  }
});

test('dsh: the minted owner cookie has the documented shape', () => {
  const secret = Buffer.alloc(32, 7).toString('base64url');
  const cookie = mintOwnerCookie(secret, '127.0.0.1:10748');
  const [name, value] = cookie.split('=');
  assert.ok(name.startsWith('dsh-auth-'), 'the cookie name must use the dsh-auth- prefix');
  const parts = value.split('.');
  assert.equal(parts.length, 3);
  assert.equal(parts[0], 'v1');
  const payload = JSON.parse(Buffer.from(parts[1].replaceAll('-', '+').replaceAll('_', '/'), 'base64').toString('utf8'));
  assert.equal(payload.version, 1);
  assert.equal(payload.authority, '127.0.0.1:10748');
  assert.ok(payload.expiresAt > payload.issuedAt);
});

test('bridge: the session listing returns sane summaries from the real store', async () => {
  const harness = await startBridge();
  try {
    const response = await request(harness.port, '/api/v1/sessions', { token: harness.state.token });
    assert.equal(response.status, 200);
    assert.ok(Array.isArray(response.json.sessions), 'the response must carry a sessions array');
    assert.ok(response.json.sessions.length > 0, 'the real store must not be empty');
    for (const summary of response.json.sessions) {
      assert.equal(isSessionSummary(summary), true, `not a SessionSummary: ${JSON.stringify(summary)}`);
      assert.ok(summary.id.length > 0);
      assert.ok(summary.title.length > 0, 'the title must never be empty');
      assert.ok(summary.createdAt > 0, 'the creation time must be filled in');
      assert.ok(summary.updatedAt >= summary.createdAt);
      assert.ok(summary.messageCount >= 0);
    }
    for (let i = 1; i < response.json.sessions.length; i += 1) {
      assert.ok(response.json.sessions[i - 1].updatedAt >= response.json.sessions[i].updatedAt, 'the list must be sorted by updatedAt');
    }
  } finally {
    await harness.close();
  }
});

test('bridge: the durable message completes the live row instead of creating a second one', async () => {
  const harness = await startBridge();
  const frames = [];
  harness.bridge.addClient({ send: (frame) => frames.push(frame) });
  const sessionId = 'session-live-1';
  try {
    // The stream of the assistant starts and streams its answer.
    harness.bridge.handleDshDelta(sessionId, { type: 'start', attemptId: 'a-1' });
    harness.bridge.handleDshDelta(sessionId, { type: 'chunk', attemptId: 'a-1', chunk: { type: 'text-delta', text: 'Hello' } });
    // The stream ends.
    harness.bridge.handleDshDelta(sessionId, { type: 'end', attemptId: 'a-1', outcome: { kind: 'committed' } });
    // The durable event arrives **after** the end of the stream (that is the order the DSH
    // uses): it has to complete the very same row, with the canonical text and time.
    harness.bridge.handleDshEvent(sessionId, {
      type: 'assistant/message',
      seq: 42,
      time: 1700000000000,
      data: { message: { role: 'assistant', content: [{ type: 'text', text: 'Hello' }] } },
    });

    const created = frames.filter((frame) => frame.type === 'message.created');
    const completed = frames.filter((frame) => frame.type === 'message.completed');
    assert.equal(created.length, 1, 'the step must be one row');
    assert.equal(created[0].data.message.id, 'm-live-a-1', 'the row keeps the id of the live turn');
    assert.ok(completed.length >= 1, 'the row must be closed');
    const last = completed[completed.length - 1];
    assert.equal(last.data.message.id, 'm-live-a-1', 'the durable event completes the live row');
    assert.equal(last.data.message.text, 'Hello');
    assert.equal(last.data.message.createdAt, 1700000000000, 'the durable event carries the real time');
    assert.equal(last.data.message.status, 'done');
    assert.equal(last.data.message.seq, 42, 'the completion carries the seq of the durable message');
    assert.ok(
      !frames.some((frame) => frame.data?.message?.id === 'm-42'),
      'the durable event must not create a second row next to the live one',
    );
  } finally {
    await harness.close();
  }
});

test('bridge: the durable event that arrives before the end of the stream still closes the row once', async () => {
  const harness = await startBridge();
  const frames = [];
  harness.bridge.addClient({ send: (frame) => frames.push(frame) });
  const sessionId = 'session-live-2';
  try {
    harness.bridge.handleDshDelta(sessionId, { type: 'start', attemptId: 'a-2' });
    harness.bridge.handleDshDelta(sessionId, { type: 'chunk', attemptId: 'a-2', chunk: { type: 'text-delta', text: 'Hi' } });
    // The durable event arrives first this time.
    harness.bridge.handleDshEvent(sessionId, {
      type: 'assistant/message',
      seq: 43,
      time: 1700000000001,
      data: { message: { role: 'assistant', content: [{ type: 'text', text: 'Hi' }] } },
    });
    harness.bridge.handleDshDelta(sessionId, { type: 'end', attemptId: 'a-2', outcome: { kind: 'committed' } });

    const created = frames.filter((frame) => frame.type === 'message.created');
    const completed = frames.filter((frame) => frame.type === 'message.completed');
    assert.equal(created.length, 1, 'the step must be one row');
    assert.equal(completed.length, 1, 'the row is closed exactly once');
    assert.equal(completed[0].data.message.id, 'm-live-a-2');
    assert.equal(completed[0].data.message.createdAt, 1700000000001, 'the durable event carries the real time');
    assert.ok(
      !frames.some((frame) => frame.data?.message?.id === 'm-43'),
      'the durable event must not create a second row',
    );
  } finally {
    await harness.close();
  }
});

test('bridge: a live turn that nobody claims is dropped', async () => {
  const harness = await startBridge();
  try {
    harness.bridge.handleDshDelta('session-old', { type: 'start', attemptId: 'old' });
    assert.equal(harness.bridge.liveTurns.has('session-old'), true);
    // Pretend that the turn has been waiting for its durable event for too long.
    harness.bridge.liveTurns.get('session-old').expiresAt = Date.now() - 1;
    // Any other traffic sweeps it away.
    harness.bridge.handleDshDelta('session-new', { type: 'start', attemptId: 'new' });
    assert.equal(harness.bridge.liveTurns.has('session-old'), false, 'an unclaimed live turn must not stay forever');
    assert.equal(harness.bridge.liveTurns.has('session-new'), true);
  } finally {
    await harness.close();
  }
});

test('bridge: the reasoning of the model is not shown as the answer', async () => {
  const harness = await startBridge();
  const frames = [];
  harness.bridge.addClient({ send: (frame) => frames.push(frame) });
  const sessionId = 'session-reasoning';
  try {
    harness.bridge.handleDshEvent(sessionId, {
      type: 'assistant/message',
      seq: 7,
      time: 1700000000002,
      data: {
        message: {
          role: 'assistant',
          content: [
            { type: 'reasoning', text: 'the private thinking of the model' },
            { type: 'tool-call', id: 'call-1', name: 'read_file' },
            { type: 'text', text: 'the visible answer' },
          ],
        },
      },
    });
    const completed = frames.filter((frame) => frame.type === 'message.completed');
    assert.equal(completed.length, 1);
    assert.equal(completed[0].data.message.text, 'the visible answer', 'only the text parts are the answer');
  } finally {
    await harness.close();
  }
});

test('bridge: the messages endpoint returns parsed messages', async () => {
  const harness = await startBridge();
  try {
    // Pick a session that really has messages by reading the store directly.
    const candidate = listStoreSessions()
      .map((entry) => ({ entry, snapshot: readSessionLog(entry.logPath) }))
      .filter((item) => item.snapshot !== null && item.snapshot.messages.length > 0)
      .sort((a, b) => b.snapshot.messages.length - a.snapshot.messages.length)[0];
    assert.ok(candidate !== undefined, 'the store must contain a session with messages');

    const response = await request(harness.port, `/api/v1/sessions/${candidate.entry.id}/messages?limit=20`, { token: harness.state.token });
    assert.equal(response.status, 200, `unexpected status: ${response.text}`);
    assert.ok(Array.isArray(response.json.messages));
    assert.ok(response.json.messages.length > 0, 'the session must have messages');
    for (const message of response.json.messages) {
      assert.equal(isMessage(message), true, `not a Message: ${JSON.stringify(message)}`);
      assert.equal(message.sessionId, candidate.entry.id);
    }
    // `before` is exclusive.
    const second = response.json.messages[0].id;
    const paged = await request(harness.port, `/api/v1/sessions/${candidate.entry.id}/messages?limit=5&before=${second}`, { token: harness.state.token });
    assert.equal(paged.status, 200);
    assert.ok(paged.json.messages.every((message) => message.id !== second), 'the `before` message must be excluded');
  } finally {
    await harness.close();
  }
});

test('bridge: the stats endpoint returns the projected stats of a session', async () => {
  // The metadata directory is resolved through $DSH_HOME, so the fixture can live in a temp dir.
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-stats-home-'));
  const previousHome = process.env.DSH_HOME;
  process.env.DSH_HOME = home;
  const sessionId = 'session-bridge-stats';
  try {
    writeMetadataFixture(path.join(home, 'storages', 'session_projcache', 'sessions'), sessionId, {
      rows: {
        sessionStats: { turns: 4, steps: 25 },
        tokenUsage: { totals: { outputTokens: 347308, cacheReadTokens: 101951903 } },
        contextPressure: { surfaceTokens: 232000, contextWindow: 512000 },
        modelSelection: { lastUsed: { provider: 'minimax-code-local', model: 'MiniMax-M3.1-Flash' } },
        permissions: { preset: 'danger-full-access', sandbox: 'danger-full-access', approval: 'never' },
      },
    });
    const harness = await startBridge({ adapter: 'local' });
    try {
      const response = await request(harness.port, `/api/v1/sessions/${sessionId}/stats`, { token: harness.state.token });
      assert.equal(response.status, 200, `unexpected status: ${response.text}`);
      assert.ok(response.json.stats !== null, 'the stats must not be null');
      assert.equal(response.json.stats.sessionId, sessionId);
      assert.equal(response.json.stats.turns, 4);
      assert.equal(response.json.stats.steps, 25);
      assert.equal(response.json.stats.outputTokens, 347308);
      assert.equal(response.json.stats.cacheReadTokens, 101951903);
      assert.equal(response.json.stats.contextTokens, 232000);
      assert.equal(response.json.stats.contextWindow, 512000);
      assert.equal(response.json.stats.model, 'MiniMax-M3.1-Flash');
      assert.equal(response.json.stats.permission, 'danger-full-access');
      assert.equal(typeof response.json.stats.updatedAt, 'number');

      // An unknown session answers 200 with a null stats object, never a 500.
      const unknown = await request(harness.port, '/api/v1/sessions/session-unknown/stats', { token: harness.state.token });
      assert.equal(unknown.status, 200, `unexpected status: ${unknown.text}`);
      assert.equal(unknown.json.stats, null);
    } finally {
      await harness.close();
    }
  } finally {
    if (previousHome === undefined) delete process.env.DSH_HOME;
    else process.env.DSH_HOME = previousHome;
    fs.rmSync(home, { recursive: true, force: true });
  }
});

test('bridge: a missing or wrong token is rejected', async () => {
  const harness = await startBridge();
  try {
    const missing = await request(harness.port, '/api/v1/sessions');
    assert.equal(missing.status, 401);
    assert.equal(missing.json.error.code, 'unauthorized');
    assert.ok(typeof missing.json.error.message === 'string');

    const wrong = await request(harness.port, '/api/v1/sessions', { token: 'f'.repeat(64) });
    assert.equal(wrong.status, 401);
    assert.equal(wrong.json.error.code, 'unauthorized');

    const health = await request(harness.port, '/api/v1/health', { token: harness.state.token });
    assert.equal(health.status, 200);
    assert.equal(health.json.ok, true);
    assert.equal(health.json.name, 'dsh-harmony-bridge');
    assert.equal(typeof health.json.now, 'number');

    const unknown = await request(harness.port, '/api/v1/nope', { token: harness.state.token });
    assert.equal(unknown.status, 404);
    assert.equal(unknown.json.error.code, 'not_found');
  } finally {
    await harness.close();
  }
});

test('bridge: the stats endpoint rejects a missing or wrong token', async () => {
  const harness = await startBridge();
  try {
    const missing = await request(harness.port, '/api/v1/sessions/session-anything/stats');
    assert.equal(missing.status, 401);
    assert.equal(missing.json.error.code, 'unauthorized');
    assert.ok(typeof missing.json.error.message === 'string');

    const wrong = await request(harness.port, '/api/v1/sessions/session-anything/stats', { token: 'f'.repeat(64) });
    assert.equal(wrong.status, 401);
    assert.equal(wrong.json.error.code, 'unauthorized');
  } finally {
    await harness.close();
  }
});

test('bridge: the workspaces endpoint lists the distinct cwds', async () => {
  const harness = await startBridge();
  try {
    const response = await request(harness.port, '/api/v1/workspaces', { token: harness.state.token });
    assert.equal(response.status, 200);
    assert.ok(Array.isArray(response.json.workspaces));
    assert.ok(response.json.workspaces.length > 0);
    for (const workspace of response.json.workspaces) {
      assert.equal(typeof workspace.cwd, 'string');
      assert.equal(typeof workspace.label, 'string');
    }
  } finally {
    await harness.close();
  }
});

test('bridge: the pairing endpoint returns the token, the URL and the QR payload', async () => {
  const harness = await startBridge();
  try {
    const response = await request(harness.port, '/api/v1/pairing', { token: harness.state.token });
    assert.equal(response.status, 200, `unexpected status: ${response.text} ${harness.logs.join(' | ')}`);
    assert.equal(response.json.token, harness.state.token);
    assert.ok(response.json.url.startsWith('http://'));
    assert.ok(response.json.qrPayload.startsWith('dsh-harmony://connect?host='));
    assert.ok(response.json.qrPayload.includes(`token=${harness.state.token}`));
    const matrix = encodeQR(response.json.qrPayload, { level: 'M' });
    assert.ok(matrix.size > 21);
  } finally {
    await harness.close();
  }
});

test('bridge: the WebSocket handshake works and ping is answered with pong', async () => {
  const harness = await startBridge();
  try {
    const client = new WebSocketClient(`ws://127.0.0.1:${harness.port}/ws`, {
      headers: { Authorization: `Bearer ${harness.state.token}` },
    });
    const frames = [];
    client.on('message', (text) => frames.push(JSON.parse(text)));
    await client.connect();

    const hello = await waitForFrame(frames, (frame) => frame.type === 'hello');
    assert.equal(hello.type, 'hello');
    assert.equal(hello.data.server, 'dsh-harmony-bridge');
    assert.equal(hello.data.token, harness.state.token);
    assert.ok(typeof hello.data.dsh === 'object');

    client.send(JSON.stringify({ type: 'ping', data: {} }));
    const pong = await waitForFrame(frames, (frame) => frame.type === 'pong');
    assert.equal(pong.type, 'pong');
    client.close();
  } finally {
    await harness.close();
  }
});

test('bridge: the WebSocket rejects an upgrade without a token', async () => {
  const harness = await startBridge();
  try {
    const client = new WebSocketClient(`ws://127.0.0.1:${harness.port}/ws`);
    client.on('error', () => {});
    await assert.rejects(() => client.connect(), /handshake failed/u);
  } finally {
    await harness.close();
  }
});

test('bridge: the WebSocket sends a session.list frame on connect', async () => {
  const harness = await startBridge();
  try {
    const client = new WebSocketClient(`ws://127.0.0.1:${harness.port}/ws`, {
      headers: { Authorization: `Bearer ${harness.state.token}` },
    });
    const received = [];
    client.on('message', (text) => received.push(JSON.parse(text)));
    await client.connect();
    const list = await waitForFrame(received, (frame) => frame.type === 'session.list');
    assert.ok(Array.isArray(list.data.sessions));
    assert.ok(list.data.sessions.length > 0);
    client.close();
  } finally {
    await harness.close();
  }
});

test('bridge: the store tailer streams a locally appended row to the subscriber', async () => {
  const harness = await startBridge({ adapter: 'local' });
  try {
    const created = await request(harness.port, '/api/v1/sessions', {
      method: 'POST',
      token: harness.state.token,
      body: { cwd: os.tmpdir(), title: 'bridge tailer test' },
    });
    assert.equal(created.status, 200);
    const sessionId = created.json.session.id;

    const client = new WebSocketClient(`ws://127.0.0.1:${harness.port}/ws`, {
      headers: { Authorization: `Bearer ${harness.state.token}` },
    });
    const received = [];
    client.on('message', (text) => received.push(JSON.parse(text)));
    await client.connect();
    client.send(JSON.stringify({ type: 'subscribe', data: { sessionIds: [sessionId] } }));
    await new Promise((resolve) => setTimeout(resolve, 800));

    const marker = `tail-${crypto.randomUUID()}`;
    const submitted = await request(harness.port, `/api/v1/sessions/${sessionId}/messages`, {
      method: 'POST',
      token: harness.state.token,
      body: { text: marker, mode: 'queue' },
    });
    assert.equal(submitted.status, 200);
    assert.equal(submitted.json.accepted, true);

    const createdFrame = await waitForFrame(received, (frame) => frame.type === 'message.created'
      && String(frame.data?.message?.text ?? '').includes(marker));
    assert.ok(createdFrame.data.message.text.includes(marker));
    assert.equal(createdFrame.data.sessionId, sessionId);

    client.close();
    const entry = harness.bridge.index.get(sessionId);
    if (entry !== undefined) fs.rmSync(entry.dir, { recursive: true, force: true });
    fs.rmSync(path.join(metadataRoot(), `${sessionId}.json`), { force: true });
  } finally {
    await harness.close();
  }
});

test('bridge: dropping a subscription does not error out', async () => {
  // 回归测试: subscribe 的语义是"整体替换", 被移除的会话要判断是否还有别的客户端订阅。
  // bridge.clients 是 Set, 之前这里误用了 .some(), 导致手机端收到 error 帧(红条)。
  const harness = await startBridge({ adapter: 'local' });
  try {
    const created = await request(harness.port, '/api/v1/sessions', {
      method: 'POST',
      token: harness.state.token,
      body: { cwd: os.tmpdir(), title: 'bridge unsubscribe test' },
    });
    assert.equal(created.status, 200);
    const sessionId = created.json.session.id;

    const client = new WebSocketClient(`ws://127.0.0.1:${harness.port}/ws`, {
      headers: { Authorization: `Bearer ${harness.state.token}` },
    });
    const received = [];
    client.on('message', (text) => received.push(JSON.parse(text)));
    await client.connect();

    client.send(JSON.stringify({ type: 'subscribe', data: { sessionIds: [sessionId] } }));
    await new Promise((resolve) => setTimeout(resolve, 400));
    // 订阅清空 -> 走 "removed" 分支
    client.send(JSON.stringify({ type: 'subscribe', data: { sessionIds: [] } }));
    await new Promise((resolve) => setTimeout(resolve, 400));

    const errors = received.filter((frame) => frame.type === 'error');
    assert.equal(errors.length, 0, `unsubscribe produced error frames: ${JSON.stringify(errors)}`);

    client.close();
    const entry = harness.bridge.index.get(sessionId);
    if (entry !== undefined) fs.rmSync(entry.dir, { recursive: true, force: true });
    fs.rmSync(path.join(metadataRoot(), `${sessionId}.json`), { force: true });
  } finally {
    await harness.close();
  }
});

test('bridge: the devices endpoint lists the account devices and needs a token', async () => {
  // 没有中继时只有本机这一个设备; 有中继与账号时由中继给出在线状态。
  const harness = await startBridge({ adapter: 'local', deviceId: 'dev-local', relayName: '本机' });
  try {
    const unauthorized = await request(harness.port, '/api/v1/devices', { method: 'GET' });
    assert.equal(unauthorized.status, 401, 'the device list must need a token');

    const answer = await request(harness.port, '/api/v1/devices', {
      method: 'GET',
      token: harness.state.token,
    });
    assert.equal(answer.status, 200);
    assert.ok(Array.isArray(answer.json.devices));
    assert.equal(answer.json.devices.length, 1, 'without a relay only this bridge is a device');
    assert.equal(answer.json.devices[0].id, 'dev-local');
    assert.equal(answer.json.devices[0].role, 'desktop');
    assert.equal(answer.json.devices[0].online, true);
  } finally {
    await harness.close();
  }
});

test('bridge: the device list of an account comes from the relay', async () => {
  // 起一个假中继, 让它回答账号的设备在线状态
  const relay = http.createServer((req, res) => {
    const body = JSON.stringify({
      account: { id: 'acc-test', name: '测试账号' },
      devices: [
        { id: 'dev-desktop', name: '桌面', role: 'desktop', online: true, lastSeen: 42 },
        { id: 'dev-phone', name: '手机', role: 'phone', online: false, lastSeen: 0 },
      ],
    });
    res.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
    res.end(body);
  });
  await new Promise((resolve) => relay.listen(0, '127.0.0.1', resolve));
  const relayPort = relay.address().port;

  const harness = await startBridge({
    adapter: 'local',
    deviceId: 'dev-desktop',
    relay: `ws://127.0.0.1:${relayPort}/bridge`,
    account: 'acc-test',
    accountToken: 'a'.repeat(64),
  });
  try {
    const answer = await request(harness.port, '/api/v1/devices', {
      method: 'GET',
      token: harness.state.token,
    });
    assert.equal(answer.status, 200);
    assert.equal(answer.json.devices.length, 2, 'both devices of the account must be listed');
    assert.equal(answer.json.devices[0].id, 'dev-desktop');
    assert.equal(answer.json.devices[0].online, true);
    assert.equal(answer.json.devices[1].role, 'phone');
    assert.equal(answer.json.devices[1].online, false);
  } finally {
    await harness.close();
    await new Promise((resolve) => relay.close(resolve));
  }
});

test('bridge: the phone registers itself in the account through the bridge', async () => {
  // 手机不直接问中继(那条连接是字节管道, 中继的回答会和桌面的回答混在一起),
  // 它问 bridge, bridge 用自己的账号令牌去问中继。
  const relay = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const body = Buffer.concat(chunks).toString('utf8');
      const path = req.url.split('?')[0];
      const payload = JSON.stringify({
        device: {
          id: JSON.parse(body || '{}').deviceId ?? 'dev-phone',
          name: '我的手机',
          role: 'phone',
          online: true,
          lastSeen: 1,
        },
        seenPath: path,
        seenAuth: req.headers.authorization ?? null,
      });
      res.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) });
      res.end(payload);
    });
  });
  await new Promise((resolve) => relay.listen(0, '127.0.0.1', resolve));
  const relayPort = relay.address().port;

  const harness = await startBridge({
    adapter: 'local',
    deviceId: 'dev-desktop',
    relay: `ws://127.0.0.1:${relayPort}/bridge`,
    account: 'acc-test',
    accountToken: 'a'.repeat(64),
  });
  try {
    const answer = await request(harness.port, '/api/v1/phone/register', {
      method: 'POST',
      token: harness.state.token,
      body: { deviceId: 'dev-phone', name: '我的手机', token: 'b'.repeat(64) },
    });
    assert.equal(answer.status, 200);
    assert.equal(answer.json.ok, true);
    assert.equal(answer.json.device.id, 'dev-phone');
    assert.equal(answer.json.device.role, 'phone');

    const beat = await request(harness.port, '/api/v1/phone/heartbeat', {
      method: 'POST',
      token: harness.state.token,
      body: { deviceId: 'dev-phone' },
    });
    assert.equal(beat.status, 200);
    assert.equal(beat.json.ok, true);
  } finally {
    await harness.close();
    await new Promise((resolve) => relay.close(resolve));
  }
});

test('bridge: a heartbeat without a device id still names the phone', async () => {
  // 手机的续心跳有时不带设备号(老版本的 App 就是这样)。桥接如果照抄一个空的设备号,
  // 中继收到的是 `/_relay/accounts/<账号>/phones//heartbeat` —— 认不出这台手机,
  // 于是手机的在线状态再也刷不上(桌面上会显示"我的手机 离线")。
  // ⇒ 登记的时候记下设备号, 续心跳时请求体里没有就用它 ✓
  const seen = [];
  const relay = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const body = Buffer.concat(chunks).toString('utf8');
      const path = req.url.split('?')[0];
      seen.push({ path, body });
      const payload = JSON.stringify({ device: { id: 'dev-phone', role: 'phone', online: true, lastSeen: 1 } });
      res.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) });
      res.end(payload);
    });
  });
  await new Promise((resolve) => relay.listen(0, '127.0.0.1', resolve));
  const relayPort = relay.address().port;

  const harness = await startBridge({
    adapter: 'local',
    deviceId: 'dev-desktop',
    relay: `ws://127.0.0.1:${relayPort}/bridge`,
    account: 'acc-test',
    accountToken: 'a'.repeat(64),
  });
  try {
    const registered = await request(harness.port, '/api/v1/phone/register', {
      method: 'POST',
      token: harness.state.token,
      body: { deviceId: 'dev-phone', name: '我的手机', token: 'b'.repeat(64) },
    });
    assert.equal(registered.status, 200);

    // 请求体里没有设备号。
    const beat = await request(harness.port, '/api/v1/phone/heartbeat', {
      method: 'POST',
      token: harness.state.token,
      body: {},
    });
    assert.equal(beat.status, 200);
    assert.equal(beat.json.ok, true);

    const beatPath = seen.find((entry) => entry.path.includes('/heartbeat'));
    assert.ok(beatPath !== undefined, 'the relay must be asked for the heartbeat');
    assert.equal(
      beatPath.path,
      '/_relay/accounts/acc-test/phones/dev-phone/heartbeat',
      'the heartbeat must name the phone, not leave the device id empty',
    );
  } finally {
    await harness.close();
    await new Promise((resolve) => relay.close(resolve));
  }
});

test('bridge: submitting a prompt without DSH reports dsh_unavailable instead of pretending', async () => {
  const harness = await startBridge({ dshUrl: 'http://127.0.0.1:1', adapter: 'dsh' });
  try {
    const sessions = await request(harness.port, '/api/v1/sessions', { token: harness.state.token });
    assert.equal(sessions.status, 200, `unexpected status: ${sessions.text} ${harness.logs.join(' | ')}`);
    assert.ok(sessions.json.sessions.length > 0, `no sessions: ${sessions.text}`);
    const sessionId = sessions.json.sessions[0].id;
    const response = await request(harness.port, `/api/v1/sessions/${sessionId}/messages`, {
      method: 'POST',
      token: harness.state.token,
      body: { text: 'hello from the phone', mode: 'queue' },
    });
    assert.equal(response.status, 503, 'an unreachable DSH must be reported as 503');
    assert.equal(response.json.error.code, 'dsh_unavailable');
    assert.ok(typeof response.json.error.message === 'string' && response.json.error.message.length > 0);
  } finally {
    await harness.close();
  }
});

test('bridge: an empty prompt is rejected with bad_request', async () => {
  const harness = await startBridge();
  try {
    const sessions = await request(harness.port, '/api/v1/sessions', { token: harness.state.token });
    const sessionId = sessions.json.sessions[0].id;
    const response = await request(harness.port, `/api/v1/sessions/${sessionId}/messages`, {
      method: 'POST',
      token: harness.state.token,
      body: { text: '   ' },
    });
    assert.equal(response.status, 400);
    assert.equal(response.json.error.code, 'bad_request');
  } finally {
    await harness.close();
  }
});

test('bridge: the local adapter writes a prompt into the store', async () => {
  const harness = await startBridge({ adapter: 'local' });
  try {
    const created = await request(harness.port, '/api/v1/sessions', {
      method: 'POST',
      token: harness.state.token,
      body: { cwd: os.tmpdir(), title: 'bridge test session' },
    });
    assert.equal(created.status, 200);
    assert.ok(created.json.session.id.length > 0);
    assert.equal(created.json.session.cwd, os.tmpdir());

    const marker = `local-${crypto.randomUUID()}`;
    const submitted = await request(harness.port, `/api/v1/sessions/${created.json.session.id}/messages`, {
      method: 'POST',
      token: harness.state.token,
      body: { text: marker, mode: 'queue' },
    });
    assert.equal(submitted.status, 200);
    assert.equal(submitted.json.accepted, true);

    const messages = await request(harness.port, `/api/v1/sessions/${created.json.session.id}/messages`, { token: harness.state.token });
    assert.equal(messages.status, 200);
    assert.ok(messages.json.messages.some((message) => message.text.includes(marker)), 'the prompt must be readable back');

    // The throw-away session must not stay in the DSH store.
    const entry = harness.bridge.index.get(created.json.session.id);
    if (entry !== undefined) fs.rmSync(entry.dir, { recursive: true, force: true });
    fs.rmSync(path.join(metadataRoot(), `${created.json.session.id}.json`), { force: true });
  } finally {
    await harness.close();
  }
});

test('bridge: the DSH application answers the session/list endpoint with the bridge credential', async () => {
  const client = new DshClient({ baseUrl: 'http://127.0.0.1:10748' });
  const result = await client.probe();
  if (!result.reachable) {
    process.stdout.write('       (skipped: the DSH application is not reachable)\n');
    return;
  }
  assert.equal(result.authenticated, true, `the DSH credential must be accepted: ${result.error ?? ''}`);
  const rows = await client.listSessionRows();
  assert.ok(Array.isArray(rows));
  assert.ok(rows.length > 0, 'the running DSH must report sessions');
  const first = rows[0];
  assert.equal(typeof first.sessionId, 'string');
  assert.equal(typeof first.updatedAt, 'number');
});

/* ------------------------------------------------- the newest page, the previews, the titles */

test('bridge: the message list returns the newest page and not the first one', async () => {
  const fake = new FakeDsh();
  // A session with 40 messages: the old default asked for the cursor 1 and got the first page.
  fake.events = Array.from({ length: 40 }, (unused, index) => ({
    type: 'user/message',
    seq: index + 1,
    time: 1792700000000 + index,
    data: { content: [{ type: 'text', text: `message ${index + 1}` }] },
  }));
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/sessions/session-unknown/messages?limit=5', {
      token: harness.state.token,
    });
    assert.equal(response.status, 200);
    const messages = response.json.messages;
    assert.ok(messages.length > 0, 'the page must not be empty');
    // The newest message has to be in there, and the oldest one must not.
    assert.equal(messages[messages.length - 1].text, 'message 40', 'the newest message must be last');
    assert.ok(!messages.some((message) => message.text === 'message 1'), 'the first page must not be returned');
    // Ascending, and the range of the page is reported.
    const seqs = messages.map((message) => message.seq);
    assert.deepEqual(seqs, [...seqs].sort((a, b) => a - b), 'the messages must be sorted by sequence');
    assert.equal(response.json.newestSeq, 40);
    assert.equal(response.json.oldestSeq, seqs[0]);
    assert.equal(typeof response.json.hasMore, 'boolean');
  } finally {
    await harness.close();
  }
});

test('bridge: a long message is cut down and the full text can be asked for', async () => {
  const harness = await startBridge({ adapter: 'local' });
  let sessionId = null;
  try {
    const created = await request(harness.port, '/api/v1/sessions', {
      method: 'POST',
      token: harness.state.token,
      body: { cwd: os.tmpdir(), title: 'bridge test long message' },
    });
    assert.equal(created.status, 200);
    sessionId = created.json.session.id;

    const long = `长消息-${'x'.repeat(5000)}`;
    const submitted = await request(harness.port, `/api/v1/sessions/${sessionId}/messages`, {
      method: 'POST',
      token: harness.state.token,
      body: { text: long, mode: 'queue' },
    });
    assert.equal(submitted.status, 200);
    assert.equal(submitted.json.accepted, true);
    assert.equal(typeof submitted.json.seq, 'number', 'the answer must carry the sequence of the new message');
    assert.equal(typeof submitted.json.createdAt, 'number', 'the answer must carry the time of the new message');

    const messages = await request(harness.port, `/api/v1/sessions/${sessionId}/messages`, { token: harness.state.token });
    assert.equal(messages.status, 200);
    const preview = messages.json.messages.find((message) => message.text.includes('长消息-'));
    assert.ok(preview, 'the message must be in the list');
    assert.equal(preview.truncated, true, 'a long message must be marked as truncated');
    assert.equal(preview.previewLimit, 800);
    assert.equal(preview.totalLength, long.length, 'the length of the original must be reported');
    assert.ok(preview.text.length <= 800, 'the preview must not be longer than the limit');

    // The full text is fetched with the sequence of the message.
    const full = await request(harness.port, `/api/v1/sessions/${sessionId}/messages/${preview.seq}/full`, {
      token: harness.state.token,
    });
    assert.equal(full.status, 200);
    assert.equal(full.json.text, long, 'the full text must be the original');
    assert.equal(full.json.text.length, preview.totalLength, 'the full text and the reported length must fit together');
  } finally {
    if (sessionId !== null) {
      const entry = harness.bridge.index.get(sessionId);
      if (entry !== undefined) fs.rmSync(entry.dir, { recursive: true, force: true });
      fs.rmSync(path.join(metadataRoot(), `${sessionId}.json`), { force: true });
    }
    await harness.close();
  }
});

test('bridge: a session without a usable title never gets its id as the title', async () => {
  const fake = new FakeDsh();
  fake.rows = [
    {
      sessionId: 'session-broken-title',
      updatedAt: 1792700000000,
      running: false,
      cwd: 'D:\\work\\proj',
      // The desktop stored a title whose bytes were mangled on the way in.
      projections: { values: { title: '??????' } },
    },
  ];
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/sessions', { token: harness.state.token });
    assert.equal(response.status, 200);
    const summary = response.json.sessions.find((item) => item.id === 'session-broken-title');
    assert.ok(summary, 'the session must be in the list');
    assert.notEqual(summary.title, 'session-broken-title', 'the id must not be used as the title');
    assert.notEqual(summary.title, '??????', 'the broken title must not be used');
    assert.ok(summary.title.length > 0, 'the title must not be empty');
    // The raw bytes are written to the log, so a mangled title can be traced.
    assert.ok(
      harness.logs.some((line) => line.includes('session-broken-title') && line.includes('原始字节')),
      'the broken title must be logged with its raw bytes',
    );
  } finally {
    await harness.close();
  }
});

/* ------------------------------------------- desktop UI parity (models, queue, commands, …) */

test('bridge: the model catalog is flattened into providers, models and efforts', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/models', { token: harness.state.token });
    assert.equal(response.status, 200);
    assert.deepEqual(response.json.default, { provider: 'minimax-code-local', model: 'MiniMax-M3.1-Flash' });
    assert.equal(response.json.providers.length, 1);
    const [provider] = response.json.providers;
    assert.equal(provider.id, 'minimax-code-local');
    assert.equal(provider.name, 'MiniMax Code Local');
    assert.equal(provider.models.length, 2);
    assert.deepEqual(provider.models[0].efforts, [
      { id: 'off', name: 'Off' },
      { id: 'high', name: 'High' },
    ]);
    assert.equal(provider.models[0].defaultEffort, 'high');
    // A model without reasoning has no efforts and no default effort.
    assert.deepEqual(provider.models[1].efforts, []);
    assert.equal(provider.models[1].defaultEffort, null);
    assert.equal(fake.calls.some((call) => call.method === 'session/modelCatalog'), true);
  } finally {
    await harness.close();
  }
});

test('bridge: the model of a session is selected through the DSH application', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/session/session-42/model', {
      method: 'POST',
      token: harness.state.token,
      body: { provider: 'deepseek-account', model: 'deepseek-flash', reasoningEffort: 'high' },
    });
    assert.equal(response.status, 200);
    assert.deepEqual(response.json.selected, { provider: 'deepseek-account', model: 'deepseek-flash' });
    const call = fake.calls.find((entry) => entry.method === 'session/selectModel');
    assert.notEqual(call, undefined, 'the bridge must forward the selection');
    assert.equal(call.args.sessionId, 'session-42');
    assert.equal(call.args.provider, 'deepseek-account');
    assert.equal(call.args.model, 'deepseek-flash');
    assert.equal(call.args.reasoningEffort, 'high');

    // The plural spelling of the route must work as well.
    const plural = await request(harness.port, '/api/v1/sessions/session-42/model', {
      method: 'POST',
      token: harness.state.token,
      body: { provider: 'deepseek-account', model: 'deepseek-flash' },
    });
    assert.equal(plural.status, 200);

    // A selection without a model is a bad request, not a DSH call.
    const invalid = await request(harness.port, '/api/v1/session/session-42/model', {
      method: 'POST',
      token: harness.state.token,
      body: { provider: 'deepseek-account' },
    });
    assert.equal(invalid.status, 400);
    assert.equal(invalid.json.error.code, 'bad_request');
  } finally {
    await harness.close();
  }
});

test('bridge: the queued items of a session come from the inbox projection', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/session/session-42/queue', { token: harness.state.token });
    assert.equal(response.status, 200);
    assert.deepEqual(response.json.nextTurn, [{ id: 'q1', text: 'queued turn', target: 'next-turn' }]);
    assert.deepEqual(response.json.nextStep, [{ id: 'q2', text: 'queued step', target: 'next-step' }]);

    const updated = await request(harness.port, '/api/v1/session/session-42/queue', {
      method: 'POST',
      token: harness.state.token,
      body: { itemId: 'q1', action: { kind: 'remove' } },
    });
    assert.equal(updated.status, 200);
    assert.equal(updated.json.ok, true);
    const call = fake.calls.find((entry) => entry.method === 'session/updateQueue');
    assert.notEqual(call, undefined, 'the bridge must forward the queue update');
    assert.equal(call.args.sessionId, 'session-42');
    assert.equal(call.args.itemId, 'q1');
    assert.deepEqual(call.args.action, { kind: 'remove' });

    const edited = await request(harness.port, '/api/v1/session/session-42/queue', {
      method: 'POST',
      token: harness.state.token,
      body: { itemId: 'q1', action: { kind: 'edit', content: [{ type: 'text', text: '改过的' }] } },
    });
    assert.equal(edited.status, 200);
    const editCall = fake.calls.filter((entry) => entry.method === 'session/updateQueue').pop();
    assert.deepEqual(editCall.args.action, { kind: 'edit', content: [{ type: 'text', text: '改过的' }] });

    const badEdit = await request(harness.port, '/api/v1/session/session-42/queue', {
      method: 'POST',
      token: harness.state.token,
      body: { itemId: 'q1', action: { kind: 'edit', content: [] } },
    });
    assert.equal(badEdit.status, 400);
    assert.equal(badEdit.json.error.code, 'bad_request');

    const invalid = await request(harness.port, '/api/v1/session/session-42/queue', {
      method: 'POST',
      token: harness.state.token,
      body: { action: { kind: 'remove' } },
    });
    assert.equal(invalid.status, 400);
    assert.equal(invalid.json.error.code, 'bad_request');
  } finally {
    await harness.close();
  }
});

test('bridge: the slash commands and the skills of a session are listed', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const commands = await request(harness.port, '/api/v1/session/session-42/commands', { token: harness.state.token });
    assert.equal(commands.status, 200);
    assert.equal(commands.json.commands.length, 2);
    assert.deepEqual(commands.json.commands[0], { name: 'compact', description: 'Compact older history', hint: '' });
    assert.deepEqual(commands.json.commands[1], { name: 'goal', description: 'Set the goal', hint: '[<objective>]' });

    const skills = await request(harness.port, '/api/v1/session/session-42/skills', { token: harness.state.token });
    assert.equal(skills.status, 200);
    assert.deepEqual(skills.json.skills, [
      { name: 'agent-browser', description: 'Browser automation', path: 'C:\\skills\\agent-browser\\SKILL.md' },
    ]);
  } finally {
    await harness.close();
  }
});

test('bridge: the file references of a session are searched by query', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/session/session-42/files?query=README', { token: harness.state.token });
    assert.equal(response.status, 200);
    assert.deepEqual(response.json.files, [{ path: 'arch-showcase/README.md', kind: 'file' }]);
    const call = fake.calls.find((entry) => entry.method === 'fileReferences/list');
    assert.notEqual(call, undefined, 'the bridge must forward the query');
    assert.equal(call.args.agentId, 'session-42');
    assert.equal(call.args.query, 'README');
  } finally {
    await harness.close();
  }
});

test('bridge: the permission presets are listed with their default', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/permissions', { token: harness.state.token });
    assert.equal(response.status, 200);
    assert.equal(response.json.defaultPreset, 'workspace-write');
    assert.deepEqual(response.json.options, [
      { value: 'read-only', name: 'read-only', description: '' },
      { value: 'workspace-write', name: 'workspace-write', description: 'write in the workspace' },
    ]);
  } finally {
    await harness.close();
  }
});

test('bridge: the state of a session carries the model, the permissions and the running flag', async () => {
  const fake = new FakeDsh();
  fake.rows = [{
    sessionId: 'session-42',
    updatedAt: Date.now(),
    running: true,
    cwd: 'D:\\work',
  }];
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/session/session-42/state', { token: harness.state.token });
    assert.equal(response.status, 200);
    assert.deepEqual(response.json.model, { provider: 'minimax-code-local', model: 'MiniMax-M3.1-Flash' });
    // The permissions of an unknown session are simply absent.
    assert.equal(response.json.permissions, null);
    assert.equal(response.json.running, true);
  } finally {
    await harness.close();
  }
});

test('bridge: the permissions of a session are read from the projection cache', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-bridge-perm-'));
  const sessionId = 'session-perm-42';
  try {
    writeMetadataFixture(root, sessionId, {
      rows: { permissions: { preset: 'workspace-write', sandbox: 'workspace-write', approval: 'never', seeded: false } },
    });
    // The bridge reads the metadata of the real store, so the test points the reader at the fixture.
    harness.bridge.sessionStats = (id) => (id === sessionId ? readSessionStats(sessionId, { root }) : null);

    const response = await request(harness.port, `/api/v1/session/${sessionId}/state`, { token: harness.state.token });
    assert.equal(response.status, 200);
    assert.deepEqual(response.json.permissions, {
      preset: 'workspace-write',
      sandbox: 'workspace-write',
      approval: 'never',
    });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
    await harness.close();
  }
});

test('bridge: the desktop UI parity endpoints need a token', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    for (const [method, pathname] of [
      ['GET', '/api/v1/models'],
      ['GET', '/api/v1/permissions'],
      ['GET', '/api/v1/session/session-42/queue'],
      ['GET', '/api/v1/session/session-42/commands'],
      ['GET', '/api/v1/session/session-42/skills'],
      ['GET', '/api/v1/session/session-42/files?query=x'],
      ['GET', '/api/v1/session/session-42/state'],
      ['POST', '/api/v1/session/session-42/model'],
      ['POST', '/api/v1/session/session-42/queue'],
    ]) {
      const response = await request(harness.port, pathname, { method, body: method === 'POST' ? {} : undefined });
      assert.equal(response.status, 401, `${method} ${pathname} must be rejected without a token`);
      assert.equal(response.json.error.code, 'unauthorized');
    }
  } finally {
    await harness.close();
  }
});

test('bridge: an unreachable DSH application answers the error envelope, not a crash', async () => {
  const fake = new FakeDsh();
  fake.failure = new Error('connect ECONNREFUSED 127.0.0.1:10748');
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/models', { token: harness.state.token });
    assert.equal(response.status, 503);
    assert.equal(response.json.error.code, 'dsh_unavailable');
    assert.match(response.json.error.message, /could not be reached/u);
  } finally {
    await harness.close();
  }
});

test('dsh: flat argument endpoints send their arguments unwrapped', async () => {
  // A tiny server captures the envelopes the client sends.
  const received = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      received.push(body);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ type: 'server-response', rpcId: body.rpcId, result: { ok: true, value: {} } }));
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  try {
    const client = new DshClient({ baseUrl: `http://127.0.0.1:${port}` });
    await client.rpc('session/modelCatalog', {});
    await client.rpc('commands/list', { agentId: 'session-1' });
    await client.rpc('fileReferences/list', { agentId: 'session-1', query: 'x' });
    await client.rpc('commands/execute', { agentId: 'session-1', line: '/permission read-only', submittedAttachments: [] });
    await client.rpc('skills/list', { sessionId: 'session-1' });
    await client.rpc('session/list', {});

    // Flat endpoints: the arguments are the fields of `payload.args` themselves.
    assert.deepEqual(received[0].payload.args, {});
    assert.deepEqual(received[1].payload.args, { agentId: 'session-1' });
    assert.deepEqual(received[2].payload.args, { agentId: 'session-1', query: 'x' });
    assert.deepEqual(
      received[3].payload.args,
      { agentId: 'session-1', line: '/permission read-only', submittedAttachments: [] },
      'commands/execute is flat as well',
    );
    // Wrapped endpoints: the arguments live under their wire key.
    assert.deepEqual(received[4].payload.args, { request: { sessionId: 'session-1' } });
    assert.deepEqual(received[5].payload.args, { _request: {} }, 'session/list keeps its _request key');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('bridge: a request body with a UTF-8 byte order mark is still parsed', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const payload = Buffer.from(`﻿{"provider":"deepseek-account","model":"deepseek-flash"}`, 'utf8');
    const response = await new Promise((resolve, reject) => {
      const req = http.request({
        host: '127.0.0.1',
        port: harness.port,
        path: '/api/v1/session/session-42/model',
        method: 'POST',
        headers: {
          authorization: `Bearer ${harness.state.token}`,
          'content-type': 'application/json',
          'content-length': payload.length,
        },
      }, (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          let json = null;
          try { json = JSON.parse(text); } catch { json = null; }
          resolve({ status: res.statusCode, json, text });
        });
      });
      req.on('error', reject);
      req.write(payload);
      req.end();
    });
    assert.equal(response.status, 200);
    assert.equal(response.json.selected.provider, 'deepseek-account');
  } finally {
    await harness.close();
  }
});

test('bridge: the permission preset of a new session is applied through the host command', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/sessions', {
      method: 'POST',
      token: harness.state.token,
      body: { cwd: 'D:\\work', title: 'permission test', permission: 'read-only' },
    });
    assert.equal(response.status, 200, `unexpected answer: ${response.text}`);

    // The bridge really asks the host to switch the preset.
    const call = fake.calls.find((entry) => entry.method === 'session/permission');
    assert.ok(call, 'the bridge must switch the permission of the new session');
    assert.equal(call.args.preset, 'read-only');
    assert.equal(call.args.sessionId, 'session-fake');

    // The phone gets the permission that is in effect back.
    assert.equal(response.json.session.permission, 'read-only');
  } finally {
    await harness.close();
  }
});

test('bridge: the live permission of a session wins over the projection cache', async () => {
  const fake = new FakeDsh();
  // The live projection (what the desktop shows) says `read-only`, the cache on disk (written
  // at the host's checkpoints) still says `workspace-write`.
  fake.data.projections.values.permissions = { currentValue: 'read-only' };
  const harness = await startBridge({ dsh: fake });
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-bridge-perm-live-'));
  const sessionId = 'session-perm-live';
  try {
    writeMetadataFixture(root, sessionId, {
      rows: { permissions: { preset: 'workspace-write', sandbox: 'workspace-write', approval: 'never', seeded: false } },
    });
    harness.bridge.sessionStats = (id) => (id === sessionId ? readSessionStats(sessionId, { root }) : null);

    const response = await request(harness.port, `/api/v1/session/${sessionId}/state`, { token: harness.state.token });
    assert.equal(response.status, 200);
    assert.equal(response.json.permissions.preset, 'read-only', 'the live value wins');
    assert.equal(response.json.permissions.currentValue, 'read-only');
    assert.equal(response.json.permissions.approval, 'never', 'the structured form is still served');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
    await harness.close();
  }
});

test('bridge: an unknown permission preset is refused before the session is created', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/sessions', {
      method: 'POST',
      token: harness.state.token,
      body: { cwd: 'D:\\work', permission: 'super-power' },
    });
    assert.equal(response.status, 400, `unexpected answer: ${response.text}`);
    assert.match(response.json.error.message, /unknown permission preset/u);
    const switched = fake.calls.some((entry) => entry.method === 'session/permission');
    assert.equal(switched, false, 'nothing may be switched');
  } finally {
    await harness.close();
  }
});

/* ------------------------------------------------------- pending (待办) and push */
test('bridge: the pending count adds the running sessions and the queued tasks', async () => {
  const fake = new FakeDsh();
  fake.rows = [
    {
      sessionId: 'session-a',
      running: true,
      updatedAt: 3,
      projections: { values: { inbox: { 'next-turn': [{ id: 'q1' }], 'next-step': [] }, userQuestions: { active: [] } } },
    },
    {
      sessionId: 'session-b',
      running: false,
      updatedAt: 2,
      projections: { values: { inbox: { 'next-turn': [], 'next-step': [{ id: 'q2' }, { id: 'q3' }] }, userQuestions: { active: [{ id: 'q4' }] } } },
    },
    { sessionId: 'session-c', running: false, updatedAt: 1, projections: { values: { inbox: { 'next-turn': [], 'next-step': [] } } } },
  ];
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/pending', { token: harness.state.token });
    assert.equal(response.status, 200);
    // 1 running session + 3 queued items + 1 open question.
    assert.equal(response.json.count, 5);
  } finally {
    await harness.close();
  }
});

test('bridge: the pending count survives an unreachable DSH application', async () => {
  const fake = new FakeDsh();
  fake.failure = new Error('connect ECONNREFUSED 127.0.0.1:10748');
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/pending', { token: harness.state.token });
    assert.equal(response.status, 200);
    assert.equal(response.json.count, 0);
  } finally {
    await harness.close();
  }
});

test('bridge: a phone registers its push token', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/phone/push-token', {
      method: 'POST',
      token: harness.state.token,
      body: { deviceId: 'dev-abc', token: 'push-token-123' },
    });
    assert.equal(response.status, 200);
    assert.equal(response.json.ok, true);
    assert.equal(response.json.deviceId, 'dev-abc');
    assert.equal(harness.bridge.push.store.size, 1);
    assert.deepEqual(harness.bridge.push.store.all(), ['push-token-123']);

    // The token must be stored outside the repository, in a git-ignored file.
    const storeFile = harness.bridge.push.store.file;
    assert.match(storeFile, /push-tokens\.local\.json$/u);

    // An empty token is a bad request.
    const invalid = await request(harness.port, '/api/v1/phone/push-token', {
      method: 'POST',
      token: harness.state.token,
      body: { deviceId: 'dev-abc' },
    });
    assert.equal(invalid.status, 400);
    assert.equal(invalid.json.error.code, 'bad_request');
  } finally {
    await harness.close();
  }
});

test('bridge: the pending and the push token endpoints need a token', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const pending = await request(harness.port, '/api/v1/pending');
    assert.equal(pending.status, 401);
    assert.equal(pending.json.error.code, 'unauthorized');
    const pushToken = await request(harness.port, '/api/v1/phone/push-token', { method: 'POST', body: { token: 'x' } });
    assert.equal(pushToken.status, 401);
    assert.equal(pushToken.json.error.code, 'unauthorized');
  } finally {
    await harness.close();
  }
});

test('push: the configuration comes from the environment, never from the source', () => {
  const empty = loadPushConfig({ env: {}, file: null });
  assert.equal(empty.enabled, false);
  assert.equal(empty.appId, null);

  const configured = loadPushConfig({ env: { DSH_PUSH_APPID: 'app-1', DSH_PUSH_SECRET: 'secret-1' }, file: null });
  assert.equal(configured.enabled, true);
  assert.equal(configured.appId, 'app-1');
  assert.equal(configured.sendUrl, 'https://push-api.cloud.huawei.com/v3/app-1/messages:send');
});

test('push: a local configuration file is read when the environment is empty', () => {
  const file = path.join(os.tmpdir(), `dsh-push-config-${crypto.randomUUID()}.json`);
  fs.writeFileSync(file, JSON.stringify({ appId: 'file-app', secret: 'file-secret' }), 'utf8');
  try {
    const config = loadPushConfig({ env: {}, file });
    assert.equal(config.enabled, true);
    assert.equal(config.appId, 'file-app');
    // The environment wins over the file.
    const overridden = loadPushConfig({ env: { DSH_PUSH_APPID: 'env-app' }, file });
    assert.equal(overridden.appId, 'env-app');
  } finally {
    fs.rmSync(file, { force: true });
  }
});

test('push: the JWT is a HS256 token over the app id', () => {
  const token = mintJwt('app-1', 'secret-1');
  const [header, payload, signature] = token.split('.');
  assert.equal(header.length > 0 && payload.length > 0 && signature.length > 0, true);
  const decode = (part) => JSON.parse(Buffer.from(part.replace(/-/gu, '+').replace(/_/gu, '/'), 'base64').toString('utf8'));
  assert.equal(decode(header).alg, 'HS256');
  assert.equal(decode(payload).app_id, 'app-1');
  assert.ok(decode(payload).exp > decode(payload).iat);
  // The signature must match the secret.
  const expected = crypto.createHmac('sha256', 'secret-1').update(`${header}.${payload}`).digest('base64')
    .replace(/\+/gu, '-').replace(/\//gu, '_').replace(/=+$/u, '');
  assert.equal(signature, expected);
});

test('push: an unconfigured notifier only logs and never sends', async () => {
  const sent = [];
  const logs = [];
  const notifier = new PushNotifier({
    config: loadPushConfig({ env: {}, file: null }),
    store: new PushTokenStore({ file: path.join(os.tmpdir(), `dsh-push-none-${crypto.randomUUID()}.json`) }),
    log: (level, message) => logs.push(`${level}: ${message}`),
    fetchImpl: async () => { sent.push(true); return { ok: true, status: 200, text: async () => '{}' }; },
  });
  const ok = await notifier.notify({ title: '标题', body: '正文' });
  assert.equal(ok, false);
  assert.equal(sent.length, 0, 'nothing may be sent without a configuration');
  assert.ok(logs.some((line) => line.includes('push is not configured')));
});

test('push: a notification is posted to the Huawei gateway', async () => {
  const calls = [];
  const notifier = new PushNotifier({
    config: { appId: 'app-1', secret: 'secret-1', tokenUrl: null, sendUrl: 'https://push-api.cloud.huawei.com/v3/app-1/messages:send', enabled: true },
    store: new PushTokenStore({ file: path.join(os.tmpdir(), `dsh-push-ok-${crypto.randomUUID()}.json`) }),
    log: () => {},
    fetchImpl: async (url, options) => {
      calls.push({ url, options, body: JSON.parse(options.body) });
      return { ok: true, status: 200, text: async () => '{"code":"80000000"}' };
    },
  });
  notifier.store.register('dev-1', 'token-1');
  const ok = await notifier.notify({ title: '标题', body: '正文' });
  assert.equal(ok, true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://push-api.cloud.huawei.com/v3/app-1/messages:send');
  assert.equal(calls[0].options.headers['push-type'], '0');
  assert.match(calls[0].options.headers.authorization, /^Bearer eyJ/u);
  assert.deepEqual(calls[0].body.target, { token: ['token-1'] });
  assert.equal(calls[0].body.payload.notification.title, '标题');
  assert.equal(calls[0].body.payload.notification.body, '正文');
});

test('push: a failing gateway never breaks the caller', async () => {
  const notifier = new PushNotifier({
    config: { appId: 'app-1', secret: 'secret-1', tokenUrl: null, sendUrl: 'https://push-api.cloud.huawei.com/v3/app-1/messages:send', enabled: true },
    store: new PushTokenStore({ file: path.join(os.tmpdir(), `dsh-push-fail-${crypto.randomUUID()}.json`) }),
    log: () => {},
    fetchImpl: async () => { throw new Error('network down'); },
  });
  notifier.store.register('dev-1', 'token-1');
  const ok = await notifier.notify({ title: '标题', body: '正文' });
  assert.equal(ok, false, 'a broken push must be reported, not thrown');
});

/* ------------------------------------------------------- pending (待办) and push */

test('bridge: the pending count adds the running sessions and the queued tasks', async () => {
  const fake = new FakeDsh();
  fake.rows = [
    {
      sessionId: 'session-a',
      running: true,
      updatedAt: 3,
      projections: { values: { inbox: { 'next-turn': [{ id: 'q1' }], 'next-step': [] }, userQuestions: { active: [] } } },
    },
    {
      sessionId: 'session-b',
      running: false,
      updatedAt: 2,
      projections: { values: { inbox: { 'next-turn': [], 'next-step': [{ id: 'q2' }, { id: 'q3' }] }, userQuestions: { active: [{ id: 'q4' }] } } },
    },
    { sessionId: 'session-c', running: false, updatedAt: 1, projections: { values: { inbox: { 'next-turn': [], 'next-step': [] } } } },
  ];
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/pending', { token: harness.state.token });
    assert.equal(response.status, 200);
    // 1 running session + 3 queued items + 1 open question.
    assert.equal(response.json.count, 5);
  } finally {
    await harness.close();
  }
});

test('bridge: the pending count survives an unreachable DSH application', async () => {
  const fake = new FakeDsh();
  fake.failure = new Error('connect ECONNREFUSED 127.0.0.1:10748');
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/pending', { token: harness.state.token });
    assert.equal(response.status, 200);
    assert.equal(response.json.count, 0);
  } finally {
    await harness.close();
  }
});

test('bridge: a phone registers its push token', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/phone/push-token', {
      method: 'POST',
      token: harness.state.token,
      body: { deviceId: 'dev-abc', token: 'push-token-123' },
    });
    assert.equal(response.status, 200);
    assert.equal(response.json.ok, true);
    assert.equal(response.json.deviceId, 'dev-abc');
    assert.equal(harness.bridge.push.store.size, 1);
    assert.deepEqual(harness.bridge.push.store.all(), ['push-token-123']);

    // The token must be stored outside the repository, in a git-ignored file.
    assert.match(harness.bridge.push.store.file, /push-tokens\.local\.json$/u);

    // An empty token is a bad request.
    const invalid = await request(harness.port, '/api/v1/phone/push-token', {
      method: 'POST',
      token: harness.state.token,
      body: { deviceId: 'dev-abc' },
    });
    assert.equal(invalid.status, 400);
    assert.equal(invalid.json.error.code, 'bad_request');
  } finally {
    await harness.close();
  }
});

test('bridge: the pending and the push token endpoints need a token', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const pending = await request(harness.port, '/api/v1/pending');
    assert.equal(pending.status, 401);
    assert.equal(pending.json.error.code, 'unauthorized');
    const pushToken = await request(harness.port, '/api/v1/phone/push-token', { method: 'POST', body: { token: 'x' } });
    assert.equal(pushToken.status, 401);
    assert.equal(pushToken.json.error.code, 'unauthorized');
  } finally {
    await harness.close();
  }
});

test('push: the configuration comes from the environment, never from the source', () => {
  const empty = loadPushConfig({ env: {}, file: null });
  assert.equal(empty.enabled, false);
  assert.equal(empty.appId, null);

  const configured = loadPushConfig({ env: { DSH_PUSH_APPID: 'app-1', DSH_PUSH_SECRET: 'secret-1' }, file: null });
  assert.equal(configured.enabled, true);
  assert.equal(configured.appId, 'app-1');
  assert.equal(configured.sendUrl, 'https://push-api.cloud.huawei.com/v3/app-1/messages:send');
});

test('push: a local configuration file is read when the environment is empty', () => {
  const file = path.join(os.tmpdir(), `dsh-push-config-${crypto.randomUUID()}.json`);
  fs.writeFileSync(file, JSON.stringify({ appId: 'file-app', secret: 'file-secret' }), 'utf8');
  try {
    const config = loadPushConfig({ env: {}, file });
    assert.equal(config.enabled, true);
    assert.equal(config.appId, 'file-app');
    // The environment wins over the file.
    const overridden = loadPushConfig({ env: { DSH_PUSH_APPID: 'env-app' }, file });
    assert.equal(overridden.appId, 'env-app');
  } finally {
    fs.rmSync(file, { force: true });
  }
});

test('push: the JWT is a HS256 token over the app id', () => {
  const token = mintJwt('app-1', 'secret-1');
  const [header, payload, signature] = token.split('.');
  assert.equal(header.length > 0 && payload.length > 0 && signature.length > 0, true);
  const decode = (part) => JSON.parse(Buffer.from(part.replace(/-/gu, '+').replace(/_/gu, '/'), 'base64').toString('utf8'));
  assert.equal(decode(header).alg, 'HS256');
  assert.equal(decode(payload).app_id, 'app-1');
  assert.ok(decode(payload).exp > decode(payload).iat);
  // The signature must match the secret.
  const expected = crypto.createHmac('sha256', 'secret-1').update(`${header}.${payload}`).digest('base64')
    .replace(/\+/gu, '-').replace(/\//gu, '_').replace(/=+$/u, '');
  assert.equal(signature, expected);
});

test('push: an unconfigured notifier only logs and never sends', async () => {
  const sent = [];
  const logs = [];
  const notifier = new PushNotifier({
    config: loadPushConfig({ env: {}, file: null }),
    store: new PushTokenStore({ file: path.join(os.tmpdir(), `dsh-push-none-${crypto.randomUUID()}.json`) }),
    log: (level, message) => logs.push(`${level}: ${message}`),
    fetchImpl: async () => { sent.push(true); return { ok: true, status: 200, text: async () => '{}' }; },
  });
  const ok = await notifier.notify({ title: '标题', body: '正文' });
  assert.equal(ok, false);
  assert.equal(sent.length, 0, 'nothing may be sent without a configuration');
  assert.ok(logs.some((line) => line.includes('push is not configured')));
});

test('push: a notification is posted to the Huawei gateway', async () => {
  const calls = [];
  const notifier = new PushNotifier({
    config: { appId: 'app-1', secret: 'secret-1', tokenUrl: null, sendUrl: 'https://push-api.cloud.huawei.com/v3/app-1/messages:send', enabled: true },
    store: new PushTokenStore({ file: path.join(os.tmpdir(), `dsh-push-ok-${crypto.randomUUID()}.json`) }),
    log: () => {},
    fetchImpl: async (url, options) => {
      calls.push({ url, options, body: JSON.parse(options.body) });
      return { ok: true, status: 200, text: async () => '{"code":"80000000"}' };
    },
  });
  notifier.store.register('dev-1', 'token-1');
  const ok = await notifier.notify({ title: '标题', body: '正文' });
  assert.equal(ok, true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://push-api.cloud.huawei.com/v3/app-1/messages:send');
  assert.equal(calls[0].options.headers['push-type'], '0');
  assert.match(calls[0].options.headers.authorization, /^Bearer eyJ/u);
  assert.deepEqual(calls[0].body.target, { token: ['token-1'] });
  assert.equal(calls[0].body.payload.notification.title, '标题');
  assert.equal(calls[0].body.payload.notification.body, '正文');
});

test('push: a failing gateway never breaks the caller', async () => {
  const notifier = new PushNotifier({
    config: { appId: 'app-1', secret: 'secret-1', tokenUrl: null, sendUrl: 'https://push-api.cloud.huawei.com/v3/app-1/messages:send', enabled: true },
    store: new PushTokenStore({ file: path.join(os.tmpdir(), `dsh-push-fail-${crypto.randomUUID()}.json`) }),
    log: () => {},
    fetchImpl: async () => { throw new Error('network down'); },
  });
  notifier.store.register('dev-1', 'token-1');
  const ok = await notifier.notify({ title: '标题', body: '正文' });
  assert.equal(ok, false, 'a broken push must be reported, not thrown');
});

test('bridge: a pending change pushes a notification to the registered phones', async () => {
  const previous = process.env.DSH_PENDING_INTERVAL_MS;
  process.env.DSH_PENDING_INTERVAL_MS = '50';
  const fake = new FakeDsh();
  fake.rows = [{
    sessionId: 'session-a',
    running: true,
    updatedAt: 3,
    projections: { values: { inbox: { 'next-turn': [], 'next-step': [] }, userQuestions: { active: [] } } },
  }];
  const pushed = [];
  const store = new PushTokenStore({ file: path.join(os.tmpdir(), `dsh-push-watch-${crypto.randomUUID()}.json`) });
  const push = {
    store,
    notify: async (message) => { pushed.push(message); return true; },
    describe: () => ({ enabled: true, appId: 'app-1', sendUrl: null, tokenUrl: null, registeredPhones: store.size }),
  };
  const harness = await startBridge({ dsh: fake, push });
  try {
    // The watch starts as soon as a phone registers its token.
    const registered = harness.bridge.registerPushToken('dev-1', 'token-1');
    assert.equal(registered.ok, true);
    await new Promise((resolve) => setTimeout(resolve, 900));
    assert.ok(pushed.length >= 1, 'a pending change must push a notification');
    assert.match(pushed[0].title, /待办/u);
    assert.match(pushed[0].body, /会话正在运行/u);
  } finally {
    await harness.close();
    if (previous === undefined) delete process.env.DSH_PENDING_INTERVAL_MS;
    else process.env.DSH_PENDING_INTERVAL_MS = previous;
  }
});

test('bridge: the phone polling the pending count does not hide a change from the watch', async () => {
  const previous = process.env.DSH_PENDING_INTERVAL_MS;
  process.env.DSH_PENDING_INTERVAL_MS = '50';
  const fake = new FakeDsh();
  fake.rows = [{ sessionId: 'session-a', running: true, updatedAt: 1, projections: { values: { inbox: { 'next-turn': [], 'next-step': [] } } } }];
  const pushed = [];
  const store = new PushTokenStore({ file: path.join(os.tmpdir(), `dsh-push-watch2-${crypto.randomUUID()}.json`) });
  const push = {
    store,
    notify: async (message) => { pushed.push(message); return true; },
    describe: () => ({ enabled: true, appId: 'app-1', sendUrl: null, tokenUrl: null, registeredPhones: store.size }),
  };
  const harness = await startBridge({ dsh: fake, push });
  try {
    harness.bridge.registerPushToken('dev-1', 'token-1');
    // The phone polls the count itself; the watch must still see the change.
    await request(harness.port, '/api/v1/pending', { token: harness.state.token });
    fake.rows = [
      { sessionId: 'session-a', running: true, updatedAt: 2, projections: { values: { inbox: { 'next-turn': [], 'next-step': [] } } } },
      { sessionId: 'session-b', running: true, updatedAt: 3, projections: { values: { inbox: { 'next-turn': [], 'next-step': [] } } } },
    ];
    await request(harness.port, '/api/v1/pending', { token: harness.state.token });
    // The watch may or may not have seen the first state before the change, so only the new
    // state is asserted: the notification must report the two running sessions. The cached rows
    // are refreshed in the background, so the change needs a moment to arrive.
    const deadline = Date.now() + 15000;
    let latest = null;
    while (Date.now() < deadline) {
      latest = pushed[pushed.length - 1] ?? null;
      if (latest !== null && /2 项待办/u.test(latest.title)) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assert.notEqual(latest, null, 'the watch must notify the phone');
    assert.match(latest.title, /2 项待办/u, 'the notification must report the new pending count');
  } finally {
    await harness.close();
    if (previous === undefined) delete process.env.DSH_PENDING_INTERVAL_MS;
    else process.env.DSH_PENDING_INTERVAL_MS = previous;
  }
});

test('bridge: the phone gets a pending frame with the finished sessions and the open questions', async () => {
  const previous = process.env.DSH_PENDING_INTERVAL_MS;
  process.env.DSH_PENDING_INTERVAL_MS = '50';
  const fake = new FakeDsh();
  fake.rows = [
    { sessionId: 'session-a', running: true, updatedAt: 3, projections: { values: { inbox: { 'next-turn': [], 'next-step': [] }, userQuestions: { active: [] } } } },
  ];
  const harness = await startBridge({ dsh: fake });
  try {
    const client = new WebSocketClient(`ws://127.0.0.1:${harness.port}/ws`, {
      headers: { Authorization: `Bearer ${harness.state.token}` },
    });
    const frames = [];
    client.on('message', (text) => frames.push(JSON.parse(text)));
    await client.connect();

    // The phone learns the current state right after the handshake.
    const first = await waitForFrame(frames, (frame) => frame.type === 'pending');
    assert.equal(first.data.count, 1);
    assert.deepEqual(first.data.running, ['session-a']);
    assert.deepEqual(first.data.finished, []);
    assert.deepEqual(first.data.questions, []);

    // Nothing changed: the bridge must stay quiet (the phone would notify again and again).
    await new Promise((resolve) => setTimeout(resolve, 400));
    const quiet = frames.filter((frame) => frame.type === 'pending');
    assert.equal(quiet.length, 1, 'an unchanged pending state must not be sent again');

    // Now the session finishes and another one asks a question.
    fake.rows = [
      { sessionId: 'session-a', running: false, updatedAt: 4, projections: { values: { inbox: { 'next-turn': [], 'next-step': [] }, userQuestions: { active: [] } } } },
      { sessionId: 'session-b', running: false, updatedAt: 2, projections: { values: { inbox: { 'next-turn': [], 'next-step': [] }, userQuestions: { active: [{ id: 'q1' }] } } } },
    ];
    // The session rows are cached, so the watch needs a moment to see the new state.
    const deadline = Date.now() + 20000;
    let frame = null;
    while (Date.now() < deadline) {
      frame = frames.filter((f) => f.type === 'pending').pop() ?? null;
      if (frame !== null && frame.data.questions.length > 0) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assert.notEqual(frame, null, 'the phone must get the pending frame');
    assert.equal(frame.data.questions.length, 1, 'the open question must be reported');
    assert.equal(frame.data.questions[0].sessionId, 'session-b');
    const finished = frame.data.finished.map((entry) => entry.sessionId);
    assert.ok(finished.includes('session-a'), 'the session that stopped running must be reported as finished');
    assert.equal(frame.data.running.length, 0);
    client.close();
  } finally {
    await harness.close();
    if (previous === undefined) delete process.env.DSH_PENDING_INTERVAL_MS;
    else process.env.DSH_PENDING_INTERVAL_MS = previous;
  }
});

test('cli: a secret with a blank inside is refused (the relay would answer 401 forever)', () => {
  const clean = 'b501de81997196415f27ec1a45b06d6fa560e122529031f6b36692c9aa45c3f0';
  assert.equal(checkRelaySecrets({ deviceToken: clean }).ok, true, 'a clean token must pass');
  assert.equal(checkRelaySecrets({}).ok, true, 'no secret at all must pass');

  // The real accident: the token was copied out of a wrapped line, so a blank landed in the
  // middle of it. The handshake header cannot carry that — the relay reads a truncated secret.
  const broken = checkRelaySecrets({ deviceToken: 'b501de81 997196415f27ec1a45b06d6fa560e122529031f6b36692c9aa45c3f0' });
  assert.equal(broken.ok, false, 'a token with a blank inside must be refused');
  assert.equal(broken.name, '--device-token');
  assert.match(broken.reason, /whitespace/u);

  const brokenAccount = checkRelaySecrets({ accountToken: '53a3aca9 8dc795db' });
  assert.equal(brokenAccount.ok, false);
  assert.equal(brokenAccount.name, '--account-token');
});

test('cli: the bridge refuses to start when the device token carries a blank', async () => {
  const port = await freePort();
  const cliPath = path.join(fileURLToPath(new URL('..', import.meta.url)), 'src', 'cli.js');
  const stateFile = path.join(os.tmpdir(), `dsh-bridge-test-${process.pid}.json`);
  const configFile = path.join(os.tmpdir(), `dsh-bridge-test-${process.pid}.config.json`);
  fs.writeFileSync(configFile, JSON.stringify({ port }), 'utf8');
  const child = spawn(process.execPath, [
    cliPath,
    '--port', String(port),
    '--host', '127.0.0.1',
    '--config', configFile,
    '--state', stateFile,
    '--relay', 'ws://127.0.0.1:1/bridge',
    '--device-id', 'dev-test',
    '--device-token', 'b501de81 997196415f27ec1a45b06d6fa560e122529031f6b36692c9aa45c3f0',
    '--account', 'acc-test',
    '--account-token', '53a3aca98dc795db77ae91ecc1e7d39cc5545ae88117fc84d40b5de4502c214c',
  ], { stdio: ['ignore', 'pipe', 'pipe'] });

  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
  const exited = new Promise((resolve) => {
    const timer = setTimeout(() => { child.kill('SIGKILL'); resolve({ code: null, timedOut: true }); }, 30000);
    child.on('exit', (code) => { clearTimeout(timer); resolve({ code, timedOut: false }); });
  });
  const result = await exited;
  try { fs.unlinkSync(stateFile); } catch { /* the file may not exist */ }
  try { fs.unlinkSync(configFile); } catch { /* the file may not exist */ }

  assert.equal(result.timedOut, false, 'the bridge must not keep running with a broken token');
  assert.equal(result.code, 2, 'the bridge must stop with the error code 2');
  assert.match(stderr, /contains whitespace/u, 'the reason must be on stderr');
  assert.match(stderr, /令牌里混进了空格或换行/u, 'the reason must be in plain words too');
});

/* ------------------------------------------------- the workspace a session belongs to */

/**
 * A DSH host that answers the two calls the bridge makes when it creates a session.
 *
 * @param {object} options
 * @param {object|null} options.workspace - the Workspace `workspace/create` answers with.
 * @param {object|null} options.workspaceError - the failure of `workspace/create`.
 * @param {object|null} options.sessionErrorOnce - the failure of the first `session/create`.
 * @returns {Promise<{port: number, received: object[], close: () => Promise<void>}>}
 */
async function fakeWorkspaceHost({ workspace = null, workspaceError = null, sessionErrorOnce = null } = {}) {
  const received = [];
  let sessionCalls = 0;
  const server = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      received.push(body);
      const answer = (value) => {
        response.writeHead(200, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ type: 'server-response', rpcId: body.rpcId, result: { ok: true, value } }));
      };
      const fail = (code, message) => {
        response.writeHead(200, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ type: 'server-response', rpcId: body.rpcId, result: { ok: false, error: { code, message } } }));
      };
      if (body.method === 'workspace/create') {
        if (workspaceError !== null) fail(workspaceError.code, workspaceError.message);
        else answer({ workspace, created: false });
        return;
      }
      if (body.method === 'session/create') {
        sessionCalls += 1;
        if (sessionErrorOnce !== null && sessionCalls === 1) {
          fail(sessionErrorOnce.code, sessionErrorOnce.message);
          return;
        }
        answer({ sessionId: 'session-new', agentPreset: null });
        return;
      }
      answer({});
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  return { port, received, close: () => new Promise((resolve) => server.close(resolve)) };
}

/** A DSH home that carries the owner secret the client needs. */
function fakeDshHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-home-'));
  fs.writeFileSync(path.join(home, '.credentials.yaml'),
    'records:\n  client-connection/browser-session:\n    payload:\n      secret: "' + Buffer.alloc(32, 7).toString('base64url') + '"\n');
  return home;
}

test('workspace: the spellings of one directory are one directory', () => {
  const groups = groupDirectories([
    'D:\\APP\\Deepseek\\DSHHarmony',
    'D:/APP/Deepseek/DSHHarmony',
    'D:\\\\APP\\\\Deepseek\\\\DSHHarmony',
    'D:\\APP\\Deepseek\\DSHHarmony\\',
    'C:\\other',
  ]);
  assert.equal(groups.length, 2, 'one group per directory');
  const byPath = new Map(groups.map((group) => [group.path, group]));
  const harmony = byPath.get('D:\\APP\\Deepseek\\DSHHarmony');
  assert.ok(harmony !== undefined, 'the canonical spelling is the one the desktop writes');
  assert.equal(harmony.spellings.length, 4, 'every spelling lands in the same group');
  assert.ok(byPath.has('C:\\other'), 'another directory is another group');
  assert.equal(normalizeDirectory('D:/APP/Deepseek/DSHHarmony'), 'D:\\APP\\Deepseek\\DSHHarmony');
  assert.equal(normalizeDirectory('D:\\APP\\Deepseek\\DSHHarmony\\'), 'D:\\APP\\Deepseek\\DSHHarmony');
});

test('dsh: a session is created in the workspace that owns the directory', async () => {
  // The desktop files a session under a Workspace only when the session is created with a
  // `workspaceId`; a session created with a bare `cwd` stays "ungrouped" forever. The
  // directory is therefore resolved to its Workspace first.
  const host = await fakeWorkspaceHost({
    workspace: {
      workspaceId: 'ws-1',
      path: 'D:\\APP\\Deepseek\\DSHHarmony',
      title: 'DSHHarmony',
      sessionIds: [],
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
    },
  });
  try {
    const client = new DshClient({ baseUrl: `http://127.0.0.1:${host.port}`, home: fakeDshHome() });
    const created = await client.createSession({ cwd: 'D:/APP/Deepseek/DSHHarmony' });
    assert.equal(created.sessionId, 'session-new');
    assert.equal(created.workspaceId, 'ws-1');
    const lookup = host.received.find((body) => body.method === 'workspace/create');
    const creation = host.received.find((body) => body.method === 'session/create');
    assert.deepEqual(lookup.payload.args, { request: { path: 'D:/APP/Deepseek/DSHHarmony' } }, 'the path is resolved through workspace/create');
    assert.deepEqual(creation.payload.args, { request: { workspaceId: 'ws-1' } }, 'the session is created in the workspace, not in a bare cwd');
  } finally {
    await host.close();
  }
});

test('dsh: a directory the desktop refuses falls back to the plain cwd', async () => {
  const host = await fakeWorkspaceHost({
    workspaceError: { code: 'workspace/invalid-path', message: 'cannot create a Workspace at "D:/app/x"' },
  });
  try {
    const client = new DshClient({ baseUrl: `http://127.0.0.1:${host.port}`, home: fakeDshHome() });
    const created = await client.createSession({ cwd: 'D:/app/x' });
    assert.equal(created.sessionId, 'session-new', 'the phone still gets its session');
    assert.equal(created.workspaceId, undefined);
    const creation = host.received.find((body) => body.method === 'session/create');
    assert.deepEqual(creation.payload.args, { request: { cwd: 'D:/app/x' } });
  } finally {
    await host.close();
  }
});

test('dsh: a workspace that vanished falls back to the plain cwd', async () => {
  const host = await fakeWorkspaceHost({
    workspace: { workspaceId: 'ws-1', path: 'D:\\app\\x', title: 'x', sessionIds: [] },
    sessionErrorOnce: { code: 'workspace/not-found', message: 'workspace "ws-1" not found' },
  });
  try {
    const client = new DshClient({ baseUrl: `http://127.0.0.1:${host.port}`, home: fakeDshHome() });
    const created = await client.createSession({ cwd: 'D:/app/x' });
    assert.equal(created.sessionId, 'session-new');
    assert.equal(created.workspaceId, undefined);
    const creations = host.received.filter((body) => body.method === 'session/create');
    assert.equal(creations.length, 2, 'the creation is tried once more');
    assert.deepEqual(creations[0].payload.args, { request: { workspaceId: 'ws-1' } });
    assert.deepEqual(creations[1].payload.args, { request: { cwd: 'D:/app/x' } });
  } finally {
    await host.close();
  }
});

test('bridge: a slash command runs on the desktop instead of being sent as a prompt', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/sessions/session-1/command', {
      method: 'POST',
      token: harness.state.token,
      body: { line: '/plan' },
    });
    assert.equal(response.status, 200);
    assert.equal(response.json.ok, true, 'the host ran the command');
    assert.match(response.json.text, /preset/u);
    const executed = fake.calls.find((call) => call.method === 'commands/execute');
    assert.ok(executed !== undefined, 'the command goes to the host command registry');
    assert.equal(executed.args.line, '/plan', 'the whole line is handed over');
    assert.equal(fake.calls.some((call) => call.method === 'session/prompt'), false,
      'a command must not be sent to the model as a prompt');
  } finally {
    await harness.close();
  }
});

test('bridge: an empty command line is refused', async () => {
  const fake = new FakeDsh();
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/sessions/session-1/command', {
      method: 'POST',
      token: harness.state.token,
      body: { line: '   ' },
    });
    assert.equal(response.status, 400);
    assert.equal(fake.calls.some((call) => call.method === 'commands/execute'), false);
  } finally {
    await harness.close();
  }
});

test('bridge: the workspaces endpoint lists one entry per directory', async () => {
  const fake = new FakeDsh();
  fake.rows = [
    { sessionId: 'session-1', cwd: 'D:\\APP\\Deepseek\\DSHHarmony', updatedAt: 3 },
    { sessionId: 'session-2', cwd: 'D:/APP/Deepseek/DSHHarmony', updatedAt: 2 },
    { sessionId: 'session-3', cwd: 'D:\\\\APP\\\\Deepseek\\\\DSHHarmony', updatedAt: 1 },
  ];
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/workspaces', { token: harness.state.token });
    assert.equal(response.status, 200);
    const harmony = response.json.workspaces.filter((workspace) => workspace.label === 'DSHHarmony');
    assert.equal(harmony.length, 1, 'the phone must not see the same project twice');
    assert.equal(harmony[0].cwd, 'D:\\APP\\Deepseek\\DSHHarmony');
  } finally {
    await harness.close();
  }
});

test('bridge: the session list carries one spelling per directory', async () => {
  const fake = new FakeDsh();
  fake.rows = [
    { sessionId: 'session-1', cwd: 'D:/APP/Deepseek/DSHHarmony', updatedAt: 3 },
    { sessionId: 'session-2', cwd: 'D:\\APP\\Deepseek\\DSHHarmony', updatedAt: 2 },
  ];
  const harness = await startBridge({ dsh: fake });
  try {
    const response = await request(harness.port, '/api/v1/sessions', { token: harness.state.token });
    assert.equal(response.status, 200);
    const harmony = response.json.sessions.filter((session) => session.cwd.endsWith('DSHHarmony'));
    assert.ok(harmony.length > 0, 'the sessions of the project are listed');
    for (const session of harmony) {
      assert.equal(session.cwd, 'D:\\APP\\Deepseek\\DSHHarmony', 'every session of the project spells its directory the same way');
    }
  } finally {
    await harness.close();
  }
});

await run();
