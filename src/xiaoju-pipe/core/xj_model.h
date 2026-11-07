// 小橘双机推理：Qwen3.5（GGUF 架构名 qwen35）的结构和权重表。
// 算法和 llama.cpp 的 src/models/qwen35.cpp 一一对应，见 README「每层怎么算」。
#pragma once
#include "gguf.h"

#ifdef __cplusplus
extern "C" {
#endif

#define XJ_MAX_LAYERS 128

// 一个权重：指向 mmap 里的数据，ne0 是输入维度（一行的长度），ne1 是输出维度（行数）
typedef struct {
    const void *data;
    uint64_t    file_off;   // 在 GGUF 文件里的绝对偏移（Metal 端按这个建 no-copy 缓冲）
    uint64_t    nbytes;
    uint32_t    type;
    int64_t     ne0, ne1;
} xj_w;

typedef struct {
    bool recurrent;          // true: Gated DeltaNet 线性注意力；false: 全注意力
    xj_w attn_norm, post_norm;
    // 全注意力
    xj_w wqkv;               // 有的 GGUF 合并成一个（可能为空）
    xj_w wq, wk, wv, wo, q_norm, k_norm;
    // 线性注意力
    xj_w ssm_qkv, ssm_gate, ssm_conv1d, ssm_dt, ssm_a, ssm_beta, ssm_alpha, ssm_norm, ssm_out;
    // FFN
    xj_w ffn_gate, ffn_up, ffn_down;
} xj_layer;

typedef struct {
    int   n_layer, n_embd, n_ff, n_vocab;
    int   n_head, n_head_kv, head_dim;     // 全注意力
    int   n_rot;                           // 旋转位置编码只转前 n_rot 维
    float rope_base, eps;
    int   conv_k;                          // 卷积核长度（4）
    int   d_inner;                         // value 总维度
    int   s_k;                             // 每个头的 key 维度（= state_size）
    int   h_k, h_v;                        // key 头数、value 头数
    int   s_v;                             // 每个头的 value 维度 = d_inner / h_v
    int   key_dim, conv_dim;               // key_dim = s_k*h_k，conv_dim = 2*key_dim + d_inner
    int   full_attn_interval;
    uint32_t eos, eot;                     // <|endoftext|>、<|im_end|>
} xj_hparams;

typedef struct {
    gguf_file *gguf;
    xj_hparams hp;
    xj_w tok_embd, output_norm, output;    // output 为空时和 tok_embd 共用
    xj_layer layers[XJ_MAX_LAYERS];
    uint64_t fingerprint;                  // 两台手机核对是不是同一个模型文件（不含 MTP 层）

    // MTP（多 token 预测）头：投机解码时猜后面的字。结构 = 一个全注意力层（放在 layers[n_layer]）
    // 前面加 enorm(下一个字的 embedding) ‖ hnorm(主干最后一层的输出，未过 output_norm) → eh_proj，
    // 后面用 shared_head_norm + 主干的输出头。可以在模型文件里，也可以从另一个带 MTP 的 GGUF 单独挂上来。
    bool has_mtp;
    xj_w mtp_eh, mtp_enorm, mtp_hnorm, mtp_head_norm;
    gguf_file *mtp_gguf;                   // MTP 来自另一个文件时（否则 NULL）
} xj_model;

// 打开模型。只解析结构，权重留在 mmap 里，用到哪层读哪层（没用到的页不进内存）。
xj_model *xj_model_load(const char *path, char *err, size_t errlen);
// 只映射 [l0, l1) 层（with_io 时再加 embedding / 输出头）的权重。从机用这个。
xj_model *xj_model_load_layers(const char *path, int l0, int l1, bool with_io, char *err, size_t errlen);
// 只用头部建结构（data 都为 NULL），从机按这个算出要下载哪些字节
xj_model *xj_model_from_gguf(gguf_file *g, char *err, size_t errlen);
void xj_model_free(xj_model *m);
// 从另一个带 MTP 头的 GGUF（同一个模型，比如 prithivMLmods/Qwen3.5-9B-MTP-GGUF）挂上 MTP 层。
// 那个文件只需要文件头和 MTP 层那一段（其余可以是空洞），见 xj_model_mtp_ranges。
int xj_model_attach_mtp(xj_model *m, const char *path, char *err, size_t errlen);
// 带 MTP 的 GGUF 里 MTP 层的字节范围 [lo, hi)（App 只下这一段）；没有 MTP 返回 -1
int xj_model_mtp_range(gguf_file *g, uint64_t *lo, uint64_t *hi, char *err, size_t errlen);

// [l0, l1) 这些层的权重在文件里的字节范围（按偏移排好、相邻的已合并）。
// 输出到 ranges（每项 [起点, 终点)），返回个数；include_embd 时把 embedding / 输出头也算上。
int xj_model_ranges(const xj_model *m, int l0, int l1, bool include_embd, uint64_t (*ranges)[2], int max);
// [l0, l1) 层的权重总字节数
uint64_t xj_model_layer_bytes(const xj_model *m, int l0, int l1);

#ifdef __cplusplus
}
#endif
