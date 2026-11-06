// Scans DSH's local session logs and emits a telemetry snapshot (JSON).
// No server, no polling daemon — a one-shot reader over ~/.dsh/sessions/**/session.v4.jsonl.zstd
//
// Per session it extracts: identity (id/cwd/parent/origin/depth), title, per-turn token usage
// (from assistant/message.usage), background jobs (job/registered + job/settled) and the
// subagent descriptor. It then aggregates by date and by workspace.
import { readdirSync, statSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { createZstdDecompress } from 'node:zlib';

const DSH_HOME = process.env.DSH_HOME || `${process.env.USERPROFILE}\\.dsh`;
const SESSIONS = join(DSH_HOME, 'sessions');
const OUT = process.argv[2] || join(process.env.USERPROFILE, 'DSHHarmony', 'tools', 'dsh-monitor', 'snapshot.json');
const DAY_LIMIT = Number(process.argv[3] || 30);   // only aggregate the last N days of turns
const since = Date.now() - DAY_LIMIT * 864e5;

/** DSH writes zstd as concatenated frames; walk them and yield the full text. */
async function decode(file) {
  const buf = readFileSync(file);
  const parts = []; let offset = 0;
  while (offset < buf.length) {
    const slice = buf.subarray(offset);
    let consumed = 0; const out = [];
    await new Promise((res, rej) => {
      const d = createZstdDecompress();
      d.on('data', c => out.push(c));
      d.on('end', () => { consumed = d.bytesWritten; res(); });
      d.on('error', rej);
      d.end(slice);
    });
    if (!consumed) break;
    parts.push(...out); offset += consumed;
  }
  return Buffer.concat(parts).toString('utf8');
}

function sessionDirs(root) {
  const out = [];
  for (const ws of readdirSync(root, { withFileTypes: true })) {
    if (!ws.isDirectory()) continue;
    const wsPath = join(root, ws.name);
    let subs = [];
    try { subs = readdirSync(wsPath, { withFileTypes: true }); } catch { continue; }
    for (const s of subs) {
      if (!s.isDirectory()) continue;
      const f = join(wsPath, s.name, 'session.v4.jsonl.zstd');
      if (existsSync(f)) out.push({ file: f, wsSlug: ws.name, id: s.name });
    }
  }
  return out;
}

const dayKey = ms => new Date(ms).toISOString().slice(0, 10);

(async () => {
  const dirs = sessionDirs(SESSIONS);
  console.error(`scanning ${dirs.length} session logs under ${SESSIONS} …`);

  const sessions = [];
  const daily = new Map();          // date -> {total, byWs:{}}
  const jobs = [];
  const wsTotals = new Map();
  let done = 0;

  for (const d of dirs) {
    let text;
    try { text = await decode(d.file); } catch (e) { continue; }
    const recs = [];
    for (const line of text.split('\n')) {
      if (!line) continue;
      try { recs.push(JSON.parse(line)); } catch {}
    }
    if (!recs.length) continue;

    const head = recs.find(r => r.type === 'session');
    const titleRec = recs.find(r => r.type === 'session/title');
    const subDesc  = recs.find(r => r.type === 'subagent/descriptor');
    const times = recs.map(r => r.time).filter(Number.isFinite);
    const createdAt = head?.createdAt ?? (times[0] ?? 0);
    const updatedAt = times.length ? Math.max(...times) : createdAt;

    let inTok = 0, outTok = 0, cacheRead = 0, cacheWrite = 0, turns = 0, lastUsageAt = 0;
    const jobMap = new Map();
    let running = false, lastStepStart = 0, lastStepEnd = 0;

    for (const r of recs) {
      if (r.type === 'assistant/message') {
        const u = r.data?.usage;
        if (u) {
          inTok += u.inputTokens ?? 0; outTok += u.outputTokens ?? 0;
          cacheRead += u.cacheReadTokens ?? 0; cacheWrite += u.cacheWriteTokens ?? 0;
          turns++;
          const ts = r.time ?? 0; if (ts > lastUsageAt) lastUsageAt = ts;
          if (ts >= since) {
            const k = dayKey(ts);
            const bucket = daily.get(k) ?? { total: 0, billed: 0, byWs: {} };
            const add = (u.inputTokens ?? 0) + (u.outputTokens ?? 0) + (u.cacheReadTokens ?? 0) + (u.cacheWriteTokens ?? 0);
            const bill = (u.inputTokens ?? 0) + (u.outputTokens ?? 0);
            bucket.total += add; bucket.billed += bill;
            bucket.byWs[d.wsSlug] = (bucket.byWs[d.wsSlug] ?? 0) + add;
            daily.set(k, bucket);
          }
        }
      } else if (r.type === 'job/registered') {
        const j = r.data ?? {};
        jobMap.set(j.jobId, { id: j.jobId, kind: j.kind, label: j.label, owner: j.owner, startedAt: j.startedAt, status: 'running' });
      } else if (r.type === 'job/settled') {
        const j = r.data ?? {};
        const prev = jobMap.get(j.jobId) ?? { id: j.jobId, kind: j.kind, label: j.label, owner: j.owner };
        jobMap.set(j.jobId, { ...prev, status: j.status, finishedAt: j.finishedAt, detail: j.detail });
      } else if (r.type === 'step/start') { lastStepStart = r.time ?? 0; }
      else if (r.type === 'step/end')   { lastStepEnd   = r.time ?? 0; }
    }
    // a session with a step/start newer than its last step/end is mid-turn
    running = lastStepStart > lastStepEnd;

    for (const j of jobMap.values()) {
      jobs.push({ ...j, wsSlug: d.wsSlug, sessionId: d.id, label: (j.label ?? '').slice(0, 200) });
    }

    const total = inTok + outTok + cacheRead + cacheWrite;
    const billed = inTok + outTok;
    const cwd = head?.cwd ?? d.wsSlug;
    const wsKey = cwd;
    const w = wsTotals.get(wsKey) ?? { cwd: wsKey, slug: d.wsSlug, sessions: 0, running: 0, tokens: 0, billed: 0 };
    w.sessions++; if (running) w.running++; w.tokens += total; w.billed += billed;
    wsTotals.set(wsKey, w);

    sessions.push({
      id: d.id,
      title: titleRec?.data?.title ?? null,
      cwd,
      wsSlug: d.wsSlug,
      createdAt, updatedAt,
      lastUsageAt,
      tokens: { input: inTok, output: outTok, cacheRead, cacheWrite, total, billed },
      turns,
      running,
      origin: head?.origin ?? 'root',
      parentSession: head?.parentSession ?? null,
      delegationDepth: head?.delegationDepth ?? 0,
      agentPreset: head?.agentPreset ?? null,
      subagentLabel: subDesc?.data?.label ?? null,
      subagentMode: subDesc?.data?.mode ?? null,
      subagentProvider: subDesc?.data?.provider ?? null,
    });
    if (++done % 50 === 0) console.error(`  ${done}/${dirs.length}`);
  }

  sessions.sort((a, b) => b.updatedAt - a.updatedAt);
  const dailyArr = [...daily.entries()].sort((a,b)=>a[0].localeCompare(b[0]))
    .map(([date, v]) => ({ date, total: v.total, billed: v.billed, byWs: v.byWs }));

  const snapshot = {
    generatedAt: Date.now(),
    source: 'local-session-logs',
    dshHome: DSH_HOME,
    sessions,
    workspaces: [...wsTotals.values()].sort((a, b) => b.tokens - a.tokens),
    jobs: jobs.sort((a, b) => (b.startedAt ?? 0) - (a.startedAt ?? 0)),
    daily: dailyArr,
    totals: {
      sessions: sessions.length,
      running: sessions.filter(s => s.running).length,
      subagents: sessions.filter(s => s.origin === 'subagent').length,
      jobs: jobs.length,
      jobsRunning: jobs.filter(j => j.status === 'running').length,
      tokens: sessions.reduce((t, s) => t + s.tokens.total, 0),
      billed: sessions.reduce((t, s) => t + s.tokens.billed, 0),
      cacheRead: sessions.reduce((t, s) => t + s.tokens.cacheRead, 0),
    },
  };
  writeFileSync(OUT, JSON.stringify(snapshot));
  console.error(`\nwrote ${OUT}`);
  console.error(JSON.stringify(snapshot.totals, null, 1));
  console.error('daily days:', dailyArr.length, '| workspaces:', snapshot.workspaces.length);
})();
