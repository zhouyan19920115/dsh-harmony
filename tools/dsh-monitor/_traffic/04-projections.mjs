// 04-projections.mjs — unary session/projections for (a) busy running, (b) idle,
// (c) subagent session. Raw / gzip-9 / brotli-11 + per-key size breakdown.
import { writeFileSync, readFileSync } from 'node:fs';
import { gzipSync, brotliCompressSync, constants } from 'node:zlib';
import { DshClient } from '../dsh-client.mjs';

const HERE = new URL('./', import.meta.url).pathname.replace(/^\//, '');
const c = new DshClient();

const sl = JSON.parse(readFileSync(`${HERE}session-list.json`, 'utf8'));
const items = sl?.result?.value?.items ?? [];
const idOf = s => s?.sessionId ?? s?.id;
const running = items.filter(s => s?.running === true);
const idle = items.filter(s => s?.running !== true);
const subs = items.filter(s => s?.parentSessionId || s?.origin === 'subagent');

// pick a BUSY one that actually has projections with a turnOutline (a real working session)
const busy = running.find(s => (s?.projections?.turnOutline?.length ?? 0) > 0) ?? running[0];
// pick an IDLE one with a non-trivial title
const idlePick = idle.find(s => (s?.title ?? '').length > 0) ?? idle[0];
// subagent: prefer one whose parent is a running session
const subPick = subs.find(s => s?.projections?.tokenUsage) ?? subs[0];

const targets = [
  { kind: 'busy-running', s: busy },
  { kind: 'idle', s: idlePick },
  { kind: 'subagent', s: subPick }
];

const NAMED = ['title', 'tokenUsage', 'sessionStats', 'turnOutline', 'tokenOptimizer', 'contextBreakdown', 'agentTeam'];

const enc = text => {
  const b = Buffer.from(text, 'utf8');
  return {
    raw: b.length,
    gzip9: gzipSync(b, { level: 9 }).length,
    brotli11: brotliCompressSync(b, { params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: b.length } }).length
  };
};

/** find the projection "values" object anywhere in the response */
function findValues(node, depth = 0) {
  if (!node || typeof node !== 'object' || depth > 6) return null;
  if (node.values && typeof node.values === 'object' && (node.values.title !== undefined || node.values.tokenUsage !== undefined)) return node.values;
  for (const v of Object.values(node)) {
    const r = findValues(v, depth + 1);
    if (r) return r;
  }
  return null;
}

const results = [];
for (const t of targets) {
  if (!t.s) { results.push({ kind: t.kind, error: 'no candidate session found' }); continue; }
  const sid = idOf(t.s);
  const body = {
    type: 'client-request',
    rpcId: `r-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
    method: 'session/projections',
    payload: { args: { request: { sessionId: sid } } }
  };
  const bodyText = JSON.stringify(body);
  const t0 = Date.now();
  const res = await fetch(`http://${c.authority}/api/session/projections`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Cookie': c.cookie, 'Accept-Encoding': 'identity' },
    body: bodyText
  });
  const text = await res.text();
  const elapsed = Date.now() - t0;
  let json = null; try { json = JSON.parse(text); } catch {}
  const envelope = enc(text);
  const innerText = json?.result?.value === undefined ? null : JSON.stringify(json.result.value);
  const inner = innerText === null ? null : enc(innerText);
  const values = findValues(json?.result?.value);
  let breakdown = null;
  if (values) {
    const perKey = {};
    let other = 0;
    for (const [k, v] of Object.entries(values)) {
      const n = Buffer.byteLength(JSON.stringify(v ?? null), 'utf8');
      if (NAMED.includes(k)) perKey[k] = n; else other += n;
    }
    const namedSum = Object.values(perKey).reduce((a, b) => a + b, 0);
    breakdown = { perKey, other, namedSum, valuesKeyCount: Object.keys(values).length };
  }
  results.push({
    kind: t.kind, sessionId: sid, title: t.s?.title ?? null, running: t.s?.running ?? null,
    isSubagent: !!t.s?.parentSessionId || t.s?.origin === 'subagent',
    cwd: t.s?.cwd ?? null, parentSessionId: t.s?.parentSessionId ?? null, origin: t.s?.origin ?? null,
    httpStatus: res.status, elapsedMs: elapsed,
    requestBodyBytes: Buffer.byteLength(bodyText, 'utf8'),
    envelope, inner, breakdown,
    topLevelKeys: json?.result?.value && typeof json.result.value === 'object' ? Object.keys(json.result.value) : null,
    valuesKeys: values ? Object.keys(values) : null
  });
  process.stderr.write(`[04] ${t.kind} sid=${sid} raw=${envelope.raw} gzip9=${envelope.gzip9} br=${envelope.brotli11}\n`);
}

const out = { measuredAt: new Date().toISOString(), endpoint: 'session/projections', results };
writeFileSync(`${HERE}04-projections.result.json`, JSON.stringify(out, null, 1));
console.log(JSON.stringify(out, null, 1));
