# 同赛道对比: DSHsync vs dsh-Go vs dsh-remote vs dsh-Remote

> 数据采集时间 **2026-11-05**, 来源为 GitHub API 与三个仓库的 README / 文档原文。
> Star、Release 状态会随时间变化, 引用时请以当时的仓库页面为准。
>
> 这一篇只对比**同类产品**(都是给 DeepSeek Harness 做远程/移动端)。
> 与 Happy Coder / VibeTunnel / Remodex / Termopus 这类通用移动 agent 客户端的对比见
> [`COMPARISON.md`](COMPARISON.md)。

## 0. 先说结论

三家里有**两种完全不同的产品语义**, 别被名字骗了:

| 产品 | 谁在动 | 一句话 |
|---|---|---|
| **flymysql/dsh-remote** | **Agent → 远程机器** | 把任意 SSH 机器变成 DSH 的工作区, 21 个 `rw_*` 工具让 agent 在远端读写/跑命令 |
| **Blank-not-black/dsh-Remote** | **人 → 手机 → 桌面** | 口袋里的 DSH 控制台: 会话 / 审批 / 提问 / 文件 |
| **ccch1mneyyy/dsh-Go** | **手机自己也能干活** | Android 客户端, 内置 Linux 运行时能在手机上跑 DSH, 也能遥控电脑 |
| **DSHsync (本项目)** | **人 → 鸿蒙手机 → 桌面** | 鸿蒙原生控制台, 手机只看/只说, 执行永远在桌面 |

`dsh-remote` 和 `dsh-Remote` 名字几乎一样, 但**不是同一个项目**, 也不是同一个 npm 包
(`dsh-remote` vs `dsh-remote-plugin`)。这是社区里最容易搞混的一处。

## 1. 基础事实

| | DSHsync | dsh-Go | dsh-remote | dsh-Remote |
|---|---|---|---|---|
| 仓库 | 本仓库 | `ccch1mneyyy/dsh-Go` | `flymysql/dsh-remote` | `Blank-not-black/dsh-Remote` |
| Star / Fork | — | 10,710 / 482 | 252 / 45 | 74 / 8 |
| 许可 | **MIT** | **AGPL-3.0** (`sdk/`、`examples/` 为 MIT) | MIT | MIT |
| 主语言 | **ArkTS + Node.js** | Dart(Flutter) + Kotlin | JavaScript | JavaScript |
| 形态 | 鸿蒙客户端 + 桌面桥 + 云中继 | Android App(内含 Linux 运行时) | DSH 插件 | DSH 插件 + 单文件网关 + 多端客户端 |
| 手机端平台 | **HarmonyOS / ArkTS** | Android 8+ | 无 | Android / WebUI / **HarmonyOS 源码** |
| 桌面端要装 DSH 插件吗 | **不要** | 需要 DSHarness Remote | **要**(`dsh plugin add`) | **要**(`dsh-remote-plugin`) |
| 依赖 | **零第三方依赖** | Flutter + Linux 运行时 | npm 包 | 网关零运行时依赖 |
| 首次开源时间 | 2026-11 | 2026-10 | 2026-08 | 2026-08 |

> **AGPL 的差别要留意**: dsh-Go 是 AGPL-3.0, 拿它的代码做闭源或商用分发会被传染;
> 另外两家和本项目是 MIT。

## 2. 架构与链路

| | DSHsync | dsh-Go | dsh-remote | dsh-Remote |
|---|---|---|---|---|
| 链路 | 手机 ──http/ws──► 中继(可选) ◄──ws 外拨── 桥 ──► DSH | App ──► 手机内 Linux 里的 DSH;或 ──► 电脑上的 DSH | 本地 DSH 插件 ──ssh 主动出──► 远端主机 | 手机 ──► 网关 ──► DSH |
| 谁发起连接 | 桌面**主动外拨**中继 | App 发起 | 本机**主动连出** SSH | 手机发起(或桌面网关外拨?) |
| 桌面端口要暴露吗 | 不要 | 不要 | 不要(SSH 出向) | 网关监听 `0.0.0.0:8787` |
| 跨公网方案 | **自建中继, 桌面只外拨** | 官方中继 / 分享服务 | 无(本身就是远程执行) | **无公共中继**, 建议 LAN / Tailscale |
| 默认端口 | 桥 `8787`, DSH `10748` | — | — | 网关 `8787`, upstream `127.0.0.1:3080` |
| 不改 DSH 核心 | ✅ 只用 DSH 自己的 HTTP/WS | ✅ | ✅ 声明不改 `dsh-workspace` | ✅ 以插件方式接入 |
| 接入 DSH 的方式 | 外部进程 + Host 围栏 + Cookie 签名 | DSH 的 Web API / DSH Remote 协议 | 宿主插件 + 原生工作区流 | DSH 插件 + 网关代理 |

**端口冲突提醒**: 本项目的桥和 dsh-Remote 的网关**默认都是 8787**。
同一台电脑上同时装两套时, 后启动的那个会起不来, 改 `--port` 即可。

## 3. 功能面

| 能力 | DSHsync | dsh-Go | dsh-remote | dsh-Remote |
|---|---|---|---|---|
| 会话列表 / 全文 / 实时流 | ✅ | ✅ | (针对远程工作区) | ✅ |
| 手机下发指令, 桌面执行 | ✅ | ✅ | ✅ | ✅ |
| 生成中插话 / 排队消息 | ✅(队列条可编辑/插队/删除) | ✅ | ❌ | ✅(queues) |
| 模型 / 推理强度选择 | ✅(按 provider 分组) | ✅ | ❌ | ✅ |
| 权限 / 沙箱模式显示与切换 | ✅ | ✅ | ✅(同本机策略) | ✅(审批) |
| **工具调用审批卡片** | ❌(只显示 approval policy) | ✅ | ❌ | ✅ |
| **提问(ask)交互** | 部分(有问题面板) | ✅ | ❌ | ✅ |
| 目标 / 子 agent / 分支 | ❌ | ❌ | ❌ | ✅(goals/subagents/turn branches) |
| 用量 / token / 上下文统计 | ✅(直取 DSH 会话元数据) | 部分 | ❌ | ✅(需 dsh-cost-meter) |
| **文件传输 / 预览** | ❌ | ✅(图片附件) | ✅(SFTP 镜像 + 上传下载) | ✅(断点续传, 最大 2 GB) |
| 手机本机跑 Agent | ❌(设计上不在手机上跑) | ✅(PRoot Linux, 免 Root) | ❌ | ❌ |
| 多机 / 多主机管理 | 待办(账号内设备可见, 未做多桌面路由) | ✅(切主机) | ✅(多台 SSH, 跳板机) | ✅(多服务器自动选最快) |
| 端口转发 / PTY 终端 | ❌ | ❌ | ✅ | ❌ |
| 插件管理界面 | ❌(`+` 里能插技能/指令) | ✅ | ❌ | ✅ |
| 主题 / 多语言 | 深色对齐桌面, 跟随系统 | ✅ 6 套主题 + 英文 | WebUI | ✅ 6 套 Web 主题 |
| 推送通知 | ✅ 华为 Push Kit(需自己的 appId) | ✅ | ❌ | ❌ |
| 离线可看历史 | ✅(从磁盘投影) | ✅ | ❌ | ✅ |
| 弱网重连 / 补发 | ✅(订阅 + 心跳) | ✅ | — | ✅(长轮询 + 退避 + 崩溃恢复) |
| **端到端加密** | ❌(中继可读明文) | ✅(分享链接 E2E) | ❌ | ❌ |
| 账号 / 设备模型 | ✅(账号 = 共享密钥 + 设备表) | 部分 | ❌ | 部分(设备/令牌列表) |
| **鸿蒙原生客户端** | ✅ 已真机验证 | ⏳ 作者说会适配 | ❌ | ⚠️ 有 ArkTS 源码, 需自签名 |

## 4. 我们在哪些地方确实不一样

1. **鸿蒙端是验证过的, 不是"计划中"。**
   本项目在 Mate 80(HarmonyOS 6 / API 26)上跑通: 签名安装 → WiFi 配对 → 211 个会话同步 →
   待办角标 → Push Token 上报 → 三折叠双栏。
   dsh-Go 目前只有 Android, 鸿蒙在作者 README 里是"尽快适配";
   dsh-Remote 提供了 HarmonyOS 源码工程, 但需要自己构建与签名, 且它自家声明仍是 0.6.26 的老版本配置。

2. **不需要往 DSH 里装插件。**
   桥是 DSH 之外的独立进程, 用 DSH 自己的 `POST /api/session/list`、`WS /api/remote.mux`,
   自己过 Host 围栏、自己签 Cookie。所以:
   DSH 升级不会连坐手机端, 也不用担心插件版本与 DSH 的 peer 版本打架
   (dsh-remote 的 README 里就有一整节讲"DSH 升级后插件整包被丢弃"的坑)。

3. **自带云中继 + 账号/设备模型。**
   三家里只有 dsh-Go 有中继, 但那是它的公共服务(还带分享服务), 你不能自建;
   dsh-Remote 明确只做 LAN / Tailscale;
   dsh-remote 根本不处理手机。
   本项目的中继是零依赖 Node, 一条命令自建, 桌面端只外拨, **纯血鸿蒙装不了 Tailscale 的场景**才有解。

4. **局域网免手输配对。**
   `/_dsh/discover` 应答 + 60 秒一次性配对码换令牌。
   另外两家要么扫码, 要么手填 IP + 令牌。

5. **界面是 1:1 复刻桌面端 DSH, 不是重新设计一套。**
   按工作区分组的会话树、对话/轨迹双视图、队列条、`+` 面板(指令/技能/文件)、
   模型胶囊、权限胶囊、`12 轮 512 步 · 461K tok · 上下文 195K/512K` 用量条。
   配色从桌面端采样(`#151517` / `#1B1B1C` / `#2C2C2E` / `#7AAFFF`)。
   手机上看到的数字和桌面端是同一份。

## 5. 我们明显不如的地方

实话实说, 这三家的功能面都比我们宽:

| 缺口 | 谁有 | 说明 |
|---|---|---|
| 工具调用审批卡片 | dsh-Go / dsh-Remote | 我们只显示 policy, 不能在手机上点"允许/拒绝" |
| 文件传输 / 预览 | 全部三家 | dsh-Remote 连断点续传都做了 |
| 目标 / 子 agent / 分支 / 队列语义 | dsh-Remote | 它的会话能力是目前最全的 |
| 插件管理界面 | dsh-Go / dsh-Remote | 我们只能把技能/指令插进输入框 |
| 端到端加密 | dsh-Go(分享链接) | 我们的中继是中间人, 能看明文 |
| 文档与社区 | dsh-Go(1 万 star + 论坛 + QQ 群) | 我们只有仓库里的文档 |
| 移动端多平台 | dsh-Remote(Win/Linux/macOS/Browser) | 我们只有鸿蒙 |

## 6. 选型建议

| 你的诉求 | 选 |
|---|---|
| 手上是**鸿蒙手机**, 想看着电脑上的 DSH 干活 | **本项目**(或 dsh-Remote 的鸿蒙源码, 但得自己编) |
| 手上是 Android, 还想**在手机上跑起来** | dsh-Go |
| 想让 agent **直接读写/构建远程服务器上的代码** | dsh-remote |
| 想**在手机上审批工具调用、传文件**, 且能接受装插件 | dsh-Remote |
| 想**完全自建、可审计、不依赖别人的服务** | 本项目(bridge + relay 都能自己跑) |

四者并不互斥: `dsh-remote` 解决"agent 怎么够到远端机器",
`dsh-Remote` / 本项目 / dsh-Go 解决"人怎么在手机上看住 agent"。
如果你同时要"agent 在远端机器上干活"和"手机上看住它",
`dsh-remote` + 本项目可以叠着用(注意别抢 8787 端口)。

## 7. 引用与许可

| 项目 | 许可 | 我们用了什么 |
|---|---|---|
| dsh-Go | AGPL-3.0 | **一行代码没用, 也没看过它的实现**; 只对比它 README 里公开的功能清单 |
| dsh-remote | MIT | 只用它的文档做能力对照; 没有引用代码 |
| dsh-Remote | MIT | 只用它的 README / 平台矩阵做对照; 没有引用代码 |

本项目独立实现: 桥与中继是 DSH 的 HTTP/WS 客户端, 鸿蒙端是 ArkTS 原生应用,
界面参数来自本项目自己实测的 DSH 桌面端。
