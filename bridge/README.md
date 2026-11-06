# DSH Harmony Bridge

The desktop half of the HarmonyOS phone client. It exposes the running **DeepSeek Harness (DSH)**
desktop agent on the local network as a small HTTP + WebSocket API, so a phone can list the
desktop's sessions, watch a turn stream live and — most importantly — make the desktop agent
actually execute an instruction.

The wire contract is [`../docs/PROTOCOL.md`](../docs/PROTOCOL.md); this document only explains how
to run the bridge and how it talks to DSH.

* **Zero runtime dependencies.** Only Node built-ins (`node:http`, `node:fs`, `node:path`,
  `node:zlib`, `node:crypto`, `node:os`, `node:net`). No npm packages.
* **Node 20+** (developed and verified on Node v26.7.0).

---

## 1. Run it

```bash
node bridge/src/cli.js                 # 0.0.0.0:8787, adapter "dsh"
node bridge/src/cli.js --port 8799     # a different port
node bridge/src/cli.js --adapter local # offline mode: the local store only
```

| Option | Default | Meaning |
|---|---|---|
| `--port <n>` | `8787` | TCP port |
| `--host <addr>` | `0.0.0.0` | bind address (`0.0.0.0` so a phone on the LAN can reach it) |
| `--state <file>` | `%USERPROFILE%\.dsh-harmony-bridge\bridge.json` | where the token is persisted |
| `--adapter <dsh\|local>` | `dsh` | `dsh` executes prompts in the desktop app, `local` only writes into the store |
| `--dsh-url <url>` | `http://127.0.0.1:10748` | base URL of the running DSH application |
| `--allow-unauth-pairing` | off | allow `GET /api/v1/pairing` from other hosts |

On startup the bridge prints the LAN URLs, the token, a copy-paste `curl` example and a terminal
QR code for the pairing payload.

### The token

The token is **32 random bytes in hex (64 characters)**. It is created on the first start and
stored in

```
%USERPROFILE%\.dsh-harmony-bridge\bridge.json
```

(the directory is created if needed). Later starts reuse the same token. `--state <file>` moves it
elsewhere.

Every request needs it:

```bash
curl -s -H "Authorization: Bearer <token>" http://127.0.0.1:8787/api/v1/health
```

The WebSocket accepts the same header, and `?token=<token>` as a fallback for clients that cannot
set headers.

### Firewall

The bridge listens on `0.0.0.0`, so Windows Firewall will ask. **Allow it on the "Private"
network** — otherwise the phone cannot reach `http://<lan-ip>:8787`. If the prompt does not appear:

```powershell
New-NetFirewallRule -DisplayName "DSH Harmony Bridge" -Direction Inbound -LocalPort 8787 -Protocol TCP -Action Allow -Profile Private
```

Use the port you actually started the bridge with. The DSH application itself
(`127.0.0.1:10748`) must **not** be exposed to the LAN: it is loopback-only by design and the
bridge is the only thing that talks to it.

### Pairing

```bash
curl -s http://127.0.0.1:8787/api/v1/pairing
# {"token":"…","url":"http://192.168.1.10:8787",
#  "qrPayload":"dsh-harmony://connect?host=192.168.1.10&port=8787&token=…"}
```

The endpoint is restricted to **localhost** (it hands out the token, so it cannot require the
token itself). `--allow-unauth-pairing` lifts that restriction. The QR code is rendered in the
terminal at startup and encodes `qrPayload` as a byte-mode QR code (error correction level M);
the encoder is implemented in [`src/qr.js`](src/qr.js) and was verified to be bit-identical to the
reference `qrcode` implementation for versions 1, 3, 7, 13 and 29.

---

## 2. How the bridge talks to DSH — the exact call path that works

DSH exposes a **Typert RPC** surface on `http://127.0.0.1:10748` (loopback only). This is what the
bridge uses; everything below was verified live against the running application.

### 2.1 Authentication — a minted owner cookie, not a bearer token

There is **no bearer token**. DSH expects a cookie that the client mints itself from an on-disk
secret:

| Step | Value |
|---|---|
| secret | `records["client-connection/browser-session"].payload.secret` in `%USERPROFILE%\.dsh\.credentials.yaml` (43-char base64url = 32 raw bytes) |
| cookie name | `"dsh-auth-" + base64url(sha256("127.0.0.1:10748"))` |
| cookie body | `base64url('{"version":1,"authority":"127.0.0.1:10748","issuedAt":<ms>,"expiresAt":<ms+30d>}')` |
| cookie value | `"v1." + body + "." + base64url(HMAC-SHA256(secretBytes, body))` |
| header | `Cookie: <name>=<value>` **and** `Host: 127.0.0.1:10748` |

The **Host header must stay `127.0.0.1:10748`** — DSH enforces a loopback fence and answers
`403` for any other authority. The bridge therefore uses `node:http` directly instead of `fetch`,
so the header can be set explicitly.

The **v2 cookie** (the API-operator flavour, with a peer id) does not work: it is only accepted for
a peer that was published through `/connect`, and this build registers no remote-access policy, so
every v2 call is denied. The **v1 owner cookie** is the one that works.

Implementation: [`src/dsh.js` → `readBrowserSessionSecret()` / `mintOwnerCookie()`].

### 2.2 The universal RPC route

```
POST /api/<namespace>/<method>
Content-Type: application/json
Host: 127.0.0.1:10748
Cookie: dsh-auth-…

{"type":"client-request","rpcId":"<uuid>","method":"session/list","payload":{"args":{…}}}
```

The response is `{"type":"server-response","rpcId":…,"result":{"ok":true,"value":{…}}}` or
`result.ok=false` with `result.error.{code,message,details}`.

> **The argument key is the trap.** It is `parameter.wire ?? parameter.name`, so
> `session/list` takes `args._request` while everything else takes `args.request`. The wrong key
> yields `gateway/arguments-invalid: args fields do not match the descriptor`.

Endpoints the bridge uses:

| Endpoint | Arg key | Purpose |
|---|---|---|
| `POST /api/session/list` | `_request` | live session rows (id, cwd, updatedAt, running, projections) |
| `POST /api/session/page` | `request` | history page (`{address,throughSeq,maxMessages}`) |
| `POST /api/session/prompt` | `request` | **submit a prompt — this is the write path** |
| `POST /api/session/cancel` | `request` | cancel the active turn |
| `POST /api/session/create` | `request` | create a session in a cwd |
| `POST /api/session/rename` | `request` | set the title |
| `POST /api/session/projections` | `request` | projections of one session |

`session/page` needs `throughSeq` ≤ the session cursor, which the bridge takes from the on-disk
log (the highest event sequence it knows).

### 2.3 Live streaming — the `remote.mux` WebSocket

Streaming is **WebSocket only** (there is no SSE endpoint for session data):

```
ws://127.0.0.1:10748/api/remote.mux      with Cookie + Host: 127.0.0.1:10748

→ {"type":"open","streamId":"<uuid>","endpoint":"session/follow",
   "payload":{"args":{"request":{"address":{"kind":"session","sessionId":"…"},
                                  "assistantStream":true,"maxMessages":200}}}}
← {"type":"item","streamId":"…","value":{"type":"snapshot", …}}
← {"type":"item","streamId":"…","value":{"type":"event","event":{"type":"user/message", …}}}
← {"type":"item","streamId":"…","value":{"type":"assistant-stream",
                                  "frame":{"type":"chunk","attemptId":"…","chunk":{"type":"text-delta","text":"…"}}}}
```

A **subagent** session must be addressed as
`{"kind":"subagent","parentSessionId":…,"childSessionId":…,"mode":…}`; addressing it as
`{"kind":"session"}` fails with `session/agent-busy`.

### 2.4 The on-disk session store (read path and fallback)

```
%USERPROFILE%\.dsh\sessions\<slug(cwd)>\<sessionId>\session.v4.jsonl.zstd
%USERPROFILE%\.dsh\storages\session_projcache\sessions\<sessionId>.json
```

The log is **zstd-compressed JSON Lines**, and DSH writes it as a sequence of independent zstd
frames. **Node's `zlib.zstdDecompressSync` only decodes the first frame** (both the sync and the
streaming API), so the bridge implements its own zstd frame walker
([`src/store.js` → `zstdFrameRanges()`]) that parses the frame header and the block headers from
RFC 8878 and inflates every frame separately. Without this the bridge would only ever see the
`session` header row.

The directory slug is `D:\APP\Deepseek\DSHHarmony` → `--D-APP-Deepseek-DSHHarmony--`
(spaces become `~0020`). Reversing a slug is lossy, so the bridge always prefers
`identity.cwd` from the metadata JSON.

### 2.5 What each bridge endpoint actually reads or writes

| Bridge endpoint | Source |
|---|---|
| `GET /api/v1/sessions` | DSH `session/list` (live) merged with the store index (createdAt, message count, title fallback) |
| `GET /api/v1/sessions/{id}/messages` | the on-disk log (canonical history, supports the `before` message id); falls back to DSH `session/page` |
| `POST /api/v1/sessions/{id}/messages` | **DSH `session/prompt`** — the desktop agent executes it |
| `POST /api/v1/sessions/{id}/cancel` | DSH `session/cancel` |
| `POST /api/v1/sessions` | DSH `session/create` (falls back to writing a store session in `local` mode) |
| `GET /api/v1/workspaces` | the distinct cwds of the store and of the application |
| WebSocket live frames | DSH `session/follow` over `remote.mux`; the store tailer (600 ms poll) is the fallback |

---

## 3. Desktop-UI parity endpoints

The phone mirrors the desktop UI, so the bridge also exposes the model picker, the queued task
boxes, the slash commands, the skills, the permission presets and the `@` file completion.

Every one of them goes through the same bearer-token middleware and answers the PROTOCOL error
envelope when the DSH application cannot be reached.

| Bridge endpoint | DSH call | Answer |
|---|---|---|
| `GET /api/v1/models` | `session/modelCatalog` (flat) | `{default, providers}` |
| `POST /api/v1/session/:id/model` | `session/selectModel` | `{selected}` |
| `GET /api/v1/session/:id/queue` | `session/projections` | `{nextTurn, nextStep}` |
| `POST /api/v1/session/:id/queue` | `session/updateQueue` | `{ok: true}` |
| `GET /api/v1/session/:id/commands` | `commands/list` (flat) | `{commands}` |
| `GET /api/v1/session/:id/skills` | `skills/list` | `{skills}` |
| `GET /api/v1/session/:id/files?query=` | `fileReferences/list` (flat) | `{files}` |
| `GET /api/v1/permissions` | `permissionPresets/catalog` (flat) | `{options, defaultPreset}` |
| `GET /api/v1/session/:id/state` | `session/projections` + the store metadata | `{model, permissions, running}` |

The session routes are registered under **both** spellings — `/api/v1/session/:id/…` and
`/api/v1/sessions/:id/…` — so the phone can use either one.

### The shapes

```jsonc
// GET /api/v1/models
{
  "default": { "provider": "minimax-code-local", "model": "MiniMax-M3.1-Flash" },
  "providers": [{
    "id": "minimax-code-local", "name": "MiniMax Code（本机登录）",
    "models": [{
      "id": "MiniMax-M3.1-Flash", "name": "MiniMax-M3.1-Flash",
      "efforts": [{ "id": "low", "name": "Low" }, { "id": "high", "name": "High" }],
      "defaultEffort": "high"
    }]
  }]
}

// POST /api/v1/session/:id/model      body {provider, model, reasoningEffort?}
{ "selected": { "provider": "minimax-code-local", "model": "MiniMax-M3.1-Flash" } }

// GET /api/v1/session/:id/queue       (the desktop's queued task boxes)
{ "nextTurn": [], "nextStep": [] }

// POST /api/v1/session/:id/queue      body {itemId, action}
//   action = {kind:"edit",content:[{type:"text",text}]} | {kind:"remove"} | {kind:"steer"}
{ "ok": true }

// GET /api/v1/session/:id/commands
{ "commands": [{ "name": "compact", "description": "Compact older conversation history", "hint": "" }] }

// GET /api/v1/session/:id/skills
{ "skills": [{ "name": "agent-browser", "description": "Browser automation CLI …", "path": "C:\\…\\SKILL.md" }] }

// GET /api/v1/session/:id/files?query=README
{ "files": [{ "path": "arch-showcase/README.md", "kind": "file" }] }

// GET /api/v1/permissions
{ "options": [{ "value": "workspace-write", "name": "workspace-write", "description": "" }],
  "defaultPreset": "workspace-write" }

// GET /api/v1/session/:id/state
{ "model": { "provider": "minimax-code-local", "model": "MiniMax-M3.1-Flash" },
  "permissions": { "preset": "danger-full-access", "sandbox": "danger-full-access", "approval": "never" },
  "running": true }
```

### Flat and wrapped arguments

The DSH gateway accepts two argument shapes. Most endpoints take a single `request` object
(`payload.args.request`), `session/list` takes `_request`, and four endpoints take **flat**
arguments — they are the fields of `payload.args` themselves:

| Endpoint | Shape |
|---|---|
| `session/modelCatalog` | flat `{}` |
| `commands/list` | flat `{agentId}` |
| `permissionPresets/catalog` | flat `{}` |
| `fileReferences/list` | flat `{agentId, query}` |

`DshClient.rpc()` handles this through the `ARG_KEYS` table: a `null` value marks a flat
endpoint. Sending the wrong shape is rejected by DSH with
`gateway/arguments-invalid: args fields do not match the descriptor`.

### Where the data comes from

* **model** — `session/projections` → `values.modelSelection.lastUsed` (falling back to `next`).
* **permissions** — the projection-cache metadata on disk
  (`~/.dsh/storages/session_projcache/sessions/<id>.json` → `record.rows.permissions.val`, which
  holds `{preset, sandbox, approval}`). The projections only carry the flattened
  `values.permissions.currentValue`, so the disk row is the better source.
* **running** — the live session list; `false` when the session is unknown.

---

## 4. Pending (待办) and push notifications

The phone shows a badge with the number of things the desktop is waiting for, and the desktop can
push a notification to the phone.

| Bridge endpoint | Answer |
|---|---|
| `GET /api/v1/pending` | `{"count": 17}` |
| `POST /api/v1/phone/push-token` | `{"ok": true, "deviceId": "dev-abc", "registered": 1}` |

### What counts as pending

`count` = the number of **running sessions** + the **queued tasks** + the **open questions**:

| Part | Where it comes from |
|---|---|
| running sessions | `session/list` → `running` |
| queued tasks | `session/list` → `projections.values.inbox["next-turn"]` + `["next-step"]` |
| open questions | `session/list` → `projections.values.userQuestions.active` |

The session rows of the DSH application already carry the inbox of every session, so the count
needs **no extra call** — it is computed from the rows the bridge already caches. When the DSH
application is unreachable the last known count is served instead of failing.

### The push token

```bash
curl -s -X POST -H "Authorization: Bearer <token>" -H "content-type: application/json" \
  -d '{"deviceId":"dev-abc","token":"<push token>"}' \
  http://127.0.0.1:8787/api/v1/phone/push-token
```

The token is stored in `push-tokens.local.json` **next to the bridge state** (by default
`%USERPROFILE%\.dsh-harmony-bridge\`, outside the repository; the repository ignores
`bridge/*.local.json` anyway). It is never logged and never leaves the machine.

### The push configuration

**No secret is hard coded.** The notifier reads its configuration from the environment first and
from a local, git-ignored `push.local.json` (next to the bridge state) second:

| Variable | File key | Meaning |
|---|---|---|
| `DSH_PUSH_APPID` | `appId` | the Huawei app id (the `client_id`) |
| `DSH_PUSH_SECRET` | `secret` | the client secret used to sign the JWT |
| `DSH_PUSH_TOKEN_URL` | `tokenUrl` | optional: an OAuth2 endpoint that exchanges the credentials for a bearer token |
| `DSH_PUSH_SEND_URL` | `sendUrl` | optional: overrides `https://push-api.cloud.huawei.com/v3/<appId>/messages:send` |

Without an app id (and a secret or a token url) the bridge **only logs** what it would have sent
and never touches the network. The startup banner says which state it is in:

```
[bridge] INFO  push           : configured (123456789)   phones: 1
[bridge] INFO  push           : not configured — notifications are only logged   phones: 0
```

### What is sent

```
POST <sendUrl>
Content-Type: application/json
Authorization: Bearer <JWT>
push-type: 0

{
  "payload": {
    "notification": {
      "category": "IM",
      "title": "桌面端有 17 项待办",
      "body": "15 个会话正在运行, 2 个任务排队中",
      "clickAction": { "actionType": 0 },
      "foregroundShow": true,
      "notifyId": 1792679903162
    }
  },
  "target": { "token": ["<the phone's push token>"] },
  "pushOptions": { "ttl": 86400 }
}
```

The bearer token is either a JWT the bridge signs itself (`HS256` over `{iat, exp, app_id}` with
the client secret) or the access token of `DSH_PUSH_TOKEN_URL`.

### When a notification is sent

A background watch (every 15 s, `DSH_PENDING_INTERVAL_MS`) compares the pending count with the
previous one and pushes a notification when it changes — that covers a finished turn, a queued
task that was picked up and a question that needs an answer. The watch only runs while a phone has
registered a token, and **every failure is caught and logged**: a broken push never disturbs the
bridge.

---

## 5. Live streaming, in detail

The bridge prefers the DSH `session/follow` stream and falls back to tailing the compressed log
(re-read + re-inflate whenever the file grew, diff against what was already sent, ~600 ms poll).

Mapping to the protocol:

| DSH event | Bridge frame |
|---|---|
| `turn/start` / `turn/end` | `session.state` (`running` / `idle`) |
| `user/message`, `system/message`, `developer/message` | `message.created` + `message.completed` |
| `tool/call` | `message.created` + `message.completed` (`kind: "tool_call"`) |
| `tool/result` | `message.created` + `message.completed` (`kind: "tool_result"`) |
| `assistant-stream` `chunk` | `message.delta` (only `text-delta`; the reasoning deltas stay in the desktop agent) |
| `assistant-stream` `start` / `end` | `message.created` (status `streaming`) / `message.completed` |

An in-flight assistant turn uses a **provisional message id** (`m-live-<attemptId>`) because its
durable sequence number is not known while it streams. When the durable `assistant/message` event
arrives it updates that same row with the canonical text instead of creating a second one — the
durable event and the end of the stream can arrive in either order, and both are handled. The
canonical ids (`m-<seq>`, the same ids the REST endpoint returns) come from the durable log.

---

## 5. Deviations from `docs/PROTOCOL.md`

The spec was implemented as written. The following points needed a judgement call; the spec was
**not** modified.

1. **`GET /api/v1/pairing` does not require the bearer token.** It *hands out* the token, so
   requiring the token would be circular. It is restricted to localhost instead, exactly as the
   spec describes ("Localhost-only unless the bridge was started with `--allow-unauth-pairing`").
2. **`POST /api/v1/sessions/{id}/messages` answers `{"accepted":true,"messageId":null}`.** The
   DSH prompt API acknowledges the request but does not return the id of the accepted message —
   the id only exists once the durable row is written. The id is therefore `null`; the phone
   learns it from the WebSocket or from `GET …/messages`.
3. **`session.state`** is taken from the live DSH flag (`running`) when the application is
   reachable. The spec's rule ("`running` for the session id in `$DSH_SESSION_ID` or the newest
   session") is applied on top of it, and is the only rule when the application is unreachable.
4. **`messageCount`** is not available from the DSH API, so it is counted from the on-disk log. The
   counts are computed in the background (the whole store is ~45 MB / ~120 sessions, roughly two
   seconds) and may still be `0` for a session that has not been counted yet.
5. **`GET /api/v1/sessions/{id}/messages?before=`** is exclusive and takes a **message id**
   (`m-<seq>`), as the spec says. The returned window is the *last* `limit` messages before it,
   which is what paging backwards needs.
6. **`mode`** — the protocol uses `"queue" | "interrupt"`, DSH uses `"queue" | "steer"`.
   `"interrupt"` is translated to `"steer"`.

---

## 6. Tests

```bash
node bridge/test/run.js              # or: cd bridge && npm test
node bridge/test/relay-client.test.js
```

No dependencies, `node:assert` only. The suite runs against the **real** DSH session store and the
**real** running DSH application; the endpoints that need the desktop application but must not
disturb it (the model catalog, the queue, the commands, the skills, the permissions) are covered
against a fake DSH that answers with the real wire shapes.

* the zstd frame walker covers a real log byte for byte, and the reader sees every row;
* the session listing returns well-formed `SessionSummary` objects, sorted by `updatedAt`;
* the messages endpoint returns well-formed `Message` objects and honours `before`;
* a missing or wrong token is rejected with the protocol error envelope;
* the WebSocket handshake works and `ping` is answered with `pong`;
* the QR encoder produces a matrix of the right size with intact finder and timing patterns;
* the model catalog is flattened into `providers[].models[].efforts`;
* the queue, the commands, the skills, the file references and the permissions are flattened into
  the phone's shapes, and the selection and the queue update are forwarded to the DSH;
* the flat argument endpoints really send their arguments unwrapped (asserted against a capture
  server);
* a prompt submitted while DSH is unreachable answers `503 dsh_unavailable` instead of pretending
  to succeed;
* the `local` adapter writes a prompt into the store and reads it back.
* a request body with a UTF-8 byte order mark is still parsed (some clients send one).

The relay client has its own suite:

```bash
node bridge/test/relay-client.test.js
```

---

## 7. Layout

```
bridge/
  package.json          zero dependencies, ESM
  README.md             this file
  src/
    cli.js              argument parsing, banner, QR code, startup
    config.js           state file, token, LAN address discovery
    server.js           HTTP routing, auth middleware, the phone WebSocket
    router.js           the bridge core and the route table
    store.js            DSH session store reader (zstd frames, metadata, tailing)
    session-stats.js    projection-cache metadata → the session status strip
    relay-client.js     the client of the phone relay
    dsh.js              DSH HTTP adapter (cookie auth, RPC, remote.mux client)
    protocol.js         protocol constants, error envelope, shape validators
    ws.js               minimal RFC 6455 server and client
    qr.js               QR encoder (byte mode, ECC M)
  test/
    run.js              the test suite
    relay-client.test.js  the relay client test suite
```
