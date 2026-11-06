// Probe the `data` payload shape of the record types a usage dashboard needs.
import { readFileSync } from 'node:fs';
import { createZstdDecompress } from 'node:zlib';

async function decode(file) {
  const buf = readFileSync(file);
  const parts = []; let offset = 0, frames = 0;
  while (offset < buf.length) {
    const slice = buf.subarray(offset);
    let consumed = 0; const out = [];
    await new Promise((res, rej) => {
      const d = createZstdDecompress();
      d.on('data', c => out.push(c));
      d.on('end', () => { consumed = d.bytesWritten; res(); });
      d.on('error', rej);
      d.end(slice);
    });
    if (!consumed) break;
    parts.push(...out); offset += consumed; frames++;
  }
  return { raw: Buffer.concat(parts), frames };
}

const file = process.argv[2];
const { raw, frames } = await decode(file);
const recs = raw.toString('utf8').split('\n').filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
console.log(`frames=${frames} records=${recs.length}\n`);

const want = ['session','assistant/message','job/registered','job/settled','subagent/descriptor','session/title','step/start','step/end','turn/start','request/header','user/message'];
for (const t of want) {
  const hit = recs.find(r => r.type === t);
  if (!hit) { console.log(`--- ${t}: (none)`); continue; }
  console.log(`--- ${t} ---`);
  console.log(JSON.stringify(hit.data ?? hit, null, 1).slice(0, 1500));
  console.log();
}

// Hunt every distinct usage-ish path across the whole file
const paths = new Map();
const walk = (o, p, d = 0) => {
  if (d > 5 || !o || typeof o !== 'object') return;
  for (const [k, v] of Object.entries(o)) {
    const q = p ? `${p}.${k}` : k;
    if (/token|usage|cost|cache/i.test(k)) {
      const key = `${hitType(o)}|${q}`;
      paths.set(key, (paths.get(key) || 0) + 1);
    }
    if (v && typeof v === 'object' && !Array.isArray(v)) walk(v, q, d + 1);
  }
};
function hitType(o) { return o.__t || '?'; }
for (const r of recs) { r.__t = r.type; walk(r.data, ''); }
console.log('=== usage/token paths (path | count) ===');
[...paths.entries()].sort().forEach(([k, n]) => console.log(`  ${k}  x${n}`));
