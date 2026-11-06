// 11-strip.mjs — what does the session/control baseline cost if a local relay
// strips the keys a telemetry dashboard does NOT need?
import { readFileSync } from 'node:fs';
import { gzipSync, brotliCompressSync, constants } from 'node:zlib';
const HERE = new URL('./', import.meta.url).pathname.replace(/^\//, '');
const frames = JSON.parse(readFileSync(`${HERE}03-streams-60s.frames.json`, 'utf8'));
const sc = frames.find(s => s.label === 'session/control');
const base = sc.frames.find(f => f.valueType === 'baseline');
const rawText = base.text ?? JSON.stringify(base.parsed);
const ps = base.parsed.value.value.projections;

const enc = t => { const b = Buffer.from(t, 'utf8'); return { raw: b.length, gzip9: gzipSync(b, { level: 9 }).length, brotli11: brotliCompressSync(b, { params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: b.length } }).length }; };

console.log('FULL baseline frame            :', JSON.stringify(enc(rawText)));

// key groups
const NEEDED = ['title', 'tokenUsage', 'sessionStats', 'contextPressure', 'contextBreakdown', 'workingDirectory'];
const MINIMAL = ['title', 'tokenUsage', 'sessionStats'];
function strip(keys) {
  const out = {};
  for (const [sid, p] of Object.entries(ps)) {
    const v = {};
    for (const k of keys) if (p.values[k] !== undefined) v[k] = p.values[k];
    out[sid] = { asOfSeq: p.asOfSeq, values: v };
  }
  return JSON.stringify({ type: 'item', value: { type: 'baseline', value: { projections: out } } });
}
for (const [label, keys] of [['dashboard-needed (6 keys)', NEEDED], ['minimal (title/tokenUsage/sessionStats)', MINIMAL]]) {
  const t = strip(keys);
  console.log(`STRIPPED ${label.padEnd(42)}:`, JSON.stringify(enc(t)));
}

// per-key totals across all 69 sessions in the baseline
const totals = {};
for (const p of Object.values(ps)) for (const [k, v] of Object.entries(p.values)) totals[k] = (totals[k] || 0) + Buffer.byteLength(JSON.stringify(v ?? null), 'utf8');
const sorted = Object.entries(totals).sort((a, b) => b[1] - a[1]);
console.log('\nper-key totals across baseline (' + Object.keys(ps).length + ' sessions):');
for (const [k, n] of sorted) console.log(`  ${k.padEnd(24)} ${String(n).padStart(8)}  ${(100 * n / Object.values(totals).reduce((a, b) => a + b, 0)).toFixed(2)}%`);

// delta frames: how many bytes if only the 3 dashboard keys are forwarded?
const deltas = sc.frames.filter(f => f.valueType === 'projection');
const keep = new Set(MINIMAL);
const fwd = deltas.filter(f => keep.has(f.key));
const rawFwd = fwd.map(f => JSON.stringify(f.parsed)).join('\n');
console.log('\ndelta frames total:', deltas.length, 'bytes', deltas.reduce((a, f) => a + f.bytes, 0));
console.log('after filtering to title/tokenUsage/sessionStats:', fwd.length, 'bytes', fwd.reduce((a, f) => a + f.bytes, 0), 'gzip9 of batch:', gzipSync(Buffer.from(rawFwd, 'utf8'), { level: 9 }).length);
