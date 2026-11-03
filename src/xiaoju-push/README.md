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

## 编译和安装

推送 `src/xiaoju-push/` 的改动后，`.github/workflows/xiaoju-push.yml` 在 GitHub 的 Mac 机器上编译，
没签名的 `.ipa` 发布到 Release「xiaoju-push」。用 SideStore（自己的 Apple ID）或自己的证书签名后安装。

桌面小组件靠 App Group（`group.com.langhua98.xiaoju.push`）和 App 共享数据。编译时用 `ldid` 把 entitlements 写进去，
SideStore 签名时会保留这个 App Group。小组件一直显示 0 的话，先打开一次 App（会检查并写入数据），或者用 SideStore 重新安装。
