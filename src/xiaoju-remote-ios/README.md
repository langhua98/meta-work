# 小橘遥控（iPhone 被控端）

在一台 iPhone（B）上装这个 App，开「待命」后，另一台设备（A，手机或电脑都行）就能发指令，用 B 的硬件：拍照、录音、定位、手电筒、震动、响铃。

和安卓版、iOS「小橘推送」同一个后端：走小橘云盘当「信箱」。A 把指令写到云盘，B 轮询收到就执行，再把结果和照片写回云盘。不用在同一个网络，隔着城市也行；代价是有几秒延迟（轮询 4 秒一次）。

## iOS 的限制（系统定的，比安卓更严）

- **App 必须开在前台**。iOS 不允许普通 App 在后台或锁屏时开摄像头 / 麦克风。待命时这个 App 会让屏幕一直亮着（不自动锁），你可以把手机插上电、亮屏放着。切到后台或锁屏后，拍照 / 录音会停，回到前台才继续。
- 做不到远程看 / 操作 B 的整个屏幕。
- **没有 shell**。iOS 不让 App 跑别的程序，所以 `shell` 指令在 iOS 上不执行（要跑命令用安卓那台，或 iOS「小橘推送」里的本机命令）。

要「后台也能用、能跑命令、能看屏幕」的宽松环境，还是安卓或越狱设备更合适。

## 编译和安装

iOS App 只能在装了 Xcode 的 Mac 上编译，所以和「小橘推送」一样走 GitHub Actions：

1. 推送 `src/xiaoju-remote-ios/` 的改动，`.github/workflows/xiaoju-remote-ios.yml` 在 GitHub 的 Mac 机器上用 `xcodegen` 生成工程再编译。
2. 没签名的 `.ipa` 发布到 Release「xiaoju-remote-ios」，下载 `XiaojuRemote-latest.ipa`。
3. 用 SideStore（自己的 Apple ID）或自己的证书签名后装到 B 手机。免费 Apple ID 每 7 天要重签一次。

## 用

B 手机，打开 App：
- 填**云盘地址**、**云盘令牌**（`xa_`，要有写权限，才能把回执和照片传回去，存在钥匙串里）。
- 起个**设备名**，比如 `测试机B`。
- 定一个**配对口令**，A 发指令要带同一个口令，不对的会被拒绝。
- 点**授权硬件**，允许相机 / 麦克风 / 定位。
- 点**开始待命**。屏幕会保持常亮，App 别切后台。

A 设备发指令，用 `scripts/遥控/遥控.py`（和安卓版共用同一个脚本、同一套云盘信箱）：

```bash
export XIAOJU_TOKEN=xa_你的令牌
export XIAOJU_PAIR=你定的口令
python3 scripts/遥控/遥控.py 测试机B photo --lens front
python3 scripts/遥控/遥控.py 测试机B audio --seconds 8
python3 scripts/遥控/遥控.py 测试机B location
python3 scripts/遥控/遥控.py 测试机B torch --on
python3 scripts/遥控/遥控.py 测试机B ring --seconds 5
```

## 指令

| do | 参数 | iOS 上 |
|----|------|--------|
| `info` | — | 型号、系统、电量 |
| `photo` | `lens`=back/front | 拍一张 JPEG 传回（要前台） |
| `audio` | `seconds` 1–60 | 录一段 m4a 传回（要前台） |
| `location` | — | 一次定位，经纬度 + 苹果地图链接 |
| `torch` | `on` true/false | 开关手电筒 |
| `vibrate` | — | 震动 |
| `ring` | `seconds` | 响铃 + 震动（找手机） |
| `shell` | — | ❌ iOS 不支持，返回说明 |

## 云盘上的文件夹（和安卓版一致）

```
/小橘推送/遥控/<设备名>/
  收件/   A 写指令（<id>.json）
  回执/   B 写结果（<id>.json）
  文件/   B 传照片 / 录音
```

## 代码

- `App/XiaojuRemoteApp.swift`：入口
- `App/ContentView.swift`：设置界面 + 记录
- `App/Store.swift`：设置（令牌进钥匙串）
- `App/Cloud.swift`：小橘云盘客户端
- `App/Commands.swift`：硬件指令（AVFoundation / CoreLocation）
- `App/RemoteEngine.swift`：轮询收件箱、执行、写回执
- `project.yml`：XcodeGen 工程定义
