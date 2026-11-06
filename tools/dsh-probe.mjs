#!/usr/bin/env node
/**
 * DSH API 探针 —— 验证"桌面端代理"可以直接调用本机 DSH。
 *
 * 用法:
 *   node tools/dsh-probe.mjs               # 列出会话
 *   node tools/dsh-probe.mjs --prompt <sessionId> "要执行的指令"
 *
 * 原理(已实测验证):
 *   DSH 的 Web/API 服务只监听 127.0.0.1:10748, 且带 Host 围栏与 Cookie 认证。
 *   认证用的密钥在 %USERPROFILE%\.dsh\.credentials.yaml 的
 *   records["client-connection/browser-session"].payload.secret,
 *   用它可以签出一个 v1 的 owner Cookie。
 */
import { readFileSync } from 'node:fs';
import { createHash, createHmac } from 'node:crypto';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const DSH_URL = process.env.DSH_URL ?? 'http://127.0.0.1:10748';
const AUTHORITY = '127.0.0.1:10748';

function base64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** 从 .credentials.yaml 里取出 browser-session 的 secret(只做定向解析, 不引入 YAML 依赖)。 */
export function readBrowserSessionSecret(credentialsPath = join(homedir(), '.dsh', '.credentials.yaml')) {
  const text = readFileSync(credentialsPath, 'utf8');
  const lines = text.split(/\r?\n/);
  let inRecord = false;
  let inPayload = false;
  for (const line of lines) {
    if (/^\s*client-connection\/browser-session\s*:/.test(line)) {
      inRecord = true;
      continue;
    }
    if (inRecord) {
      if (/^\s{0,2}[\w"'-]+\s*:/.test(line) && !/browser-session/.test(line)) break;
      if (/^\s*payload\s*:/.test(line)) { inPayload = true; continue; }
      if (inPayload) {
        const m = line.match(/^\s*secret\s*:\s*['"]?([^'"\s]+)['"]?\s*$/);
        if (m) return m[1];
        if (/^\s{0,4}\w+\s*:/.test(line) && !/secret/.test(line)) break;
      }
    }
  }
  throw new Error(`未能从 ${credentialsPath} 解析出 client-connection/browser-session.secret`);
}

/** 签出 v1 owner Cookie */
export function mintCookie(secret, authority = AUTHORITY, ttlDays = 30) {
  const issuedAt = Date.now();
  const expiresAt = issuedAt + ttlDays * 86400_000;
  const payload = { version: 1, authority, issuedAt, expiresAt };
  const body = base64url(Buffer.from(JSON.stringify(payload), 'utf8'));
  const key = Buffer.from(secret, 'base64url');
  const sig = base64url(createHmac('sha256', key).update(body).digest());
  const name = 'dsh-auth-' + base64url(createHash('sha256').update(authority).digest());
  return `${name}=v1.${body}.${sig}`;
}

/** 调用一个 DSH RPC */
export async function rpc(method, args, cookie, key = 'request') {
  const res = await fetch(`${DSH_URL}/api/${method}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Host: AUTHORITY, Cookie: cookie },
    body: JSON.stringify({
      type: 'client-request',
      rpcId: `probe-${Date.now()}`,
      method,
      payload: { args: { [key]: args } }
    })
  });
  const json = await res.json();
  if (!json.result?.ok) {
    throw new Error(`${method} 失败: ${JSON.stringify(json.result?.error ?? json)}`);
  }
  return json.result.value;
}

async function main() {
  const secret = readBrowserSessionSecret();
  const cookie = mintCookie(secret);
  const args = process.argv.slice(2);

  if (args[0] === '--prompt' && args[1]) {
    const sessionId = args[1];
    const text = args[2] ?? 'hello from probe';
    const value = await rpc('session/prompt', {
      requestId: `probe-${Date.now()}`,
      sessionId,
      mode: 'queue',
      content: [{ type: 'text', text }],
      clientTimeZone: 'Asia/Shanghai'
    }, cookie);
    console.log('prompt accepted:', JSON.stringify(value));
    return;
  }

  const value = await rpc('session/list', {}, cookie, '_request');
  const list = value.items ?? [];
  console.log(`会话总数: ${list.length}`);
  for (const s of list.slice(0, 8)) {
    const title = s.projections?.values?.title ?? s.title ?? '(无标题)';
    console.log(`- ${s.sessionId}  ${s.running ? '[运行中]' : ''} ${title}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => {
    console.error('失败:', e.message);
    process.exit(1);
  });
}
