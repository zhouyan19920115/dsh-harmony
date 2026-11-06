// DSH local client — talks to the ALREADY-RUNNING DeepSeek Harness web server.
// No background service of our own: this is a one-shot reader / a browser-side adapter.
//
// Auth: DSH's v1 owner cookie can be minted from the on-disk secret
//   ~/.dsh/.credentials.yaml  ->  records."client-connection/browser-session".payload.secret
// The launch token is NOT on disk (it lives in the host process), so we sign our own cookie.
//
// Wire: POST http://<authority>/api/<method>
//   { "type":"client-request", "rpcId":"r1", "method":"session/list",
//     "payload": { "args": { "_request": {} } } }
// Note the arg key: session/list uses `_request`; most others use `request`.
import { readFileSync } from 'node:fs';
import { createHmac, createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const B64URL = b => b.toString('base64').replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');

export function readSecret(dshHome = process.env.DSH_HOME || `${process.env.USERPROFILE}\\.dsh`) {
  const y = readFileSync(`${dshHome}\\.credentials.yaml`, 'utf8');
  const m = y.match(/client-connection\/browser-session:[\s\S]*?secret:\s*(\S+)/);
  if (!m) throw new Error('browser-session secret not found in .credentials.yaml');
  return m[1];
}

/** Mint a v1 owner cookie for the given authority ("host:port"). */
export function mintCookie(authority, secretB64Url) {
  const secret = Buffer.from(secretB64Url, 'base64');
  const name = 'dsh-auth-' + B64URL(createHash('sha256').update(authority).digest());
  const now = Date.now();
  const body = B64URL(Buffer.from(JSON.stringify({
    version: 1, authority, issuedAt: now, expiresAt: now + 30*24*3600*1000
  })));
  const sig = B64URL(createHmac('sha256', secret).update(body).digest());
  return `${name}=v1.${body}.${sig}`;
}

export class DshClient {
  constructor({ authority = '127.0.0.1:28425', dshHome } = {}) {
    this.authority = authority;
    this.base = `http://${authority}`;
    this.cookie = mintCookie(authority, readSecret(dshHome));
  }
  async call(method, args = {}, argKey = null) {
    const key = argKey ?? (method === 'session/list' ? '_request' : 'request');
    const body = {
      type: 'client-request',
      rpcId: `r-${Date.now()}-${Math.random().toString(16).slice(2,8)}`,
      method,
      payload: { args: { [key]: args } }
    };
    const res = await fetch(`${this.base}/api/${method}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Cookie': this.cookie },
      body: JSON.stringify(body)
    });
    const text = await res.text();
    let json; try { json = JSON.parse(text); } catch { json = { raw: text }; }
    if (!res.ok) throw new Error(`${method} → HTTP ${res.status}: ${text.slice(0,200)}`);
    const v = json?.result?.value;
    if (json?.result?.ok === false) throw new Error(`${method} → ${json.result.error?.message ?? 'rpc error'}`);
    return v ?? json?.result ?? json;
  }
}

/* ---------------- CLI: snapshot the live machine ---------------- */
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const c = new DshClient();
  const sessions = (await c.call('session/list', {}))?.items ?? [];
  let jobs = [];
  try { jobs = (await c.call('job/list', {}))?.items ?? (await c.call('job/list', {})) ?? []; }
  catch (e) { jobs = [{ error: String(e.message) }]; }

  const t = s => {
    const u = s?.projections?.tokenUsage ?? {};
    return (u.uncachedInputTokens ?? u.inputTokens ?? 0) + (u.outputTokens ?? 0)
         + (u.cacheReadTokens ?? 0) + (u.cacheWriteTokens ?? 0);
  };
  const running = sessions.filter(s => s.running);
  const subs    = sessions.filter(s => s.parentSessionId || s.origin === 'subagent');
  const byCwd = new Map();
  for (const s of sessions) {
    const k = s.cwd ?? '(unknown)';
    const e = byCwd.get(k) ?? { cwd:k, n:0, running:0, tokens:0 };
    e.n++; if (s.running) e.running++; e.tokens += t(s);
    byCwd.set(k, e);
  }
  const top = [...sessions].sort((a,b)=>t(b)-t(a)).slice(0,8)
    .map(s=>({ id:s.sessionId, title:s.title?.slice(0,40), cwd:s.cwd, running:s.running, tokens:t(s) }));

  console.log(`SESSIONS   : ${sessions.length}  (running ${running.length}, subagents ${subs.length})`);
  console.log(`JOBS       : ${Array.isArray(jobs)?jobs.length:JSON.stringify(jobs).slice(0,120)}`);
  console.log(`TOKENS(total across sessions): ${sessions.reduce((a,s)=>a+t(s),0).toLocaleString()}`);
  console.log('\nBY WORKSPACE:');
  for (const e of [...byCwd.values()].sort((a,b)=>b.tokens-a.tokens))
    console.log(`  ${String(e.running).padStart(2)}/${String(e.n).padEnd(3)} ${String(e.tokens).padStart(10)}  ${e.cwd}`);
  console.log('\nTOP TOKEN CONSUMERS:');
  for (const s of top) console.log(`  ${String(s.tokens).padStart(9)}  ${s.running?'RUN':'   '}  ${(s.title||s.id).slice(0,44)}  ${(s.cwd||'').slice(-32)}`);
  console.log('\nRAW SESSION SAMPLE:');
  console.log(JSON.stringify(sessions[0], null, 1).slice(0, 1600));
}
