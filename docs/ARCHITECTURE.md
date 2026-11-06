# 架构说明

## 1. 为什么需要一层桥接

DeepSeek Harness(DSH)的 Web/API 服务有几个硬性约束, 使得手机**不能**直连:

| 约束 | 后果 |
|---|---|
| 只监听 `127.0.0.1:10748` | 手机在局域网里根本够不着 |
| Host 围栏 | `Host` 头不等于 `127.0.0.1:10748` 直接 403 |
| Cookie 认证 | 密钥只在本机磁盘上, 且每次会话要重新签发 |

所以架构固定为三段:

```
手机 (ArkTS)  ──HTTP/WS──►  bridge (本机 Node.js)  ──RPC/WS──►  DSH (127.0.0.1:10748)
```

bridge 干三件事, 一件都不多:
1. **Termination** —— 把手机的简单 REST/WS 协议翻译成 DSH 的 RPC 信封。
2. **Authentication** —— 读本机密钥、签 Cookie、强制正确 Host 头。
3. **Fan-out** —— 一个桌面可能有多个会话; bridge 把 DSH 的 `remote.mux` 多路复用流拆成"每个会话一条"的语义, 再转成手机友好的事件。

**没有修改 DSH 的任何代码, 也没有往 DSH 里装插件。**

---

## 2. 两套协议

### 2.1 手机 ↔ bridge(自研, 见 `PROTOCOL.md`)

刻意做成极简: 7 个 REST 端点 + 1 个 WebSocket。

- 认证用 `Authorization: Bearer <token>`(手机端可直接设置 HTTP 头, 且 ArkTS 的
  `@ohos.net.socket` 支持在握手时带自定义头)。
- WebSocket 帧统一是 `{type, data}`, 事件驱动, 没有轮询。
- 配对信息用二维码承载: `dsh-harmony://connect?host=…&port=…&token=…`。

### 2.2 bridge ↔ DSH(既有, 见 `DSH_HTTP_API_MAP.md`)

- 统一 RPC 路由 `POST /api/<namespace>/<method>`, 信封:
  ```json
  {"type":"client-request","rpcId":"…","method":"session/list","payload":{"args":{"_request":{}}}}
  ```
- **参数键名不统一**是最大的坑: `session/list` 用 `args._request`,
  `session/prompt` 用 `args.request`, 其它大多用 `args.request`。
  键名错了会得到 `gateway/arguments-invalid`。
- 实时流只有 WebSocket(`/api/remote.mux`), 没有 SSE。

---

## 3. 数据流

### 3.1 同步会话列表

```
手机 GET /api/v1/sessions
  → bridge POST /api/session/list
    → DSH 返回 { items: [ SessionSummary, … ] }
  → bridge 投影成 PROTOCOL.md 的 SessionSummary
```

### 3.2 实时输出

```
DSH  WS /api/remote.mux  ── session/follow 流 ──►
bridge  订阅每个活跃会话, 把 assistant-stream 的 chunk 帧聚合成
        message.created / message.delta / message.completed
  ── WS /ws ──►  手机界面追加文本
```

`session/follow` 是**快照 + 增量**模式: 先给一个 `snapshot` 帧(带 cursor),
之后是 `event` 帧和 `assistant-stream` 帧。bridge 需要按 `streamId` 维护游标,
避免重放。

### 3.3 下发指令

```
手机 POST /api/v1/sessions/{id}/messages  {text}
  → bridge POST /api/session/prompt
      { requestId, sessionId, mode:'queue', content:[{type:'text',text}] }
    → DSH 返回 { accepted:true }
  → 手机本地先回显一条 user 消息, 桌面端真正的回包稍后经 WS 推回来
```

`requestId` 由 bridge 生成并保持幂等, 避免网络重试导致重复下发。

---

## 4. 鸿蒙端实现要点

踩过的坑, 都固化在代码里了:

| 坑 | 处理 |
|---|---|
| ArkTS 没有 `fetch` | 用 `@kit.NetworkKit` 的 `@ohos.net.http`, 记得 `destroy()` |
| `AsyncCallback` 的参数顺序是 `(err, data)`, **不是** `(data, err)` | 见 `BridgeClient.ets` |
| `arkts-no-untyped-obj-literals`: 含方法成员的接口不能用对象字面量赋值 | `BridgeListener` 改成"类 + 函数字段" |
| `Record<string, string>` 不是合法 ArkTS 类型 | 换成显式 interface(`SubmitPromptPayload` 等) |
| V1/V2 状态装饰器不能混用 | 全项目统一用 V1 `@Component` + `@State` |
| 每个 `.ets` 只能有一个 `@Entry` | `pages.json` 注册三个页面, 每个文件一个 `@Entry` |
| `TextDecoder` 不在全局 | `import { util } from '@kit.ArkTS'` → `util.TextDecoder` |
| `Scroller` 没有 `scrollToEnd` | `scrollToIndex(len-1, true, ScrollAlign.END)` |
| `throw e` 里的 `e` 是 `unknown` | ArkTS 禁止抛任意类型, 改成 `throw new Error(err.message)` |
| `preferences` 是异步的, 读配置会晚一拍 | `EntryAbility` 先 `await AppState.restore()` 再 `loadContent`, 否则客户端还停在默认 `127.0.0.1:8787` |
| **一条工具结果可能有几十万字符** | 直接渲染会把主线程卡死(`THREAD_BLOCK_6S` 应用无响应); 按角色截断(普通 1200 / 工具 400 字)并跳过 `system` 消息 |
| 模拟器里的 `127.0.0.1` 是模拟器自己 | 连接页加「自动探测」: 依次试 `10.0.2.2`、`127.0.0.1` |

---

## 4.1 调试期踩到的几个真实缺陷(已修)

| 现象 | 根因 | 修法 |
|---|---|---|
| 会话页一点就退, 日志里只有 `THREAD_BLOCK_6S` | 一次性把 200 条消息(含几十万字的工具输出)渲染出来, 主线程 6 秒无响应被系统判定无响应并杀掉 | 见上表: 限量 + 截断 + 跳过 system |
| 会话页一直显示「执行中」, 永远等不到桌面端回复 | 手机端**从来没发过 `subscribe` 帧**, bridge 因此不为该会话建立流式推送 | `SessionPage.aboutToAppear` 发 `subscribe`; bridge 端按 `PROTOCOL.md` 把 `subscribe` 改为整体替换语义 |
| 配对过之后 App 每次启动都退回连接页, 且连的是 `127.0.0.1` | `EntryAbility` 只调了 `ConfigStore.load()`, 没把配置写进全局的 `BridgeClient` | 改用 `AppState.restore()`(读配置 + 设端点), 首屏再按 `paired` 决定 |
| 换成中继地址后一直「未连接」 | `connect()` 发现 socket 还活着就直接返回, 手机连的还是旧地址 | `setEndpoint()` 发现地址变了就 `disconnect()`; 断线后 3 秒自动重连 |
| 中继上的设备每隔一两分钟就掉线 | 中继把**设备自己的 WebSocket 连接**也当成"手机连接"做原始字节抓取, 设备的二进制帧把抓取缓冲区撑爆, 连接被判为"请求头过大"而销毁 | 设备连接被接管时立即 `release()` 掉手机侧的抓取 |
| 顶部显示的桌面端地址是旧的 | V1 组件里非 `@State` 的表达式只在创建时渲染一次 | 改成 `@State endpointLabel`, 在 `aboutToAppear` 和连接状态变化时刷新 |

---

## 4.2 云中继那一层

远程使用的结构是四段:

```
手机 ──https/wss──► 中继(公网) ◄──ws(桌面主动外拨)──► bridge ──► DSH
```

- 中继是**哑管道**: 只搬字节, 不理解 bridge 的业务协议。手机发的 HTTP 请求
  (连同 `Authorization` 头)**原样透传**, 最终由 bridge 自己裁决令牌 ——
  中继不缓存业务数据, 也不做业务鉴权。
- 一条设备连接上跑多条"流": 帧格式 `streamId(4B BE) | type(1B) | length(4B BE) | payload`。
- 中继**不自己回 101**: WebSocket 升级请求的原始字节写进流里, 由 bridge 那边算
  `Sec-WebSocket-Accept` 并回 101, 中继只把字节搬过去。
- `OPEN` 的目标被限制成 `127.0.0.1:<bridgePort>` —— 中继不能借设备去扫内网。

协议细节见 [`RELAY.md`](RELAY.md), 部署见 [`REMOTE.md`](REMOTE.md)。

> **一个容易误解的现象**: 手机上"我"的气泡里有时会带一大段 "Time sampled while
> preparing turn…" 或技能清单 —— 那是 **DSH 自己**在往用户消息里注入运行时上下文,
> 不是桥接或手机端的 bug, 桌面端的 agent 看到的就是这条消息。

---

## 5. 已知边界

- **DSH 只监听 127.0.0.1** —— 桥接服务必须跑在用户自己的电脑上, 且手机与电脑要在同一局域网(或自行加中继/内网穿透)。
- **鉴权是"共享密钥"级别** —— token 等同于 DSH 的完整读写权限, 只在可信局域网使用;
  跨公网请自行套一层 TLS/中继。
- **HarmonyOS 后台存活** —— 应用被系统回收后 WebSocket 会断, 需要重新进入前台时重连;
  桥接侧每 600ms 轮询一次会话状态, 重连后会自动补齐增量。
- **尚未实现** —— 云端中继(官方产品的做法)、Push Kit 推送、文件传输、远程审批卡片、
  多设备同时配对。
- **模拟器只是开发环境** —— 真机上 bridge 的局域网 IP 直接可达; 模拟器要走 `10.0.2.2`。

---

## 6. 总图

```
                      ① 局域网: http / ws
  ┌─────────────┐ ──────────────────────────► ┌─────────────┐ ── ② 本机回环 ──► ┌────────┐
  │  手机 App   │                             │   bridge    │   RPC / WS        │  DSH   │
  │  (ArkTS)    │ ◄────────────────────────── │  (Node.js)  │ ◄───────────────── │ (本机) │
  └─────────────┘      事件 / 消息 / 心跳       └─────────────┘                    └────────┘
        │                                        ▲
        │ ③ 公网: wss(可选)                      │ ④ 桌面端**主动外拨**(ws)
        ▼                                        │
  ┌─────────────┐                          ┌─────┴───────┐
  │   云中继    │ ◄─────────────────────── │   bridge    │
  │  (哑管道)   │                          └─────────────┘
  └─────────────┘
```

| 走法 | 什么时候用 | 特点 |
|---|---|---|
| **① 局域网直连** | 手机和电脑在同一个 WiFi | 最快, 数据一步都不出局域网 ✓ |
| **② bridge ⇄ DSH** | 永远 | 只在本机回环上, 走 DSH 自己的 RPC/WS ✓ |
| **③④ 经云中继** | 手机不在同一个网段(CGNAT、公司网…) | 电脑**主动外拨**, 家里不用开端口、不用做端口映射 ✓ |

**两条路的业务协议完全一样** —— 中继只换路, 不改语义 ✓。

---

## 7. 各组件职责

| 组件 | 跑在哪 | 干什么 | 端口 |
|---|---|---|---|
| **App** | 手机 (HarmonyOS / ArkTS) | 界面(会话树 / 对话 / 下指令)、局域网自动探测、密封层、令牌存 HUKS | 只有出站连接 ✓ |
| **bridge** | 你的电脑 (Node.js, **零依赖**, 只用 `node:` 内置模块) | 手机与 DSH 之间的翻译层: 鉴权、协议转换、把 DSH 的多路复用流拆成"每个会话一条"、在后台扫描会话库 | **8787**(可用 `--port` 改) |
| **relay** | 公网或自建服务器(可选) | **哑管道**: 只搬字节, 不缓存业务数据, 不做业务鉴权 | 8788(明文)/ 8789(TLS)/ 8443(反代后面) |
| **DSH** | 你的电脑(桌面端) | 真正干活的 agent: 代码、终端、模型密钥全在这边 | **动态端口**(自动探测, 见 §10) |

一句话分工: **App 是遥控器, bridge 是解码器, relay 是搬运工, DSH 是干活的人** ✓。

---

## 8. 数据流的三条路 + 心跳

> §3 讲的是"一次请求怎么走完"; 这一节讲的是**这三种通道各自长什么样** ✓。

### 8.1 REST(手机 → bridge)

```
手机 GET /api/v1/sessions
  → bridge POST /api/session/list        (DSH 的 RPC 信封)
    → DSH 返回 { items: [ SessionSummary, … ] }
  → bridge 投影成 PROTOCOL.md 的 SessionSummary
```

读接口(会话列表 / 消息 / 统计 / 待办摘要)都走这条路; 写接口(下发指令 / 取消 / 建会话)也一样,
只是 envelope 里换成 `session/prompt` ✓。细节见 [`PROTOCOL.md`](PROTOCOL.md)。

### 8.2 WebSocket(实时)

```
手机 ws://<host>:8787/ws
  首帧: { "type": "auth", "token": "…" }        ← 认证永远是第一帧 ✓
  之后: { "type": "subscribe" | "prompt" | "ping", … }
  bridge → 手机: { "type": "message.delta" | "session.state" | "pending" | "pong", … }
```

桥接把 DSH `remote.mux` 的 `session/follow` 流(快照 + 增量)按 `streamId` 拆给每个订阅的会话 ✓。

### 8.3 密封层(端到端)

```
手机:  明文 body ──AES-256-GCM(NDK 原生模块)──► 信封(iv‖密文‖tag, base64)
       头里带 SEAL_HEADER / SEAL_ID_HEADER / SEAL_TIMESTAMP_HEADER
       ↓  (中继/代理只看到这一坨 base64)
bridge: 打开信封(密钥由 bridge token + 账号/设备号派生)──► 明文 body ──► 业务处理
```

- 密封发生在**手机上**(NDK 的 AES-256-GCM ✓), 密钥由 **bridge token** 派生(HKDF ✓)——
  中继没有 bridge token, 所以**它打不开信封** ✓。
- 手机的实现和 bridge 的实现**逐字节一致**(固定向量测试守着 ✓)⇒ 两端一定解得开 ✓。
- 降级: 密封不可用时回落到明文 + `Authorization` 头, 功能不受影响(但中继就看得见了 ⚠️)✓。

### 8.4 心跳(为什么需要)

中间的盒子(Cloudflare 之类)会把**空闲**的 WebSocket 当成死连接掐掉; 而一条**半开**的连接
(对端进程没了、但没来得及发 RST)在两端看起来都还活着 ⇒ 得自己发现。

| 链路 | 心跳 | 多久没回应算死 | 死了怎么办 |
|---|---|---|---|
| 手机 ⇄ bridge | 应用层 `{"type":"ping"}` / `{"type":"pong"}` 帧, 每 25 s ✓ | 连续 2 次 ✓ | 手机主动断开并重连 ✓(比等对端掐更快 ✓) |
| 手机 ⇄ bridge | 另有系统层的 WebSocket ping(`pingInterval` / `pongTimeout` ✓) | — | 系统直接断连 ✓ |
| bridge ⇄ relay | 中继协议自带的 `PING(0x12)` / `PONG(0x13)` 帧, 每 25 s ✓ | 连续 3 次 ✓ | bridge 断开重拨 ✓ |

心跳是**控制帧**: 不带业务数据、不进消息正文、不进日志正文 ✓。

---

## 9. 安全模型

| 事实 | 含义 |
|---|---|
| **每设备一个令牌** | 桌面端、每台手机各有自己的设备令牌 ✓; 中继按设备号鉴权 ✓ |
| **令牌用 HUKS 加密后存** | 手机的令牌交给系统的硬件钥匙服务保管, **明文绝不落盘** ✓, 密钥不出手机 ✓ |
| **中继是字节管道** | 只搬字节, **不缓冲**业务数据、不做业务鉴权 ✓; 手机发来的 `Authorization` 头原样透传, 由 bridge 自己裁决 ✓ |
| **端到端密封** | 请求体在手机上就加密了(§8.3 ✓)⇒ **中继看不到内容** ✓ |
| **中继的 `OPEN` 被限制** | 只能开 `127.0.0.1:<bridgePort>` ⇒ 中继不能借设备去扫内网 ✓ |
| **局域网不需要端口映射** | 电脑只**拨出**(到中继 ✓), 从来不需要在路由器上开洞 ✓ |
| **首帧认证** | WebSocket 的第一帧必须是 `auth` ✓ —— 认证之前不接受任何别的帧 ✓ |

一句话: **中继是"不聪明也不好奇"的搬运工, 业务数据要么根本到不了它那儿, 要么到了它也解不开** ✓。

---

## 10. 端口表

| 端口 | 谁连谁 | 协议 | 能不能改 |
|---|---|---|---|
| **8787** | App ⇄ bridge(局域网直连) | http / ws | 能, `--port` ✓ |
| **8788** | App / bridge ⇄ relay(明文) | http / ws | 能, relay 的 `--port` ✓ |
| **8789** | App / bridge ⇄ relay(TLS) | https / wss | 能, relay 的 `--tls-port` ✓ |
| **8443** | 反向代理后面给公网用的 https / wss | https / wss | 能 ✓ |
| **8787** | relay → bridge(**只准开本机这一个**) | 内部流 | 由 bridge 的 `--port` 决定 ✓ |
| **动态端口** | bridge ⇄ DSH | http / ws | **不要写死** ⚠️ |

> ⚠️ **DSH 的端口是动态的** —— 桌面端每次启动的端口都可能变(常见是 `127.0.0.1:10748` ✓,
> 但**不是固定的** ✓)。bridge 靠 `bridge/src/dsh.js` 的 `listeningPorts()` **自动探测** ✓,
> 手机和文档里都**不要**把它写死 ✓; 万一要手动指定, 用 `--dsh-url http://127.0.0.1:<端口>` ✓。

---

## 11. 为什么电脑端必须跑这份代码

这不是可以省掉的步骤, 是设计如此:

1. **bridge 在局域网里应答** —— 手机扫网段的时候, 只有跑着 bridge 的电脑会回话 ✓
   ⇒ 没装这份代码的电脑**根本不响应** ✓ ⇒ 手机扫到的就正好是你要的那台 ✓
   (它同时也是"这台电脑上有 DSH 在跑"的证据 ✓)
2. **DSH 只监听 `127.0.0.1`** —— 手机在局域网里够不着它 ✓; 中间必须有一层
   能替它说话、又懂它的协议的东西 ✓ —— 那就是 bridge ✓
3. **活儿在电脑上干** —— 代码、终端、模型密钥、你的仓库全在电脑上 ✓;
   手机只是一块**带屏幕的遥控器** ✓。手机上的每一个字, 都是电脑上的 agent 真的在干 ✓
4. **以后"把文件从手机发到电脑"** —— 不用改架构, 只需要给 bridge **再加一个上传端点** ✓
   (bridge 本来就是那个"电脑上的入口" ✓)。同理, 远程审批卡片、更多推送方式也都是加端点, 不是重写 ✓
