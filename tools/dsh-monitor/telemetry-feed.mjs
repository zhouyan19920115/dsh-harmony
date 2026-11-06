// Compact telemetry feed — the thing a phone would pull.
//
// Design goal: the phone must NOT pull DSH's raw API through the Cloudflare tunnel.
// The desktop computes a compact aggregate and publishes it; the phone renders that.
//
// Sources (all local, no extra service):
//   session/control  (WS)  → baseline projections: tokenUsage + sessionStats(decode rate)
//   workspace/follow (WS)  → workspaces and their sessionIds
//   job/list         (WS)  → background jobs, opened per watched session
//   ~/.dsh/storages/session_projcache/*.json → fast per-session token totals (no HTTP)
//
// Usage:
//   node telemetry-feed.mjs                 # one-shot snapshot → telemetry.json
//   node telemetry-feed.mjs --watch 2       # refresh every 2s, print byte size
import { writeFileSync, readFileSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { gzipSync } from 'node:zlib';
import { DshClient } from './dsh-client.mjs';

const DSH_HOME = process.env.DSH_HOME || `${process.env.USERPROFILE}\\.dsh`;
const OUT = process.argv.find(a => a.endsWith('.json') && !a.endsWith('snapshot.json')) || './telemetry.json';
const WATCH = process.argv.includes('--watch');
const EVERY = Number(process.argv[process.argv.indexOf('--watch') + 1]) || 2;
const norm = c => (c || '(未知)').replace(/\//g, '\\').replace(/\\+/g, '\\').replace(/\\+$/, '');

/* ---------- 1. fast local token totals from the projection cache ---------- */
function projcacheTotals() {
  const dir = join(DSH_HOME, 'storages', 'session_projcache', 'sessions');
  const out = new Map();
  if (!existsSync(dir)) return out;
  for (const f of readdirSync(dir)) {
    if (!f.endsWith('.json')) continue;
    try {
      const j = JSON.parse(readFileSync(join(dir, f), 'utf8'));
      const t = j?.tokenUsage?.val?.totals ?? j?.tokenUsage?.totals ?? j?.values?.tokenUsage;
      if (!t) continue;
      const id = f.replace(/\.json$/, '');
      const billed = (t.uncachedInputTokens ?? 0) + (t.outputTokens ?? 0);
      out.set(id, {
        billed, total: billed + (t.cacheReadTokens ?? 0) + (t.cacheWriteTokens ?? 0),
        cache: (t.cacheReadTokens ?? 0) + (t.cacheWriteTokens ?? 0),
        cwd: norm(j?.identity?.cwd ?? j?.cwd),
        title: j?.title ?? null
      });
    } catch { /* skip malformed */ }
  }
  return out;
}

/* ---------- 2. live WS streams ---------- */
function openStream(ws, endpoint, args = {}) {
  const streamId = crypto.randomUUID();
  ws.send(JSON.stringify({ type: 'open', streamId, endpoint, payload: { args } }));
  return streamId;
}

async function collectLive(c) {
  const authority = c.authority;
  const cookie = c.cookie;
  const ws = new WebSocket(`ws://${authority}/api/remote.mux`, { headers: { Cookie: cookie } });
  const sessions = new Map();   // id -> {billed,total,cache,cwd,title,rate}
  const workspaces = new Map();
  const jobs = new Map();
  const listeners = [];

  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  ws.onmessage = (ev) => {
    let m; try { m = JSON.parse(ev.data); } catch { return; }
    if (m.type !== 'item') return;
    const v = m.value ?? {};
    for (const fn of listeners) fn(v);
  };

  listeners.push(v => {
    if (v.type === 'baseline' && v.value?.projections) {
      for (const [sid, p] of Object.entries(v.value.projections)) {
        const vals = p?.values ?? p ?? {};
        const tu = vals.tokenUsage ?? {};
        const st = vals.sessionStats ?? {};
        sessions.set(sid, {
          billed: (tu.uncachedInputTokens ?? 0) + (tu.outputTokens ?? 0),
          total: (tu.uncachedInputTokens ?? 0) + (tu.outputTokens ?? 0) + (tu.cacheReadTokens ?? 0) + (tu.cacheWriteTokens ?? 0),
          cache: (tu.cacheReadTokens ?? 0) + (tu.cacheWriteTokens ?? 0),
          cwd: norm(vals.workingDirectory),
          title: vals.title ?? null,
          rate: st.decodeMs > 0 ? (st.decodeTokens / st.decodeMs) * 1000 : 0,
          running: true
        });
      }
    } else if (v.type === 'projection' && v.key === 'tokenUsage') {
      const s = sessions.get(v.sessionId) ?? { billed: 0, total: 0, cache: 0, cwd: '', title: null, rate: 0 };
      s.billed = (v.value.uncachedInputTokens ?? 0) + (v.value.outputTokens ?? 0);
      s.cache = (v.value.cacheReadTokens ?? 0) + (v.value.cacheWriteTokens ?? 0);
      s.total = s.billed + s.cache;
      sessions.set(v.sessionId, s);
    } else if (v.type === 'projection' && v.key === 'sessionStats') {
      const s = sessions.get(v.sessionId); if (!s) return;
      const st = v.value ?? {};
      s.rate = st.decodeMs > 0 ? (st.decodeTokens / st.decodeMs) * 1000 : 0;
    }
  });

  listeners.push(v => {
    if (v.type === 'baseline' && v.value?.items) {
      for (const w of v.value.items) workspaces.set(w.workspaceId, { path: norm(w.path), title: w.title, sessions: w.sessionIds?.length ?? 0 });
    } else if (v.type === 'workspace') {
      const w = v.workspace ?? {}; workspaces.set(w.workspaceId, { path: norm(w.path), title: w.title, sessions: w.sessionIds?.length ?? 0 });
    }
  });

  listeners.push(v => {
    if (v.type === 'rows' && Array.isArray(v.jobs)) {
      for (const j of v.jobs) jobs.set(j.id, { id: j.id, kind: j.kind, owner: j.owner, status: j.status, label: (j.label ?? '').slice(0, 60) });
    }
  });

  openStream(ws, 'session/control');
  openStream(ws, 'workspace/follow');
  await new Promise(r => setTimeout(r, 2500));            // let the baselines arrive

  // jobs: open one stream per session that looks alive (has a title/activity)
  const watched = [...sessions.keys()].slice(0, 40);
  for (const sid of watched) openStream(ws, 'job/list', { sessionId: sid });
  await new Promise(r => setTimeout(r, 2000));

  return { ws, sessions, workspaces, jobs, stop: () => ws.close() };
}

/* ---------- 3. build the compact payload ---------- */
function build(c) {
  const cache = projcacheTotals();
  const sessions = new Map();
  for (const [id, v] of cache) sessions.set(id, { ...v, rate: 0, running: false });
  for (const [id, v] of live.sessions) sessions.set(id, { ...(sessions.get(id) ?? {}), ...v });

  const byWs = new Map();
  for (const [id, s] of sessions) {
    const k = s.cwd || '(未知)';
    const e = byWs.get(k) ?? { p: k, n: 0, r: 0, t: 0, b: 0, s: 0, j: 0 };
    e.n++; e.t += s.total ?? 0; e.b += s.billed ?? 0;
    if (s.running) e.r++;
    byWs.set(k, e);
  }
  for (const j of live.jobs.values()) {
    const s = sessions.get(j.owner); if (!s) continue;
    const e = byWs.get(s.cwd || '(未知)'); if (e) e.j++;
  }

  const liveIds = [...live.sessions.keys()];
  return {
    t: Date.now(),
    ws: [...byWs.values()].sort((a, b) => b.b - a.b),
    live: liveIds.map(id => {
      const s = live.sessions.get(id);
      return { id, w: s.cwd, b: s.billed, c: s.cache, r: Math.round(s.rate), n: (s.title ?? id).slice(0, 40) };
    }),
    jobs: [...live.jobs.values()].filter(j => j.status === 'running' || j.status === 'stopping')
              .map(j => ({ id: j.id, k: j.kind, o: j.owner, s: j.status, l: j.label })),
    tot: {
      sess: sessions.size, run: live.sessions.size,
      sub: [...sessions.values()].filter(s => s.cwd && s.title && /子|agent/i.test(s.title ?? '')).length,
      job: [...live.jobs.values()].filter(j => j.status === 'running' || j.status === 'stopping').length,
      billed: [...sessions.values()].reduce((t, s) => t + (s.billed ?? 0), 0),
      cache: [...sessions.values()].reduce((t, s) => t + (s.cache ?? 0), 0)
    }
  };
}

/* ---------- run ---------- */
const c = new DshClient();
let live = { sessions: new Map(), workspaces: new Map(), jobs: new Map() };
live = await collectLive(c);
console.error(`live streams: ${live.sessions.size} sessions, ${live.workspaces.size} workspaces, ${live.jobs.size} jobs`);

async function emit() {
  const payload = build(c);
  const raw = Buffer.byteLength(JSON.stringify(payload), 'utf8');
  const gz = gzipSync(Buffer.from(JSON.stringify(payload)), { level: 9 }).length;
  writeFileSync(OUT, JSON.stringify(payload));
  console.error(`[${new Date().toISOString()}] ${OUT}  raw=${raw}B gzip=${gz}B  sessions=${payload.tot.sess} live=${payload.tot.run} jobs=${payload.tot.job} billed=${payload.tot.billed}`);
  return { raw, gz };
}
const first = await emit();
if (WATCH) {
  setInterval(async () => { await emit(); }, EVERY * 1000);
} else {
  live.stop();
  console.log(JSON.stringify({ out: OUT, ...first }, null, 1));
}
