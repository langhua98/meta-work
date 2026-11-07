// 小橘双机推理：Metal stage。接口和 CPU 版一样（core/xj_stage.h），内核在 xj_kernels.metal。
//
// 权重不拷贝：模型文件 mmap 之后，直接用 newBufferWithBytesNoCopy 把那段内存交给 GPU（和 llama.cpp 一样），
// 7P 上没用到的层根本不会读进内存。KV 缓存用半精度，线性注意力状态用 float。
// 所有 dispatch 放在一个 compute encoder 里顺序执行（默认串行模式，后一个能看到前一个的结果）。
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "../core/xj_stage.h"
#include "xj_shader_types.h"

typedef struct { uint64_t file_off; uint32_t buf; uint64_t off; } wmap;

@interface XJMetal : NSObject
@property(nonatomic, strong) id<MTLDevice> dev;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id<MTLComputePipelineState>> *pso;
@property(nonatomic, strong) NSMutableArray<id<MTLBuffer>> *wbufs;
@property(nonatomic, strong) NSMutableArray<id<MTLBuffer>> *kc, *vc, *conv, *ssm;  // 每层一个（没用的放占位）
@property(nonatomic, strong) id<MTLBuffer> x, h, A, B, C, D, G, SC, logits, dummy;
@property(nonatomic) BOOL simd;   // 能用 mvs_*（simd_sum 版矩阵乘）
@property(nonatomic) uint32_t lanes;  // mv1_* 每行几个线程（自动调优选出来的）
@end
@implementation XJMetal
@end

typedef struct {
    void *obj;          // XJMetal（桥接持有）
    wmap *maps; int n_maps;
    size_t sf;          // 每个临时缓冲多少 float
} metal_impl;

static XJMetal *M(xj_stage *s) { return (__bridge XJMetal *)((metal_impl *)s->impl)->obj; }

static NSString *g_device_name;
static NSString *g_tune_note;   // 调优结果，界面上显示
const char *xj_metal_tune_note(void) { return g_tune_note ? g_tune_note.UTF8String : ""; }
const char *xj_metal_device_name(void) { return g_device_name ? g_device_name.UTF8String : "Metal"; }

// ---------- 内核库 ----------

static id<MTLLibrary> load_library(id<MTLDevice> dev, char *err, size_t errlen) {
    // App 里：Xcode 把 xj_kernels.metal 编进 default.metallib
    id<MTLLibrary> lib = [dev newDefaultLibrary];
    if (lib && [lib newFunctionWithName:@"mv_q4_K"]) return lib;
    // 命令行：运行时从源码编译（XJ_METAL_DIR 或 ./metal 下找）
    NSString *dir = NSProcessInfo.processInfo.environment[@"XJ_METAL_DIR"] ?: @"metal";
    NSString *src = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"xj_kernels.metal"] encoding:NSUTF8StringEncoding error:nil];
    NSString *hdr = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"xj_shader_types.h"] encoding:NSUTF8StringEncoding error:nil];
    if (!src || !hdr) { snprintf(err, errlen, "找不到 Metal 内核（设 XJ_METAL_DIR 指向 metal/ 目录）"); return nil; }
    src = [src stringByReplacingOccurrencesOfString:@"#include \"xj_shader_types.h\"" withString:hdr];
    MTLCompileOptions *opt = [MTLCompileOptions new];
    NSError *e = nil;
    lib = [dev newLibraryWithSource:src options:opt error:&e];
    if (!lib) { snprintf(err, errlen, "Metal 内核编译失败：%s", e.localizedDescription.UTF8String); return nil; }
    return lib;
}

// one = 一次只有 1 个 token（生成阶段）：用 mv1_ 专用内核
static const char *mv_name(uint32_t type, bool one) {
    switch (type) {
        case XJ_F32: return one ? "mv1_f32" : "mv_f32"; case XJ_F16: return one ? "mv1_f16" : "mv_f16";
        case XJ_BF16: return one ? "mv1_bf16" : "mv_bf16"; case XJ_Q8_0: return one ? "mv1_q8_0" : "mv_q8_0";
        case XJ_Q4_K: return one ? "mv1_q4_K" : "mv_q4_K"; case XJ_Q5_K: return one ? "mv1_q5_K" : "mv_q5_K";
        case XJ_Q6_K: return one ? "mv1_q6_K" : "mv_q6_K"; default: return NULL;
    }
}

// ---------- 权重映射 ----------

static int find_map(metal_impl *im, const xj_w *w) {
    for (int i = 0; i < im->n_maps; i++) if (im->maps[i].file_off == w->file_off) return i;
    return -1;
}

static void collect(const xj_w *w, const xj_w **list, int *n) {
    if (!w->nbytes) return;
    for (int i = 0; i < *n; i++) if (list[i]->file_off == w->file_off) return;
    list[(*n)++] = w;
}

static int cmp_w(const void *a, const void *b) {
    const xj_w *x = *(const xj_w *const *)a, *y = *(const xj_w *const *)b;
    return x->file_off < y->file_off ? -1 : x->file_off > y->file_off;
}

static bool map_weights(xj_stage *s, metal_impl *im, XJMetal *o, char *err, size_t errlen) {
    const xj_model *m = s->m;
    const uint64_t page = (uint64_t)getpagesize();
    const uint64_t maxlen = o.dev.maxBufferLength;
    const xj_w **list = calloc(64 * (s->l1 - s->l0) + 8, sizeof(xj_w *));
    int n = 0;
    for (int il = s->l0; il < s->l1; il++) {
        const xj_w *ws = (const xj_w *)&m->layers[il].attn_norm;
        int count = (int)((sizeof(xj_layer) - offsetof(xj_layer, attn_norm)) / sizeof(xj_w));
        for (int k = 0; k < count; k++) collect(&ws[k], list, &n);
    }
    if (s->has_head) { collect(&m->output_norm, list, &n); collect(&m->output, list, &n); }
    qsort(list, n, sizeof(list[0]), cmp_w);
    im->maps = calloc(n ? n : 1, sizeof(wmap));
    o.wbufs = [NSMutableArray array];
    // 按文件顺序把相邻权重装进同一个缓冲，每个缓冲不超过设备上限
    int i = 0;
    while (i < n) {
        uint64_t start = list[i]->file_off / page * page, end = start;
        int j = i;
        while (j < n) {
            uint64_t e = (list[j]->file_off + list[j]->nbytes + page - 1) / page * page;
            if (e - start > maxlen && j > i) break;
            // 中间隔着一大段别人的权重（比如主机后半段和输出头之间夹着从机那几层）就另起一个缓冲，
            // 不把用不到的那 1 GB 也交给 GPU
            if (j > i && list[j]->file_off > end + (8u << 20)) break;
            if (e - start > maxlen) { snprintf(err, errlen, "一个张量就超过 GPU 缓冲上限（%llu MB）", maxlen >> 20); free(list); return false; }
            if (e > end) end = e;
            j++;
        }
        const void *ptr = gguf_ptr(m->gguf, start, 1);
        if (!ptr || start < m->gguf->map_off) { snprintf(err, errlen, "第 %d 层之后的权重没映射", s->l0); free(list); return false; }
        id<MTLBuffer> b = [o.dev newBufferWithBytesNoCopy:(void *)ptr length:end - start
                                                  options:MTLResourceStorageModeShared deallocator:nil];
        if (!b) { snprintf(err, errlen, "GPU 映射权重失败（%llu MB）", (end - start) >> 20); free(list); return false; }
        for (int k = i; k < j; k++) {
            wmap *mp = &im->maps[im->n_maps++];
            mp->file_off = list[k]->file_off;
            mp->buf = (uint32_t)o.wbufs.count;
            mp->off = list[k]->file_off - start;
        }
        [o.wbufs addObject:b];
        i = j;
    }
    // 预读：每页摸一下，第一个 token 就不用等闪存（7P 上 8 层约 1 GB，要几秒）
    volatile uint8_t sink = 0;
    for (int k = 0; k < n; k++) {
        const uint8_t *p = list[k]->data;
        for (uint64_t off = 0; off < list[k]->nbytes; off += page) sink ^= p[off];
    }
    (void)sink;
    free(list);
    return true;
}

// ---------- 编码小工具 ----------

static id<MTLComputePipelineState> P(XJMetal *o, const char *name) { return o.pso[@(name)]; }

// 线程组太多时摊成二维网格（每维不超过 32768），内核里用 grid_x 还原成一维编号
static uint32_t gx_of(uint32_t groups) { return groups == 0 ? 1 : groups < 32768 ? groups : 32768; }

static void dispatch(id<MTLComputeCommandEncoder> enc, uint32_t groups, uint32_t threads) {
    if (!groups) groups = 1;
    uint32_t gx = groups < 32768 ? groups : 32768, gy = (groups + gx - 1) / gx;
    [enc dispatchThreadgroups:MTLSizeMake(gx, gy, 1) threadsPerThreadgroup:MTLSizeMake(threads, 1, 1)];
}

static void set_w(id<MTLComputeCommandEncoder> enc, xj_stage *s, const xj_w *w, int idx) {
    metal_impl *im = s->impl;
    int k = find_map(im, w);
    [enc setBuffer:M(s).wbufs[im->maps[k].buf] offset:im->maps[k].off atIndex:idx];
}

// y[t] (+)= W·x[t]，x、y 带偏移（float 个数）
static void enc_mv(id<MTLComputeCommandEncoder> enc, xj_stage *s, const xj_w *w,
                   id<MTLBuffer> x, size_t xoff, uint32_t xs, id<MTLBuffer> y, size_t yoff, uint32_t ys, int T, bool add) {
    XJMetal *o = M(s);
    set_w(enc, s, w, 0);
    for (int t0 = 0; t0 < T; t0 += XJ_MV_MAXT) {
        xj_mv_args a = { (uint32_t)w->ne0, (uint32_t)w->ne1, (uint32_t)(T - t0 < XJ_MV_MAXT ? T - t0 : XJ_MV_MAXT),
                         (uint32_t)xj_row_bytes(w->type, w->ne0), xs, ys, add ? 1u : 0u, 0, XJ_MV_LANES };
        // XJ_MV_GENERIC=1：生成阶段也用通用内核（xjpipe-check 对比速度用）
        static int generic = -1;
        if (generic < 0) generic = getenv("XJ_MV_GENERIC") != NULL;
        const char *nm = mv_name(w->type, a.T == 1 && !generic);
        // 新芯片上 Q4_K / Q5_K / Q6_K 用 simd_sum 版（XJ_MV_NOSIMD=1 关掉）
        if (a.T == 1 && !generic && o.simd && (w->type == XJ_Q4_K || w->type == XJ_Q5_K || w->type == XJ_Q6_K))
            nm = w->type == XJ_Q4_K ? "mvs_q4_K" : w->type == XJ_Q5_K ? "mvs_q5_K" : "mvs_q6_K";
        else if (!strncmp(nm, "mv1_", 4) && o.lanes)
            a.lanes = o.lanes;   // mv1_*：用调优选出的每行线程数
        else if (a.T > 1 && !generic && (w->type == XJ_Q4_K || w->type == XJ_Q5_K || w->type == XJ_Q6_K))
            nm = w->type == XJ_Q4_K ? "mvb_q4_K" : w->type == XJ_Q5_K ? "mvb_q5_K" : "mvb_q6_K";   // 多 token
        const uint32_t rows = XJ_MV_ROWS * XJ_MV_LANES / a.lanes;
        const uint32_t groups = (uint32_t)((w->ne1 + rows - 1) / rows);
        [enc setComputePipelineState:P(o, nm)];
        a.grid_x = gx_of(groups);
        [enc setBuffer:x offset:(xoff + (size_t)t0 * xs) * 4 atIndex:1];
        [enc setBuffer:y offset:(yoff + (size_t)t0 * ys) * 4 atIndex:2];
        [enc setBytes:&a length:sizeof a atIndex:3];
        dispatch(enc, groups, XJ_MV_ROWS * XJ_MV_LANES);
    }
}

// 自动调优：mv1_* 每行用几个线程最快。不同 GPU 差别很大（A10 上 32 个线程分一行，每个线程只算两三段就要归约 5 轮），
// 拿这一段最大的一个矩阵（第一层的 ffn_up）每种跑几遍，挑最快的。XJ_MV_LANES 可以强制指定。
static uint32_t tune_lanes(xj_stage *s, char *note, size_t nlen) {
    XJMetal *o = M(s);
    const char *env = getenv("XJ_MV_LANES");
    if (env) { int v = atoi(env); if (v == 4 || v == 8 || v == 16 || v == 32) { snprintf(note, nlen, "每行 %d 线程（指定）", v); return (uint32_t)v; } }
    const xj_w *w = &s->m->layers[s->l0].ffn_up;
    if (!mv_name(w->type, true)) return XJ_MV_LANES;
    const uint32_t cand[] = { 32, 16, 8, 4 };
    double best = 1e30; uint32_t pick = XJ_MV_LANES;
    char buf[160] = ""; size_t bl = 0;
    for (int c = 0; c < 4; c++) {
        o.lanes = cand[c];
        double t = 1e30;
        for (int rep = 0; rep < 4; rep++) {
            @autoreleasepool {
                id<MTLCommandBuffer> cb = [o.queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                for (int k = 0; k < 4; k++) enc_mv(enc, s, w, o.h, 0, (uint32_t)w->ne0, o.G, 0, (uint32_t)w->ne1, 1, false);
                [enc endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                if (cb.status != MTLCommandBufferStatusCompleted) { o.lanes = XJ_MV_LANES; return XJ_MV_LANES; }
                double dt = cb.GPUEndTime - cb.GPUStartTime;
                if (rep > 0 && dt > 0 && dt < t) t = dt;   // 第一遍预热
            }
        }
        if (t < best) { best = t; pick = cand[c]; }
        bl += (size_t)snprintf(buf + bl, sizeof buf - bl, "%s%u:%.2fms", c ? " " : "", cand[c], t * 1e3 / 4);
    }
    o.lanes = pick;
    snprintf(note, nlen, "每行 %u 线程（%s）", pick, buf);
    return pick;
}

typedef struct { id<MTLBuffer> b; size_t off; uint32_t tok, row; } view;  // 缓冲 + 起点 + 每 token 间隔 + 每行间隔（float）

static void enc_norm(id<MTLComputeCommandEncoder> enc, xj_stage *s, view in, view out, const xj_w *w, view *gate,
                     uint32_t n, uint32_t rows, uint32_t rows_per_tok, uint32_t mode) {
    XJMetal *o = M(s);
    xj_norm_args a = { n, rows, rows_per_tok, in.tok, in.row, out.tok, out.row,
                       gate ? gate->tok : 0, gate ? gate->row : 0, mode, w ? 1u : 0u, gate ? 1u : 0u, s->m->hp.eps, 0 };
    a.grid_x = gx_of(rows);
    [enc setComputePipelineState:P(o, "xj_norm")];
    [enc setBuffer:in.b offset:in.off * 4 atIndex:0];
    [enc setBuffer:out.b offset:out.off * 4 atIndex:1];
    if (w) set_w(enc, s, w, 2); else [enc setBuffer:o.dummy offset:0 atIndex:2];
    if (gate) [enc setBuffer:gate->b offset:gate->off * 4 atIndex:3]; else [enc setBuffer:o.dummy offset:0 atIndex:3];
    [enc setBytes:&a length:sizeof a atIndex:4];
    dispatch(enc, rows, 256);
}

static void enc_rope(id<MTLComputeCommandEncoder> enc, xj_stage *s, view v, uint32_t heads, int T) {
    const xj_hparams *hp = &s->m->hp;
    xj_rope_args a = { (uint32_t)hp->n_rot, heads, v.row, v.tok, (uint32_t)T, (uint32_t)s->n_past, hp->rope_base, 0 };
    uint32_t total = (uint32_t)T * heads * hp->n_rot / 2, groups = (total + 63) / 64;
    a.grid_x = gx_of(groups);
    [enc setComputePipelineState:P(M(s), "xj_rope")];
    [enc setBuffer:v.b offset:v.off * 4 atIndex:0];
    [enc setBytes:&a length:sizeof a atIndex:1];
    dispatch(enc, groups, 64);
}

// ---------- 一层 ----------

static void enc_full(id<MTLComputeCommandEncoder> enc, xj_stage *s, int il, int T) {
    XJMetal *o = M(s);
    const xj_hparams *hp = &s->m->hp;
    const xj_layer *L = &s->m->layers[il];
    const uint32_t D = hp->head_dim, H = hp->n_head, Hkv = hp->n_head_kv, nq = 2 * H * D, nk = Hkv * D;
    const uint32_t E = hp->n_embd;
    view q, k, v;
    if (L->wqkv.nbytes) {
        const uint32_t st = nq + 2 * nk;
        enc_mv(enc, s, &L->wqkv, o.h, 0, E, o.G, 0, st, T, false);
        q = (view){ o.G, 0, st, 2 * D }; k = (view){ o.G, nq, st, D }; v = (view){ o.G, nq + nk, st, D };
    } else {
        enc_mv(enc, s, &L->wq, o.h, 0, E, o.A, 0, nq, T, false);
        enc_mv(enc, s, &L->wk, o.h, 0, E, o.B, 0, nk, T, false);
        enc_mv(enc, s, &L->wv, o.h, 0, E, o.C, 0, nk, T, false);
        q = (view){ o.A, 0, nq, 2 * D }; k = (view){ o.B, 0, nk, D }; v = (view){ o.C, 0, nk, D };
    }
    enc_norm(enc, s, q, q, &L->q_norm, NULL, D, T * H, H, 0);
    enc_norm(enc, s, k, k, &L->k_norm, NULL, D, T * Hkv, Hkv, 0);
    enc_rope(enc, s, q, H, T);
    enc_rope(enc, s, k, Hkv, T);

    const int li = il - s->l0;
    {
        xj_kv_args a = { (uint32_t)T, Hkv, D, k.tok, 0, 0, (uint32_t)s->n_past, 0 };
        uint32_t groups = ((uint32_t)T * nk + 63) / 64;
        a.grid_x = gx_of(groups);
        [enc setComputePipelineState:P(o, "xj_kv_store")];
        [enc setBuffer:k.b offset:k.off * 4 atIndex:0];
        [enc setBuffer:v.b offset:v.off * 4 atIndex:1];
        [enc setBuffer:o.kc[li] offset:0 atIndex:2];
        [enc setBuffer:o.vc[li] offset:0 atIndex:3];
        [enc setBytes:&a length:sizeof a atIndex:4];
        dispatch(enc, groups, 64);
    }
    xj_attn_args a = { (uint32_t)T, H, Hkv, D, (uint32_t)s->n_past, (uint32_t)s->n_ctx, q.tok, q.row, D,
                       1.0f / sqrtf((float)D), 0 };
    {
        uint32_t total = (uint32_t)T * H * (s->n_past + T), groups = (total + 63) / 64;
        a.grid_x = gx_of(groups);
        [enc setComputePipelineState:P(o, "xj_attn_scores")];
        [enc setBuffer:q.b offset:q.off * 4 atIndex:0];
        [enc setBuffer:o.kc[li] offset:0 atIndex:1];
        [enc setBuffer:o.SC offset:0 atIndex:2];
        [enc setBytes:&a length:sizeof a atIndex:3];
        dispatch(enc, groups, 64);
    }
    {
        uint32_t groups = (uint32_t)T * H;
        a.grid_x = gx_of(groups);
        [enc setComputePipelineState:P(o, "xj_softmax")];
        [enc setBuffer:o.SC offset:0 atIndex:0];
        [enc setBytes:&a length:sizeof a atIndex:1];
        dispatch(enc, groups, 256);
    }
    {
        uint32_t total = (uint32_t)T * H * D, groups = (total + 63) / 64;
        a.grid_x = gx_of(groups);
        [enc setComputePipelineState:P(o, "xj_attn_out")];
        [enc setBuffer:o.SC offset:0 atIndex:0];
        [enc setBuffer:o.vc[li] offset:0 atIndex:1];
        [enc setBuffer:q.b offset:q.off * 4 atIndex:2];
        [enc setBuffer:o.D offset:0 atIndex:3];
        [enc setBytes:&a length:sizeof a atIndex:4];
        dispatch(enc, groups, 64);
    }
    enc_mv(enc, s, &L->wo, o.D, 0, H * D, o.x, 0, E, T, true);
}

static void enc_linear(id<MTLComputeCommandEncoder> enc, xj_stage *s, int il, int T) {
    XJMetal *o = M(s);
    const xj_hparams *hp = &s->m->hp;
    const xj_layer *L = &s->m->layers[il];
    const uint32_t E = hp->n_embd, CD = hp->conv_dim, S = hp->s_k, Hk = hp->h_k, Hv = hp->h_v, DI = hp->d_inner;
    const int li = il - s->l0;
    enc_mv(enc, s, &L->ssm_qkv, o.h, 0, E, o.A, 0, CD, T, false);
    enc_mv(enc, s, &L->ssm_gate, o.h, 0, E, o.B, 0, DI, T, false);
    enc_mv(enc, s, &L->ssm_beta, o.h, 0, E, o.C, 0, Hv, T, false);
    enc_mv(enc, s, &L->ssm_alpha, o.h, 0, E, o.D, 0, Hv, T, false);
    {
        xj_conv_args a = { (uint32_t)T, CD, (uint32_t)hp->conv_k, 0 };
        uint32_t groups = (CD + 63) / 64;
        a.grid_x = gx_of(groups);
        [enc setComputePipelineState:P(o, "xj_conv_silu")];
        [enc setBuffer:o.A offset:0 atIndex:0];
        [enc setBuffer:o.conv[li] offset:0 atIndex:1];
        set_w(enc, s, &L->ssm_conv1d, 2);
        [enc setBytes:&a length:sizeof a atIndex:3];
        dispatch(enc, groups, 64);
    }
    view qv = { o.A, 0, CD, S }, kv = { o.A, (size_t)hp->key_dim, CD, S };
    enc_norm(enc, s, qv, qv, NULL, NULL, S, T * Hk, Hk, 1);
    enc_norm(enc, s, kv, kv, NULL, NULL, S, T * Hk, Hk, 1);
    {
        xj_dn_args a = { (uint32_t)T, Hk, Hv, S, CD, (uint32_t)hp->key_dim, (uint32_t)(2 * hp->key_dim), DI, 1.0f / sqrtf((float)S) };
        [enc setComputePipelineState:P(o, "xj_delta_net")];
        [enc setBuffer:o.A offset:0 atIndex:0];
        [enc setBuffer:o.C offset:0 atIndex:1];
        [enc setBuffer:o.D offset:0 atIndex:2];
        set_w(enc, s, &L->ssm_dt, 3);
        set_w(enc, s, &L->ssm_a, 4);
        [enc setBuffer:o.ssm[li] offset:0 atIndex:5];
        [enc setBuffer:o.G offset:0 atIndex:6];
        [enc setBytes:&a length:sizeof a atIndex:7];
        [enc dispatchThreadgroups:MTLSizeMake(Hv, 1, 1) threadsPerThreadgroup:MTLSizeMake(S, 1, 1)];
    }
    view ov = { o.G, 0, DI, S }, zv = { o.B, 0, DI, S };
    enc_norm(enc, s, ov, ov, &L->ssm_norm, &zv, S, T * Hv, Hv, 0);
    enc_mv(enc, s, &L->ssm_out, o.G, 0, DI, o.x, 0, E, T, true);
}

static int metal_forward(xj_stage *s, float *x, int T, char *err, size_t errlen) {
    XJMetal *o = M(s);
    const xj_hparams *hp = &s->m->hp;
    const uint32_t E = hp->n_embd, FF = hp->n_ff;
    if (T <= 0 || T > s->max_batch) { snprintf(err, errlen, "一次 %d 个 token，超过上限 %d", T, s->max_batch); return -1; }
    if (s->n_past + T > s->n_ctx) { snprintf(err, errlen, "上下文满了（%d）", s->n_ctx); return -1; }
    memcpy(o.x.contents, x, (size_t)T * E * 4);
    @autoreleasepool {
        id<MTLCommandBuffer> cb = [o.queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        for (int il = s->l0; il < s->l1; il++) {
            const xj_layer *L = &s->m->layers[il];
            view xv = { o.x, 0, E, 0 }, hv = { o.h, 0, E, 0 };
            enc_norm(enc, s, xv, hv, &L->attn_norm, NULL, E, T, 1, 0);
            if (L->recurrent) enc_linear(enc, s, il, T); else enc_full(enc, s, il, T);
            enc_norm(enc, s, xv, hv, &L->post_norm, NULL, E, T, 1, 0);
            enc_mv(enc, s, &L->ffn_gate, o.h, 0, E, o.G, 0, FF, T, false);
            enc_mv(enc, s, &L->ffn_up, o.h, 0, E, o.A, 0, FF, T, false);
            {
                xj_ew_args a = { (uint32_t)T * FF, 0 };
                uint32_t groups = (a.n + 63) / 64;
                a.grid_x = gx_of(groups);
                [enc setComputePipelineState:P(o, "xj_swiglu")];
                [enc setBuffer:o.G offset:0 atIndex:0];
                [enc setBuffer:o.A offset:0 atIndex:1];
                [enc setBytes:&a length:sizeof a atIndex:2];
                dispatch(enc, groups, 64);
            }
            enc_mv(enc, s, &L->ffn_down, o.G, 0, FF, o.x, 0, E, T, true);
        }
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) {
            snprintf(err, errlen, "GPU 出错：%s（App 在后台时 iOS 不让用 GPU，保持亮屏）", cb.error.localizedDescription.UTF8String ?: "?");
            return -1;
        }
    }
    memcpy(x, o.x.contents, (size_t)T * E * 4);
    s->n_past += T;
    return 0;
}

static int metal_logits(xj_stage *s, const float *x, float *logits, char *err, size_t errlen) {
    XJMetal *o = M(s);
    const xj_hparams *hp = &s->m->hp;
    if (!s->has_head) { snprintf(err, errlen, "这一段没有输出头"); return -1; }
    memcpy(o.x.contents, x, (size_t)hp->n_embd * 4);
    @autoreleasepool {
        id<MTLCommandBuffer> cb = [o.queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        view xv = { o.x, 0, (uint32_t)hp->n_embd, 0 }, hv = { o.h, 0, (uint32_t)hp->n_embd, 0 };
        enc_norm(enc, s, xv, hv, &s->m->output_norm, NULL, hp->n_embd, 1, 1, 0);
        enc_mv(enc, s, &s->m->output, o.h, 0, hp->n_embd, o.logits, 0, (uint32_t)s->m->output.ne1, 1, false);
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) { snprintf(err, errlen, "GPU 出错"); return -1; }
    }
    memcpy(logits, o.logits.contents, sizeof(float) * s->m->output.ne1);
    return 0;
}

static void metal_reset(xj_stage *s) {
    XJMetal *o = M(s);
    for (id<MTLBuffer> b in o.conv) memset(b.contents, 0, b.length);
    for (id<MTLBuffer> b in o.ssm) memset(b.contents, 0, b.length);
    s->n_past = 0;
}

static void metal_destroy(xj_stage *s) {
    if (!s) return;
    metal_impl *im = s->impl;
    if (im) {
        if (im->obj) CFRelease(im->obj);
        free(im->maps);
        free(im);
    }
    free(s);
}

xj_stage *xj_metal_stage_new(const xj_model *m, int l0, int l1, int n_ctx, int max_batch, bool has_head,
                             char *err, size_t errlen) {
    const xj_hparams *hp = &m->hp;
    if (l0 < 0 || l1 > hp->n_layer || l0 > l1) { snprintf(err, errlen, "层范围 [%d,%d) 不对", l0, l1); return NULL; }
    for (int il = l0; il < l1; il++)
        if (!m->layers[il].ffn_down.data) { snprintf(err, errlen, "第 %d 层权重没有映射进来", il); return NULL; }
    if (has_head && !m->output.data) { snprintf(err, errlen, "输出头没有映射进来"); return NULL; }
    if (hp->s_k > 512 || hp->conv_k > 8 || hp->head_dim % 4) { snprintf(err, errlen, "模型维度超出内核支持范围"); return NULL; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { snprintf(err, errlen, "这台设备没有 Metal"); return NULL; }
    g_device_name = dev.name;

    XJMetal *o = [XJMetal new];
    o.dev = dev;
    o.queue = [dev newCommandQueue];
    id<MTLLibrary> lib = load_library(dev, err, errlen);
    if (!lib) return NULL;
    o.pso = [NSMutableDictionary dictionary];
    const char *names[] = { "mv_f32", "mv_f16", "mv_bf16", "mv_q8_0", "mv_q4_K", "mv_q5_K", "mv_q6_K",
                            "mv1_f32", "mv1_f16", "mv1_bf16", "mv1_q8_0", "mv1_q4_K", "mv1_q5_K", "mv1_q6_K",
                            "mvb_q4_K", "mvb_q5_K", "mvb_q6_K", "xj_norm", "xj_rope",
                            "xj_kv_store", "xj_attn_scores", "xj_softmax", "xj_attn_out", "xj_conv_silu", "xj_delta_net", "xj_swiglu" };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        id<MTLFunction> f = [lib newFunctionWithName:@(names[i])];
        NSError *e = nil;
        id<MTLComputePipelineState> p = f ? [dev newComputePipelineStateWithFunction:f error:&e] : nil;
        if (!p) { snprintf(err, errlen, "内核 %s 建不起来：%s", names[i], e.localizedDescription.UTF8String ?: "找不到"); return NULL; }
        // A10 上每个线程组最多 512 线程；寄存器用得多的内核上限会更低（7 Plus 上 mv_q6_K 只有 224）。
        // 按每个内核实际派发的线程数检查（和下面 enc_* 里 dispatch 的第三个参数一致）；delta_net 单独查
        NSUInteger need = !strncmp(names[i], "mv", 2) ? XJ_MV_ROWS * XJ_MV_LANES
                        : (!strcmp(names[i], "xj_norm") || !strcmp(names[i], "xj_softmax")) ? 256
                        : !strcmp(names[i], "xj_delta_net") ? 0 : 64;
        if (p.maxTotalThreadsPerThreadgroup < need) {
            snprintf(err, errlen, "内核 %s 在这台设备上每组只能 %lu 线程（要 %lu）", names[i],
                     (unsigned long)p.maxTotalThreadsPerThreadgroup, (unsigned long)need);
            return NULL;
        }
        o.pso[@(names[i])] = p;
    }
    if (o.pso[@"xj_delta_net"].maxTotalThreadsPerThreadgroup < (NSUInteger)hp->s_k) { snprintf(err, errlen, "delta_net 线程组太小"); return NULL; }
    // 新芯片：simd_sum 版矩阵乘。A10（7 Plus）不支持，建不起来就照旧用 mv1_*
    if (!getenv("XJ_MV_NOSIMD") && ([dev supportsFamily:MTLGPUFamilyApple7] || [dev supportsFamily:MTLGPUFamilyMac2])) {
        BOOL ok = YES;
        for (NSString *nm in @[ @"mvs_q4_K", @"mvs_q5_K", @"mvs_q6_K" ]) {
            id<MTLFunction> f = [lib newFunctionWithName:nm];
            id<MTLComputePipelineState> p = f ? [dev newComputePipelineStateWithFunction:f error:nil] : nil;
            if (!p || p.threadExecutionWidth != XJ_MV_LANES || p.maxTotalThreadsPerThreadgroup < XJ_MV_ROWS * XJ_MV_LANES) { ok = NO; break; }
            o.pso[nm] = p;
        }
        o.simd = ok;
        if (ok) g_device_name = [dev.name stringByAppendingString:@"（simd 内核）"];
    }

    xj_stage *s = calloc(1, sizeof(*s));
    metal_impl *im = calloc(1, sizeof(*im));
    s->m = m; s->l0 = l0; s->l1 = l1; s->n_ctx = n_ctx; s->max_batch = max_batch; s->has_head = has_head;
    s->backend = "metal";
    s->forward = metal_forward; s->logits = metal_logits; s->reset = metal_reset; s->destroy = metal_destroy;
    s->impl = im;
    im->obj = (__bridge_retained void *)o;

    if (!map_weights(s, im, o, err, errlen)) { metal_destroy(s); return NULL; }

    // 临时缓冲：和 CPU 版一样大
    size_t sf = hp->n_ff;
    size_t qkv = 2 * (size_t)hp->n_head * hp->head_dim + 2 * (size_t)hp->n_head_kv * hp->head_dim;
    if (qkv > sf) sf = qkv;
    if ((size_t)hp->conv_dim > sf) sf = hp->conv_dim;
    if ((size_t)hp->n_embd > sf) sf = hp->n_embd;
    sf *= max_batch;
    im->sf = sf;
    MTLResourceOptions sh = MTLResourceStorageModeShared;
    o.x = [dev newBufferWithLength:(size_t)hp->n_embd * max_batch * 4 options:sh];
    o.h = [dev newBufferWithLength:sf * 4 options:sh];
    o.A = [dev newBufferWithLength:sf * 4 options:sh];
    o.B = [dev newBufferWithLength:sf * 4 options:sh];
    o.C = [dev newBufferWithLength:sf * 4 options:sh];
    o.D = [dev newBufferWithLength:sf * 4 options:sh];
    o.G = [dev newBufferWithLength:sf * 4 options:sh];
    o.SC = [dev newBufferWithLength:(size_t)max_batch * hp->n_head * n_ctx * 4 options:sh];
    o.dummy = [dev newBufferWithLength:256 options:sh];
    if (has_head) o.logits = [dev newBufferWithLength:(size_t)m->output.ne1 * 4 options:sh];
    o.kc = [NSMutableArray array]; o.vc = [NSMutableArray array]; o.conv = [NSMutableArray array]; o.ssm = [NSMutableArray array];
    for (int il = l0; il < l1; il++) {
        if (m->layers[il].recurrent) {
            [o.conv addObject:[dev newBufferWithLength:(size_t)hp->conv_dim * (hp->conv_k - 1) * 4 options:sh]];
            [o.ssm addObject:[dev newBufferWithLength:(size_t)hp->h_v * hp->s_v * hp->s_k * 4 options:sh]];
            [o.kc addObject:o.dummy]; [o.vc addObject:o.dummy];
        } else {
            size_t kvb = (size_t)n_ctx * hp->n_head_kv * hp->head_dim * 2;
            id<MTLBuffer> kb = [dev newBufferWithLength:kvb options:MTLResourceStorageModePrivate];
            id<MTLBuffer> vb = [dev newBufferWithLength:kvb options:MTLResourceStorageModePrivate];
            if (!kb || !vb) { snprintf(err, errlen, "KV 缓存分配失败（上下文开小一点）"); metal_destroy(s); return NULL; }
            [o.kc addObject:kb]; [o.vc addObject:vb];
            [o.conv addObject:o.dummy]; [o.ssm addObject:o.dummy];
        }
    }
    if (!o.x || !o.h || !o.A || !o.G || !o.SC || (has_head && !o.logits)) { snprintf(err, errlen, "GPU 内存不够"); metal_destroy(s); return NULL; }
    metal_reset(s);
    o.lanes = XJ_MV_LANES;
    if (!o.simd && l1 > l0) {
        char note[200];
        tune_lanes(s, note, sizeof note);
        g_tune_note = @(note);
        g_device_name = [NSString stringWithFormat:@"%@（每行 %u 线程）", g_device_name ?: dev.name, o.lanes];
        fprintf(stderr, "Metal 调优：%s\n", note);
    }
    return s;
}
