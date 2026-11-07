// 小橘双机推理：一段连续的层 [l0, l1) 叫一个 stage。
// 主机上一个 stage 算前半段，从机（iPhone 7 Plus）上一个 stage 算后半段，中间只传隐藏向量。
// 有 CPU 版（core/xj_cpu.c，参考实现）和 Metal 版（metal/xj_metal.m，A10 也能跑）。
#pragma once
#include "xj_model.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct xj_stage xj_stage;

struct xj_stage {
    const xj_model *m;
    int l0, l1;          // 负责的层
    int n_ctx;           // KV 缓存能放多少个位置
    int max_batch;       // 一次最多算几个 token（预填充分块大小）
    int n_past;          // 已经算过的位置数（下一个 token 的位置）
    bool has_head;       // 能不能算输出头（output_norm + LM head）
    bool mtp;            // MTP 段（l0 = n_layer，l1 = n_layer + 1）：输入每个 token 是 [embedding ‖ 主干隐藏向量]
    const char *backend; // "cpu" / "metal"

    // 投机解码：keep = 下一次 forward 的 token 数时，给每个 token 算完后的线性注意力状态留存档，
    // 之后 rollback 能退回到这批里任意一个 token 之后（猜错的字作废）。forward 完自动清零。
    int keep;
    int ck_start, ck_T;  // 存档那一批的起点和长度
    // 输出头只算前 head_rows 个词（0 = 全部）。MTP 猜字用：词表按 BPE 合并顺序排，越靠前越常用，
    // 只看前几万个词，猜字时读的输出头少一大半（猜不到生僻词也没关系，主干验证时会纠正）
    int head_rows;

    // x：T 个 token 的隐藏向量 [T][n_embd]，原地改成过完这些层之后的值。位置 n_past .. n_past+T-1。
    // MTP 段：输入 [T][2*n_embd]（embedding ‖ 隐藏向量），输出写在前 [T][n_embd]（未过 norm）。
    int  (*forward)(xj_stage *s, float *x, int T, char *err, size_t errlen);
    // T 个 token 的隐藏向量 [T][n_embd] → 词表上的分数 logits[T][n_vocab]（一次读一遍输出头）
    int  (*logits)(xj_stage *s, const float *x, int T, float *logits, char *err, size_t errlen);
    // 退回到 n_past（只能退到上一次带 keep 的那批里，或者不动）
    int  (*rollback)(xj_stage *s, int n_past, char *err, size_t errlen);
    // 清空 KV 缓存和线性注意力状态（新对话）
    void (*reset)(xj_stage *s);
    void (*destroy)(xj_stage *s);
    void *impl;
};

// CPU 参考实现。has_head 时同时准备输出头。l0 = n_layer、l1 = n_layer + 1 且模型有 MTP 时是 MTP 段。
xj_stage *xj_cpu_stage_new(const xj_model *m, int l0, int l1, int n_ctx, int max_batch, bool has_head,
                           char *err, size_t errlen);
#ifdef __APPLE__
// Metal 实现：只用 threadgroup 内存做归约，不用 simdgroup 指令，A10（Apple3）也能跑。
xj_stage *xj_metal_stage_new(const xj_model *m, int l0, int l1, int n_ctx, int max_batch, bool has_head,
                             char *err, size_t errlen);
const char *xj_metal_device_name(void);
// Metal 自动调优的结果（每行线程数和各自耗时），没调过是空串
const char *xj_metal_tune_note(void);
#endif

// token → 隐藏向量（查 embedding 表解码一行，CPU 做，很快）
void xj_embed(const xj_model *m, int32_t token, float *out);

// 这段层的状态大概要多少内存（KV 缓存 + 线性注意力状态 + 临时缓冲），不含权重
uint64_t xj_stage_state_bytes(const xj_model *m, int l0, int l1, int n_ctx, int max_batch);

#ifdef __cplusplus
}
#endif
