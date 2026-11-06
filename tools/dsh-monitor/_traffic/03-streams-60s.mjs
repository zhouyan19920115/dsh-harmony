// 03-streams-60s.mjs — 60s window measurement of session/control, workspace/follow,
// job/list (x3 running sessions). Separate socket per stream so attribution is clean.
import { writeFileSync, readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { DshClient } from '../dsh-client.mjs';
import { wsConnect, attachFrameReader, sendText, sendClose } from './wsraw.mjs';

const HERE = new URL('./', import.meta.url).pathname.replace(/^\//, '');
const WINDOW_MS = Number(process.env.WINDOW_MS || 60000);

const c = new DshClient();
const [host, portStr] = c.authority.split(':');
const port = Number(portStr);

// ---- pick sessions from the cached session/list (do NOT re-call it) ----
const sl = JSON.parse(readFileSync(`${HERE}session-list.json`, 'utf8'));
const items = sl?.result?.value?.items ?? [];
const running = items.filter(s => s?.running === true);
const idle = items.filter(s => s?.running !== true);
const subagents = items.filter(s => s?.parentSessionId || s?.origin === 'subagent');
const pick = arr => (arr[0]?.sessionId ?? arr[0]?.id ?? null);
const jobSessionIds = running.slice(0, 3).map(s => s.sessionId ?? s.id).filter(Boolean);
process.stderr.write(`[03] running=${running.length} idle=${idle.length} subagents=${subagents.length} jobSessionIds=${JSON.stringify(jobSessionIds)}\n`);

async function collect(endpoint, args, label) {
  const { socket, responseHeaders } = await wsConnect({ host, port, path: '/api/remote.mux', cookie: c.cookie });
  const frames = [];
  attachFrameReader(socket, f => {
    if (f.opcode !== 0x1) return;
    const text = f.payload.toString('utf8');
    let parsed = null; try { parsed = JSON.parse(text); } catch {}
    frames.push({
      t: f.t, dt: 0, bytes: f.payload.length, wire: f.wireBytes,
      ftype: parsed?.type, valueType: parsed?.value?.type,
      key: parsed?.value?.key, sessionId: parsed?.value?.sessionId,
      vkeys: parsed?.value?.value && typeof parsed.value.value === 'object' ? Object.keys(parsed.value.value) : null,
      vlen: Array.isArray(parsed?.value?.value?.items) ? parsed.value.value.items.length
          : Array.isArray(parsed?.value?.value?.rows) ? parsed.value.value.rows.length
          : Array.isArray(parsed?.value?.value?.jobs) ? parsed.value.value.jobs.length : null,
      parsed
    });
  });
  const streamId = randomUUID();
  sendText(socket, JSON.stringify({ type: 'open', streamId, endpoint, payload: { args } }));
  return { label, endpoint, args, streamId, socket, frames, responseHeaders };
}

const t0 = Date.now();
const handles = [];
handles.push(await collect('session/control', {}, 'session/control'));
handles.push(await collect('workspace/follow', {}, 'workspace/follow'));
for (const sid of jobSessionIds) handles.push(await collect('job/list', { request: { sessionId: sid } }, `job/list:${sid}`));
const opened = Date.now();
process.stderr.write(`[03] ${handles.length} streams open at t=${opened - t0}ms; window ${WINDOW_MS}ms\n`);

await new Promise(r => setTimeout(r, WINDOW_MS));
const closed = Date.now();

// normalise dt relative to each stream's first frame
for (const h of handles) {
  const base = h.frames.length ? h.frames[0].t : opened;
  for (const f of h.frames) f.dt = f.t - base;
}

const out = {
  measuredAt: new Date().toISOString(),
  windowMs: WINDOW_MS,
  actualWindowMs: closed - opened,
  openLatencyMs: opened - t0,
  wsPath: '/api/remote.mux',
  permessageDeflateNegotiated: !!handles[0].responseHeaders['sec-websocket-extensions'],
  handshakeResponseHeaders: handles[0].responseHeaders,
  streams: handles.map(h => ({
    label: h.label, endpoint: h.endpoint, args: h.args, streamId: h.streamId,
    frameCount: h.frames.length,
    totalBytes: h.frames.reduce((a, f) => a + f.bytes, 0),
    totalWireBytes: h.frames.reduce((a, f) => a + f.wire, 0),
    baselineBytes: h.frames.find(f => f.valueType === 'baseline')?.bytes ?? null,
    frames: h.frames.map(f => ({ t: f.t, dt: f.dt, bytes: f.bytes, wire: f.wire, ftype: f.ftype, valueType: f.valueType, key: f.key, sessionId: f.sessionId, vkeys: f.vkeys, vlen: f.vlen }))
  }))
};

writeFileSync(`${HERE}03-streams-60s.result.json`, JSON.stringify(out, null, 1));
writeFileSync(`${HERE}03-streams-60s.frames.json`, JSON.stringify(handles.map(h => ({ label: h.label, frames: h.frames })), null, 1));

// console summary
for (const s of out.streams) {
  const perKey = {};
  for (const f of s.frames) { const k = f.key ?? (f.valueType === 'baseline' ? 'baseline' : 'other'); perKey[k] = (perKey[k] || 0) + f.bytes; }
  const kbPerMin = s.totalBytes / 1024 / (WINDOW_MS / 60000);
  console.log(JSON.stringify({ label: s.label, frames: s.frameCount, totalBytes: s.totalBytes, baseline: s.baselineBytes, perKey, bytesPerFrame: s.frameCount ? +(s.totalBytes / s.frameCount).toFixed(2) : 0, kbPerMin: +kbPerMin.toFixed(3) }));
}
console.log(JSON.stringify({ permessageDeflateNegotiated: out.permessageDeflateNegotiated, actualWindowMs: out.actualWindowMs }));

for (const h of handles) { sendClose(h.socket); h.socket.destroy(); }
process.exit(0);
