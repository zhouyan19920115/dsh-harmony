# DSH local API payload / bandwidth measurements

**Date:** 2026-10-24 12:38–13:05 (+08:00) · **Endpoint:** `http://127.0.0.1:28425` (verified live, PID 29372)
**Auth:** reused `tools/dsh-monitor/dsh-client.mjs` (`DshClient` → `mintCookie`), no auth rewrite.
**Scratch only:** everything below lives in `tools/dsh-monitor/_traffic/`. DSH install untouched, DSH not restarted.

---

## 0. Method & the compression question (read this first)

Raw bytes = UTF-8 byte length of the exact JSON text received.
Compressed bytes = `zlib.gzipSync(text, {level:9})` and `zlib.brotliCompressSync(text, {BROTLI_PARAM_QUALITY:11})`.

**WebSocket compression — measured, not assumed:**

| Probe | Result |
|---|---|
| Handshake headers Node's global `WebSocket` (undici) sends | `sec-websocket-extensions: permessage-deflate; client_max_window_bits` — **it DOES offer permessage-deflate** |
| DSH `GET /api/remote.mux` handshake, client offers `permessage-deflate` | HTTP `101`, response headers = `upgrade`, `connection`, `sec-websocket-accept` — **no `sec-websocket-extensions`** |
| DSH handshake, client offers nothing | HTTP `101`, identical headers — **no `sec-websocket-extensions`** |

**⇒ DSH's `/api/remote.mux` never negotiates `permessage-deflate`.** It does not echo the extension even when explicitly offered. Every server→client frame therefore travels **uncompressed**, and Cloudflare's tunnel will carry raw JSON bytes end-to-end. (Cloudflare *can* compress WS, but it needs both ends to negotiate; here the origin refuses.)

**WS framing overhead (measured on the wire):** 2 B for payload ≤125, 4 B for 126–65535, 10 B for >65535.
Examples: 351,090 B payload → 351,100 B on wire; 7,240 → 7,244; 850 → 854; 99 → 101; 352,101 → 352,111.
Overhead is ≤0.003 % — **ignore it, the payload IS the cost.**

---

## 1. Unary response sizes

### 1.1 `session/list` (full roster) — called **exactly once**, 135.053 s

| Payload | Raw bytes | gzip -9 | brotli -11 |
|---|---:|---:|---:|
| HTTP response envelope (`type:"client-response"…`) | **1,133,363** | **230,277** | **159,879** |
| Inner `result.value` (the roster itself) | 1,133,273 | 230,248 | 159,738 |
| Request body | 118 | — | — |

* **838 items**, **17 running**, **143 subagents** (`origin:"subagent"` or has `parentSessionId`)
* HTTP 200 · latency **135,053 ms** · gzip ratio 20.3 %, brotli ratio 14.1 %
* Response carried **no** `content-encoding` (identity) — the proxy must compress it.

### 1.2 `session/projections` (unary, arg key `request`, `{sessionId}`)

| Target | sessionId | Raw bytes | gzip -9 | brotli -11 | Latency |
|---|---|---:|---:|---:|---:|
| **(a) busy, running** | `session-5a1145f6-7195-4443-b375-6462e72d3980` | **50,226** | **22,755** | **18,914** | 181 ms |
| **(b) idle** | `session-9de904f1-55bd-4b89-88ef-8b9c5b0fce1e` | **41,928** | **18,286** | **15,000** | 23 ms |
| **(c) subagent** | `b5307f18-18b6-4d95-b7db-3cd36055569c` | **8,656** | **3,837** | **2,961** | 196 ms |
| ↳ inner `result.value` (busy) | | 50,137 | 22,697 | 18,870 | |
| ↳ inner `result.value` (idle) | | 41,839 | 18,235 | 14,924 | |
| ↳ inner `result.value` (subagent) | | 8,567 | 3,791 | 2,937 | |

### 1.3 Projections size breakdown — **is `turnOutline` the fat one? YES. Is `tokenOptimizer`? NO.**

Bytes of `values.<key>` as JSON, summed per key (22 keys total in `values`):

| key | busy-running | % of `values` | idle | % | subagent | % |
|---|---:|---:|---:|---:|---:|---:|
| **`turnOutline`** | **36,546** | **73.4 %** | **32,884** | **79.3 %** | **5,671** | **69.2 %** |
| **`agentTeam`** | **10,262** | **20.6 %** | **5,065** | **12.2 %** | 115 | 1.4 % |
| `tokenOptimizer` | **177** | 0.4 % | **180** | 0.4 % | **178** | 2.2 % |
| `sessionStats` | 138 | 0.3 % | 139 | 0.3 % | 136 | 1.7 % |
| `tokenUsage` | 104 | 0.2 % | 104 | 0.3 % | 104 | 1.3 % |
| `contextBreakdown` | 64 | 0.1 % | 64 | 0.2 % | 64 | 0.8 % |
| `title` | 41 | 0.1 % | 35 | 0.1 % | 41 | 0.5 % |
| *everything else* (17 other keys) | 2,428 | 4.9 % | 2,991 | 7.2 % | 1,882 | 23.0 % |
| **total `values`** | **49,760** | | **41,462** | | **8,191** | |

**Verdict:** `turnOutline` is 69–79 % of every projection payload and is the *only* thing worth cutting.
`tokenOptimizer` is **not** fat (177–180 B). `agentTeam` is the real #2 (10,262 B on a busy session).

### 1.4 Every running session (17/17) — needed for strategy (b)

| metric | value |
|---|---:|
| count | 17 |
| **sum raw** | **120,968 B** |
| mean raw | 7,115.8 B |
| median raw | 3,553 B |
| min / max raw | 1,926 B / 50,226 B |
| sum gzip-9 | 59,156 B |
| sum brotli-11 | 47,681 B |

Per-session raw: 1,926 · 2,031 · 2,714 · 2,802 · 2,830 · 2,876 · 3,210 · 3,229 · 3,553 · 3,678 · 4,993 · 5,398 · 5,888 · 7,430 · 8,656 · 9,528 · 50,226.

---

## 2. Stream payload sizes over a 60 s window

Machine under normal load (agent sessions actively turning). Two independent windows were captured.

### 2.1 `session/control` (stream, **no args allowed**)

Frame shapes: first frame `value.type="baseline"` (`value.projections[<sid>].values{…}`, 69 sessions); every later frame is `value.type="projection"` with `value.key` ∈ {`sessionStats`, `subagentTiming`, `contextPressure`, `contextBreakdown`, `tokenUsage`}.

| metric | window 1 (60,011 ms) | window 2 (45,011 ms) |
|---|---:|---:|
| frames | 36 | 55 |
| total payload bytes | 361,019 | 363,625 |
| **initial `baseline` frame** | **351,090 B** | **348,316 B** |
| delta frames | 35 | 54 |
| **delta bytes** | **9,929 B** | **15,309 B** |
| bytes/frame (all) | 10,028.31 | 6,611.36 |
| bytes/frame (deltas only) | 283.69 | 283.50 |
| **sustained rate, total** | **352.493 KB/min** | 470.407 KB/min |
| **sustained rate, steady-state deltas only** | **9.6945 KB/min** | **19.8046 KB/min** |
| wire bytes (framing included) | 361,029 | 363,635 |

**Per-`key` byte totals, window 1 (all 36 frames):**

| key | bytes |
|---|---:|
| `baseline` (one-time) | 351,090 |
| `sessionStats` | 4,109 |
| `subagentTiming` | 2,351 |
| `contextPressure` | 1,325 |
| `contextBreakdown` | 1,287 |
| `tokenUsage` | 857 |
| **`tokenOptimizer`** | **0** |
| **other** | **0** |

Window 2 per-key: baseline 348,316 · `sessionStats` 6,006 · `subagentTiming` 3,410 · `contextPressure` 2,115 · `contextBreakdown` 2,055 · `tokenUsage` 1,723 · `tokenOptimizer` 0 · other 0.

**Per-key share of the whole 69-session baseline (351,090 B):** `turnOutline` **155,028 (47.97 %)** · `agentTeam` **55,085 (17.04 %)** · `subagentCatalog` 21,855 (6.76 %) · `imageLimits` 13,800 (4.27 %) · `modelSelection` 11,021 (3.41 %) · `tokenOptimizer` 10,950 (3.39 %) · `sessionStats` 7,935 (2.46 %) · `todos` 7,750 · `inbox` 6,849 · `tokenUsage` 6,491 (2.01 %) · `contextBreakdown` 4,249 · `contextPressure` 4,190 · `title` 2,385 · `workingDirectory` 1,794 · …

> Note: the baseline's `turnOutline` share (47.97 %) is lower than a single-session share (73 %) because the baseline spreads over 69 sessions while `session/projections` returns one fat session.

### 2.2 `workspace/follow` (stream, no args)

| metric | window 1 (60 s) | window 2 (45 s) |
|---|---:|---:|
| frames | **1** | **1** |
| **baseline frame size** | **7,240 B** | 7,240 B |
| subsequent delta frames | **0** | **0** |
| delta bytes | **0** | **0** |
| sustained rate | 7.069 KB/min (amortised baseline) | 9.366 KB/min |
| steady-state delta rate | **0 KB/min** | **0 KB/min** |

Baseline shape: `{"type":"baseline","value":{"items":[…11 workspaces…],"archivedSessionIds":[…4…],"pinnedSessionIds":[]}}`.
Each workspace item = `{workspaceId, path, title, sessionIds[], createdAt, updatedAt}` (~658 B each).
**Zero workspace mutations were observed in 105 s total** — the workspace grouping is essentially static.

### 2.3 `job/list` (stream) for 3 different running sessions

Arg shape is `{"request":{"sessionId":"…"}}` — **`args.sessionId` is rejected** (`gateway/arguments-invalid`). Frame shape is `value.type="rows"` with `value.jobs[]`.

| session | rows frame size | job count | B/job | new rows in 60 s |
|---|---:|---:|---:|---:|
| `8c93da4c-f963-4fae-903c-0470093a3fe0` | **99 B** | 0 | — | **0** |
| `session-0c0b48ef-52a6-4018-861b-bdd733c059d7` | **99 B** | 0 | — | **0** |
| `f2547873-d946-4809-9072-762610b04b11` | **850 B** | 2 | **425 B** | **0** |

* Empty rows frame = `{"type":"item","streamId":"…","value":{"type":"rows","jobs":[]}}` → exactly **99 B**.
* A job row ≈ **425 B**, dominated by `label` (191 B and 104 B in the capture); other fields: `id`, `kind`, `owner`, `status`, `detail`, `startedAt`, `finishedAt`, `output{total,earliest}`.
* **0 new row frames arrived in 60 s on any of the three streams** — job rows are pushed only on job start/finish.
* Rates: 0.0967 / 0.0967 / 0.8299 KB/min (baseline only, one-shot).

---

## 3. Projected bandwidth for dashboard polling strategies

`MB/hour` = 1,048,576 B. All raw numbers; gzip/brotli columns show what a compressing relay would save.

| # | Strategy | Bytes/poll | Polls/min | **Bytes/sec (raw)** | **MB/hour (raw)** | Bytes/sec (gzip-9) | MB/hour (gzip-9) | Bytes/sec (brotli-11) | MB/hour (brotli-11) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **(a)** | naive: full `session/list` every 30 s | 1,133,363 | 2 | **37,778.77** | **129.70** | 7,675.90 | 26.35 | 5,329.30 | 18.29 |
| **(b)** | `session/projections` × **17** running sessions every 5 s | 120,968 | 12 | **24,193.60** | **83.06** | 11,831.20 | 40.62 | 9,536.20 | 32.74 |
| **(b′)** | same, scaled to **21** running sessions | 149,431 | 12 | **29,886.21** | **102.62** | 14,631.72 | 50.24 | 11,799.15 | 40.53 |
| **(c)** | `session/control` push only — steady state (no baseline) | — | push | **165.45** | **0.568** | 165.45 | 0.568 | 165.45 | 0.568 |
| **(c′)** | `session/control` push only — busier window 2 | — | push | **337.99** | **1.160** | 337.99 | 1.160 | 337.99 | 1.160 |
| **(c″)** | `session/control` push, reconnect every 60 s (baseline amortised) | 361,019 | 1/60 s | **6,015.88** | **20.65** | ~1,846 | 6.34 | ~1,421 | 4.88 |
| **(d)** | **hybrid**: `session/control` push + `workspace/follow` + `job/list` (active set only) — steady state | 10,977/60 s | push | **182.92** | **0.628** | — | — | — | — |
| **(d′)** | hybrid, one connect per hour (baseline once) | 1,017,998/h | — | **282.78** | **0.971** | — | — | — | — |
| **(d″)** | hybrid, reconnect every 60 s | 370,355/60 s | 1/60 s | **6,172.58** | **21.19** | — | — | — | — |

**Hybrid (d) component bytes per 60 s:** `session/control` deltas 9,929 + `workspace/follow` deltas 0 + `job/list` (×3) deltas 1,048 = **10,977 B**.
**One-time baselines for (d):** control 351,090 + workspace 7,240 + job rows 99+99+850 = **359,378 B**.

### What "can Cloudflare survive it?"

* **(a)** 129.70 MB/h = **3.11 GB/day** — Cloudflare's edge will happily proxy it, but it is pure waste, and the *real* problem is not bandwidth: **each `session/list` call takes 135 s**, so a 30 s poll loop builds up overlapping 1.13 MB requests against DSH. Naive polling is a self-inflicted DoS on the origin.
* **(b)** 83.06 MB/h = **1.99 GB/day** — same origin pressure (17 unary RPCs every 5 s, each re-rendering the full `turnOutline`), 137× more bytes than needed for a token-rate widget.
* **(c)/(d)** **0.57–1.16 MB/h** and **0.63 MB/h** — i.e. **~4 KB/min**, roughly **0.0001 %** of a typical link. Cloudflare (and the tunnel) is nowhere near stressed; this is a non-event for the edge.
* Because DSH refuses `permessage-deflate`, **the tunnel carries raw bytes** — so compression has to be applied by a relay, not by the tunnel.

---

## 4. Recommendation — minimum-bandwidth design

**Facts that drive it:** (i) there is **no server-side field filter** — `session/projections` silently ignores `keys`/`fields`/`include`/`projections` and always returns all 22 value keys, and `session/control` **strictly rejects every arg** (`unexpected "keys"` / `unexpected "request"` / `unexpected "sessionIds"`); (ii) `turnOutline` + `agentTeam` are **91 %** of every projection payload and **65 %** of the control baseline; (iii) `tokenOptimizer` is *not* a problem (177–180 B per session, 0 bytes on the stream); (iv) `workspace/follow` is static (0 deltas in 105 s) and `job/list` only pushes on job transitions (0 new rows in 60 s).

**Recommended design — 3 push streams, zero polling, plus an optional local relay:**

1. **One `session/control` WS stream** for per-session token rate + running state. It gives `tokenUsage`/`sessionStats`/`contextPressure`/`contextBreakdown` deltas as they change. Cost: **351,090 B once** + **9.7–19.8 KB/min** steady state.
2. **One `workspace/follow` WS stream** for workspace grouping. Cost: **7,240 B once**, **0 B/min** (no deltas observed).
3. **`job/list` WS streams only for the active set** (the sessions the dashboard shows). Cost: **99 B** for an empty session, **~425 B per job row**, **0 B/min** unless a job starts/finishes.
4. **Never call `session/list` from the dashboard.** It costs 1,133,363 B and **135 seconds** of origin time for a roster that `workspace/follow` + `session/control` already cover. If a full 838-session roster is genuinely required, fetch it **once** at startup and cache it (1.13 MB raw / 230,277 B gzip-9 / 159,879 B brotli-11), never on a timer.

**Concrete numbers for the minimum-bandwidth design:**

| variant | one-time | steady state | bytes/sec | MB/hour |
|---|---:|---:|---:|---:|
| **Raw, direct from DSH through the tunnel** | 359,378 B | 10,977 B/min | **182.92** | **0.628** |
| + reconnect every 60 s (worst realistic) | 359,378 B each | — | 6,172.58 | 21.19 |
| **With a local stripping+gzip relay** (drop `turnOutline`,`agentTeam`,`subagentCatalog`,`imageLimits`,`modelSelection`,`tokenOptimizer`,`todos`,`plan`,… keep `title`,`tokenUsage`,`sessionStats`,`contextPressure`,`contextBreakdown`,`workingDirectory`) | baseline **38,900 B raw / 6,444 B gzip-9 / 5,006 B brotli-11** (vs 351,090 raw / 107,696 gzip-9 / 82,844 brotli-11 unstripped) | control deltas **4,966 B/60 s** raw (16 of 35 frames) — gzip-batched: **755 B** | **≈83–90** | **≈0.29** |
| vs. naive (a) | 1,133,363 B **every 30 s** | — | 37,778.77 | 129.70 |

**Bottom line:** the hybrid push design is **~700× cheaper than naive polling** (0.628 vs 129.70 MB/h) and **~132× cheaper than 5 s projections polling** (0.628 vs 83.06 MB/h). A local stripping+gzip relay cuts the one-time baseline from 351,090 B to **6,444 B** (gzip-9) — a **54× reduction** — and brings the whole dashboard to **≈0.29 MB/h, ~83 bytes/sec**. Cloudflare will not notice it exists; the tunnel, the edge and DSH itself all stay idle. The only remaining risk is the origin, not the tunnel: keep `session/list` out of any loop, because its 135-second latency (not its 1.13 MB) is what will actually hurt.
