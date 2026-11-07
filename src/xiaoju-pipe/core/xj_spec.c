// 小橘双机推理：投机解码（见 xj_spec.h）。
#include "xj_spec.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>

static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec * 1e-6; }

static int argmax(const float *x, int n) {
    int b = 0;
    for (int i = 1; i < n; i++) if (x[i] > x[b]) b = i;
    return b;
}

// x ← RMSNorm(x) * w（w 是 F32 norm 权重）
static void norm_inplace(float *x, const xj_w *w, int n, float eps) {
    double ss = 0;
    for (int i = 0; i < n; i++) ss += (double)x[i] * x[i];
    const float sc = 1.0f / sqrtf((float)(ss / n) + eps);
    const float *wf = w->data;
    for (int i = 0; i < n; i++) x[i] *= sc * wf[i];
}

static bool env_flag(const char *k, bool def) { const char *v = getenv(k); return v ? atoi(v) != 0 : def; }

static bool is_end(const xj_model *m, int id) { return (uint32_t)id == m->hp.eot || (uint32_t)id == m->hp.eos; }

static int grow_hid(xj_spec *sp, int n) {
    if (n <= sp->hid_cap) return 0;
    float *h = realloc(sp->hid, sizeof(float) * (size_t)n * sp->m->hp.n_embd);
    if (!h) return -1;
    sp->hid = h; sp->hid_cap = n;
    return 0;
}

static int grow_ph(xj_spec *sp, int n) {
    if (n <= sp->ph_cap) return 0;
    int cap = n * 2;
    float *h = realloc(sp->ph, sizeof(float) * (size_t)cap * sp->m->hp.n_embd);
    if (!h) return -1;
    sp->ph = h;
    int32_t *t = realloc(sp->pt, sizeof(int32_t) * cap);
    if (!t) return -1;
    sp->pt = t; sp->ph_cap = cap;
    return 0;
}

// 记下主干位置的隐藏向量（后面那个字 next 可以先不知道）
static int push_ph(xj_spec *sp, const float *h, int n, const int32_t *next) {
    const int E = sp->m->hp.n_embd;
    if (grow_ph(sp, sp->n_ph + n)) return -1;
    memcpy(sp->ph + (size_t)sp->n_ph * E, h, sizeof(float) * n * E);
    if (sp->main_post)
        for (int i = 0; i < n; i++) norm_inplace(sp->ph + (size_t)(sp->n_ph + i) * E, &sp->m->output_norm, E, sp->m->hp.eps);
    for (int i = 0; i < n; i++) sp->pt[sp->n_ph + i] = next ? next[i] : -1;
    sp->n_ph += n;
    return 0;
}

int xj_spec_init(xj_spec *sp, xj_pipeline *p, xj_stage *mtp, int k) {
    memset(sp, 0, sizeof(*sp));
    sp->p = p; sp->m = p->m; sp->mtp = mtp;
    if (k > XJ_SPEC_MAXK) k = XJ_SPEC_MAXK;
    if (k > p->max_batch - 1) k = p->max_batch - 1;
    if (mtp && k > mtp->max_batch) k = mtp->max_batch;
    sp->k = mtp && k > 0 ? k : 0;
    const int V = sp->m->hp.n_vocab, E = sp->m->hp.n_embd;
    sp->last_logits = malloc(sizeof(float) * V);
    sp->logits = malloc(sizeof(float) * V * (sp->k + 1));
    sp->mlog = malloc(sizeof(float) * V);
    const int mb = mtp && mtp->max_batch > p->max_batch ? mtp->max_batch : p->max_batch;
    sp->mx = malloc(sizeof(float) * 2 * E * mb);
    sp->forced = -1;
    sp->main_post = env_flag("XJ_MTP_MAIN_POST", true);    // 和 vLLM 的 Qwen3-Next MTP 一样都过 norm，CI 上 0.8B 实测这样最准
    sp->chain_post = env_flag("XJ_MTP_CHAIN_POST", true);
    // 猜字只看前多少个词（XJ_MTP_VOCAB，0 = 全部）
    if (mtp) {
        const char *v = getenv("XJ_MTP_VOCAB");
        mtp->head_rows = v ? atoi(v) : XJ_SPEC_DRAFT_VOCAB;
    }
    if (grow_hid(sp, p->max_batch)) return -1;
    return sp->last_logits && sp->logits && sp->mlog && sp->mx ? 0 : -1;
}

void xj_spec_free(xj_spec *sp) {
    free(sp->last_logits); free(sp->logits); free(sp->mlog); free(sp->mx);
    free(sp->hid); free(sp->ph); free(sp->pt);
    memset(sp, 0, sizeof(*sp));
}

void xj_spec_reset(xj_spec *sp) {
    sp->n_ph = 0;
    sp->forced = -1;
    if (sp->mtp) sp->mtp->reset(sp->mtp);
}

// MTP 吃掉前 n 个待处理位置（它们后面的字都已知）。want：最后一个位置要不要出 logits（猜下一个字）。
// 最后一个位置的 MTP 输出（未过 norm）留在 sp->mx 的第 0 行，接着猜用。
static int mtp_flush(xj_spec *sp, int n, bool want, char *err, size_t errlen) {
    const int E = sp->m->hp.n_embd, B = sp->mtp->max_batch;
    for (int i = 0; i < n; i += B) {
        const int T = n - i < B ? n - i : B;
        for (int t = 0; t < T; t++) {
            xj_embed(sp->m, sp->pt[i + t], sp->mx + (size_t)t * 2 * E);
            memcpy(sp->mx + (size_t)t * 2 * E + E, sp->ph + (size_t)(i + t) * E, sizeof(float) * E);
        }
        if (sp->mtp->forward(sp->mtp, sp->mx, T, err, errlen)) return -1;
        if (i + T == n) {
            if (want && sp->mtp->logits(sp->mtp, sp->mx + (size_t)(T - 1) * E, 1, sp->mlog, err, errlen)) return -1;
            memmove(sp->mx, sp->mx + (size_t)(T - 1) * E, sizeof(float) * E);
        }
    }
    memmove(sp->ph, sp->ph + (size_t)n * E, sizeof(float) * (size_t)(sp->n_ph - n) * E);
    memmove(sp->pt, sp->pt + n, sizeof(int32_t) * (sp->n_ph - n));
    sp->n_ph -= n;
    return 0;
}

int xj_spec_feed(xj_spec *sp, const int32_t *tok, int n, char *err, size_t errlen) {
    if (n <= 0) return 0;
    const bool mtp = sp->mtp != NULL;
    if (mtp && grow_hid(sp, n)) { snprintf(err, errlen, "内存不够"); return -1; }
    if (xj_pipeline_eval(sp->p, tok, n, sp->last_logits, mtp ? sp->hid : NULL, err, errlen)) return -1;
    sp->forced = -1;
    if (!mtp) return 0;
    if (sp->n_ph && sp->pt[sp->n_ph - 1] < 0) sp->pt[sp->n_ph - 1] = tok[0];
    if (push_ph(sp, sp->hid, n, NULL)) { snprintf(err, errlen, "内存不够"); return -1; }
    for (int i = 0; i < n - 1; i++) sp->pt[sp->n_ph - n + i] = tok[i + 1];
    // 后面的字已知的位置先让 MTP 过掉（提示词很长时不攒着）
    return sp->n_ph > 1 ? mtp_flush(sp, sp->n_ph - 1, false, err, errlen) : 0;
}

int xj_spec_next(xj_spec *sp, xj_sample_fn sample, void *sctx, int32_t *out, int room, char *err, size_t errlen) {
    const xj_model *m = sp->m;
    const int V = m->hp.n_vocab, E = m->hp.n_embd;
    xj_pipeline *p = sp->p;
    const int t = sp->forced >= 0 ? sp->forced : sample(sctx, sp->last_logits, V);
    sp->forced = -1;
    out[0] = t;
    if (is_end(m, t)) return 1;   // 结束符不喂（调用方收尾）
    sp->n_gen++;

    int k = sp->k;
    if (k > room - 1) k = room - 1;
    if (k > p->a->n_ctx - p->a->n_past - 1) k = p->a->n_ctx - p->a->n_past - 1;
    if (k <= 0 || !sp->mtp || !sp->n_ph) {
        // 不投机：喂这一个字
        if (xj_pipeline_eval(p, &out[0], 1, sp->last_logits, sp->mtp ? sp->hid : NULL, err, errlen)) return -1;
        if (sp->mtp) {
            if (sp->n_ph) sp->pt[sp->n_ph - 1] = t;
            if (push_ph(sp, sp->hid, 1, NULL)) { snprintf(err, errlen, "内存不够"); return -1; }
        }
        return 1;
    }

    // 1) MTP 猜 k 个字：先把待处理的位置（最后一个后面就是 t）喂掉，猜出第 1 个；再拿它自己的输出接着猜
    double t0 = now_ms();
    int32_t toks[XJ_SPEC_MAXK + 1];
    toks[0] = t;
    if (sp->n_ph) sp->pt[sp->n_ph - 1] = t;
    const int mtp_pos = sp->mtp->n_past + sp->n_ph;   // MTP 真实位置到这里为止，后面的是猜的
    if (mtp_flush(sp, sp->n_ph, true, err, errlen)) return -1;
    for (int j = 1; j <= k; j++) {
        toks[j] = argmax(sp->mlog, sp->mtp->head_rows > 0 && sp->mtp->head_rows < V ? sp->mtp->head_rows : V);
        if (j == k) break;
        // sp->mx 第 0 行是上一次 MTP 的输出：拼成 [embedding(猜的字) ‖ 输出]
        memmove(sp->mx + E, sp->mx, sizeof(float) * E);
        if (sp->chain_post) norm_inplace(sp->mx + E, &m->mtp_head_norm, E, m->hp.eps);
        xj_embed(m, toks[j], sp->mx);
        if (sp->mtp->forward(sp->mtp, sp->mx, 1, err, errlen)) return -1;
        if (sp->mtp->logits(sp->mtp, sp->mx, 1, sp->mlog, err, errlen)) return -1;
    }
    if (sp->mtp->rollback(sp->mtp, mtp_pos, err, errlen)) return -1;
    sp->t_draft_ms += now_ms() - t0;
    for (int j = 1; j <= k && sp->oracle; j++) {
        const long g = sp->n_gen - 1 + j;   // t 是第 n_gen-1 个字
        if (g < sp->n_oracle) toks[j] = sp->oracle[g];
        if (sp->oracle_miss && (g * 7 + j) % sp->oracle_miss == 0) toks[j] = (toks[j] + 1) % V;
    }

    // 2) 一批验证：[t, 猜1..猜k]，每个位置的 logits 都要
    const int P = p->a->n_past;
    if (xj_pipeline_verify(p, toks, k + 1, sp->logits, sp->hid, err, errlen)) return -1;

    // 3) 从头比：主干在位置 i 采样出的字等于猜的第 i+1 个就接受
    int a = 0, s = -1;
    for (int i = 0; i < k; i++) {
        s = sample(sctx, sp->logits + (size_t)i * V, V);
        if (s != toks[i + 1]) break;
        sp->acc_at[i]++;
        a++;
        s = -1;
    }
    int n_out = 1 + a;
    for (int i = 1; i < n_out; i++) out[i] = toks[i];
    // 接受的字里有结束符：它和后面的都不算喂进去
    int fed = n_out;
    for (int i = 1; i < n_out; i++) if (is_end(m, out[i])) { n_out = i + 1; fed = i; s = -1; break; }

    sp->n_gen += fed - 1;
    sp->n_steps++; sp->n_drafted += k; sp->n_accepted += fed - 1 < a ? fed - 1 : a;
    if (fed < k + 1 && xj_pipeline_rollback(p, P + fed, err, errlen)) return -1;
    if (fed == k + 1) memcpy(sp->last_logits, sp->logits + (size_t)k * V, sizeof(float) * V);
    else if (s >= 0) { memcpy(sp->last_logits, sp->logits + (size_t)a * V, sizeof(float) * V); sp->forced = s; }

    // 4) 喂进去的位置记给 MTP（下一步一起过）
    if (push_ph(sp, sp->hid, fed, NULL)) { snprintf(err, errlen, "内存不够"); return -1; }
    for (int i = 0; i < fed - 1; i++) sp->pt[sp->n_ph - fed + i] = toks[i + 1];
    sp->pt[sp->n_ph - 1] = sp->forced;   // 下一个字（-1 = 下一步采样后再填）
    return n_out;
}
