// 10-filter-probe.mjs — can we ask for a SUBSET of projection keys?
// If yes, the minimum-bandwidth design can drop turnOutline/agentTeam entirely.
import { DshClient } from '../dsh-client.mjs';
const c = new DshClient();
const BUSY = 'session-5a1145f6-7195-4443-b375-6462e72d3980';

const tries = [
  ['projections keys[]', 'session/projections', { request: { sessionId: BUSY, keys: ['tokenUsage', 'sessionStats', 'title'] } }],
  ['projections keys string', 'session/projections', { request: { sessionId: BUSY, keys: 'tokenUsage' } }],
  ['projections fields[]', 'session/projections', { request: { sessionId: BUSY, fields: ['tokenUsage'] } }],
  ['projections projections[]', 'session/projections', { request: { sessionId: BUSY, projections: ['tokenUsage'] } }],
  ['projections include[]', 'session/projections', { request: { sessionId: BUSY, include: ['tokenUsage'] } }],
  ['projections keys+noTurnOutline', 'session/projections', { request: { sessionId: BUSY, keys: ['tokenUsage', 'sessionStats', 'contextPressure', 'contextBreakdown', 'title', 'workingDirectory'] } }],
];

for (const [label, method, args] of tries) {
  const bodyText = JSON.stringify({ type: 'client-request', rpcId: `r-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`, method, payload: { args } });
  const res = await fetch(`http://${c.authority}/api/${method}`, { method: 'POST', headers: { 'Content-Type': 'application/json', Cookie: c.cookie }, body: bodyText });
  const text = await res.text();
  let json = null; try { json = JSON.parse(text); } catch {}
  const ok = json?.result?.ok !== false;
  const v = json?.result?.value;
  const keys = v?.values ? Object.keys(v.values) : null;
  console.log(JSON.stringify({ label, status: res.status, ok, bytes: Buffer.byteLength(text, 'utf8'), err: json?.result?.error?.message?.slice(0, 160) ?? null, valuesKeys: keys, nValues: keys?.length ?? null }));
}

// ---- session/control with a filter arg? ----
const { wsConnect, attachFrameReader, sendText, sendClose } = await import('./wsraw.mjs');
const [host, portStr] = c.authority.split(':');
for (const [label, args] of [
  ['control args keys[]', { keys: ['tokenUsage', 'sessionStats'] }],
  ['control args request.keys[]', { request: { keys: ['tokenUsage'] } }],
  ['control args sessions[]', { sessionIds: [BUSY] }]
]) {
  const { socket } = await wsConnect({ host, port: Number(portStr), path: '/api/remote.mux', cookie: c.cookie });
  let got = null;
  attachFrameReader(socket, f => { if (f.opcode === 0x1 && !got) { try { got = JSON.parse(f.payload.toString('utf8')); } catch { got = { raw: true }; } } });
  sendText(socket, JSON.stringify({ type: 'open', streamId: crypto.randomUUID(), endpoint: 'session/control', payload: { args } }));
  await new Promise(r => setTimeout(r, 1500));
  console.log(JSON.stringify({ label, firstFrameBytes: got ? JSON.stringify(got).length : null, error: got?.error?.message?.slice(0, 160) ?? null, vtype: got?.value?.type ?? null, nProj: got?.value?.value?.projections ? Object.keys(got.value.value.projections).length : null }));
  sendClose(socket); socket.destroy();
}
process.exit(0);
