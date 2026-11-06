// 07-second-window.mjs — a SECOND 45s session/control + workspace/follow capture,
// to contrast the "busy" window against a quieter one.
import { writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { DshClient } from '../dsh-client.mjs';
import { wsConnect, attachFrameReader, sendText, sendClose } from './wsraw.mjs';

const HERE = new URL('./', import.meta.url).pathname.replace(/^\//, '');
const WINDOW_MS = Number(process.env.WINDOW_MS || 45000);
const c = new DshClient();
const [host, portStr] = c.authority.split(':');
const port = Number(portStr);

async function collect(endpoint, args, label) {
  const { socket, responseHeaders } = await wsConnect({ host, port, path: '/api/remote.mux', cookie: c.cookie });
  const frames = [];
  attachFrameReader(socket, f => {
    if (f.opcode !== 0x1) return;
    const text = f.payload.toString('utf8');
    let parsed = null; try { parsed = JSON.parse(text); } catch {}
    frames.push({ t: f.t, bytes: f.payload.length, wire: f.wireBytes, ftype: parsed?.type,
      valueType: parsed?.value?.type, key: parsed?.value?.key, sessionId: parsed?.value?.sessionId });
  });
  const streamId = randomUUID();
  sendText(socket, JSON.stringify({ type: 'open', streamId, endpoint, payload: { args } }));
  return { label, socket, frames, responseHeaders };
}

const t0 = Date.now();
const a = await collect('session/control', {}, 'session/control');
const b = await collect('workspace/follow', {}, 'workspace/follow');
const opened = Date.now();
await new Promise(r => setTimeout(r, WINDOW_MS));
const closed = Date.now();

const out = { windowMs: WINDOW_MS, actualWindowMs: closed - opened, openLatencyMs: opened - t0, streams: [] };
for (const h of [a, b]) {
  const base = h.frames.length ? h.frames[0].t : opened;
  for (const f of h.frames) f.dt = f.t - base;
  const total = h.frames.reduce((x, f) => x + f.bytes, 0);
  const baseline = h.frames.find(f => f.valueType === 'baseline');
  const deltas = h.frames.filter(f => f.valueType !== 'baseline');
  const perKey = {};
  for (const f of h.frames) { const k = f.key ?? (f.valueType === 'baseline' ? 'baseline' : 'other'); perKey[k] = (perKey[k] || 0) + f.bytes; }
  // what would per-frame gzip cost us (i.e. if a proxy compressed each frame)
  const gzipTotal = h.frames.reduce((x, f) => x + gzipSync(Buffer.from(JSON.stringify(f.parsed ?? null)), { level: 9 }).length, 0);
  out.streams.push({ label: h.label, frameCount: h.frames.length, totalBytes: total, totalWireBytes: h.frames.reduce((x, f) => x + f.wire, 0),
    baselineBytes: baseline?.bytes ?? null, deltaBytes: total - (baseline?.bytes ?? 0), deltaFrames: deltas.length, perKey,
    gzip9TotalBytes: gzipTotal, frames: h.frames.map(f => ({ dt: f.dt, bytes: f.bytes, valueType: f.valueType, key: f.key, sessionId: f.sessionId })) });
}
writeFileSync(`${HERE}07-second-window.result.json`, JSON.stringify(out, null, 1));
for (const s of out.streams) console.log(JSON.stringify({ label: s.label, frames: s.frameCount, total: s.totalBytes, baseline: s.baselineBytes, deltaBytes: s.deltaBytes, deltaFrames: s.deltaFrames, perKey: s.perKey, gzip9Total: s.gzip9TotalBytes }));
for (const h of [a, b]) { sendClose(h.socket); h.socket.destroy(); }
process.exit(0);
