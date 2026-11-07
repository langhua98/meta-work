// Metal 内核对照：同一段层、同样的输入，Metal 版和 CPU 参考实现各算一遍，比较结果。
//   xjpipe-check 模型.gguf [--layers 0:8]
// 先一次预填充 12 个 token（走多 token 和分块的矩阵乘），再一个一个算 3 个，最后比较输出头。
// 相对误差超过 2% 返回非 0（KV 缓存是半精度，正常在 1e-3 量级）。只在有 Metal 的机器上有意义。
#include "../core/xj_stage.h"
#include "../core/xj_tok.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
    for (int i = 2; i + 1 < argc; i++) if (!strcmp(argv[i], "--layers")) sscanf(argv[++i], "%d:%d", &l0, &l1);
    char err[256];
    xj_model *m = xj_model_load(argv[1], err, sizeof err);
    if (!m) { fprintf(stderr, "%s\n", err); return 1; }
    if (l1 > m->hp.n_layer) l1 = m->hp.n_layer;
    xj_tok *tok = xj_tok_new(m->gguf, err, sizeof err);
    const int E = m->hp.n_embd, B = 16, CTX = 64;
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
    if (c->logits(c, xc, lc, err, sizeof err) || g->logits(g, xg, lg, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    double r = rel_diff(lc, lg, m->hp.n_vocab);
    int ac = argmax(lc, m->hp.n_vocab), ag = argmax(lg, m->hp.n_vocab);
    fprintf(stderr, "输出头：相对误差 %.2e，第一名 CPU %d / Metal %d %s\n", r, ac, ag, (r < 2e-2 && ac == ag) ? "OK" : "不一致");
    if (!(r < 2e-2) || ac != ag) bad++;
    g->reset(g); c->reset(c);
    c->destroy(c); g->destroy(g);
    printf(bad ? "FAIL\n" : "PASS\n");
    return bad ? 1 : 0;
#endif
}
