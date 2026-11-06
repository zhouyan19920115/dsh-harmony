# 账号与多端同步 (Account & Multi-Device Sync)

> 这份文档描述**账号 (account) / 设备 (device)** 这两个实体、它们的配对流程,
> 以及相对于 [`docs/RELAY.md`](RELAY.md) 的线格式改动。
> 实现: `relay/src/accounts.js` (注册表)、`relay/src/server.js` (按账号路由)、
> `bridge/src/relay-client.js` (握手带账号)。

---

## 0. 一句话先说清楚: 这里的"账号"是什么

**账号 = 一个共享密钥 (account token) + 一份属于它的设备清单。**

不是用户账号系统。**没有**密码、**没有**邮箱、**没有**注册流程、**没有**托管后端、
**没有**端到端加密。注册表就是中继机器上的一个 JSON 文件。

想清楚这一点很重要: 本项目里 "account" ≈ Happy Coder 里的 `Account.publicKey` +
一组 `Machine` 记录, 但**去掉了密钥对与签名**, 只留了一个 bearer secret。

---

## 1. 实体模型

### 1.1 Account(账号)

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | `acc-1a2b` | 账号的公开标识。手机用它做路径前缀。 |
| `name` | `我的账号` | 给人看的名字。 |
| `token` | 32 字节 hex (64 字符) | **账号的密钥**。持有它 = 有资格加入这个账号。**常量时间比较**。 |
| `createdAt` | epoch ms | 创建时间。 |
| `devices[]` | 设备列表 | 属于该账号的设备。 |

账号令牌是**唯一的凭据**: 它同时承担两个角色

1. **加入凭据** —— 桌面 bridge 拿它向中继证明"我属于这个账号", 还能把自己的设备
   登记进这个账号;
2. **查询凭据** —— 运维/手机用 `GET /_relay/accounts/<accountId>/devices` 查该账号
   的设备在线状态时必须带上它。

> ⚠️ 持有账号令牌 = 有资格往这个账号里加设备。它是 bearer secret, 不是密码。
> 中继可以用 `--no-join` 关闭"自动加入"(见 §3.2), 那时设备必须事先登记。

### 1.2 Device(设备)

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | `dev-8f2a` | 设备 id。**在账号内命名空间化**: 同一个 `dev-x` 可以同时存在于两个账号下。 |
| `name` | `我的台式机` | 设备名。**以注册表为准**: 桌面在 `HELLO` 帧里自报的名字只在注册表里还没有名字时才会被采用, 客户端不能随意改掉登记好的名字。 |
| `role` | `desktop` \| `phone` | `desktop` 有 bridge 端口, `phone` 没有。 |
| `token` | 32 字节 hex | 设备自己的密钥, **常量时间比较**。 |
| `port` | `8787` | 桌面 bridge 在本机的端口(手机没有这个字段)。 |
| `lastSeen` | epoch ms | 中继最后一次看到这台设备的时刻(桌面 = 收到 `PONG`; 手机 = 收到心跳)。 |

`role` 的区别是实打实的: 手机没有 bridge 可以连, 所以它不会发起 `/bridge` 握手;
它用 HTTP 接口把自己登记进账号(§2.4), 在账号的设备清单里出现(在线状态),
并通过 `/_relay/accounts/...` 读别人的状态。

### 1.3 Session(会话)—— **不是中继的实体**

**中继不知道什么是会话。** 它是哑管道: 只搬运字节。

会话活在 `bridge/` 与 DSH 里(见 [`docs/PROTOCOL.md`](PROTOCOL.md))。中继这一层
唯一和"会话"沾边的东西是**在线状态 (presence)**: 某台桌面设备的 WebSocket 连着,
它就是 online。

本设计对应到 Happy Coder 的模型是:

| 本项目 | Happy Coder (`happy-server`) |
|---|---|
| Account (`acc-…`, token) | `Account` (有 `publicKey`, 无密码) |
| Device (`dev-…`, role, token) | `Machine` (`@@unique([accountId, id])`) |
| 在线状态 `lastSeen` | `Machine.active` + `Machine.lastActiveAt` |
| (不在中继) 会话 | `Session` (`@@unique([accountId, tag])`) |

### 1.4 注册表文件

新格式 `relay/accounts.json`:

```jsonc
{
  "accounts": [
    {
      "id": "acc-1a2b",
      "name": "我的账号",
      "token": "<32 bytes hex>",
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

**旧格式迁移**: 旧的扁平注册表 `relay/devices.json`(`{ "devices": [...] }`)仍然可用。
中继启动时若发现新的 `relay/accounts.json` 不存在, 就把 `relay/devices.json`
里的设备**整体迁进一个账号**, 并把迁移结果写回 `relay/accounts.json`。

迁移是**确定性**的: 旧文件里可以带 `account.id` / `account.name` / `account.token`
提示(以及每个设备上的 `accountId`), 中继会照搬, 不会每次随机生成新账号。
仓库里当前的 `relay/devices.json` 就是这样写的, 所以老部署升级后账号 id 不变。

> ⚠️ 注册表是**中继启动时读一次**的快照。中继在设备加入、或设备上报名字时会把自己
> 内存里的注册表落盘, 所以**运行中手工编辑注册表文件会被下一次落盘覆盖**。
> 要改注册表, 请停中继 → 改文件 → 起中继。

---

## 2. 线格式改动(相对 `docs/RELAY.md` v1)

### 2.1 设备握手(桌面 bridge → 中继)

```
ws://host:8788/bridge?token=<deviceToken>&deviceId=<deviceId>
                                  [&accountId=<accountId>]
                                  [&accountToken=<accountToken>]
```

| 参数 | 必填 | 含义 |
|---|---|---|
| `token` | 是 | 设备令牌 |
| `deviceId` | 是 | 设备 id |
| `accountId` | 否 | 账号 id。设备**必须已登记**在该账号下。 |
| `accountToken` | 否 | 账号令牌。**它就是账号的身份**: 持有它即可加入该账号。 |

判定规则(中继侧, `relay/src/server.js` 的 `#authorizeDevice`):

1. **带 `accountToken`** → 用它反查账号(常量时间)。找到后:
   - 该 `deviceId` 已在账号里 → 还要 `token` 与设备令牌相符;
   - 该 `deviceId` 不在账号里 → **自动加入**该账号(`--no-join` 可关闭), 登记表落盘。
2. **只带 `accountId`** → 账号必须存在, 且该设备必须属于这个账号, `token` 必须相符。
3. **两个都不带** → 旧的扁平注册表路径: 设备 id 必须存在且全局唯一, `token` 必须相符。

任何不匹配 → **401**, 连接直接被关掉。

`HELLO` 帧的 payload 允许多带一个 `accountId` 字段(中继会忽略未知字段),
这样中继日志和排障时能直接看出设备属于谁:

```json
{ "deviceId": "dev-8f2a", "name": "我的台式机", "port": 8787, "accountId": "acc-1a2b" }
```

### 2.2 手机 URL(手机 → 中继)

| 形状 | 状态 | 说明 |
|---|---|---|
| `https://relay/<accountId>/<deviceId>/api/v1/…` | **新** | 账号作用域。设备必须属于该账号, 否则 **404**。 |
| `https://relay/<deviceId>/api/v1/…` | 旧, 保留 | 扁平作用域。设备 id 必须全局唯一; 若同一 id 存在于多个账号 → **409**, 中继不猜。 |
| `https://relay/<accountId>/<deviceId>/ws?token=…` | 新 | WebSocket 升级同上。 |
| `https://relay/<deviceId>/ws?token=…` | 旧, 保留 | 同上。 |

转发给桌面时, 中继把前缀整个剥掉: `/<accountId>/<deviceId>/api/v1/health`
→ 桌面收到 `/api/v1/health`; 旧形状 `/<deviceId>/api/v1/health` → `/api/v1/health`。
**其余字节一个不动**(含 `Authorization` 头)。

> 鸿蒙端的 `parseEndpoint()` 把 host 之后的整段当作 path prefix, 所以
> `https://relay/acc-1a2b/dev-8f2a` 这个新形状**手机端不用改任何代码**就能用:
> 它会自动拼成 `/acc-1a2b/dev-8f2a/api/v1/…` 和 `/acc-1a2b/dev-8f2a/ws?token=…`。

### 2.3 运维端点

| 端点 | 鉴权 | 返回 |
|---|---|---|
| `GET /_relay/health` | 无 | 健康信息。**设备列表按账号作用域**: 不带账号令牌时 `devices` 为空数组。 |
| `GET /_relay/devices` | **账号令牌** | 该账号的设备。**没有令牌 → 401**。 |
| `GET /_relay/accounts/<accountId>/devices` | **账号令牌** | 该账号的设备。 |
| `POST /_relay/accounts/<accountId>/phones` | **账号令牌** | **手机把自己登记**成账号里的一台 `phone` 设备(见 §2.4)。 |
| `POST /_relay/accounts/<accountId>/phones/<deviceId>/heartbeat` | **账号令牌** | **手机的心跳**: 刷新 `lastSeen`(见 §2.4)。 |

账号令牌可以用 `?accountToken=<hex>`, 也可以用 `Authorization: Bearer <hex>`。

```jsonc
// GET /_relay/accounts/acc-1a2b/devices?accountToken=<hex>
{
  "relay": "dsh-harmony-relay",
  "version": "1.0.0",
  "account": { "id": "acc-1a2b", "name": "我的账号" },
  "devices": [
    { "id": "dev-8f2a", "name": "我的台式机", "role": "desktop",
      "online": true, "lastSeen": 1790000000000, "port": 8787 },
    { "id": "dev-p3h1", "name": "我的手机", "role": "phone",
      "online": false, "lastSeen": 0 }
  ]
}
```

**跨账号隔离**: 手机 A 带自己的账号令牌查 `/_relay/accounts/<A>/devices`,
只能看到 A 的设备; 想看 B 的设备, 令牌对不上 → 401。
手机 A 用 `/<acc-A>/<dev-B>/…` 访问 B 的设备 → **404**, 请求根本不会离开中继。

### 2.4 手机自己登记(手机 → 中继)

桌面设备是**靠 WebSocket 握手**进账号的(`ws://…/bridge?token=…&accountToken=…`),
手机没有这个握手 —— 它是 HTTP 客户端。所以手机用两个 HTTP 接口进账号:

```
POST /_relay/accounts/<accountId>/phones
Authorization: Bearer <accountToken>      (或 ?accountToken=<hex>)
Content-Type: application/json

{ "deviceId": "dev-p3h1", "name": "我的手机", "token": "<32 bytes hex>" }
```

`deviceId` 与 `token` **由手机自己生成**并存在自己的私有存储里(手机重装/换机就是新的 id),
所以中继接受客户端自选的 id, 但要校验形状:

| 字段 | 规则 | 不合法 |
|---|---|---|
| `deviceId` | `/^[A-Za-z0-9._-]{1,64}$/` | `400` `{"error":"bad_request",…}` |
| `token` | 64 个 hex 字符(32 字节) | `400` `{"error":"bad_request",…}` |
| `name` | 最多 64 个字符(可以省略) | `400` `{"error":"bad_request",…}` |

登记成功(`200`)回答的是这台设备本身:

```jsonc
// POST /_relay/accounts/acc-1a2b/phones
{
  "device": { "id": "dev-p3h1", "name": "我的手机", "role": "phone",
              "online": true, "lastSeen": 1792640000000 }
}
```

同一个 `deviceId` **再登记一次**的语义:

| 情况 | 答案 | 含义 |
|---|---|---|
| 同一个 `token` | `200` | 一次**更新**: 名字可以改, `lastSeen` 刷新 |
| 不同的 `token` | `409` `device_conflict` | 手机不能抢别人的设备 id |
| 这个 id 属于**别的账号** | `409` `device_conflict` | 设备 id **绝不跨账号搬家** |
| 缺令牌 / 令牌不对 | `401` `unauthorized` | 与其它账号作用域接口同一个说法 |
| 账号不存在 | `404` `unknown_account` | |

手机在线时每 ~30 秒发一次心跳, 这是它唯一的"我还在"信号:

```
POST /_relay/accounts/<accountId>/phones/<deviceId>/heartbeat
Authorization: Bearer <accountToken>
```

回答 `200 { "device": { …同上… } }`, `lastSeen` 被刷新; 设备不属于这个账号 →
`404` `unknown_device`。

> **两种角色的"在线"不是一个东西**: 桌面的在线 = 设备 WebSocket 连着(中继自己知道);
> 手机的在线 = `lastSeen` 在 **60 秒**之内(`PHONE_ONLINE_WINDOW_MS`, `relay/src/server.js`),
> 因为手机只有心跳。`GET /_relay/accounts/<accountId>/devices` 对两者用同一套字段,
> 只是判在线的方式不同。

> **落盘**: 登记会把注册表写回磁盘(`relay/accounts.json`), 所以手机在重启中继之后
> 仍然在账号的设备清单里; 心跳只刷新内存里的 `lastSeen`, 不写盘(每 30 秒写一次太吵)。

> **和 `--no-join` 的关系**: `--no-join` 挡的是"拿着账号令牌**自动**混进账号"的桌面设备
> (`ws://…/bridge` 握手)。手机这个接口是**显式登记**(有请求体、有名字、有自己的设备令牌),
> 不受 `--no-join` 影响 —— 否则手机就永远进不了账号了。

### 2.5 bridge 命令行

```
--account <id>            账号 id, e.g. acc-1a2b
--account-token <hex>     账号令牌; 桌面拿它加入账号
--relay-public-url <url>  中继给手机用的公网基地址 (默认从 --relay 推导)
```

`--account` / `--account-token` 只有配合 `--relay` 才有意义。

---

## 3. 配对流程

### 3.1 桌面端(bridge)

**第一步: 建账号**(在中继的机器上跑一次)

```bash
node relay/src/cli.js --account-create --account-name "我的账号" \
     --device-id dev-8f2a --device-name "我的台式机"
```

输出:

```
account id     : acc-1a2b
account name   : 我的账号
account token  : e1672a17…
device id      : dev-8f2a
device name    : 我的台式机
device token   : 9a2dc23c…
```

**第二步: 起中继**

```bash
node relay/src/cli.js --port 8788 --account-file relay/accounts.json
```

**第三步: 起 bridge, 带账号**

```bash
node bridge/src/cli.js --relay ws://relay.example.com:8788/bridge \
     --device-id dev-8f2a --device-token 9a2dc23c… \
     --account acc-1a2b --account-token e1672a17…
```

握手带上了 `accountId` 与 `accountToken`。中继校验通过后这台桌面就属于 `acc-1a2b`。
(如果 `--account-token` 对的账号里还没有这台设备, 中继会把它登记进去;
加 `--no-join` 则拒绝。)

**第四步: 看配对行**

bridge 启动横幅里会出现:

```
  account id     : acc-1a2b
  pair this phone: http://relay.example.com:8788/acc-1a2b/dev-8f2a
```

以及这个 URL 的二维码(用 `bridge/src/qr.js` 的 `qrToText`, 没有另写编码器)。

### 3.2 手机端

1. 扫桌面上的二维码(或手输 `pair this phone:` 后面那串 URL)。
2. 手机把它填进"桌面端地址"。QR 的 payload 就是那个 URL, 形状固定为:

   ```
   <scheme>://<relay-host>:<phone-port>/<accountId>/<deviceId>
   ```

   例: `http://relay.example.com:8788/acc-1a2b/dev-8f2a`。
   scheme/端口取决于中继是否在单独端口上终止 TLS(公网部署通常要加
   `--relay-public-url https://relay.example.com:8443`)。
3. 手机照旧填 bridge 的 `Bearer token`(桌面横幅里也有)。
4. 手机连的是 `https://relay/<accountId>/<deviceId>/api/v1/…`,
   中继按账号把字节转给那台桌面。

**另外, 手机要把自己登记进这个账号**(§2.4), 这样账号的设备清单里才有"我的手机",
桌面也才看得到"我的手机 online":

```
POST /_relay/accounts/<accountId>/phones
Authorization: Bearer <accountToken>
{ "deviceId": "<手机自己生成的 id>", "name": "我的手机", "token": "<手机自己生成的 32 字节 hex>" }
```

登记一次就够(`200`); 之后手机在线期间每 ~30 秒发一次心跳
(`POST /_relay/accounts/<accountId>/phones/<deviceId>/heartbeat`), 中继按心跳判断它还在不在。

### 3.3 手机想知道"哪些设备在线了"

```bash
curl -s "https://relay.example.com:8443/_relay/accounts/acc-1a2b/devices?accountToken=e1672a17…"
```

返回该账号所有设备(含手机自己)的 `online` / `role` / `name` / `lastSeen`。
**别人的账号查不到**: 令牌对不上就是 401。

**怎么算"在线"**:

| 角色 | 判据 |
|---|---|
| `desktop` | 设备 WebSocket 连着中继 |
| `phone` | `lastSeen` 在 **60 秒**之内(`PHONE_ONLINE_WINDOW_MS`)—— 手机只发心跳 |

---

## 4. 这个东西**不是**什么

请认真读这一节, 别被"账号"两个字骗了:

* **不是用户账号系统。** 没有密码, 没有邮箱, 没有手机号, 没有注册/登录页面,
  没有"忘记密码"。"账号"就是一个共享密钥, 谁拿到它谁就是这个账号的人。
* **没有托管服务。** 中继是你自己(或你公司)跑的一台机器上的一个 Node 进程,
  注册表是那台机器上的一个 JSON 文件。没有云端账号数据库。
* **没有端到端加密。** 中继是哑管道, 手机到桌面的字节**明文**经过中继。
  真实鉴权由 bridge 的 `Bearer token` 中间件做, 但那只是 bearer token, 不是加密。
  (Happy Coder 在这一点上比我们强得多, 见 §5。)
* **没有推送通知。** 没有 APNs/FCM, 没有"任务跑完了推一下手机"。
  中继没有事件推送通道; 现在只有**拉取式**的在线状态查询。
* **没有真正的会话同步。** 会话数据在桌面本地, 手机是通过中继**实时转发**访问它,
  不是"把会话同步到手机本地"。手机离线时看不到任何东西。
* **没有多账号切换。** 一次配对 = 一个账号。手机端目前只有一个"桌面端地址"字段。
* **没有设备撤销。** 账号令牌泄露了没法单独吊销某一台设备 —— 只能换账号令牌,
  而换令牌要手工改注册表。
* **没有权限分级。** 账号里的设备权限完全一样(能进就算能进)。
* **注册表是明文 JSON。** 里面的令牌就是明文, 文件权限就是你的全部安全边界。
  没有加密、没有密钥管理、没有 HSM、没有审计日志。

---

## 5. 和 Happy Coder / VibeTunnel 的对比

### 5.1 Happy Coder (`slopus/happy`, MIT)

它有而我们**没有**的:

* **真正的账号系统**: 服务端账号记录, 公钥签名鉴权(没有密码), 可选 GitHub 登录,
  还有一整套 `AccountAuthRequest` / `TerminalAuthRequest` 的配对握手。
* **端到端加密**: 客户端本地生成密钥, 服务端只存密文("zero knowledge"),
  中继看不到消息内容。我们这边中继看得到全部字节。
* **完整的会话同步**: 会话(`Session`)存在服务端(加密), 多端实时共享同一份会话,
  有 `seq` / `feedSeq` 版本号做增量同步, 还有 `AccessKey` 这种
  `(accountId, machineId, sessionId)` 三元组授权。
* **推送通知**: `AccountPushToken` + 加密推送, 任务完成/需要授权时能推手机。
* **社交/协作**: 好友关系、动态流、共享会话、文件上传、artifact、语音会话。

我们**有**而它**没有**的:

* **零依赖、零数据库**: 一个 JSON 文件 + `node:` 内置模块, `git clone` 完就能跑。
  它那边是 Postgres(PGlite)+ Docker + 一堆环境变量。
* **中继是纯字节管道**: 不解析业务协议, 不存任何东西。断电即忘, 无状态可迁移。
  它的服务端是"加密 blob 存储 + 同步引擎", 复杂得多。
* **HTTP 直通**: 手机发的是标准 HTTP 请求, 原样打到桌面的 bridge,
  桌面自己的中间件鉴权。不需要两边的协议都懂加密信封。
* **账号令牌极简**: 一个 hex 字符串就能配对, 没有公钥基础设施。

### 5.2 VibeTunnel (`amantus-ai/vibetunnel`)

它有而我们**没有**的:

* **终端会话面板**: 一个 web 面板列出所有终端会话, 活动/空闲指示器,
  git follow 模式, 会话录制(asciinema), 控制模式(键鼠路由)。
* **多种远程接入方式**: Tailscale Serve / Funnel、ngrok、Cloudflare Tunnel 开箱即用。
* **会话级口令 / SSH key 鉴权**, 以及"只监听 localhost"模式。

我们**有**而它**没有**的:

* **账号与设备是一等公民**: 设备 id 在账号内命名空间化, 账号之间互相看不见,
  能列出"这个账号下哪些设备在线"。VibeTunnel 是"一服务器一堆会话", 没有账号概念。
* **中继在云上, 桌面只外拨**: 桌面完全在 NAT 后面也不需要端口映射,
  这是它(本地服务器 + 隧道)的模型解决不了的问题。

### 5.3 一句话总结

> Happy Coder 解决的是**"多端共享同一个加密会话"**;
> VibeTunnel 解决的是**"在手机上操控一个终端"**;
> 我们解决的是**"在手机上操控 NAT 后面那台跑着 DSH 的电脑, 而且按账号隔离"**。

---

## 6. 相关文件

| 文件 | 作用 |
|---|---|
| `relay/src/accounts.js` | 注册表: 读/写/迁移, 常量时间比较, 按账号查设备 |
| `relay/src/server.js` | 按账号路由握手与手机 URL, 账号作用域的在线状态端点, 手机自助登记与心跳 |
| `relay/src/cli.js` | `--account-file` / `--account-create` / `--no-join`, 横幅 |
| `relay/accounts.json` | 新的账号注册表 |
| `relay/devices.json` | 旧的扁平注册表(兼容用, 会被自动迁移) |
| `bridge/src/relay-client.js` | 握手带 `accountId` / `accountToken`, 配对 URL |
| `bridge/src/cli.js` | `--account` / `--account-token`, 配对行与二维码 |
| `docs/RELAY.md` | 线格式的唯一真源(账号部分见本文) |
