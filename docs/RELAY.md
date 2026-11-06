# 云中继协议 (Relay Protocol) v1

> 这份文档是**桌面桥接服务 ↔ 云中继** 与 **手机端 ↔ 云中继** 的唯一真源。
> 两个实现者(`relay/` 服务端 与 `bridge/src/relay-client.js` 客户端)必须严格按本文档对齐。

---

## 0. 为什么需要它

局域网直连有硬伤: 家庭宽带多为 CGNAT(无法端口映射)、令牌明文过公网、
桌面端处于 NAT 后无法被公网主动连接。

因此采用与 TRAE SOLO / MiniMax Code 相同的模型: **桌面端主动外拨**到云中继,
手机端也连云中继, 中继把两端的字节流对接起来。桌面端永远不需要公网入口。

```
        ┌─────────────┐        wss / https        ┌──────────────┐
        │  鸿蒙手机端  │◄────────────────────────►│              │
        └─────────────┘                           │   云中继       │
                                                  │  (relay/)     │
        ┌─────────────┐        ws (外拨)          │  公网服务器    │
        │  桌面 bridge │◄────────────────────────►│              │
        │  + DSH      │                           └──────────────┘
        └─────┬───────┘
              │ 127.0.0.1:10748
        ┌─────▼───────┐
        │     DSH     │
        └─────────────┘
```

**中继是"哑管道"**: 它不理解 bridge 的业务协议, 只做字节搬运。
手机发给 bridge 的 HTTP 请求(包括 `Authorization` 头)**原样透传**,
由 bridge 自己的鉴权中间件最终裁决 —— 中继不参与业务鉴权。

---

## 1. 角色与凭据

| 角色 | 方向 | 凭据 |
|---|---|---|
| **设备 (device)** | bridge 主动外拨到中继 | `deviceToken`: 中继签发, 与设备一一对应 |
| **手机 (phone)** | 手机连中继 | 复用 bridge 的 `Bearer token`(原样透传给 bridge 校验) |

设备注册在中继的配置文件里:

```jsonc
// relay/devices.json
{
  "devices": [
    { "id": "dev-8f2a", "name": "我的台式机", "token": "<32 bytes hex>" }
  ]
}
```

中继只信任这些 `token`; 未注册的设备连接会被立即关闭。

---

## 2. 设备侧连接 (bridge → relay)

### 2.1 连接

```
ws://<relay-host>:8788/bridge?token=<deviceToken>&deviceId=<deviceId>
```

- `token` 与 `deviceId` 必须在查询参数里(浏览器/ArkTS 的 WebSocket 握手不方便带自定义头)。
- 握手失败(`401`)时中继返回 `HTTP/1.1 401 Unauthorized` 并关闭。
- 设备掉线时中继立刻把该设备标记为离线, 之后手机的新请求会收到 `503`。

### 2.2 心跳

中继每 20 秒向设备发一个 `PING` 帧(见 §3), 设备必须回 `PONG`。
连续 3 个周期没有 `PONG`, 中继认为设备掉线并关闭连接。

### 2.3 单连接承载多路流

一条设备连接上可以同时跑多条"流"(stream), 每条流对应一个手机侧连接。
流用 `streamId` (4 字节, 由中继分配, 从 1 递增) 区分。

---

## 3. 帧格式

设备连接上的所有载荷都是**二进制帧**, 结构固定:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-------------------------------+---------------+---------------+
|         streamId (4B BE)      |    type (1B)  |  length (4B BE)|
+-------------------------------+---------------+---------------+
|                      payload (length bytes)                    |
+---------------------------------------------------------------+
```

> `streamId = 0` 表示"与具体流无关"的控制帧(握手、心跳)。

### 3.1 帧类型

| type | 名称 | 方向 | payload | 含义 |
|---|---|---|---|---|
| `0x01` | `OPEN` | 中继 → 设备 | UTF-8 `"<host>:<port>"` | 请求设备打开一条到该地址的 TCP 连接 |
| `0x02` | `OPEN_OK` | 设备 → 中继 | 空 | 连接已建立 |
| `0x03` | `OPEN_ERR` | 设备 → 中继 | UTF-8 错误信息 | 连接失败, 中继向手机返回 502 |
| `0x04` | `DATA` | 双向 | 原始字节 | TCP 数据 |
| `0x05` | `CLOSE` | 双向 | 空 | 关闭该流 |
| `0x10` | `HELLO` | 设备 → 中继 | UTF-8 JSON `{ "deviceId": "…", "name": "…" }` | 建链后的第一帧 |
| `0x11` | `HELLO_OK` | 中继 → 设备 | UTF-8 JSON `{ "relay": "dsh-harmony-relay", "version": "1.0.0" }` | 握手确认 |
| `0x12` | `PING` | 中继 → 设备 | 空 | 心跳 |
| `0x13` | `PONG` | 设备 → 中继 | 空 | 心跳应答 |

### 3.2 状态机

```
设备                                              中继
 │  WS connect /bridge?token=…&deviceId=…  ───────►│
 │  HELLO  {deviceId, name}                 ────────►│
 │  HELLO_OK                                 ◄───────│
 │                                              │
 │                                        收到手机请求
 │  OPEN   streamId=7  "127.0.0.1:8787"    ◄───────│
 │  OPEN_OK streamId=7                     ────────►│
 │  DATA   streamId=7  <HTTP 请求字节>      ────────►│
 │  DATA   streamId=7  <HTTP 响应字节>      ◄───────│
 │  CLOSE  streamId=7                     ◄───────►│
```

- `OPEN` 的目标地址是**设备侧**的地址。设备默认只允许打开 `127.0.0.1:<bridgePort>`,
  其它目标一律 `OPEN_ERR` —— 中继不能借设备当跳板去扫内网。
- `DATA` 的 `length` 最大 256 KB, 更大的话分片发送(接收方按流拼接即可)。

---

## 4. 手机侧连接 (phone → relay)

### 4.1 URL 形状

```
https://<relay-host>:<port>/<deviceId>/api/v1/sessions
https://<relay-host>:<port>/<deviceId>/api/v1/sessions/{id}/messages
wss://<relay-host>:<port>/<deviceId>/ws?token=<bridgeToken>
```

- `<deviceId>` 是路径前缀, 中继会把它剥掉再把剩余部分原样转给设备。
  设备未在线 → `503`; `deviceId` 不存在 → `404`。
- 手机的 `Authorization: Bearer <bridgeToken>` 头**原样透传**, 由设备校验。

### 4.2 WebSocket 升级

手机对 `/<deviceId>/ws` 发 `Upgrade: websocket` 时:

- 中继**不自己回 101**, 而是把整个 HTTP 握手请求(原始字节)写进一条流,
  由设备的 WebSocket 服务端回 101 —— 这样中继不需要实现 WebSocket 协议。
- 中继在拿到手机的 upgrade 请求后, 建立一条新流, 把请求字节写进去,
  然后把这条流的响应字节原样写回手机 socket。
- 之后这条流上跑的就是手机的 WebSocket 帧字节, 中继仍然只搬运字节。

实现要点(Node `http`): 注册 `server.on('upgrade', …)` 后 Node **不会**自动回 101,
所以中继要自己在 `upgrade` 事件里接管 socket, 写原始字节, 并把 socket 的
后续数据当作"流数据"处理。

---

## 5. 手机端怎么填地址

手机端的"桌面端地址"输入框现在接受**完整 URL**, 例如:

```
https://relay.example.com:8443/dev-8f2a
ws://192.168.1.10:8787
http://10.0.2.2:8787
```

解析规则:

1. 没写协议 → 默认 `http://`; 写了 `https://` → `https://`; 写了 `wss://` → `wss://`。
2. `http` → `ws`, `https` → `wss`。
3. 路径部分(例如 `/dev-8f2a`)保留, 作为 API 与 WebSocket 的共同前缀。
4. 最终:
   - REST: `{scheme}://{host}[:{port}]{prefix}/api/v1/...`
   - WebSocket: `{wsScheme}://{host}[:{port}]{prefix}/ws?token=…`

---

## 6. 安全要求

| 项 | 要求 |
|---|---|
| 中继 ↔ 设备 | 必须走 TLS(`wss://`), 或部署在受信网络内; 明文 `ws://` 只允许在本地/内网测试 |
| 中继 ↔ 手机 | 必须走 TLS(`https/wss`), 由公网证书终结 |
| 设备鉴权 | `deviceToken` 常量时间比较, 失败即关连接 |
| 手机鉴权 | 由设备(即 bridge)最终裁决, 中继不缓存业务数据 |
| 目标限制 | 设备只允许 `OPEN` 到 `127.0.0.1:<bridgePort>` |
| 超时 | 空闲 60 秒无数据的流自动关闭; 设备 60 秒无 `PONG` 视为掉线 |

---

## 7. 离线自测

```bash
# 1) 起一个本地中继(设备注册在 relay/devices.json)
node relay/src/cli.js --port 8788 --tls-port 0 --device relay/devices.json

# 2) 让 bridge 外拨到本地中继
node bridge/src/cli.js --relay ws://127.0.0.1:8788/bridge --device-token <token>

# 3) 手机(或 curl)连中继
curl -s -H "Authorization: Bearer <bridgeToken>" \
     http://127.0.0.1:8788/dev-8f2a/api/v1/health
```

第 3 步返回的 JSON 必须与直连 bridge 时**完全一致**。
