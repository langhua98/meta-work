// 主机命令行版：本机算 [0,s1) 和 [s2,L) + 输出头，从机算 [s1,s2)。
//   xjpipe-host 模型.gguf "问题" --worker 192.168.1.23 --split 12:24 [--pin 0] [--n 64] [--batch 8] [--retry 5] [--cpu]
//               [--draft 3] [--mtp 带MTP的.gguf]
// 不给 --worker 就整个模型在本机跑（对照用）；不给 --split 就用从机准备好的那几层。
// 从机断了会自动重连、重放之前的 token 再接着算，最多 --retry 次（0 = 不重连）。
// --draft K：MTP 投机解码，每步猜 K 个字（模型文件里没有 MTP 层时用 --mtp 指定带 MTP 的文件）。贪心解码，输出和不投机一样。
#include "../core/xj_spec.h"
#include "../core/xj_tok.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static int argmax(const float *x, int n) { int b = 0; for (int i = 1; i < n; i++) if (x[i] > x[b]) b = i; return b; }
static int greedy(void *ctx, const float *x, int n) { return argmax(x, n); }

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
    const char *worker = NULL, *mtp_path = NULL, *ids_path = NULL, *oracle_path = NULL;
    int oracle_miss = 0;
    int draft = 0;
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
        else if (!strcmp(argv[i], "--draft") && i + 1 < argc) draft = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--mtp") && i + 1 < argc) mtp_path = argv[++i];
        else if (!strcmp(argv[i], "--ids") && i + 1 < argc) ids_path = argv[++i];
        else if (!strcmp(argv[i], "--oracle") && i + 1 < argc) { oracle_path = argv[++i]; if (i + 1 < argc && argv[i + 1][0] != '-') oracle_miss = atoi(argv[++i]); }
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
    xj_stage *mtp = NULL;
    if (draft > 0) {
        if (mtp_path && xj_model_attach_mtp(m, mtp_path, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
        if (!m->has_mtp) { fprintf(stderr, "模型里没有 MTP 层，用 --mtp 指定带 MTP 的 GGUF\n"); return 1; }
        mtp = local(m, L, L + 1, n_ctx, batch, true, err, sizeof err);
        if (!mtp) { fprintf(stderr, "%s\n", err); return 1; }
        fprintf(stderr, "MTP 投机解码：每步猜 %d 个字\n", draft);
        // norm 权重的均值（排查：转换时有没有 +1）
        const xj_w *nw[] = { &m->mtp_enorm, &m->mtp_hnorm, &m->mtp_head_norm, &m->layers[L].attn_norm, &m->output_norm, &m->layers[0].attn_norm };
        const char *nn[] = { "enorm", "hnorm", "shared_head_norm", "mtp.attn_norm", "output_norm", "blk0.attn_norm" };
        for (int i = 0; i < 6; i++) {
            double sum = 0; const float *f = nw[i]->data;
            for (int j = 0; j < nw[i]->ne0; j++) sum += f[j];
            fprintf(stderr, "  %s 均值 %.3f\n", nn[i], sum / nw[i]->ne0);
        }
    }

    xj_pipeline p;
    xj_pipeline_init(&p, m, a, r, b);
    p.reconnect_tries = retry;
    p.on_status = status;
    char prompt[8192];
    snprintf(prompt, sizeof prompt, "<|im_start|>user\n%s<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", argv[2]);
    int32_t toks[4096];
    int n = xj_tok_encode(tok, prompt, toks, 4096);
    xj_spec sp;
    if (xj_spec_init(&sp, &p, mtp, draft)) { fprintf(stderr, "内存不够\n"); return 1; }
    // 测试：--ids 把生成的字的编号写下来；--oracle 文件 [N] 拿它当猜的字（每隔约 N 个故意错一个）
    static int32_t oracle[8192];
    FILE *ids = ids_path ? fopen(ids_path, "w") : NULL;
    if (oracle_path) {
        FILE *f = fopen(oracle_path, "r");
        if (!f) { fprintf(stderr, "打不开 %s\n", oracle_path); return 1; }
        int n_or = 0;
        while (n_or < 8192 && fscanf(f, "%d", &oracle[n_or]) == 1) n_or++;
        fclose(f);
        sp.oracle = oracle; sp.n_oracle = n_or; sp.oracle_miss = oracle_miss;
    }

    double t0 = now();
    if (xj_spec_feed(&sp, toks, n, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    double t1 = now();
    int id = argmax(sp.last_logits, m->hp.n_vocab);
    fprintf(stderr, "预填充 %d 个 token %.2f 秒；第一个词 id=%d 分数=%.5f\n", n, t1 - t0, id, sp.last_logits[id]);
    p.t_local = p.t_remote = p.t_net = 0;
    int produced = 0;
    bool done = false;
    while (produced < n_gen && !done) {
        int32_t out[XJ_SPEC_MAXK + 1];
        int k = xj_spec_next(&sp, greedy, NULL, out, n_gen - produced, err, sizeof err);
        if (k < 0) { fprintf(stderr, "\n%s\n", err); return 1; }
        for (int i = 0; i < k; i++) {
            if ((uint32_t)out[i] == m->hp.eot || (uint32_t)out[i] == m->hp.eos) { done = true; break; }
            char piece[256];
            int pl = xj_tok_piece(tok, out[i], piece, sizeof piece);
            fwrite(piece, 1, pl, stdout);
            if (ids) fprintf(ids, "%d\n", out[i]);
            produced++;
        }
        fflush(stdout);
    }
    double t2 = now();
    if (ids) fclose(ids);
    printf("\n");
    if (produced)
        fprintf(stderr, "生成 %d 个 token，%.2f 字/秒；每个 token：本机 %.1f ms，从机计算 %.1f ms，等从机（含网络）%.1f ms\n",
                produced, produced / (t2 - t1), p.t_local / produced, p.t_remote / produced, p.t_net / produced);
    if (sp.n_steps)
        fprintf(stderr, "投机解码：%ld 步，猜了 %ld 个字，猜中 %ld 个（%.0f%%），平均每步出 %.2f 个字，MTP 猜字共 %.0f ms\n",
                sp.n_steps, sp.n_drafted, sp.n_accepted, 100.0 * sp.n_accepted / (sp.n_drafted ? sp.n_drafted : 1),
                (double)produced / sp.n_steps, sp.t_draft_ms);
    if (sp.n_steps) {
        fprintf(stderr, "各位置猜中：");
        for (int j = 0; j < sp.k; j++) fprintf(stderr, "第%d个 %ld/%ld  ", j + 1, sp.acc_at[j], j ? sp.acc_at[j - 1] : sp.n_steps);
        fprintf(stderr, "\n");
    }
    if (p.n_reconnects) fprintf(stderr, "中途重连了 %d 次\n", p.n_reconnects);
    if (r) r->destroy(r);
    a->destroy(a);
    if (b) b->destroy(b);
    if (mtp) mtp->destroy(mtp);
    xj_spec_free(&sp);
    return 0;
}
