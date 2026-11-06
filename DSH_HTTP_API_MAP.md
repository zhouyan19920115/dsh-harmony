# DSH HTTP/WebSocket API Map (machine-verified)

Source of truth: `D:\APP\Deepseek\resources\app.asar` (packed Electron archive), package
`@deepseek-ai/dsh-desktop-runtime` v`0.2.1-rc.2`, build commit `332895e0f7c9d4dbfb29729f5eb367fa263ff986`.

Method: the asar was extracted read-only to `D:\APP\Deepseek\DSHHarmony\_tmp\asar`
(3863 files, 82 MB) with a custom Node reader (`_tmp\extract-asar.js`, no `asar` npm needed);
`grep`/`read` were then run against that tree. **Every endpoint, path string and field name below
was located in source. Live behaviour was additionally verified against the running instance
(`127.0.0.1:10748`, PID 105712 = `DeepSeek Harness.exe`).**

No DSH file was modified. Only scratch files under `D:\APP\Deepseek\DSHHarmony\_tmp\` were created
(plus `_tmp_asar_header.json` in the workspace root).

---

## 1. HTTP server implementation

| Package | Role |
|---|---|
| `@deepseek-ai/dsh-host-webserver` | Generic `node:http`/`node:https` listener. Service key `webServer`. Route kinds: `exact`, `prefix`, `fallback`, `upgrade`. Knows no harness concepts. |
| `@deepseek-ai/dsh-client-connection` | Owns auth + mounts the `/api` prefix route and the `/connect` exact route. Service key `connection`. |
| `@deepseek-ai/dsh-api-gateway` | Mounts the `/api/remote.mux` WebSocket upgrade and *intercepts* the `/api` channel to dispatch Typert endpoints (`ctx.connection.rpc.intercept("/api", …)`). |
| `@deepseek-ai/dsh-host-frontend-static` | The single fallback seat: serves the SPA dist; `/` and the configured index are gated by `ctx.connection.authorizeIndex`. |
| `@deepseek-ai/dsh-api-session-controller` | Registers the `session/*` Typert endpoints + the `/api/file` route. |
| `@deepseek-ai/dsh-api-remote-access` | Method-level access control for non-owner Peers (`ctx.remoteAccess`). |
| `@deepseek-ai/dsh-web-app` | Prints/opens the tokenised URL; provides `ctx.webApp`. |

**There is no OpenAPI/Swagger file and no static route table.** The authoritative schema lives in
generated per-package files `lib/typert.host.js` (Host face) and `lib/typert.remote-client.js`
(Client face) as inline JSON Schema per parameter/result, e.g.

```
dsh/node_modules/@deepseek-ai/dsh-api-session-controller/lib/typert.host.js
  'session/prompt': { service:'sessionController', parameters:[{name:'request', codec:{jsonSchema:{…}}}],
                       result:{jsonSchema:{…}}, sourceLocation:{"file":"packages/api/session-controller/src/index.ts","line":462} }
```

Extracted catalog of **130 Typert endpoints** (full dump: `_tmp\endpoints.json`,
printer: `_tmp\dump-endpoints.js`). Namespaces: `session`, `account`, `job`, `workspace`,
`workspaceFiles`, `terminal`, `settings`, `credentials`, `commands`, `goals`, `schedule`,
`subagents`, `userQuestions`, `fileUploads`, `fileReferences`, `skills`, `llm`, `pluginManager`,
`pluginMarket`, `agentPresets`, `dynamicCordisRunner`, `speech`, `cotTranslation`, `messageFeedback`,
`sessionFeedback`, `officeToPdf`, `permissionPresets`, `pluginInventory`, `productAnalytics`,
`remoteAccess`, `sessionReferenceResolver`, `productAnalytics`.

### 1.1 The universal RPC route

Registered by `dsh-client-connection/lib/index.js:1044-1058`:

```js
const API_PATH = "/api";                      // lib/types/api-path.js:14
route = { kind: "prefix", path: API_PATH, handler: async (req,res) => { … bridge(req,res,fetchHandler,admission.peer) } }
```

* **Method**: `POST` only. `GET`/`PUT`/… → `404 not found`.
* **Path**: `POST /api/<namespace>/<method>` — the URL suffix **must equal** the envelope `method`
  field, else `gateway/bad-request`.
* **Request `Content-Type`**: must be `application/json`, else `415`.
* **Body**: the `client-request` envelope (`dsh-client-connection/lib/index.js:631`):

```jsonc
{
  "type": "client-request",   // literal
  "rpcId": "<string>",        // correlation id, echoed back
  "method": "session/list",   // must equal the path suffix
  "payload": { "args": { … } } // EXACTLY one plain-object "args" field (api-gateway remoteRequest, lib/index.js:1460-1472)
}
```

* **Response**: the `server-response` envelope (`lib/index.js:638`):

```jsonc
{ "type": "server-response", "rpcId": "<same>", "result": { "ok": true, "value": { … } } }
{ "type": "server-response", "rpcId": "<same>", "result": { "ok": false,
    "error": { "code": "gateway/…", "message": "…", "details": { … } } } }
```

  `error.code` values seen in source: `gateway/bad-request`, `gateway/arguments-invalid`,
  `gateway/signature-invalid`, `gateway/service-unavailable`, `gateway/internal`,
  `remote-access/denied`, `session/migration-required`, `session/invalid-time-zone`,
  `session/agent-busy`, `session/attachment-invalid`.

* **Argument naming**: the *wire* key of each argument is `parameter.wire ?? parameter.name`
  (`dsh-typert-protocol/lib/types/remote-info.js:34`). So `session/list` takes the key `_request`,
  most others take the key `request`. This trips clients up — see the curl example below.
* **Attachments**: when a result carries attachments the response is `multipart/form-data` with a
  `metadata` part holding the same JSON plus `attachments:[{path,codec,part}]` (`lib/index.js:938-968`).

### 1.2 All HTTP routes (complete)

| Method | Path | Auth | Request | Response |
|---|---|---|---|---|
| GET | `/` | launch token in `?token=` **or** valid cookie | — | `303` → `./` + `Set-Cookie`, else `401` |
| GET | `/<index>` (SPA) | same | — | HTML, else `401` |
| GET/HEAD | `/<static asset>` | **none (public)** | — | file bytes |
| GET | `/connect` | launch token in `?token=` | `?interactions=none\|answer` (once) | `302` → `./api/remote.mux` + `Set-Cookie` (v2) |
| GET/HEAD | `/api/file` | cookie (owner peer) | query params | bytes (media references) |
| GET/HEAD | `/api/session.export` | cookie | query params | ZIP stream of a session log |
| POST | `/api/session/uploadFileBinary` | cookie | raw bytes (streaming body) | upload receipt |
| GET | `/api/experimental-inspector/bootstrap` | cookie | — | inspector bootstrap JSON |
| POST | `/api/<ns>/<method>` | cookie | `client-request` envelope | `server-response` envelope |
| GET (upgrade) | `/api/remote.mux` | cookie (via WS `Cookie` header) | — | WebSocket |
| GET | `/oauth/callback` | — | OAuth callback | account token |
| GET (prefix) | `/plugins` | — | — | client bundle JS |
| GET | HMR SSE route | — | — | dev-only `text/event-stream` (`dsh-client-hmr`) |

Route-path constants (exact source strings):
`/api` (`dsh-client-connection/lib/types/api-path.js:14`), `/connect`
(`lib/types/connect-protocol.js:19`), `/api/remote.mux`
(`dsh-api-gateway/lib/types/stream-protocol.js:4`), `/api/file`
(`dsh-api-session-controller/lib/index.js:2483`), `/api/session.export`
(`dsh-session-log-export/lib/index.js:488`), `/api/session/uploadFileBinary`
(`dsh-client-file-upload/lib/index.js:72`), `/api/experimental-inspector/bootstrap`
(`dsh-experimental-inspector/lib/index.js:2329`), `/plugins`
(`dsh-client-modules/lib/index.js:202`).

### 1.3 The session endpoints (the ones a phone needs)

Service `sessionController`, namespace `session`, from
`dsh/node_modules/@deepseek-ai/dsh-api-session-controller/lib/typert.host.js`.

| Endpoint (⇒ `POST /api/<ep>`) | mode | Request arg key | Request shape | Result shape |
|---|---|---|---|---|
| `session/list` | unary | `_request` | `{}` or `{cursor?:string}` | `{items: SessionSummary[]}` |
| `session/search` | unary | `request` | `{query:string}` | `{items:[{sessionId,snippet}],hasMore:boolean}` |
| `session/create` | unary | `request` | `{workspaceId?,cwd?,sessionId?,agentPreset?}` | `{sessionId,agentPreset?}` |
| `session/page` | unary | `request` | `{address,throughSeq,beforeSeq?,maxMessages?,turnWindow?}` | `{records:SessionHistoryRecord[],hasMore:boolean}` |
| **`session/prompt`** | unary | `request` | `{requestId,sessionId,mode:'queue'\|'steer',content:PromptContentPart[],clientTimeZone?}` | `{accepted:true}` |
| `session/follow` | **stream** | `request` | `{address,maxMessages?,turnWindow?,assistantStream?:true}` | `SessionFollowFrame` (stream) |
| `session/control` | **stream** | — | `{}` | `SessionControlFrame` (stream) |
| `session/cancel` | unary | `request` | `{sessionId}` | `{accepted:true}` |
| `session/updateQueue` | unary | `request` | queue mutation | ack |
| `session/rename` | unary | `request` | `{sessionId,title}` | ack |
| `session/fork` | unary | `request` | source session + boundary | new session id |
| `session/projections` | unary | `request` | `{sessionId}` | baseline or `null` |
| `session/attachment` | unary | `request` | `{sessionId,attachmentId}` | attachment bytes |
| `session/modelCatalog` | unary | — | — | model catalog |
| `session/initializeDefaultModel` | unary | — | — | `void` |
| `session/canOpenWorkspacePath` | unary | — | — | boolean |
| `session/openWorkspacePath` | unary | `request` | path | result |
| `session/workspacePathApplications` | unary | `request` | `{path}` | app list |
| `session/selectModel` | unary | `request` | model selection | result |
| `skills/list` | unary | `request` | — | skill list |
| `fileReferences/list` | unary | `agentId`,`query` | — | file candidates |

---

## 2. Authentication

Source: `dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js`.

### 2.1 Mechanism

There is **no bearer token and no `Authorization` header**. The README of that package states it
verbatim (lib/README.md, "Over the Web carrier …"):

> "The HTTP carrier accepts query tokens only at the root exchange and `/connect`, and accepts no
> Authorization-header token."

Two credentials exist:

**(a) Launch token — process-scoped, in memory only**
* `TOKEN_QUERY = "token"` (line 276).
* Value = `encodeBase64Url(randomBytes(32))` → 43-char base64url (line 294-299).
* Stored in a `WeakMap` keyed by the root Cordis context → **not on disk**, regenerated every
  process start.
* Accepted **only** on `GET /` and `GET /connect` (lines 464, 519). Both require exactly one
  `token` query param and a timing-safe compare.
* `GET /?token=…` → `303` to `./` + `Set-Cookie`.
* `GET /connect?token=…` → `302` to `./api/remote.mux` + `Set-Cookie` (v2, API-operator peer).
* In the desktop build the URL is minted by `dsh-desktop-host/lib/index.js:342`
  (`ctx.connection.authenticatedUrl(...)`) and shipped to the Electron main process over IPC
  (`{type:"ready", url}`), which opens the browser with it.

**(b) Browser-session cookie — persistent, owner-level**
* `COOKIE_PREFIX = "dsh-auth-"` (line 277).
* Cookie **name** = `dsh-auth-` + `base64url(sha256(authority))`, where
  `authority` = the request `Host` header value for an HTTP listener (e.g. `127.0.0.1:10748`).
* Cookie **value** = `v<version>.<base64url(payloadJSON)>.<base64url(HMAC-SHA256(secret, body))>`
  where `body` is the base64url payload string.
* Payload v1 (browser/owner): `{"version":1,"authority":"127.0.0.1:10748","issuedAt":<ms>,"expiresAt":<ms>}`.
* Payload v2 (API operator): adds `"id": "<peer uuid>"`.
* Cookie attributes: `Max-Age=<s>, Path=/, Expires=…, HttpOnly, SameSite=Strict`
  (`; Secure` only when the *listener* is TLS) — line 347-350.
* Default lifetime `cookieMaxAgeDays: 30` (Config, line 1017).
* `secret` = 32 random bytes, base64url, used as the HMAC-SHA256 key.

### 2.2 Where the credential lives on disk

* **DSH home** = `$DSH_HOME` else `~/.dsh` → on this machine **`C:\Users\YourName\.dsh`**
  (`@deepseek-ai/dsh-home-paths` → `resolveDshHome`).
* **Credential file**: `C:\Users\YourName\.dsh\.credentials.yaml`
  (from `dsh-credentials-local/lib/index.js:58`:
  `filename: resolve(config.path ?? join(resolveDshHome(config.dshHome), ".credentials.yaml"))`).
* **Record key** (exact YAML path, `credentialKey("client-connection","browser-session")` →
  `client-connection/browser-session`):

```yaml
records:
  client-connection/browser-session:
    kind: grant
    payload:
      version: 1
      secret: <43-char base64url>   # 32 random bytes — the cookie HMAC signing key
```

  The same file also holds unrelated secrets (`deepseek-account-platform/*`, `refs:` API keys) —
  the phone client must read **only** the `client-connection/browser-session` → `payload.secret` value.
* The **launch token is NOT on disk** — it exists only in the DSH host process's memory and in the
  Electron main process. No `token=` string was found in
  `C:\Users\YourName\AppData\Local\Temp\dsh-subprocess-*\*.log` (verified).

### 2.3 Admission (why you get 401 / 403)

`HostConnectionService.admit(request)` (`lib/index.js:742-750`):

1. `isTrusted(request)` → `isTrustedApiRequest` (line 240-250). The **Host fence**:
   * `Host` header must be present and parse.
   * Hostname must be **loopback** (`localhost`, `127.0.0.0/8`, `::1`) **OR** the listener's own
     bind IP literal **OR** a configured `trustedHosts` entry.
   * `sec-fetch-site: cross-site` → rejected.
   * If an `Origin` header is present, its host must equal the `Host` host.
   * Failure → **`403`**.
2. `disposed` → `401`.
3. Valid **v1** cookie → the shared **owner** peer → full access.
4. Valid **v2** cookie → the API-operator peer → **non-owner** → subject to `ctx.remoteAccess`.
5. Otherwise → **`401`** with body `unauthorized`.

`GET /` and the SPA index use `BrowserAuth.authorizeIndex` (line 458) → `401` body:
`dsh web authentication required; reopen the URL printed by dsh web.\n`.

Exact-Fetch routes (`/api/file`, `/api/session.export`, …) additionally require
`peer.principal.kind === "owner"`, else `403` (`lib/index.js:830`).

### 2.4 The v2 / API-operator path is effectively dead in this build

`ctx.remoteAccess.decide()` is consulted only for non-owner principals
(`dsh-api-gateway/lib/index.js:1175-1190`). A call that declares **no** `resources` is refused with
reason `resource-invalid` before the policy is even asked. `registerPolicy(kind, policy)` exists
(`dsh-api-remote-access/lib/index.js:175`) but **no shipped package calls it** (verified by grep over
the whole extracted tree) → no principal kind has a policy → every non-owner call is denied.

**Consequence: the only usable credential is a v1 owner cookie.**

### 2.5 Live verification of the auth paths (this machine)

```
GET  /                      → 401  "dsh web authentication required; reopen the URL printed by dsh web."
POST /api/session/list      → 401  "unauthorized"
GET  /api/remote.mux        → 401
GET  /connect?token=x       → 401
```
After minting a v1 cookie from the on-disk secret:
```
POST /api/session/list      → 200  {"type":"server-response","rpcId":"probe-1","result":{"ok":true,
                                       "value":{"items":[ …117 sessions… ]}}}
```

---

## 3. Session / message domain model

### 3.1 What a Session is

`@deepseek-ai/dsh-session` — "records every model-visible fact in an append-only session log and
derives model history from that record". A Session is an **event-sourced log** with a monotonic
`SessionSeq`; `ctx.sessions.create()/get()/list()/fork()` are the in-process API.

Distinguishing fields of a session row (`SessionSummary`, typert.host.js:2967):

```jsonc
{
  "sessionId": "2694089e-d8eb-47e9-af92-428455100309",
  "updatedAt": 1792600941763,          // epoch ms
  "agentAvailable": true,              // owns a live Agent
  "running": true,
  "blank": false,
  "formatStatus": "current",           // or "migration-required"
  "parentSessionId": "session-9de9…",  // present ⇒ subagent
  "origin": "subagent",                // absent ⇒ root session
  "cwd": "D:\\APP\\Deepseek\\DSHHarmony",
  "projections": {
    "kind": "sequenced",               // or "cached"
    "asOfSeq": 29,
    "values": {
      "title": "…", "goal": null, "agentPreset": "cordis",
      "inbox": {"next-turn": [], "next-step": []},
      "workingDirectory": "…", "permissions": {"currentValue": "danger-full-access"},
      "sessionStats": {"turns":1,"steps":2,"llmMs":9302,"toolMs":1735,"ttftMs":6304,…},
      "tokenUsage": {...}, "contextPressure": {...}, "contextBreakdown": {...},
      "turnOutline": [{"turn":1,"seq":5,"prompt":"…","response":""}],
      "userQuestions": {"active":[],"settled":[]}
    }
  }
}
```

`SessionAddress` (typert.host.js:2751) — how a client names a session:

```ts
{ kind: 'session',  sessionId: SessionId }
| { kind: 'subagent', parentSessionId: SessionId, childSessionId: SessionId,
    mode: 'one-shot' | 'continuable' | 'unknown' }
```

> **Verified trap**: `session/follow` on a subagent with `kind:'session'` fails with
> `session/agent-busy` — *"subagent Sessions require their durable parent address"*.
> A subagent must be addressed with `kind:'subagent'` + `parentSessionId` + `childSessionId` + `mode`.

### 3.2 Message / event shapes

Wire event (`SessionWireEvent`, typert.host.js:2999):

```jsonc
{ "type": "user/message", "seq": 12, "time": 1792600926199,
  "data": { … }, "ignorable": true?, "sourceEventSeqs": …?, "surfaceOp": …? }
```

`SessionEventType = keyof SessionEventMap`. The full event-type map (typert.host.js:2807) — this is
the message vocabulary:

```
'turn/start' {turn}                     'turn/end' {turn, reason}
'step/start' {turn, step}               'step/end' {turn, step}
'user/message'   UserMessage            'developer/message' {turn, step, message, headerSeq?}
'system/message' {turn, step, message}  'assistant/message' {turn, step, message, stream, usage?, interrupted?}
'assistant/attempt' {turn, step, stream}
'tool/call'   {turn, step, callId, name, arguments}
'tool/result' {turn, step, message, error?:{name,code,reason?}, meta?}
'request/header' {header, reason, startsSeries?}   'request/context' RequestContext
'session/end-seed' {inherited?}         'agent/inbox/spliced' {target,start,removedCount?,inserted,outcome?}
'working-directory/change' {cwd}        'sandbox/mode' {mode, source?}
'approval/asked' {id, toolName, callId?, reason?}  'approval/decided' {id, outcome}
'approval/policy' {policy, source?}
'tool/ptc-dispatch-start' / 'tool/ptc-dispatch'
'agent-preset/selected' {agentPreset}
'job/registered' / 'job/settled'
'command/run' {commandId, name, stri…}
… (further entries truncated in the generated file)
```

`SessionWireHeader` (typert.host.js:3003):

```jsonc
{ "version": 4, "id": "2694089e-…", "createdAt": 1792600925870,
  "cwd": "D:\\…", "parentSession": "session-9de9…", "isSeeded": false,
  "origin": "subagent", "delegationDepth": 1, "agentPreset": "cordis" }
```

`PromptContentPart` (typert.host.js:2647):

```ts
{ type: 'text',  text: string }
| { type: 'image', mediaType: 'image/png'|'image/jpeg'|'image/webp'|'image/gif', data: string /*base64*/, name?: string }
| { type: 'file',  receiptId: string }
```

`SessionPromptRequest` (typert.host.js:2911):

```ts
{ requestId: SessionRequestId,   // client-minted id, persisted on the accepted user message (idempotency)
  sessionId: SessionId,
  mode: 'queue' | 'steer',
  content: readonly PromptContentPart[],
  clientTimeZone?: string }        // 'UTC' or an IANA Area/Location; else session/invalid-time-zone
```

`SessionPromptValue` = `{ accepted: true }`.

### 3.3 Follow frames

`SessionFollowFrame` (typert.host.js:2815):

```ts
{ type: 'snapshot', header: SessionWireHeader, cursor: number,
  records: readonly SessionHistoryRecord[], hasMore: boolean,
  projections: SessionProjectionBaseline, assistantStream?: SessionAssistantStreamBaseline }
| { type: 'event', event: SessionWireEvent }
| { type: 'assistant-stream', frame: SessionAssistantStreamFrame }
```

`SessionHistoryRecord = SessionEventEntry` = `{ type: 'event', event: SessionWireEvent }`.

`SessionAssistantStreamFrame` (typert.host.js:2763):

```ts
{ type: 'start', attemptId, revision, startedAfterSeq, turn, step }
| { type: 'chunk', attemptId, revision, index, time, chunk: JsonValue }   // e.g. {type:'reasoning-delta',index,text} / text deltas
| { type: 'end',   attemptId, revision, index,
    outcome: { kind:'committed', eventType:'assistant/message'|'assistant/attempt', seq } | { kind:'abandoned' } }
```

---

## 4. Streaming mechanism

**WebSocket only. There is no SSE endpoint for session/message data.** (`text/event-stream` appears
only in `dsh-client-hmr` — the dev hot-reload route — and in vendored pdf.js.)

Endpoint: **`ws://127.0.0.1:10748/api/remote.mux`** (constant `REMOTE_STREAM_MUX_PATH`,
`dsh-api-gateway/lib/types/stream-protocol.js:4`). Registered as a WS **upgrade** route
(`dsh-api-gateway/lib/index.js:784-821`); the upgrade is admitted by
`connection.admitConnection(req)` — same cookie + Host fence as HTTP (401/403 otherwise).

Frame envelope (validated by `parseRemoteStreamServerMessage`,
`dsh-api-gateway/lib/types/client/stream-client.js:61-79`):

**Client → server**

```jsonc
{ "type": "open",   "streamId": "<uuid>", "endpoint": "session/follow", "payload": { "args": { … } } }
{ "type": "item",   "streamId": "<uuid>", "value": { … } }   // uplink items (optional)
{ "type": "end",    "streamId": "<uuid>" }                   // uplink end
{ "type": "cancel", "streamId": "<uuid>" }
```

**Server → client**

```jsonc
{ "type": "item",  "streamId": "<uuid>", "value": <SessionFollowFrame> }
{ "type": "end",   "streamId": "<uuid>" }
{ "type": "error", "streamId": "<uuid>", "error": { "code": "…", "message": "…", "details": { … } } }
```

The socket is a **multiplexer**: one physical WebSocket carries many logical streams, each with its
own `streamId`. Frames are JSON text messages. Unary endpoints **cannot** be opened on this socket
(`gateway/signature-invalid`: "unary Remote methods cannot be opened through the stream carrier")
and stream endpoints cannot be called over HTTP POST ("stream Remote methods must be opened through
the stream carrier"). Both verified live.

**Live-verified stream output** (subagent session, `assistantStream: true`):

```
→ {"type":"open","streamId":"97e5…","endpoint":"session/follow",
   "payload":{"args":{"request":{"address":{"kind":"subagent","parentSessionId":"session-9de9…",
             "childSessionId":"2694089e-…","mode":"continuable"},"assistantStream":true}}}}
← {"type":"item","streamId":"97e5…","value":{"type":"snapshot",
      "header":{"version":4,"id":"2694089e-…","createdAt":1792600925870,"cwd":"D:\\…",
                "parentSession":"session-9de9…","isSeeded":false,"origin":"subagent",
                "delegationDepth":1,"agentPreset":"cordis"},
      "cursor":92,"records":[{"type":"event","event":{"type":"subagent/descriptor","seq":0,
                "time":1792600926199,"data":{…}}}]}}
← {"type":"item","streamId":"97e5…","value":{"type":"assistant-stream",
      "frame":{"type":"chunk","attemptId":"2694089e-…:9","revision":1445,"index":314,
               "time":1792601080079,"chunk":{"type":"reasoning-delta","index":0,"text":"…"}}}}
```

Other streams available on the same socket: `session/control`, `job/follow`, `job/list`,
`workspace/follow`, `terminal/attach`, `terminal/retain`, `account/watch`, `account/watchExpiry`,
`remoteAccess/follow`, `speech/follow`, `userQuestions/attachWait`, `productAnalytics/watchPolicy`,
plus the gateway-internal `$events` forwarded-event stream and `$events/result`.

---

## 5. Existing "remote / mobile / pairing / QR / device" features

| Searched term | Result |
|---|---|
| `qrcode`, `QRCode`, `QR code`, `pair-device`, `pairing code` | **Nothing** (only a pdf.js licence comment and a Lighthouse description). |
| `mobile`, `phone`, App Store, Play Store | **Nothing** DSH-related (only "phone number" in the DeepSeek account profile, and Lighthouse docs). |
| `remote` | `@deepseek-ai/dsh-api-remote-access` (method-level access control for non-owner Peers), `@deepseek-ai/dsh-api-remotes` (the application Remote assembly that mounts the Typert contributions), `GET /connect` (API-operator exchange), `/api/remote.mux` (the WS carrier), `remoteAccess/follow` (access snapshot stream). |
| `device` | `deepseek-account-platform/device` credential record (DeepSeek account device id) — unrelated. |
| `push` | No push-notification service. |
| `websocket` / `ws` | Only the single `/api/remote.mux` carrier. |
| `sse` | Only the dev HMR route. |

**There is no mobile/phone/pairing/QR feature.** The nearest thing is the *Remote* subsystem
(Typert RPC over HTTP + WS with per-method access control) and the `/connect` API-operator
exchange — but, as shown in §2.4, the shipped build registers no access policy, so a
`/connect`-minted (v2) peer is denied everything.

---

## 6. VERDICT

### Can an external client already do read + send over HTTP? — **YES**, with two caveats.

**Caveat 1 — network reachability.** The listener is bound to **127.0.0.1 only**
(`Get-NetTCPConnection -LocalPort 10748` → `LocalAddress 127.0.0.1`, PID 105712). A phone on the LAN
cannot reach it directly, and the **Host fence** (§2.3) will reject a request whose `Host` header is
a LAN IP with **403** before any auth check. Options:
* (a) Run a small bridge on the PC that forwards to `127.0.0.1:10748` **and rewrites the `Host`
  header to `127.0.0.1:10748`** (and `Origin` to `http://127.0.0.1:10748` if it sets one), or
* (b) start the web profile with `--host <lan-ip>` and `--trusted-host <lan-ip>:<port>` (the
  `--trusted-host` flag exists in `dsh-web-app/lib/startup.js:25`; note the desktop build does not
  use it), or
* (c) tunnel (SSH/ngrok/cloudflared) + `--trusted-host`.
  A bridge that preserves the original `Host` **will fail with 403** — this is the single most
  likely integration bug.

**Caveat 2 — credential.** The launch token is not on disk. Two viable credentials:
* **Recommended (verified):** ship the cookie signing secret to the phone (out-of-band, once) and
  let the phone **mint its own v1 owner cookie** from `~/.dsh/.credentials.yaml` →
  `records."client-connection/browser-session".payload.secret`. Verified working end-to-end.
* Alternative: extract the launch token from the DSH host process (not on disk) and have the phone
  exchange it once: `GET /connect?token=…` → `302` + v2 cookie — but v2 is denied by the current
  policy, so instead do `GET /?token=…` and keep the **v1** cookie that it sets.

### Concrete curl example (read)

```bash
# 1) mint a v1 owner cookie (placeholders; run once on the PC and copy the secret to the phone)
SECRET='<43-char base64url from ~/.dsh/.credentials.yaml>'
AUTH='127.0.0.1:10748'
NAME="dsh-auth-$(printf '%s' "$AUTH" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=')"
BODY="$(printf '{"version":1,"authority":"%s","issuedAt":%s,"expiresAt":%s}' \
        "$AUTH" "$(date +%s000)" "$(( $(date +%s) + 30*24*3600 ))000" \
        | base64 | tr '+/' '-_' | tr -d '=')"
SIG="$(printf '%s' "$BODY" | openssl dgst -sha256 -mac HMAC -macopt hexkey:$(printf '%s' "$SECRET" | base64 -d | xxd -p -c 256) -binary | base64 | tr '+/' '-_' | tr -d '=')"
COOKIE="$NAME=v1.$BODY.$SIG"

# 2) list sessions
curl -s -X POST http://127.0.0.1:10748/api/session/list \
  -H "Content-Type: application/json" -H "Cookie: $COOKIE" \
  -d '{"type":"client-request","rpcId":"r1","method":"session/list","payload":{"args":{"_request":{}}}}'
```

### Concrete curl example (send a prompt)

```bash
curl -s -X POST http://127.0.0.1:10748/api/session/prompt \
  -H "Content-Type: application/json" -H "Cookie: $COOKIE" \
  -d '{
    "type":"client-request","rpcId":"r2","method":"session/prompt",
    "payload":{"args":{"request":{
      "requestId":"<client-minted-uuid>",
      "sessionId":"<sessionId>",
      "mode":"queue",
      "content":[{"type":"text","text":"hello from the phone"}],
      "clientTimeZone":"Asia/Shanghai"}}}}
# → {"type":"server-response","rpcId":"r2","result":{"ok":true,"value":{"accepted":true}}}
```

> Note the arg key: `session/prompt` takes `payload.args.request`; `session/list` takes
> `payload.args._request`. Getting this wrong yields
> `gateway/arguments-invalid: args fields do not match the descriptor: missing "request"`.

### Streaming the reply (WebSocket)

```
ws://127.0.0.1:10748/api/remote.mux      with header  Cookie: <dsh-auth-…>
→ {"type":"open","streamId":"<uuid>","endpoint":"session/follow",
   "payload":{"args":{"request":{"address":{"kind":"session","sessionId":"<id>"},
                                 "assistantStream":true,"maxMessages":50}}}}
← {"type":"item","streamId":"<uuid>","value":{"type":"snapshot","header":{…},"cursor":N,"records":[…]}}
← {"type":"item","streamId":"<uuid>","value":{"type":"event","event":{"type":"user/message",…}}}
← {"type":"item","streamId":"<uuid>","value":{"type":"assistant-stream","frame":{"type":"chunk",…}}}
← {"type":"end","streamId":"<uuid>"}
```

Send `{"type":"cancel","streamId":"<uuid>"}` to stop.

### If a DSH plugin had to be written instead (not needed, for reference)

* Service `ctx.connection` → `ctx.connection.rpc.handle("/api/<channel>", handler)` for a new RPC
  channel, `ctx.connection.rpc.intercept("/api", matches, handler)` to extend the shared `/api`
  channel, `ctx.connection.fetch.register({path, methods, requestBody, fetch})` for an exact
  non-RPC route (`dsh-client-connection/lib/index.js:723-854`).
* Service `ctx.remoteAccess` → `ctx.remoteAccess.registerPolicy(kind, policy)` to grant a
  non-owner principal an action set over a resource kind; `decide()` is Gateway-only.
* Service `ctx.sessions` → `ctx.sessions.create()/get()/list()/fork()`; `session.append(type, data)`
  for log events; `session.deriveMessages()` for model history.
* Service `ctx.agents` → the live Agent registry; a prompt is admitted via
  `sessionController.commands.prompt(request, source)` with
  `source = {kind:'user', rpcId, clientTimeZone?, principal?}`.
* Host events for the session namespace: `api-session/activity`, `api-session/added`,
  `api-session/error`, `api-session/removed`, `api-session/status`
  (`dsh-api-session-controller/lib/typert.host.js:3952-4048`).

---

## Appendix — files consulted (all inside the asar unless stated)

```
dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js        (auth, /api, /connect, RPC envelope)
dsh/node_modules/@deepseek-ai/dsh-client-connection/README.md            (auth prose)
dsh/node_modules/@deepseek-ai/dsh-host-webserver/lib/index.js            (server core)
dsh/node_modules/@deepseek-ai/dsh-api-gateway/lib/index.js               (dispatch, endpointOf, remoteRequest)
dsh/node_modules/@deepseek-ai/dsh-api-gateway/lib/types/stream-protocol.js
dsh/node_modules/@deepseek-ai/dsh-api-gateway/lib/types/client/stream-client.js
dsh/node_modules/@deepseek-ai/dsh-api-session-controller/lib/typert.host.js   (session/* schemas)
dsh/node_modules/@deepseek-ai/dsh-api-session-controller/lib/index.js        (prompt impl, /api/file)
dsh/node_modules/@deepseek-ai/dsh-api-remote-access/README.md
dsh/node_modules/@deepseek-ai/dsh-web-app/lib/index.js, lib/startup.js
dsh/node_modules/@deepseek-ai/dsh-host-frontend-static/lib/index.js
dsh/node_modules/@deepseek-ai/dsh-credentials-local/lib/index.js        (credentials.yaml path)
dsh/node_modules/@deepseek-ai/dsh-session/README.md
dsh/node_modules/@deepseek-ai/dsh-typert-protocol/lib/types/remote-info.js
lib/main.js                                                            (Electron shell, WS usage)
C:\Users\YourName\.dsh\.credentials.yaml                                  (credential store — paths only in this report)
C:\Users\YourName\.dsh\profiles\desktop\cordis.patch.yml                  (profile patch, no trustedHosts)
```
