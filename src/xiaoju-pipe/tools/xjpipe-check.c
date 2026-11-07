// Metal 内核对照：同一段层、同样的输入，Metal 版和 CPU 参考实现各算一遍，比较结果。
//   xjpipe-check 模型.gguf [--layers 0:8] [--mtp 带MTP的.gguf]
// 另外测：投机解码的存档 / 回退（Metal 和 CPU 各走一遍同样的「算 4 个、退回 2 个、再算 2 个」），
// 模型带 MTP（或 --mtp 指定）时对照 MTP 层。
// 先一次预填充 12 个 token（走多 token 和分块的矩阵乘），再一个一个算 3 个，最后比较输出头。
// 相对误差超过 2% 返回非 0（KV 缓存是半精度，正常在 1e-3 量级）。只在有 Metal 的机器上有意义。
#include "../core/xj_stage.h"
#include "../core/xj_tok.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef __APPLE__
static double rel_diff(const float *a, const float *b, size_t n) {
    double md = 0, ma = 0;
    for (size_t i = 0; i < n; i++) {
        double d = fabs((double)a[i] - b[i]);
        if (d > md || isnan(d)) md = isnan(d) ? INFINITY : d;
        if (fabs(a[i]) > ma) ma = fabs(a[i]);
    }
    return ma > 0 ? md / ma : md;
}

static int argmax(const float *x, int n) { int b = 0; for (int i = 1; i < n; i++) if (x[i] > x[b]) b = i; return b; }
#endif

int main(int argc, char **argv) {
#ifndef __APPLE__
    fprintf(stderr, "这个工具要在有 Metal 的 Mac 上跑\n");
    (void)argc; (void)argv;
    return 0;
#else
    if (argc < 2) { fprintf(stderr, "用法: xjpipe-check 模型.gguf [--layers 0:8]\n"); return 1; }
    int l0 = 0, l1 = 8;
    const char *mtp_path = NULL;
    for (int i = 2; i + 1 < argc; i++) {
        if (!strcmp(argv[i], "--layers")) sscanf(argv[++i], "%d:%d", &l0, &l1);
        else if (!strcmp(argv[i], "--mtp")) mtp_path = argv[++i];
    }
    char err[256];
    xj_model *m = xj_model_load(argv[1], err, sizeof err);
    if (!m) { fprintf(stderr, "%s\n", err); return 1; }
    if (mtp_path && xj_model_attach_mtp(m, mtp_path, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    if (l1 > m->hp.n_layer) l1 = m->hp.n_layer;
    xj_tok *tok = xj_tok_new(m->gguf, err, sizeof err);
    const int E = m->hp.n_embd, B = 16, CTX = 128;
    xj_stage *c = xj_cpu_stage_new(m, l0, l1, CTX, B, true, err, sizeof err);
    xj_stage *g = c ? xj_metal_stage_new(m, l0, l1, CTX, B, true, err, sizeof err) : NULL;
    if (!c || !g) { fprintf(stderr, "%s\n", err); return 1; }
    fprintf(stderr, "设备：%s，对照第 %d–%d 层\n", xj_metal_device_name(), l0, l1 - 1);

    int32_t toks[64];
    int n = xj_tok_encode(tok, "<|im_start|>user\n小橘，今天天气怎么样？Tell me in one line.<|im_end|>\n", toks, 64);
    if (n < 15) { fprintf(stderr, "prompt 太短\n"); return 1; }
    float *xc = malloc(sizeof(float) * E * B), *xg = malloc(sizeof(float) * E * B);
    float *lc = malloc(sizeof(float) * m->hp.n_vocab), *lg = malloc(sizeof(float) * m->hp.n_vocab);
    int bad = 0, pos = 0;
    const int steps[] = { 12, 1, 1, 1 };
    for (int k = 0; k < 4; k++) {
        int T = steps[k];
        for (int t = 0; t < T; t++) xj_embed(m, toks[pos + t], xc + (size_t)t * E);
        memcpy(xg, xc, sizeof(float) * E * T);
        if (c->forward(c, xc, T, err, sizeof err) || g->forward(g, xg, T, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
        double r = rel_diff(xc, xg, (size_t)E * T);
        fprintf(stderr, "第 %d 步（%2d 个 token）：隐藏向量相对误差 %.2e %s\n", k, T, r, r < 2e-2 ? "OK" : "超了");
        if (!(r < 2e-2)) bad++;
        pos += T;
    }
    if (c->logits(c, xc, 1, lc, err, sizeof err) || g->logits(g, xg, 1, lg, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    double r = rel_diff(lc, lg, m->hp.n_vocab);
    int ac = argmax(lc, m->hp.n_vocab), ag = argmax(lg, m->hp.n_vocab);
    fprintf(stderr, "输出头：相对误差 %.2e，第一名 CPU %d / Metal %d %s\n", r, ac, ag, (r < 2e-2 && ac == ag) ? "OK" : "不一致");
    if (!(r < 2e-2) || ac != ag) bad++;

    // 投机解码：算 4 个（留存档）→ 退回到第 2 个之后 → 换 2 个别的字接着算，Metal 和 CPU 比
    {
        c->reset(c); g->reset(g);
        int T0 = 6;
        for (int t = 0; t < T0; t++) xj_embed(m, toks[t], xc + (size_t)t * E);
        memcpy(xg, xc, sizeof(float) * E * T0);
        int rc = c->forward(c, xc, T0, err, sizeof err) || g->forward(g, xg, T0, err, sizeof err);
        for (int t = 0; t < 4; t++) xj_embed(m, toks[T0 + t], xc + (size_t)t * E);
        memcpy(xg, xc, sizeof(float) * E * 4);
        c->keep = 4; g->keep = 4;
        rc = rc || c->forward(c, xc, 4, err, sizeof err) || g->forward(g, xg, 4, err, sizeof err);
        rc = rc || c->rollback(c, T0 + 2, err, sizeof err) || g->rollback(g, T0 + 2, err, sizeof err);
        for (int t = 0; t < 2; t++) xj_embed(m, toks[T0 + 6 + t], xc + (size_t)t * E);
        memcpy(xg, xc, sizeof(float) * E * 2);
        rc = rc || c->forward(c, xc, 2, err, sizeof err) || g->forward(g, xg, 2, err, sizeof err);
        if (rc) { fprintf(stderr, "回退：%s\n", err); return 1; }
        double r2 = rel_diff(xc, xg, (size_t)E * 2);
        fprintf(stderr, "投机解码回退（算 4 个退 2 个再算 2 个）：相对误差 %.2e %s\n", r2, r2 < 2e-2 ? "OK" : "超了");
        if (!(r2 < 2e-2)) bad++;
        // 再和不回退、直接算同样的 8 个字比（CPU）：回退后的状态要和从没算过那 2 个字一样
        xj_stage *ref = xj_cpu_stage_new(m, l0, l1, CTX, B, false, err, sizeof err);
        float *xr = malloc(sizeof(float) * E * B);
        int seq[10];
        for (int t = 0; t < T0 + 2; t++) seq[t] = toks[t];
        seq[T0 + 2] = toks[T0 + 6]; seq[T0 + 3] = toks[T0 + 7];
        for (int t = 0; t < T0 + 4; t++) xj_embed(m, seq[t], xr + (size_t)t * E);
        if (!ref || ref->forward(ref, xr, T0 + 4, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
        double r3 = rel_diff(xr + (size_t)(T0 + 2) * E, xg, (size_t)E * 2);
        fprintf(stderr, "回退后 vs 从没算过（Metal 对 CPU）：相对误差 %.2e %s\n", r3, r3 < 2e-2 ? "OK" : "超了");
        if (!(r3 < 2e-2)) bad++;
        ref->destroy(ref); free(xr);
    }

    // MTP 层
    if (m->has_mtp) {
        const int L = m->hp.n_layer;
        xj_stage *mc = xj_cpu_stage_new(m, L, L + 1, CTX, B, true, err, sizeof err);
        xj_stage *mg = mc ? xj_metal_stage_new(m, L, L + 1, CTX, B, true, err, sizeof err) : NULL;
        if (!mc || !mg) { fprintf(stderr, "MTP：%s\n", err); return 1; }
        float *ic = malloc(sizeof(float) * 2 * E * B), *ig = malloc(sizeof(float) * 2 * E * B);
        float *mlc = malloc(sizeof(float) * m->hp.n_vocab * 3), *mlg = malloc(sizeof(float) * m->hp.n_vocab * 3);
        for (int step = 0; step < 2; step++) {
            const int T = step ? 1 : 3;
            for (int t = 0; t < T; t++) {
                xj_embed(m, toks[step * 3 + t + 1], ic + (size_t)t * 2 * E);
                for (int i = 0; i < E; i++) ic[(size_t)t * 2 * E + E + i] = sinf(0.37f * i + t + step) * 3.0f;   // 当作主干输出
            }
            memcpy(ig, ic, sizeof(float) * 2 * E * T);
            if (mc->forward(mc, ic, T, err, sizeof err) || mg->forward(mg, ig, T, err, sizeof err) ||
                mc->logits(mc, ic, T, mlc, err, sizeof err) || mg->logits(mg, ig, T, mlg, err, sizeof err)) { fprintf(stderr, "MTP：%s\n", err); return 1; }
            double rh = rel_diff(ic, ig, (size_t)E * T), rl = rel_diff(mlc, mlg, (size_t)m->hp.n_vocab * T);
            int okm = 1;
            for (int t = 0; t < T; t++) okm &= argmax(mlc + (size_t)t * m->hp.n_vocab, m->hp.n_vocab) == argmax(mlg + (size_t)t * m->hp.n_vocab, m->hp.n_vocab);
            fprintf(stderr, "MTP 层（%d 个 token）：隐藏向量 %.2e，logits %.2e，第一名%s %s\n", T, rh, rl, okm ? "一致" : "不一致",
                    rh < 2e-2 && rl < 2e-2 && okm ? "OK" : "超了");
            if (!(rh < 2e-2 && rl < 2e-2 && okm)) bad++;
        }
        mc->destroy(mc); mg->destroy(mg);
        free(ic); free(ig); free(mlc); free(mlg);
    }

    // 速度：Metal 一次 1 个 token（生成阶段），这几层权重整个读一遍的等效带宽
    {
        double wbytes = 0;
        for (uint64_t i = 0; i < m->gguf->n_tensors; i++) {
            int il;
            if (sscanf(m->gguf->tensors[i].name, "blk.%d.", &il) == 1 && il >= l0 && il < l1) wbytes += (double)m->gguf->tensors[i].nbytes;
        }
        const int N = 32;
        struct timespec t0, t1;
        for (int k = 0; k < N + 2; k++) {
            if (k == 2) clock_gettime(CLOCK_MONOTONIC, &t0);   // 前两个不计（预热）
            xj_embed(m, toks[k % n], xg);
            if (g->forward(g, xg, 1, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double ms = ((t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6) / N;
        fprintf(stderr, "速度：%d 层（%.0f MB 权重）每个 token %.2f ms，等效 %.1f GB/s\n", l1 - l0, wbytes / 1048576, ms,
                wbytes / (ms / 1e3) / 1e9);
        // 投机解码验证一批 4 个字要多久（理想情况和 1 个字差不多：权重只读一遍）
        g->reset(g);
        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (int k = 0; k < N / 4; k++) {
            for (int t = 0; t < 4; t++) xj_embed(m, toks[(4 * k + t) % n], xg + (size_t)t * E);
            if (g->forward(g, xg, 4, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double ms4 = ((t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6) / (N / 4);
        fprintf(stderr, "一批 4 个 token：%.2f ms（是 1 个的 %.1f 倍）\n", ms4, ms4 / ms);
    }
    g->reset(g); c->reset(c);
    c->destroy(c); g->destroy(g);
    printf(bad ? "FAIL\n" : "PASS\n");
    return bad ? 1 : 0;
#endif
}
