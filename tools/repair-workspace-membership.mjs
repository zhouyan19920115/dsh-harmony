// Repair the Workspace membership of the sessions that were created with a bare `cwd`.
//
// Why this exists
// ---------------
// The desktop only files a session under a Workspace when the session is **created** with a
// `workspaceId`. A session created with a bare `cwd` keeps the right working directory but
// stays in the desktop's "ungrouped" bucket — forever, because the desktop exposes no
// "move this session into that workspace" verb.
//
// The bridge used to create every phone session with a bare `cwd` (see `bridge/src/dsh.js`,
// `DshClient.createSession`), so a batch of sessions is stranded in "ungrouped" even though
// their working directory matches a Workspace exactly.
//
// What it does
// ------------
// For every Workspace, it looks at the sessions on disk whose canonical working directory is
// that Workspace's path, and adds the ones the Workspace does not account for yet.
//
// The registry is DSH's own durable file, so this MUST run with the desktop closed: while it
// is running, it holds the registry in memory and would overwrite the change.
//
//   node tools/repair-workspace-membership.mjs            # dry run: what would change
//   node tools/repair-workspace-membership.mjs --apply    # write it (desktop must be closed)

import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

import { listStoreSessions, readSessionLog } from '../bridge/src/store.js';
import { directoryKey, normalizeDirectory } from '../bridge/src/workspace.js';

const REGISTRY = path.join(os.homedir(), '.dsh', 'storages', 'workspace.json');
const APPLY = process.argv.includes('--apply');
const FORCE = process.argv.includes('--force');

/** The port the desktop answers on; a listener there means the registry is live. */
const DESKTOP_PORTS = [28425, 10748];

/** Does anything answer on that port? A half-open socket is not an answer. */
function portAnswers(port) {
  return new Promise((resolve) => {
    const socket = net.connect({ host: '127.0.0.1', port });
    const done = (value) => { socket.destroy(); resolve(value); };
    socket.setTimeout(800);
    socket.once('connect', () => done(true));
    socket.once('timeout', () => done(false));
    socket.once('error', () => done(false));
  });
}

function canonical(pathname) {
  try {
    return fs.realpathSync(pathname);
  } catch {
    return normalizeDirectory(pathname);
  }
}

async function main() {
  if (!fs.existsSync(REGISTRY)) {
    console.error(`the registry is not there: ${REGISTRY}`);
    process.exit(1);
  }
  const registry = JSON.parse(fs.readFileSync(REGISTRY, 'utf8'));
  const workspaces = registry?.tables?.workspaces ?? {};
  const ids = Object.keys(workspaces);
  if (ids.length === 0) {
    console.error('the registry holds no workspace');
    process.exit(1);
  }

  if (APPLY) {
    for (const port of DESKTOP_PORTS) {
      if (await portAnswers(port)) {
        console.error(`the desktop answers on 127.0.0.1:${port} — it holds the registry in memory and would`);
        console.error('overwrite the change. Close the desktop (and the bridge) first, then run this again.');
        if (!FORCE) process.exit(1);
        console.error('--force was given, so it goes on anyway.');
        break;
      }
    }
  }

  // Every session on disk with its working directory.
  // A subagent session (the header says `origin: "subagent"`) belongs to its parent, not to a
  // Workspace — the desktop never accounts them, so the repair must not either.
  const sessions = [];
  for (const session of listStoreSessions()) {
    const log = readSessionLog(session.logPath, { tailLines: 1 });
    const header = log?.header ?? null;
    if (header === null) continue;
    if (header.origin === 'subagent' || typeof header.parentSession === 'string') continue;
    const cwd = header.cwd;
    if (typeof cwd !== 'string' || cwd.trim().length === 0) continue;
    sessions.push({ id: session.id, cwd });
  }
  const byKey = new Map();
  for (const session of sessions) {
    const key = directoryKey(canonical(session.cwd));
    const list = byKey.get(key);
    if (list === undefined) byKey.set(key, [session.id]);
    else list.push(session.id);
  }

  const archived = new Set(registry?.global?.archivedSessionIds ?? []);
  const plan = [];
  for (const id of ids) {
    const record = workspaces[id];
    const key = directoryKey(canonical(record.path));
    const candidates = (byKey.get(key) ?? []).filter((sessionId) => !archived.has(sessionId));
    const missing = candidates.filter((sessionId) => !(record.sessionIds ?? []).includes(sessionId));
    plan.push({ id, record, missing });
  }

  const wanted = process.argv
    .filter((arg) => arg.startsWith('--workspace='))
    .map((arg) => arg.slice('--workspace='.length));
  const all = process.argv.includes('--all');

  console.log('\nworkspace                        accounted   to add');
  console.log('---------------------------------------------------------------');
  for (const entry of plan) {
    const mark = wanted.includes(entry.record.title) || all ? '*' : ' ';
    console.log(`${mark} ${(entry.record.title ?? '').padEnd(28)} ${String(entry.record.sessionIds?.length ?? 0).padStart(9)} ${String(entry.missing.length).padStart(8)}`);
  }
  const total = plan.reduce((sum, entry) => sum + entry.missing.length, 0);
  console.log(`\n${total} session(s) would move from "ungrouped" into their workspace.`);

  const chosen = plan.filter((entry) => wanted.includes(entry.record.title) || all);
  if (chosen.length === 0) {
    console.log('\nnothing selected. Add --workspace="<title>" (repeatable) or --all to choose what to repair.');
    return;
  }
  for (const entry of chosen) {
    console.log(`\n${entry.record.title}  (${entry.record.path})`);
    console.log(`  ${entry.record.sessionIds?.length ?? 0} session(s) accounted, ${entry.missing.length} would be added:`);
    for (const sessionId of entry.missing) console.log(`    + ${sessionId}`);
  }

  if (!APPLY) {
    console.log('\ndry run. Run it again with --apply to write it (the desktop has to be closed).');
    return;
  }

  for (const entry of chosen) {
    if (entry.missing.length === 0) continue;
    entry.record.sessionIds = [...entry.missing, ...(entry.record.sessionIds ?? [])];
    entry.record.updatedAt = new Date().toISOString();
  }

  const backup = `${REGISTRY}.bak-${Date.now()}`;
  fs.copyFileSync(REGISTRY, backup);
  fs.writeFileSync(REGISTRY, `${JSON.stringify(registry, null, 2)}\n`, 'utf8');
  const added = chosen.reduce((sum, entry) => sum + entry.missing.length, 0);
  console.log(`\n${added} session(s) added. The old registry is at ${backup}`);
  console.log('start the desktop again — it reads the registry when it boots.');
}

await main();
