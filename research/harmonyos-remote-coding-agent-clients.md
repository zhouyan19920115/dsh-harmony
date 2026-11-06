# HarmonyOS / ArkTS Remote Client for a Desktop AI Coding Agent — Landscape & Architecture Report

> Research date: 2026-10-22 · Scope: find existing open-source solutions, determine the architecture
> pattern used by the real products (TRAE SOLO Mobile, MiniMax Code Remote Control, Claude Code
> Remote Control, Codex Remote), and recommend a design for our own HarmonyOS client.

---

## 0. TL;DR / Bottom line

1. **No official HarmonyOS build exists** for any of the four reference products. TRAE SOLO Mobile,
   MiniMax Agent, the Claude mobile app and ChatGPT/Codex mobile are **iOS + Android only**.
   The premise in the brief ("Trae and MiniMax Code now have HarmonyOS clients") is **not verifiable
   from any official source** — their download pages and store listings show no HarmonyOS package.
   What *does* exist is a small, fast-growing set of **unofficial community HarmonyOS clients**
   (all created in 2026, all ≤ 35 stars).
2. **The architecture is uniform across every real product**: a **cloud WebSocket relay sits in the
   middle**, the **desktop dials out** to it (never opening an inbound port), and the **phone also
   dials out** to the same relay. Pairing is a **QR code carrying a long-lived credential**, and the
   wire handshake is a **HMAC challenge-response**, not a bearer token.
3. **HarmonyOS's official distributed APIs cannot replace the relay** for this use case — the desktop
   is a Windows/macOS box running Claude Code, not a HarmonyOS device. The public `distributedDeviceManager`
   only reaches HarmonyOS peers, `distributedKVStore` is state replication (not RPC) and its `autoSync`
   only works inside the cross-device-`Call` scenario, and the old `distributedHardware.deviceManager`
   is a **system API that third-party apps cannot call**.
4. **The single most valuable artifact to steal from** is
   [`studyguy/ZcodeRemote`](https://github.com/studyguy/ZcodeRemote) — it publishes a full reverse-engineered
   protocol spec (`research/protocol.md`) of a *desktop AI agent → cloud WSS relay → phone* system,
   including frame formats, auth, RPC channels and error codes. It is the closest open description of
   the TRAE / MiniMax / Codex pattern.
5. **Recommended design**: mirror Claude Code Remote Control + ZcodeRemote. Build a small ArkTS app
   (WebSocket + AssetStoreKit + Push Kit), a small self-hosted relay, and a desktop Node/TS daemon
   that drives **Claude Code via its Agent SDK + `PreToolUse` hook** (and **Codex via `codex app-server`**,
   **opencode via `opencode serve`**). Do **not** reimplement session parsing, and do **not** build a
   SignalR client from scratch.

---

## 1. (a) Comparison table — candidate existing solutions

### 1.1 Tier 1 — HarmonyOS-native (ArkTS) remote clients for desktop AI agents

| Project | URL | ★ | Lang | Last push | ArkTS/HarmonyOS module (path) | Transport | Auth / pairing | Session sync |
|---|---|---|---|---|---|---|---|---|
| **Serein** | [liznee/serein](https://github.com/liznee/serein) | 1 | Go (+ArkTS, Node, Python) | 2026-08-22 | `harmony/entry/src/main/ets/**` — `api/WebSocketClient.ets`, `api/ApprovalApi.ets`, `api/DeviceApi.ets`, `pages/ApprovalsPage.ets`, `pages/PairPage.ets`, `pages/ProjectsPage.ets` | **Self-hosted relay**: phone →HTTPS/WSS→ Go backend (chi + SQLite) →WSS→ PC Relay (Node + node-pty) → PTY/JSONL → `claude`/`codex` CLI. Optional ntfy + HarmonyOS **Push Kit** | QR code pairing (`serein pair` prints QR) + `PAIR_CODE`; `HOOK_TOKEN` for hooks; per-device token stored in **HUKS**; single bound device | WSS push; Claude Code `PreToolUse` hook → risk classification → approval cards on phone → hook returns the decision |
| **ZcodeRemote** | [studyguy/ZcodeRemote](https://github.com/studyguy/ZcodeRemote) | 0 | JavaScript (ArkTS) | 2026-10-19 | `app/entry/src/main/ets/**` — `protocol/RelayClient.ets`, `protocol/ChannelClient.ets`, `protocol/FrameCodec.ets`, `protocol/WireSerializer.ets`, `protocol/BridgeSession.ets`, `protocol/Crc32.ets`, `store/BindingStore.ets`, `store/QrParser.ets`, `service/ZcodeService.ets`, `view/MarkdownView.ets` | **Cloud WSS relay** `wss://<host>/ws` (host = domain in the binding link; **privately deployable**). Binary framed protocol (custom, CRC32) | QR code from desktop's "移动端远程控制"; credential = `device_sid` + `passHash`; **HMAC-SHA256 challenge-response** (`auth_init`→`auth_challenge`→`auth_response`); secret stored in **AssetStoreKit** | Push: `workspace-list-updated`; per-session bridge with etag incremental refresh. **Publishes a full protocol spec in `research/protocol.md`** |
| **Codex Harmony Remote** | [CCDawn/harmony-codex](https://github.com/CCDawn/harmony-codex) | 2 | JavaScript (ArkTS) + Node | 2026-10-18 | `HarmonyCodexRemote/entry/src/main/ets/**` — `services/BridgeClient.ets`, `services/BridgePairingService.ets`, `services/BridgeCredentialStore.ets`, `services/HdcRelayTunnel.ets`, `services/AppBackgroundRuntimeService.ets`, `components/CompanionConversationPanel.ets` | **LAN direct** (default) **or optional public relay** → Windows local bridge (Node) → **Codex Desktop app-server**. Bridge owns the app-server stdio process; the phone never sees the app-server port | Token in `BridgeConfig.ets` + `BridgeCredentialStore.ets`; pairing panel; optional TOTP | Bridge proxies app-server `thread/list`, `account/rateLimits/read`; history read from local session records (documented limitation: not single-source-of-truth) |
| **Corterm / CortexTerminal2** | [monster-echo/CortexTerminal2](https://github.com/monster-echo/CortexTerminal2) | 35 | C# (+ArkTS) | 2026-10-21 | `src/Harmony/**` — `common/core/src/main/ets/service/p2p/P2pTransfer.ets`, `ReliableStream.ets`, `StunClient.ets`; ~8 645 lines ArkTS, incl. a **1 091-line hand-rolled SignalR client** | **SignalR / WebSocket to a .NET Gateway** (JWT auth) → Worker on the desktop machine (PTY). Optional **P2P via STUN** | Gateway auth: password / SMS / GitHub / Google / Apple OAuth; JWT | PTY stream with scrollback replay; Claude Code **hooks** report every prompt/tool-call/notification to the Worker and render as a timeline. **App Store + Google Play + Huawei AppGallery** |
| **Hermes Agent Mobile (HarmonyOS)** | [fengnanrui/Hermes-Agent-Mobile-HarmonyOS](https://github.com/fengnanrui/Hermes-Agent-Mobile-HarmonyOS) | 0 | TypeScript (ArkTS/ArkUI/ArkWeb) | 2026-08-06 | `entry/src/main/ets/**` (ArkWeb wrapper) | Remote backend (dashboard) over HTTP | Dash URL persisted, strict same-origin check | N/A — it's a remote dashboard, not an agent-protocol client |
| **Hey** | [popsiclelmlm/Hey](https://github.com/popsiclelmlm/Hey) | 41 | C++ | 2026-09-24 | Native HarmonyOS NEXT app (C++/ArkUI) | Network tunnel + protocol debugger, **bring your own server** | user-supplied | N/A — transport utility, not an agent client |
| **ToRustDesk** | [llllliuke/ToRustDesk](https://github.com/llllliuke/ToRustDesk) | 1 | Shell | 2026-08-31 | HarmonyOS RustDesk viewer | RustDesk P2P | RustDesk | Remote *desktop* (screen+touch), not agent sessions |

### 1.2 Tier 2 — HarmonyOS-relevant but not ArkTS-native

| Project | URL | ★ | Lang | Last push | HarmonyOS? | Transport | Notes |
|---|---|---|---|---|---|---|---|
| **Android SSH Codex** | [wkj2333666/Android-SSH-Codex](https://github.com/wkj2333666/Android-SSH-Codex) | 4 | Dart / Flutter | 2026-10-20 | ✅ ships an **OpenHarmony** build (`tool/prepare_ohos.sh`), but the app is Flutter/ArkUI-runtime, not ArkTS | **Direct SSH** to a Codex app-server — "**no hosted relay**"; SSH exec channel → loopback→Unix-socket tunnel → `codex app-server`. App-server modes: Shared / Custom / Isolated | SSH host key fingerprint verification; `~/.ssh/config` + ProxyJump; no OpenAI credentials on phone | JSON-RPC over the SSH channel; task list, approvals, file up/download, `/goal` `/compact` `/skills` `/interrupt` |
| **Feishu mobile Codex skill** | [ChiyuSONG/feishu-mobile-codex-skill](https://github.com/ChiyuSONG/feishu-mobile-codex-skill) | 2 | Python | 2026-10-14 | ✅ claims support for iOS/Android/**HarmonyOS** users (via Feishu app, not a native HAP) | Push to a Feishu bot + poll-back | Feishu creds outside repo | Dispatch tasks, receive notifications, deliver image/PDF/Excel |
| **Lavamilk** | [lavamilkTeam/lavamilk.template](https://github.com/lavamilkTeam/lavamilk.template) | 11 | JavaScript | 2026-10-04 | Claims Android/iOS/**HarmonyOS** mobile agent | "connect to Codex and other software on your computer" | — | ⚠️ the public repo is only the **marketing website** (Vue 3 + PocketBase). The app itself is not in this repo. Treat as unverified. |
| **AgentHub** | [QinpanWan/AgentHub](https://github.com/QinpanWan/AgentHub) | 3 | JavaScript | 2026-09-05 | HarmonyOS **PC** (not phone) | local daemon (`hish`) | local | Cross-agent management of Codex / Claude / DSH on a HarmonyOS PC. Desktop-side, not a phone client. |
| **DSH desktop on HOS** | [fellow99/dsh-desktop-hos](https://github.com/fellow99/dsh-desktop-hos) | 4 | JavaScript | 2026-10-21 | Electron 37 on HarmonyOS | — | — | DSH as a native 2in1/tablet app — relevant to *our* stack, not a phone client |

### 1.3 Tier 3 — non-HarmonyOS reference implementations (the pattern to port)

| Project | URL | ★ | Lang | Last push | Transport | Auth | Session sync |
|---|---|---|---|---|---|---|---|
| **Claude Code UI / CloudCLI** | [siteboon/claudecodeui](https://github.com/siteboon/claudecodeui) | 14 220 | TypeScript | 2026-10-21 | Node/React server on the desktop, browser or mobile web UI (responsive) | server-side; optional CloudCLI Cloud | Reads Claude Code session JSONL; spawns the CLI with `--resume`; file explorer, Git explorer, built-in terminal, plugin system, TaskMaster AI |
| **Claudia → opcode** | [getAsterisk/claudia](https://github.com/getAsterisk/claudia) → [winfunc/opcode](https://github.com/winfunc/opcode) | 22 417 | TypeScript | 2026-09-18 | **Tauri desktop GUI** (not remote) | local | AGPL-3.0. TUI-equivalent GUI: custom agents, interactive sessions, secure background agents, checkpoints, timeline, MCP config |
| **opencode** | [sst/opencode](https://github.com/sst/opencode) → [anomalyco/opencode](https://github.com/anomalyco/opencode) | 219 540 | TypeScript | 2026-10-21 | **`opencode serve`** — headless **HTTP + OpenAPI 3.1** server on :4096, SSE at `/global/event` and per-session `/event`; generated SDK; `opencode attach` | HTTP Basic via `OPENCODE_SERVER_PASSWORD` / `OPENCODE_SERVER_USERNAME`; `--cors` for browser origins; `--mdns` discovery | **The cleanest reusable protocol of the lot** — `/session`, `/session/:id/message`, `/event` SSE, `/tui/*` endpoints |
| **Termopus** | [Termopus/termopus](https://github.com/Termopus/termopus) | — | Rust + Flutter | — | **Cloudflare Durable Object relay**; Rust bridge on the desktop; Flutter phone app; WebSocket both sides; **E2E encrypted (AES-256-GCM, hardware-backed keys)**, mTLS | Device-certificate issuance via Cloudflare Workers; challenge-response | Push notifications via Firebase. iOS/Android only — **not HarmonyOS** |
| **claude-code-web-client** | [serebano/claude-code-web-client](https://github.com/serebano/claude-code-web-client) | — | TypeScript / Next.js | — | Next.js route handlers; **Anthropic's first-party Code Sessions API** over SSE (`/v1/code/sessions/{id}/events/stream`) + **local file tailing** of `~/.claude/projects/**/*.jsonl` by byte offset with `fs.watch` | Reuses the Claude Code **OAuth token** from the macOS Keychain / `~/.claude/.credentials.json`; scope `user:sessions:claude_code`; **no API key needed** | True realtime, no polling. `/api/rc/send` drives the **live** session; `/api/rc/presence` heartbeats; Agent SDK `query()` for resume/fork. **This is the reference implementation of the "message parity + live session" approach** |
| **Agent of Empires (AoE)** | [agent-of-empires/agent-of-empires](https://github.com/agent-of-empires/agent-of-empires) | 3 371 | Rust | — | Rust TUI + browser UI; parallel agents across branches, worktree/container isolation | — | MIT. `brew install aoe` |
| **claude-code-router** | [musistudio/claude-code-router](https://github.com/musistudio/claude-code-router) | 37 788 | TypeScript | 2026-10-10 | local control plane (model routing), **not a remote client** | — | Useful as the *local* side of a bridge (routing Claude Code to MiniMax/GLM/Kimi models) |
| **claude-code-web / moltbot** | `aiondadotcom/claude-code-web`, `aiondadotcom/moltbot` | — | — | — | — | — | ⚠️ **These do not exist.** Both 404 on the GitHub API, and the `AiondaDotCom` account's public repo list contains neither. Correct the brief — the live equivalents are `siteboon/claudecodeui` (CloudCLI) and `serebano/claude-code-web-client`. |

### 1.4 Tier 4 — the commercial products we must mirror (no source available)

| Product | Docs / announcement | Platform | Desktop-side | Transport | Pairing | Sync |
|---|---|---|---|---|---|---|
| **Claude Code Remote Control** | [code.claude.com/docs/en/remote-control](https://code.claude.com/docs/en/remote-control) | claude.ai/code web + **Claude app iOS/Android** (no HarmonyOS) | `claude remote-control` runs in **server mode**; the local session *is* the execution host | **Outbound HTTPS only — "never opens inbound ports on your machine"**; registers with the Anthropic API and polls for work; the server routes messages over a streaming connection. Multiple short-lived, purpose-scoped credentials over TLS | `claude remote-control` prints a **session URL + QR code** (spacebar toggles QR); or open claude.ai/code and find the session by name; account must be the same claude.ai login | **Push/streaming**, both directions; compaction, `/clear`, `/resume`, `/teleport`, diffs, model & effort changes, subagent status all sync live. Requires a **claude.ai subscription** (no API keys; no Bedrock/Vertex; `ANTHROPIC_BASE_URL` must point at `api.anthropic.com`) |
| **Codex Remote Connections** | [developers.openai.com/codex/app/remote](https://developers.openai.com/codex/app/remote) | ChatGPT mobile app iOS/Android + ChatGPT/Codex desktop (macOS/Windows) | **`codex app-server`** daemon owns sessions, approvals, project context. `codex app-server --listen ws://127.0.0.1:4500`; `codex remote-control`; `codex app-server daemon bootstrap` (Unix socket `~/.codex/app-server-control/app-server-control.sock`) | (a) hosted relay, or (b) **SSH** to a remote host running the app-server (ChatGPT mobile has a native Codex-over-SSH client). Docs warn: *"Don't expose app-server transports directly on a shared or public network"* | Desktop: *Settings → Connections → "Allow other devices to connect"* (off by default) → **scan the desktop QR**; confirm same ChatGPT account/workspace + MFA/SSO/passkey. WS auth: **capability token** (`--ws-auth capability-token --ws-token-file`) or **signed bearer JWT** (`--ws-auth signed-bearer-token --ws-shared-secret-file --ws-issuer --ws-audience`) | Push over the app-server channel; mobile shows live threads, pending approvals, plugin context, project files. Enterprise access tokens; device-code flow for headless auth |
| **TRAE SOLO Mobile** (now **TRAE Work**; IDE renamed **TraeCode** 2026-08) | [trae.ai/blog/trae_solo_mobile_0506](https://www.trae.ai/blog/trae_solo_mobile_0506) · [trae.ai/download](https://trae.ai/download) | **iOS + Android only** (App Store / Google Play). ⚠️ **No HarmonyOS package listed** | Desktop = **TRAE Work / TraeCode desktop**; also a **Web (Cloud)** execution endpoint | Vendor cloud. *("Tasks created on mobile instantly appear on Web (Cloud) and Desktop (Local)")*. *("任务已提交到服务端队列，桌面端只要开机运行 TRAE 会继续执行")* — i.e. **a server-side task queue** | **Same account on desktop + phone**, then desktop *avatar → Settings → SOLO 移动端 → scan QR* → phone can access the desktop's projects. ([guide](https://toolin.ai/blog/trae-solo-mobile-guide)) | Push. Parallel task dispatch across paired endpoints; remote folder access with desktop-side folder permissions; artifacts saved back into the same directories; voice input; Privacy Mode. Two modes: **Code Mode** and **MTC Mode** |
| **MiniMax Code Remote Control** | [agent.minimax.cn/docs/code/automation/remote-control](https://agent.minimax.cn/docs/code/automation/remote-control) · [MiniMax Agent on Google Play](https://play.google.com/store/apps/details?id=com.minimax.ai) | **MiniMax Agent mobile app (iOS/Android)**; desktop = MiniMax Code (macOS/Windows). ⚠️ **No HarmonyOS package listed** | MiniMax Code desktop app (the local session executes) | Vendor cloud relay. *"your project files, terminal, and runtime environment stay on your computer"*; *"App Remote Control is now live, letting you connect your phone directly to the desktop Agent"* | Desktop opens the **Remote Control** entry; the page shows how to bind the phone ("根据页面提示完成手机端绑定"). MiniMax account login on the desktop | Push; can view desktop task progress, send follow-up instructions, handle permission confirmations, view task artifacts and some file contents. Also has **IM 连接** (chat-platform integration) as an alternative channel |

---

## 2. (b) The architecture pattern

### 2.1 The invariant: relay in the middle, desktop dials out

```
┌──────────────┐   WSS (phone dials out)   ┌────────────────────┐   WSS (desktop dials out)   ┌──────────────────────┐
│  Phone app   │ ─────────────────────────► │  Vendor relay      │ ◄───────────────────────── │  Desktop daemon      │
│  (initiator) │ ◄───────────────────────── │  (opaque frames,   │ ─────────────────────────► │  (claude / codex /   │
│              │                            │   session routing) │                            │   opencode + PTY)    │
└──────────────┘                            └────────────────────┘                            └──────────────────────┘
```

Every real product agrees on these **seven invariants**:

| # | Invariant | Evidence |
|---|---|---|
| 1 | **A cloud relay in the middle.** No official product does LAN P2P by default. | Claude RC: "When you start Remote Control, it **registers with the Anthropic API** and polls for work." TRAE: tasks "submitted to the **server queue**". ZCode: `wss://zcode.z.ai/ws`. Codex: hosted relay *or* SSH. |
| 2 | **The desktop dials OUT and never opens an inbound port.** | Claude RC: "Your local Claude Code session makes **outbound HTTPS requests only and never opens inbound ports** on your machine." ZCode: "桌面端与手机端都**主动外连**同一个云端 WebSocket 中继（**本机不监听端口**）." Codex: "Don't expose app-server transports directly on a shared or public network." |
| 3 | **Pairing = QR code carrying a long-lived credential**, scanned once, then auto-connect forever. | Claude RC: session URL + QR (`spacebar` toggles). Codex: desktop QR + "Allow other devices to connect". TRAE: desktop *SOLO 移动端* QR. MiniMax: Remote Control binding page. ZCode: desktop QR = `https://zcode.z.ai/remote/v4?sid=…&hash=…`. |
| 4 | **The wire handshake is a challenge-response (HMAC), not a bearer token.** | ZCode: `auth_init{role}` → `auth_challenge{nonce}` → `auth_response{proof = HMAC-SHA256(passHash, nonce+"|"+role+"|"+sid)}` → `auth_ack{pair_status}`. Claude RC: "multiple short-lived credentials, each scoped to a single purpose and expiring independently." Codex: capability token / signed JWT. |
| 5 | **One socket, two symmetric roles.** The relay pairs a `device` role with a `terminal` role by `device_sid`. | ZCode: `role=device` (desktop) / `role=terminal` (phone) over the same `wss://…/ws?mid=…`. |
| 6 | **Push notifications for "the agent needs you".** | Claude RC (app), Codex (app), TRAE ("notifies you with push alerts"). HarmonyOS equivalent = **Push Kit** (Serein implements it). |
| 7 | **The desktop is the single source of truth for execution; the phone is a window into it.** | TRAE distinguishes **Web (Cloud)** endpoints from **Desktop (Local)** endpoints. Codex: the app-server daemon owns sessions and approvals. Claude RC: "the web and mobile interfaces are just a window into that local session." |

### 2.2 Session sync: push, not polling

* **TRAE** — "Tasks created on mobile **instantly appear** on Web (Cloud) and Desktop (Local)." Cross-endpoint, not phone↔desktop polling.
* **Claude RC** — a streaming connection carries messages both ways; the phone sees compaction, `/clear`, `/resume`, subagent stop, diffs, model & effort changes as they happen.
* **ZCode** — two levels: (a) session list pushed via `workspace-list-updated`; (b) inside a session "bridge", a `getTaskSnapshotWithEtag` + `ifNoneMatch` etag loop for incremental refresh, plus `readSessionMessages` deltas.
* **opencode** — SSE: `/global/event` and per-session `/event`.
* **serebano/claude-code-web-client** — the most technically interesting: it **tails `~/.claude/projects/**/*.jsonl` by byte offset** with `fs.watch` and pushes appended lines over SSE, so the phone shows *byte-exact parity* with the terminal. It also drives the **live** session through Anthropic's first-party Code Sessions API rather than a resumed copy.

**Design implication:** on the desktop side, prefer reading the agent's **own session files** (Claude Code JSONL) over scraping terminal output. It gives exact parity, survives restarts, and needs no hook.

### 2.3 The four transport variants you can copy

| Variant | Shape | Who uses it | When to pick it |
|---|---|---|---|
| **A. Vendor relay** | Phone ↔ vendor cloud ↔ desktop agent | Claude RC, Codex, TRAE, MiniMax, ZCode | You have an account backend and want zero setup. |
| **B. Self-hosted relay** | Phone ↔ *your* relay ↔ desktop agent | Serein (Go+SQLite+Docker), Termopus (Cloudflare Durable Object + Workers), Corterm (.NET gateway) | You want the data to stay under your control; the wire shape is identical to A. |
| **C. Direct SSH / tunnel** | Phone → SSH → app-server | Android-SSH-Codex, Codex SSH remote projects, ChatGPT mobile's Codex-over-SSH | Same LAN/VPN only. Needs a **VPN/mesh** for WAN. |
| **D. Direct LAN** | Phone → LAN bridge → desktop agent | `CCDawn/harmony-codex` LAN mode | Dev / home use only. Production needs A or B. |

### 2.4 What the reference OpenHarmony projects teach us (concrete ArkTS patterns)

* **AssetStoreKit for the binding credential.** `ZcodeRemote` stores the pair credential in the **system encrypted asset store** — hardware-backed, destroyed on uninstall. Serein uses **HUKS**. This is the correct HarmonyOS answer to "where do I keep the secret".
* **HarmonyOS Push Kit for "agent is waiting".** Serein ships `backend/internal/pushkit/publisher.go` + `docs/PUSH_KIT_SETUP.md`.
* **App background runtime + continuous task.** `harmony-codex` has `services/AppBackgroundRuntimeService.ets` and `services/AppNotificationService.ets`; Corterm's write-up says app-kill/network-switch/phone-sleep is *the* hard problem in mobile terminals.
* **Don't reimplement SignalR.** Corterm needed **1 091 lines of hand-rolled ArkTS** (negotiate handshake, WS transport with backoff, hub protocol with 5 message types, 0x1E record separator, keepalive) because there is no Microsoft SDK for HarmonyOS. Unless your backend is .NET, use a **plain WebSocket + JSON frame protocol** (ZCodeRemote's choice) and skip this entirely.
* **ArkTS language constraints** (from Corterm's write-up): no `as const`, no untyped object literals, no destructuring, `throw` only accepts `Error`. Plan for this — it is a real cost.

---

## 3. (c) Can OpenHarmony's official distributed APIs replace the relay?

**Short answer: no — not for a Windows/macOS desktop. And for a HarmonyOS desktop, still not for a streaming terminal.**

| API | Kit / API level | 3rd-party callable? | What it actually gives | Verdict for us |
|---|---|---|---|---|
| [`@ohos.distributedDeviceManager`](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-distributedservice-kit/js-apis-distributedDeviceManager.md) | Distributed Service Kit, API 10+ | ✅ **public** | Discover nearby *untrusted* devices, **bind** them (PIN / 碰 / 扫 / 靠), query the trusted-device list, listen online/offline. Requires `ohos.permission.DISTRIBUTED_DATASYNC` + an explicit user consent prompt, and both devices on the same LAN or with BT on | ❌ Can only reach **HarmonyOS** peers. A Windows/macOS box running Claude Code is invisible to it. |
| [`@ohos.distributedHardware.deviceManager`](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-distributedservice-kit/js-apis-device-manager-sys.md) | API 7+, deprecated API 11+ | ❌ **system API — "三方应用不支持调用"** | device publish/discover | ❌ **Hard dead end.** |
| [`@ohos.data.distributedKVStore`](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkdata/js-apis-distributedKVStore.md) | ArkData, API 9+ | ✅ with `DISTRIBUTED_DATASYNC` | `SingleKVStore` (unversioned) / `DeviceKVStore` (per-device). `autoSync` **only takes effect in the 跨设备Call (cross-device `Call`) multi-device collaboration scenario**; everywhere else it is manual sync. Value ≤ 4 MiB, `DeviceKVStore` key ≤ 896 B | ⚠️ **State replication, not RPC.** No request/response, no streaming, no bidirectional command channel. Fine for "last known state" badges, useless as the transport. |
| [`@ohos.data.distributedData`](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkdata/js-apis-distributed-data.md) | ArkData, API 7+ | ⚠️ deprecated from API 9 → use `distributedKVStore` | Old KV manager. Also *"所有需要获取 deviceId 的接口，都仅系统应用可用"* | ❌ Use `distributedKVStore`. |
| [`linkEnhance`](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-distributedservice-kit/js-apis-link-enhance.md) | Distributed Service Kit, **API 20+** | ✅ + `DISTRIBUTED_DATASYNC` | `createServer` / `createClient` — **Bluetooth** multi-channel data transfer between two devices (SystemCapability `DistributedSched.AppCollaboration`) | ⚠️ Real, but Bluetooth bandwidth/latency is wrong for a terminal stream, and the desktop still isn't a HarmonyOS device. Could carry a fallback heartbeat. |
| **Multi-device collaboration** (`startAbility` with `Operation.withDeviceId`) | [Ability Kit](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/application-models/hop-multi-device-collaboration.md) | ✅ to start a remote ability, but **device list is system-only**: *"由于'多端协同任务管理'能力尚未具备，开发者当前只能通过开发系统应用获取设备列表，不支持三方应用接入"* | Cross-device start of a `UIAbility` / `ServiceExtensionAbility`; data via `want`, **recommended < 100 KB** | ⚠️ One-shot `want` passing to a HarmonyOS peer. Not a stream; and the peer must run a HarmonyOS app. |
| **Push Kit** | — | ✅ | Push to the phone (the "agent needs approval" channel) | ✅ **Use this** — it is the one distributed-ish primitive that genuinely helps. |
| **Remote Communication Kit** | Huawei (not in OpenHarmony mainline docs) | ? | New cross-device comms for wearables | ❌ Watch/IoT scope. |

### Verdict

HarmonyOS's distributed stack is designed for **phone↔phone / phone↔tablet / phone↔HarmonyOS-PC** flows over the softbus, gated on **user-mediated device trust** and a **trusted-device group** configured in system settings, with **one-shot** `want` payloads. It was never designed to reach a **non-HarmonyOS** desktop, and none of its primitives is a **bidirectional streaming RPC**.

> **Therefore: a cloud (or self-hosted) WSS relay is mandatory for the WAN case.** The only ways to avoid one are Variant C (SSH + VPN/mesh) and Variant D (LAN) — both require the user to be on a private network.

---

## 4. (d) Recommended design for our HarmonyOS client

### 4.1 Recommendation in one line

> **Mirror Claude Code Remote Control + ZcodeRemote:** ArkTS phone app ⇄ small WSS relay ⇄ desktop daemon that drives **Claude Code via the Agent SDK + a `PreToolUse` hook**, with **Codex via `codex app-server`** and **opencode via `opencode serve`** as adapters. Pairing by QR + HMAC challenge-response, credentials in **AssetStoreKit**, notifications via **Push Kit**. **Do not** use HarmonyOS distributed APIs as the transport, and **do not** reimplement session parsing or a SignalR client.

### 4.2 Component breakdown

#### A. HarmonyOS app (ArkTS, HarmonyOS NEXT / API 12+)

```
entry/src/main/ets/
├── api/
│   ├── RelayClient.ets        # @kit.NetworkKit webSocket; reconnect w/ exponential backoff
│   ├── HttpClient.ets          # pairing REST calls
│   └── types.ets              # frame types
├── store/
│   ├── BindingStore.ets       # credential -> AssetStoreKit (hardware-backed)
│   └── SessionStore.ets       # session list + live transcript reducer
├── service/
│   ├── PushService.ets        # Push Kit: "approval needed"
│   └── BackgroundService.ets  # continuous task so the socket survives app-kill
├── view/
│   ├── MarkdownView.ets
│   └── DiffView.ets
└── pages/
    ├── PairPage.ets           # Scan Kit QR
    ├── SessionListPage.ets
    ├── ChatPage.ets
    ├── ApprovalPage.ets       # allow / deny / edit
    └── SettingsPage.ets
```

* **Transport:** plain **WebSocket + JSON frames** (ZCodeRemote's model), *not* SignalR. If we ever need the .NET gateway, port Corterm's SignalR client — but plan for ~1 100 lines of ArkTS.
* **Credentials:** `AssetStoreKit` (as ZcodeRemote) or `HUKS` (as Serein). Never `Preferences`/`preferences` in plaintext.
* **Push:** Push Kit for "Claude needs permission" / "task finished".
* **Permissions:** `ohos.permission.INTERNET`, `ohos.permission.CAMERA` (QR scan) — ZcodeRemote needs exactly these two.
* **Background survival:** HarmonyOS will kill background apps. Use a **continuous task / background task** + Push Kit. (Corterm's dev.to write-up: *"Every mobile terminal app has the same problem: none can actually keep a connection alive."*)

#### B. Relay (the small piece we must write)

Minimal: **one WebSocket room server + a tiny HTTP API for pairing**, backed by SQLite.

* Implementation: **Node/TypeScript (~600–1 000 LoC)** or **Go + chi + SQLite** (copy Serein's `backend/`). Or **Cloudflare Durable Objects + Workers** if we want zero-ops (copy Termopus) — the Durable Object gives you stateful room routing for free.
* Room model: a `device_sid` identifies a desktop; the phone and the desktop are two sockets on the same room.
* Frame relay: **opaque** — forward frames, don't interpret them. (Termopus does E2E encryption so the relay literally cannot read the traffic; we can do the same with `AES-256-GCM` + a key derived from the pairing secret.)

#### C. Desktop daemon (Node/TypeScript)

```
dsh-remote/
├── src/
│   ├── agent-claude.ts   # Claude Code adapter
│   ├── agent-codex.ts    # Codex app-server adapter
│   ├── agent-opencode.ts # opencode serve adapter
│   ├── session-tail.ts   # byte-offset tail of ~/.claude/projects/**/*.jsonl
│   ├── approval.ts       # PreToolUse hook client
│   └── relay-client.ts   # dials out to the relay
└── hooks/
    └── claude-pretooluse.py  # risk classification + ask the relay
```

**Claude Code adapter** (highest value, do this first):
* Read history from `~/.claude/projects/**/*.jsonl` — **byte-offset tail with `fs.watch`** (copy `serebano/claude-code-web-client` `lib/rc-local.ts` `tailLocalFromByte()`), so the phone sees exactly what the terminal shows.
* Drive turns with the **Claude Code Agent SDK** (`query()` with `resume` / `fork`, `settingSources: ["user","project","local"]` so the real `CLAUDE.md`, settings, hooks and MCP servers load). Do **not** shell out and scrape stdout.
* **Approvals:** install a `PreToolUse` hook that classifies risk (green/yellow/red). Red → ask the relay → phone shows an approval card → hook returns allow/deny. **Fail closed**: backend down / timeout → deny. (This is Serein's model and it is the killer feature.)

**Codex adapter:** `codex app-server --listen ws://127.0.0.1:4500` (or the managed `codex app-server daemon bootstrap` Unix socket) and speak its JSON-RPC. Never expose the app-server port to the phone or the public relay. (Per `CCDawn/harmony-codex` CONFIGURATION.md and the Codex docs.)

**opencode adapter:** just proxy `opencode serve` — it already has an OpenAPI 3.1 spec, SSE events and Basic auth. We only need a thin session-id mapping.

**MiniMax Code adapter:** it speaks **ACP** (see `MiniMax-AI/minimax-code` `packages/code-acp` and the [ACP registry](https://github.com/agentclientprotocol/registry)) — `npx -y @minimax-ai/code-acp acp` launches the CLI over stdio with ACP. ACP is a much better integration surface than reverse-engineering, and it is agent-agnostic (Zed, Gemini CLI, Claude Code adapters exist).

### 4.3 Build vs. reuse

**REUSE (do not rebuild)**
| Asset | Source | Why |
|---|---|---|
| Claude Code **Agent SDK** | Anthropic | Driving/resuming/forking sessions |
| Claude Code **hooks** (`PreToolUse`) | Anthropic | Remote approvals, risk gating |
| Claude Code **session JSONL** format + byte-offset tailing | `serebano/claude-code-web-client` (`lib/rc-local.ts`) | Exact message parity, no re-parsing |
| Codex **app-server** protocol | OpenAI | Don't reimplement thread/turn/approval semantics |
| opencode **serve** OpenAPI + SSE | `anomalyco/opencode` | Already a remote-capable server |
| **ACP** | `agentclientprotocol/registry` | Agent-agnostic desktop side (MiniMax Code, Gemini CLI, …) |
| **ZcodeRemote's protocol spec** | `studyguy/ZcodeRemote` → `research/protocol.md` | The best free written spec of the exact pattern (frame format, HMAC handshake, error codes, heartbeat) |
| ArkTS WebSocket | `@kit.NetworkKit` | Don't hand-roll TLS/WSS |
| Secure credential storage | **AssetStoreKit** / **HUKS** | Hardware-backed |
| Push | **Push Kit** | The "agent is waiting" channel |
| Optional: encrypted relay | Termopus scheme (AES-256-GCM + mTLS) | If we want the relay to be a blind pipe |

**BUILD (ours)**
1. ArkTS app: pair / session list / chat / approval cards / settings — *the UI is the product; there is no open-source HarmonyOS UI to copy*.
2. The relay (small).
3. The desktop daemon + the Claude `PreToolUse` hook.
4. Push Kit integration.
5. Codex / opencode / ACP adapters.

**AVOID**
* ❌ Using HarmonyOS distributed APIs as the WAN transport (won't reach a Windows/macOS desktop; wrong shape anyway).
* ❌ Writing a SignalR client from scratch unless the backend is .NET (Corterm: 1 091 lines of ArkTS).
* ❌ Reverse-engineering a vendor's private protocol (ZcodeRemote's approach) as our *primary* strategy — it breaks on every desktop upgrade. Use it as a **reference**, and prefer official protocols (Claude Agent SDK, Codex app-server, ACP, opencode serve).
* ❌ Scraping terminal output to reconstruct history — read the session files.

### 4.4 Phasing

| Phase | Scope | Done when |
|---|---|---|
| **P0** | ArkTS app + relay + daemon; **read-only** Claude Code session list & transcript over WSS; LAN + WSS | Phone lists desktop projects/sessions and renders the transcript with terminal parity |
| **P1** | Send prompts; live streaming; **PreToolUse remote approval**; Push Kit | Phone can drive a turn and approve a red-flagged tool call from a cold start |
| **P2** | Codex adapter, opencode adapter, ACP adapter; file transfer; multi-session; E2E-encrypted relay | Multi-agent parity: Claude Code, Codex, opencode, MiniMax Code all drivable |
| **P3** | Voice input, artifacts preview, parallel task dispatch, remote desktop | TRAE-like feature parity |

### 4.5 Risks & gotchas

* **Claude Code Remote Control constraints** (if we wanted to use the official path instead of our own): requires a claude.ai **subscription**, **no API keys**, no Bedrock/Vertex/Foundry, `ANTHROPIC_BASE_URL` must be `api.anthropic.com`, and requires a trusted workspace. A self-hosted bridge has **none** of these restrictions — that is our differentiator.
* **HarmonyOS background execution** is the #1 failure mode. Budget for it up front.
* **Relay = trusted third party.** If the relay is ours, we can make it opaque/E2E-encrypted (Termopus model). If we reuse a vendor relay, we accept metadata exposure.
* **Protocol drift** if we follow ZCodeRemote's approach. Prefer the Agent SDK.
* **Duplicate-source-of-truth** (the `harmony-codex` author documents exactly this: history read from local records while task list comes from the app-server → "不能将当前版本理解为全链路单一事实源"). Pick one owner per piece of state.

---

## 5. Corrections to the brief

* **`aiondadotcom/claude-code-web` and `aiondadotcom/moltbot` do not exist** (404; not in the `AiondaDotCom` account's public repos). Live equivalents: [`siteboon/claudecodeui`](https://github.com/siteboon/claudecodeui) (now "CloudCLI", 14.2k★) and [`serebano/claude-code-web-client`](https://github.com/serebano/claude-code-web-client).
* **`coder/claudecodeui` → `siteboon/claudecodeui`; `siteboon/claudecodexui` → `siteboon/claudecodeui`** (same project, renamed).
* **`getAsterisk/claudia` → `winfunc/opcode`** (22.4k★, AGPL-3.0, **desktop GUI, not a remote client**).
* **`sst/opencode` → `anomalyco/opencode`** (219k★).
* **TRAE SOLO was renamed TRAE Work (2026-06-09); the IDE was renamed TraeCode (2026-08).** trae.ai now offers both; trae.cn is a separate mainland edition.
* **TRAE SOLO Mobile, MiniMax Agent, the Claude app and ChatGPT/Codex mobile are iOS + Android only** — no HarmonyOS package found on any official download page or store listing as of 2026-10-22. The HarmonyOS clients that exist are **unofficial community projects**.

---

## 6. Source URLs

**HarmonyOS-native (ArkTS) candidates**
* https://github.com/liznee/serein · https://www.serein.run
* https://github.com/studyguy/ZcodeRemote (protocol spec: `research/protocol.md`)
* https://github.com/CCDawn/harmony-codex
* https://github.com/monster-echo/CortexTerminal2 · https://dev.to/west_ray_2ce9b33122aea8cf/i-built-a-self-hosted-remote-terminal-that-survives-app-kills-network-switches-and-phone-sleep--nip
* https://github.com/fengnanrui/Hermes-Agent-Mobile-HarmonyOS
* https://github.com/popsiclelmlm/Hey
* https://github.com/llllliuke/ToRustDesk
* https://github.com/wkj2333666/Android-SSH-Codex
* https://github.com/ChiyuSONG/feishu-mobile-codex-skill
* https://github.com/lavamilkTeam/lavamilk.template
* https://github.com/QinpanWan/AgentHub
* https://github.com/fellow99/dsh-desktop-hos

**Reference implementations (non-HarmonyOS)**
* https://github.com/siteboon/claudecodeui · https://cloudcli.ai
* https://github.com/winfunc/opcode (was getAsterisk/claudia) · https://opcode.sh
* https://github.com/anomalyco/opencode (was sst/opencode) · https://opencode.ai
* https://github.com/Termopus/termopus
* https://github.com/serebano/claude-code-web-client
* https://github.com/agent-of-empires/agent-of-empires
* https://github.com/musistudio/claude-code-router
* https://github.com/MiniMax-AI/minimax-code · https://github.com/agentclientprotocol/registry

**Official products (the pattern to mirror)**
* https://code.claude.com/docs/en/remote-control
* https://developers.openai.com/codex/app/remote
* https://codex.danielvaughan.com/2026/05/21/codex-remote-connections-mobile-pairing-ssh-hosts-enterprise-access-tokens
* https://github.com/openai/codex/issues/31991
* https://trae.ai/blog/trae_solo_mobile_0506 · https://trae.ai/download · https://toolin.ai/blog/trae-solo-mobile-guide
* https://agent.minimax.cn/docs/code/automation/remote-control · https://agent.minimax.cn/docs/code/get-started/download
* https://play.google.com/store/apps/details?id=com.minimax.ai
* https://github.com/CodeWithBehnam/cc-docs/blob/main/claude-code-docs/remote-control.md

**OpenHarmony / HarmonyOS official APIs**
* https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-distributedservice-kit/js-apis-distributedDeviceManager.md
* https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-distributedservice-kit/js-apis-device-manager-sys.md
* https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-distributedservice-kit/js-apis-link-enhance.md
* https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkdata/js-apis-distributedKVStore.md
* https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkdata/js-apis-distributed-data.md
* https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/application-models/hop-multi-device-collaboration.md
* https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/distributedservice/devicemanager-guidelines.md
* https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/use-distributed-data-V5
