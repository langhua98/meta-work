# 小橘推送（iPhone App）

把小橘云盘文件夹里改过的代码，在手机上提交、推送到 GitHub。原来在 xiaoju-cloud 仓库的 `pushapp/`，现在搬到这里。

- 设置里填：小橘云盘地址、`xa_` 令牌（只读即可）、GitHub 令牌（目标仓库 Contents 可写）。令牌存在钥匙串。
- 「推送任务」：云盘文件夹 → 仓库 / 分支 / 仓库里的目录；可以填「不推的文件夹」（比如 cloude审阅），检查时直接跳过。可以浏览云盘选文件夹、从自己的仓库里选。
- 点一个任务：自动检查改动，列出改了哪些文件（新增 / 修改，+加 −减 行数）；点文件看具体改了哪几行（绿加红减）。
- 提交说明自动生成（摘要 + 文件清单），可以改；点「提交并推送」，一次提交推到分支。
- 只推内容变了的文件（云盘 sha256 + git blob sha 比较）；云盘删掉的文件不会在 GitHub 删除；没改动不提交；不强推。
- 0.2 新增：新界面（深色 / 浅色跟着系统）、震动和动画、搜索筛选、风险提醒、提交说明模板、推送记录、后台检查和通知、桌面小组件（主屏小号 / 中号、锁屏）、首次引导。

不打开手机也想自动同步：用 xiaoju-cloud 仓库的 `tools/cloud-sync`（GitHub Actions 定时跑）。

## 0.3：编码助手对话框 + 本地模型

点任务进入对话框，所有事都在里面说一句话完成：检查改动、推送、看记录、不推某个文件夹、在云盘找文件、新建 / 改名 / 移动 / 放回收站。会改东西的都先出确认卡片。

- 简单的话（「推送」「检查」）直接用关键词认，不用模型。
- 其他的交给手机上的 Qwen3.5-2B（Q4_K_M，1.28 GB，设置 → 本地模型 下载）。llama.cpp 跑，输出用 GBNF 语法锁成一条 JSON 指令。只在说话时加载，空闲 2 分钟 / 切后台 / 内存告警就释放。
- 本地搞不定的交给 HF Space 上的 OpenCode（设置 → 云端大模型，填 OPENCODE_SERVER_PASSWORD）。它只出方案，手机确认后执行。
- 长记忆：说「记住…」或纠正它时，由 OpenCode 整理成云盘 `/小橘推送/记忆/` 里一个主题一个 .md 加 `索引.md`，确认后写入。本地模型看索引，OpenCode 看全部。设置 → 记忆 可以看和删。
- 改云盘文件要在设置里填带「整理」权限的令牌。

代码在 `App/Assistant/`。llama.xcframework（llama.cpp 最新正式版）由 workflow 编译时下载到 `Vendor/`，不进仓库。

## 本机命令（shell）

对话里说「找一下哪里用了 cloudToken」「git 改了哪些」，本地模型输出 `{"do":"run","cmd":"…"}`，命令在当前任务的代码文件夹里跑，输出实时显示在对话里：工作区任务就是它的工作区；云盘任务先把云盘文件夹同步一份到手机（`资源库/Caches/云盘副本/`，只下新的和改过的，5 MB 以上的文件不下），在副本里跑，改了不会传回云盘；没选任务在「工作区」总文件夹。

- 用 a-Shell 作者的 [ios_system](https://github.com/holzschu/ios_system)（BSD-3）：iPhone 不让 App 启动别的程序，它把每个命令做成框架，在 App 自己进程里调用。
- 带的命令：ls cp mv rm mkdir find grep sed awk sort uniq wc diff head tail cat tar gzip curl dash（sh 脚本）和 git（lg2，libgit2）等 70 多条，见 `App/Shell/commandDictionary.plist`。还有：
  - `python3`：官方 CPython 3.13 的 iOS 版（BeeWare 打包）。`pip install 包名` 只能装纯 Python 的包，装在 资源库/python/site-packages。
  - `sqlite3`：Python 自带的 sqlite3 命令行（`sqlite3 数据库 "SQL"`）。
  - `node` / `js`：iPhone 自带的 JavaScriptCore，有 console、process、`require("fs")`、`require("path")`，没有 npm。
  - `jq`、`ssh` / `scp` / `sftp` / `ssh-keygen`（密钥在 ~/.ssh）。
  - 没有 bash、npm。
- 快捷指令：快捷指令 App 里能找到「问小橘」（带一句话打开小橘发出去，可以配合「自动化」定时跑）；对小橘说「运行快捷指令 xxx」会先确认，再跳到快捷指令去跑。
- 上网：「上网搜 xxx」走自己 HF 上的 SearXNG；「打开 网址」读网页正文。结果可以一键交给云端整理。
- git 历史：任务对着整个仓库时，第一次跑 git log / diff / blame 会先从 GitHub clone 一份，只把 `.git` 放进命令文件夹（文件本身不动），半小时内不重拿；工作区「从 GitHub 拉」时也会顺便更新。所以 `git status` / `git diff` 看到的是手机上和 GitHub 的差别。
- 只看不改的直接跑；删文件、写文件（>）、`sed -i`、git commit / push / reset 这类先出确认卡片（`App/Shell/ShellSafety.swift`）。一条命令最多 2 分钟，停止键能停。
- git：提交作者用 GitHub 用户名；push / pull 用 GitHub 连接器的令牌（写在 资源库/Preferences/git/config，「文件」App 里看不到）。
- 框架由 workflow 按固定版本和 sha256 下载到 `Vendor/`（设备上一共约 10 MB）。开源许可见 `App/Shell/NOTICES.txt`。

## 编译和安装

推送 `src/xiaoju-push/` 的改动后，`.github/workflows/xiaoju-push.yml` 在 GitHub 的 Mac 机器上编译，
没签名的 `.ipa` 发布到 Release「xiaoju-push」。用 SideStore（自己的 Apple ID）或自己的证书签名后安装。

桌面小组件靠 App Group（`group.com.langhua98.xiaoju.push`）和 App 共享数据。编译时用 `ldid` 把 entitlements 写进去，
SideStore 签名时会保留这个 App Group。小组件一直显示 0 的话，先打开一次 App（会检查并写入数据），或者用 SideStore 重新安装。

## 遥控

设置 → 遥控。开「待命」后，这台 iPhone 被另一台设备（安卓「小橘遥控」或另一台装了本 App 的 iPhone）通过小橘云盘发指令，调用本机硬件：拍照、录音、定位、手电筒、震动、响铃。走云盘中转（`/小橘推送/遥控/<设备名>/` 下的 收件 / 回执 / 文件），不用同一个网络。

- 先在连接器里填好云盘令牌；回执和照片要写回云盘，得填「整理令牌」。
- 设一个设备名和配对口令，发指令的一方要带同一个口令，不对的拒绝执行。
- 待命时屏幕保持常亮，App 别切后台——iOS 不允许后台用摄像头 / 麦克风。
- 发送端：在另一台 iPhone 的同一页「遥控别的设备」里填对方设备名、选指令、发送，回执和照片直接显示；电脑上也可以用 `scripts/遥控/遥控.py`。
- `shell` 指令在遥控里暂时没接本机命令（本 App 有 ios_system，以后可以接上）。
- 代码在 `App/Remote/`。
