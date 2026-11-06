// Measures the size of a COMPACT telemetry payload — the thing a phone would actually pull.
// The naive approach (poll session/list over the tunnel) is measured for comparison.
import { readFileSync } from 'node:fs';
import { gzipSync, brotliCompressSync } from 'node:zlib';

const snap = JSON.parse(readFileSync(process.argv[2] || './snapshot.json', 'utf8'));
const now = Date.now();
const sz = o => Buffer.byteLength(JSON.stringify(o), 'utf8');
const gz = o => gzipSync(Buffer.from(JSON.stringify(o)), { level: 9 }).length;
const br = o => brotliCompressSync(Buffer.from(JSON.stringify(o))).length;

const running = snap.sessions.filter(s => s.running);
const liveJobs = (snap.jobs || []).filter(j => j.status === 'running' || j.status === 'stopping');
const norm = c => (c || '').replace(/\//g, '\\').replace(/\\+/g, '\\').replace(/\\+$/, '');

// --- A. compact aggregate (what a phone should get) ---
const compact = {
  t: now,
  ws: Object.entries(snap.sessions.reduce((m, s) => {
    const k = norm(s.cwd);
    const e = m[k] ??= { p: k, n: 0, r: 0, t: 0, b: 0, sub: 0, job: 0 };
    e.n++; if (s.running) e.r++; e.t += s.tokens.total; e.b += s.tokens.billed;
    if (s.origin === 'subagent') e.sub++;
    return m;
  }, {})).map(([, e]) => e),
  live: running.map(s => ({
    id: s.id, w: norm(s.cwd), t: s.tokens.billed, r: (s.decodeRate || 0),
    k: s.origin === 'subagent' ? 'sub' : 'con', n: s.title?.slice(0, 40) || s.id.slice(0, 8)
  })),
  jobs: liveJobs.map(j => ({ id: j.id, k: j.kind, o: j.owner, s: j.status })),
  tot: { sess: snap.sessions.length, run: running.length, sub: snap.sessions.filter(s => s.origin === 'subagent').length, job: liveJobs.length, billed: snap.totals.billed }
};

// --- B. naive: full session/list shape ---
const naive = { items: snap.sessions.map(s => ({
  sessionId: s.id, updatedAt: s.updatedAt, running: s.running, agentAvailable: true,
  cwd: s.cwd, origin: s.origin, parentSessionId: s.parentSession, blank: false, formatStatus: 'current',
  projections: { kind: 'sequenced', asOfSeq: 0, values: { title: s.title, tokenUsage: {
    uncachedInputTokens: s.tokens.input, outputTokens: s.tokens.output,
    cacheReadTokens: s.tokens.cacheRead, cacheWriteTokens: s.tokens.cacheWrite } } }
})) };

const rows = [
  ['紧凑聚合（推荐给手机）', compact],
  ['朴素全量 session/list', naive],
];
console.log('payload'.padEnd(26), 'raw'.padStart(11), 'gzip-9'.padStart(10), 'brotli'.padStart(9));
for (const [name, obj] of rows) {
  console.log(name.padEnd(24), String(sz(obj)).padStart(12), String(gz(obj)).padStart(10), String(br(obj)).padStart(9));
}
const cs = sz(compact), cg = gz(compact);
console.log('\n--- 拉取频率对应的流量（仅紧凑聚合）---');
for (const [label, every] of [['1 秒', 1], ['2 秒', 2], ['5 秒', 5], ['30 秒', 30]]) {
  const raw = cs * 60 / every, gzipped = cg * 60 / every;
  console.log(`每 ${label.padEnd(5)} → 原始 ${(raw/1024).toFixed(1)} KB/s (${(raw*3600/1048576).toFixed(1)} MB/h) · gzip 后 ${(gzipped/1024).toFixed(2)} KB/s (${(gzipped*3600/1048576).toFixed(1)} MB/h)`);
}
const ns = sz(naive), ng = gz(naive);
console.log(`\n朴素 session/list 每 30 秒 → 原始 ${(ns*2/1024).toFixed(0)} KB/s (${(ns*2*3600/1048576).toFixed(0)} MB/h) · gzip 后 ${(ng*2/1024).toFixed(0)} KB/s (${(ng*2*3600/1048576).toFixed(0)} MB/h)`);
