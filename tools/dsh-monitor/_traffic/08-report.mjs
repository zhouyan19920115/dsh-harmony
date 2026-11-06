// 08-report.mjs — final aggregation: byte tables, stream rates, bandwidth projections.
import { readFileSync, writeFileSync } from 'node:fs';
const HERE = new URL('./', import.meta.url).pathname.replace(/^\//, '');
const R = n => JSON.parse(readFileSync(`${HERE}${n}`, 'utf8'));

const list = R('01-session-list.result.json');
const proj = R('06-projections.result.json');
const w1 = R('03-streams-60s.result.json');
let w2 = null; try { w2 = R('07-second-window.result.json'); } catch {}

const KB = 1024, MB = 1024 * 1024;
const out = {};

// ---------- 1. unary tables ----------
out.unary = {
  'session/list': { raw: list.envelope.raw, gzip9: list.envelope.gzip9, brotli11: list.envelope.brotli11,
    innerRaw: list.innerValue.raw, items: list.itemCount, running: list.runningCount, subagents: list.subagentCount, elapsedMs: list.elapsedMs },
  'session/projections': {}
};
for (const [kind, t] of Object.entries(proj.targets)) {
  out.unary['session/projections'][kind] = { sessionId: t.sessionId, raw: t.envelope.raw, gzip9: t.envelope.gzip9,
    brotli11: t.envelope.brotli11, innerRaw: t.inner?.raw ?? null, innerGzip9: t.inner?.gzip9 ?? null, innerBrotli11: t.inner?.brotli11 ?? null,
    elapsedMs: t.elapsedMs, breakdown: t.breakdown, title: t.title };
}
const raws = proj.allRunning.map(r => r.envelope.raw).sort((a, b) => a - b);
const gzs = proj.allRunning.map(r => r.envelope.gzip9).sort((a, b) => a - b);
const brs = proj.allRunning.map(r => r.envelope.brotli11).sort((a, b) => a - b);
const sum = a => a.reduce((x, y) => x + y, 0);
out.runningSessions = { count: raws.length, sumRaw: sum(raws), meanRaw: sum(raws) / raws.length,
  medianRaw: raws[Math.floor(raws.length / 2)], minRaw: raws[0], maxRaw: raws[raws.length - 1],
  sumGzip9: sum(gzs), sumBrotli11: sum(brs), all: proj.allRunning.map(r => ({ id: r.sessionId, raw: r.envelope.raw, gzip9: r.envelope.gzip9, brotli11: r.envelope.brotli11, elapsedMs: r.elapsedMs })) };

// ---------- 2. stream rates ----------
out.streams = {};
for (const s of w1.streams) {
  const perKey = {};
  for (const f of s.frames) { const k = f.key ?? (f.valueType === 'baseline' ? 'baseline' : 'other'); perKey[k] = (perKey[k] || 0) + f.bytes; }
  const baseline = s.baselineBytes ?? 0;
  out.streams[s.label] = { frames: s.frameCount, totalBytes: s.totalBytes, totalWireBytes: s.totalWireBytes,
    baselineBytes: baseline, deltaBytes: s.totalBytes - baseline, deltaFrames: s.frameCount - (baseline ? 1 : 0),
    bytesPerFrame: s.frameCount ? +(s.totalBytes / s.frameCount).toFixed(3) : 0,
    perKey, kbPerMin: +(s.totalBytes / KB / (w1.actualWindowMs / 60000)).toFixed(4),
    deltaKbPerMin: +((s.totalBytes - baseline) / KB / (w1.actualWindowMs / 60000)).toFixed(4) };
}
if (w2) out.streamsSecondWindow = w2.streams.map(s => ({ label: s.label, frames: s.frameCount, totalBytes: s.totalBytes,
  baselineBytes: s.baselineBytes, deltaBytes: s.deltaBytes, deltaFrames: s.deltaFrames, perKey: s.perKey,
  gzip9TotalBytes: s.gzip9TotalBytes, kbPerMin: +(s.totalBytes / KB / (w2.actualWindowMs / 60000)).toFixed(4),
  deltaKbPerMin: +(s.deltaBytes / KB / (w2.actualWindowMs / 60000)).toFixed(4) }));
out.window1 = { ms: w1.actualWindowMs, permessageDeflateNegotiated: w1.permessageDeflateNegotiated, handshakeHeaders: w1.handshakeResponseHeaders };

// ---------- 3. projected bandwidth ----------
const N_RUNNING = out.runningSessions.count;
const P = {};
// (a) naive: full session/list every 30s
P['a: session/list every 30s'] = { bytesPerPoll: list.envelope.raw, pollsPerMin: 2, bytesPerSec: list.envelope.raw * 2 / 60,
  mbPerHour: list.envelope.raw * 2 * 60 / MB, gzipBytesPerSec: list.envelope.gzip9 * 2 / 60, gzipMbPerHour: list.envelope.gzip9 * 2 * 60 / MB };
// (b) projections for every running session every 5s
const bBytesPerCycle = out.runningSessions.sumRaw;
P[`b: session/projections x${N_RUNNING} running every 5s`] = { bytesPerPoll: bBytesPerCycle, pollsPerMin: 12,
  bytesPerSec: bBytesPerCycle * 12 / 60, mbPerHour: bBytesPerCycle * 12 * 60 / MB,
  gzipBytesPerSec: out.runningSessions.sumGzip9 * 12 / 60, gzipMbPerHour: out.runningSessions.sumGzip9 * 12 * 60 / MB };
// (c) session/control push stream
const sc = out.streams['session/control'];
P['c: session/control push (steady state, no baseline)'] = { bytesPerSec: sc.deltaBytes / (w1.actualWindowMs / 1000),
  mbPerHour: sc.deltaBytes * 3600 / (w1.actualWindowMs / 1000) / MB,
  note: 'baseline is one-time ' + sc.baselineBytes + ' B on subscribe' };
P['c2: session/control push incl. amortised baseline (1 connect / 60s reconnect)'] = {
  bytesPerSec: (sc.baselineBytes + sc.deltaBytes) / (w1.actualWindowMs / 1000),
  mbPerHour: (sc.baselineBytes + sc.deltaBytes) * 3600 / (w1.actualWindowMs / 1000) / MB };
if (out.streamsSecondWindow) {
  const s2 = out.streamsSecondWindow.find(s => s.label === 'session/control');
  if (s2) P['c3: session/control push (2nd window, steady state)'] = { bytesPerSec: s2.deltaBytes / (w2.actualWindowMs / 1000),
    mbPerHour: s2.deltaBytes * 3600 / (w2.actualWindowMs / 1000) / MB, deltaBytes: s2.deltaBytes, frames: s2.frames };
}
// (d) hybrid
const wf = out.streams['workspace/follow'];
const jobStreams = w1.streams.filter(s => s.label.startsWith('job/list'));
const jobBaselineSum = jobStreams.reduce((a, s) => a + (s.baselineBytes ?? 0), 0);
const jobTotalSum = jobStreams.reduce((a, s) => a + s.totalBytes, 0);
const ACTIVE = 3; // sessions in the "active" set
const hybridBytesPerSec = (sc.deltaBytes + wf.deltaBytes + jobStreams.reduce((a, s) => a + (s.totalBytes - (s.baselineBytes ?? 0)), 0)) / (w1.actualWindowMs / 1000);
P['d: hybrid (control push + workspace/follow + job/list x3 active)'] = {
  bytesPerSec: hybridBytesPerSec, mbPerHour: hybridBytesPerSec * 3600 / MB,
  components: { controlDelta: sc.deltaBytes, workspaceDelta: wf.deltaBytes, jobDelta: jobStreams.reduce((a, s) => a + (s.totalBytes - (s.baselineBytes ?? 0)), 0) },
  oneTimeBaselines: { control: sc.baselineBytes, workspace: wf.baselineBytes, job3: jobBaselineSum } };
out.projected = P;

writeFileSync(`${HERE}08-report.json`, JSON.stringify(out, null, 1));
console.log(JSON.stringify(out, null, 1));
