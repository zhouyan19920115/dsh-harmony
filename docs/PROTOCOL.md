# DSH Harmony Bridge — Protocol v1

The desktop bridge (`bridge/`) exposes a small, stable HTTP + WebSocket API on the LAN.
The HarmonyOS phone app (`harmony/`) is the only client.

This document is the **single source of truth** for both sides. Change it here first.

---

## 1. Transport

| Aspect | Value |
|---|---|
| Base URL | `http://<desktop-lan-ip>:8787` (configurable via `--port`) |
| Content type | `application/json; charset=utf-8` |
| Auth | `Authorization: Bearer <token>` on every request; on the WebSocket either the same header or the **first frame** (see [§3](#3-websocket-protocol)) |
| WebSocket endpoint | `GET /ws` (also accepts `?token=<token>` for clients that cannot set headers) |
| Version prefix | `/api/v1` |

The token is generated on first bridge start and stored in
`%USERPROFILE%\.dsh-harmony-bridge\bridge.json` (or `--state <file>`).
The desktop prints the LAN URL + token on startup, and serves a QR code at
`GET /api/v1/pairing` (localhost-only unless `--allow-unauth-pairing`).

> **WebSocket 认证**: 手机端**不必**把令牌放进握手头或 query —— 令牌在 WS 握手里会进中继/代理的
> 访问日志。推荐做法: 握手不带令牌, 连上之后**第一帧**发 `{"type":"auth","token":"<token>"}`
> (见 [§3](#3-websocket-protocol))。老的 `Authorization` 头和 `?token=` 仍然接受, 方便过渡。

---

## 2. REST API

All responses are JSON. Errors use:

```json
{ "error": { "code": "bad_request", "message": "human readable" } }
```

### `GET /api/v1/health`
```json
{
  "ok": true,
  "name": "dsh-harmony-bridge",
  "version": "1.0.0",
  "dsh": { "webUrl": "http://127.0.0.1:10748", "reachable": true },
  "now": 1792600000000
}
```

### `GET /api/v1/sessions`
```json
{
  "sessions": [
    {
      "id": "session-9de904f1-...",
      "title": "Research task: ...",
      "cwd": "D:\\APP\\Deepseek\\DSHHarmony",
      "createdAt": 1792599607781,
      "updatedAt": 1792600000000,
      "state": "idle",              // idle | running | error
      "messageCount": 42,
      "model": { "provider": "minimax", "model": "MiniMax-M3.1-Flash" }
    }
  ]
}
```
Sorted by `updatedAt` descending.

### `GET /api/v1/sessions/{id}`
```json
{ "session": { ...SessionSummary, "messageCount": 42 } }
```
404 when unknown.

### `GET /api/v1/sessions/{id}/messages?limit=200&before=<msgId>`
```json
{
  "messages": [
    {
      "id": "m-17",
      "sessionId": "session-...",
      "role": "assistant",          // user | assistant | system | tool
      "kind": "text",               // text | tool_call | tool_result
      "text": "…",
      "createdAt": 1792599900000,
      "status": "done"              // streaming | done | error
    }
  ]
}
```
`before` is exclusive; used for paging backwards.

### `GET /api/v1/sessions/{id}/stats`

The status numbers of one session, read from the DSH session projection-cache metadata
(`%USERPROFILE%\.dsh\storages\session_projcache\sessions\<id>.json`). It is the data behind the
desktop status strip (turns, steps, tokens, context window, compaction counters).

```json
{
  "stats": {
    "sessionId": "session-9de904f1-...",
    "turns": 1,
    "steps": 465,
    "lastTurn": 1,
    "llmMs": 9022990,
    "toolMs": 11559250,
    "ttftMs": 4248969,
    "uncachedInputTokens": 1864613,
    "outputTokens": 347308,
    "cacheReadTokens": 101951903,
    "cacheWriteTokens": 0,
    "contextTokens": 96465,
    "contextWindow": 512000,
    "contextBreakdown": { "systemTokens": 1952, "toolsTokens": 21799, "messageTokens": 94513 },
    "permission": "danger-full-access",
    "permissionInfo": { "preset": "danger-full-access", "sandbox": "danger-full-access", "approval": "never" },
    "sandboxMode": "danger-full-access",
    "model": "MiniMax-M3.1-Flash",
    "modelInfo": { "provider": "minimax-code-local", "model": "MiniMax-M3.1-Flash" },
    "agentMode": "continuable",
    "agentLabel": "Chase mode coastal island map",
    "backgroundTasks": 0,
    "tokenOptimizer": {
      "savedTokens": 15437,
      "compressedResults": 11,
      "compactionCount": 0,
      "spilledResults": 1
    },
    "updatedAt": 1792570049975
  }
}
```

Rules:

- The endpoint always answers `200`. When the session has no readable metadata (missing file,
  unparsable JSON, unknown id) it answers `{"stats": null}` — never a `404` and never a `500`.
- Only fields that could actually be read are present. Every field above is optional: a session
  whose metadata predates a row simply has no such field. `sessionId`, `backgroundTasks` and
  `updatedAt` are always present.
- `permission` and `model` are plain strings, because the phone renders them directly
  (`permission` is compared against the sandbox mode names `danger-full-access` /
  `workspace-write`, `model` is shown as one line of text). The structured forms of the same
  data follow in `permissionInfo` and `modelInfo`.
- `contextTokens` / `contextWindow` are the current context occupancy and the size of the
  context window, `contextBreakdown` splits the occupancy into system, tool and message tokens.
- `backgroundTasks` is `1` when the session is a subagent whose turn has not completed yet
  (`subagentTiming.lastTurnCompleted === false`), otherwise `0`. The metadata of one session
  says nothing about the subagents it spawned — a parent session never counts its children.
- `tokenOptimizer` carries the counters of the desktop status strip: `savedTokens` (token
  savings), `compressedResults` (compression), `compactionCount` (compaction) and
  `spilledResults` (spill). `savedChars`, `originalChars`, `retainedChars` and `compactedTokens`
  are present when the metadata knows them.
- `updatedAt` is the moment DSH last rewrote the projection file (epoch milliseconds).

### `POST /api/v1/sessions`
Request:
```json
{
  "cwd": "D:\\work\\proj",
  "title": "optional",
  "agentPreset": "standard",
  "permission": "workspace-write"
}
```
- `cwd` — the working directory of the new session (the desktop's *workspace*).
- `agentPreset` — the **mode** the session runs in (`standard` | `ptc` | `minimal` | `cordis`,
  see `GET /api/v1/agent-presets`).
- `permission` — the permission preset the phone selected. The value is accepted and reported
  back; the DSH remote surface exposes the preset *catalog* but no "apply" call, so the preset
  is recorded by the bridge and forwarded to the desktop when a write path is available.

Response: `{ "session": { ...SessionSummary } }`

### `GET /api/v1/session-tree`
The desktop's sidebar tree: **conversations first, their topics and sub tasks right behind them**.
Response:
```json
{
  "conversations": [
    {
      "id": "session-…",
      "title": "鸿蒙手机端桌面代理开发",
      "cwd": "D:\\APP\\Deepseek\\DSHHarmony",
      "state": "idle",
      "updatedAt": 1792715985504,
      "topics": [
        { "id": "dbdfdc58-…", "title": "…", "state": "idle", "kind": "subtask", "cwd": "…" }
      ]
    }
  ]
}
```
A session that has a parent is a **topic** of that parent and is not repeated as a conversation.

### `GET /api/v1/agent-presets`
The **modes** a new conversation can run in (the desktop offers the same list).
Response:
```json
{ "presets": [ { "id": "standard", "name": "standard", "description": "", "isDefault": true } ] }
```

### `GET /api/v1/pending`
The number of things the desktop is waiting for — the badge of the phone.
Response: `{ "count": 20 }`
Count = running sessions + queued tasks + open questions.

### `POST /api/v1/phone/push-token`
The phone hands over its Huawei Push Kit token.
Request: `{ "deviceId": "dev-…", "token": "<push token>" }`
Response: `{ "ok": true, "deviceId": "dev-…", "registered": 1 }`

### `GET /_dsh/discover` (no token!)
"Is there a desktop agent on this machine?" — the phone asks every host of its network.
Response:
```json
{
  "name": "我的台式机",
  "version": "1.0.0",
  "server": "dsh-harmony-bridge",
  "url": "http://192.168.1.10:8787",
  "host": "192.168.1.10",
  "port": 8787,
  "code": "169751",
  "expiresAt": 1792685204020
}
```
Only harmless information plus a **short lived pairing code** (60 s). A machine without the bridge
does not answer this path at all — that is how the phone tells the desktops apart.

### `POST /api/v1/pair` (no token!)
Exchange the pairing code for the bridge token.
Request: `{ "code": "169751" }`
Response: `{ "ok": true, "token": "<bridge token>", "url": "http://192.168.1.10:8787", "name": "我的台式机" }`
A wrong or expired code → `400 bad_request`.

### `GET /api/v1/remote-config`
Everything the phone needs to switch from the LAN to the cloud relay.
Response: `{ "available": true, "relayUrl": "http://192.168.1.10:8788/acc-1a2b/dev-8f2a", "token": "…", "accountId": "acc-1a2b", "deviceId": "dev-8f2a" }`
Without a relay: `{ "available": false, "reason": "桌面端没有配置云中继" }`

### `GET /api/v1/relay/certificate`
The identity of the relay the phone is about to trust: **the fingerprint of the CA that signed
the relay's certificate**, plus the address the phone should connect to. The phone shows it once
and asks the user to confirm it, so a man-in-the-middle cannot silently take over the cloud hop.

Response:
```json
{
  "sha256": "9F2C…",         // SHA-256 of the CA certificate, uppercase hex
  "host": "192.168.1.10",
  "port": 8788,
  "selfSigned": false
}
```

Rules:

- Requires the token (401 without it).
- `sha256` is empty (`""`) when the bridge was started **without** `--relay-ca`: there is no CA to
  fingerprint, and the phone must not show a "confirmed" state for it. The packaged launcher always
  passes `--relay-ca`, so a desktop installed from the package has a real fingerprint.
- `selfSigned` is `true` when the certificate is self-signed (no CA in the chain) — the phone shows
  an extra warning in that case.
- `host` / `port` are the **relay** address (not the bridge address) when a relay is configured;
  without a relay they are the bridge's own address.

### `POST /api/v1/sessions/{id}/messages`
Request:
```json
{ "text": "run the tests and fix failures", "mode": "queue" }
```
`mode`: `"queue"` (default — append after current work) | `"interrupt"`.

Response:
```json
{ "accepted": true, "messageId": "m-18" }
```

### `POST /api/v1/sessions/{id}/cancel`
Response: `{ "ok": true }`

### `GET /api/v1/workspaces`
```json
{ "workspaces": [ { "cwd": "D:\\work\\proj", "label": "proj" } ] }
```

### `GET /api/v1/devices`
The devices of the account this bridge belongs to (the phone's 「设备」 page).

With `--relay` + `--account` + `--account-token` the bridge asks the relay for the presence of
the account's devices (`GET /_relay/accounts/<accountId>/devices`); without a relay only this
bridge is a device.

```json
{
  "devices": [
    { "id": "dev-8f2a", "name": "我的台式机", "role": "desktop", "online": true,  "lastSeen": 1792641291827 },
    { "id": "dev-p3h1", "name": "我的手机",   "role": "phone",   "online": false, "lastSeen": 0 }
  ]
}
```

`role` is `desktop` or `phone`. `lastSeen` is an epoch millisecond timestamp, `0` when the
device was never seen. See [`ACCOUNT.md`](ACCOUNT.md) for the account model.

### `GET /api/v1/pairing`
Localhost-only unless the bridge was started with `--allow-unauth-pairing`.
```json
{
  "token": "…",
  "url": "http://192.168.1.23:8787",
  "qrPayload": "dsh-harmony://connect?host=192.168.1.23&port=8787&token=…"
}
```

### `GET /api/v1/models`
The model catalog of the desktop (the phone's model picker).

```json
{
  "default": { "provider": "minimax-code-local", "model": "MiniMax-M3.1-Flash", "reasoningEffort": "high" },
  "providers": [
    {
      "id": "minimax-code-local",
      "name": "MiniMax Code（本机登录）",
      "models": [
        { "id": "MiniMax-M3.1-Flash", "name": "MiniMax-M3.1-Flash",
          "efforts": [ { "id": "off", "name": "Off" }, { "id": "high", "name": "High" } ],
          "defaultEffort": "high" }
      ]
    }
  ]
}
```

Backed by DSH `session/modelCatalog`.

### `POST /api/v1/sessions/{id}/model`
```json
{ "provider": "minimax-code-local", "model": "MiniMax-M3.1-Flash", "reasoningEffort": "high" }
```
→ `{ "selected": { "provider": "…", "model": "…", "reasoningEffort": "…" } }`

Backed by DSH `session/selectModel`.

### `GET /api/v1/sessions/{id}/queue`
The tasks that are queued while the desktop agent is busy (the desktop's
「队列中排队的对话任务框」).

```json
{
  "nextTurn": [ { "id": "…", "text": "把 README 翻译成英文", "target": "next-turn" } ],
  "nextStep": []
}
```

Backed by DSH `session/projections` → `values.inbox`. DSH keeps a queued item as a message
(`{ id, role, content: [{ type, text }] }`); the bridge flattens it to `{ id, text, target }`.

### `POST /api/v1/sessions/{id}/queue`
```json
{ "itemId": "…", "action": { "kind": "edit", "content": [ { "type": "text", "text": "新的内容" } ] } }
```
`action.kind` is `edit` (replace the text — `content` is required), `remove` (drop it) or
`steer` (let it interrupt the running turn right now). → `{ "ok": true }`

Backed by DSH `session/updateQueue`.

### `GET /api/v1/sessions/{id}/commands`
The slash commands of the session (the desktop's 「调用指令」).
```json
{ "commands": [ { "name": "compact", "description": "Compact older conversation history", "hint": "" } ] }
```

### `GET /api/v1/sessions/{id}/skills`
```json
{ "skills": [ { "name": "agent-browser", "description": "…", "path": "C:\\…\\SKILL.md" } ] }
```

### `GET /api/v1/sessions/{id}/files?query=<text>`
The `@` completion candidates of the session's working directory.
```json
{ "files": [ { "path": "src/main.ts", "kind": "file" }, { "path": "src", "kind": "directory" } ] }
```

### `GET /api/v1/permissions`
The permission presets the desktop offers. **Read only** — the preset is changed on the desktop.

```json
{ "options": [ { "value": "read-only", "name": "read-only", "description": "" } ], "defaultPreset": "workspace-write" }
```

### `GET /api/v1/sessions/{id}/state`
What the session is doing right now.
```json
{
  "model": { "provider": "…", "model": "…", "reasoningEffort": "…" },
  "permissions": { "preset": "workspace-write", "sandbox": "workspace-write", "approval": "never" },
  "running": false
}
```

### `GET /api/v1/sessions/{id}/prompt-preview?text=…`
**What is this prompt going to do?** The phone asks before it sends, so a prompt that changes the
machine can be confirmed one more time on the phone — the desktop stays the place where the work
happens, but the phone does not let an `npm install` slip through unnoticed.

Request: `GET /api/v1/sessions/{id}/prompt-preview?text=<url encoded prompt>`

Response:
```json
{
  "requiresConfirmation": true,
  "reason": "danger-full-access",
  "summary": "桌面端要执行 npm install",
  "actions": [
    { "kind": "command", "text": "npm install" },
    { "kind": "delete",  "path": "build" },
    { "kind": "write",   "path": "src/main.ts" },
    { "kind": "config",  "path": "package.json" }
  ]
}
```

Rules:

- Requires the token (401 without it).
- `actions[]` is empty and `requiresConfirmation` is `false` when the prompt contains nothing
  dangerous — a harmless prompt must **not** nag the user.
- `kind` is one of `command` (runs something that changes the machine), `delete`, `write` or
  `config` (a configuration file is touched). `text` carries the matched command, `path` the
  matched file.
- `requiresConfirmation` is `true` **only** for a session whose permission is
  `danger-full-access`. A `read-only` or `workspace-write` session is never stopped for a second
  look — the sandbox already limits the damage.
- When the permission of the session cannot be read, nothing is blocked: the bridge answers
  `requiresConfirmation: false` and the phone sends the prompt.
- `summary` is one plain sentence for the phone to show as it is, e.g.
  `桌面端要执行 npm install` or `桌面端要在 D:\work\proj 里删除 build 等 3 个危险动作: …`.
- The detector is a **text scan of the prompt**, not a look at the tool calls the agent will make.
  It is a second pair of eyes, not a guarantee — the desktop remains the authority.

---

## 3. WebSocket protocol

Endpoint: `ws://<host>:8787/ws`

### 首帧认证 (phone → bridge)

The handshake **may** carry no token at all. The phone authenticates with its **first frame**:

```json
{ "type": "auth", "token": "<bridge token>" }
```

Rules:

- The first frame of a connection **must** be `{"type":"auth","token":"…"}` when the handshake
  carries no token. Until that frame arrives the connection gets **nothing** — no `hello`, no
  `session.list`, no events. A connection that stays silent therefore never sees any data.
- A wrong token → the server answers `{"type":"error","data":{"code":"unauthorized","message":"…"}}`
  and then **closes the connection**.
- A right token → the server answers with `hello` and `session.list` as usual. The phone does not
  have to wait for anything: the `auth` frame is not acknowledged separately.
- The legacy ways still work: `Authorization: Bearer <token>` on the upgrade request, or
  `?token=<token>` in the query. A connection that authenticates that way skips the first frame
  entirely.

> **为什么**: 令牌放在握手的 query 里会进中继/代理的**访问日志** —— 谁读了日志谁就拿到了令牌。
> 首帧认证把令牌留在已经建立的连接里, 不经过任何日志。

### Envelope

Every frame is one JSON object:

```json
{ "type": "<type>", "data": { … } }
```

### Server → client

| type | data | when |
|---|---|---|
| `hello` | `{ server, version, token, dsh }` | immediately after connect |
| `session.list` | `{ sessions: SessionSummary[] }` | on connect + whenever the set changes |
| `session.state` | `{ sessionId, state, title }` | agent started/finished a turn |
| `message.created` | `{ sessionId, message: Message }` | a new message row appeared |
| `message.delta` | `{ sessionId, messageId, delta }` | streamed text chunk |
| `message.completed` | `{ sessionId, message: Message }` | message finished (status `done`/`error`) |
| `error` | `{ message, code? }` | protocol or upstream failure |

### Client → server

| type | data | meaning |
|---|---|---|
| `auth` | `{ token }` | **the first frame of a connection that did NOT authenticate in the handshake** — see [首帧认证](#首帧认证-phone--bridge) |
| `subscribe` | `{ sessionIds: ["…"] }` | 设置"这个客户端要看的会话集合", **整体替换**而不是累加; 空数组表示取消全部订阅。全局事件(`session.list`)始终推送。服务器只会为被订阅的会话开启流式推送。 |
| `prompt` | `{ sessionId, text, mode? }` | submit a user instruction for the desktop to execute |
| `cancel` | `{ sessionId }` | stop the current turn |
| `ping` | — | keep-alive; server answers with `pong` |

> **实现提示**: 不发 `subscribe` 时, 服务器不会为该会话建立流式推送,
> 手机端会话页会一直停在「执行中」而看不到桌面端的回复。
> 手机端在进入会话页时发 `subscribe {sessionIds:[id]}`, 离开时发 `subscribe {sessionIds:[]}`。

### 桥接 → 云中继 (the relay hop)

The phone never talks to the relay directly: the **bridge** is the device that connects to it and
forwards the frames. The relay handshake is authenticated with the `Sec-WebSocket-Protocol` header:

```
Sec-WebSocket-Protocol: dsh-device.<deviceToken>, dsh-account.<accountToken>, dsh-account-id.<accountId>
```

Rules:

- The **device token** travels in the handshake header, **not in the query**. The query only
  carries the identifiers: `?deviceId=<deviceId>&accountId=<accountId>`. A token in the query ends
  up in the relay's **access log** — whoever reads the log holds the token.
- The relay reads the token from the header, checks it, and **echoes the subprotocol it picked**
  in its `101` response.
- The old way (the token in the query) is still accepted, so an older bridge can still connect
  during the transition.
- The `hello` frame of the bridge → relay hop carries **no** token either; the handshake header
  is the only place the token travels.

| subprotocol | carries |
|---|---|
| `dsh-device.<token>` | the device token of this bridge |
| `dsh-account.<token>` | the account token (only when the bridge is bound to an account) |
| `dsh-account-id.<id>` | the account id (only when the bridge is bound to an account) |

---

## 4. Session / message model

```ts
interface SessionSummary {
  id: string
  title: string
  cwd: string
  createdAt: number     // epoch ms
  updatedAt: number     // epoch ms
  state: 'idle' | 'running' | 'error'
  messageCount: number
  model?: { provider: string, model: string }
}

interface Message {
  id: string
  sessionId: string
  role: 'user' | 'assistant' | 'system' | 'tool'
  kind: 'text' | 'tool_call' | 'tool_result'
  text: string
  createdAt: number
  status: 'streaming' | 'done' | 'error'
}
```

---

## 5. Desktop-side execution contract

The bridge is responsible for making a *desktop* agent actually execute the phone's
instruction. Two adapters are supported, selected with `--adapter`:

| adapter | read path | write path |
|---|---|---|
| `dsh` (default) | DSH HTTP API (`http://127.0.0.1:10748`) when reachable, otherwise the local session store under `%USERPROFILE%\.dsh\sessions` | DSH HTTP API; falls back to the DSH IM/channel bridge |
| `local` | local session store only | writes a prompt into the local store — used for tests/offline |

The session store lives at `%USERPROFILE%\.dsh\sessions\<slug(cwd)>\<sessionId>\session.v4.jsonl.zstd`
(compressed JSON lines) and metadata at
`%USERPROFILE%\.dsh\storages\session_projcache\sessions\<sessionId>.json`.

The bridge tails the compressed session log so that new turns are streamed to the
phone in real time (the log is re-read and decompressed whenever it grows).

> **注意: 会话日志是 zstd 压缩的** —— `session.v4.jsonl.zstd` 里的每一行都是压缩过的 JSON。
> 统计消息条数(`messageCount`)、取首条用户消息、取标题都必须**先解压**再读; 直接按明文读会
> 得到空结果(这正是「对话里没有消息」的原因)。解压很贵, 所以这一步在 worker 线程里做(见
> [§7](#7-实现注记)), 主线程只收结果。

---

## 6. DSH 侧的参数形状约定

The bridge talks to the desktop over the DSH RPC surface. The **shape of the arguments** is not
uniform, and getting it wrong is silent — a wrong shape does not throw, it answers with an empty
result. These are the shapes that work:

| DSH call | `args` |
|---|---|
| `session/list` | `{ "_request": {} }` — the request **must** be wrapped in `_request` |
| `session/modelCatalog` | flat — the arguments go straight into `args` |
| `agentPresets/list` | flat |
| `permissionPresets/catalog` | flat |
| `session/page` | `{ "request": { "address": { "kind": "session", "sessionId": "…" }, "throughSeq": 12, "maxMessages": 200 } }` |

Rules:

- ⚠️ **`session/page`: `throughSeq` must not be beyond the cursor.** A `throughSeq` past the end
  of the session is answered with `past cursor` — the bridge then falls back to the newest page.
  `maxMessages` is optional.
- ⚠️ **`session/projections` fails on the current DSH** with `build context fail`. The bridge is
  **tolerant** about it: when the call fails, it uses the `projections` that came with the
  `session/list` row instead. A failing DSH endpoint must never be passed on to the phone as an
  error — the phone would lose the session list, the badge and the whole tree because of one
  broken call.
- The DSH **RPC calls stay on the main thread** (they are I/O and the DSH client lives there).
  Only the *file scanning* moved into a worker thread (see §7).

---

## 7. 实现注记

Implementation notes that are not part of the wire protocol, but that everybody who touches the
bridge has to know.

### 扫描在 worker 线程里

The session store scan (read every session directory, decompress the logs, count the messages)
is the most expensive thing the bridge does. It runs in a **worker thread**
(`bridge/src/scan-worker.js`):

- The worker only does **"read the files + compute"**; the main thread only **"use the result"**.
  The results (the counts, the session summaries) come back as one `postMessage`.
- The DSH RPC calls stay on the main thread — they must not be moved into the worker.
- **Only one scan runs at a time** inside the worker. A scan request that arrives while a scan is
  running only sets a flag; it does **not** start a second scan. Two parallel scans double the
  CPU use and starve the bridge's own event loop — the symptom is a discovery probe that suddenly
  takes seconds instead of milliseconds.
- The worker file is shipped **next to the executable** (the folder `worker\`), because the
  packaged exe holds bytecode only and cannot load a worker from inside itself. The bridge looks
  for `<exe folder>\worker\scan-worker.js` first; if there is no worker file at all, it falls back
  to a chunked scan on the main thread.

Consequence: `GET /_dsh/discover` answers in **milliseconds** — even while the store is being
scanned, and even on a machine with thousands of sessions.

---

## 8. The registration endpoint of the relay (desktop bridge → public relay)

The relay is the **trust boundary**: it issues the credentials, the bridge only proves that it
is the same machine as the last time. This is the interface the bridge client uses
(`bridge/src/config.js`, `registerWithRelay`) — and the interface the relay server has to
implement (`relay/src/server.js`).

### 8.1 The request

```http
POST /_relay/accounts/register
Content-Type: application/json
```

```json
{
  "deviceName": "my desktop",
  "deviceId": "dev-1a2b3c4d",
  "accountId": "acc-5e6f7a8b",
  "secret": "<64 hex characters>",
  "platform": "windows",
  "version": "1.0.0"
}
```

| field | type | meaning |
|---|---|---|
| `deviceName` | string | the friendly name of the computer, shown in the phone's device list |
| `deviceId` | string | **generated by the client**, `dev-` + 8 hex characters; the client retries with a new one on a conflict |
| `accountId` | string | **generated by the client**, `acc-` + 8 hex characters; the relay may return a different one |
| `secret` | string | **generated by the client**, 32 random bytes as hex; the relay stores its hash, never the value |
| `platform` | string | `windows` / `linux` / `darwin` |
| `version` | string | the version of the bridge |

**Authentication: none.** The first registration is anonymous — that is the point, the user has
no credential yet. The relay is expected to:

- rate limit the endpoint **per address** (429 when there are too many attempts);
- be able to **switch self registration off** (503, see 8.3) — an operator who does not want
  strangers on their relay can close the door and hand out the credentials by hand instead.

### 8.2 The answer

```http
HTTP/1.1 201 Created
Content-Type: application/json
```

```json
{
  "accountId": "acc-5e6f7a8b",
  "accountToken": "<64 hex characters>",
  "deviceId": "dev-1a2b3c4d",
  "deviceToken": "<64 hex characters>",
  "publicUrl": "https://relay.example.com",
  "registeredAt": 1790000000000
}
```

| field | meaning |
|---|---|
| `accountToken` | the secret of the account; the bridge presents it in the device handshake |
| `deviceToken` | the secret of the device; the bridge presents it in the device handshake |
| `publicUrl` | the base url the **phone** has to use; optional, the bridge falls back to its own `--relay-public-url` |
| `registeredAt` | the unix time in milliseconds, optional |

The relay keeps the **hash** of `secret` and compares it with the hash of the secret of a
registration for the same `deviceId`: the same machine gets the same credentials back, a
different machine with the same id gets a conflict.

### 8.3 The errors

| status | `error.code` | when |
|---|---|---|
| 400 | `bad_request` | a field is missing or has the wrong shape |
| 409 | `device_conflict` | the `deviceId` is known, but the secret does not match — the client generates a new id and retries once |
| 429 | `rate_limited` | too many registrations from this address |
| 503 | `registration_closed` | the operator does not accept new registrations |
| 404 | `unknown_route` | the relay is too old for this endpoint — the client says so and stops |

The error body is the same shape everywhere in the relay:

```json
{ "error": { "code": "rate_limited", "message": "too many registrations from this address" } }
```

### 8.4 What the client does with it

The client (`bridge/src/cli.js`, `resolveRelayCredentials`) picks its credentials in this order:

1. `--device-id` + `--device-token` on the command line — a hand made setup;
2. the credentials the relay issued during an earlier run, stored in
   `%USERPROFILE%\.dsh-harmony-bridge\bridge.json`;
3. **a fresh registration** — the first run of a bridge that points at a relay.

A registration that fails is **never silent**: the bridge prints the reason and stops with
exit code 1, because a bridge that did not register cannot be reached by a phone. The
credentials are written to the state file of the machine and are never put into a config file
(`bridge/src/config.js`, `FORBIDDEN_CONFIG_KEYS`).

