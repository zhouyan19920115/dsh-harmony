// 01-session-list.mjs — call session/list EXACTLY ONCE, measure raw/gzip/brotli bytes.
// Reuses DshClient only for auth (mintCookie). We do our own fetch so we can
// capture the exact response bytes + headers.
import { writeFileSync } from 'node:fs';
import { gzipSync, brotliCompressSync, constants } from 'node:zlib';
import { DshClient } from '../dsh-client.mjs';

const OUT = new URL('./', import.meta.url).pathname.replace(/^\//, '');
const c = new DshClient();
const authority = c.authority;
const cookie = c.cookie;

const body = {
  type: 'client-request',
  rpcId: `r-${Date.now()}-traffic`,
  method: 'session/list',
  payload: { args: { _request: {} } }
};
const bodyText = JSON.stringify(body);

const t0 = Date.now();
process.stderr.write(`[01] POST http://${authority}/api/session/list ...\n`);
const res = await fetch(`http://${authority}/api/session/list`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'Cookie': cookie, 'Accept-Encoding': 'identity' },
  body: bodyText
});
const text = await res.text();
const elapsed = Date.now() - t0;

const raw = Buffer.byteLength(text, 'utf8');
const gz = gzipSync(Buffer.from(text, 'utf8'), { level: 9 }).length;
const br = brotliCompressSync(Buffer.from(text, 'utf8'), {
  params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: raw }
}).length;

let json = null;
try { json = JSON.parse(text); } catch { /* keep null */ }

const innerText = json?.result?.value === undefined ? null : JSON.stringify(json.result.value);
const innerRaw = innerText === null ? null : Buffer.byteLength(innerText, 'utf8');
const innerGz = innerText === null ? null : gzipSync(Buffer.from(innerText, 'utf8'), { level: 9 }).length;
const innerBr = innerText === null ? null : brotliCompressSync(Buffer.from(innerText, 'utf8'), {
  params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: innerRaw }
}).length;

const items = json?.result?.value?.items ?? json?.result?.value ?? [];
const list = Array.isArray(items) ? items : [];

const out = {
  measuredAt: new Date().toISOString(),
  endpoint: `http://${authority}/api/session/list`,
  elapsedMs: elapsed,
  httpStatus: res.status,
  responseHeaders: Object.fromEntries(res.headers.entries()),
  requestBodyBytes: Buffer.byteLength(bodyText, 'utf8'),
  envelope: { raw, gzip9: gz, brotli11: br },
  innerValue: innerText === null ? null : { raw: innerRaw, gzip9: innerGz, brotli11: innerBr },
  itemCount: list.length,
  runningCount: list.filter(s => s?.running).length,
  subagentCount: list.filter(s => s?.parentSessionId || s?.origin === 'subagent').length,
  rawText: text
};

writeFileSync(`${OUT}session-list.json`, JSON.stringify(json, null, 1));
writeFileSync(`${OUT}session-list-envelope.json`, text);
writeFileSync(`${OUT}01-session-list.result.json`, JSON.stringify(out, null, 2));

process.stderr.write(`[01] done in ${elapsed}ms status=${res.status} items=${out.itemCount} running=${out.runningCount} subagents=${out.subagentCount}\n`);
process.stderr.write(`[01] envelope raw=${raw} gzip9=${gz} brotli11=${br}\n`);
process.stderr.write(`[01] innerValue raw=${innerRaw} gzip9=${innerGz} brotli11=${innerBr}\n`);
console.log(JSON.stringify({ ...out, rawText: undefined, responseHeaders: undefined }, null, 2));
