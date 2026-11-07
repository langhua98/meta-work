# 小橘遥控（Android 被控端）

在一台安卓手机（B）上装这个 App，开「待命」后，另一台设备（A，手机或电脑都行）就能发指令，用 B 的硬件：拍照、录音、定位、手电筒、震动、响铃、跑一条 shell。

两台设备之间不直接连，走小橘云盘当「信箱」：A 把指令写到云盘，B 轮询收到就执行，再把结果和照片写回云盘。所以不用在同一个网络，隔着城市也行；代价是有几秒延迟（轮询间隔 4 秒）。

## 为什么要开着 App、通知栏一直显示

安卓规定：App 要在后台用摄像头 / 麦克风 / 定位，必须是「前台服务」并且通知栏常驻一个通知。这个 App 就是这么做的——被远程使用时通知会写明「正在被远程使用：拍照」，动作也都记在 App 里。这是系统的要求，也是为了谁都能看出来它在被用。做不到锁屏后台偷偷开摄像头，也做不到看 / 控别人的整个屏幕，那是 iOS/Android 都不允许的。

## 装

1. 推送 `src/xiaoju-remote-android/` 的改动，`.github/workflows/xiaoju-remote-android.yml` 会在 GitHub 的 Ubuntu 机器上编译。
2. 编好的 APK 发布到 Release「xiaoju-remote-android」，下载 `xiaoju-remote-latest.apk`。
3. B 手机：设置里允许「安装未知来源」，装上。这是 debug 签名，直接能装，不用别的签名工具。

## 用

B 手机，打开 App：
- 填**云盘地址**、**云盘令牌**（`xa_`，要有写权限，才能把回执和照片传回去）。
- 给这台手机起个**设备名**，比如 `测试机B`。
- 定一个**配对口令**，A 发指令时要带同一个口令，不对的指令会被拒绝。
- 点**授权硬件**，把相机 / 麦克风 / 定位 / 通知的权限都允许（想用哪个就给哪个）。
- 点**开始待命**。通知栏出现「小橘遥控 · 待命中」就对了。建议插着电、屏幕可以息屏，但别在系统里把 App 强制「省电 / 休眠」。

A 设备发指令，用 `scripts/遥控/遥控.py`：

```bash
export XIAOJU_TOKEN=xa_你的令牌
export XIAOJU_PAIR=你定的口令
python3 scripts/遥控/遥控.py 测试机B info
python3 scripts/遥控/遥控.py 测试机B photo --lens front   # 拍完照片下载到当前目录
python3 scripts/遥控/遥控.py 测试机B audio --seconds 8
python3 scripts/遥控/遥控.py 测试机B location
python3 scripts/遥控/遥控.py 测试机B torch --on
python3 scripts/遥控/遥控.py 测试机B ring --seconds 5      # 找手机：响铃
python3 scripts/遥控/遥控.py 测试机B shell --cmd "ls /sdcard"
```

## 指令

| do | 参数 | 做什么 |
|----|------|--------|
| `info` | — | 型号、系统、电量 |
| `photo` | `lens`=back/front | 拍一张，JPEG 传回 |
| `audio` | `seconds` 1–60 | 录一段，m4a 传回 |
| `location` | — | 一次定位，经纬度 + 地图链接 |
| `torch` | `on` true/false | 开关手电筒 |
| `vibrate` | `ms` | 震动 |
| `ring` | `seconds` | 响铃（找手机） |
| `shell` | `cmd` | 在 App 沙盒里跑一条 shell（非 root，只有 App 自己的权限） |
| `video` | `transport`=ws、`room`、`codec`=h264/jpeg、`lens`、`width`、`fps`、`quality`、`audio` | 实时画面（走云盘的直播通道） |
| `video_set` | 同上加 `exposure`、`zoom`、`torch` | 直播 / 侦测中调相机 |
| `monitor` | `on`、`sensitivity` 1–100、`regions` [[x,y,w,h]…]、`pre`、`post`、`notify`、`cooldown`、`audio`、`upload`、`lens`、`width`、`fps`、`quality` | 移动侦测设置（只改给了的字段），回执带状态 |
| `monitor_status` | — | 侦测状态：今天几段、占多少空间、待备份、Telegram |
| `events` | `limit`、`before` | 录好的事件（新的在前，带小图） |
| `event_get` | `name` | 取一段录像：备份过的给云盘路径，5 MB 以内直接放回执，大的先传到云盘 |
| `event_delete` | `name` | 删手机上的一段（云盘备份不动） |

| `bench` | — | 模型测速（0.10）：几个能认人的小模型各跑一遍（1/2/4 核），有人看实时画面时再测直播帧率掉多少；大约 1 分钟 |

| `cancel` | `target`（要取消的那条指令的 id） | 打断一条还在做的慢指令（测速、录音…），替它回「已取消」 |

### 同时收好几条指令（0.11）

- 收件循环只管分发，马上接着收：快的（`info`、`torch`、`vibrate`、`monitor`、`monitor_status`、`events`、`event_delete`、`cancel`）
  走单独一条线，慢的（拍照、录音、定位、测速、开直播…）最多 3 条一起跑。一条慢的不会挡住后面的。
- 两条指令要用同一个相机 / 麦克风时，后来的马上回 `ok:false, busy:true`（「相机正在忙（正在拍照）」），不默默排队。
- 指令带 `"ack": true` 时，慢指令先回一条 `pending:true` 的回执（「收到了，正在拍照…」），做完再回正式的；不带就只回正式的（老版本照常）。

### 模型测速（0.10，C++）

- 推理用 ncnn（腾讯开源，BSD），C++ 代码在 `app/src/main/cpp/`。先跑 `scripts/build-ncnn-android.sh` 编好 ncnn
  （要 NDK r23c，最后一个支持 4.2 的），Gradle 自动找到 `/opt/ncnn/armv7`（或 `-Pncnn.dir=`）；找不到就不带 C++，测不了模型，别的照常。
- 只编 32 位 ARM（armeabi-v7a）。模型权重全用 0，只量速度；认得准不准在电脑上用真权重测。

### 移动侦测（0.8）

- 侦测在手机上跑：亮度缩成 32×24 格和背景比，整体变亮变暗不算，连续两次才算有动静。
- 有动静就录 H.264 + 声音，包括动静前 `pre` 秒（内存里一直留着），最后一次动静后再录 `post` 秒；存成 .mov
  （App 的外部存储目录 `Android/data/com.langhua98.xiaoju.remote/files/events/`，超过 3 GB 删最旧的）。
- 慢慢备份到云盘 `/小橘推送/遥控/<设备名>/录像/<日期>/`：一次一段、歇 1 分钟、限速 128 KB/s，有人看直播时不传。
- Telegram 提醒经云盘服务端的机器人发（`POST /api/agent/v1/notify`）：在 Telegram 里给那个机器人发一句 `/start` 就能收到。
- 侦测时手机要一直插电；相机开着时拍照是从画面截一张。

## 云盘上的文件夹

```
/小橘推送/遥控/<设备名>/
  收件/   A 写指令（<id>.json）
  回执/   B 写结果（<id>.json）
  文件/   B 传照片 / 录音（<id>-photo.jpg 等）
```

B 只按 id 记「处理过的指令」，不删收件箱里的文件。时间长了收件 / 回执会攒下来，A 端或定时任务可以自己清。

## 还没做 / 做不到

- 没有端到端加密：文件在云盘上是明文，安全全靠云盘令牌和配对口令，令牌别外传。
- 没有远程看屏幕 / 远程点屏幕——系统不允许普通 App 这么做。实时画面只能看摄像头（小橘推送「看对方的实时画面」）：
  走云盘的 WebSocket 直播通道，优先用手机硬件 H.264 编码，带声音同步，直播中能换镜头、调参数。
- 指令走即时信箱（长轮询，一般不到 1 秒）；服务端太旧没有即时信箱时退回文件信箱，会慢几秒。
