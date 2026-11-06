# 真机安装与连接(Mate 80 实测)

> 这份文档记录的是**真跑通过**的步骤: 华为 Mate 80(VYG-AL00, HarmonyOS 6 / API 26),
> 通过 **WiFi 无线调试** 连到电脑, 签名安装, 连上桌面端。

---

## 0. 先说清楚三件事

| 常见误解 | 实际情况 |
| --- | --- |
| `devecocli` / `npm i deveco` 能装鸿蒙应用 | 那���是第三方的鸿蒙命令行 Agent, **不能**装应用。真正的安装动作是 `hdc install <hap>` |
| 模拟器能装, 真机直接装同一个包 | **不行**。模拟器接受未签名的 HAP, 真机只接受**用证书签过**的包 |
| 手机必须和电脑同一局域网才能用 | 局域网直连、或者经云中继跨网都可以, 见 `docs/REMOTE.md` |

### 0.1 普通用户: 装完即用(不用往下看)

这份文档剩下的部分是给开发者看的(签名、编译、hdc)。**普通用户只做三件事**:

| # | 在哪 | 做什么 |
| --- | --- | --- |
| 1 | 手机 | 装 **DSHsync** |
| 2 | 电脑 | App 里把「桌面端程序」发到电脑 → 解压 → **双击 `双击我-开始.cmd`** |
| 3 | 手机 | App 里点「**自动探测**」→ 选中「我的台式机」→ 配对 → 开始用 |

- **电脑上不需要装 Node**: 那个包里带的是单文件可执行程序(`dsh-harmony-bridge.exe`, 约 55 MB);
- **不需要域名 / VPS / 证书 / 注册账号**: 桌面端第一次运行会自动去公共中继登记;
- 完整说明见 [SELF-HOST.md](SELF-HOST.md) 第 1 章。

---

## 1. 签名材料(一次性)

真机只认签过名的包, 需要三个文件:

| 文件 | 是什么 | 从哪来 |
| --- | --- | --- |
| `*.p12` | 密钥库, 里面是私钥, **有密码** | DevEco Studio: 项目结构 → Signing Configs → 自动签名 |
| `*.cer` | 证书 | 同上 |
| `*.p7b` | 描述文件, 里面写着这个包名能用哪些设备 | 同上 |

本机用的是:

```
certificate/DSHHarmony.p12      别名 zy
certificate/DSHHarmony-debug.cer
certificate/DSHdebugDebug.p7b    包名 com.example.dshsync
```

> `certificate/` 已经在 `.gitignore` 里 —— 私钥不能进仓库。

### 1.1 把签名配置写进 build-profile.json5

DevEco 的 IDE 会把密码**加密**成 `00000019...` 存进 `build-profile.json5`。
这个密文在**本机的命令行也能解开**, 所以照抄 DevEco 写好的那份就行。

关键是**两处**都要有 —— 只贴 `signingConfigs` 而忘了下面 `products` 里的
`"signingConfig": "default"`, 编译出来的是**未签名**的包, 真机会拒绝安装
(报错 `install sign info inconsistent`)。完整的一段是这样:

```json5
{
  "app": {
    "signingConfigs": [
      {
        "name": "default",
        "type": "HarmonyOS",
        "material": {
          "storeFile": "D:/APP/Deepseek/DSHHarmony/certificate/DSHHarmony.p12",
          "storePassword": "YOUR_ENCRYPTED_PWD",
          "keyAlias": "zy",
          "keyPassword": "YOUR_ENCRYPTED_PWD",
          "signAlg": "SHA256withECDSA",
          "profile": "D:/APP/Deepseek/DSHHarmony/certificate/DSHdebugDebug.p7b",
          "certpath": "D:/APP/Deepseek/DSHHarmony/certificate/DSHHarmony-debug.cer"
        }
      }
    ],
    "products": [
      {
        "name": "default",
        "signingConfig": "default",   // ← 少了这一行, 出来的是未签名的包
        "targetSdkVersion": "26.0.0",
        "compatibleSdkVersion": "26.0.0",
        "runtimeOS": "HarmonyOS"
      }
    ]
  }
}
```

> ⚠️ **别把密文换成明文密码**: hvigor 会校验密码字段长度 ≥ 32, 明文口令只有 9 位,
> 编译会报 `The length of the storePassword or keyPassword field in the signature
> configuration is less than 32`。让 DevEco 自己写这份配置, 命令行照样能用。

**包名必须和 `.p7b` 里的包名一致**(这里是 `com.example.dshsync`), 否则描述文件对不上, 装不上。

> 📦 装到**真机**上用的是 `entry-default-**signed**.hap`; `entry-default-unsigned.hap`
> 是同一次构建的未签名版, 只给模拟器用。两者都在
> `harmony/entry/build/default/outputs/default/` 下面。

### 1.2 编译 + 签名

```powershell
$ide = "D:\APP\Devecostudio26\DevEco Studio"
$env:DEVECO_STUDIO_PATH = $ide
$env:DEVECO_SDK_HOME  = "$ide\sdk"
$env:JAVA_HOME        = "$ide\jbr"
$env:Path             = "$ide\tools\node;$ide\jbr\bin;$env:Path"
Set-Location D:\APP\Deepseek\DSHHarmony\harmony
& "$ide\tools\node\node.exe" "$ide\tools\hvigor\bin\hvigorw.js" assembleHap `
    --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon
```

产物: `harmony/entry/build/default/outputs/default/entry-default-signed.hap` ✅
(`entry-default-unsigned.hap` 是同一次构建的未签名版, 只给模拟器用)

---

## 2. 用 WiFi 连上真机(不用插线)

手机: 设置 → 关于手机 → 连点「版本号」进开发者模式 → 开发者选项 → **无线调试** 打开,
记下它显示的 `IP:端口`。然后:

```powershell
$hdc = "D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
& $hdc tconn 192.168.1.20:40663      # 手机上显示的 IP:端口
& $hdc list targets                    # 应该能看到 192.168.1.20:40663
```

> USB 线也能连, 但要走「USB 调试」并且装 HDC 驱动; **无线调试省事得多**,
> 实测这台 Mate 80 用无线调试一次就通。

安装:

```powershell
& $hdc -t 192.168.1.20:40663 install -r `
    D:\APP\Deepseek\DSHHarmony\harmony\entry\build\default\outputs\default\entry-default-signed.hap
# -> install bundle successfully.
```

启动:

```powershell
& $hdc -t 192.168.1.20:40663 shell "aa start -a EntryAbility -b com.example.dshsync"
```

---

## 3. 在手机上连桌面端

打开 App → 连接页, 填两项:

| 字段 | 同一 WiFi(直连) | 远程(经云中继) |
| --- | --- | --- |
| 桌面端地址 | `http://192.168.1.10:8787` | `http://192.168.1.10:8788/acc-1a2b/dev-8f2a` |
| 访问令牌 | 桥接服务启动时打印的那串 | 同左 |

令牌是**桌面端与手机之间的共享密钥**, 两边必须一致; 桌面端换令牌后手机要重新填。

连上以后:

- 桌面端「设备」页会多出一条 **我的手机 在线**(手机通过桥接服务登记到账号下,
  手机本身拿不到账号令牌)
- 手机右上角会出现**待办角标**(正在跑的任务 + 排队中的任务)
- 桌面端 agent 有动静时, 手机能收到 Push Kit 推送

---

## 4. 实测记录

| 项 | 结果 |
| --- | --- |
| 真机 | HUAWEI Mate 80 (VYG-AL00), HarmonyOS 6 / API 26 |
| 连接方式 | WiFi 无线调试 `192.168.1.20:40663` |
| 桌面端地址 | `http://192.168.1.10:8788/acc-1a2b/dev-8f2a`(经云中继) |
| 设备登记 | 手机自动登记为 `dev-cd2cfa`, 桌面端可见「我的手机 在线」 |
| 会话列表 | 211 个会话, 按工作区分组, 运行中的会话带转圈 |
| Push Token | 真机成功取到(长度 112)并上报桥接服务 |
| 窗口尺寸 | 365 × 809 vp → 单栏布局; 展开折叠屏/平板宽度自动切双栏 |
