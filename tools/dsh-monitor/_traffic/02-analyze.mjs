// 02-analyze.mjs — summarize the 6s probe capture (frame shapes per endpoint).
import { readFileSync } from 'node:fs';
const raw = JSON.parse(readFileSync(new URL('./02-stream-probe.raw.json', import.meta.url), 'utf8'));
for (const f of raw) {
  const p = f.parsed;
  const v = p?.value;
  const line = {
    bytes: f.bytes, wire: f.wire, type: p?.type,
    valueType: v?.type,
    valueTopKeys: v && typeof v === 'object' ? Object.keys(v) : null,
    innerKeys: v?.value && typeof v.value === 'object' ? Object.keys(v.value) : null,
    projectionsCount: v?.value?.projections ? Object.keys(v.value.projections).length : undefined,
    error: p?.error?.message
  };
  console.log(JSON.stringify(line));
  if (v?.value?.projections) {
    const [k, pv] = Object.entries(v.value.projections)[0];
    console.log('   sample projection key=', k, 'valueKeys=', Object.keys(pv), 'valuesKeys=', Object.keys(pv.values ?? {}));
    console.log('   sessionIds=', Object.keys(v.value.projections).slice(0, 5).join(','));
  }
  if (v?.type && v.type !== 'baseline') {
    console.log('   NON-BASELINE value keys:', JSON.stringify(Object.fromEntries(Object.entries(v).map(([k, x]) => [k, typeof x === 'object' ? (Array.isArray(x) ? `arr(${x.length})` : `obj(${Object.keys(x).slice(0,6).join(',')})`) : String(x).slice(0,50)]))));
  }
}
