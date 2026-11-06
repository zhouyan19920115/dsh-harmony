// 06-projections2.mjs — projections for explicit busy/idle/subagent targets AND
// every running session (needed for the "poll all running sessions" projection).
import { writeFileSync, readFileSync } from 'node:fs';
import { gzipSync, brotliCompressSync, constants } from 'node:zlib';
import { DshClient } from '../dsh-client.mjs';

const HERE = new URL('./', import.meta.url).pathname.replace(/^\//, '');
const c = new DshClient();
const sl = JSON.parse(readFileSync(`${HERE}session-list.json`, 'utf8'));
const items = sl?.result?.value?.items ?? [];

const NAMED = ['title', 'tokenUsage', 'sessionStats', 'turnOutline', 'tokenOptimizer', 'contextBreakdown', 'agentTeam'];
const enc = text => { const b = Buffer.from(text, 'utf8'); return {
  raw: b.length, gzip9: gzipSync(b, { level: 9 }).length,
  brotli11: brotliCompressSync(b, { params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: b.length } }).length }; };

function findValues(node, depth = 0) {
  if (!node || typeof node !== 'object' || depth > 6) return null;
  if (node.values && typeof node.values === 'object' && (node.values.title !== undefined || node.values.tokenUsage !== undefined)) return node.values;
  for (const v of Object.values(node)) { const r = findValues(v, depth + 1); if (r) return r; }
  return null;
}

async function measure(sid) {
  const bodyText = JSON.stringify({ type: 'client-request', rpcId: `r-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
    method: 'session/projections', payload: { args: { request: { sessionId: sid } } } });
  const t0 = Date.now();
  const res = await fetch(`http://${c.authority}/api/session/projections`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'Cookie': c.cookie, 'Accept-Encoding': 'identity' }, body: bodyText });
  const text = await res.text();
  const elapsed = Date.now() - t0;
  let json = null; try { json = JSON.parse(text); } catch {}
  const envelope = enc(text);
  const innerText = json?.result?.value === undefined ? null : JSON.stringify(json.result.value);
  const inner = innerText === null ? null : enc(innerText);
  const values = findValues(json?.result?.value);
  let breakdown = null;
  if (values) {
    const perKey = {}; let other = 0;
    for (const [k, v] of Object.entries(values)) {
      const n = Buffer.byteLength(JSON.stringify(v ?? null), 'utf8');
      if (NAMED.includes(k)) perKey[k] = n; else other += n;
    }
    breakdown = { perKey, other, namedSum: Object.values(perKey).reduce((a, b) => a + b, 0), valuesKeyCount: Object.keys(values).length };
  }
  return { sessionId: sid, httpStatus: res.status, elapsedMs: elapsed, requestBodyBytes: Buffer.byteLength(bodyText, 'utf8'),
    envelope, inner, breakdown, valuesKeys: values ? Object.keys(values) : null,
    title: values?.title ?? null, running: json?.result?.value?.running ?? null };
}

// ---- explicit targets ----
const runningIds = items.filter(s => s?.running === true).map(s => s?.sessionId ?? s?.id);
const BUSY = 'session-5a1145f6-7195-4443-b375-6462e72d3980';   // biggest running projection (49,907 B)
const IDLE_FAT = 'session-9de904f1-55bd-4b89-88ef-8b9c5b0fce1e'; // idle session with a big turnOutline
const SUB = 'b5307f18-18b6-4d95-b7db-3cd36055569c';             // running subagent of BUSY

const out = { measuredAt: new Date().toISOString(), targets: {}, allRunning: [] };

for (const [kind, sid] of [['busy-running', BUSY], ['idle', IDLE_FAT], ['subagent', SUB]]) {
  out.targets[kind] = await measure(sid);
  const t = out.targets[kind];
  process.stderr.write(`[06] ${kind} ${sid} raw=${t.envelope.raw} gzip9=${t.envelope.gzip9} br11=${t.envelope.brotli11} elapsed=${t.elapsedMs}ms\n`);
}

// ---- every running session ----
for (const sid of runningIds) {
  const r = await measure(sid);
  out.allRunning.push(r);
  process.stderr.write(`[06] running ${sid} raw=${r.envelope.raw}\n`);
}
writeFileSync(`${HERE}06-projections.result.json`, JSON.stringify(out, null, 1));
console.log(JSON.stringify(out, null, 1));
