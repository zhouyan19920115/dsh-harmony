# 兼容性说明（平台 / 系统）

这个项目由三块组成，**每块支持的系统不一样**：

| 角色 | 是什么 | 支持的系统 |
|---|---|---|
| **手机 App**（`harmony/`） | HarmonyOS NEXT 原生 ArkTS 应用 | **HarmonyOS NEXT 手机/平板**（Mate 80 真机验证）。**iOS 没有客户端**，Android 也没有。 |
| **电脑端桥接**（`bridge/`） | Node.js 服务，零第三方依赖 | **Windows / macOS / Linux**（任何能跑 Node 20+ 的电脑）。实测在 Windows 11 上跑通。 |
| **DSH 插件**（`plugins/dsh-harmony-bridge/`） | 让 DSH 自己拉起桥接 | 取决于 **DeepSeek Harness 桌面端**能装在哪：Windows 版已验证；macOS/Linux 如果官方有对应版本，插件本身是纯 Node，可直接用。 |

## 常见问题的直答

### iOS 能用吗？

**目前不能，没有 iOS 客户端。**
桥接的协议是普通 HTTP + WebSocket + JSON（见 `bridge/src/protocol.js`），
理论上是跨平台的，理论上可以照着写一个 iOS 客户端，但仓库里没有，也不在近期计划里。

### 鸿蒙电脑（HarmonyOS PC）能用吗？

分两半：

- **DSH 桌面端**目前没有 HarmonyOS PC 版本 → **插件方案在鸿蒙电脑上跑不了**；
- **手机 App 本身**是 HarmonyOS 应用，理论上能在鸿蒙 PC/平板上安装运行，
  但它仍然需要**另一台电脑（或服务器）跑桥接**才能连上 DSH；
- 所以「鸿蒙电脑 + 鸿蒙手机」的组合：手机 App 可以装在鸿蒙电脑上，但桥接要跑在别的机器上。

### Android 手机能用吗？

不能。App 是 HarmonyOS NEXT 原生实现（ArkTS/ArkUI），没有 Android 版本。

### 电脑端一定要装 DSH 吗？

不一定：

- **方案一（插件）**：必须电脑上有 DSH（插件随 DSH 启动桥接）；
- **方案二（独立桥接）**：不需要 DSH 桌面的插件系统，电脑装 Node 22+ 即可跑
  `dsh-harmony-desktop.zip` 里的桥接（Windows 也提供免安装 exe）。桥接仍然会连本机 DSH 应用 ——
  没有 DSH 应用就没有会话可看。

### 中继服务器有平台限制吗？

没有。中继就是一个 WebSocket 服务（`relay/`，Node.js），Windows / macOS / Linux 都能跑；
手机通过 `wss://` 连它，所以不在同一局域网也能用。

## 端口与网络

- 桥接默认端口 **8787**（插件和独立运行都一样），手机自动探测优先扫 8787，
  找不到会兜底扫 8788/8789/8790/8791/8899；
- 电脑防火墙需要放行该端口（Windows 首次运行会弹窗，选「专用网络」）；
- 手机和电脑在同一 WiFi/路由器下即可，不需要公网 IP；跨网络请用云中继。
