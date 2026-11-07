// 小橘双机推理：Qwen3.5 的 Metal 内核。
//
// 为什么不用 llama.cpp 的内核：它的矩阵乘、RMSNorm、softmax 都要 simdgroup 归约（A14 / Apple7 以上），
// iPhone 7 Plus 的 A10 是 Apple3，没有这些指令。这里所有归约都用 threadgroup 内存 + 栅栏做，
// 线程组最多 256 线程、共享内存最多 4 KB（A10 上限 512 线程 / 16 KB），网格全部用整数个线程组（A10 不支持非整数线程组）。
// 新手机上同一份内核也能跑，只是没 llama.cpp 那么快。
//
// 每个内核和 core/xj_cpu.c 里的一段一一对应，结果对照见 tests/metal_check.m。
#include <metal_stdlib>
using namespace metal;

#include "xj_shader_types.h"

// 和 core/gguf.h 的 enum xj_type 一样
#define T_F32 0
#define T_F16 1
#define T_Q8_0 8
#define T_Q4_K 12
#define T_Q5_K 13
#define T_Q6_K 14
#define T_BF16 30

static inline uint group_id(uint3 tg, uint grid_x) { return tg.y * grid_x + tg.x; }

static inline float silu_f(float x) { return x / (1.0f + exp(-x)); }

static inline void scale_min_k4(uint j, device const uchar *q, thread float &d, thread float &m) {
    if (j < 4) { d = q[j] & 63; m = q[j + 4] & 63; }
    else { d = (q[j + 4] & 0xF) | ((q[j - 4] >> 6) << 4); m = (q[j + 4] >> 4) | ((q[j] >> 6) << 4); }
}

static inline float rdh(device const uchar *p) { return float(*(device const half *)p); }

// 把一行里第 u 个单元（32 个元素）解码到 w[32]
template <int TYPE>
static inline void dequant_unit(device const uchar *row, uint u, thread float *w) {
    if (TYPE == T_F32) {
        device const float4 *p = (device const float4 *)(row + u * 128);
        for (int i = 0; i < 8; i++) { float4 v = p[i]; w[4*i] = v.x; w[4*i+1] = v.y; w[4*i+2] = v.z; w[4*i+3] = v.w; }
    } else if (TYPE == T_F16) {
        device const half4 *p = (device const half4 *)(row + u * 64);
        for (int i = 0; i < 8; i++) { float4 v = float4(p[i]); w[4*i] = v.x; w[4*i+1] = v.y; w[4*i+2] = v.z; w[4*i+3] = v.w; }
    } else if (TYPE == T_BF16) {
        device const ushort *p = (device const ushort *)(row + u * 64);
        for (int i = 0; i < 32; i++) w[i] = as_type<float>(uint(p[i]) << 16);
    } else if (TYPE == T_Q8_0) {
        device const uchar *b = row + u * 34;
        float d = rdh(b);
        device const char *q = (device const char *)(b + 2);
        for (int i = 0; i < 32; i++) w[i] = d * float(q[i]);
    } else if (TYPE == T_Q4_K) {
        device const uchar *b = row + (u / 8) * 144;
        uint j = u % 8;
        float d = rdh(b), dmin = rdh(b + 2), s, m;
        scale_min_k4(j, b + 4, s, m);
        float d1 = d * s, m1 = dmin * m;
        device const uchar *q = b + 16 + 32 * (j / 2);
        uint sh = (j & 1) * 4;
        for (int l = 0; l < 32; l++) w[l] = d1 * float((q[l] >> sh) & 0xF) - m1;
    } else if (TYPE == T_Q5_K) {
        device const uchar *b = row + (u / 8) * 176;
        uint j = u % 8;
        float d = rdh(b), dmin = rdh(b + 2), s, m;
        scale_min_k4(j, b + 4, s, m);
        float d1 = d * s, m1 = dmin * m;
        device const uchar *qh = b + 16, *ql = b + 48 + 32 * (j / 2);
        uint sh = (j & 1) * 4;
        for (int l = 0; l < 32; l++) w[l] = d1 * float(((ql[l] >> sh) & 0xF) + (((qh[l] >> j) & 1) << 4)) - m1;
    } else if (TYPE == T_Q6_K) {
        device const uchar *b = row + (u / 8) * 210;
        uint j = u % 8, n = j / 4, g = j % 4;
        device const uchar *ql = b + n * 64 + (g & 1) * 32, *qh = b + 128 + n * 32;
        device const char *sc = (device const char *)(b + 192 + n * 8 + 2 * g);
        float d = rdh(b + 208);
        uint lsh = g >= 2 ? 4 : 0, hsh = 2 * g;
        for (int l = 0; l < 32; l++) {
            int q = int(((ql[l] >> lsh) & 0xF) | (((qh[l] >> hsh) & 3) << 4)) - 32;
            w[l] = d * float(sc[l / 16]) * float(q);
        }
    }
}

// y[t][r] (+)= W[r] · x[t]，t < T（T <= 8）
template <int TYPE>
static void mv_impl(device const uchar *W, device const float *x, device float *y, constant xj_mv_args &a,
                    uint3 tg, uint tid, threadgroup float *red) {
    const uint grp = group_id(tg, a.grid_x);
    const uint rl = tid / XJ_MV_LANES, lane = tid % XJ_MV_LANES;
    const uint row = grp * XJ_MV_ROWS + rl;
    float acc[XJ_MV_MAXT];
    for (int t = 0; t < XJ_MV_MAXT; t++) acc[t] = 0;
    if (row < a.N) {
        device const uchar *r = W + (ulong)row * a.row_bytes;
        const uint nu = a.K / 32;
        for (uint u = lane; u < nu; u += XJ_MV_LANES) {
            float w[32];
            dequant_unit<TYPE>(r, u, w);
            for (uint t = 0; t < a.T; t++) {
                device const float4 *xp = (device const float4 *)(x + t * a.x_stride + u * 32);
                float s = 0;
                for (int i = 0; i < 8; i++) s += dot(float4(w[4*i], w[4*i+1], w[4*i+2], w[4*i+3]), xp[i]);
                acc[t] += s;
            }
        }
    }
    for (uint t = 0; t < XJ_MV_MAXT; t++) red[(t * XJ_MV_ROWS + rl) * XJ_MV_LANES + lane] = acc[t];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = XJ_MV_LANES / 2; s > 0; s >>= 1) {
        if (lane < s)
            for (uint t = 0; t < a.T; t++) red[(t * XJ_MV_ROWS + rl) * XJ_MV_LANES + lane] += red[(t * XJ_MV_ROWS + rl) * XJ_MV_LANES + lane + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lane == 0 && row < a.N) {
        for (uint t = 0; t < a.T; t++) {
            float v = red[(t * XJ_MV_ROWS + rl) * XJ_MV_LANES];
            device float *o = y + t * a.y_stride + row;
            *o = a.add ? *o + v : v;
        }
    }
}

#define MV_KERNEL(NAME, TYPE)                                                                    \
kernel void NAME(device const uchar *W [[buffer(0)]], device const float *x [[buffer(1)]],      \
                 device float *y [[buffer(2)]], constant xj_mv_args &a [[buffer(3)]],           \
                 uint3 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]]) { \
    threadgroup float red[XJ_MV_ROWS * XJ_MV_LANES * XJ_MV_MAXT];                                \
    mv_impl<TYPE>(W, x, y, a, tg, tid, red);                                                     \
}
MV_KERNEL(mv_f32, T_F32)
MV_KERNEL(mv_f16, T_F16)
MV_KERNEL(mv_bf16, T_BF16)
MV_KERNEL(mv_q8_0, T_Q8_0)
MV_KERNEL(mv_q4_K, T_Q4_K)
MV_KERNEL(mv_q5_K, T_Q5_K)
MV_KERNEL(mv_q6_K, T_Q6_K)

// ---------- 生成阶段（一次 1 个 token）专用的矩阵乘向量 ----------
// 生成时每个字都要把从机那几层权重整个读一遍，速度基本由读权重的带宽决定。上面的通用版先把 32 个元素解码进
// float w[32] 再乘，寄存器用得多（A10 上 mv_q6_K 每组只能开 224 线程），还要按 token 循环。
// 这里一个线程一次处理 Q4_K / Q5_K 的两个单元（共用同一段 4 位数据，只读一次）、Q6_K 的半个块（128 个元素），
// 边解码边乘，用 uchar4 / float4 成批读，只留一个累加器。

// Q4_K：第 p 对单元（64 个元素 = 一个块里的第 2jp、2jp+1 单元，共用 32 字节的 4 位数据）
static inline float q4k_pair(device const uchar *r, uint p, device const float *x) {
    device const uchar *b = r + (p / 4) * 144;
    const uint jp = p % 4;
    float d = rdh(b), dmin = rdh(b + 2), s0, m0, s1, m1;
    scale_min_k4(2 * jp, b + 4, s0, m0);
    scale_min_k4(2 * jp + 1, b + 4, s1, m1);
    device const uchar4 *q = (device const uchar4 *)(b + 16 + 32 * jp);
    device const float4 *xa = (device const float4 *)(x + p * 64), *xb = xa + 8;
    float4 lo = 0, hi = 0, sa = 0, sb = 0;
    for (int i = 0; i < 8; i++) {
        uchar4 v = q[i];
        float4 a = xa[i], c = xb[i];
        lo += float4(v & uchar4(0xF)) * a;
        hi += float4(v >> uchar4(4)) * c;
        sa += a; sb += c;
    }
    const float4 one = 1;
    return d * (s0 * dot(lo, one) + s1 * dot(hi, one)) - dmin * (m0 * dot(sa, one) + m1 * dot(sb, one));
}

// Q5_K：同上，多一位高位（32 字节 qh，第 j 个单元用第 j 位）
static inline float q5k_pair(device const uchar *r, uint p, device const float *x) {
    device const uchar *b = r + (p / 4) * 176;
    const uint jp = p % 4;
    float d = rdh(b), dmin = rdh(b + 2), s0, m0, s1, m1;
    scale_min_k4(2 * jp, b + 4, s0, m0);
    scale_min_k4(2 * jp + 1, b + 4, s1, m1);
    device const uchar4 *qh = (device const uchar4 *)(b + 16), *ql = (device const uchar4 *)(b + 48 + 32 * jp);
    device const float4 *xa = (device const float4 *)(x + p * 64), *xb = xa + 8;
    const uchar4 h0 = uchar4(2 * jp), h1 = uchar4(2 * jp + 1);
    float4 lo = 0, hi = 0, sa = 0, sb = 0;
    for (int i = 0; i < 8; i++) {
        uchar4 v = ql[i], h = qh[i];
        float4 a = xa[i], c = xb[i];
        lo += float4((v & uchar4(0xF)) + (((h >> h0) & uchar4(1)) << uchar4(4))) * a;
        hi += float4((v >> uchar4(4)) + (((h >> h1) & uchar4(1)) << uchar4(4))) * c;
        sa += a; sb += c;
    }
    const float4 one = 1;
    return d * (s0 * dot(lo, one) + s1 * dot(hi, one)) - dmin * (m0 * dot(sa, one) + m1 * dot(sb, one));
}

// Q6_K：第 h 个半块（128 个元素）。4 个单元共用 32 字节高位，两两共用 32 字节低位。
// 块长 210 字节，不是 4 的倍数，只能按字节读。
static inline float q6k_half(device const uchar *r, uint h, device const float *x) {
    device const uchar *b = r + (h / 2) * 210;
    const uint n = h % 2;
    device const uchar *ql = b + n * 64, *qh = b + 128 + n * 32;
    device const char *sc = (device const char *)(b + 192 + n * 8);
    device const float *xp = x + h * 128;
    float acc = 0;
    for (int half16 = 0; half16 < 2; half16++) {
        float s0 = 0, s1 = 0, s2 = 0, s3 = 0;
        for (int k = 0; k < 16; k++) {
            const int l = half16 * 16 + k;
            const int a = ql[l], c = ql[l + 32], hb = qh[l];
            s0 += float(int((a & 0xF) | ((hb & 3) << 4)) - 32) * xp[l];
            s1 += float(int((c & 0xF) | (((hb >> 2) & 3) << 4)) - 32) * xp[l + 32];
            s2 += float(int((a >> 4) | (((hb >> 4) & 3) << 4)) - 32) * xp[l + 64];
            s3 += float(int((c >> 4) | (((hb >> 6) & 3) << 4)) - 32) * xp[l + 96];
        }
        acc += float(sc[half16]) * s0 + float(sc[2 + half16]) * s1 + float(sc[4 + half16]) * s2 + float(sc[6 + half16]) * s3;
    }
    return rdh(b + 208) * acc;
}

template <int TYPE>
static void mv1_impl(device const uchar *W, device const float *x, device float *y, constant xj_mv_args &a,
                     uint3 tg, uint tid, threadgroup float *red) {
    const uint grp = group_id(tg, a.grid_x);
    const uint rl = tid / XJ_MV_LANES, lane = tid % XJ_MV_LANES;
    const uint row = grp * XJ_MV_ROWS + rl;
    float acc = 0;
    if (row < a.N) {
        device const uchar *r = W + (ulong)row * a.row_bytes;
        if (TYPE == T_Q4_K) {
            for (uint p = lane; p < a.K / 64; p += XJ_MV_LANES) acc += q4k_pair(r, p, x);
        } else if (TYPE == T_Q5_K) {
            for (uint p = lane; p < a.K / 64; p += XJ_MV_LANES) acc += q5k_pair(r, p, x);
        } else if (TYPE == T_Q6_K) {
            for (uint h = lane; h < a.K / 128; h += XJ_MV_LANES) acc += q6k_half(r, h, x);
        } else {
            for (uint u = lane; u < a.K / 32; u += XJ_MV_LANES) {
                float w[32];
                dequant_unit<TYPE>(r, u, w);
                device const float4 *xp = (device const float4 *)(x + u * 32);
                for (int i = 0; i < 8; i++) acc += dot(float4(w[4*i], w[4*i+1], w[4*i+2], w[4*i+3]), xp[i]);
            }
        }
    }
    red[tid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = XJ_MV_LANES / 2; s > 0; s >>= 1) {
        if (lane < s) red[tid] += red[tid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lane == 0 && row < a.N) {
        device float *o = y + row;
        *o = a.add ? *o + red[tid] : red[tid];
    }
}

#define MV1_KERNEL(NAME, TYPE)                                                                   \
kernel void NAME(device const uchar *W [[buffer(0)]], device const float *x [[buffer(1)]],      \
                 device float *y [[buffer(2)]], constant xj_mv_args &a [[buffer(3)]],           \
                 uint3 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]]) { \
    threadgroup float red[XJ_MV_ROWS * XJ_MV_LANES];                                             \
    mv1_impl<TYPE>(W, x, y, a, tg, tid, red);                                                    \
}
MV1_KERNEL(mv1_f32, T_F32)
MV1_KERNEL(mv1_f16, T_F16)
MV1_KERNEL(mv1_bf16, T_BF16)
MV1_KERNEL(mv1_q8_0, T_Q8_0)
MV1_KERNEL(mv1_q4_K, T_Q4_K)
MV1_KERNEL(mv1_q5_K, T_Q5_K)
MV1_KERNEL(mv1_q6_K, T_Q6_K)

// ---------- 新芯片（A14 / Apple7 起）版：同样的算法，归约用 simd_sum ----------
// 一个线程组 4 个 simdgroup，一个 simdgroup 算一行，不用线程组内存和栅栏。
// A10 上建不了这些管线（没有 simdgroup 归约），xj_metal.m 只在 supportsFamily(Apple7) 时用。
template <int TYPE>
static void mvs_impl(device const uchar *W, device const float *x, device float *y, constant xj_mv_args &a,
                     uint3 tg, uint tid) {
    const uint grp = group_id(tg, a.grid_x);
    const uint rl = tid / XJ_MV_LANES, lane = tid % XJ_MV_LANES;
    const uint row = grp * XJ_MV_ROWS + rl;
    if (row >= a.N) return;   // 整个 simdgroup 一起退出，不影响别的行
    device const uchar *r = W + (ulong)row * a.row_bytes;
    float acc = 0;
    if (TYPE == T_Q4_K) {
        for (uint p = lane; p < a.K / 64; p += XJ_MV_LANES) acc += q4k_pair(r, p, x);
    } else if (TYPE == T_Q5_K) {
        for (uint p = lane; p < a.K / 64; p += XJ_MV_LANES) acc += q5k_pair(r, p, x);
    } else {
        for (uint h = lane; h < a.K / 128; h += XJ_MV_LANES) acc += q6k_half(r, h, x);
    }
    acc = simd_sum(acc);
    if (lane == 0) {
        device float *o = y + row;
        *o = a.add ? *o + acc : acc;
    }
}

#define MVS_KERNEL(NAME, TYPE)                                                                   \
kernel void NAME(device const uchar *W [[buffer(0)]], device const float *x [[buffer(1)]],      \
                 device float *y [[buffer(2)]], constant xj_mv_args &a [[buffer(3)]],           \
                 uint3 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]]) { \
    mvs_impl<TYPE>(W, x, y, a, tg, tid);                                                         \
}
MVS_KERNEL(mvs_q4_K, T_Q4_K)
MVS_KERNEL(mvs_q5_K, T_Q5_K)
MVS_KERNEL(mvs_q6_K, T_Q6_K)

// 归一化：一个线程组（256 线程）一行。in 和 out 可以是同一个缓冲。
kernel void xj_norm(device const float *in [[buffer(0)]], device float *out [[buffer(1)]],
                    device const float *w [[buffer(2)]], device const float *gate [[buffer(3)]],
                    constant xj_norm_args &a [[buffer(4)]],
                    uint3 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                    uint3 ntg3 [[threads_per_threadgroup]]) {
    const uint ntg = ntg3.x;
    threadgroup float red[256];
    const uint row = group_id(tg, a.grid_x);
    if (row >= a.rows) return;  // 整个线程组一起返回，不会卡在栅栏上
    const uint t = row / a.rows_per_tok, h = row % a.rows_per_tok;
    device const float *ip = in + t * a.in_tok_stride + h * a.in_row_stride;
    device float *op = out + t * a.out_tok_stride + h * a.out_row_stride;
    device const float *gp = gate + t * a.gate_tok_stride + h * a.gate_row_stride;
    float ss = 0;
    for (uint i = tid; i < a.n; i += ntg) ss += ip[i] * ip[i];
    red[tid] = ss;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = ntg / 2; s > 0; s >>= 1) {
        if (tid < s) red[tid] += red[tid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    const float sum = red[0];
    const float sc = a.mode == 0 ? 1.0f / sqrt(sum / float(a.n) + a.eps) : 1.0f / sqrt(sum + a.eps);
    for (uint i = tid; i < a.n; i += ntg) {
        float v = ip[i] * sc;
        if (a.has_w) v *= w[i];
        if (a.has_gate) v *= silu_f(gp[i]);
        op[i] = v;
    }
}

// neox 旋转（原地）：每个线程转一对 (i, i + n_rot/2)
kernel void xj_rope(device float *x [[buffer(0)]], constant xj_rope_args &a [[buffer(1)]],
                    uint3 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                    uint3 ntg3 [[threads_per_threadgroup]]) {
    const uint ntg = ntg3.x;
    const uint gid = group_id(tg, a.grid_x) * ntg + tid;
    const uint half_rot = a.n_rot / 2;
    if (gid >= a.T * a.n_heads * half_rot) return;
    const uint i = gid % half_rot, h = (gid / half_rot) % a.n_heads, t = gid / (half_rot * a.n_heads);
    const float theta = float(a.pos0 + t) * precise::pow(a.base, -2.0f * float(i) / float(a.n_rot));
    const float c = precise::cos(theta), s = precise::sin(theta);
    device float *p = x + t * a.tok_stride + h * a.head_stride;
    const float x0 = p[i], x1 = p[i + half_rot];
    p[i] = x0 * c - x1 * s;
    p[i + half_rot] = x0 * s + x1 * c;
}

// 把这批 token 的 k、v 存进 KV 缓存（半精度）
kernel void xj_kv_store(device const float *k [[buffer(0)]], device const float *v [[buffer(1)]],
                        device half *kc [[buffer(2)]], device half *vc [[buffer(3)]],
                        constant xj_kv_args &a [[buffer(4)]],
                        uint3 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                        uint3 ntg3 [[threads_per_threadgroup]]) {
    const uint ntg = ntg3.x;
    const uint gid = group_id(tg, a.grid_x) * ntg + tid;
    const uint per = a.n_kv_heads * a.D;
    if (gid >= a.T * per) return;
    const uint t = gid / per, e = gid % per;
    kc[(a.pos0 + t) * per + e] = half(k[t * a.src_tok_stride + a.k_off + e]);
    vc[(a.pos0 + t) * per + e] = half(v[t * a.src_tok_stride + a.v_off + e]);
}

// 注意力分数：scores[t*H + h][j] = q·k_j * scale（j 超过因果范围写 -inf）
kernel void xj_attn_scores(device const float *q [[buffer(0)]], device const half *kc [[buffer(1)]],
                           device float *sc [[buffer(2)]], constant xj_attn_args &a [[buffer(3)]],
                           uint3 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                           uint3 ntg3 [[threads_per_threadgroup]]) {
    const uint ntg = ntg3.x;
    const uint gid = group_id(tg, a.grid_x) * ntg + tid;
    const uint n_kv = a.pos0 + a.T;
    if (gid >= a.T * a.H * n_kv) return;
    const uint j = gid % n_kv, h = (gid / n_kv) % a.H, t = gid / (n_kv * a.H);
    device float *o = sc + (t * a.H + h) * a.n_ctx + j;
    if (j > a.pos0 + t) { *o = -INFINITY; return; }
    const uint kvh = h / (a.H / a.Hkv);
    device const float4 *qp = (device const float4 *)(q + t * a.q_tok_stride + h * a.q_head_stride);
    device const half4 *kp = (device const half4 *)(kc + (j * a.Hkv + kvh) * a.D);
    float s = 0;
    for (uint i = 0; i < a.D / 4; i++) s += dot(qp[i], float4(kp[i]));
    *o = s * a.scale;
}

// softmax：一个线程组一行（长度 pos0+T）
kernel void xj_softmax(device float *sc [[buffer(0)]], constant xj_attn_args &a [[buffer(1)]],
                       uint3 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                       uint3 ntg3 [[threads_per_threadgroup]]) {
    const uint ntg = ntg3.x;
    threadgroup float red[256];
    const uint row = group_id(tg, a.grid_x);
    if (row >= a.T * a.H) return;
    const uint n = a.pos0 + a.T;
    device float *p = sc + row * a.n_ctx;
    float mx = -INFINITY;
    for (uint i = tid; i < n; i += ntg) mx = max(mx, p[i]);
    red[tid] = mx;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = ntg / 2; s > 0; s >>= 1) {
        if (tid < s) red[tid] = max(red[tid], red[tid + s]);
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    mx = red[0];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float sum = 0;
    for (uint i = tid; i < n; i += ntg) { float e = exp(p[i] - mx); p[i] = e; sum += e; }
    red[tid] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = ntg / 2; s > 0; s >>= 1) {
        if (tid < s) red[tid] += red[tid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    const float inv = 1.0f / red[0];
    for (uint i = tid; i < n; i += ntg) p[i] *= inv;
}

// 注意力输出：out[t][h][d] = Σ_j p_j v_j[d]，再乘 sigmoid(门控)
kernel void xj_attn_out(device const float *sc [[buffer(0)]], device const half *vc [[buffer(1)]],
                        device const float *gate [[buffer(2)]], device float *out [[buffer(3)]],
                        constant xj_attn_args &a [[buffer(4)]],
                        uint3 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                        uint3 ntg3 [[threads_per_threadgroup]]) {
    const uint ntg = ntg3.x;
    const uint gid = group_id(tg, a.grid_x) * ntg + tid;
    if (gid >= a.T * a.H * a.D) return;
    const uint d = gid % a.D, h = (gid / a.D) % a.H, t = gid / (a.D * a.H);
    const uint kvh = h / (a.H / a.Hkv);
    device const float *p = sc + (t * a.H + h) * a.n_ctx;
    float o = 0;
    const uint last = a.pos0 + t;
    for (uint j = 0; j <= last; j++) o += p[j] * float(vc[(j * a.Hkv + kvh) * a.D + d]);
    const float g = gate[t * a.q_tok_stride + h * a.q_head_stride + a.gate_off + d];
    out[(t * a.H + h) * a.D + d] = o / (1.0f + exp(-g));
}

// 因果卷积 + silu（原地）。一个线程一个通道，按 token 顺序走，卷积状态留着给下一批
kernel void xj_conv_silu(device float *x [[buffer(0)]], device float *state [[buffer(1)]],
                         device const float *w [[buffer(2)]], constant xj_conv_args &a [[buffer(3)]],
                         uint3 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                         uint3 ntg3 [[threads_per_threadgroup]]) {
    const uint ntg = ntg3.x;
    const uint c = group_id(tg, a.grid_x) * ntg + tid;
    if (c >= a.C) return;
    float st[8], wc[8];
    for (uint k = 0; k + 1 < a.K; k++) st[k] = state[c * (a.K - 1) + k];
    for (uint k = 0; k < a.K; k++) wc[k] = w[c * a.K + k];
    for (uint t = 0; t < a.T; t++) {
        const float xv = x[t * a.C + c];
        float acc = xv * wc[a.K - 1];
        for (uint k = 0; k + 1 < a.K; k++) acc += st[k] * wc[k];
        for (uint k = 0; k + 2 < a.K; k++) st[k] = st[k + 1];
        st[a.K - 2] = xv;
        x[t * a.C + c] = silu_f(acc);
    }
    for (uint k = 0; k + 1 < a.K; k++) state[c * (a.K - 1) + k] = st[k];
}

// Gated DeltaNet 递推：一个线程组一个 value 头，线程 j 负责状态矩阵的第 j 列（value 的第 j 维）。
// 状态存成 Mt[i][j]（i 是 key 维），相邻线程读相邻地址。
kernel void xj_delta_net(device const float *qkv [[buffer(0)]], device const float *beta_raw [[buffer(1)]],
                         device const float *alpha_raw [[buffer(2)]], device const float *dt [[buffer(3)]],
                         device const float *A [[buffer(4)]], device float *state [[buffer(5)]],
                         device float *out [[buffer(6)]], constant xj_dn_args &a [[buffer(7)]],
                         uint3 tg [[threadgroup_position_in_grid]], uint j [[thread_index_in_threadgroup]]) {
    threadgroup float kk[512], qq[512];
    const uint hv = tg.x, hk = hv % a.Hk, S = a.S;
    device float *M = state + hv * S * S;
    for (uint t = 0; t < a.T; t++) {
        device const float *row = qkv + t * a.qkv_tok_stride;
        qq[j] = row[hk * S + j];
        kk[j] = row[a.k_off + hk * S + j];
        threadgroup_barrier(mem_flags::mem_threadgroup);
        const float b = 1.0f / (1.0f + exp(-beta_raw[t * a.Hv + hv]));
        const float z = alpha_raw[t * a.Hv + hv] + dt[hv];
        const float sp = z > 20.0f ? z : log(1.0f + exp(z));
        const float eg = exp(sp * A[hv]);
        float sk = 0;
        for (uint i = 0; i < S; i++) {
            float m = M[i * S + j] * eg;
            M[i * S + j] = m;
            sk += m * kk[i];
        }
        const float delta = (row[a.v_off + hv * S + j] - sk) * b;
        float o = 0;
        for (uint i = 0; i < S; i++) {
            float m = M[i * S + j] + kk[i] * delta;
            M[i * S + j] = m;
            o += m * qq[i];
        }
        out[t * a.out_tok_stride + hv * S + j] = o * a.qscale;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

// g = silu(g) * u
kernel void xj_swiglu(device float *g [[buffer(0)]], device const float *u [[buffer(1)]],
                      constant xj_ew_args &a [[buffer(2)]],
                      uint3 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                      uint3 ntg3 [[threads_per_threadgroup]]) {
    const uint ntg = ntg3.x;
    const uint i = group_id(tg, a.grid_x) * ntg + tid;
    if (i >= a.n) return;
    g[i] = silu_f(g[i]) * u[i];
}
