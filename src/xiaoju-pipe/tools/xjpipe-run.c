// 单进程测试：整个模型在本机按 CPU 参考实现跑，或者在同一进程里拆成两段（--split N），
// 看生成的文字通不通顺、两种算法结果是否一致。
//   xjpipe-run 模型.gguf "问题" [--split 16] [--n 40] [--batch 8]
#include "../core/xj_stage.h"
#include "../core/xj_tok.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

static int argmax(const float *x, int n) { int b = 0; for (int i = 1; i < n; i++) if (x[i] > x[b]) b = i; return b; }

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "用法: xjpipe-run 模型.gguf \"问题\" [--split N] [--n 40] [--batch 8]\n"); return 1; }
    int split = -1, n_gen = 40, batch = 8;
    for (int i = 3; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "--split")) split = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--n")) n_gen = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--batch")) batch = atoi(argv[i + 1]);
    }
    char err[256];
    xj_model *m = xj_model_load(argv[1], err, sizeof err);
    if (!m) { fprintf(stderr, "%s\n", err); return 1; }
    const xj_hparams *hp = &m->hp;
    xj_tok *tok = xj_tok_new(m->gguf, err, sizeof err);
    if (!tok) { fprintf(stderr, "%s\n", err); return 1; }

    char prompt[8192];
    snprintf(prompt, sizeof prompt, "<|im_start|>user\n%s<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", argv[2]);
    int32_t toks[4096];
    int n = xj_tok_encode(tok, prompt, toks, 4096);
    fprintf(stderr, "层数 %d，embd %d，prompt %d 个 token，拆分点 %d\n", hp->n_layer, hp->n_embd, n, split);

    int L = hp->n_layer, s1 = split > 0 && split < L ? split : L;
    xj_stage *a = xj_cpu_stage_new(m, 0, s1, 4096, batch, s1 == L, err, sizeof err);
    xj_stage *b = s1 < L ? xj_cpu_stage_new(m, s1, L, 4096, batch, true, err, sizeof err) : NULL;
    if (!a || (s1 < L && !b)) { fprintf(stderr, "%s\n", err); return 1; }
    xj_stage *head = b ? b : a;

    float *x = malloc(sizeof(float) * hp->n_embd * batch);
    float *logits = malloc(sizeof(float) * hp->n_vocab);
    double t0 = now();
    for (int i = 0; i < n; i += batch) {
        int T = n - i < batch ? n - i : batch;
        for (int t = 0; t < T; t++) xj_embed(m, toks[i + t], x + (size_t)t * hp->n_embd);
        if (a->forward(a, x, T, err, sizeof err) || (b && b->forward(b, x, T, err, sizeof err))) { fprintf(stderr, "%s\n", err); return 1; }
        if (i + T == n) head->logits(head, x + (size_t)(T - 1) * hp->n_embd, 1, logits, err, sizeof err);
    }
    double t1 = now();
    { int id = argmax(logits, hp->n_vocab); fprintf(stderr, "预填充 %.2f 秒；第一个词 id=%d 分数=%.5f\n", t1 - t0, id, logits[id]); }
    for (int g = 0; g < n_gen; g++) {
        int id = argmax(logits, hp->n_vocab);
        if ((uint32_t)id == hp->eot || (uint32_t)id == hp->eos) break;
        char piece[256];
        int pl = xj_tok_piece(tok, id, piece, sizeof piece);
        fwrite(piece, 1, pl, stdout); fflush(stdout);
        xj_embed(m, id, x);
        if (a->forward(a, x, 1, err, sizeof err) || (b && b->forward(b, x, 1, err, sizeof err))) { fprintf(stderr, "%s\n", err); return 1; }
        head->logits(head, x, 1, logits, err, sizeof err);
    }
    double t2 = now();
    printf("\n");
    fprintf(stderr, "生成 %.2f 秒\n", t2 - t1);
    return 0;
}
