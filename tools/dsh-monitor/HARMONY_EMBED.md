# 嵌入鸿蒙 APP —— 可行性报告（摘要）

调查对象：`D:\APP\Deepseek\DSHHarmony`（只读）。完整证据与行号见下。

## 结论

**能嵌入，但必须做成原生 ArkUI 页面，且数据必须在 bridge 侧聚合。**

| 方案 | 可行性 | 理由 |
|---|---|---|
| (a) 原生 ArkUI 页面，经 bridge/relay 拉数据 | ✅ **推荐** | 新增 1 个 bridge 端点 + 1 个 ArkTS `@Entry` 页 |
| (b) 打包进 APP 的 WebView 页 | ⚠️ 不推荐 | APP **没有 WebView**（`renderer/`、`lib/` 是空目录且未跟踪；全仓 0 命中 `ArkWeb`；`module.json5` 也没有 ArkWeb 权限）。且 bridge **不发 CORS 头**、密封密钥在 NDK 里 WebView 拿不到 → 只能明文带 `Authorization`，破坏 `docs/ARCHITECTURE.md:264` 的安全模型。 |
| (c) 桌面侧 DSH 插件 + 手机只显示 | ⚠️ 只对桌面用户有价值 | DSH Web GUI 没有 URL 路由，手机无法深链；DSH 只监听 127.0.0.1 + Host 围栏。 |

## 现有数据路径

```
手机(ArkUI) ──wss──► cloudflared ──► relay:8788(哑字节管道) ──► bridge:8787 ──Typert RPC──► DSH:127.0.0.1:动态端口
      └──────────── 局域网直连 8787（无隧道）─────────────┘
```

- `relay/` 是**纯字节管道**，不理解 DSH 的 `client-request` 信封和 `remote.mux` 流帧
  → **新增遥测数据流零改动即可穿透隧道**（`relay/src/http-rewriter.js:1-18`）。
- 链路**零压缩**：relay 与 bridge 都是手写 WS（`relay/src/ws.js`、`bridge/src/ws.js:1-9`），
  不协商 `permessage-deflate`；也没有 gzip/brotli。→ 上公网的就是原始 JSON 字节。
- 限流/上限：单帧 256KB、回压队列 8MB、**空闲 60s 即断流**（`relay/src/frames.js:46`、`relay/src/server.js:56,212`）。
  → 遥测 WS 必须自带心跳（bridge→DSH 侧已有 20s ping：`bridge/src/dsh.js:763`）。

## bridge 侧现成的（可直接复用）

| 需求 | bridge 已有端点 | 位置 |
|---|---|---|
| 会话状态（运行/空闲） | `GET /api/v1/sessions` | `bridge/src/router.js:1832-1836` |
| 每会话 token/上下文/步数 | `GET /api/v1/sessions/:id/stats` | `bridge/src/session-stats.js:102-208` |
| 工作区列表 | `GET /api/v1/workspaces` | `bridge/src/router.js:1452-1464` |
| 会话树（会话→话题→子任务） | `GET /api/v1/session-tree` | `bridge/src/session-tree.js` |
| 待办计数 | `GET /api/v1/pending` | `bridge/src/router.js:1947-1950` |

`session/list` 已被 bridge 缓存：TTL 5s，后台每 20s 轮询一次（`router.js:177,304,344-347`）。

## 缺口（3 个，全是新接入面）

- `session/control`（WS）→ 实时 token 速率
- `job/list`（WS）→ 后台任务计数
- `workspace/follow`（WS）→ 工作区→会话映射

⚠ 流式端点**只能开在 `WS /api/remote.mux`**，不能走 HTTP POST（`bridge/src/dsh.js:726-733` 是现成骨架）。
⚠ `job/list` 的参数是 `args.request.sessionId`，`args.sessionId` 会被拒。

## 改动清单

1. `bridge/src/dsh.js` —— 新增 `openControl()` / `openJobList()` / `openWorkspaceFollow()`（照抄 `openFollow` 骨架 `:721-797`）。
2. `bridge/src/router.js:1807-2089` —— 新增 `GET /api/v1/telemetry` 聚合路由 + WS 广播（照 `publishSessionListIfChanged` 模式 `:1469-1489`）。
3. `bridge/src/protocol.js:139-151` —— 新增 `ServerFrame.TELEMETRY` 帧类型。
4. `harmony/.../common/BridgeClient.ets:680-715` + `Models.ets` + 新建 `pages/MonitorPage.ets` + `main_pages.json:2-8` 注册页面。
5. **relay 与 Cloudflare 隧道零改动。**

## 安全注意

WS 帧**不密封**（`BridgeClient.ets:620-676` 只在 REST 用密封）→ 遥测帧会被 relay 与 CF 边缘看见。
遥测敏感度低于对话正文，但 `cwd` 会泄露目录结构。
→ 建议：**WS 只推增量数值**（token 速率、job 计数、运行状态），**标题/路径留在 bridge 侧用密封 REST 按需拉**。

## 已知风险

- 隧道当前已失联：`tools/cf-tunnel.log` 尾部 214 条 `Failed to refresh DNS local resolver`，最后一条 `2026-10-24T04:47:38Z`；quick tunnel 无 SLA。
- 经 Cloudflare 时 relay 看到的 `remoteAddress` 是 `127.0.0.1`（cloudflared 本机拨入）→ **所有手机共用一个限流桶**。手机路径本身不限流所以目前无碍，但将来加限流必须按令牌/账号分桶。
