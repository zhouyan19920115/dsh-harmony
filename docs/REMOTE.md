# 远程使用指南(不在同一局域网)

> 一句话: **可以远程**, 但不要"把电脑的 8787 端口直接暴露到公网"。
> 正确做法是让**桌面端主动外拨**到一台公网中继, 手机也连中继 —— 这正是
> TRAE SOLO / MiniMax Code 等官方产品的做法。

---

## 0. 已验证(本机模拟器 + 真实 DSH + 真实中继)

| 环节 | 结果 |
|---|---|
| bridge 主动外拨中继 | `the device dev-8f2a is online` / `said hello` |
| 经中继取健康状态 | 与直连**完全一致**(`health through relay matches direct : True`) |
| 经中继列会话 | 直连 135 个 = 经中继 135 个 |
| 未授权访问 | 中继返回 **401** |
| 手机经中继看会话 | 会话列表正常, 实时通道 **已连接** |
| 手机经中继建会话 | `relay e2e` 会话创建成功 |
| 手机经中继下发指令 | 桌面 agent 执行, 回复 `RELAY-OK` **原路回到手机** |

截图: `docs/screenshots/09-relay-connect.jpeg` → `10-relay-session-list.jpeg`
→ `11-relay-command-typed.jpeg` → `12-relay-reply-on-phone.jpeg`

> 本机验证用的是明文 `http://10.0.2.2:8788/dev-8f2a`;
> **上公网必须换成 `https://` 并由证书终结 TLS**, 见 §2.2。

---

## 1. 三种方案对比

| 方案 | 电脑要公网 IP? | 手机要装 VPN? | 令牌是否明文过公网 | 适合谁 |
|---|---|---|---|---|
| **A. 云中继(本项目实现)** | 不需要 | 不需要 | 否(TLS) | 任何人, 推荐 |
| B. 路由器端口映射 + TLS 反代 | 需要公网 IP(很多宽带是 CGNAT, 没有) | 不需要 | 否(有 TLS 时) | 有公网 IP 的固定宽带 |
| C. 异地组网(Tailscale / WireGuard) | 不需要 | **需要** —— HarmonyOS NEXT 不能装 Android APK, VPN 客户端生态不确定 | 否 | 愿意折腾的人 |

> **注意 C 的坑**: HarmonyOS 5/6/7 NEXT 是"纯血鸿蒙", 装不了 Android APK。
> Tailscale / ZeroTier 只有 Android/iOS 客户端, 在鸿蒙 NEXT 上没有原生版,
> 所以"电脑装 Tailscale + 手机装 Tailscale"这条路在纯血鸿蒙上走不通。
> 方案 A 正好绕开这个问题: 手机只需要一个普通的 HTTPS/WSS 客户端。

---

## 2. 方案 A:云中继

### 2.1 架构

```
   手机 ──wss/https──►  公网中继  ◄──ws(主动外拨)──  桌面 bridge ──► DSH
```

中继是"哑管道": 它不理解业务协议, 只把两端的字节流对接起来。
手机发给 bridge 的 HTTP 请求(连同 `Authorization` 头)**原样透传**,
最终由 bridge 自己校验令牌 —— 中继不缓存也不解析业务数据。

协议细节见 [`RELAY.md`](RELAY.md)。

### 2.2 部署

**一台公网 VPS**(任意云厂商的轻量应用服务器即可, 1 核 512 MB 够用):

```bash
# 1) 放代码
cd /opt && git clone <你的仓库> dsh-harmony && cd dsh-harmony/relay

# 2) 注册设备: 编辑 devices.json, 自己生成一个 32 字节 hex 令牌
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
#    devices.json:
#    { "devices": [ { "id": "dev-8f2a", "name": "我的台式机", "token": "<上面那串>", "port": 8787 } ] }

# 3a) 用 Caddy / Nginx 做 TLS 终结(推荐, 证书自动续期)
#     Caddyfile:
#     relay.example.com {
#       reverse_proxy 127.0.0.1:8788
#     }
#     然后 relay 只监听 127.0.0.1:8788

# 3b) 或者让 relay 自己终结 TLS(需要一张证书)
#     node relay/src/cli.js --port 8788 --tls-port 8443 \
#         --tls-cert fullchain.pem --tls-key privkey.pem --device devices.json

# 4) 起中继
node relay/src/cli.js --port 8788 --host 127.0.0.1 --device devices.json \
    --public-url https://relay.example.com
```

启动横幅会打印每个设备的"手机该填的地址", 以及设备外拨用的 URL:

```
[relay] INFO  phone urls (enter one of these in the phone app):
[relay] INFO    https://relay.example.com/dev-8f2a   (我的台式机)
[relay] INFO  device dial-in (the desktop bridge needs this):
[relay] INFO    ws://relay.example.com:8788/bridge?token=9a2dc23c…6a4f4d&deviceId=dev-8f2a
```

**桌面端(在家里/公司/任何有网的地方)**:

```bash
node bridge/src/cli.js \
  --relay wss://relay.example.com:8788/bridge \
  --device-id dev-8f2a \
  --device-token <设备令牌>
```

启动横幅会打印出手机该填的地址:

```
[bridge] INFO  cloud relay (the phone may reach the bridge through the relay):
[bridge] INFO    relay url      : wss://relay.example.com:8788/bridge
[bridge] INFO    device id      : dev-8f2a
[bridge] INFO    device name    : 我的台式机
[bridge] INFO    relay connected: yes
[bridge] INFO    phone address  : https://relay.example.com:8788/dev-8f2a
```

**手机端**: 「桌面端地址」填 `https://relay.example.com:8788/dev-8f2a`,
令牌填 bridge 的 `Bearer token`(和局域网直连时是同一个)。

搞定。之后无论手机在 4G、公司还是另一个城市, 都能看到并驱动桌面上的会话。

### 2.3 自检

```bash
# 在中继所在机器上, 模拟手机的请求(必须和直连 bridge 的返回完全一致)
curl -s -H "Authorization: Bearer <bridgeToken>" \
     https://relay.example.com:8788/dev-8f2a/api/v1/health
```

本机一键跑完整条链路(起中继 + 起带 `--relay` 的 bridge + 对比直连/经中继的返回):

```powershell
tools\relay-e2e.ps1 -Keep     # -Keep 表示跑完不关进程, 方便手机接着连
```

它会打印:

```
health through relay matches direct : True
sessions: direct=135  via relay=135  match=True
relay rejects unauthenticated requests: OK (401)
```

---

## 3. 方案 B:端口映射(不推荐但最快)

条件: 你的宽带有**公网 IP**(不是 CGNAT)、路由器支持端口映射、你能改路由器设置。

1. 路由器上把外部 `443` 映射到内网 `8787`;
2. 用 DDNS 绑定一个域名;
3. 在 bridge 前面放一层 TLS 反代(Caddy 最省事):

   ```
   dsh.example.com {
     reverse_proxy 127.0.0.1:8787
   }
   ```

4. 手机填 `https://dsh.example.com`。

坑: 很多运营商给的是 CGNAT, 外部根本连不进来; 端口暴露在公网上, 令牌等于你的 DSH 全部权限。

---

## 4. 地址格式速查

手机端的「桌面端地址」框现在接受**完整 URL**:

| 写法 | 含义 |
|---|---|
| `192.168.1.10:8787` | 局域网直连(省略协议时默认 `http`) |
| `http://10.0.2.2:8787` | 模拟器访问宿主机(`10.0.2.2` 是 QEMU 的宿主机别名) |
| `https://relay.example.com:8443/dev-8f2a` | 云中继, `/dev-8f2a` 是设备号前缀 |
| `https://dsh.example.com` | 前面挂了 TLS 反代的直连 |

解析规则:

1. 没写协议 → 默认 `http://`; `https://` → `wss://`; `ws://` → 按 `http` 处理;
2. 端口省略 → 按协议取默认(80 / 443);
3. 路径前缀原样保留, 作为 REST 与 WebSocket 的共同前缀:
   - REST: `{scheme}://{host}[:{port}]{前缀}/api/v1/…`
   - WebSocket: `{wsScheme}://{host}[:{port}]{前缀}/ws?token=…`

---

## 5. 安全清单

- [ ] 中继的手机侧必须走 TLS(公网证书), 不要裸奔
- [ ] 桌面端连中继的 `deviceToken` 与手机端的 `Bearer token` 是**两个不同的密钥**, 不要混用
- [ ] 中继不注册任何设备 = 任何人都进不来; 设备下线时手机立刻收到 503
- [ ] bridge 仍然只监听本机/局域网, **永远不要把 DSH 的 10748 端口暴露出去**(它是回环设计)
- [ ] 手机端令牌等于你的 DSH 全部读写权限, 泄露就等于把电脑交出去
