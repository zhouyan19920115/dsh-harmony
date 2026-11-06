// 02-stream-probe.mjs — short probe to learn the frame SHAPE of each stream
// endpoint (we need this before writing the 60s collectors).
import { writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { DshClient } from '../dsh-client.mjs';
import { wsConnect, attachFrameReader, sendText, sendClose } from './wsraw.mjs';

const c = new DshClient();
const [host, portStr] = c.authority.split(':');
const port = Number(portStr);

const { socket, responseHeaders } = await wsConnect({
  host, port, path: '/api/remote.mux', cookie: c.cookie
});
process.stderr.write(`handshake ok: ${JSON.stringify(responseHeaders)}\n`);

const rawFrames = [];
attachFrameReader(socket, f => {
  if (f.opcode !== 0x1) { if (f.ping) { /* ignore */ } return; }
  const text = f.payload.toString('utf8');
  let parsed = null; try { parsed = JSON.parse(text); } catch {}
  rawFrames.push({ t: f.t, bytes: f.payload.length, wire: f.wireBytes, text, parsed });
});

const streams = [
  { endpoint: 'session/control', args: {} },
  { endpoint: 'workspace/follow', args: {} },
  { endpoint: 'job/list', args: { sessionId: 'probe' } }
];

for (const s of streams) {
  const streamId = randomUUID();
  const frame = { type: 'open', streamId, endpoint: s.endpoint, payload: { args: s.args } };
  sendText(socket, JSON.stringify(frame));
  process.stderr.write(`opened ${s.endpoint} -> ${JSON.stringify(frame)}\n`);
}

await new Promise(r => setTimeout(r, 6000));

writeFileSync(new URL('./02-stream-probe.raw.json', import.meta.url), JSON.stringify(rawFrames, null, 1));

// Print a shape summary (keys only, truncated values)
const summary = rawFrames.map((f, i) => {
  const p = f.parsed;
  const v = p?.value;
  let valueShape = null;
  if (v && typeof v === 'object') {
    valueShape = {};
    for (const [k, val] of Object.entries(v)) {
      const s = typeof val === 'string' ? JSON.stringify(val).slice(0, 60)
        : Array.isArray(val) ? `[array len=${val.length}]`
        : val && typeof val === 'object' ? `{obj keys=${Object.keys(val).join(',')}}`
        : String(val);
      valueShape[k] = s;
    }
  }
  return { i, bytes: f.bytes, wire: f.wire, type: p?.type, streamId: p?.streamId, endpoint: p?.endpoint, valueShape, rawHead: f.text.slice(0, 400) };
});
console.log(JSON.stringify(summary, null, 1));

sendClose(socket);
socket.destroy();
process.exit(0);
