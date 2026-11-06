# Research report — open-source phone/remote clients for desktop AI coding agents

**Date:** 2026-10-22 · **For:** HarmonyOS (ArkTS/ArkUI) phone client controlling a desktop DeepSeek Harness (DSH) agent
**Method:** source-level inspection of four cloned repos + official docs. Local clones live in `D:\APP\Deepseek\research\{happy,vibetunnel,termopus}`.

> **Read this first.** Three findings dominate everything below:
> 1. **The "account" in every one of these systems is a client-held key, not a server-side user row.** The server stores a public key and opaque ciphertext. There is no email/password, no OAuth user table. If you want "account-based multi-device sync" in the Happy/Termopus sense, your account *is* a 32-byte master secret.
> 2. **All four projects pair a phone to a desktop via a QR code that carries a public key, not a session token.** The token comes *after* a key handshake.
> 3. **None of them use push the way you might assume.** Happy = Expo/FCM+APNs via a relay; VibeTunnel = **Web Push with VAPID** (fully self-hosted, no store); Termopus = FCM (optional); Remodex = APNs behind an optional push service.

---

## 1. Project landscape

| Project | Repo | Stack | What it controls | Pairing | Self-hostable | License |
|---|---|---|---|---|---|---|
| **Happy Coder** ("Happy Harness") | [slopus/happy](https://github.com/slopus/happy) | TS/React-Native (Expo) iOS+Android+web app · TS Node relay server (Prisma/Postgres, Socket.IO) · TS CLI (`npm i -g happy`) · separate repos `happy-desktop`, `happy-agent` | Claude Code, OpenAI Codex and Grok sessions running on **your own machines**; multi-provider; "natively multiplayer" | **QR** (`happy://terminal?<base64url pubkey>` printed by CLI) · web OAuth · manual 35-char Base32 secret | **Yes** — `packages/happy-server-self-host` ships a bundled server with **embedded PGlite**: no Postgres, no Redis, no S3. (`happy server` / `happy-server serve`) | **MIT** |
| **VibeTunnel** | [amantus-ai/vibetunnel](https://github.com/amantus-ai/vibetunnel) | TS Node server + **Lit** web front-end + ghostty-web terminal · native Swift macOS menu-bar app | Any terminal session (Claude Code, Codex, dev servers); session recording; git follow mode | **URL + JWT**, not QR: system auth (macOS/PAM), SSH Ed25519 key, username/password env, Tailscale identity, or `--no-auth` | **Yes**, fully (Docker/npm/macOS app) | **MIT** |
| **Termopus** | [Termopus/termopus](https://github.com/Termopus/termopus) | **Flutter** phone app (iOS/Android) · **Rust** bridge binary (macOS/Win/Linux) · **Cloudflare Workers + Durable Object** relay · CF provisioning API for mTLS device certs | Claude Code only. Approve edits, review diffs, chat | **QR** shown by the Rust bridge | **Yes** — deploy into your own Cloudflare account | **AGPL-3.0** ⚠️ |
| **Remodex / Dex** | [emanuele-web04/remodex](https://github.com/emanuele-web04/remodex) · [MRL-00/Dex](https://github.com/MRL-00/Dex) | Node bridge on the Mac (spawns `codex app-server`, speaks JSON-RPC) · native **Swift iOS** app · self-hostable WS relay | OpenAI Codex CLI **and** Codex.app threads | **QR** one-time bootstrap → "trusted Mac" that can auto-reconnect | **Yes** — `REMODEX_RELAY` points at your own relay; Tailscale recommended | **Apache-2.0** |
| *Claude Code Remote Control* (official) | [docs.anthropic.com/en/docs/claude-code/remote-control](https://docs.anthropic.com/en/docs/claude-code/remote-control) | Closed-source app + service | Local Claude Code sessions (via `claude remote-control`) | claude.ai account + **QR / session URL** | No (cloud service) | Proprietary |
| *Codex in ChatGPT mobile* (official) | [openai.com/index/work-with-codex-from-anywhere](https://openai.com/index/work-with-codex-from-anywhere) · [developers.openai.com/codex/remote-connections](https://developers.openai.com/codex/remote-connections) | Closed-source | Codex threads on your laptops/devboxes/remote envs | ChatGPT account + "secure relay layer" | No | Proprietary (the Codex **CLI** repo is open) |
| *Cursor for iOS* (official) | [cursor.com/docs/cloud-agent/mobile](https://cursor.com/docs/cloud-agent/mobile) | Closed-source | Cursor cloud + local agents | Cursor account (SSO) | No | Proprietary |

**Honesty notes.**
- I could not fetch `developers.openai.com/codex/remote-connections` directly (HTTP 403 both times), so the Codex-relay description above comes from OpenAI's own marketing page and the Codex mobile docs I surfaced via search. Treat the relay internals as unverified.
- `packages/happy-server` is described by Happy's own `happy-server-self-host/README.md` as **private** ("the server source lives there"); only the self-host *shell* is published. So Happy's backend source is **not** fully open-source today, even though the mobile app is MIT.
- Termopus is **AGPL-3.0** — copying *code* from it would infect your project. Copying *ideas* is fine.
- Remodex's own README states: *"public GitHub/source checkouts stay open-source and self-host friendly, so they do not ship with a hosted relay baked in"* — i.e. the published npm package may embed a default relay. Source checkouts don't.

---

## 2. Detailed mobile UI/UX — the three most relevant projects

### 2.1 Happy Coder (most relevant; MIT, and it is the closest thing to "agent-first" mobile UI)

Source: `packages/happy-app/sources/`. Screenshots (1080×1920, official store assets):
- `01-models.png` → https://raw.githubusercontent.com/slopus/happy/main/packages/happy-app/marketing/google-play/en-US/phone/01-models.png
- `02-sessions.png` → https://raw.githubusercontent.com/slopus/happy/main/packages/happy-app/marketing/google-play/en-US/phone/02-sessions.png
- `04-multiplayer.png` → https://raw.githubusercontent.com/slopus/happy/main/packages/happy-app/marketing/google-play/en-US/phone/04-multiplayer.png
- iPad set: https://github.com/slopus/happy/tree/main/packages/happy-app/marketing/app-store/en-US/ipad
- Landing page: https://happy.engineering/ · Docs: https://happy.engineering/welcome/

**Navigation pattern.** Bottom-tab app (`MainView.tsx` → `variant="phone"`), **3 tabs**, declared as `TAB_TITLES = { sessions, inbox, settings }` (`MainView.tsx:138-142`). `sessions` is home; `inbox` is a notification/approval inbox; `settings` holds account/appearance/agents/usage/voice. *Inbox* as a separate tab is a pattern worth stealing — it isolates "the agent needs you" from "the agent is talking".
On tablets the same `MainView` switches to `variant="sidebar"` (`EmptySessionsTablet`, `SidebarNavigator`, `SidebarView`), so the phone is a deliberate narrow variant of one shared component tree — exactly the ArkUI `Navigation`/`Tabs` split you want.

**Screen A — Sessions list (`02-sessions.png`).**
- Background is near-black in dark mode; the list paints **one continuous column on the page background** with a hairline divider under each row — *no cards*. This is an explicit design decision, documented in `FlatSessionRow.tsx:37-39`: *"The single colour the flat list paints, rows and page alike, so nothing reads as a card sitting on a backdrop."*
- Header: a **grid icon on the left**, the title **"Sessions" centred**, a **gear on the right**, with a hairline rule under the header. The gear is a *segmented pill* — a `NativeSettingsMenu` (filter/grouping) and a separate settings button separated by a 1px vertical divider (`MainView.tsx:128-134`).
- Row geometry (`FlatSessionRow.tsx:280-419`), which you can lift verbatim into ArkUI:
  - padding-left **16**, padding-right **16**, padding-vertical **10**; `alignItems: 'center'`
  - avatar **60×60**, circular, margin-right **12**; the avatar is **vertically centred**, not top-aligned, so it lines up with the 3 text lines like a chat list
  - title: **17px / line-height 22 / semibold**
  - project line: **15px / line-height 20 / secondary colour**
  - workspace+worktree line: **13px / line-height 18**, with a small git-branch glyph and a `+N` unread badge on the right
  - timestamp right-aligned: **13px / line-height 22**, `fontVariant: tabular-nums` (so digits don't jitter), in a **fixed 56dp slot** so an unread dot can overlay it without reflow (`FlatSessionRow.tsx:335-356`)
  - divider: **1px hairline**, but starting at `16 + 60 + 12 = 88dp` (i.e. it starts *after* the avatar column) and running to the screen edge
  - unread state: **not greyed out** — the row keeps its own colour and is merely dimmed (opacity 0.45 for pending user messages, 0.5/0.6 for archived/offline-machine rows). Comment at `FlatSessionRow.tsx:64-67`: *"A session idle since yesterday on a machine that is still up is ordinary work you can pick back up, and drawing it as dead makes a healthy list look like a graveyard."*
- **Grouping toggle in the header**: the grid icon opens a native menu with *flat list* vs *group by project* (`SESSION_LIST_GROUPING_MODES`, `MainView.tsx:156-185`). One tap, no separate screen.
- Bottom: a **floating pill composer** — rounded, spanning the width, placeholder *"Plan, ask, build…"*, with a **circular up-arrow send button** overlapping its right end, and a translucent backdrop behind it so list content scrolls under it.

**Screen B — Session/chat (`04-multiplayer.png`).**
- Header: **back chevron**, session title (left-aligned, semibold, truncating), and the **session avatar with a small overlay glyph** on the far right.
- **Assistant messages have NO bubble** — plain left-aligned text directly on the background, with `marginHorizontal: 16`, `marginVertical: 10`, `borderRadius: 16` (`MessageView.tsx:459-466`).
- **User/collaborator messages DO have a bubble**: radius **16 on three corners, 4 on the corner nearest the sender** — a classic messenger "tail" (`MessageView.tsx:494-499` for the "other participant" case).
- Collaborator messages carry a **name label above the bubble** in semibold 14px (`MessageView.tsx:500-508`), so a multiplayer session reads as a group chat.
- A **copy icon (outline, 20px)** sits under each message, aligned to the text's left edge, with `hitSlop` for the touch target (`MessageView.tsx:467-479`).
- **Streaming / status** is a single small line in `agentEventText` colour, 14px, centred, `paddingVertical: 8` (`MessageView.tsx:529-536`).
- **Composer**: a large rounded card. Top line is the text field ("Type a message …"). Bottom row inside the card: a **`+` button** (left), the **permission mode** ("Auto"), the **model + effort** ("GPT-5.6 Sol · Medium"), and a **voice/waveform button** on the right. Immediately above the composer: a **`● online` status dot + label** in green. This is the single most important thing to copy — it mirrors the DSH desktop composer almost exactly (see §4).
- **Model picker** (`01-models.png`): a bottom sheet, `MODEL` header, then **provider sections** ("OpenAI Codex", "Anthropic Claude", "xAI Grok") each with radio rows: a **radio circle + provider glyph + model name** on line 1, **provider name in secondary text** on line 2. Selected row gets a raised `#2A2A2E` background and a **blue radio**; unselected radios are hollow grey.

**Tool-call rendering (`components/tools/`).** This is where Happy most directly answers your "collapsed tool blocks" question:
- A tool call renders as a **compact one-line row**, not a card, by default (`ToolView.tsx:332-336` `compactContainer` / `inlineContainer`: `backgroundColor: 'transparent'`, `marginVertical: 2`).
- Row shape: 20×20 icon container, gap **10**, activity text **15px / line-height 20 / secondary colour**, a trailing status icon, and on the far right an **elapsed-time chip** (`13px`, monospace) while the tool is running (`ToolView.tsx:342-421`).
- Status icons are deliberately sparse (`ToolView.tsx:144-175`):
  - running → a small `ActivityIndicator` scaled to 0.8
  - completed → **nothing** (the green check is commented out — a completed tool just stops animating)
  - error → `alert-circle-outline` in the warning colour
  - denied/cancelled → `remove-circle-outline` in secondary
- The **full** (non-compact) form is a card: `surfaceHigh` background, radius **8**, margin-vertical **8**, header padding **12** on `surfaceHighest`, content padding-horizontal **12** / padding-top **8** (`ToolView.tsx:325-420`).
- Section titles inside a tool card are **uppercase, 13px, weight 600, secondary colour** (`ToolSectionView.tsx:38-47`).
- The tool **title** is a single non-interactive, single-line, middle-ellipsised nav title, 16px semibold in the header tint — it doubles as the screen title so the top of the session screen never changes (`ToolHeader.tsx`).
- Permission prompts render a dedicated **`PermissionFooter`** component (`components/tools/PermissionFooter.tsx`, 25KB) — Allow / Deny / Edit-allow-all as pill buttons coloured by the theme's `permissionButton` tokens (green allow, red deny, blue allow-all, grey inactive).

**Design tokens (`packages/happy-app/sources/theme.ts` + `constants/Typography.ts`) — the palette you'd adapt:**
- **Type**: `IBM Plex Sans` (regular/italic/semibold) for UI text, `IBM Plex Mono` for code, `Bricolage Grotesque` for the logo only. Weights 400 / 600 / 700.
- **Spacing scale**: 4 / 8 / 12 / 16 / 20 / 24.
- **Radii**: 4 / 8 / 10 / 12 / 16.
- **Icon sizes**: 12 / 16 / 20 / 24.
- **Light**: bg `#F2F2F7` (grouped, iOS) or `#F5F5F5`; surface `#FFFFFF`; surfaceHigh `#F8F8F8`; surfaceHighest `#f0f0f0`; divider `#eaeaea`; text `#000000`; textSecondary `#49454F`; **user bubble `#f0eee6`** (a warm off-white, *not* blue).
- **Dark**: system dark; glass tokens `rgba(255,255,255,0.68)` etc. with a `backdrop` of **plain black** and **transparent glows** (the comment at `theme.ts:72-75` explains: *"Plain white, mirroring the dark theme's plain black: the tinted gradient + colored glows read as a stain behind white surfaces."* — a real lesson).
- **Semantic**: status connected `#34C759`, connecting `#007AFF`, error `#FF3B30`. Permission modes: default `#8E8E93`, acceptEdits `#007AFF`, bypass `#FF9500`, plan `#34C759`, readOnly `#8B8B8D`, yolo `#DC143C`.
- **Diff palette** is GitHub-derived: addedBg `#E6FFED` / addedBorder `#34D058`, removedBg `#FFEEF0` / removedBorder `#D73A49`, hunkHeaderBg `#F1F8FF`, inline added `#ACFFA6` / `#0A3F0A`, inline removed `#FFCECB` / `#5A0A05`, plus a full Shiki-style syntax palette.

**Onboarding / pairing UI** (`components/onboarding/`, `app/(app)/restore/`):
- First run with an account but **no linked machine** → a dedicated **`OnboardingLinkComputer`** screen (not an empty list). The code comment in `app/(app)/index.tsx:33-36` states the rationale: *"Until a computer is linked there is nothing for the home chrome to do: the dock, filters, session list, and tablet sidebar all need a machine."*
- If not authenticated: `OnboardingScreen` with a `WelcomeContent` block, **one filled primary button** ("Create account") and **one quiet text button** underneath ("Restore existing"). On web the primary/secondary swap (mobile is the primary path, web restores from a phone).
- Restore-by-QR: the new device **shows** a QR (`happy:///account?<base64url pubkey>`) that the *existing* phone scans; a 260dp QR on a white rounded card (radius 16) inside a `surfaceHigh` placeholder; a "use key instead" button routes to `/restore/manual` for the 35-char Base32 code.

---

### 2.2 Termopus (Flutter; the closest to a *chat-first* mobile client)

Repo: [Termopus/termopus](https://github.com/Termopus/termopus) · Screenshots: `assets/screenshots/{onboarding.jpg,chat.png,demo.gif,demo2.gif}` → https://raw.githubusercontent.com/Termopus/termopus/main/assets/screenshots/chat.png

**Screens** (`app/lib/features/`): `onboarding/` (onboarding_screen, biometric_setup, provisioning_screen), `pairing/` (qr_scanner_screen, pairing_progress, pairing_success), `sessions/` (sessions_list_screen, session_card), `chat/` (chat_screen + widgets), `settings/`.

**Chat screen** (`features/chat/chat_screen.dart`, 55KB) with widgets:
`message_list.dart` · `message_bubble.dart` · `tool_use_card.dart` · `diff_view.dart` · `code_block.dart` · `input_bar.dart` · `model_selector.dart` · `slash_command_picker.dart` · `ask_question_card.dart` · `active_agents_bar.dart` · `task_progress_bar.dart` · `file_transfer_bar.dart` · `browser_view.dart`.

**Bubble model** (`message_bubble.dart:132-178`) — a deliberate **"Smart mode" vs "Terminal mode"** switch:
- Smart mode = **WhatsApp layout**: user bubble right, agent bubble left, radius **16 on three corners / 4 on the tail corner**, `maxWidth: rChatBubbleMaxWidth`, horizontal padding `rHorizontalPadding * 1.15`, vertical `rSpacing * 1.25`. Long-press copies with a 1-second SnackBar "Copied to clipboard".
- Terminal mode = no bubbles; a small **role label + icon** above each message instead (`_terminalLabel` / `_terminalIcon` at `message_bubble.dart:181-220`): "You", "Claude", "Output", "Thinking", "Code", "Changes", "Permission Required", "Question", "Agent".
- Message types are a clean enum: `claudeResponse`, `text`, `thinking`, `toolUse`, `code`, `diff`, `action`, `askQuestion`, `subagentEvent`. **Copy this enum** — it maps 1:1 onto a DSH transcript.
- Timestamps live **inside** the bubble, right-aligned, 10–12px muted, with a **`schedule` icon** for a queued (not-yet-sent) message.

**Tool card** (`tool_use_card.dart`) — collapsible, WhatsApp-ish:
- Container `Color(0xFF161825)`, radius **12**, a header row (icon in a radius-8 rounded square, title, subtitle) and a chevron that expands into a **body**. Body content is **per-tool**: `_EditBody`, `_BashBody`, `_WriteBody`, `_ReadBody`, `_TaskBody` (Create/Update/List/Get). `_WriteBody`/`_ReadBody` use a `Color(0xFF23241F)` code panel with monospace 11–13px and a muted file-path row.
- Status icons: `Icons.error_outline` red on error, `Icons.check_circle` green on success, muted chevron otherwise.

**Theme** (`shared/theme.dart`) — **dark-only**, brand-derived:
- bg `#0D0D1A`, surface `#1A1B2E`, surfaceLight `#252640`, surfaceElevated `#2D2E4A`
- primary `#7DD3FC` (sky), primaryLight `#A5E4FC`, accent `#9D8CFF` (violet), brandCyan `#67E8F9`, brandPurple `#8B7CF6`
- text `#F8FAFC`, secondary `#B8C0D0`, muted `#6B7280`, divider `#374151`
- bubbles: agent `#1E1F35`, **user `#3B82F6` (blue)**, system `#252640`
- diff: add `#166534`, remove `#991B1B`
- Type scale: headline 24/600/-0.3, titleLarge 20/600, titleMedium 16/500, bodyLarge 16/1.5, bodyMedium 14/1.5, bodySmall 12/1.4
- Gradients: `primaryGradient` (#7DD3FC→#67E8F9), `accentGradient` (#8B7CF6→#A78BFA), `brandGradient` (#67E8F9→#8B7CF6)

> ⚠️ **Termopus's blue user bubble is exactly the "looks nothing like the desktop app" problem.** DSH's user bubble is `#2C2C2E` (a neutral raised surface), not blue. Termopus is a good structural reference (message-type enum, per-tool bodies, collapsible cards) but a **bad palette reference** for you. Happy's warm-neutral `#f0eee6` user bubble is closer in spirit to DSH.

### 2.3 VibeTunnel (web-first; relevant for auth + push, not for chat UI)

Repo: [amantus-ai/vibetunnel](https://github.com/amantus-ai/vibetunnel) · Docs: https://docs.vibetunnel.sh · Live demo: https://vt.sh

- **Front-end is Lit + ghostty-web**, not React. Components in `web/src/client/components/`: `session-list.ts`, `session-card.ts`, `compact-session-card.ts`, `repository-header.ts`, `session-view.ts`, `mobile-action-bar.ts`, `terminal-chat-view.ts`, `auth-login.ts`, `auth-quick-keys.ts`, `settings.ts`, `file-browser.ts`, `monaco-editor.ts`.
- **Mobile adaptation** is via `mobile-action-bar.ts` (a bottom action bar with a **virtual keyboard toggle** and quick keys) plus `quick-keys.ts` / `auth-quick-keys.ts` — a **saved "quick keys" palette** you tap to send common commands without the OS keyboard. That is a genuinely good mobile-native pattern for a terminal-like client.
- `terminal-chat-view.ts` is a **terminal/chat hybrid view**: the same session renders as a chat when the agent emits chat events and as a raw terminal otherwise.
- **Session cards carry activity state**: `sessionActivity.ts` drives active/idle; the README documents *"Session Activity Indicators — Real-time activity tracking shows which sessions are active or idle"* and titles modes (`static` = path + command, `filter` = block app title changes, `none`).
- Server↔browser sync is **WebSocket** (`terminal-socket-client.ts`), with `server-event-service.ts` for server→client events and `session-service.ts` / `api-client.ts` for REST.

---

## 3. Account + multi-device sync architecture (the core of your question)

### 3.1 Happy Coder — the most complete reference

**Entities** (`packages/happy-server/prisma/schema.prisma`, Postgres via Prisma):

| Model | Purpose | Notable fields |
|---|---|---|
| `Account` | the "user" | `id` (cuid), **`publicKey` (unique)**, `seq`, `feedSeq`, `settings` + `settingsVersion`, `username`, `avatar` (Json) |
| `Machine` | a linked desktop | `id`, `accountId`, **`metadata`** (encrypted static info), **`daemonState`** (encrypted dynamic state), `metadataVersion`, `daemonStateVersion`, `dataEncryptionKey`, `seq`, `active`, `lastActiveAt` — `@@unique([accountId, id])` |
| `Session` | an agent session | `id`, `tag`, `accountId`, `projectId`, `metadata`, `agentState`, `metadataVersion`, `agentStateVersion`, **`dataEncryptionKey`**, `seq`, `active`, `lastActiveAt` — `@@unique([accountId, tag])` |
| `SessionMessage` | one message | `id`, `sessionId`, `localId`, `seq`, `content` (Json), `@@unique([sessionId, localId])` |
| `AccountPushToken` | a registered push target | `token`, `@@unique([accountId, token])` |
| `AccountAuthRequest` / `TerminalAuthRequest` | pending pairings | `publicKey` (unique), `response`, `responseAccountId` |
| `Project` | a workspace/group of sessions | `externalId`, `metadata`, `dataEncryptionKey`, `avatarRef` |
| `Artifact`, `UploadedFile`, `AccessKey`, `UserKVStore`, `UserFeedItem`, `UserRelationship`, `ServiceAccountToken`, `UsageReport`, `GithubUser` | supporting entities | `UserKVStore` is an **encrypted generic KV per account** (`key` plaintext for indexing, `value` encrypted) |

**Auth flow (the important bit).** There is **no email, no password, no OAuth user table**. The account *is* a 32-byte master secret held only by clients; the server knows only the corresponding public key.

1. **CLI** (`packages/happy-cli/src/ui/auth.ts`): `happy auth login` → generates an ephemeral 32-byte secret → `crypto_box` keypair → `POST /v1/auth/request { publicKey, supportsV2: true }` → prints a **terminal QR** of `happy://terminal?<base64url publicKey>` (`qrcode-terminal`, `src/ui/qrcode.ts`).
2. **Phone**: scans the QR, generates its own `crypto_box` keypair (`authQRStart.ts`), `POST /v1/auth/account/request { publicKey }`, then **polls the same endpoint every 1s** (`authQRWait.ts`) until `state === 'authorized'`.
3. **CLI** polls `GET /v1/auth/request/status?publicKey=…` (`authApprove.ts`); on `pending` it `POST /v1/auth/response { publicKey, response }` with the **master secret encrypted to the phone's public key** (`encryptBox`, versioned V1/V2 via `supportsV2`).
4. **Phone** receives `{ state: 'authorized', token, response }`, **decrypts** the master secret with its own secret key, and calls `auth.login(token, base64url(secret))`.
5. Credentials are stored in **expo-secure-store** (`tokenStorage.ts`, `AUTH_KEY`, with a `localStorage` fallback on web) — the token on iOS/Android is the Keychain/Keystore-backed store, *not* AsyncStorage.
6. `AuthContext.login()` → `syncCreate(credentials)` → the whole sync engine starts.

**The alternative "create account" path** (`app/(app)/index.tsx` → `authGetToken.ts`): the phone generates 32 random bytes itself, calls `authChallenge(secret)` (Ed25519 `crypto_sign_detached` over a random 32-byte challenge), and `POST /v1/auth` with `{ challenge, signature, publicKey }`. The server returns a token; the secret never leaves the phone. **This is a stateless, zero-KYC "account"** — the closest thing to what you could ship without a user database.

**Restore / second device** (`app/(app)/restore/index.tsx` + `secretKeyBackup.ts`): the new phone **shows** a QR (`happy:///account?<pubkey>`) for an existing phone to scan, *or* the user types a **35-character Base32 code** (`XXXXX-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`, RFC-4648 alphabet minus confusables, with `0→O`, `1→I`, `8→B`, `9→G` normalisation). Both deliver the same 32-byte master secret. **This is the single best "account = key" UX in the whole set, and it maps perfectly onto HarmonyOS.**

**Encryption model** (`sources/sync/encryption/encryption.ts` + `sources/encryption/`):
- Root: `deriveKey(masterSecret, usage, path[])` — an **HMAC-SHA512 based key tree** (BIP32-style), with separate usage roots `'Happy EnCoder'` (content), `'Happy Coder'` (analytics), `'Happy Blobs'` (legacy blobs). `deriveKey.ts` also carries a great warning comment about `subarray` vs `slice` and libsodium key-length validation.
- **Content keypair**: `crypto_box_seed_keypair(deriveKey(master,'Happy EnCoder',['content']))` — this keypair encrypts *per-session data keys*.
- **Per-session**: `Session.dataEncryptionKey` is stored wrapped with the content public key (version byte `0` prefix), and the session body is encrypted with **AES-256-GCM** (`aes.ts`, `AES256Encryption`).
- **Legacy sessions** (no per-session key) fall back to `SecretBoxEncryption(masterSecret)` (XSalsa20-Poly1305).
- **Machines**: separate `MachineEncryption` with its own per-machine `dataEncryptionKey`; machine `metadata` and `daemonState` are encrypted blobs.
- Primitives: **TweetNaCl** (`libsodium.lib.ts`, `crypto_box`, `crypto_sign`, `crypto_secretbox`) + **libsodium native TurboModule** on iOS + a pure-JS web fallback. The App Store copy claims *"the same encryption as Signal (TweetNaCl)"*.
- **Anonymous analytics ID**: `deriveKey(master,'Happy Coder',['analytics','id'])` truncated to 16 hex chars — so even analytics IDs are unlinkable to the server.

**Transport / event model.**
- **Socket.IO** (`sources/sync/apiSocket.ts`, server `sources/app/api/socket.ts`). Rooms are namespaced per account:
  - `user:{userId}` — all authenticated connections for the account
  - `user:{userId}:user-scoped` — **UI clients only** (phones, web)
  - `user:{userId}:session:{sessionId}` — watchers of one session
  - `user:{userId}:machine:{machineId}` — a specific machine's daemon
- Two server→client event names only: **`update`** (durable, sequenced) and **`ephemeral`** (transient). `eventRouter.ts` builds typed payloads: `new-message`, `new-session`, `update-session`, `new-machine`, `update-machine`, `delete-machine`, `new-project`, `update-project`, `delete-project`, `new-artifact`, `update-artifact`, `delete-artifact`, `delete-session`, `update-account`, `relationship-updated`, `new-feed-post`, `kv-batch-update`, `activity`, `machine-activity`, `usage`, `machine-status`, `session-event`.
- **Recipient filters** (`eventRouter.ts:44-48`): `all-user-authenticated-connections`, `user-scoped-only`, `all-interested-in-session` (union of session-room + user-scoped), `machine-scoped-only`.
- **Durable updates are versioned**, e.g. `UpdateSessionBody = { t:'update-session', id, metadata: {version, value}, agentState: {version, value}|null }` — so a client can tell "unchanged" from "changed" and from "deleted". Same pattern on `SessionMessage` (`seq`, `localId`, `@@unique([sessionId, localId])` for idempotent re-sends).
- **Client→server socket events**: `session-subscribe` / `session-unsubscribe`, `message`, `session-alive`, `session-end`, `update-metadata`, `update-state`, `machine-alive`, `machine-update-metadata`, `machine-update-state`, `access-key-get`, `artifact-read/update/create/delete`, `usage-report`, `ping`, `app-state`, and an **RPC** subsystem (`rpc-register` / `rpc-call` / `rpc-unregister`).
- **REST surface** (from `routes/*.ts`): `/v1/auth*`, `/v1/account/{profile,settings}`, `/v1/sessions` (+ `/v2/sessions`, `/v2/sessions/active`), `/v1/sessions/:id/messages`, `/v3/sessions/:id/messages`, `/v1/machines`, `/v1/projects`, `/v1/kv` (+`/bulk`), `/v1/push-tokens`, `/v1/sessions/:id/push-event`, `/v1/artifacts`, `/v1/access-keys/:sessionId/:machineId`, `/v1/attachments`, `/v1/friends`, `/v1/feed`, `/v1/usage/query`, `/v1/voice/*`, `/v1/connect/:vendor/*` (GitHub + provider tokens).
- **Shared wire protocol** lives in `packages/happy-wire` (zod schemas) — `SessionMessageContent = { c: string, t: 'encrypted' }`, `SessionProtocolMessage = { role:'session', content: envelope, meta? }`. **The `happy-wire` package is a separate, small, MIT module you can read as a protocol design reference even if you never use the code.**

**Push.**
- Client: `expo-notifications` → `pushRegistration.ts` → `POST /v1/push-tokens { token }` (Bearer token). `GET /v1/push-tokens` lists them, `DELETE /v1/push-tokens/:token` removes one. On **logout**, `AuthContext.logout()` **unregisters the push token first**, then clears persistence.
- Server: `AccountPushToken` rows, `POST /v1/sessions/:sessionId/push-event` to fire one, `pushDispatch.ts` + `pushSend.ts` (batched tickets, 15s budget), and **`focusTracker.ts`**.
- **The best idea in the whole codebase** is in `eventRouter.ts:300-327`, `hasActiveUiClient()`:
  > *"Returns true if the user is demonstrably looking at a Happy UI client right now. Used to suppress a push they would only find redundant. Both conditions are deliberately positive — presence must be proven, not assumed. The costs are asymmetric: a redundant push is a buzz the user dismisses, while a missed push leaves an agent blocked on a permission prompt with nobody watching."*
  > It only counts `clientType === 'user-scoped'` sockets (a running session's own socket must **not** suppress the push that session is asking for) and only when `appState === 'active'`. It fails **open** on infrastructure errors.
  **Steal this.** DSH's phone client must not fire a HarmonyOS Push Kit notification when the user is already looking at the session.

**Offline / reconnect.**
- The server is the **source of truth for ordering** (`seq` on Account/Session/Machine/SessionMessage), and every durable entity carries a **version** + `updatedAt`. Clients keep a local store (`sources/sync/storage.ts`, `persistence.ts`) and re-sync on reconnect.
- **Offline history is real**: the App Store copy promises *"Access conversation history even when your terminal is offline"* — because messages are persisted server-side, not just streamed.
- `sessionMessagePreloader.ts` pre-fetches a session's messages when you tap into it, so the transcript is there before the socket catches up.
- `sync.ts` maintains **separate `InvalidateSync` lanes** (`settingsSync`, `profileSync`, `purchasesSync`, `machinesSync`, `pushTokenSync`, `nativeUpdateSync`, `artifactsSync`, `friendsSync`, `friendRequestsSync`, `feedSync`) plus an `ActivityUpdateAccumulator` that **batches** high-frequency activity events instead of emitting one per token. It also watches `AppState` to flush on background, and re-syncs the push token when the app returns.
- **`controlHandoff.ts`** — the "who is driving" concept: when two devices both send, the server decides the control direction.

### 3.2 Termopus — mTLS device identity + opaque relay

```
COMPUTER                CLOUDFLARE               PHONE
Claude Code                                  Flutter App
   ↓                                            ↓
Bridge (Rust) ←── WebSocket ──→ Relay DO ←── WebSocket ──→ Native WS
   ↓                        (opaque)                ↓
Encrypt(msg)                                Decrypt(msg)
```
- **Relay = Cloudflare Durable Object**: stateful WebSocket relay that forwards **opaque blobs only**. The relay never sees plaintext.
- **Provisioning API = Cloudflare Workers**: issues **device certificates**; a **CA** is generated at install time and stored as a Worker secret (`setup.sh` → "Generate a CA certificate for mTLS device authentication", "Set CA secrets on both workers").
- **KV namespaces**: `FCM_TOKENS`, `PROVISIONED_DEVICES`, `SUBSCRIPTIONS` — i.e. per-device registration rows and push subscriptions.
- **Crypto**: AES-256-GCM with **hardware-backed keys** (Keystore/Keychain) + biometric unlock (`biometric_lock_screen.dart`, `security_channel.dart`, `core/services/security_service.dart`). `cert_renewal_provider.dart` handles certificate rotation.
- **Pairing**: the Rust bridge prints a QR; the app scans it (`qr_scanner_screen.dart` → `pairing_progress.dart` → `pairing_success.dart`).
- **Push**: optional FCM; `FCM_TOKENS` KV holds the tokens; `push_handler.dart` on the app side.
- **Chat transport**: `chat_provider.dart` (84KB) holds message state; `active_agents_provider.dart`, `active_tasks_provider.dart`, `live_state_provider.dart` are separate providers so the UI can show *per-agent* activity without touching the chat state.

### 3.3 Remodex — "trusted Mac" + self-hosted relay (the most relevant to your LAN/relay setup)

- `remodex up` on the Mac spawns `codex app-server` and speaks **JSON-RPC** to it. The bridge is the trust boundary: the phone never touches the Codex process.
- **QR bootstrap → trusted session**: the CLI prints a QR for first-time pairing or recovery; after the handshake the iPhone "resolves the Mac's live session through the configured relay and reconnects automatically" — the Mac is remembered as *trusted*, so later connections don't need a second scan.
- **macOS `launchd`** background service keeps the bridge alive for hands-free reconnects (other OSes use the foreground bridge flow).
- **Relay**: plain WebSocket, `ws://host:port/relay` or `wss://…/relay`, reverse-proxy friendly (`/remodex` subpath stripping). `REMODEX_RELAY` is the single override; source checkouts ship **no default relay**.
- **Push**: optional `REMODEX_PUSH_SERVICE_URL` with endpoints `/v1/push/session/register-device` and `/v1/push/session/notify-completion` (APNs behind your own service).
- **Resilience**: exponential backoff reconnect (1s → 5s), a **bounded local outbound buffer** that re-sends missed encrypted messages after a secure reconnect, Codex process kept alive across transient drops, clean SIGINT/SIGTERM shutdown. **This "buffer + replay" pattern is exactly what your byte-pipe relay needs.**
- **Limitation honestly stated in its own README**: *"Codex.app does not act like a second live subscriber to the active run by default… True phone-to-desktop live sync in the Codex.app GUI is not supported today."* — and it ships an explicit **hand-off button** in the phone app to continue the chat on the Mac. **The hand-off concept is worth copying:** rather than pretending two UIs are live-synced, let the phone hand the conversation to the desktop explicitly.
- Conversation persistence: Codex writes **JSONL rollout files** under `~/.codex/sessions`, so phone-started threads appear in Codex.app. Same idea as DSH's session list.

### 3.4 VibeTunnel — self-hosted auth + Web Push (the only fully store-independent push in the set)

- **Auth modes**: system auth (macOS local accounts / Linux PAM), `VIBETUNNEL_USERNAME`/`VIBETUNNEL_PASSWORD`, **SSH Ed25519 key** auth against `~/.ssh/authorized_keys` (browser SSH agent via WebCrypto — `BrowserSSHAgent`), Tailscale identity, `--no-auth`, and a dev-only `--allow-local-bypass` (localhost bypass that rejects `X-Forwarded-For` header injection).
- **JWT**: signing key generated once at `~/.vibetunnel/jwt-secret` with owner-only perms, so browser sessions survive restarts; `JWT_SECRET` for operator-managed secrets; rotating either **logs clients out**.
- **Challenge–response**: `AuthClient.createChallenge(userId)` → sign with the SSH key → `POST /api/auth/ssh-key { challengeId, publicKey, signature }` → `{ success, token, userId }`. **The same challenge–response shape as Happy's `/v1/auth`.**
- **Push = Web Push with VAPID** (`web/src/client/services/push-notification-service.ts`): `navigator.serviceWorker.register('/sw.js')` → `pushManager.getSubscription()` → `pushManager.subscribe({ userVisibleOnly:true, applicationServerKey: vapidKey })` → the subscription is POSTed to the server; the server holds the **VAPID private key** and pushes directly to FCM/APNs/Mozilla endpoints. **No app store, no Firebase project, fully self-hosted.**
- **`autoResubscribe()`** on every load: if permission was granted but the subscription is gone, re-subscribe silently; on success show a *"VibeTunnel Notifications Active"* welcome notification.
- A **notification preference set** (`NotificationPreferences`, `DEFAULT_` and `RECOMMENDED_` presets) lives in `web/src/types/config.ts` — per-category opt-in.

---

## 4. What the DSH desktop actually looks like (so the phone can match it)

I opened the running DSH Web GUI (`http://127.0.0.1:10748`) and sampled computed styles. **Your `Theme.ets` already matches the palette** — the gap is *structure*, not colour.

**Tokens sampled live from the running app:**
- `--dsw-font-family`: `-apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Helvetica Neue", Helvetica, Arial, sans-serif`
- `--dsh-font-family-code-default`: `"SF Mono", "JetBrains Mono", "Fira Code", Consolas, "Liberation Mono", Menlo, Courier, "PingFang SC", "Microsoft YaHei"`
- `--dsw-font-family-brand`: `"Montserrat", …`
- `--dsw-radius-xs/sm/md/lg/xl/panel`: **4 / 8 / 12 / 16 / 20 / 28**
- `--dsm-radius-s/m/l`: **4 / 8 / 12**
- `--ds-transition-duration-fast/base/slow`: **.1s / .2s / .3s**; `--ds-ease-in-out`: `cubic-bezier(.4, 0, .2, 1)`
- `--dsw-corner-shape`: `superellipse(1.5)`
- body bg **`#151517`**, text **`#F9FAFB`**, surface **`#1B1B1C`**, muted text **`#ADB2B8`**, secondary **`#CFD3D6`**
- **role colours** (trajectory badges, 10px, weight **650**):
  - **工具 (tool)** `#DD8629` (amber) — *note: your `Theme.ets` currently has `TOOL: '#C084FC'`, a purple. The desktop uses **amber** for tools and **violet** for the assistant.*
  - **助手 (assistant)** `rgb(148,116,188)` = **`#9474BC`** (violet)
  - **上下文 (context)** `rgb(89,201,132)` = **`#59C984`** (green)
- **active tab accent**: `#7AAFFF` (the 对话/轨迹 tab label when active)
- `--dsm-warn` `#D49245`, `--dsm-warn-bg` `rgba(212,146,69,.12)`

**Desktop structure (what the phone must mirror):**
- **Left rail** (≈272px): logo + `HARNESS` pill → **新会话** primary button (radius 12, bg `#43454A`) → nav rows (插件 / IM机器人 / 自动化任务 / 工具管理, 14px, radius 12) → **工作区** section header with search / filter / open-folder icon buttons → **workspace tree** (folder glyph + name + relative timestamp on the right, e.g. `5分钟`, `27分钟`) → 默认工作区 → 未分组 → user avatar + name at the bottom.
- **Main header**: session title (bold) on the left, then a row of **icon + text chips** with chevrons (智能体团队, 创造模式, 2 个子智能体, 2 个后台任务), then far right a folder icon, a `…` menu, and a panel toggle.
- **Tabs**: **对话** | **轨迹** (13px; inactive `#ADB2B8`, active `#7AAFFF`).
- **对话 (chat) tab**: assistant text is **plain, no bubble**, left-aligned. Tool calls are **collapsed single-line rows prefixed with a `›` chevron** and a small glyph, e.g. `已读取文件，已写入文件，执行了命令`, `执行了命令，已写入文件，已读取文件`. Filenames are **inline mono pills** (`jobs_ranked.json`). Status lines: `⏳ 正在分析请求` (spinner) and `⏳ 深度求索中，用时 27分54秒 …` (hourglass). A right-edge vertical scrollbar. A floating round **globe button with a green dot** pinned to the right edge (network/connection status).
- **Composer**: a **floating rounded card** (radius ≈16) that overlaps the transcript, placeholder `发消息或创建任务 / 调用指令 @ 文件或对话`; bottom row = `+` round button · shield icon + `完全权限 ▾` · right-aligned `MiniMax M3.1 Flash Default ▾` · **blue circular send FAB** (`#3B82F6`).
- **Bottom status strip** (the desktop's signature): `🕐 4 轮 230…` · `🧾 37.9M tok…` · `Token 节省 -19,044` · `上下文 274K / 512K (53.6%)` · `缓存命中（累计）99.0%` · `压缩 18 次` · `Compaction 0 次` · `Spill 1 次` · `⟳ 54%`.
- **轨迹 (trajectory) tab**: a **Gantt-style timeline**. Left gutter with 输入/输出/工具 lane labels; per-row horizontal bars coloured by lane (green = input, purple = output, amber = tool); each row below is a one-line entry with the **role badge** (工具/助手/上下文) and the tool call summarised. **This is the most distinctive DSH UI element and the one most worth bringing to the phone** — on a narrow screen it becomes a **vertical event timeline** rather than a Gantt, keeping the same role colours.

---

## 5. Concrete recommendations for your ArkUI app

### 5.1 UI/UX — adopt these 8 patterns

1. **Floating composer that overlaps the transcript, with a three-part footer row.** Mirror the desktop exactly: text field on top; footer row = `+` (attach) · permission-mode chip (`完全权限`) · model+effort chip right-aligned · **circular blue send FAB** on the far right. ArkUI: a `Column` inside a `Stack` with `alignContent: Alignment.Bottom`, the card `borderRadius(16)`, `backgroundColor('#2C2C2E')`, `margin({left:12,right:12,bottom:12})`, and a `Shadow`/`blur` behind it so list content scrolls under it. **Reason:** this is the single strongest "same app" signal; your desktop already has it, and Happy independently arrived at the same shape (`+` / permission / model / voice).
2. **Collapse tool calls to one line with a leading `›` chevron + role-coloured glyph, never a card by default.** Use the desktop's three role colours exactly: tool `#DD8629`, assistant `#9474BC`, context `#59C984`. Summary text like `已读取文件，已写入文件，执行了命令`. Tap to expand into the full block (params, diff, output). **Reason:** matches the desktop 1:1, keeps the phone transcript scannable, and matches Happy's own "compact tool row" default (`ToolView.tsx:332-336`).
3. **Keep the desktop's bottom status strip, on the phone.** A single 11–12px row under the composer: `4 轮 · 37.9M tok · 上下文 274K/512K (53.6%) · 缓存 99.0% · 压缩 18`. Your bridge already exposes exactly these fields (`Models.ets` → `SessionStatsData` has `turns/steps/outputTokens/cacheReadTokens/contextTokens/contextWindow/model/permission/agentLabel`). **Reason:** it is the desktop's identity, it is cheap, and it gives the user the same mental model on both surfaces.
4. **Copy the desktop's session-list row geometry, not a chat-style bubble list.** 16dp horizontal padding, 10dp vertical, avatar 60 (or 44 on the phone), 12dp gap, title 17/22 semibold, project line 15/20 secondary, worktree/branch line 13/18, right-aligned tabular timestamp in a fixed 56dp slot, hairline divider starting *after* the avatar column. **Reason:** you already have `SessionListPage.ets`; adopting the desktop's *row rhythm* (rather than inventing one) is what makes it read as "the same app".
5. **Drop the tab bar; use a single stack + a bottom-anchored action row, and put "needs you" in a badge rather than a tab.** Happy's 3-tab model (sessions / inbox / settings) is good, but DSH has no tabs on the phone-sized layout. **Reason:** on a 6.1″ phone, 3 tabs + a floating composer + a status strip is too much vertical chrome. Instead: home = session list (with a `+` FAB), and an **unread/approval badge on the session row and on the FAB**, mirroring Happy's `+N` green badge and Claude Code's "computer icon with a green status dot when online".
6. **Expose the 轨迹 (trajectory) as a vertical event timeline on the phone**, keeping the same role colours and lane semantics (输入 / 输出 / 工具). Render it as a second tab *inside* the session screen (对话 | 轨迹), exactly as the desktop does — not as a separate top-level destination. **Reason:** it is the desktop's most distinctive feature, it translates 1:1 to a vertical list on a narrow screen, and it is what makes a phone client feel like it is showing you *the agent's work*, not just a chat log.
7. **Adopt a "no bubble for the agent, bubble only for the human" rule.** Agent text plain on the background; your own messages in the raised-surface bubble `#2C2C2E` with radius 16 (3 corners) / 4 (tail). Pending messages dimmed to 45% opacity but keep their colour — Happy's rule: *"the bubble keeps its own color, so the message reads as the user's own and merely not arrived yet."* **Reason:** it mirrors the desktop (which has no bubbles at all) and it removes the "IM chat app" look the user is complaining about.
8. **Ship a real "link a computer" onboarding screen, plus a key-based restore.** Follow Happy: (a) first run with an account but no machine → a dedicated *link your desktop* screen with a big QR (260dp) on a white radius-16 card; (b) restore by typing a **grouped Base32 code** (`XXXXX-XXXXX-…`, 35 chars) for the case where the user already has the account on another device; (c) one filled primary button + one quiet secondary link, never a form. **Reason:** you already have `ConnectPage.ets`; the gap is that it's a *form*, whereas both Happy and Claude Code use a **QR-first, key-second** flow with no typed host/port on the phone at all.

Also worth copying, lower priority:
- **Model picker as a bottom sheet with provider sections** (`OpenAI Codex` / `Anthropic Claude` / `xAI Grok`), each row = radio + provider glyph + model name + provider subtitle. Happy's `01-models.png` is a direct model for this.
- **Streaming indicator as one 11–14px status line**, fixed height (14) so an empty line and a long error take the same space — no layout jitter. (`MessageView.tsx:517-525`.)
- **A permission footer on tool rows**: Allow / Deny / Edit — with the theme's `permissionButton` colours (green allow `#34C759`, red deny `#FF3B30`, blue allow-all `#007AFF`). Happy's `PermissionFooter.tsx` is 25KB of this; the pattern is what matters.
- **Ellipsised, middle-truncated tool titles** so long paths don't blow out the layout.
- **Monospace for all code, filenames and paths** with an inline pill background — exactly the desktop's `jobs_ranked.json` treatment.

### 5.2 Architecture — adopt these 5 patterns

1. **Make the account a client-held 32-byte master secret; let the server hold only the public key.** Adopt Happy's `deriveKey(master, usage, path[])` HMAC-SHA512 key tree with separate usage roots (`'content'`, `'settings'`, `'analytics'`) so you can rotate one namespace without re-keying everything. **Reason:** it removes the need for a user database, gives you zero-knowledge sync for free, and makes "add a second phone" a key-transfer problem instead of a password problem. It is also the only approach in this set that works with a self-hosted relay and no third-party identity provider.
2. **QR pairing that carries a *public key*, with the session token issued after a key handshake.** Desktop generates an ephemeral keypair → prints `dsh://pair?<base64url pubkey>` as a QR → phone posts its own pubkey → desktop polls status → desktop returns the payload **encrypted to the phone's public key** → phone decrypts and stores. **Reason:** this is the exact flow Happy, Termopus and Remodex all converge on, and Claude Code's `/remote-control` QR. It means the QR is safe to photograph; a stolen QR grants nothing without the approving desktop.
3. **Versioned, sequenced, durable events over one socket, with ephemeral events on the same channel — and the server as the ordering authority.** Adopt Happy's shape: every durable entity carries `seq` + `updatedAt` + a per-field `version`; the socket carries two event classes (`update` durable / `ephemeral` transient); the server keeps the canonical order and the client reconciles. **Reason:** your existing `WsFrame`/`WsFrameData` (`Models.ets`) is already close — you mainly need to (a) add `seq`/`version` to `SessionSummary`/`BridgeMessage`, and (b) split `session.list`/`session.state` into *durable* vs *ephemeral* classes so a reconnect can resume from a sequence number instead of re-fetching everything.
4. **Suppress push when the user is already looking at the app — but fail open.** Port Happy's `hasActiveUiClient()` rule: only the *phone UI* socket counts (never the agent's own socket), only `appState === 'active'`, and any infrastructure error must **fail open** (send the push). **Reason:** Happy's own comment gets it exactly right — *"a redundant push is a buzz the user dismisses, while a missed push leaves an agent blocked on a permission prompt with nobody watching."* This is one of the highest-value, lowest-cost behaviours you can add.
5. **Bounded outbound buffer + replay on reconnect, and a "hand-off" escape hatch.** Adopt Remodex's resilience design: the bridge keeps a bounded queue of encrypted messages not yet acknowledged and re-sends them after a secure reconnect (exponential backoff 1s→5s). Then adopt its **honesty pattern**: when the desktop UI cannot live-mirror the phone (true for DSH's `Codex.app`-like split), provide an explicit **"在桌面端继续 / Continue on desktop"** button rather than pretending the two UIs are one. **Reason:** your byte-pipe relay already has a reconnect path; the buffer is what stops a dropped socket from losing a user prompt.

Additional architecture notes worth copying:
- **Per-entity encryption keys, not one key for everything.** Happy stores a `dataEncryptionKey` per Session/Project/Machine, wrapped by the account's content keypair. That lets you share one project with a teammate without sharing your whole account.
- **An encrypted per-account KV store** (`UserKVStore`: plaintext key for indexing, encrypted value) for settings you want synced but not modelled.
- **A separate "linked machine" entity with `active` + `lastActiveAt`**, surfaced in the UI as *"a session idle since yesterday on a machine that is still up is ordinary work"* — don't grey out offline sessions that are merely idle.

### 5.3 Things that are a bad idea on HarmonyOS — call-outs

| Don't do | Why | Do instead |
|---|---|---|
| **FCM / APNs push** | HarmonyOS has no Play Services and no APNs entitlement. An FCM token is unobtainable on HarmonyOS; an APNs token is only issued to a correctly-provisioned iOS app. | **Huawei Push Kit** (`@kit.PushKit`) — token via `pushService.getToken()`, and the token registered with your relay exactly like Happy's `POST /v1/push-tokens`. Note Push Kit tokens are per-app, and **emulators without a Huawei account do not get them** — so make the app fully usable *without* push (Happy's relay is the fallback: when the socket is up, you get the event anyway). |
| **Web Push / VAPID service workers** | VibeTunnel's VAPID approach works because it's a browser; ArkUI has no service worker and no `pushManager`. | Push Kit + a server-side sender. If you want a store-independent path, keep the **websocket relay as the primary transport** and treat push purely as a wake-up hint. |
| **Expo / React Native / Flutter / SwiftUI** | Not available for HarmonyOS. | ArkUI + ArkTS. **But** the *interaction patterns* port 1:1 (see §5.1). |
| **Termopus's blue user bubble (`#3B82F6`)** | It reads as an IM chat app — the exact complaint you have. | DSH's raised-surface bubble `#2C2C2E`. |
| **Termopus's dark-only theme** | DSH's desktop is dark but the app shouldn't be dark-locked; HarmonyOS users expect system-theme following, and DSH's desktop also has a light theme. | Follow the system theme; ship both light and dark token sets like Happy does (its `theme.ts` has `lightTheme`/`darkTheme` with `Platform.select` overrides). |
| **Copying Termopus code** | **AGPL-3.0.** Copying code would require you to open-source your HarmonyOS app. | Take *ideas* only, or use Happy (MIT) / VibeTunnel (MIT) / Remodex (Apache-2.0). |
| **A hand-rolled `crypto_box` in ArkTS** | TweetNaCl/libsodium bindings don't exist for ArkTS; and `crypto_box` + `crypto_sign` in pure ArkTS is a footgun (constant-time, RNG quality). | Use **HarmonyOS Crypto Architecture Framework (HUKS / `@kit.CryptoArchitectureKit`)**: `cryptoFramework` provides AES-GCM (`AES|GCM`), SHA/HMAC (`HMAC|SHA256`), and ECDSA. Derive your key tree with **HMAC-SHA512** (or SHA-256 if you must) and store the root key in **HUKS with a user-auth token** so the phone can require a biometric/PIN to unlock. Termopus's "hardware-backed keys + biometric lock" is the model; Happy's key-tree derivation is the model for the *structure*. |
| **A live `ws://` on `cleartext`** | HarmonyOS and modern OSes restrict cleartext. | `wss://` for anything off-LAN; on pure LAN use `ws://` only with the network-scoped cleartext exemption, and prefer your existing byte-pipe relay's TLS termination. |
| **`X-Happy-Client`-style plain-text device headers for auth** | Fine for telemetry, but don't let the *only* device identity be a client-supplied header. | Bind the socket to the account via the bearer token at connect time, and derive the device id from the **HUKS-held keypair**, not a header. |

### 5.4 Licensing / attribution

| Project | License | What you may do |
|---|---|---|
| **Happy Coder** (`slopus/happy`, `happy-desktop`, `happy-agent`, `happy-wire`) | **MIT** | Copy code, copy design, ship a fork — **keep the MIT notice** (`Copyright (c) 2026 Happy Coder Contributors`). The `happy-wire` protocol package is the most reusable part. **However** `packages/happy-server` is stated to be *private* in `happy-server-self-host/README.md` — so the **relay server source is not actually open** even though the app is MIT. Copy the *protocol*, not the server. |
| **VibeTunnel** (`amantus-ai/vibetunnel`) | **MIT** (`Copyright (c) 2025 Amantus Machina`) | Copy freely; keep the MIT notice. |
| **Termopus** (`Termopus/termopus`) | **AGPL-3.0** | **Do not copy code.** Design ideas and interaction patterns are not copyrightable, but reading its code to reimplement its logic is legally murky — keep it at the level of "I saw a Flutter app that does X" and design your own ArkUI implementation. Also note its branding (deep-navy + cyan octopus) is trademarked-looking; don't copy the palette or the logo. |
| **Remodex / Dex** (`emanuele-web04/remodex`, `MRL-00/Dex`) | **Apache-2.0** (per its repo metadata) | Copy freely; keep the Apache notice and the NOTICE file if present. Apache-2.0's patent grant is actually the *most permissive* of the lot. |
| **Claude Code / Codex mobile / Cursor for iOS** | Proprietary | Look at them for UX reference only. Do not copy assets, icons or copy text. Anthropic's and OpenAI's trademarks and the specific "computer icon with green dot" motif are theirs. |
| **IBM Plex Sans / IBM Plex Mono** (Happy's fonts) | SIL Open Font License 1.1 | Free to embed, including in a commercial product. If you want the desktop's exact type, DSH uses the **system stack** (`-apple-system … PingFang SC … Microsoft YaHei`) and `SF Mono / JetBrains Mono / Fira Code` — on HarmonyOS the equivalents are **HarmonyOS Sans** (system default) and **HarmonyOS Sans Mono** for code. |
| **Shiki / GitHub diff palette** in Happy's theme | MIT (Shiki) / BSD-ish (GitHub Primer colours are MIT) | Primer colour tokens are MIT-licensed; the specific hex values are freely reusable. |
| **Practical note** | — | If you copy **design ideas** (not code, not assets), you generally owe no attribution. But: (1) do not copy Happy's **logo**, the "Happy" wordmark, or its app-store screenshots; (2) don't claim affiliation; (3) if your ArkUI code ends up looking like a direct transliteration of a specific MIT file, keeping a `NOTICE` line naming the source is the cheap, safe thing to do. |

---

## 6. One-page summary for the implementer

**Phone IA (recommended, mirroring DSH desktop):**
```
ConnectPage  →  (paired)  →  SessionListPage  →  SessionPage
                                                    ├─ 对话 tab  (transcript + collapsed tool rows)
                                                    └─ 轨迹 tab  (vertical event timeline, role colours)
                          + floating composer ( + | 完全权限 | model ▾ | blue send FAB )
                          + status strip (轮 / tok / 上下文 / 缓存 / 压缩)
```

**Role colours (match the desktop exactly):** tool `#DD8629`, assistant `#9474BC`, context `#59C984`, accent `#7AAFFF`, send `#3B82F6`.
**Surfaces:** bg `#151517`, deepest `#111113`, rail/panel `#1B1B1C`, raised `#2C2C2E`, raised-hi `#34363A`, border `#43454A`, soft border `#242325`. Text `#E9EAEB` / `#A2A3A5` / `#8C8F93`.

**Sync model:** account = 32-byte client-held master secret → HMAC-SHA512 key tree → per-session/project/machine data keys → AES-256-GCM bodies. QR pairing carries a public key; the desktop approves; the secret travels encrypted to the phone. Durable events carry `seq`+`version`; ephemeral events don't. Server is the ordering authority. Push (Push Kit) is suppressed when the phone UI socket is `active`, and fails open.

**Do first (highest value ÷ effort):**
1. Replace the tool-call card with a one-line `›` chevron row in the desktop's role colours.
2. Rebuild the composer as the desktop's floating card with the `+ / 完全权限 / model ▾ / blue FAB` footer.
3. Add the desktop's status strip under the composer (the bridge already returns the fields).
4. Add the 对话/轨迹 segmented tabs inside the session screen, with the trajectory as a vertical timeline.
5. Restyle user messages to the raised-surface bubble (kill any blue), and leave agent text plain.

**Files in this workspace worth reading next:** `harmony/entry/src/main/ets/common/Theme.ets` (palette — already correct), `Models.ets` (protocol — needs `seq`/`version`), `SessionPage.ets` (chat rendering — biggest UI change), `SessionListPage.ets` (row geometry), `ConnectPage.ets` (replace the form with QR-first pairing).
