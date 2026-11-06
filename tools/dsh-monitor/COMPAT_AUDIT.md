# DSH 升级兼容性审计（摘要）

问题：**鸿蒙 APP 是绑死某个 DSH 版本，还是能跟着桌面端升级？**

结论：**没有版本绑定。** DSH 线上**不存在**任何版本握手——没有 `apiVersion`、没有 `capabilities`、
没有 `protocolVersion` 字段。`client-request` 信封就是 `{type, rpcId, method, payload.args}`。
APP 绑的是**字段名**（形状），不是版本。

## 三层解耦

```
APK(ArkTS) ──我们自己的 /api/v1 + 密封层──► bridge(Node,:8787) ──DSH Typert RPC──► DSH
              独立版本化，与 DSH 无关                 ▲ 唯一的接缝
```

- `harmony/**` 里 **0 处**出现 `typert` / `client-request` / `remote.mux` / `dsh-auth`。
- `bridge/src/protocol.js:5` → `PROTOCOL_VERSION = '1.0.0'`，独立于 DSH。
- relay 是纯字节管道，与两端都解耦。

**DSH 升级 → 坏的是 bridge，不是 APK。**

## bridge ↔ DSH 的全部接缝（17 个端点）

参数键表在 `bridge/src/dsh.js:26-45`（`ARG_KEYS`），注释写着"verified against the running
application"——是**手工对着当前这版验证**的。

| # | 端点 | 参数键 | 读了哪些字段 |
|---|---|---|---|
| 1 | `session/list` | `_request` ⚠怪键 | `items`/`sessions`、`sessionId`、`cwd`、`running`、`parentSessionId`、`projections.values.*` |
| 2 | `session/page` | `request` | `records[].event`、`hasMore`、游标错误文案 `past cursor N` |
| 3 | `session/projections` | `request` | `asOfSeq`、`values.*`、`kind`（`sequenced`/`migration-required`） |
| 4 | `session/prompt` | `request` | `accepted` |
| 5 | `session/cancel` / `create` / `rename` / `selectModel` / `updateQueue` | `request` | `accepted` / `sessionId` / `selected` |
| 6 | `session/modelCatalog` | *扁平* | `catalog.default`、`groups[].models[].reasoning` |
| 7 | `commands/list` / `commands/execute` | *扁平* | `{name, description}`、`result.kind`/`result.text` |
| 8 | `permissionPresets/catalog` | *扁平* | `options[]`、`defaultOptions[]`、`defaultPreset` |
| 9 | `agentPresets/list` | *扁平* | `catalog.presets[]` |
| 10 | `skills/list` | `request` | `skills[]` |
| 11 | `fileReferences/list` | *扁平* | `[{path, kind}]` |
| 12 | `session/follow` | **WS** | 帧类型 `snapshot`/`event`/`assistant-stream`；`chunk.type='text-delta'` |

事件词表硬编码在 `store.js:312-402`：`user/message`、`assistant/message`、`system/message`、
`developer/message`、`tool/call`、`tool/result` + `turn/start|end`、`step/start|end`。
未知类型**按设计忽略** → 消息和工具调用会静默消失。

还有**第二处未版本化的耦合**：磁盘。
- `store.js:239` 硬编码 `session.v4.jsonl.zstd`（DSH 当前 `SESSION_FORMAT_VERSION = 4`）
- `store.js:707` 硬编码日志头 `version: 4`
- DSH 若升到 v5 → 扫描器**一个会话都找不到** → 本地快路径、tailer、磁盘标题全废（静默）

## 破坏等级

| 级别 | 例子 | 手机上的表现 |
|---|---|---|
| **全灭** | cookie 格式 / Host 围栏 / 信封改名 | 每个端点 401/403/502，APP 每屏报错 |
| **全灭（最可能）** | **DSH 重启后换了端口** | `discoverDshUrl` 只在启动时跑一次 → 之后所有 DSH 路由 503，**直到重启 bridge** |
| 单功能死 | 权限目录、模型目录、权限切换、游标错误文案 | 权限选择器空、模型选择器空 |
| **静默降级**（最危险） | `session/list` 少个字段、日志格式升版、事件词表漂移、`userQuestions.active` 没了 | 用户只会觉得"今天 APP 有点傻"，**APP 从不说是版本问题** |

## 已有的版本防护

`bridge/src/dsh.js:62` → `DSH_MINIMUM_VERSION = '0.1.2-alpha.1'`
启动横幅会警告"DSH 比这老 → 受 CVE-2026-82533 本地 Host 头绕过影响"。

**但只管下限，不管上限。** 真正危险的方向（DSH 变得比 bridge 预期更新）是裸奔的。
而且 `isDshVersionSafe` 在版本读不到时**默认放行**（fail open）。

## 测试的盲区

`bridge/test/run.js` 用的是 `FakeDsh` 测试替身——**它手写复刻了 DSH 的形状**。
所以它只能证明 bridge 自洽于一份**手写的虚构**，**永远发现不了 DSH 的变化**。
CI（`.github/workflows/ci.yml`）里根本没有 DSH。

## 手机端现在拿不到 DSH 版本

- `/api/v1/health` 原本只有 `{webUrl, reachable}`——**没有 DSH 版本**。
- `ConnectPage.ets:254` 显示的 `info.version` 是 **bridge 的**协议版本，不是 DSH 的。
- APP **从不校验** bridge 的协议版本：`hello.data.version` 声明了（`BridgeClient.ets:74`）但
  在 `BridgeClient.ets:1465-1474` 被完全忽略。

→ 所以手机**无法说出"桌面端太旧，请更新"**。

## 已实施的加固（本次）

1. **端口再发现**（`bridge/src/dsh.js`）
   `DshClient.rpc()` 捕获连接类错误 → `rediscover()` 重新探测 DSH → 重试一次。
   - 30 秒冷却（`REDISCOVER_COOLDOWN_MS`），不把没开的 DSH 扫成筛子
   - 只有**自动发现**的主机才允许换（`--dsh-url` 钉住的不换）——`allowRediscovery`
   - 重试失败时**抛原始错误**，不改变错误语义（原来 503 的还是 503）
   - 换端口后**重签 cookie**（cookie 绑 authority）
2. **DSH 版本上 `/api/v1/health`**（`bridge/src/router.js`）
   `dsh: { webUrl, reachable, version }`，`readDshVersion()` 读
   `~/.dsh/dsh-runtimes/*/runtime.json`，缓存 60 秒。
3. **测试**（`bridge/test/run.js`，+3 个）
   - 自动发现的主机在端口死掉后能被重新找到
   - 钉住的主机永远不会被换掉
   - `/health` 必须报 DSH 版本
   全套 **80 passed, 0 failed**（原 77）。

## 还该做（没做）

- **契约探针**：对着**真实** DSH 跑一遍，断言 17 个端点存在、参数键对、关键字段名在。
  放 `bridge/test/contract/`，CI 里没有 DSH 时跳过，另加一台有桌面的机器做 nightly。
- **APP 侧**：`hello.version` 校验 + `/health` 的 DSH 版本 → "桌面端已升级，请更新 bridge"横幅。
- **`formatStatus: 'migration-required'`**：DSH 已经会报这个标记，bridge 和 APP **都 0 处处理**。
  应该：bridge 检出后标记会话，APP 显示"需要迁移"。
- **`session.v4.jsonl.zstd` 硬编码**：改成读 DSH 的 `SESSION_FORMAT_VERSION` 常量，别写死第二份。
- **APP 侧 `hello.version` 校验**：bridge 协议若真变了，APP 现在完全感知不到。

## 部署事实

- bridge 是**独立的零依赖 Node 进程**，不在 DSH 安装目录里
- 计划任务 `DSH Harmony Bridge`（`/sc onlogon`）→ `tools/install-desktop.ps1:556-577`
- 令牌在 `%USERPROFILE%\.dsh-harmony-bridge\bridge.json` → **换代码不会掉配对**
- 本机正在跑的就是仓库里的源码：`node bridge\src\cli.js --port 8787 ...`
  → **改完源码重启 bridge 即生效，APK 不用动**
