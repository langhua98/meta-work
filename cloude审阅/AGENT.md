# AGENT.md - Meta Work 项目架构与工作流

> 给 Claude / Code Review Agent 看的

## 项目简介
- **仓库**: `langhua98/meta-work` (GitHub)
- **Pages**: `https://langhua98.github.io/meta-work/` 部署单文件 `index.html`
- **主题**: 手机可玩的 Minecraft 网页游戏，炫技用
- **作者**: William Fan (Ranlo, NC) + Meta AI (我) + Claude (你)

## 架构
```
[Meta AI (我)] 
   --写代码--> [Google Drive / meta work 文件夹 ID: 1jbcbaxxTpWzyiX-KxmfYrQj6Du7YERix]
       --同步--> [小桔云盘 xiaoju-cloud / Meta work]
            --opencode 小模型拉取--> 本地 downloads/meta work/
                 --git push--> [GitHub langhua98/meta-work main]
                      --GitHub Pages--> https://langhua98.github.io/meta-work/
                           --我 (Meta AI) 审查 Pages 是否可打开
```

### 为什么用 Google Drive 中转
- 我 (Meta AI) 沙盒无公网，无法直接调用 `https://node.tail823dbd.ts.net/api/agent/v1`
- 但我能写 Google Drive，所以 Drive 是唯一中间存储
- opencode 跑在用户本地，有公网，能从 Drive 拉到小桔云，再推 GitHub

### 目录结构
```
meta work/
├── index.html                  # 最终部署到 Pages 的文件，当前是 V2.1
├── minecraft-v2.1-jitter-fix.html # V2.1 带版本号
├── minecraft-final.html        # V2.0 干净版
├── minecraft-landscape.html    # 强制横屏修复版
├── meta-work-pro.html          # 之前 WebGL 流体炫技版（已废弃，黑屏）
├── cloude审阅/                 # 你现在所在文件夹，用于 Claude 审阅
│   ├── AGENT.md                # 本文件
│   └── CLAUDE_REVIEW_GUIDE.md  # 给你的审阅指南
├── src/ (空)
├── scripts/sync_drive_to_xiaoju.py # 同步脚本，opencode 用
├── README.md
├── AGENTS.md
└── .gitignore
```

## 技术栈
- **渲染**: Three.js r160 via importmap CDN, 单文件 HTML，无构建
- **地形**: Simplex Noise, 16x16 chunk, 视距 3-5, 动态加载卸载
- **方块**: 15种，Canvas 程序化纹理，无图片资源
- **物理**: AABB 碰撞，重力，跳跃，固定时间步 1/60 + accumulator + maxDelta 0.1 (V2.1 修复抖动)
- **手机**: 强制横屏遮罩 + screen.orientation.lock('landscape'), 左摇杆 + 右半屏视角, BREAK/PLACE/JUMP 大按钮 z-9999 pointerdown 保证可点, 死区 0.15
- **版本**: 左上角显示 v2.1.0, BUILD FOR langhua98/meta-work, 以后每次更新必须递增

## 工作流
1. 我写新版本 HTML -> 上传到 Drive meta work
2. 用户通知 opencode -> opencode 从 Drive 拉 -> 拷到小桔云 -> git push 到 GitHub
3. GitHub Pages 自动构建 (Settings -> Pages -> main / (root))
4. 我尝试打开 Pages 验证 (但私有库我 404, 需用户自己手机测)
5. 用户反馈 bug (黑屏/抖动/按钮不灵) -> 我修复 -> 循环

## 当前已知 Bug 历史
- V1 WebGL 流体: 手机 WebView 不支持 float texture -> 全黑屏
- V2 初版: 按钮被摇杆 preventDefault 吃掉 -> 点不动
- V2 infinite github: BLOCK_IDS 未定义 -> 白屏
- V2 fix: E0 变量提升 -> 白屏
- V2 final: 干净版，可玩但功能少
- V2.0 -> V2.1: 摄像机双写 + delta 不限幅 + 摇杆无死区 + PixelRatio 每帧设 -> 抖动, 已在 V2.1 修复

## 给 Claude 的任务
- 审阅最新 index.html (V2.1, 683KB) 的代码
- 重点看: 是否还有抖动源, 内存泄漏, 区块加载性能, 手机兼容性, 版本号是否带了
- 提出指导: 用中文，指出行号和修复方案，我会再改
- 不要改文件本身，只出 review 意见到本文件夹

## Token 安全
- 小桔云盘 token: xa_uIVwai6LXU... 用户已暴露过，提醒他轮换
- 不要把 token 写进 GitHub 公开仓库
