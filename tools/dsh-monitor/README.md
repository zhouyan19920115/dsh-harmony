# DSH // TELEMETRY — 本机用量与状态分析

一个**纯本地**的 DSH（DeepSeek Harness）用量/状态看板。原样保留了"不引入自建后台服务"的约束。

```
tools/dsh-monitor/
├── index.html            # 看板本体（单文件，零依赖，双击即开）
├── preview.png           # 真实数据下的看板截图
├── snapshot.json         # 真实快照（本机扫出来的，已 gitignore）
├── dsh-client.mjs        # DSH 本机 RPC 客户端（自签 v1 owner cookie）
├── scan-logs.mjs         # 扫描 ~/.dsh/sessions 的会话日志 → 快照
├── enrich-live.mjs       # 给快照补上 DSH 实时投影（解码速率、标题、团队）
├── telemetry-feed.mjs    # 紧凑遥测流（WS 推送 → 12KB/次，给手机用）
├── measure-compact.mjs   # 载荷体积与流量测算
├── asar-extract.mjs      # 无依赖的 app.asar 读取器（查 DSH 源码用）
├── inspect-session.mjs   # 单个会话日志结构探查
├── probe-payloads.mjs    # 记录类型/载荷结构探查
├── DSH_DISK_FORMAT.md    # 磁盘格式完整报告（证据）
├── TRAFFIC_REPORT.md     # 载荷体积 / 带宽实测报告（证据）
├── HARMONY_EMBED.md      # 嵌入鸿蒙 APP 的可行性报告（证据）
└── COMPAT_AUDIT.md       # DSH 升级兼容性审计（证据）
```

![preview](preview.png)

## 怎么用

```powershell
# 1) 扫本机会话日志（约 4 分钟，834 个会话 / 286MB zstd）
node tools/dsh-monitor/scan-logs.mjs tools/dsh-monitor/snapshot.json 30

# 2) 补实时状态（DSH 本机 RPC：running / 标题 / 解码速率 / 团队）
node tools/dsh-monitor/enrich-live.mjs tools/dsh-monitor/snapshot.json tools/dsh-monitor/snapshot.json

# 3) 打开看板 → 右上角「载入快照」选 snapshot.json（或点 REAL 自动读取）
start tools/dsh-monitor/index.html
```

`file://` 下浏览器会拦截 `fetch('snapshot.json')`，所以用「载入快照」按钮；把目录用任意静态服务器
打开则 REAL 按钮可自动读取。快捷键：`空格` 暂停/继续，`1–4` 切时间范围。

## 结论：有没有意义 / 能不能实现

**都能实现，而且 DSH 本身已经把数据准备好了。** 关键发现（全部在本机实测验证）：

| 你想要的 | 数据来源 | 状态 |
|---|---|---|
| 各工作区有什么任务在进行 | `session/list` 的 `cwd` + `running`；或 `workspace/follow` 的 `sessionIds[]` | ✅ |
| 有几个后台 | `job/list`（流式，按会话）；或日志里的 `job/registered`/`job/settled` | ✅ |
| 有几个子 Agent | `session/list` 的 `origin:'subagent'`+`parentSessionId`；`subagentCatalog[]`、`agentTeam.members[]` | ✅ |
| 现在的 token 速度 | `sessionStats.decodeTokens/decodeMs` → tok/s；`session/control` 实时推送 | ✅ |
| 按日期/工作区累计消耗 | 投影 `tokenUsage`（会话累计）+ 会话日志按天聚合 | ✅ |
| 点击任务跳转对话框 | **⚠ Web GUI 没有 URL 路由** | ⚠ 见下 |

### 唯一真正做不到的一格：点击跳转

DSH 的 Web GUI **没有 URL 路由**——没有 hash 路由、没有 query 参数、没有 `dsh://` 协议处理器
（`location.hash` / `pushState` 只存在于 pdf.js 和 DevTools 里）。导航是纯内存态：
`ctx.uiWorkspace.openSession(id)`（`dsh-client-ui-workspace/lib/client.js:1470`）。

所以"点击跳转"有两条路：

1. **做成 DSH 客户端插件**（推荐）。插件的 client bundle 由 DSH 自己以同源方式提供在
   `/plugins/<id>/client.js`，既能调本机 RPC，也能直接调 `openSession` → 真正的点击跳转。
   Cordis profile（`~/.dsh/profiles/desktop/cordis.patch.yml`）是 DSH 唯一可写的接入面。
2. **退一步**：点击 → 打开 `/api/session.export?sessionId=…`（导出该会话原始日志），
   或者用 `session/prompt` + `session/follow` 驱动会话。

### 为什么"不用自建后台"是可行的

DSH **自己**已经在 `127.0.0.1:<动态端口>`（本次为 28425）跑着 web server。浏览器侧要直连它，
必须**同源**：跨源 / `file://` 会被 Host 栅栏拒绝（实测 403 forbidden）。同源解决办法只有一个：
让页面由 DSH 自己提供（插件 bundle）。非浏览器进程（Node/curl）不带 `Origin` 头即可通过栅栏，
所以本仓库的 `dsh-client.mjs` / `scan-logs.mjs` 能直接读。

凭据：启动 token 只在宿主进程内存里，**不落盘**；落盘的只有
`~/.dsh/.credentials.yaml` → `records."client-connection/browser-session".payload.secret`。
用这 32 字节原始密钥签一个 v1 owner cookie 即可（HMAC-SHA256 + base64url）。

## 两条落地路线

### A. 实时流量统计（可立即做，零后台）

- 一个静态页面 + 一次性 `node scan-logs.mjs` 产出的 `snapshot.json`。
- 想要"实时"：把 `scan-logs.mjs` 换成 **DSH 插件内的 `session/control` 推送流**
  （WS `ws://127.0.0.1:<port>/api/remote.mux`，同源，cookie 自动带）。
  推来的帧就是 `{type:'projection', sessionId, key:'tokenUsage', value:{…}}`，直接累加成速率。
- 排行、是否在运行、按日期/工作区汇总：全部有现成字段。

### B. 完整版（做成 DSH 插件）

- 在 `~/.dsh/profiles/desktop/cordis.patch.yml` 注册一个插件；
- 插件 client bundle 里挂一个"用量"面板：同源调 `session/list`（**别轮询**：实测 2 分钟/1MB），
  平时用 `session/projections` 增量或 `session/control` 推送；
- `workspace/follow` 拿工作区→会话映射，`job/list` 拿后台任务；
- 点击一行 → `ctx.uiWorkspace.openSession(id)` 直接跳到那个对话框。

## 踩过的坑（都已在代码里处理）

1. **zstd 是拼接帧流**：`zstdDecompressSync` 只解第一帧。必须用 `createZstdDecompress()` 逐帧
   推进（`bytesWritten` 即下一帧起点）。否则一个 300KB 的日志只解出 1 条记录。
2. **`session/list` 的参数键是 `_request`**，其余端点都是 `request`。键写错 →
   `gateway/arguments-invalid`。
3. **HTTP 415**：`Content-Type` 必须是 `application/json`，没有 form 编码路径。
4. **端口是动态的**，每次启动都变，别硬编码 28425，用 `Get-NetTCPConnection` 查。
5. **流式端点不能走 HTTP POST，unary 不能走 WS**：
   `session/control` / `session/follow` / `job/list` / `workspace/follow` 必须开在
   `/api/remote.mux` 上。
6. **子 agent 不能用 `{kind:'session'}` 寻址**，必须
   `{kind:'subagent', parentSessionId, childSessionId, mode}`，否则 `session/agent-busy`。
7. **缓存读 token 占大头**：本机 10.29B 总 token 里 9.86B 是 cacheRead，
   真正计费口径（uncached input + output）只有 435.5M。看板把两者分开显示。
8. **日志里的 cwd 有 `D:/APP/X` 和 `D:\\APP\\X` 两种写法**，不归一会把同一工作区拆成两行。

## 本机实测数据（2026-10-24）

```
会话 834（运行中 21）· 子 Agent 140 · 后台任务 18,814（运行中 36）· 工作区 13
总 token 10.29B ＝ 计费 435.5M ＋ 缓存读 9.86B
今日计费 262.4M · 当前解码速率合计 ~1.77k tok/s
```

## 带宽实测（决定能不能走 Cloudflare）

**DSH 的 `/api/remote.mux` 不协商 `permessage-deflate`**（客户端明明 offer 了，101 响应里没有
`sec-websocket-extensions` 头）→ 隧道上跑的是**未压缩的原始 JSON**，载荷即成本。

| 端点 | raw | gzip-9 | 备注 |
|---|---:|---:|---|
| `session/list` | 1,133,363 | 230,277 | **单次 135 秒**！绝不能轮询 |
| `session/projections`（忙碌会话） | 50,226 | 22,755 | 其中 `turnOutline` 占 73% |
| `session/projections`（子 agent） | 8,656 | 3,837 | |
| `session/control` baseline | 351,090 | 107,696 | 一次性；69 个会话 |
| `session/control` 增量 | 9,929 B/60s | — | 稳态 **9.7–19.8 KB/min**，283 B/帧 |
| `workspace/follow` baseline | 7,240 | — | 之后 **0 B/min**（静态的） |
| `job/list` rows | 99 B 空 / 425 B 每条 | — | 平时 0 B/min |

**没有服务端字段过滤**（`session/projections` 静默忽略 `keys`/`fields`，`session/control` 严格拒绝任何参数）
→ 要瘦身只能在本地中转层做。

### 流量对比

| 策略 | B/s | MB/h |
|---|---:|---:|
| 朴素：每 30s 拉 `session/list` | 37,779 | **129.7** |
| 每 5s 拉 17 个会话的 projections | 24,194 | **83.1** |
| **混合推送**（control 推送 + workspace + job） | **183** | **0.63** |
| 混合 + 中转层裁剪字段并 gzip | **83** | **0.29** |

裁剪掉 `turnOutline`/`agentTeam`/`subagentCatalog`/`imageLimits`/`modelSelection`/
`tokenOptimizer`/`todos`/`plan` 后，baseline 从 351KB → **38.9KB（54×）**，增量减半。

**结论：Cloudflare 扛得住，而且是压倒性地扛得住**（0.63 MB/h 是链路的千万分之几）。
真正的风险从来不是隧道，是**源站**：`session/list` 一次 135 秒 + 1.13MB，
30 秒轮询会让请求在 DSH 上堆叠。
另注意 relay **空闲 60 秒断流**，遥测 WS 必须自带心跳。

完整实测见 [TRAFFIC_REPORT.md](TRAFFIC_REPORT.md)。

## 嵌入鸿蒙 APP

见 [HARMONY_EMBED.md](HARMONY_EMBED.md)。要点：

- APP 是**纯原生 ArkUI，没有 WebView** → 不能把看板做成网页塞进去；
  正确做法是新增一个 `MonitorPage.ets`，数据由 **bridge 侧聚合**后经现有 relay 隧道下发。
- bridge 已有 `/api/v1/sessions`、`/api/v1/sessions/:id/stats`、`/api/v1/workspaces`、
  `/api/v1/session-tree`、`/api/v1/pending` 可直接复用；只缺 `session/control`、`job/list`、
  `workspace/follow` 三条 WS。
- **relay 与 Cloudflare 隧道零改动**（relay 是纯字节管道，不理解语义）。
