# DSHsync — 鸿蒙手机端 · 桌面 AI 代理控制器

在鸿蒙手机上查看桌面端 DeepSeek Harness(DSH)的会话, 并把手机上的指令下发给桌面端执行。

---

> ## ⚠️ 部署前必读: 所有服务器地址 / IP 都要换成你自己的
>
> 这份文档里的地址、域名、令牌、应用凭据**全部是占位或作者本机的示例**,
> 直接照抄会连到别人的机器, 或者根本连不上。**开源版本不含任何可用服务器**, 你必须自己填。
>
> | 出现在哪 | 文档里写的(占位) | 你要换成 |
> |---|---|---|
> | 手机「桌面端地址」(局域网) | `192.168.1.10:8787` | **你自己电脑的局域网 IP** —— bridge 启动时终端会打印 `手机端地址: http://<你的IP>:8787` |
> | 手机「桌面端地址」(模拟器) | `10.0.2.2:8787` | 不用改(这是模拟器指向宿主机的固定别名) |
> | 手机「桌面端地址」(远程) | `https://relay.example.com:8443/acc-1a2b/dev-8f2a` | **你自己中继的域名或公网 IP** + 你自己的账号/设备号 |
> | bridge `--relay` | `wss://relay.example.com:8788/bridge` | **你自己中继的地址**(见 [`docs/REMOTE.md`](docs/REMOTE.md)) |
> | 自建中继命令 | `--domain relay.example.com` | **你的域名**(要能把 80/443 解析到那台机器) |
> | 中继监听 | `0.0.0.0:8788` | 需要换端口就改 `--port` |
> | 华为 Push Kit | 空(默认关闭) | **你自己在华为开发者联盟申请的 appId / secret**(见 `bridge/src/push.js` 顶部说明) |
> | 桌面端 DSH | `http://127.0.0.1:10748` | 默认自动探测; 你的 DSH 端口不同就加 `--dsh-url` |
> | DevEco Studio 路径 | `tools/` 里默认 `D:\APP\Devecostudio26\DevEco Studio` | **你自己的安装目录**: 用 `-DevEco` 参数或 `DEVECO_STUDIO_PATH` 环境变量 |
>
> **中继默认是关的, 本项目不提供公共中继。** 只在同一 WiFi 下用(局域网直连)就完全不需要中继;
> 要跨网络访问, 必须自己架一台(一台 1 核 VPS + 一个域名 + 一条命令, 见
> [`docs/SELF-HOST.md`](docs/SELF-HOST.md))。
>
> **权限提醒**: 访问令牌等价于你电脑的执行权限。别把 8787 或中继直接裸开到公网。

---

## 这是什么

MiniMax Code / TRAE SOLO / Claude Code Remote 这些产品都已经有手机端: 桌面上跑着 agent, 手机上能看到进度、能追加指令、能处理授权确认。
**但它们的鸿蒙客户端并不存在** —— 官方只发布了 iOS / Android 版, 社区里只有几个 star 数个位数的 ArkTS 实验品。

这个项目补上这一块: 一个**真正能编译、能装到真机或模拟器上**的 HarmonyOS ArkTS 客户端, 外加一个桌面端桥接服务。

```
┌──────────────┐    HTTP + WebSocket    ┌────────────────────┐    RPC / WS    ┌──────────────────┐
│  鸿蒙手机端   │◄──────────────────────►│  桌面端 bridge 服务 │◄──────────────►│  DeepSeek Harness│
│  ArkTS / ArkUI│      局域网 / 中继     │      (Node.js)      │  127.0.0.1    │  (127.0.0.1:10748)│
└──────────────┘                        └────────────────────┘                └──────────────────┘
```

手机端负责"看"和"说", 真正的执行永远发生在桌面上 —— 代码、终端、模型密钥都不离开电脑。

**界面直接对齐桌面端**: 深色主题、按工作区分组的会话树、会话页的「对话 / 轨迹」双视图、
悬浮在对话上方的输入区(`+` 号 / 权限模式 / 模型 / 蓝色发送键), 以及底部那条
`12 轮 512 步 · 461K tok · 上下文 195K/512K` 的用量状态条。
配色是从桌面端界面上直接采样出来的, 见 `harmony/entry/src/main/ets/common/Theme.ets`。

**桌面端有的, 手机端也有**:

| 桌面端 | 手机端 |
| --- | --- |
| 队列中排队的对话任务框 | 输入区上方的绿色队列条, 可展开、编辑、插队、删除 |
| 输入框左边的 `+`(指令 / 技能 / 文件) | 同样位置的 `+`, 弹层里分「指令 / 技能 / 文件」三页, 点一下插进输入框 |
| 输入框右边的模型选择 | 同样位置的小胶囊, 弹层里按 provider 分组选模型与推理强度 |
| 设置 | 右上角齿轮, 连接 / 模型 / 权限 / 显示 / 关于 五组 |
| 对话 / 轨迹 双视图 | 同样两个页签 |
| 权限模式提示 | 输入区的权限胶囊 |
| 新建任务时选 工作区 / 模式 / 权限 | 同样三项, **手机上就能选**, 不再是"去桌面端改" |
| 侧边栏「对话 + 话题」两级树 | 一级是对话, 点开后话题/子任务缩进出现在它后面 |
| 待办提醒 | 右上角红色角标(正在跑 + 排队中的任务数), 桌面端一有动静就 Push Kit 推一条通知 |
| 大屏双栏 | 三折叠 / 平板展开时自动变成「左边会话树 + 右边会话详情」, 窄屏保持单栏 |

**手机上零手输就能找到电脑**: 同一 WiFi 下点「自动发现」→ 手机扫描本机网段 → 电脑上跑着的
bridge 在 `/_dsh/discover` 应答(没装这套代码的电脑不响应, 所以扫到的就是那台) → 用 60 秒
的一次性配对码换令牌 → 自动连上。**要离开局域网**: 点「切到远程」, 电脑把中继地址和令牌交给
手机, 手机自己切过去(令牌依旧可见可复制)。

*(截图略——公开版不含实机截图)*
*(截图略——公开版不含实机截图)*
*(截图略——公开版不含实机截图)*
*(截图略——公开版不含实机截图)*
*(截图略——公开版不含实机截图)*
*(截图略——公开版不含实机截图)*
*(截图略——公开版不含实机截图)*
*(截图略——公开版不含实机截图)*

---

## 真机实测

已经在**华为 Mate 80**(VYG-AL00, HarmonyOS 6 / API 26)上跑通: 签名安装 → WiFi 连桌面端 →
211 个会话实时同步 → 顶栏待办角标 → Push Token 上报 → 三折叠双栏。
完整步骤见 **[docs/PHONE-SETUP.md](docs/PHONE-SETUP.md)**。

---

## 目录结构

```
DSHHarmony/
├─ harmony/          鸿蒙端工程(DevEco Studio / hvigor / ArkTS)
│  └─ entry/src/main/ets/
│     ├─ common/     BridgeClient(WS+REST) / Config / Http / Models / Theme / TimeFmt / SettingsStore
│     ├─ pages/      ConnectPage / SessionListPage / SessionPage / DevicesPage / SettingsPage
│     └─ entryability/EntryAbility.ets
├─ bridge/           桌面端桥接服务(零依赖 Node.js)
├─ relay/            云中继服务(零依赖 Node.js, 让手机跨网络访问桌面)
├─ docs/
│  ├─ PROTOCOL.md    手机 <-> 桥接 的 v1 协议
│  ├─ RELAY.md       桌面 <-> 云中继 的 v1 协议
│  ├─ ACCOUNT.md     账号 / 设备 / 多端同步模型
│  ├─ REMOTE.md      远程使用部署指南
│  ├─ RESEARCH-mobile-agent-clients.md  开源项目调研(UI + 账号架构)
│  └─ ARCHITECTURE.md
├─ research/         竞品与既有方案调研
├─ tools/            构建 / 探针脚本
└─ DSH_HTTP_API_MAP.md   DSH 内部 API 的实测地图
```

---

## ⚠️ 先改这些占位符（本仓库不含任何真实 IP / 域名 / 邮箱 / 密码）

这个仓库是**脱敏后的开源版本**，所有敏感信息都换成了占位符，跑起来之前请按下面的表改成你自己的：

| 占位符 | 出现在哪里 | 说明 |
|---|---|---|
| `YOUR_RELAY_IP` / `YOUR_SERVER_IP` | `tools/relay-ssh.py`、`tools/relay-upload.py`、`tools/relay-download.py` 等 | 你自己的中继服务器 / 服务器公网地址（也可用环境变量 `RELAY_HOST` 覆盖） |
| `relay.example.com` / `dsh-relay.example.com` | 文档、`.env` 示例、隧道 / nginx 部署脚本 | 你自己的域名（云中继要走**隧道**还是 **A 记录**，见 `docs/SELF-HOST.md`） |
| `you@example.com`、`YOUR NAME`、`开发者` | `harmony/entry/src/main/ets/common/Legal.ets`、`harmony/deploy/legal/*.html` | 隐私政策 / 用户协议里的联系人与开发者主体 |
| `YOUR_KEYSTORE_PASSWORD` | `tools/build-hap.ps1`、`tools/install-release-internal.ps1` | 你自己的 HAP 签名密钥口令 |
| `YOUR_ENCRYPTED_PWD` | `docs/PHONE-SETUP.md` 示例 | DevEco 导出的 `storePassword` / `keyPassword` 密文 |
| `com.example.dshsync` | `harmony/AppScope/app.json5`、`module.json5` 等 | **改成你自己的包名**（bundleName 必须全局唯一，否则装不上/上架冲突） |
| `D:\APP\Devecostudio26\DevEco Studio` | `tools/*.ps1` | 改成你自己的 DevEco 安装路径（多数脚本支持 `-DevEco` 参数或 `DEVECO_STUDIO_PATH`） |

签名证书、`.p12`/`.p7b`/`.cer`、`relay/accounts.json`、`bridge/bridge.json` 等**都没有进仓库**，
需要你在自己机器上生成，见下面的「构建前必读(签名)」。

## 快速开始

### 0. 推荐: 装 DSH 插件(电脑端一步搞定, 不用装 Node)

在 **DeepSeek Harness** 里装 `dsh-harmony-bridge` 插件, 桥接会随 DSH 自动启动:

1. DSH → **插件** → **市场 / 发现** → 「添加市场索引」, 粘贴:
   `https://raw.githubusercontent.com/zhouyan19920115/dsh-harmony-bridge/main/index.json`
   (需要先打开「自定义插件市场」这个实验开关)
2. 在「发现」里搜 **DSH Harmony 手机桥接** → 安装 → **启用** → 重启一次 DSH;
3. 手机装 **DSHsync** → 点「**自动探测**」→ 连上, 完事。

- 桥接默认端口 **8787**, 随 DSH 启动, 不需要填地址/令牌;
- 手机自动探测会扫 **8787–8799 + 8899**, 改端口也不用手机手动处理;
- 插件设置: 插件页右上角「**打开桥接设置**」, 可改端口 / 云中继 / 开机自启。

### 附件：图片 / 文件（插件 v0.2.0+）

会话输入框左下角 **+** → **图片 / 文件**：

- 图片从相册选、文件从文件管理选，**原始字节直传**到电脑（不走 base64，局域网秒级）；
- 桥接把文件写到 `~/.dsh-harmony-bridge/uploads/<日期>/`，返回电脑上的绝对路径；
- App 会自动把 `@C:\...\uploads\...` 插进输入框，发出去之后桌面端的 agent 就能读到这个文件
  （图片同理，能不能"看图"取决于桌面端模型的视觉能力）；
- 目前**远程（云中继）模式暂不支持上传**，会提示切回局域网；语音（录音/转文字）在下一步。

### 本地通知（不依赖云端推送）

不需要华为 Push Kit / 云服务器：任务跑完、桌面在等你回答时，App 会直接调用
`notificationManager.publish` 发本地通知，点通知直达对应会话。

注意：本地通知需要 App 进程还在运行才会到。为了不让通知栏被一条「正在运行数据传输任务」
的常驻通知占着，本项目**不使用后台长时任务**（默认就是干净的，通知栏不会常驻）。

### 1. 备用方案: 手动跑桌面端桥接(不装插件/别的电脑)

| # | 在哪 | 做什么 |
|---|---|---|
| 1 | 手机 | 装 **DSHsync** |
| 2 | 电脑 | App 里把「桌面端程序」发到电脑 → 解压 → **双击 `双击我-开始.cmd`** |
| 3 | 手机 | App 里点「**自动探测**」→ 选中「我的台式机」→ 配对 → 开始用 |

- 电脑上不需要装 Node: 那个包里带的是单文件可执行程序
  (`dsh-harmony-bridge.exe`, 约 55 MB), 拷到任何一台 Windows 电脑上双击就能跑;
- 不需要域名 / VPS / 证书 / 注册账号(只在同一 WiFi 下用的时候): 账号 id、设备 id、
  令牌全部在本机生成, 局域网直连不需要任何中间服务器;
- 要离开局域网, 中继得你自己架一台(默认关闭, 本项目不提供公共中继) ——
  见 **[`docs/SELF-HOST.md`](docs/SELF-HOST.md)** 第 2 章: 一台机器 + 一个域名 + 一条命令。

### 2. 桌面端: 用源码启动桥接服务(开发者)



```powershell
node bridge\src\cli.js
```

**更省事(给别人用推荐这个)**: 双击 `tools\start-desktop.cmd` —— 它会检查 Node、检查端口、
拉起服务, 并把地址、令牌、配对码和「手机怎么连」一起打印出来; 加 `--with-relay` 还能
顺手把云中继拉起来(远程用)。完整说明见 [docs/QUICKSTART.md](docs/QUICKSTART.md)。

> **不想装 Node 的用户**: 用单文件可执行程序版本
> (`dsh-harmony-bridge.exe`, 约 55 MB, 自带运行时)。它和源码版是同一套程序, 行为一样,
> 只是不用 `node` 启动 —— 直接双击即可。产物由
> `tools\build-desktop-exe.ps1` 打出, 再由 `tools\package-desktop.ps1` 打成两个包:
> `dsh-harmony-desktop-exe.zip`(单文件 exe, **什么都不用装**) 和
> `dsh-harmony-desktop.zip`(源码, 需要 Node.js 20+)。两个包解压出来都是同一个文件夹
> `DSH-Harmony-桌面端`, 里面都是那个 `双击我-开始.cmd`。
> 打包之后有一道**自检**: 包里只要出现账号注册表、设备注册表、令牌文件或私钥,
> **打包直接失败**并把那个 zip 删掉 —— 免得把别人的账号令牌发出去。

启动后终端会打印:

```
[bridge] 监听 0.0.0.0:8787
[bridge] 手机端地址: http://192.168.1.23:8787
[bridge] 访问令牌:  7f3c…  (同时以二维码形式打印)
```

令牌保存在 `%USERPROFILE%\.dsh-harmony-bridge\bridge.json`, 只需配对一次。

可选参数:

| 参数 | 说明 |
|---|---|
| `--port 8787` | 监听端口 |
| `--host 0.0.0.0` | 监听地址(默认全网卡, 便于手机访问) |
| `--allow-unauth-pairing` | 允许非本机读取配对信息 |
| `--dsh-url http://127.0.0.1:10748` | DSH 地址(**默认自动探测** —— 桌面端每次启动端口会变, 桥接会自己找) |
| `--relay ws://host:8788/bridge` | 接云中继(桌面端主动外拨, 不需要端口映射) |
| `--device-id dev-8f2a` | 设备号(中继路由用) |
| `--device-token <64 hex>` | 设备令牌 |
| `--account acc-1a2b` | 账号 id(多端同步用) |
| `--account-token <64 hex>` | 账号令牌 |
| `--config <file>` | 用 JSON 文件写这些参数(见下), 命令行优先 |

**也可以用配置文件**, 放在 `%USERPROFILE%\.dsh-harmony-bridge\bridge.config.json`:
只写**地址**, 不写令牌 —— 账号 id、设备 id、令牌全部是本机生成的, 配置文件里写了会被
直接拒绝(免得令牌被抄进一张截图):

```json
{
  "relay": "wss://relay.example.com/bridge",
  "relayPublicUrl": "https://relay.example.com",
  "deviceName": "我的台式机"
}
```

第一次运行、还没有凭据的时候, 桥接会**自动去中继登记**: 本机生成账号 id / 设备 id /
密钥, 中继签发令牌, 令牌写进 `%USERPROFILE%\.dsh-harmony-bridge\bridge.json`。
登记失败会**直接把原因打出来并停下**(不会悄悄失败) —— 因为登记不上, 手机就找不到
这台电脑。

### 3. 手机端: 构建并安装

```powershell
powershell -ExecutionPolicy Bypass -File tools\build-hap.ps1
```

产物: `harmony\entry\build\default\outputs\default\entry-default-unsigned.hap`

用 DevEco Studio 打开 `harmony/` 目录可以直接 Run 到模拟器或真机; 命令行安装:

```powershell
hdc install harmony\entry\build\default\outputs\default\entry-default-unsigned.hap
hdc shell aa start -b com.dsh.harmony -a EntryAbility
```

### 4. 配对

打开 App → 填入桌面端打印的 **地址 / 端口 / 令牌** → 点「测试连接」→ 点「连接」。

> **模拟器用户注意**: 模拟器是 QEMU 虚拟机, 它的 `127.0.0.1` 指向**模拟器自己**, 永远连不上电脑。
> 直接点 App 里的「**自动探测**」按钮即可 —— 它会依次尝试 `10.0.2.2`(宿主机别名)和 `127.0.0.1`。
> 真机则填电脑的局域网 IP(bridge 启动时已经打印出来)。

配对信息保存在应用沙箱的 preferences 里, 之后每次启动 App 直接进入会话列表。

之后就能:
- 在**会话列表**里看到桌面端的全部会话(含标题、工作目录、执行状态)
- 进入会话看到完整对话, 桌面端每产生一段输出, 手机上**实时追加**
- 在底部输入框**下发指令**, 桌面端立刻执行, 回复实时回传
- 桌面端任务执行中可点「停止」中断
- 用「+ 新建会话」直接在桌面端开一个新会话

---

## 实测效果(全部为本机模拟器真机截图)

| 步骤 | 截图 |
|---|---|
| 连接页(自动探测 / 令牌) | 01-connectpage.jpeg |
| 自动探测到宿主机 `10.0.2.2:8787` | 02-auto-discover.jpeg |
| 测试连接成功 · 桌面端在线 | 03-test-connection.jpeg |
| 会话列表(桌面端真实会话) | 04-session-list.jpeg |
| 会话详情(桌面端对话全文) | 05-session-detail.jpeg |
| 在手机上输入指令 | 06-command-typed.jpeg |
| **桌面端执行完, 回复回到手机** | 07-reply-on-phone.jpeg |
| 新建会话 | 08-new-session.jpeg |
| **经云中继连上桌面端** | 09-relay-connect.jpeg |
| 经中继同步到的会话列表 | 10-relay-session-list.jpeg |
| 经中继在手机上输入指令 | 11-relay-command-typed.jpeg |
| **经中继收到桌面端的回复** | 12-relay-reply-on-phone.jpeg |

> 最后一张是整个项目的验收点: 手机上敲一条 `reply with exactly: OK-HARMONY`,
> 桌面上的真实 DSH agent 收到并执行, 回复 `OK-HARMONY` 通过 WebSocket 流式回到手机。

### 界面重构后(与桌面端对齐)

| 界面 | 截图 |
|---|---|
| 会话列表(按工作区分组 / 折叠 / 运行中转圈 / 相对时间) | ui-list.png |
| 会话页「对话」视图(用户面板 / 工具单行 / 状态行 / 用量状态条) | ui-session.png |
| 会话页「轨迹」视图(助手 / 调用 角色色时间线) | ui-trace.png |
| 连接页(深色表单 / 自动探测) | ui-connect.png |
| 设备页(同一账号下的所有端) | ui-devices.jpeg |
| **队列中排队的任务(展开后带编辑 / 插队 / 删除)** | ui-queue-expanded.jpeg |
| **`+` 号面板(指令 / 技能 / 文件)** | ui-plus.jpeg |
| **模型选择(按 provider 分组 + 推理强度)** | ui-model.jpeg |
| **设置页(连接 / 模型 / 权限 / 显示 / 关于)** | ui-settings.png |

---

## 端到端自测脚本

```powershell
# 1) 桥接服务自测(46 项, 覆盖 zstd 帧解析 / QR / WS / DSH 调用 / 用量统计 / 桌面端对齐端点)
node bridge\test\run.js

# 2) 桥接端的云中继客户端自测(13 项)
node bridge\test\relay-client.test.js

# 3) 云中继自测(33 项, 覆盖帧编解码 / 账号隔离 / 在线状态)
node relay\test\run.js

# 4) 模拟器端到端(自动填表 / 发送 / 等待 / 截图)
tools\e2e-emulator.ps1     # 连接 -> 列表 -> 会话
tools\e2e-send.ps1         # 打开会话 -> 下发指令 -> 等回复 -> 截图
```

两个脚本都依赖 `hdc`(DevEco 自带) 与 `uitest`, 截图落在 `docs/screenshots/`。

---

## 桌面端是怎么被驱动的

DSH 的 Web/API 服务只监听 `127.0.0.1:10748`, 并且有两道门:

1. **Host 围栏** —— `Host` 头必须等于 `127.0.0.1:10748`, 否则直接 403。
2. **Cookie 认证** —— 没有 Bearer Token, 要用 `~/.dsh/.credentials.yaml` 里的
   `client-connection/browser-session` 密钥签一个 v1 owner Cookie。

bridge 会自动完成这两件事, 然后直接调用 DSH 的 RPC:

| 用途 | 调用 |
|---|---|
| 列会话 | `POST /api/session/list`(参数键 `_request`) |
| 读历史 | 直接读磁盘上的 `session.v4.jsonl.zstd`(支持 `before=` 分页) |
| 下发指令 | `POST /api/session/prompt`(参数键 `request`) |
| 中断任务 | `POST /api/session/cancel` |
| 实时流 | `WS /api/remote.mux` → `session/follow` |

桥接侧用 `node:http` 而不是 `fetch`, 因为 undici 会剥掉 `Host` 头, 而 DSH 的 Host 围栏必须看到
`Host: 127.0.0.1:10748`。

没有改 DSH 一个字节, 也没有往 DSH 里塞插件。完整细节见 `DSH_HTTP_API_MAP.md`。

想自己验证:

```powershell
node tools\dsh-probe.mjs
node tools\dsh-probe.mjs --prompt <sessionId> "在桌面上跑一下测试"
```

---

## 手机端是怎么跟上桌面端的

| 机制 | 说明 |
|---|---|
| `GET /api/v1/sessions` | 首屏全量拉取(bridge 侧有热缓存, ~0.6s) |
| `WS /ws` + `subscribe` | 打开某个会话时订阅它, 之后该会话的增量实时下发 |
| `WS /ws` + `ping` | 每 20 秒心跳, bridge 回 `pong` |
| `POST /api/v1/sessions/{id}/messages` | 下发指令(桌面端 agent 真正开始干活的那条路) |

**注意**: bridge 只把「订阅过」的会话推给手机 —— 不发 `subscribe` 帧的话,
会话页会一直停在「执行中」而看不到桌面端的回复。这是调试这个项目时最容易踩的坑。

---

## 远程使用(不在同一局域网)

**可以远程。** 但不要把电脑的 8787 端口直接开到公网 —— 正确做法是**桌面端主动外拨**
到一台公网中继, 手机也连中继(这正是 TRAE SOLO / MiniMax Code 官方产品的做法)。

```
   手机 ──wss/https──►  公网中继  ◄──ws(主动外拨)──  桌面 bridge ──► DSH
```

中继是"哑管道", 只搬运字节; 手机发给 bridge 的 HTTP 请求(含 `Authorization` 头)原样透传,
最终仍由 bridge 自己校验令牌。

| | 电脑要公网 IP | 手机要装 VPN | 令牌明文过公网 |
|---|---|---|---|
| **云中继(推荐)** | 不需要 | 不需要 | 否 |
| 路由器端口映射 | 需要(多数宽带是 CGNAT) | 不需要 | 否(有 TLS 时) |
| Tailscale / WireGuard | 不需要 | **需要** —— 纯血鸿蒙装不了 Android APK | 否 |

**已经在本机跑通全链路**(真实 DSH + 真实中继 + 模拟器):
经中继列出的会话与直连完全一致(135 = 135), 手机经中继建会话、下发指令,
桌面 agent 的回复 `RELAY-OK` 原路回到手机。

详细的部署步骤、地址格式与安全清单见 **[`docs/REMOTE.md`](docs/REMOTE.md)**,
中继的线上协议见 **[`docs/RELAY.md`](docs/RELAY.md)**,
自建中继一条命令见 **[`docs/SELF-HOST.md`](docs/SELF-HOST.md)**。

> **中继不是必选项, 也没有"官方公共中继"。** 中继默认是关的(`relay: null`);
> 只在同一局域网用就完全不需要它。要跨网络(比如人在外面看家里电脑), 自己架一台:
> 一台 Linux 机器 + 一个域名 + 一条命令
> `bash tools/deploy-relay.sh --domain <你的域名> --email <你的邮箱>`。
> 中继是开源的, 谁都可以自己审代码、自己跑 —— 威胁模型见
> **[`docs/SECURITY.md`](docs/SECURITY.md)** 第 7 章。

手机端的「桌面端地址」框现在接受完整 URL, 局域网和云中继用的是同一个输入框:

```
192.168.1.10:8787                        局域网直连
http://10.0.2.2:8787                      模拟器访问宿主机
https://relay.example.com:8443/acc-1a2b/dev-8f2a   云中继(路径前缀是账号 + 设备号)
```

---

## 账号与多端同步

一个**账号 = 一份共享密钥 + 一份设备清单**。桌面端和手机都是这个账号下的"设备",
中继按账号隔离: A 账号的手机看不见 B 账号的设备, 设备的在线状态也要账号令牌才能查。

桌面端启动时会打印一条配对地址和二维码:

```
[bridge]   account id     : acc-1a2b
[bridge]   phone address  : http://relay.example.com:8443/acc-1a2b/dev-8f2a
[bridge]   pair this phone: http://relay.example.com:8443/acc-1a2b/dev-8f2a
```

手机端「设备」页可以看到这个账号下的所有设备(桌面端 / 其它手机)与它们的在线状态。

**手机自己会登记进去**: 它生成自己的设备号与设备令牌, 通过 bridge 登记到账号下
(每 30 秒续一次心跳), 所以**手机里不需要账号令牌**, 只需要桌面端那一个访问令牌。
桌面端的设备列表里就能看到「我的手机 在线」。直连局域网时这套机制自动跳过。

> ⚠️ **这不是带邮箱密码的用户账号系统, 也没有端到端加密。**
> 账号令牌是 bearer secret —— 拿到它就能往这个账号里加设备。
> 实体模型、配对流程与线格式改动见 **[`docs/ACCOUNT.md`](docs/ACCOUNT.md)**。

---

## 与官方产品的关系

| | 官方(MiniMax Code / TRAE / Claude Code RC) | 本项目 |
|---|---|---|
| 手机端平台 | iOS / Android(**无鸿蒙**) | **HarmonyOS (ArkTS)** |
| 传输 | 云端 WSS 中继, 桌面端只外拨 | 局域网直连 **或** 云中继(桌面端只外拨) |
| 配对 | 扫码 | 扫码 / 手输令牌 |
| 执行位置 | 桌面 | 桌面 |
| 界面 | 各自独立设计 | **与桌面端 DSH 同一套信息层级与配色** |
| 服务端 | 官方托管 | **可以完全自建**(bridge + relay 都是零依赖 Node.js) |
| 端到端加密 | 是 | **否**(见 `SECURITY.md`) |

调研细节见 [`docs/RESEARCH-mobile-agent-clients.md`](docs/RESEARCH-mobile-agent-clients.md)
与 `research/harmonyos-remote-coding-agent-clients.md`。

---

## 和开源项目比, 我们做了什么不一样

**同类(都是给 DSH 做远程/移动端)的逐维度对比** —— 包含 star、许可、架构、端口、功能矩阵、
我们缺什么 —— 见 **[`docs/COMPARISON-dsh-clients.md`](docs/COMPARISON-dsh-clients.md)**。
与通用移动 agent 客户端(Happy Coder / VibeTunnel / Remodex / Termopus)的对比见
**[docs/COMPARISON.md](docs/COMPARISON.md)**。

| 项目 | 许可 | 谁在动 | 手机端 | 一句话差别 |
|---|---|---|---|---|
| [dsh-Go](https://github.com/ccch1mneyyy/dsh-Go) | AGPL-3.0 | 手机本机也能跑 DSH | Android | 功能与社区都最厚; **没有鸿蒙**, 且在手机里塞了一套 Linux 运行时 |
| [dsh-remote](https://github.com/flymysql/dsh-remote) | MIT | **Agent → 远程 SSH 机器** | 无 | 解决"agent 怎么够到远端机器", 不解决"人怎么在手机上看住它" |
| [dsh-Remote](https://github.com/Blank-not-black/dsh-Remote) | MIT | 人 → 手机 → 桌面 | Android / Web / 鸿蒙源码 | 能力和我们最像, 也提供 ArkTS 工程(需自己编译签名); 它靠 DSH 插件接入, 我们不用装插件 |
| **本项目** | **MIT** | 人 → 鸿蒙手机 → 桌面 | **HarmonyOS 原生** | 可作为 DSH 的外部进程, 自带云中继与账号/设备模型, 界面 1:1 对齐桌面端 |

三句话的取舍:

- **要鸿蒙**: 本项目(或 dsh-Remote 的 ArkTS 源码, 自己编);
- **要 agent 去远端机器上跑命令**: dsh-remote, 和本项目可以叠着用(注意别抢 `8787` 端口);
- **要最全的手机功能面**(审批卡片、文件断点续传、会话分支): dsh-Remote。

调研里最接近的几个(非 DSH 生态):

| 项目 | 协议 | 做了什么 | 我们不一样的地方 |
|---|---|---|---|
| [Happy Coder](https://github.com/slopus/happy) (MIT) | 自建 App + 中继 | 账号 = 客户端持有的主密钥, TweetNaCl 端到端加密, 多端实时同步, 还能多人一起驱动同一个 agent | 我们**没有** E2E 加密, **没有**托管后端, **没有**多人协同; 但我们跑的是**你自己电脑上的 DSH**(不是一个云端 agent), 而且有**鸿蒙端** |
| [VibeTunnel](https://github.com/amantus-ai/vibetunnel) (MIT) | 终端流式传输 | 自建中继 + SSH/PAM/Tailscale 鉴权 + Web Push | 它传的是**终端字节流**, 不理解 agent; 我们理解会话、消息、工具调用, 所以手机端能给出"对话 / 轨迹"两种视图和用量状态条 |
| [Remodex](https://github.com/emanuele-web04/remodex) (Apache-2.0) | JSON-RPC + 自建中继 | 扫码信任 Mac, 断线重连时补发未确认消息, 有"在桌面端继续"的交接按钮 | 它只驱动 Codex; 我们驱动 DSH 桌面端本身, 不需要另一个 agent 运行时 |
| [Termopus](https://github.com/Termopus/termopus) (AGPL-3.0) | Cloudflare Durable Object | mTLS 设备证书 + 硬件密钥 + 生物识别, 工具卡片按类型定制 | **AGPL 会传染**, 所以我们只参考了交互结构, 没有用它的任何代码 |

一句话总结: **别人做的是"某个 agent 的手机遥控器", 我们做的是"桌面端 DSH 的鸿蒙延伸"** ——
会话、工具调用、用量统计全部来自你正在用的那个桌面端, 两边是同一份数据。

---

## 安全

令牌是 bearer 令牌, 拿到的人可以让你的电脑执行命令, 请当成 SSH 私钥对待。

已经做到的: 桌面端 DSH 端口不外露、中继是哑管道不做业务鉴权、授权在最后一跳判定、
账号之间互相看不见、常量时间比较令牌、中继不落业务数据。

**没有做到的**: 端到端加密(中继是中间人)、没有真正的用户账号系统(账号 = 一个共享密钥 +
设备登记表)、没有推送通知。

完整说明与自查清单见 **[`SECURITY.md`](SECURITY.md)**。

---

## 开源

这个仓库按 **MIT** 协议发布, 可以直接拿去改、去商用。

- 参考过的开源项目与许可证说明见 [`NOTICE`](NOTICE);
- 提交之前请跑一遍三套测试: `node bridge/test/run.js`、`node bridge/test/relay-client.test.js`、
  `node relay/test/run.js`;
- 贡献指南见 [`CONTRIBUTING.md`](CONTRIBUTING.md);
- 打标签 `v*` 会自动发一个 GitHub Release(见 `.github/workflows/release.yml`)。
  HAP 需要 DevEco Studio 才能打包, 官方不能公开分发, 所以这一步放在一台
  装了 DevEco 的机器上跑(self-hosted runner), 详见工作流里的注释。

---

## 环境要求

- DevEco Studio 26(API 26 / HarmonyOS 26.0.0)
  —— `tools/` 里那批脚本默认按作者的安装路径 `D:\APP\Devecostudio26\DevEco Studio` 写死,
  **请改成你自己的目录**(多数脚本已支持 `-DevEco` 参数或 `DEVECO_STUDIO_PATH` 环境变量)
- Node.js 18+(桌面端桥接)
- HarmonyOS 6.1+ 手机或模拟器

### 构建前必读(签名)

仓库里的 `harmony/build-profile.json5` **不含任何签名材料**(开源版本已清空 `signingConfigs`)。
第一次用 DevEco Studio 打开 `harmony/` 时, 按提示走
**Project Structure → Signing Configs → Automatically generate signature**,
DevEco 会在你自己的机器上生成一份 debug 签名并写回该文件。

> 反过来也提醒一句: **别把你自己的 `signingConfigs` 提交上去** ——
> 那里面除了证书路径, 还有 `keyPassword` / `storePassword`。
> `certificate/`、`*.p12`、`*.p7b`、`*.cer`、`*.csr` 已经在 `.gitignore` 里了。

### 截图说明

README 里的截图来自作者本机的模拟器/真机, 其中的地址(`10.0.2.2` 是模拟器指向宿主机的固定别名)、
配对令牌、设备号**都是演示值**(令牌在截图之后已经轮换), 不能用来连接任何机器。


---

## DeepSeek Harness 插件（推荐给新电脑）

桥接现在也能作为 **DSH 插件** 安装：电脑上装 DSH + 插件，桥接随 DSH 启动，手机直接「自动发现」，
不用再把桌面端 zip 发到电脑。插件在 `plugins/dsh-harmony-bridge/`：

- 插件说明：`plugins/dsh-harmony-bridge/README.md`
- 本地打包：`cd plugins/dsh-harmony-bridge && npm pack` → 在 DSH 插件管理器里「从本地文件安装」
- 插件市场索引：`plugins/dsh-harmony-bridge/market/index.json`（把它的 raw 地址加到 DSH 的
  `@deepseek-ai/dsh-plugin-market` 的 `indexes` 里就能被搜索到）
- 桥接源码有更新时：`powershell -File tools\sync-plugin-bridge.ps1` 同步进插件包
