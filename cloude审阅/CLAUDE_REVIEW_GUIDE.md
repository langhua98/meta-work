# CLAUDE 审阅指南 - 请审查 Meta AI 写的 Minecraft 代码

> 你好 Claude，我是 Meta AI，这个项目是 William Fan 的 meta-work，手机版我的世界

## 你要审什么
- **文件**: `../index.html` (当前 V2.1, 683KB) 和 `../minecraft-v2.1-jitter-fix.html` 是同一个文件，是最新部署到 Pages 的版本
- **路径**: 在 Google Drive `meta work / index.html`，你从小桔云盘 `Meta work/index.html` 也能看到

## 我写的代码哪里烂 (用户原话: 太垃圾)
1. 之前 WebGL 流体版黑屏 (float texture 不支持)
2. 按钮被摇杆吃掉点不动
3. BLOCK_IDS / E0 未定义导致白屏
4. 打开抖动 (camera 双写 + delta 不限幅 + 摇杆无死区)
- V2.1 已修复抖动，但可能还有隐藏 bug

## 请你重点审
- **抖动**: 是否还有 camera.position 被写两次？fixed timestep 是否正确？摇杆死区 0.15 是否够？renderer.setPixelRatio 是否只设一次？
- **白屏**: 是否还有变量提升 (Temporal Dead Zone)？所有常量是否在顶部？是否有未定义 BLOCK？
- **手机**: 强制横屏遮罩是否会误触？touch-action 是否分层？BREAK/PLACE 按钮 z-index 9999 + pointerdown 是否够？
- **性能**: 区块加载是否内存泄漏？InstancedMesh 是否正确释放？视距 4 在低端机是否会卡？是否需要 Web Worker？
- **版本**: 左上角是否显示 v2.1.0？以后每次更新必须带版本号，用户要求的

## 请你输出
- 在本文件夹新建一个 `review_v2.1.md`，用中文
- 格式:
  ```
  ## 严重 Bug
  - 行号: 问题描述 + 修复代码片段

  ## 性能建议
  - ...

  ## 下一版 V2.2 建议
  - 应该加什么功能
  ```
- 不要直接改 index.html，只给意见，我 (Meta AI) 会根据你的意见再改

## 项目上下文
- 单文件 HTML, 15种方块, 无限世界, Simplex Noise, 洞穴矿脉, 生物群系, 合成背包, 动物僵尸, 昼夜, AO
- Three.js r160 CDN, 无构建, 手机 60fps 目标
- 工作流: Meta AI 写 -> Drive -> 小桔云 -> opencode -> GitHub -> Pages

## 最后
- 用户说 "你自己写的太垃圾"，所以请狠狠审，越严格越好
- 审完 @ 我 (Meta AI) 会继续迭代升级

谢谢！

-- Meta AI
