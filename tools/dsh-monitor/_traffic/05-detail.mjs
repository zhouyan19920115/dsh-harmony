// 05-detail.mjs — detail: job/list frame contents, session/control frame timing,
// and a proper busy/idle/subagent selection for session/projections.
import { readFileSync, writeFileSync } from 'node:fs';

const HERE = new URL('./', import.meta.url).pathname.replace(/^\//, '');

// ---- job/list frame contents ----
const frames = JSON.parse(readFileSync(`${HERE}03-streams-60s.frames.json`, 'utf8'));
for (const s of frames) {
  if (!s.label.startsWith('job/list')) continue;
  console.log(`--- ${s.label} ---`);
  for (const f of s.frames) {
    console.log(JSON.stringify({ dt: f.dt, bytes: f.bytes, ftype: f.ftype, valueType: f.valueType, vkeys: f.vkeys, vlen: f.vlen }));
    console.log('   raw:', JSON.stringify(f.parsed).slice(0, 600));
  }
}

// ---- session/control timing ----
const sc = frames.find(s => s.label === 'session/control');
console.log('\n--- session/control frame timeline ---');
for (const f of sc.frames) console.log(JSON.stringify({ dt: f.dt, bytes: f.bytes, type: f.valueType, key: f.key, sessionId: f.sessionId }));
const deltas = sc.frames.filter(f => f.valueType !== 'baseline');
const gaps = [];
for (let i = 1; i < deltas.length; i++) gaps.push(deltas[i].dt - deltas[i - 1].dt);
console.log('delta frames:', deltas.length, 'delta bytes:', deltas.reduce((a, f) => a + f.bytes, 0));
console.log('gap ms min/median/max:', gaps.length ? Math.min(...gaps) : null, gaps.length ? gaps.sort((a,b)=>a-b)[Math.floor(gaps.length/2)] : null, gaps.length ? Math.max(...gaps) : null);

// ---- workspace/follow ----
const wf = frames.find(s => s.label === 'workspace/follow');
console.log('\n--- workspace/follow ---');
for (const f of wf.frames) console.log(JSON.stringify({ dt: f.dt, bytes: f.bytes, type: f.valueType, vkeys: f.vkeys, vlen: f.vlen }));
console.log('wf raw head:', JSON.stringify(wf.frames[0].parsed).slice(0, 800));

// ---- proper busy/idle/subagent candidates from session/list ----
const sl = JSON.parse(readFileSync(`${HERE}session-list.json`, 'utf8'));
const items = sl?.result?.value?.items ?? [];
console.log('\n--- session/list item sample keys ---');
console.log(Object.keys(items[0] ?? {}));
console.log(JSON.stringify(items[0]).slice(0, 1200));

const tok = s => { const u = s?.projections?.tokenUsage ?? {}; return (u.uncachedInputTokens ?? 0) + (u.outputTokens ?? 0) + (u.cacheReadTokens ?? 0) + (u.cacheWriteTokens ?? 0); };
const topLevel = s => !(s?.parentSessionId || s?.origin === 'subagent');
const running = items.filter(s => s?.running === true);
const cands = running.map(s => ({
  id: s?.sessionId ?? s?.id, title: s?.projections?.title ?? s?.title, tokens: tok(s),
  outlineLen: s?.projections?.turnOutline?.length ?? 0,
  outlineBytes: Buffer.byteLength(JSON.stringify(s?.projections?.turnOutline ?? []), 'utf8'),
  sub: !topLevel(s), origin: s?.origin, parent: s?.parentSessionId,
  projBytes: Buffer.byteLength(JSON.stringify(s?.projections ?? {}), 'utf8')
})).sort((a, b) => b.projBytes - a.projBytes);
console.log('\n--- top running sessions by projection bytes ---');
console.log(JSON.stringify(cands.slice(0, 8), null, 1));
console.log('\n--- top running TOP-LEVEL sessions by projection bytes ---');
console.log(JSON.stringify(cands.filter(c => !c.sub).slice(0, 8), null, 1));
writeFileSync(`${HERE}05-candidates.json`, JSON.stringify(cands, null, 1));
