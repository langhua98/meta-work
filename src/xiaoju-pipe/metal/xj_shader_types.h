// 小橘双机推理：Metal 内核参数（.metal 和 .m 共用这一份定义）
#pragma once

#ifdef __METAL_VERSION__
typedef uint  xu32;
typedef int   xi32;
#else
#include <stdint.h>
typedef uint32_t xu32;
typedef int32_t  xi32;
#endif

// 矩阵乘向量：一个线程组 128 线程 = 4 行 × 32 个线程，一个线程一次算 32 个元素（一个「单元」）
#define XJ_MV_ROWS 4
#define XJ_MV_LANES 32
#define XJ_MV_MAXT 8        // 一次最多带几个 token（权重读一遍给 8 个 token 用）

typedef struct {
    xu32 K, N, T;           // 输入维度、输出行数、token 数
    xu32 row_bytes;         // 一行权重多少字节
    xu32 x_stride, y_stride;// 每个 token 的输入 / 输出间隔（float 个数）
    xu32 add;               // 1：结果加到 y 上（残差连接）
    xu32 grid_x;            // 二维网格展开用
} xj_mv_args;

// RMSNorm / L2 归一化 / 门控归一化。第 r 行的位置 = (r / rows_per_tok) * tok_stride + (r % rows_per_tok) * row_stride
typedef struct {
    xu32 n, rows, rows_per_tok;
    xu32 in_tok_stride, in_row_stride;
    xu32 out_tok_stride, out_row_stride;
    xu32 gate_tok_stride, gate_row_stride;
    xu32 mode;              // 0：RMS（除以均方根）；1：L2（除以模长）
    xu32 has_w, has_gate;   // 乘权重（每行共用 n 个）；乘 silu(gate)
    float eps;
    xu32 grid_x;
} xj_norm_args;

typedef struct {
    xu32 n_rot, n_heads, head_stride, tok_stride, T, pos0;
    float base;
    xu32 grid_x;
} xj_rope_args;

typedef struct {
    xu32 T, n_kv_heads, D, src_tok_stride, k_off, v_off, pos0;  // k、v 可以在同一个缓冲里（合并的 qkv）
    xu32 grid_x;
} xj_kv_args;

typedef struct {
    xu32 T, H, Hkv, D, pos0, n_ctx;  // 第 t 个 token 看 0 .. pos0+t 的位置
    xu32 q_tok_stride, q_head_stride; // q 在缓冲里的布局（float）
    xu32 gate_off;                    // 门控相对 q 的偏移
    float scale;
    xu32 grid_x;
} xj_attn_args;

typedef struct {
    xu32 T, C, K;           // token 数、通道数、卷积核长度（K <= 8）
    xu32 grid_x;
} xj_conv_args;

typedef struct {
    xu32 T, Hk, Hv, S;      // token 数、key 头数、value 头数、每个头的维度
    xu32 qkv_tok_stride;    // qkv 缓冲里每个 token 的间隔
    xu32 k_off, v_off;      // k、v 在每个 token 里的起点
    xu32 out_tok_stride;
    float qscale;
} xj_dn_args;

typedef struct {
    xu32 n;
    xu32 grid_x;
} xj_ew_args;
