import { readFileSync } from 'node:fs';
const HERE = new URL('./', import.meta.url).pathname.replace(/^\//, '');
const frames = JSON.parse(readFileSync(`${HERE}03-streams-60s.frames.json`, 'utf8'));
for (const s of frames) {
  if (!s.label.startsWith('job/list')) continue;
  for (const f of s.frames) {
    const jobs = f.parsed?.value?.jobs ?? [];
    console.log(`${s.label} :: bytes=${f.bytes} wire=${f.wire} valueType=${f.parsed?.value?.type} jobCount=${jobs.length} perJobAvg=${jobs.length ? (f.bytes / jobs.length).toFixed(1) : 'n/a'}`);
    for (const j of jobs) console.log('   job:', JSON.stringify({ id: j.id, kind: j.kind, status: j.status, labelBytes: Buffer.byteLength(j.label ?? '', 'utf8'), detail: j.detail }));
  }
}
// workspace/follow baseline shape
const wf = frames.find(s => s.label === 'workspace/follow');
const v = wf.frames[0].parsed?.value?.value;
console.log('\nworkspace/follow baseline inner keys:', Object.keys(v ?? {}));
console.log('  items:', Array.isArray(v?.items) ? v.items.length : v?.items, ' archived:', v?.archivedSessionIds?.length, ' pinned:', v?.pinnedSessionIds?.length);
console.log('  first item:', JSON.stringify(v?.items?.[0]).slice(0, 500));
// session/control baseline composition: per-session share
const sc = frames.find(s => s.label === 'session/control');
const b = sc.frames.find(f => f.valueType === 'baseline');
const ps = b.parsed?.value?.value?.projections ?? {};
const sizes = Object.entries(ps).map(([k, v]) => [k, Buffer.byteLength(JSON.stringify(v), 'utf8')]).sort((a, b) => b[1] - a[1]);
console.log('\nsession/control baseline: sessions=' + sizes.length + ' totalJsonBytes=' + Buffer.byteLength(JSON.stringify(ps), 'utf8'));
console.log('  top5:', JSON.stringify(sizes.slice(0, 5)));
console.log('  sum top5:', sizes.slice(0, 5).reduce((a, x) => a + x[1], 0), 'sum all:', sizes.reduce((a, x) => a + x[1], 0));
