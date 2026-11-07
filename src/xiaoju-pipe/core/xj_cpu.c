// 小橘双机推理：CPU 参考实现。算法逐步对应 llama.cpp 的 src/models/qwen35.cpp，
// Metal 版的每个内核都拿这里的结果对照（tests/）。有 OpenMP 时多线程。
#include "xj_stage.h"
#include "xj_quant.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    // 全注意力层：KV 缓存 [n_ctx][n_head_kv*head_dim]
    float *kc, *vc;
    // 线性注意力层：卷积状态 [conv_dim][conv_k-1]，递推状态 [h_v][s_v][s_k]（第 j 行是 value 的第 j 维）
    float *conv, *ssm;
    // 投机解码存档：第 t 个 token 算完后的状态（t < n_ck）
    float *ck_conv, *ck_ssm;
} cpu_lstate;

typedef struct {
    cpu_lstate *ls;   // 每层一个（下标 il - l0）
    // 临时缓冲（大小按 max_batch）
    float *h, *a, *b, *c, *d, *g, *u;
    float *rowbuf;    // 每个线程一行解码缓冲
    int nthreads;
    int n_ck;         // 每层有几个存档位
} cpu_impl;

// ---------- 基础算子 ----------

#ifdef _OPENMP
#include <omp.h>
#endif

// y[t][r] = dot(W[r], x[t])，W 是 ne1 行、每行 ne0 个元素
static void matmul(cpu_impl *im, const xj_w *w, const float *x, float *y, int T) {
    const int64_t K = w->ne0, N = w->ne1;
    const uint64_t rb = xj_row_bytes(w->type, K);
#pragma omp parallel for schedule(static)
    for (int64_t r = 0; r < N; r++) {
        int tid = 0;
#ifdef _OPENMP
        tid = omp_get_thread_num();
#endif
        float *buf = im->rowbuf + (size_t)tid * K;
        xj_dequant_row(w->type, (const uint8_t *)w->data + r * rb, buf, K);
        for (int t = 0; t < T; t++) {
            const float *xt = x + (size_t)t * K;
            float s = 0;
            for (int64_t k = 0; k < K; k++) s += buf[k] * xt[k];
            y[(size_t)t * N + r] = s;
        }
    }
}

static void rmsnorm(float *out, const float *x, const float *w, int n, float eps) {
    double ss = 0;
    for (int i = 0; i < n; i++) ss += (double)x[i] * x[i];
    float sc = 1.0f / sqrtf((float)(ss / n) + eps);
    for (int i = 0; i < n; i++) out[i] = x[i] * sc * (w ? w[i] : 1.0f);
}

static inline float silu(float x) { return x / (1.0f + expf(-x)); }
static inline float sigm(float x) { return 1.0f / (1.0f + expf(-x)); }
static inline float softplus(float x) { return x > 20.0f ? x : log1pf(expf(x)); }

// neox 旋转：只转前 n_rot 维，第 i 维和第 i + n_rot/2 维成对
static void rope(float *v, int n_rot, int pos, float base) {
    int half = n_rot / 2;
    for (int i = 0; i < half; i++) {
        float theta = pos * powf(base, -2.0f * i / n_rot);
        float c = cosf(theta), s = sinf(theta);
        float x0 = v[i], x1 = v[i + half];
        v[i] = x0 * c - x1 * s;
        v[i + half] = x0 * s + x1 * c;
    }
}

static const float *F(const xj_w *w) { return (const float *)w->data; }

// ---------- 全注意力层 ----------

static void attn_full(xj_stage *s, cpu_impl *im, int il, const float *h, float *out, int T) {
    const xj_hparams *hp = &s->m->hp;
    const xj_layer *L = &s->m->layers[il];
    cpu_lstate *st = &im->ls[il - s->l0];
    const int D = hp->head_dim, H = hp->n_head, Hkv = hp->n_head_kv;
    const int nq = 2 * H * D, nk = Hkv * D;
    float *qg = im->a, *k = im->b, *v = im->c, *att = im->d;

    if (L->wqkv.nbytes) {
        float *qkv = im->g;  // [T][nq + 2nk]
        matmul(im, &L->wqkv, h, qkv, T);
        for (int t = 0; t < T; t++) {
            const float *r = qkv + (size_t)t * (nq + 2 * nk);
            memcpy(qg + (size_t)t * nq, r, nq * 4);
            memcpy(k + (size_t)t * nk, r + nq, nk * 4);
            memcpy(v + (size_t)t * nk, r + nq + nk, nk * 4);
        }
    } else {
        matmul(im, &L->wq, h, qg, T);
        matmul(im, &L->wk, h, k, T);
        matmul(im, &L->wv, h, v, T);
    }

    const float scale = 1.0f / sqrtf((float)D);
    for (int t = 0; t < T; t++) {
        const int pos = s->n_past + t;
        float *kt = k + (size_t)t * nk, *vt = v + (size_t)t * nk;
        for (int hh = 0; hh < Hkv; hh++) {
            rmsnorm(kt + hh * D, kt + hh * D, F(&L->k_norm), D, hp->eps);
            rope(kt + hh * D, hp->n_rot, pos, hp->rope_base);
        }
        memcpy(st->kc + (size_t)pos * nk, kt, nk * 4);
        memcpy(st->vc + (size_t)pos * nk, vt, nk * 4);
    }

    // 每个 query 头：q 和门控交错存放 [q(D), gate(D)]
#pragma omp parallel for collapse(2) schedule(static)
    for (int t = 0; t < T; t++) {
        for (int hh = 0; hh < H; hh++) {
            const int pos = s->n_past + t, kvh = hh / (H / Hkv);
            float q[1024];
            float *qr = qg + (size_t)t * nq + hh * 2 * D;
            rmsnorm(q, qr, F(&L->q_norm), D, hp->eps);
            rope(q, hp->n_rot, pos, hp->rope_base);
            float *sc = malloc(sizeof(float) * (pos + 1));
            float mx = -INFINITY;
            for (int j = 0; j <= pos; j++) {
                const float *kj = st->kc + (size_t)j * nk + kvh * D;
                float d = 0;
                for (int i = 0; i < D; i++) d += q[i] * kj[i];
                sc[j] = d * scale;
                if (sc[j] > mx) mx = sc[j];
            }
            double sum = 0;
            for (int j = 0; j <= pos; j++) { sc[j] = expf(sc[j] - mx); sum += sc[j]; }
            float *o = att + (size_t)t * H * D + hh * D;
            for (int i = 0; i < D; i++) o[i] = 0;
            for (int j = 0; j <= pos; j++) {
                const float *vj = st->vc + (size_t)j * nk + kvh * D;
                float p = (float)(sc[j] / sum);
                for (int i = 0; i < D; i++) o[i] += p * vj[i];
            }
            free(sc);
            const float *gate = qr + D;
            for (int i = 0; i < D; i++) o[i] *= sigm(gate[i]);
        }
    }
    matmul(im, &L->wo, att, out, T);
}

// ---------- 线性注意力层（Gated DeltaNet） ----------

static void attn_linear(xj_stage *s, cpu_impl *im, int il, const float *h, float *out, int T) {
    const xj_hparams *hp = &s->m->hp;
    const xj_layer *L = &s->m->layers[il];
    cpu_lstate *st = &im->ls[il - s->l0];
    const int CD = hp->conv_dim, KC = hp->conv_k, Hv = hp->h_v, Hk = hp->h_k, S = hp->s_k;
    float *qkv = im->a, *z = im->b, *beta = im->c, *alpha = im->d, *o = im->g;

    matmul(im, &L->ssm_qkv, h, qkv, T);
    matmul(im, &L->ssm_gate, h, z, T);
    matmul(im, &L->ssm_beta, h, beta, T);
    matmul(im, &L->ssm_alpha, h, alpha, T);

    const float *cw = F(&L->ssm_conv1d), *dt = F(&L->ssm_dt), *A = F(&L->ssm_a), *nw = F(&L->ssm_norm);
    const float qscale = 1.0f / sqrtf((float)S);

    for (int t = 0; t < T; t++) {
        float *x = qkv + (size_t)t * CD;
        // 因果卷积：窗口 = 上次留下的 KC-1 个输入 + 这次的输入，算完窗口左移一格
        for (int c = 0; c < CD; c++) {
            float *cs = st->conv + (size_t)c * (KC - 1);
            const float *wc = cw + (size_t)c * KC;
            float acc = 0;
            for (int k = 0; k < KC - 1; k++) acc += cs[k] * wc[k];
            acc += x[c] * wc[KC - 1];
            for (int k = 0; k < KC - 2; k++) cs[k] = cs[k + 1];
            cs[KC - 2] = x[c];
            x[c] = silu(acc);
        }
        float *q = x, *k = x + hp->key_dim, *v = x + 2 * hp->key_dim;
        // q、k 每个头做 L2 归一化：x / sqrt(sum(x^2) + eps)
        for (int hh = 0; hh < Hk; hh++) {
            for (int which = 0; which < 2; which++) {
                float *p = (which ? k : q) + hh * S;
                double ss = 0;
                for (int i = 0; i < S; i++) ss += (double)p[i] * p[i];
                float sc = 1.0f / sqrtf((float)ss + hp->eps);
                for (int i = 0; i < S; i++) p[i] *= sc;
            }
        }
        float *ot = o + (size_t)t * hp->d_inner;
        const bool ck = s->keep && t < T - 1;
#pragma omp parallel for schedule(static)
        for (int hv = 0; hv < Hv; hv++) {
            const int hk = hv % Hk;  // 和 ggml_repeat 一样：value 头按 key 头数取模
            const float *qh = q + hk * S, *kh = k + hk * S, *vh = v + hv * S;
            const float b = sigm(beta[(size_t)t * Hv + hv]);
            const float g = softplus(alpha[(size_t)t * Hv + hv] + dt[hv]) * A[hv];
            const float eg = expf(g);
            float *M = st->ssm + (size_t)hv * S * S;
            float *oh = ot + hv * S;
            for (int j = 0; j < S; j++) {
                float *row = M + (size_t)j * S;
                float sk = 0;
                for (int i = 0; i < S; i++) { row[i] *= eg; sk += row[i] * kh[i]; }
                const float delta = (vh[j] - sk) * b;
                float acc = 0;
                for (int i = 0; i < S; i++) { row[i] += kh[i] * delta; acc += row[i] * qh[i]; }
                oh[j] = acc * qscale;
            }
            // 门控 RMSNorm：norm(o) * w * silu(z)
            const float *zh = z + (size_t)t * hp->d_inner + hv * S;
            rmsnorm(oh, oh, nw, S, hp->eps);
            for (int j = 0; j < S; j++) oh[j] *= silu(zh[j]);
            if (ck) memcpy(st->ck_ssm + ((size_t)t * Hv + hv) * S * S, M, sizeof(float) * S * S);
        }
        if (ck) memcpy(st->ck_conv + (size_t)t * CD * (KC - 1), st->conv, sizeof(float) * CD * (KC - 1));
    }
    matmul(im, &L->ssm_out, o, out, T);
}

// ---------- 整段 ----------

// 存档位不够就加（每层 T-1 个：最后一个 token 之后的状态就是当前状态）
static int ensure_ck(xj_stage *s, int n, char *err, size_t errlen) {
    cpu_impl *im = s->impl;
    const xj_hparams *hp = &s->m->hp;
    if (n <= im->n_ck) return 0;
    for (int il = s->l0; il < s->l1; il++) {
        cpu_lstate *st = &im->ls[il - s->l0];
        if (!st->ssm) continue;
        free(st->ck_conv); free(st->ck_ssm);
        st->ck_conv = malloc(sizeof(float) * n * hp->conv_dim * (hp->conv_k - 1));
        st->ck_ssm = malloc(sizeof(float) * n * hp->h_v * hp->s_v * hp->s_k);
        if (!st->ck_conv || !st->ck_ssm) { snprintf(err, errlen, "投机解码存档内存不够"); im->n_ck = 0; return -1; }
    }
    im->n_ck = n;
    return 0;
}

static int cpu_forward(xj_stage *s, float *x, int T, char *err, size_t errlen) {
    cpu_impl *im = s->impl;
    const xj_hparams *hp = &s->m->hp;
    const int E = hp->n_embd;
    if (T <= 0 || T > s->max_batch) { snprintf(err, errlen, "一次 %d 个 token，超过上限 %d", T, s->max_batch); s->keep = 0; return -1; }
    if (s->n_past + T > s->n_ctx) { snprintf(err, errlen, "上下文满了（%d）", s->n_ctx); s->keep = 0; return -1; }
    if (s->keep && ensure_ck(s, T - 1, err, errlen)) { s->keep = 0; return -1; }
    s->ck_start = s->n_past;
    s->ck_T = s->keep ? T : 0;
    if (s->mtp) {
        // [embedding ‖ 隐藏向量] 各自 RMSNorm，拼起来过 eh_proj 变回 n_embd
        const xj_model *m = s->m;
        for (int t = 0; t < T; t++) {
            rmsnorm(im->h + (size_t)t * 2 * E, x + (size_t)t * 2 * E, F(&m->mtp_enorm), E, hp->eps);
            rmsnorm(im->h + (size_t)t * 2 * E + E, x + (size_t)t * 2 * E + E, F(&m->mtp_hnorm), E, hp->eps);
        }
        matmul(im, &m->mtp_eh, im->h, x, T);
    }

    for (int il = s->l0; il < s->l1; il++) {
        const xj_layer *L = &s->m->layers[il];
        for (int t = 0; t < T; t++) rmsnorm(im->h + (size_t)t * E, x + (size_t)t * E, F(&L->attn_norm), E, hp->eps);
        if (L->recurrent) attn_linear(s, im, il, im->h, im->u, T);
        else attn_full(s, im, il, im->h, im->u, T);
        for (size_t i = 0; i < (size_t)T * E; i++) x[i] += im->u[i];

        for (int t = 0; t < T; t++) rmsnorm(im->h + (size_t)t * E, x + (size_t)t * E, F(&L->post_norm), E, hp->eps);
        matmul(im, &L->ffn_gate, im->h, im->g, T);
        matmul(im, &L->ffn_up, im->h, im->a, T);
        for (size_t i = 0; i < (size_t)T * hp->n_ff; i++) im->g[i] = silu(im->g[i]) * im->a[i];
        matmul(im, &L->ffn_down, im->g, im->u, T);
        for (size_t i = 0; i < (size_t)T * E; i++) x[i] += im->u[i];
    }
    s->n_past += T;
    s->keep = 0;
    return 0;
}

static int cpu_logits(xj_stage *s, const float *x, int T, float *logits, char *err, size_t errlen) {
    cpu_impl *im = s->impl;
    const int E = s->m->hp.n_embd;
    if (!s->has_head) { snprintf(err, errlen, "这一段没有输出头"); return -1; }
    if (T < 1 || T > s->max_batch) { snprintf(err, errlen, "输出头一次 %d 个 token 超过上限", T); return -1; }
    const xj_w *nw = s->mtp ? &s->m->mtp_head_norm : &s->m->output_norm;
    for (int t = 0; t < T; t++) rmsnorm(im->h + (size_t)t * E, x + (size_t)t * E, F(nw), E, s->m->hp.eps);
    xj_w out = s->m->output;
    if (s->head_rows > 0 && s->head_rows < out.ne1) out.ne1 = s->head_rows;
    matmul(im, &out, im->h, logits, T);
    return 0;
}

static int cpu_rollback(xj_stage *s, int n_past, char *err, size_t errlen) {
    cpu_impl *im = s->impl;
    const xj_hparams *hp = &s->m->hp;
    if (n_past == s->n_past) { s->ck_T = 0; return 0; }
    bool recurrent = false;
    for (int il = s->l0; il < s->l1; il++) if (im->ls[il - s->l0].ssm) recurrent = true;
    if (!recurrent) {
        if (n_past < 0 || n_past > s->n_past) { snprintf(err, errlen, "退不到位置 %d", n_past); return -1; }
        s->n_past = n_past;
        return 0;
    }
    const int j = n_past - s->ck_start - 1;
    if (!s->ck_T || s->n_past != s->ck_start + s->ck_T || j < 0 || j >= s->ck_T - 1) {
        snprintf(err, errlen, "退不到位置 %d（存档 %d+%d，当前 %d）", n_past, s->ck_start, s->ck_T, s->n_past);
        return -1;
    }
    const size_t nc = (size_t)hp->conv_dim * (hp->conv_k - 1), ns = (size_t)hp->h_v * hp->s_v * hp->s_k;
    for (int il = s->l0; il < s->l1; il++) {
        cpu_lstate *st = &im->ls[il - s->l0];
        if (!st->ssm) continue;
        memcpy(st->conv, st->ck_conv + (size_t)j * nc, nc * 4);
        memcpy(st->ssm, st->ck_ssm + (size_t)j * ns, ns * 4);
    }
    s->n_past = n_past;
    s->ck_T = 0;
    return 0;
}

static void cpu_reset(xj_stage *s) {
    cpu_impl *im = s->impl;
    const xj_hparams *hp = &s->m->hp;
    for (int il = s->l0; il < s->l1; il++) {
        cpu_lstate *st = &im->ls[il - s->l0];
        if (st->conv) memset(st->conv, 0, sizeof(float) * hp->conv_dim * (hp->conv_k - 1));
        if (st->ssm) memset(st->ssm, 0, sizeof(float) * hp->h_v * hp->s_v * hp->s_k);
    }
    s->n_past = 0;
}

static void cpu_destroy(xj_stage *s) {
    if (!s) return;
    cpu_impl *im = s->impl;
    if (im) {
        if (im->ls) for (int i = 0; i < s->l1 - s->l0; i++) {
            free(im->ls[i].kc); free(im->ls[i].vc); free(im->ls[i].conv); free(im->ls[i].ssm);
            free(im->ls[i].ck_conv); free(im->ls[i].ck_ssm);
        }
        free(im->ls); free(im->h); free(im->a); free(im->b); free(im->c); free(im->d); free(im->g); free(im->u);
        free(im->rowbuf);
        free(im);
    }
    free(s);
}

static size_t scratch_floats(const xj_hparams *hp) {
    size_t n = hp->n_ff;
    size_t qkv = 2 * (size_t)hp->n_head * hp->head_dim + 2 * (size_t)hp->n_head_kv * hp->head_dim;
    if (qkv > n) n = qkv;
    if ((size_t)hp->conv_dim > n) n = hp->conv_dim;
    if ((size_t)hp->n_embd * 2 > n) n = 2 * (size_t)hp->n_embd;   // MTP 的 [embedding ‖ 隐藏向量]
    return n;
}

uint64_t xj_stage_state_bytes(const xj_model *m, int l0, int l1, int n_ctx, int max_batch) {
    const xj_hparams *hp = &m->hp;
    uint64_t b = 0;
    for (int il = l0; il < l1; il++) {
        if (m->layers[il].recurrent)
            b += 4ull * ((uint64_t)hp->conv_dim * (hp->conv_k - 1) + (uint64_t)hp->h_v * hp->s_v * hp->s_k);
        else
            b += 2ull * 4 * n_ctx * hp->n_head_kv * hp->head_dim;
    }
    b += 7ull * 4 * max_batch * scratch_floats(hp);
    return b;
}

void xj_embed(const xj_model *m, int32_t token, float *out) {
    const xj_w *w = &m->tok_embd;
    if (token < 0 || token >= w->ne1) { memset(out, 0, sizeof(float) * w->ne0); return; }
    xj_dequant_row(w->type, (const uint8_t *)w->data + (uint64_t)token * xj_row_bytes(w->type, w->ne0), out, w->ne0);
}

xj_stage *xj_cpu_stage_new(const xj_model *m, int l0, int l1, int n_ctx, int max_batch, bool has_head,
                           char *err, size_t errlen) {
    const xj_hparams *hp = &m->hp;
    const bool mtp = m->has_mtp && l0 == hp->n_layer && l1 == hp->n_layer + 1;
    if (l0 < 0 || (l1 > hp->n_layer && !mtp) || l0 > l1) { snprintf(err, errlen, "层范围 [%d,%d) 不对", l0, l1); return NULL; }
    if (hp->head_dim > 1024) { snprintf(err, errlen, "头维度太大"); return NULL; }
    for (int il = l0; il < l1; il++)
        if (!m->layers[il].ffn_down.data) { snprintf(err, errlen, "第 %d 层权重没有映射进来", il); return NULL; }
    if (has_head && !m->output.data) { snprintf(err, errlen, "输出头没有映射进来"); return NULL; }
    xj_stage *s = calloc(1, sizeof(*s));
    cpu_impl *im = calloc(1, sizeof(*im));
    s->m = m; s->l0 = l0; s->l1 = l1; s->n_ctx = n_ctx; s->max_batch = max_batch; s->has_head = has_head; s->mtp = mtp;
    s->backend = "cpu";
    s->forward = cpu_forward; s->logits = cpu_logits; s->reset = cpu_reset; s->destroy = cpu_destroy;
    s->rollback = cpu_rollback;
    s->impl = im;

    im->nthreads = 1;
#ifdef _OPENMP
    im->nthreads = omp_get_max_threads();
#endif
    size_t sf = scratch_floats(hp) * (size_t)max_batch;
    im->h = malloc(sf * 4); im->a = malloc(sf * 4); im->b = malloc(sf * 4); im->c = malloc(sf * 4);
    im->d = malloc(sf * 4); im->g = malloc(sf * 4); im->u = malloc(sf * 4);
    int64_t maxk = 2 * (int64_t)hp->n_embd;
    if (hp->n_ff > maxk) maxk = hp->n_ff;
    if (hp->d_inner > maxk) maxk = hp->d_inner;
    if ((int64_t)hp->n_head * hp->head_dim > maxk) maxk = (int64_t)hp->n_head * hp->head_dim;
    im->rowbuf = malloc(sizeof(float) * maxk * im->nthreads);
    im->ls = calloc(l1 - l0 ? l1 - l0 : 1, sizeof(cpu_lstate));
    for (int il = l0; il < l1; il++) {
        cpu_lstate *st = &im->ls[il - l0];
        if (m->layers[il].recurrent) {
            st->conv = calloc((size_t)hp->conv_dim * (hp->conv_k - 1), 4);
            st->ssm = calloc((size_t)hp->h_v * hp->s_v * hp->s_k, 4);
        } else {
            st->kc = malloc((size_t)n_ctx * hp->n_head_kv * hp->head_dim * 4);
            st->vc = malloc((size_t)n_ctx * hp->n_head_kv * hp->head_dim * 4);
            if (!st->kc || !st->vc) { snprintf(err, errlen, "KV 缓存分配失败"); cpu_destroy(s); return NULL; }
        }
    }
    if (!im->h || !im->rowbuf) { snprintf(err, errlen, "内存不够"); cpu_destroy(s); return NULL; }
    return s;
}
