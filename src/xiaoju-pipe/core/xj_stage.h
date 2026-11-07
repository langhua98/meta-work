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
    const char *backend; // "cpu" / "metal"

    // x：T 个 token 的隐藏向量 [T][n_embd]，原地改成过完这些层之后的值。位置 n_past .. n_past+T-1。
    int  (*forward)(xj_stage *s, float *x, int T, char *err, size_t errlen);
    // 最后一个 token 的隐藏向量 → 词表上的分数 logits[n_vocab]
    int  (*logits)(xj_stage *s, const float *x, float *logits, char *err, size_t errlen);
    // 清空 KV 缓存和线性注意力状态（新对话）
    void (*reset)(xj_stage *s);
    void (*destroy)(xj_stage *s);
    void *impl;
};

// CPU 参考实现。has_head 时同时准备输出头。
xj_stage *xj_cpu_stage_new(const xj_model *m, int l0, int l1, int n_ctx, int max_batch, bool has_head,
                           char *err, size_t errlen);
#ifdef __APPLE__
// Metal 实现：只用 threadgroup 内存做归约，不用 simdgroup 指令，A10（Apple3）也能跑。
xj_stage *xj_metal_stage_new(const xj_model *m, int l0, int l1, int n_ctx, int max_batch, bool has_head,
                             char *err, size_t errlen);
const char *xj_metal_device_name(void);
#endif

// token → 隐藏向量（查 embedding 表解码一行，CPU 做，很快）
void xj_embed(const xj_model *m, int32_t token, float *out);

// 这段层的状态大概要多少内存（KV 缓存 + 线性注意力状态 + 临时缓冲），不含权重
uint64_t xj_stage_state_bytes(const xj_model *m, int l0, int l1, int n_ctx, int max_batch);

#ifdef __cplusplus
}
#endif
