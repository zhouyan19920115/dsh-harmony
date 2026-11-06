// DSH session log inspector — proves what can be read locally, with zero server.
// DSH stores each session as  <DSH_HOME>/sessions/<workspace-slug>/<sessionId>/session.v4.jsonl.zstd
// This script decompresses one file and reports the record shapes + token usage fields.
import { readFileSync } from 'node:fs';
import { createZstdDecompress } from 'node:zlib';

const file = process.argv[2];
if (!file) { console.error('usage: node inspect-session.mjs <session.v4.jsonl.zstd>'); process.exit(1); }

// DSH writes zstd as a CONCATENATED frame stream. Node's zstd decompressor stops at the
// end of frame #1, so we walk the stream frame by frame using bytesWritten as the cursor.
const buf = readFileSync(file);
const parts = [];
let offset = 0, frames = 0;
while (offset < buf.length) {
  const slice = buf.subarray(offset);
  let consumed = 0, out = [];
  let ended = false;
  await new Promise((res, rej) => {
    const d = createZstdDecompress();
    d.on('data', c => out.push(c));
    d.on('end', () => { ended = true; consumed = d.bytesWritten; res(); });
    d.on('error', rej);
    d.end(slice);
  });
  if (!ended || consumed <= 0) break;
  parts.push(...out);
  offset += consumed;
  frames++;
  if (frames > 5000) break;
}
const raw = Buffer.concat(parts);
console.log(`frames decoded: ${frames}, input consumed: ${offset}/${buf.length}`);
const lines = raw.toString('utf8').split('\n').filter(Boolean);
console.log(`file       : ${file}`);
console.log(`decompressed: ${(raw.length/1048576).toFixed(2)} MB, ${lines.length} records\n`);

const typeCount = new Map();
const keyShapes = new Map();
let usageSample = null, usageCount = 0, usageKeys = new Set();
let modelSample = null, tsFields = new Set(), roleSample = null;
const nested = (o, depth, path, out) => {
  if (depth > 3 || !o || typeof o !== 'object') return;
  for (const [k, v] of Object.entries(o)) {
    if (/usage|token/i.test(k)) out.push(`${path}.${k}`);
    if (v && typeof v === 'object' && !Array.isArray(v)) nested(v, depth + 1, `${path}.${k}`, out);
  }
};

for (const line of lines) {
  let rec; try { rec = JSON.parse(line); } catch { continue; }
  const t = rec.type ?? rec.kind ?? rec.event ?? '(none)';
  typeCount.set(t, (typeCount.get(t) || 0) + 1);

  const shape = Object.keys(rec).sort().join(',');
  if (!keyShapes.has(t)) keyShapes.set(t, { shape, n: 0, sample: rec });
  keyShapes.get(t).n++;

  if (rec.model && !modelSample) modelSample = rec.model;
  for (const k of ['timestamp','ts','createdAt','time','at']) if (rec[k] !== undefined) tsFields.add(k);
  if (rec.role) roleSample = rec.role;

  const hits = []; nested(rec, 0, '', hits);
  const uHits = hits.filter(h => /usage|token/i.test(h));
  if (uHits.length) {
    usageCount++;
    uHits.forEach(h => usageKeys.add(h));
    if (!usageSample) usageSample = JSON.stringify(rec).slice(0, 1400);
  }
}

console.log('=== record types ===');
[...typeCount.entries()].sort((a,b)=>b[1]-a[1]).forEach(([t,n]) => console.log(`  ${String(n).padStart(6)}  ${t}`));

console.log('\n=== key shapes per type ===');
for (const [t, s] of keyShapes) console.log(`  [${t}] x${s.n}\n    ${s.shape}`);

console.log('\n=== token/usage bearing fields ===');
console.log('  records containing usage/token keys:', usageCount, '/', lines.length);
console.log('  distinct paths:', [...usageKeys].join(', ') || '(none)');
console.log('\n=== one usage-bearing record (truncated) ===');
console.log(usageSample ? usageSample.slice(0, 1200) : '(none)');
console.log('\n=== misc ===');
console.log('  model sample :', modelSample);
console.log('  timestamp flds:', [...tsFields].join(', ') || '(none)');
console.log('  role sample  :', roleSample);
