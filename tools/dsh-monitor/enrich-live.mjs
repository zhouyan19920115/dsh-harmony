// Enriches a snapshot with LIVE state from the already-running DSH web server.
// No server of our own: one-shot RPC against 127.0.0.1:28425 using a minted v1 owner cookie.
//
// Adds per-session: running flag, title, live tokenUsage, decode rate (tokens/s from
// sessionStats.decodeTokens/decodeMs), subagent/team roster and the workspace list.
import { readFileSync, writeFileSync } from 'node:fs';
import { DshClient } from './dsh-client.mjs';

const SNAP = process.argv[2] || './snapshot.json';
const OUT  = process.argv[3] || './snapshot.json';

const c = new DshClient();
const snap = JSON.parse(readFileSync(SNAP, 'utf8'));
const byId = new Map(snap.sessions.map(s => [s.id, s]));

console.error('fetching session/list (this takes ~1-2 min: the host recomputes projections)…');
const roster = (await c.call('session/list', {}))?.items ?? [];
console.error(`  ${roster.length} sessions`);

let live = 0;
for (const it of roster) {
  const s = byId.get(it.sessionId);
  if (!s) continue;
  s.running = !!it.running;
  s.agentAvailable = !!it.agentAvailable;
  s.cwd = it.cwd ?? s.cwd;
  s.parentSessionId = it.parentSessionId ?? null;
  s.origin = it.origin ?? s.origin;
  const tu = it.projections?.values?.tokenUsage;
  if (tu) { s.liveTokens = tu; s.tokens.total = (tu.uncachedInputTokens ?? 0) + (tu.outputTokens ?? 0) + (tu.cacheReadTokens ?? 0) + (tu.cacheWriteTokens ?? 0); }
  if (it.running) live++;
}
console.error(`  running: ${live}`);

console.error('fetching projections for running sessions (decode rate, team, subagent)…');
for (const it of roster.filter(x => x.running)) {
  const s = byId.get(it.sessionId);
  if (!s) continue;
  try {
    const p = await c.call('session/projections', { sessionId: it.sessionId });
    const v = p?.values ?? p;
    if (!v) continue;
    s.title = v.title ?? s.title;
    if (v.tokenUsage) { s.liveTokens = v.tokenUsage; s.tokens.total = (v.tokenUsage.uncachedInputTokens ?? 0) + (v.tokenUsage.outputTokens ?? 0) + (v.tokenUsage.cacheReadTokens ?? 0) + (v.tokenUsage.cacheWriteTokens ?? 0); }
    s.stats = v.sessionStats ?? null;
    s.contextPressure = v.contextPressure ?? null;
    s.contextBreakdown = v.contextBreakdown ?? null;
    s.subagent = v.subagent ?? null;
    s.subagentCatalog = v.subagentCatalog ?? [];
    s.agentTeam = v.agentTeam ?? null;
    s.workingDirectory = v.workingDirectory ?? s.cwd;
    // decode rate: output tokens per second of model decode time
    const st = v.sessionStats;
    if (st && st.decodeMs > 0) s.decodeRate = (st.decodeTokens / st.decodeMs) * 1000;
    if (st && st.llmMs > 0) s.avgRate = (st.decodeTokens / st.llmMs) * 1000;
  } catch (e) { console.error(`  projections ${it.sessionId.slice(0,8)} failed: ${e.message}`); }
}

snap.live = { at: Date.now(), sessions: roster.length, running: live, authority: c.authority };
snap.totals.running = live;
snap.totals.subagents = snap.sessions.filter(s => s.origin === 'subagent').length;
writeFileSync(OUT, JSON.stringify(snap));
console.error(`\nupdated ${OUT}`);
console.error(JSON.stringify(snap.live));
