// 从机命令行版（电脑上测试用；iPhone 7 Plus 上用 ios/ 里的从机 App，算法是同一套）。
//   xjpipe-worker 模型.gguf [--layers 12:20] [--port 47321] [--pin 0] [--cpu]
// 给了 --layers 就只映射这几层（和 iPhone 从机一样），主机 --split 不写就用这个范围。
// macOS 上默认用 Metal，--cpu 强制用 CPU 参考实现。
// --die-after N：算完 N 批之后整个进程直接退出（测试主机的断线重连用，模拟从机 App 被杀）。
#include "../core/xj_net.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static bool use_cpu = false;
static int die_after = -1, n_forward = 0;
static int (*real_forward)(xj_stage *, float *, int, char *, size_t);

static int counting_forward(xj_stage *s, float *x, int T, char *err, size_t errlen) {
    if (n_forward++ == die_after) { fprintf(stderr, "[从机] --die-after %d：模拟从机被杀，退出\n", die_after); _exit(3); }
    return real_forward(s, x, T, err, errlen);
}

static xj_stage *make(void *ctx, const xj_model *m, int l0, int l1, int n_ctx, int max_batch, char *err, size_t errlen) {
    xj_stage *s = NULL;
#ifdef __APPLE__
    if (!use_cpu) s = xj_metal_stage_new(m, l0, l1, n_ctx, max_batch, false, err, errlen);
    else
#endif
    s = xj_cpu_stage_new(m, l0, l1, n_ctx, max_batch, false, err, errlen);
    if (s && die_after >= 0) { real_forward = s->forward; s->forward = counting_forward; }
    return s;
}

static void say(void *ctx, const char *msg) { fprintf(stderr, "[从机] %s\n", msg); }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "用法: xjpipe-worker 模型.gguf [--port %d] [--pin 0] [--cpu]\n", XJ_DEFAULT_PORT); return 1; }
    int port = XJ_DEFAULT_PORT;
    uint32_t pin = 0;
    int l0 = -1, l1 = -1;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--layers") && i + 1 < argc) { sscanf(argv[++i], "%d:%d", &l0, &l1); continue; }
        if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--pin") && i + 1 < argc) pin = (uint32_t)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--die-after") && i + 1 < argc) die_after = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--cpu")) use_cpu = true;
    }
    signal(SIGPIPE, SIG_IGN);
    char err[256];
    xj_model *m = l0 >= 0 ? xj_model_load_layers(argv[1], l0, l1, false, err, sizeof err) : xj_model_load(argv[1], err, sizeof err);
    if (!m) { fprintf(stderr, "%s\n", err); return 1; }
    xj_worker w;
    memset(&w, 0, sizeof w);
    w.model = m;
    w.have_l0 = l0 >= 0 ? l0 : 0;
    w.have_l1 = l0 >= 0 ? l1 : m->hp.n_layer; w.pin = pin; w.max_ctx = 32768; w.max_batch_limit = 64;
    w.make_stage = make; w.log = say;
    if (xj_worker_serve(&w, port, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    xj_model_free(m);
    return 0;
}
