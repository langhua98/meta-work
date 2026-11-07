# 小橘双机：两台 iPhone 合跑 Qwen3.5

iPhone 15 Pro Max 当**主机**，iPhone 7 Plus 当**从机**，在同一个 Wi‑Fi 里一起跑一个模型：从机用自己的 **GPU** 算中间几层 Transformer，主机算其余部分。一台手机装不下的模型（比如 Qwen3.5-9B，5.7 GB），两台合起来就能跑。

> 先说清楚：这样做是为了**跑更大的模型**，不是为了更快。一个字要按顺序过完所有层，从机算的时候主机只能等，每个字还要多走两次 Wi‑Fi。同样大小的模型，单机跑永远比拆开跑快。

## 架构

```
            主机 iPhone 15 Pro Max                         从机 iPhone 7 Plus（iOS 15，A10）
 ┌──────────────────────────────────────────┐        ┌──────────────────────────────┐
 │ 分词 → embedding（CPU 查表）               │        │                              │
 │ 第 0 … s1-1 层（Metal）                    │ ──TCP──▶ 第 s1 … s2-1 层（Metal，A10）  │
 │                                          │ 隐藏向量  │ KV 缓存 / 线性注意力状态留在从机  │
 │ 第 s2 … 31 层（Metal）                     │ ◀──TCP── │                              │
 │ output_norm + 输出头（Metal）→ 采样         │        │ 只下载、只映射这几层的权重        │
 └──────────────────────────────────────────┘        └──────────────────────────────┘
```

- **每个 token 只传一个隐藏向量**：9B 是 4096 个 float，16 KB；4B 是 10 KB。往返两次。KV 缓存、Gated DeltaNet 的递推状态都留在算那一层的手机上，不用传。
- **预填充走流水线**：提示词按 8 个 token 一块，从机算第 c 块时主机同时算第 c+1 块的前半段（`core/xj_net.c` 的 `xj_pipeline_eval`）。
- **从机只下载自己那几层**：先用 HTTP Range 拿文件头（约 11 MB），算出这几层在文件里的字节范围，只下载这部分，写成和原文件一样大的稀疏文件（没下的地方是空洞，不占空间）。9B 的 8 层只要下约 1 GB，不用下 5.7 GB。
- **从机只映射自己那几层**：整个 5.7 GB 映射进 3 GB 的 7 Plus 可能超出 App 的地址空间，所以只 mmap 用到的那一段（`gguf_open_header` + `gguf_map_range`）。
- **权重不拷贝**：mmap 出来的内存直接用 `newBufferWithBytesNoCopy` 交给 GPU（和 llama.cpp 一样）。
- **断线自动恢复**：Wi‑Fi 抖一下、从机 App 被切到后台再切回来，聊天不用重开。主机记着这次对话喂过的所有 token，发现从机断了（连接断开、1 分钟没回、从机报错）就隔 1/2/3 秒重连同一台从机，按原来的层范围再握手，把之前的 token 重新过一遍（重建从机的 KV 缓存和递推状态，主机自己的两段也一起清掉重算），然后接着算刚才那个字，最多重试 5 次。从机这边：切回前台自动重新待命；有新连接进来时直接丢掉挂死的旧连接（Wi‑Fi 掉线时旧连接常常收不到断开通知）。重放要花一次预填充的时间，对话越长越久。

### 为什么不用 llama.cpp

llama.cpp 的 Metal 后端里，矩阵乘、RMSNorm、softmax 都要求 GPU 支持 simdgroup 归约（`ggml-metal-device.m`：`has_simdgroup_reduction = supportsFamily:MTLGPUFamilyApple7`，也就是 A14 起）。7 Plus 的 A10 是 Apple3，这些算子在它上面全部会退回 CPU。llama.cpp 自带的 RPC 方案（`rpc-server`）也一样，从机只能用 CPU。

所以这里自己写了一套内核（`metal/xj_kernels.metal`），专门照顾 A10：
- 所有归约都用 threadgroup 内存 + 栅栏，不用 `simd_sum` 这类指令；
- 一个线程组最多 256 线程、最多 4 KB 共享内存（A10 上限是 512 线程 / 16 KB）；
- 只用 `dispatchThreadgroups`（A10 不支持非整数线程组的 `dispatchThreads`）；
- 用到的量化格式：Q4_K、Q5_K、Q6_K、Q8_0、F32（Qwen3.5 的 Q4_K_M 文件就是这几种），另外支持 F16、BF16。

主机也用这套内核（新 GPU 上也能跑，只是没有 llama.cpp 优化得那么快）。两台手机是同一个 App、同一份代码。

### 每层怎么算（对照 llama.cpp `src/models/qwen35.cpp`）

Qwen3.5 每 4 层里 3 层是 **Gated DeltaNet**（线性注意力），第 4 层是**全注意力**：

| 部分 | 做什么 | 内核 |
|---|---|---|
| 进层 | RMSNorm | `xj_norm` |
| 全注意力 | Q（带门控，每头 [q, gate] 交错）/K/V 投影 → q、k 每头 RMSNorm → 前 64 维 neox 旋转 → 存半精度 KV → 分数、softmax、加权 V → 乘 sigmoid(gate) → 输出投影 + 残差 | `mv_*`、`xj_norm`、`xj_rope`、`xj_kv_store`、`xj_attn_scores`、`xj_softmax`、`xj_attn_out` |
| 线性注意力 | qkv / z / β / α 投影 → 4 抽头因果卷积 + silu → q、k 每头 L2 归一化 → DeltaNet 递推（S ← S·e^g；δ = (v − Sᵀk)·β；S += k δᵀ；o = Sᵀq/√d，value 头按 `h % key头数` 对 key 头）→ 门控 RMSNorm（乘 silu(z)）→ 输出投影 + 残差 | `mv_*`、`xj_conv_silu`、`xj_norm`、`xj_delta_net` |
| FFN | RMSNorm → silu(gate)·up → down + 残差 | `xj_norm`、`mv_*`、`xj_swiglu` |

`core/xj_cpu.c` 是同一套算法的 CPU 参考实现，Metal 内核都拿它对照。

## 内存怎么分（9B，Q4_K_M）

| | 大小 |
|---|---|
| 32 层权重 | 4.07 GB（每层 113–136 MB） |
| embedding（Q4_K） | 546 MB |
| 输出头（Q6_K） | 约 830 MB |
| 整个文件 | 5.68 GB |

15 Pro Max 单独跑 9B 会被系统杀掉（在别的 App 里试过），所以一定要分给 7 Plus 一部分。默认从机负责第 12–21 层（10 层，约 1.3 GB）。主机这边真正要常驻的是剩下 22 层（约 2.8 GB）+ 输出头（约 830 MB，每个字都要整个读一遍），合计约 3.6 GB；embedding 只按需读用到的那几行，几乎不占内存。

7 Plus 的 App 大约能用 1.5–2 GB，从机别超过 10–11 层；7 Plus 崩了就减到 8 层，主机崩了就再往从机加 1–2 层。两边界面都会显示：从机显示这几层多大、手机还剩多少内存；主机连接前显示本机大约要扛多少、现在可用多少。

只支持 Q4_K / Q5_K / Q6_K / Q8_0 / F16 / BF16 / F32 这些格式，IQ2_M、IQ3_M、IQ4_NL、IQ4_XS 这类 i-quant 文件用不了（内核没写），带视觉 / MTP 的魔改版也不支持。App 里下载的是 unsloth 的标准 Q4_K_M（5.68 GB）。

## 速度估计（还没在真机上测）

一个字的时间 ≈ 主机算它那部分 + 从机算它那部分 + 两次 Wi‑Fi 往返。

- 主机：15 Pro Max 内存带宽约 50 GB/s，读约 3.6 GB 权重，用这套内核大概 120–200 ms；
- 从机：7 Plus 读约 1 GB 权重，A10 + LPDDR4 大概 80–150 ms；
- Wi‑Fi：每次往返 5–20 ms（iPhone 的 Wi‑Fi 省电模式会抖）。

所以 9B 两台合跑估计**每秒 3–5 个字**。每次回答后，界面上会显示本机、从机、等待各占多少毫秒，可以按实际情况调整从机的层数。

## 怎么用

1. 两台手机都装 [Release「xiaoju-pipe」](https://github.com/langhua98/meta-work/releases/tag/xiaoju-pipe) 里的 `XiaojuPipe-latest.ipa`（小橘云盘「软件包」里也有一份 `XiaojuPipe-版本-build构建号.ipa`）（没签名，用 SideStore 或自己的证书签）。连同一个 Wi‑Fi（个人热点也行）。
2. **7 Plus**：选「从机」→ 选模型（和主机同一个）→ 定从第几层开始、负责几层 → 「只下载这几层」→「开始待命」。屏幕上会显示配对码和 IP。保持亮屏、App 留在前台（iOS 不让后台 App 用 GPU）。
3. **15 Pro Max**：选「主机」→「下载整个模型」（也可以用电脑把 .gguf 拷进「文件」App → 小橘双机）→ 在列表里点从机（或手动填 IP）→ 填配对码 →「连接」→ 聊天。
4. 想对比速度：打开「不用从机，单机跑」。

## 电脑上测试（不用手机）

```sh
cd src/xiaoju-pipe
make && make test
# 单进程：整个模型在本机跑
./build/xjpipe-run 模型.gguf "用一句话介绍一下北京。"
# 模拟两台手机：从机只拿第 12–19 层
./build/gguf-slice 模型.gguf /tmp/slice.gguf 12:20
./build/xjpipe-worker /tmp/slice.gguf --layers 12:20 --pin 1234 &
./build/xjpipe-host 模型.gguf "用一句话介绍一下北京。" --worker 127.0.0.1 --pin 1234
# Mac 上：Metal 内核和 CPU 参考实现对照
./build/xjpipe-check 模型.gguf --layers 0:8
# 不用下载模型：随机权重的小 Qwen3.5（8 层，1 MB）跑主机 + 从机、断线重连（要 python3 + numpy）
make e2e
# 分词和官方 tokenizer.json 对照（要 pip install tokenizers）
python3 tests/tok_check.py 模型.gguf tokenizer.json
```

`make e2e`（`tests/e2e.sh`）测四件事，CI 的 Linux 上每次都跑：
1. 单机 vs 主机 + 从机两个进程走 TCP，贪心解码一字不差；
2. 生成到一半从机进程被杀（`xjpipe-worker --die-after 12`），马上再起一个：主机自动重连、重放，输出仍然和单机一字不差；
3. 从机一直起不来：主机按 `--retry` 重试完就报错退出，不会卡死；
4. 一个连上来就不说话的「旧主机」占着从机：新主机照样能连上，从机丢掉旧连接。

已经验证过的（Linux，CPU 参考实现，Qwen3.5-4B Q4_K_M）：
- 单机生成通顺正确：「北京，中国的首都，是一座拥有三千多年建城史和八百多年建都史的历史文化名城……」；
- 同一进程拆两段、两个进程走 TCP、从机只用 531 MB 稀疏文件（第 12–19 层），第一个词的分数都是 15.99396，生成的文字一字不差；
- 两轮对话能记住上文；配对码不对、从机没有主机要的层时都会拒绝并说明原因。

已经验证过的（GitHub Actions 的 Mac，Apple Paravirtual GPU，Qwen3.5-0.8B Q4_K_M，`.github/workflows/xiaoju-pipe.yml` 的 test）：
- Metal 和 CPU 参考实现对照：第 0–7 层、第 16–23 层，预填充 12 个 token 再逐个算 3 个，隐藏向量相对误差 4e-5 到 6e-4，输出头第一名一致；
- 两个进程走 TCP，从机用 Metal 算第 8–15 层（109 MB 稀疏文件），主机用 Metal 算其余部分，输出和单机一字不差；
- 内核按 iOS 15 目标（`-std=ios-metal2.4 -mios-version-min=15.0`）编译通过。

**还没在 A10 真机上跑过。** A10 有的限制（线程组大小、没有 simdgroup、只能整数个线程组）内核都按规矩写了，但真机上的速度和内存只能装上去测。

## 协议（`core/xj_net.h`）

TCP，小端。每条消息 16 字节头：`'XJP1'`、类型、标志、长度、序号。

| 主机 → 从机 | 从机 → 主机 |
|---|---|
| `HELLO` 版本、配对码、模型指纹、层范围（0,0 = 用从机准备好的）、上下文长度、批大小 | `HELLO_OK` 实际层范围、可用内存、权重大小、后端、GPU 名字 |
| `FORWARD` 起始位置、T、要哪些输出、T×n_embd 个 float | `FORWARD_OUT` 过完从机那几层的隐藏向量（全部 / 最后一个 / 不要）、从机算了多久 |
| `RESET` 新对话 | `ACK` |
| `PING` | `PONG` |
| `BYE` | `ERROR` 中文原因 |

从机会核对位置：主机发来的起始位置和从机已经算过的位置对不上时，从机拒绝这一批，避免 KV 缓存错位。

## 文件

```
core/   gguf.c（GGUF 解析、部分映射）  xj_model.c（Qwen3.5 结构）  xj_cpu.c（CPU 参考实现）
        xj_net.c（协议、从机服务、主机流水线）  xj_tok.c（分词）  xj_quant.h（量化格式解码）
metal/  xj_kernels.metal（A10 兼容内核）  xj_metal.m（GPU 缓冲、编码每一层）  xj_shader_types.h
ios/    project.yml  App/（SwiftUI 界面、分块下载、Bonjour、XJGlue.c 胶水）
tools/  xjpipe-run / xjpipe-host / xjpipe-worker / xjpipe-check / xjpipe-tok / gguf-slice / gguf-dump
tests/  unit.c  e2e.sh（端到端）  make_tiny_model.py（随机权重小模型）  tok_check.py + tok_corpus.jsonl（分词对照）
```

## 已知限制

- 分词器是自己写的 byte-level BPE，按官方 tokenizer.json 的正则规则实现。CI 用 `tests/tok_corpus.jsonl`（中英日韩、代码、数字、全角、emoji、生僻字等）和官方分词器逐条对照；语料外的罕见符号仍可能切得不同（不影响能不能跑）。
- 只支持稠密的 Qwen3.5（0.8B / 2B / 4B / 9B / 27B）。MoE 版和多模态输入不支持。
- 只能一问一答顺序聊，一次服务一台主机（新主机连上来会顶掉旧的）。改协议要两边 App 一起更新（握手会核对版本）。
- 主机 App 自己被切到后台时 iOS 也不让它用 GPU，这一句会报错，回来后点「新对话」重新开始。
- 主机的 9B 要常驻约 3.6 GB（从机 10 层时）。如果 iOS 还是不给，就让从机多分几层，或者先用 4B 试通链路。
