# 贡献指南

感谢参与。这个项目由三个部分组成, 改哪一块都有对应的验证方式。

## 目录结构

| 目录 | 语言 | 验证方式 |
| --- | --- | --- |
| `harmony/` | ArkTS / ArkUI (HarmonyOS 26, API 26) | DevEco Studio 26 构建 HAP, 装到模拟器上看 |
| `bridge/` | Node.js (零依赖) | `node bridge/test/run.js` |
| `relay/` | Node.js (零依赖) | `node relay/test/run.js` |
| `docs/` | Markdown | — |

## 硬性规则

1. **零运行时依赖。** `bridge/` 和 `relay/` 只能用 Node 内置模块 (`node:*`)。
   加依赖之前先想清楚能不能用 200 行自己写出来。
2. **不改动桌面端。** 本项目通过 DeepSeek Harness 的 HTTP/WS 接口工作, 不打补丁、不装插件。
3. **不暴露 DSH 的端口。** bridge 永远不监听 `127.0.0.1:10748`, 也不把它转发出去。
4. **中继不碰业务。** relay 只搬字节, 不解析协议, 不存会话内容。
5. **手机端的界面跟桌面端对齐。** 配色、间距、状态条都取自 `harmony/entry/src/main/ets/common/Theme.ets`,
   那个文件里的颜色是从桌面端截图上采样出来的, 改之前先确认桌面端改了。

## 提交之前

```
node bridge/test/run.js            # 31 passed, 0 failed
node bridge/test/relay-client.test.js
node relay/test/run.js
```

手机端改动还要:

```
$ide="D:\APP\Devecostudio26\DevEco Studio"
$env:DEVECO_STUDIO_PATH=$ide; $env:DEVECO_SDK_HOME="$ide\sdk"; $env:JAVA_HOME="$ide\jbr"
$env:Path="$ide\tools\node;$ide\jbr\bin;$env:Path"
cd harmony
& "$ide\tools\node\node.exe" "$ide\tools\hvigor\bin\hvigorw.js" assembleHap --mode module -p module=entry@default -p buildMode=debug --no-daemon
```

装到模拟器:

```
$HDC="$ide\sdk\default\openharmony\toolchains\hdc.exe"
& $HDC install entry\build\default\outputs\default\entry-default-unsigned.hap
& $HDC shell "aa force-stop com.dsh.harmony"
& $HDC shell "aa start -a EntryAbility -b com.dsh.harmony"
```

**改了界面就必须自己看一眼**: `hdc shell "snapshot_display -f /data/local/tmp/x.jpeg"` 再 `hdc file recv`,
用图片查看工具确认长什么样。编译通过不等于好看。

## ArkTS 的坑 (踩过的就别再踩)

- V1 装饰器: `@State` / `@Prop` / `@Link`, 没有 V2。
- 不能用 `any` / `unknown` / `Object` / `Record<string, T>` 字面量 / `fetch`。
- 组件里不能写 getter。
- 一个 `.ets` 只能有一个 `@Entry`。
- `Rectangle` / `RoundedRect` 是**类型名**, 画形状要用 `Rect()` / `RoundRect()` / `Circle()`。
- `Scroll` 默认把内容垂直居中, 要 `.align(Alignment.TopStart)`。
- `TextInput` 的 secure 模式在模拟器上会吞字符, 令牌这种字段用普通文本。
- `throw` 只能抛 `new Error(...)`。
- 异步回调的参数顺序是 `(err, data)`。

## 提交信息

用祈使句, 一句话说清做了什么, 带上影响的范围:

```
session page: show the desktop status strip on the phone
```

## 许可证

贡献即表示你同意你的贡献以 MIT 协议发布。参考了别的开源项目请在 `NOTICE` 里补一行。
