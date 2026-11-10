# meta-work

小橘的苹果端（iPhone）代码仓库。

## 目录

- `src/xiaoju-push/`：小橘推送 iPhone App（含云控控制端 `App/Remote/`）。编好的 ipa 在 Release「xiaoju-push」。
- `src/xiaoju-pipe/`：小橘双机（两台 iPhone 合跑模型）。小橘推送编译时也用它的 `core/`、`metal/`、`ios/App/`，不能删。
- `scripts/`：
  - `upload_package.py`：把编好的安装包传到小橘云盘「软件包」
  - `遥控/`：电脑上发云控指令的脚本
  - `finetune/`、`local-model-test/`：App 本地模型的训练数据和测试
  - `cloud-sync/`、`copy_app_to_cloud.py`：云盘和 GitHub 之间的同步工具
- `.github/workflows/`：编 ipa、测试本地模型、同步云盘的 workflow

被控端（iPhone / 安卓）在 `langhua98/xiaoju-remote`。工作规则见 `AGENTS.md`。
