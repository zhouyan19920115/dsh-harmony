# dsh-harmony-relay

云中继 (cloud relay) —— 把鸿蒙手机端的请求**原样**搬到桌面的 `bridge/`, 让手机隔着 NAT 也能
驱动桌面上的 DeepSeek Harness。

* 规范: [`docs/RELAY.md`](../docs/RELAY.md)(唯一真源)
* 零运行时依赖: 只用 `node:` 内置模块, 没有 `node_modules`
* Node.js ≥ 20(开发环境 v26)

```
        ┌─────────────┐        wss / https        ┌──────────────┐
        │  鸿蒙手机端  │◄────────────────────────►│              │
        └─────────────┘                           │   云中继       │
                                                  │  (relay/)     │
        ┌─────────────┐        ws (外拨)          │  公网服务器    │
        │  桌面 bridge │◄────────────────────────►│              │
        │  + DSH      │                           └──────────────┘
        └─────┬───────┘
              │ 127.0.0.1:8787
        ┌─────▼───────┐
        │     DSH     │
        └─────────────┘
```

**中继是"哑管道"**: 它不理解 bridge 的业务协议, 只做字节搬运。手机发给 bridge 的 HTTP 请求
(包括 `Authorization` 头)**原样透传**, 由 bridge 自己的鉴权中间件最终裁决。

---

## 1. 快速开始

### 1.1 带账号(推荐)

```bash
# 1) 建一个账号(账号 = 一个共享密钥 + 一份设备清单)
node relay/src/cli.js --account-create --account-name "我的账号" \
     --device-id dev-8f2a --device-name "我的台式机"
#    → 打印 account id / account token / device token

# 2) 启动中继(读账号注册表 relay/accounts.json)
node relay/src/cli.js --port 8788 --account-file relay/accounts.json

# 3) 桌面 bridge 外拨到中继, 带账号
node bridge/src/cli.js --relay ws://127.0.0.1:8788/bridge \
     --device-id dev-8f2a --device-token <deviceToken> \
     --account acc-1a2b --account-token <accountToken>

# 4) 手机/curl 走中继(账号作用域的 URL)
curl -s -H "Authorization: Bearer <bridgeToken>" \
     http://127.0.0.1:8788/acc-1a2b/dev-8f2a/api/v1/health

# 5) 查这个账号下哪些设备在线(要账号令牌)
curl -s "http://127.0.0.1:8788/_relay/accounts/acc-1a2b/devices?accountToken=<accountToken>"

# 6) 手机把自己登记进这个账号(手机端做的, 见 §3.5)
curl -s -X POST "http://127.0.0.1:8788/_relay/accounts/acc-1a2b/phones" \
     -H "Authorization: Bearer <accountToken>" -H "Content-Type: application/json" \
     -d '{"deviceId":"dev-p3h1","name":"我的手机","token":"<32 bytes hex>"}'
```

### 1.2 旧的扁平注册表(仍然可用)

```bash
# relay/devices.json 是旧格式; 中继会自动把它迁移成一个账号
node relay/src/cli.js --port 8788 --device relay/devices.json
```

公网部署时加上 TLS:

```bash
node relay/src/cli.js --port 8788 --account-file relay/accounts.json \
     --tls-port 8443 --tls-cert cert.pem --tls-key key.pem \
     --public-url https://relay.example.com:8443
```

启动横幅会打印:

* 手机端要填的地址 —— `https://relay.example.com:8443/acc-1a2b/dev-8f2a`
* 桌面 bridge 要用的外拨地址 —— `ws://relay.example.com:8788/bridge?token=…&deviceId=dev-8f2a&accountId=…&accountToken=…`

账号 / 设备 / 配对的完整说明见 [`docs/ACCOUNT.md`](../docs/ACCOUNT.md)。

### 命令行参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--port <n>` | `8788` | 明文端口: 桌面 bridge 外拨 + 手机直连测试都用它 |
| `--host <addr>` | `0.0.0.0` | 监听地址 |
| `--account-file <file>` | `relay/accounts.json` | 账号注册表(新格式) |
| `--device <file>` | `relay/devices.json` | 旧的扁平设备注册表, 会被迁移成一个账号 |
| `--bridge-port <n>` | `8787` | 设备侧 bridge 的端口(写进 `OPEN` 帧的目标地址) |
| `--tls-port <n>` | `0`(关闭) | 手机侧 TLS 端口 |
| `--tls-cert/--tls-key` | – | TLS 证书与私钥(PEM) |
| `--public-url <url>` | – | 公网基地址, 只影响横幅里的提示 |
| `--no-join` | 关 | 拒绝"拿账号令牌来、但还没登记"的设备(默认允许自动加入) |
| `--account-create` | – | 建一个账号并写进注册表, 然后退出 |
| `--account-id/--account-name` | – | 建账号时用的 id / 名字 |
| `--device-id/--device-name` | – | 建账号时顺带登记的桌面设备 |

---

## 2. 账号注册表

> 账号 = **一个共享密钥 + 一份属于它的设备清单**。没有密码, 没有邮箱, 没有注册流程,
> 没有托管后端, 没有端到端加密。详见 [`docs/ACCOUNT.md`](../docs/ACCOUNT.md)。

```jsonc
{
  "accounts": [
    {
      "id": "acc-1a2b",
      "name": "我的账号",
      "token": "<32 bytes hex — 账号密钥>",
      "createdAt": 1790000000000,
      "devices": [
        { "id": "dev-8f2a", "name": "我的台式机", "role": "desktop",
          "token": "<32 bytes hex>", "port": 8787, "lastSeen": 0 },
        { "id": "dev-p3h1", "name": "我的手机", "role": "phone",
          "token": "<32 bytes hex>", "lastSeen": 0 }
      ]
    }
  ]
}
```

* `id` —— 账号的公开标识, 手机用它做路径前缀(`/acc-1a2b/dev-8f2a/…`)。
* `token` —— 账号密钥。持有它就能加入这个账号、就能查这个账号的在线状态。**常量时间比较**。
* `devices[].role` —— `desktop`(有 bridge 端口)或 `phone`(没有端口)。
* 设备 id **在账号内命名空间化**: 同一个 `dev-x` 可以同时存在于两个账号下。

旧的扁平格式(`relay/devices.json`)仍然读得懂: 加载时会自动迁移成一个账号,
并把迁移结果写回 `relay/accounts.json`。旧文件可以带 `account` 提示, 让迁移是确定性的。

---

## 3. 协议实现(与 `docs/RELAY.md` 对齐)

### 3.1 帧格式

```
   0                   1                   2                   3
   +-------------------------------+---------------+---------------+
   |         streamId (4B BE)      |    type (1B)  |  length (4B BE)|
   +-------------------------------+---------------+---------------+
   |                      payload (length bytes)                    |
   +---------------------------------------------------------------+
```

注意字段顺序:**`streamId` → `type` → `length`**, 头长 9 字节。`streamId = 0` 表示与具体流
无关的控制帧(握手/心跳)。

| type | 名称 | 方向 | payload |
|---|---|---|---|
| `0x01` | `OPEN` | 中继 → 设备 | `"127.0.0.1:<bridgePort>"` |
| `0x02` | `OPEN_OK` | 设备 → 中继 | 空 |
| `0x03` | `OPEN_ERR` | 设备 → 中继 | UTF-8 错误信息 |
| `0x04` | `DATA` | 双向 | 原始字节 |
| `0x05` | `CLOSE` | 双向 | 空 |
| `0x10` | `HELLO` | 设备 → 中继 | `{"deviceId":"…","name":"…"}` |
| `0x11` | `HELLO_OK` | 中继 → 设备 | `{"relay":"dsh-harmony-relay","version":"1.0.0"}` |
| `0x12` | `PING` | 中继 → 设备 | 空 |
| `0x13` | `PONG` | 设备 → 中继 | 空 |

帧承载在 **WebSocket 二进制消息**里(一个 WS 二进制消息 = 一个中继帧)。分片由 WebSocket 层
自己拼接, 中继帧本身不再分片(`DATA` 单帧上限 256 KB)。

### 3.2 设备握手

```
ws://<relay-host>:8788/bridge?token=<deviceToken>&deviceId=<deviceId>
```

* `token` 与 `deviceId` 必须在查询参数里。
* 令牌不对 / 设备未注册 → 中继回 `HTTP/1.1 401 Unauthorized` 并断开。
* 连接建立后设备发 `HELLO`, 中继回 `HELLO_OK`; 之后才是 `OPEN`/`DATA`/`CLOSE`。

### 3.3 一条流的生命周期

```
手机 ──HTTP/WS──► 中继 ──OPEN streamId=1 "127.0.0.1:8787"──► 设备
                                                     ◄──OPEN_OK──┘
手机 ◄──DATA────  中继 ◄──DATA──────────────────────  设备
手机 ──DATA────►  中继 ──DATA──────────────────────►  设备
       ◄──CLOSE──        ◄──CLOSE──────────────────
```

`streamId` 由中继分配, **每条设备连接从 1 开始递增**。

### 3.4 心跳与超时

| 项 | 值 |
|---|---|
| 中继 → 设备 `PING` | 每 20 秒一帧(`streamId = 0`) |
| 设备 → 中继 `PONG` | 连续 3 个周期没有 `PONG` → 设备掉线, 关闭连接 |
| 流的空闲超时 | 60 秒没有任何数据 → 关流 |
| `OPEN` 超时 | 10 秒没有 `OPEN_OK` → 回 `504` 并关流 |

### 3.5 手机自己登记(手机 → 中继)

桌面设备是靠 WebSocket 握手进账号的; **手机没有这个握手**, 它用一个 HTTP 接口把自己登记成
账号里的一台 `role: "phone"` 设备 —— 这样桌面就能在"多端同步"里看到"我的手机 online"。

```
POST /_relay/accounts/<accountId>/phones
Authorization: Bearer <accountToken>      (或 ?accountToken=<hex>)
Content-Type: application/json

{ "deviceId": "dev-p3h1", "name": "我的手机", "token": "<32 bytes hex>" }
```

`deviceId` 与 `token` 由**手机自己生成**并存在自己的私有存储里, 所以中继接受客户端自选的 id,
但会校验形状:

| 字段 | 规则 | 不合法时 |
|---|---|---|
| `deviceId` | `/^[A-Za-z0-9._-]{1,64}$/` | `400 bad_request` |
| `token` | 64 个 hex 字符(32 字节) | `400 bad_request` |
| `name` | 最多 64 个字符(可省略) | `400 bad_request` |

成功(`200`)时回答的是这台设备本身:

```jsonc
{ "device": { "id": "dev-p3h1", "name": "我的手机", "role": "phone",
              "online": true, "lastSeen": 1792640000000 } }
```

同一个 `deviceId` **再登记一次**:

| 情况 | 答案 | 含义 |
|---|---|---|
| 同一个 `token` | `200` | 是一次**更新**: 名字可以改, `lastSeen` 刷新 |
| 不同的 `token` | `409 device_conflict` | 手机不能抢别人的设备 id |
| 这个 id 属于**别的账号** | `409 device_conflict` | 设备 id **绝不跨账号搬家** |

手机在线时每 ~30 秒发一次心跳, 它是手机唯一的"我在"信号:

```
POST /_relay/accounts/<accountId>/phones/<deviceId>/heartbeat
Authorization: Bearer <accountToken>
```

回答 `200 { "device": { …同上… } }`, `lastSeen` 被刷新; 设备不属于这个账号 → `404 unknown_device`。

**在线状态**: 桌面的在线 = 设备 WebSocket 连着; **手机的在线 = `lastSeen` 在 60 秒之内**
(`PHONE_ONLINE_WINDOW_MS`, 见 `src/server.js`)。`GET /_relay/accounts/<accountId>/devices`
对两种角色都用同一套字段, 只是判在线的方式不同。

> `--no-join` 挡的是"拿着账号令牌**自动**混进账号"的桌面设备(WS 握手); 手机这个接口是
> **显式登记**, 不受 `--no-join` 影响, 否则手机永远进不了账号。

---

## 4. 手机侧: 原始字节管道

这是本实现最需要小心的地方, 所以单独说明。

**手机 → 中继 → 设备** 的请求字节必须**逐字节**到达设备(尤其是 `Authorization` 头和
WebSocket 握手), **设备 → 中继 → 手机** 的响应字节也一样(包括设备自己回的
`101 Switching Protocols`)。实现方式:

1. `http.createServer()` 负责收请求, 但**不使用** `res` 回写业务响应。
2. `server.on('connection')` 拿到 socket, 额外挂一个 `data` 监听, **在 socket 层抓原始字节**。
   Node 的 HTTP 解析器是另一个监听者, 两者拿到的是同一批字节; 中继不依赖 Node 解析出来的
   结果来还原请求。
3. 唯一被改写的是**请求行里的路径前缀**: 手机打的是 `/<deviceId>/api/v1/...`, 设备要的是
   `/api/v1/...`。前缀删除在字节层面做(`src/http-rewriter.js`), 其它一个字节都不动:
   * 头部的顺序、大小写、空格全部保留;
   * `Content-Length` 请求体按原样搬运;
   * `Transfer-Encoding: chunked` 的分块帧原样搬运(不会重新分块);
   * `Expect: 100-continue` 交给设备回答(中继不会自己回 `100 Continue`)。
4. **一个手机 TCP 连接 = 一条流 = 设备侧一条 TCP 连接**。所以 keep-alive 连接上的第二个
   请求也会被原样转给同一条设备连接, 并且它的 `<deviceId>` 前缀同样会被剥掉。
5. WebSocket 升级走 `server.on('upgrade')`: 中继**不自己回 101**, 而是把整段握手请求写进
   一条新流, 设备回的 `101` 和之后的 WebSocket 帧再原样写回手机 socket。
   > 注意: Node 在交接 upgrade socket 时会把 `socket.readableFlowing` 置成 `null`, 数据流会
   > 停住; 中继在接管后必须 `socket.resume()` 才能继续收帧(见 `src/server.js`)。
6. 响应方向中继**不解析** HTTP: 设备的字节直接 `socket.write()` 给手机。`Content-Length`
   / chunked 由手机自己的 HTTP 客户端处理, 所以中继天然不会把响应截断或重组。

---

## 5. 规范留白处的取舍(请对照 `docs/RELAY.md`)

| # | 问题 | 决定 | 理由 |
|---|---|---|---|
| 1 | `streamId` 的作用域 | **每条设备连接从 1 开始** | 规范只说"从 1 递增"; 一条设备连接上的流互相独立更安全 |
| 2 | `OPEN` 目标地址的端口从哪来 | `--bridge-port` → `devices.json` 的 `port` → 设备 `HELLO` 里可选的 `"port"` 字段 | 规范的 `HELLO` 只有 `{deviceId,name}`, 所以必须有默认值; `port` 是**可选**扩展, 设备不发也能工作 |
| 3 | 设备什么时候算"在线" | WebSocket 建连即在线; `HELLO` 仍然必须回 `HELLO_OK` | 避免手机端在 `HELLO` 到达前被误判成 503 |
| 4 | `HELLO` 里的 `deviceId` 和查询参数不一致 | 断开连接 | 防止一个令牌顶替另一个设备 |
| 5 | 中继要不要自己回 `101` | **不要**(规范 §4.2) | 设备的 `Sec-WebSocket-Accept` 必须由设备算, 中继只搬字节 |
| 6 | 手机侧怎么做到字节透明 | socket 层抓原始字节, 只改请求行里的前缀 | `req.rawHeaders` 重建会丢掉分块帧和原始换行; 抓原始字节最忠实 |
| 7 | 一条手机连接能不能开多条流 | **不能**, 一条连接一条流 | 响应会乱序; keep-alive 由设备侧连接自己处理 |
| 8 | 中继自己的接口 | `GET /_relay/health`、`GET /_relay/devices`、`GET /_relay/accounts/<accountId>/devices`、`POST /_relay/accounts/<accountId>/phones`、`POST /_relay/accounts/<accountId>/phones/<deviceId>/heartbeat` | 运维自检 + 手机自己登记; 放在设备路由之前, 不会和 `<deviceId>` 冲突。除 `/_relay/health` 外都要账号令牌(`?accountToken=` 或 `Authorization: Bearer`), 设备列表按账号作用域 |
| 9 | 设备发来 `PING` | 中继回 `PONG` | 对称, 不算新增握手步骤 |
| 10 | 手机断网/关闭 | 中继发 `CLOSE` 给设备并关流 | `CLOSE` 是双向帧 |
| 11 | 手机算不算"在线" | 桌面 = WebSocket 连着; **手机 = `lastSeen` 在 60 秒内** | 手机没有 WebSocket 通道, 它只发心跳, 所以在线状态只能看时间戳 |

### 错误码

| 场景 | 状态码 | 说明 |
|---|---|---|
| `deviceId` 未注册 | `404` | JSON `{"error":"unknown_device",…}` |
| 设备已注册但离线 | `503` | JSON `{"error":"device_offline",…}`; 升级请求时是裸的 `HTTP/1.1 503 Service Unavailable` |
| 设备回 `OPEN_ERR` | `502` | JSON 里带设备给的错误信息 |
| 设备 10 秒不回 `OPEN_OK` | `504` | |
| 设备令牌不对 | `401` | 设备侧握手用, 直接关连接 |
| 账号令牌不对 / 缺账号令牌 | `401` | 账号作用域的接口用; JSON `{"error":"unauthorized","message":"the account token is required"}` |
| 账号不存在 | `404` | JSON `{"error":"unknown_account",…}` |
| 设备不属于该账号 | `404` | JSON `{"error":"unknown_device",…}` |
| 设备 id 在多个账号里都有 | `409` | 旧的 `/<deviceId>/…` 形状无法定位, 要改用 `/<accountId>/<deviceId>/…` |
| 手机登记的 `deviceId`/`token`/`name` 不合法 | `400` | JSON `{"error":"bad_request",…}` |
| 手机登记时设备 id 已被占用(别的令牌 / 别的账号) | `409` | JSON `{"error":"device_conflict",…}`; 设备 id 绝不跨账号搬家 |
| 对 `/_relay/accounts/…/phones` 用了非 POST | `405` | JSON `{"error":"method_not_allowed",…}` |

---

## 6. 目录结构

```
relay/
├── devices.json          设备注册表(示例设备)
├── package.json
├── README.md
├── src/
│   ├── cli.js            命令行入口 + 启动横幅
│   ├── server.js         中继主体: 设备 WS 服务 + 手机 HTTP 服务 + 流转发
│   ├── device-session.js 设备连接: 帧处理 / 流 / 心跳
│   ├── frames.js         帧编解码(9 字节头)
│   ├── http-rewriter.js  请求扫描 + 前缀剥离(字节透明)
│   ├── devices.js        注册表读取 + 常量时间令牌比较
│   └── ws.js             极简 RFC6455 服务端(只给设备侧用)
└── test/
    ├── run.js            零依赖测试运行器
    └── helpers.js        假设备 / 假 bridge / WebSocket 客户端
```

---

## 7. 测试

```bash
cd relay
node test/run.js
```

覆盖: 帧编解码往返、错误设备令牌被拒(401)、流双向跑字节、`Authorization` 头原样到达、
`CLOSE` 结束流、keep-alive 多请求、WebSocket 升级原始透传、未知设备 404、离线设备 503、
设备打不开连接 502、心跳超时掉线; 外加手机自助登记: 登记/更新/换令牌 409、缺令牌 401、
未知账号 404、非法输入 400、心跳刷新 `lastSeen`、账号之间的设备互相看不见。

---

## 8. 给 `bridge/src/relay-client.js` 的对接说明

1. **字节序**: `streamId` 与 `length` 都是 **大端**; 头长 9 字节, 顺序是
   `streamId(4) | type(1) | length(4)`。
2. **传输层**: 一个中继帧 = 一个 WebSocket **二进制**消息(用 opcode `0x2`)。不要用文本帧。
3. **握手**: 连上以后**第一帧**发 `HELLO`(payload 是 `{"deviceId","name"}` 的 JSON, UTF-8),
   收到 `HELLO_OK` 再干活。`HELLO_OK` 的 payload 是
   `{"relay":"dsh-harmony-relay","version":"1.0.0"}`。
4. **`OPEN`**: 收到 `OPEN` 后连 `payload` 里的 `"host:port"`, 连上就回 `OPEN_OK`(空 payload),
   连不上回 `OPEN_ERR`(payload 写错误信息)。设备侧只允许连 `127.0.0.1:<bridgePort>`。
5. **`DATA`**: 原样搬运 TCP 字节, 不要解析。单帧 payload 不要超过 256 KB。
6. **`CLOSE`**: 双向; 收到就关掉对应的 TCP 连接, 并且回一个 `CLOSE`(中继也会回一个, 注意别
   无限互相回)。
7. **心跳**: 中继每 20 秒发一个 `PING`(`streamId = 0`, 空 payload), **必须**回 `PONG`
   (`streamId = 0`, 空 payload)。连续 3 个周期不回, 中继会认为设备掉线并关闭连接。
8. **流编号**: 中继分配, 每条设备连接从 1 开始; 设备不要自己分配 `streamId`。
9. **设备重连**: 同一 `deviceId` 再次连接会顶掉旧连接, 设备端要能接受这一点。
10. **中继不鉴权手机**: `Authorization` 头原样转给你, 由 bridge 自己裁决。
11. **超时**: 一条流 60 秒没有任何数据会被中继关掉; `OPEN` 10 秒没有 `OPEN_OK` 会被中继放弃。
