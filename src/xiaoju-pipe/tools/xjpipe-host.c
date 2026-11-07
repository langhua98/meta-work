// 主机命令行版：本机算 [0,s1) 和 [s2,L) + 输出头，从机算 [s1,s2)。
//   xjpipe-host 模型.gguf "问题" --worker 192.168.1.23 --split 12:24 [--pin 0] [--n 64] [--batch 8] [--retry 5] [--cpu]
// 不给 --worker 就整个模型在本机跑（对照用）；不给 --split 就用从机准备好的那几层。
// 从机断了会自动重连、重放之前的 token 再接着算，最多 --retry 次（0 = 不重连）。
#include "../core/xj_net.h"
#include "../core/xj_tok.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static int argmax(const float *x, int n) { int b = 0; for (int i = 1; i < n; i++) if (x[i] > x[b]) b = i; return b; }

static bool use_cpu = false;
static void status(void *ctx, const char *msg) { fprintf(stderr, "\n[主机] %s\n", msg); }
static xj_stage *local(const xj_model *m, int l0, int l1, int n_ctx, int batch, bool head, char *err, size_t el) {
#ifdef __APPLE__
    if (!use_cpu) return xj_metal_stage_new(m, l0, l1, n_ctx, batch, head, err, el);
#endif
    return xj_cpu_stage_new(m, l0, l1, n_ctx, batch, head, err, el);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "用法: xjpipe-host 模型.gguf \"问题\" [--worker IP] [--port %d] [--split 12:24] [--pin 0] [--n 64] [--batch 8] [--retry 5] [--cpu]\n", XJ_DEFAULT_PORT);
        return 1;
    }
    const char *worker = NULL;
    int port = XJ_DEFAULT_PORT, s1 = -1, s2 = -1, n_gen = 64, batch = 8, n_ctx = 4096, retry = 5;
    uint32_t pin = 0;
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--worker") && i + 1 < argc) worker = argv[++i];
        else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--split") && i + 1 < argc) sscanf(argv[++i], "%d:%d", &s1, &s2);
        else if (!strcmp(argv[i], "--pin") && i + 1 < argc) pin = (uint32_t)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--n") && i + 1 < argc) n_gen = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--batch") && i + 1 < argc) batch = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--ctx") && i + 1 < argc) n_ctx = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--retry") && i + 1 < argc) retry = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--cpu")) use_cpu = true;
    }
    signal(SIGPIPE, SIG_IGN);
    char err[256];
    xj_model *m = xj_model_load(argv[1], err, sizeof err);
    if (!m) { fprintf(stderr, "%s\n", err); return 1; }
    const int L = m->hp.n_layer;
    xj_tok *tok = xj_tok_new(m->gguf, err, sizeof err);
    if (!tok) { fprintf(stderr, "%s\n", err); return 1; }

    xj_stage *a, *r = NULL, *b = NULL;
    if (worker) {
        if (s1 >= 0 && s2 < 0) s2 = L;
        if (s1 >= 0 && !(0 <= s1 && s1 < s2 && s2 <= L)) { fprintf(stderr, "--split 要满足 0 <= s1 < s2 <= %d\n", L); return 1; }
        // 先握手：从机报它负责哪几层，再建本机的两段
        xj_hello_ok info;
        memset(&info, 0, sizeof info);
        double t0 = now();
        r = xj_remote_stage_new(worker, port, pin, m, s1 < 0 ? 0 : s1, s1 < 0 ? 0 : s2, n_ctx, batch, &info, err, sizeof err);
        if (!r) { fprintf(stderr, "%s\n", err); return 1; }
        s1 = r->l0; s2 = r->l1;
        fprintf(stderr, "从机 %s（%s）就绪，第 %d–%d 层，权重 %.0f MB，握手 %.1f 秒，往返 %.2f ms\n",
                info.device, info.backend, s1, s2 - 1, info.weight_bytes / 1048576.0, now() - t0, xj_remote_ping(r));
        a = local(m, 0, s1, n_ctx, batch, false, err, sizeof err);
        if (!a) { fprintf(stderr, "%s\n", err); return 1; }
        b = local(m, s2, L, n_ctx, batch, true, err, sizeof err);
        if (!b) { fprintf(stderr, "%s\n", err); return 1; }
    } else {
        a = local(m, 0, L, n_ctx, batch, true, err, sizeof err);
        if (!a) { fprintf(stderr, "%s\n", err); return 1; }
    }
    fprintf(stderr, "本机后端 %s\n", a->backend);

    xj_pipeline p;
    xj_pipeline_init(&p, m, a, r, b);
    p.reconnect_tries = retry;
    p.on_status = status;
    char prompt[8192];
    snprintf(prompt, sizeof prompt, "<|im_start|>user\n%s<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", argv[2]);
    int32_t toks[4096];
    int n = xj_tok_encode(tok, prompt, toks, 4096);
    float *logits = malloc(sizeof(float) * m->hp.n_vocab);

    double t0 = now();
    if (xj_pipeline_eval(&p, toks, n, logits, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    double t1 = now();
    int id = argmax(logits, m->hp.n_vocab);
    fprintf(stderr, "预填充 %d 个 token %.2f 秒；第一个词 id=%d 分数=%.5f\n", n, t1 - t0, id, logits[id]);
    p.t_local = p.t_remote = p.t_net = 0;
    int produced = 0;
    for (; produced < n_gen; produced++) {
        id = argmax(logits, m->hp.n_vocab);
        if ((uint32_t)id == m->hp.eot || (uint32_t)id == m->hp.eos) break;
        char piece[256];
        int pl = xj_tok_piece(tok, id, piece, sizeof piece);
        fwrite(piece, 1, pl, stdout); fflush(stdout);
        int32_t one = id;
        if (xj_pipeline_eval(&p, &one, 1, logits, err, sizeof err)) { fprintf(stderr, "\n%s\n", err); return 1; }
    }
    double t2 = now();
    printf("\n");
    if (produced)
        fprintf(stderr, "生成 %d 个 token，%.2f 字/秒；每个 token：本机 %.1f ms，从机计算 %.1f ms，等从机（含网络）%.1f ms\n",
                produced, produced / (t2 - t1), p.t_local / produced, p.t_remote / produced, p.t_net / produced);
    if (p.n_reconnects) fprintf(stderr, "中途重连了 %d 次\n", p.n_reconnects);
    if (r) r->destroy(r);
    a->destroy(a);
    if (b) b->destroy(b);
    return 0;
}
