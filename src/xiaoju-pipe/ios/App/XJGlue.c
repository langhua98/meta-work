// 小橘双机：Swift ↔ 推理核心的胶水（见 XJGlue.h）。
#include "XJGlue.h"

#include "../../core/xj_net.h"
#include "../../core/xj_tok.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <math.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#if __has_include(<os/proc.h>)
#include <os/proc.h>
#define HAVE_PROC_MEM 1
#endif

static double now_s(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

static void fill_info(const xj_model *m, xjg_model_info *info) {
    memset(info, 0, sizeof(*info));
    info->n_layer = m->hp.n_layer;
    info->n_embd = m->hp.n_embd;
    for (int i = 0; i < m->hp.n_layer && i < 128; i++) info->layer_mb[i] = xj_model_layer_bytes(m, i, i + 1) / 1048576.0;
    info->io_mb = (m->tok_embd.nbytes + m->output_norm.nbytes + (m->output.file_off != m->tok_embd.file_off ? m->output.nbytes : 0)) / 1048576.0;
    info->total_bytes = m->gguf->size;
}

int xjg_plan(const uint8_t *head, uint64_t len, int l0, int l1, uint64_t (*ranges)[2], int max,
             uint64_t *need, uint64_t *data_off, xjg_model_info *info, char *err, int errlen) {
    *need = 0;
    uint64_t more = 0;
    gguf_file *g = gguf_parse_header(head, len, &more, err, (size_t)errlen);
    if (!g) {
        if (more) { *need = more; return 0; }
        return -1;
    }
    xj_model *m = xj_model_from_gguf(g, err, (size_t)errlen);
    if (!m) { gguf_close(g); return -1; }
    if (info) { fill_info(m, info); info->total_bytes = 0; }
    *data_off = g->data_off;
    if (l0 < 0 || l1 > m->hp.n_layer || l0 >= l1) { snprintf(err, errlen, "层范围不对（模型一共 %d 层）", m->hp.n_layer); xj_model_free(m); return -1; }
    int n = xj_model_ranges(m, l0, l1, false, ranges, max);
    xj_model_free(m);  // 只释放结构，head 是调用方的
    return n;
}

int xjg_model_info_of(const char *path, xjg_model_info *info, char *err, int errlen) {
    gguf_file *g = gguf_open_header(path, err, (size_t)errlen);
    if (!g) return -1;
    xj_model *m = xj_model_from_gguf(g, err, (size_t)errlen);
    if (!m) { gguf_close(g); return -1; }
    fill_info(m, info);
    xj_model_free(m);
    return 0;
}

uint64_t xjg_free_memory(void) {
#ifdef HAVE_PROC_MEM
    return (uint64_t)os_proc_available_memory();
#else
    return 0;
#endif
}

const char *xjg_gpu_name(void) {
#ifdef __APPLE__
    return xj_metal_device_name();
#else
    return "CPU";
#endif
}

// ================= 从机 =================

typedef struct {
    xj_worker w;
    xj_model *m;
    xjg_log_fn log;
    void *ctx;
} worker_box;

static xj_stage *make_stage(void *ctx, const xj_model *m, int l0, int l1, int n_ctx, int max_batch, char *err, size_t errlen) {
#ifdef __APPLE__
    return xj_metal_stage_new(m, l0, l1, n_ctx, max_batch, false, err, errlen);
#else
    return xj_cpu_stage_new(m, l0, l1, n_ctx, max_batch, false, err, errlen);
#endif
}

static uint64_t free_mem(void *ctx) { return xjg_free_memory(); }

static void wlog(void *ctx, const char *msg) {
    worker_box *b = ctx;
    if (b->log) b->log(b->ctx, msg);
}

void *xjg_worker_new(const char *path, int l0, int l1, uint32_t pin, xjg_log_fn log, void *ctx, char *err, int errlen) {
    xj_model *m = xj_model_load_layers(path, l0, l1, false, err, (size_t)errlen);
    if (!m) return NULL;
    worker_box *b = calloc(1, sizeof(*b));
    b->m = m; b->log = log; b->ctx = ctx;
    b->w.model = m;
    b->w.have_l0 = l0; b->w.have_l1 = l1;
    b->w.pin = pin;
    b->w.max_ctx = 16384;
    b->w.max_batch_limit = 16;
    b->w.make_stage = make_stage;
    b->w.free_mem = free_mem;
    b->w.log = wlog;
    b->w.ctx = b;
    b->w.listen_fd = b->w.conn_fd = -1;
    return b;
}

int xjg_worker_run(void *p, int port, char *err, int errlen) {
    worker_box *b = p;
    b->w.stop = 0;
    return xj_worker_serve(&b->w, port, err, (size_t)errlen);
}

void xjg_worker_stop(void *p) { xj_worker_stop(&((worker_box *)p)->w); }

void xjg_worker_free(void *p) {
    worker_box *b = p;
    if (!b) return;
    xj_model_free(b->m);
    free(b);
}

// ================= 主机 =================

typedef struct {
    xj_model *m;
    xj_tok *tok;
    xj_stage *a, *r, *b;
    xj_pipeline p;
    float *logits;
    int32_t *buf;
    int n_ctx;
    int32_t nl;            // "\n" 的 token
    char pending[8]; int npending;  // 没凑完整的 UTF-8 字节
} host_box;

static xj_stage *local_stage(const xj_model *m, int l0, int l1, int n_ctx, bool head, char *err, size_t el) {
#ifdef __APPLE__
    return xj_metal_stage_new(m, l0, l1, n_ctx, 8, head, err, el);
#else
    return xj_cpu_stage_new(m, l0, l1, n_ctx, 8, head, err, el);
#endif
}

void xjg_host_free(void *p) {
    host_box *h = p;
    if (!h) return;
    if (h->r) h->r->destroy(h->r);
    if (h->a) h->a->destroy(h->a);
    if (h->b) h->b->destroy(h->b);
    xj_pipeline_free(&h->p);
    xj_tok_free(h->tok);
    xj_model_free(h->m);
    free(h->logits); free(h->buf);
    free(h);
}

void *xjg_host_new(const char *path, const char *worker_host, int port, uint32_t pin, int s1, int s2,
                   int n_ctx, char *info, int infolen, char *err, int errlen) {
    host_box *h = calloc(1, sizeof(*h));
    h->n_ctx = n_ctx;
    h->m = xj_model_load(path, err, (size_t)errlen);
    if (!h->m) { free(h); return NULL; }
    h->tok = xj_tok_new(h->m->gguf, err, (size_t)errlen);
    if (!h->tok) { xjg_host_free(h); return NULL; }
    const int L = h->m->hp.n_layer;
    if (worker_host && worker_host[0]) {
        xj_hello_ok hi;
        memset(&hi, 0, sizeof hi);
        h->r = xj_remote_stage_new(worker_host, port, pin, h->m, s1, s2, n_ctx, 8, &hi, err, (size_t)errlen);
        if (!h->r) { xjg_host_free(h); return NULL; }
        h->a = local_stage(h->m, 0, h->r->l0, n_ctx, false, err, (size_t)errlen);
        h->b = h->a ? local_stage(h->m, h->r->l1, L, n_ctx, true, err, (size_t)errlen) : NULL;
        if (!h->a || !h->b) { xjg_host_free(h); return NULL; }
        snprintf(info, infolen, "从机 %s：第 %d–%d 层（%.0f MB，%s）\n本机 %s：第 0–%d 层%s + 输出头\n往返延迟 %.1f ms",
                 hi.device, h->r->l0, h->r->l1 - 1, hi.weight_bytes / 1048576.0, hi.backend,
                 xjg_gpu_name(), h->r->l0 - 1, h->r->l1 < L ? "、后面几层" : "", xj_remote_ping(h->r));
    } else {
        h->a = local_stage(h->m, 0, L, n_ctx, true, err, (size_t)errlen);
        if (!h->a) { xjg_host_free(h); return NULL; }
        snprintf(info, infolen, "单机：%s 跑全部 %d 层", xjg_gpu_name(), L);
    }
    xj_pipeline_init(&h->p, h->m, h->a, h->r, h->b);
    h->logits = malloc(sizeof(float) * h->m->hp.n_vocab);
    h->buf = malloc(sizeof(int32_t) * 16384);
    int32_t nl[4];
    h->nl = xj_tok_encode(h->tok, "\n", nl, 4) == 1 ? nl[0] : -1;
    return h;
}

void xjg_host_set_status(void *p, xjg_log_fn fn, void *ctx) {
    host_box *h = p;
    h->p.on_status = fn;
    h->p.status_ctx = ctx;
}

double xjg_host_ping(void *p) {
    host_box *h = p;
    return h->r ? xj_remote_ping(h->r) : -1;
}

int xjg_host_reset(void *p, char *err, int errlen) {
    host_box *h = p;
    h->npending = 0;
    return xj_pipeline_reset(&h->p, err, (size_t)errlen);
}

// top-k + top-p 采样；temperature <= 0 就取最大
static int sample(const float *lg, int n, float temp) {
    int best = 0;
    for (int i = 1; i < n; i++) if (lg[i] > lg[best]) best = i;
    if (temp <= 0) return best;
    enum { K = 40 };
    int idx[K]; float val[K]; int k = 0;
    for (int i = 0; i < n; i++) {
        if (k < K) { idx[k] = i; val[k] = lg[i]; k++; }
        else {
            int mi = 0;
            for (int j = 1; j < K; j++) if (val[j] < val[mi]) mi = j;
            if (lg[i] > val[mi]) { idx[mi] = i; val[mi] = lg[i]; }
        }
    }
    // 从大到小排
    for (int i = 0; i < k; i++) for (int j = i + 1; j < k; j++) if (val[j] > val[i]) { float tv = val[i]; val[i] = val[j]; val[j] = tv; int ti = idx[i]; idx[i] = idx[j]; idx[j] = ti; }
    double p[K], sum = 0;
    for (int i = 0; i < k; i++) { p[i] = exp((val[i] - val[0]) / temp); sum += p[i]; }
    double acc = 0; int cut = k;
    for (int i = 0; i < k; i++) { acc += p[i] / sum; if (acc >= 0.95) { cut = i + 1; break; } }
    double s2 = 0;
    for (int i = 0; i < cut; i++) s2 += p[i];
    double r = (double)arc4random_uniform(1u << 30) / (double)(1u << 30) * s2;
    for (int i = 0; i < cut; i++) { r -= p[i]; if (r <= 0) return idx[i]; }
    return idx[0];
}

// 只把完整的 UTF-8 字符交给界面
static int emit(host_box *h, const char *s, int n, xjg_piece_fn cb, void *ctx) {
    char out[300];
    int o = 0;
    memcpy(out, h->pending, h->npending);
    o = h->npending;
    if (n > 256) n = 256;
    memcpy(out + o, s, n);
    o += n;
    int ok = o;
    // 从尾部往回看，最后一个字符不完整就留到下次
    for (int back = 1; back <= 4 && back <= o; back++) {
        unsigned char c = (unsigned char)out[o - back];
        if ((c & 0xC0) == 0x80) continue;
        int need = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1;
        if (need > back) ok = o - back;
        break;
    }
    h->npending = o - ok;
    memcpy(h->pending, out + ok, h->npending);
    return ok ? cb(ctx, out, ok) : 0;
}

int xjg_host_chat(void *p, const char *user, float temperature, int max_tokens,
                  xjg_piece_fn cb, void *ctx, xjg_stats *st, char *err, int errlen) {
    host_box *h = p;
    const xj_hparams *hp = &h->m->hp;
    memset(st, 0, sizeof(*st));
    size_t ul = strlen(user);
    char *prompt = malloc(ul + 128);
    // 不要思考过程：给一个空的 <think> 块（Qwen3.5 的非思考模式）
    snprintf(prompt, ul + 128, "<|im_start|>user\n%s<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", user);
    int n = xj_tok_encode(h->tok, prompt, h->buf, 16384);
    free(prompt);
    int room = h->n_ctx - h->p.a->n_past;
    if (n + 4 > room) { snprintf(err, errlen, "上下文快满了，点「新对话」重新开始"); return -1; }
    if (max_tokens > room - n - 2) max_tokens = room - n - 2;

    double t0 = now_s();
    h->p.t_local = h->p.t_remote = h->p.t_net = 0;
    if (xj_pipeline_eval(&h->p, h->buf, n, h->logits, err, (size_t)errlen)) return -1;
    st->prompt_tokens = n;
    st->prefill_s = now_s() - t0;
    h->p.t_local = h->p.t_remote = h->p.t_net = 0;
    double t1 = now_s();
    int produced = 0;
    bool stop = false;
    while (produced < max_tokens && !stop) {
        int id = sample(h->logits, hp->n_vocab, temperature);
        if ((uint32_t)id == hp->eot || (uint32_t)id == hp->eos) break;
        char piece[256];
        int pl = xj_tok_piece(h->tok, id, piece, sizeof piece);
        if (emit(h, piece, pl, cb, ctx)) stop = true;
        int32_t one = id;
        if (xj_pipeline_eval(&h->p, &one, 1, h->logits, err, (size_t)errlen)) return -1;
        produced++;
    }
    // 回答收尾：把 <|im_end|>\n 也喂进去，下一句接着聊时上下文是完整的
    int32_t tail[2] = { (int32_t)hp->eot, h->nl };
    if (xj_pipeline_eval(&h->p, tail, h->nl >= 0 ? 2 : 1, h->logits, err, (size_t)errlen)) return -1;
    st->gen_tokens = produced;
    st->gen_s = now_s() - t1;
    if (produced) {
        st->local_ms = h->p.t_local / produced;
        st->remote_ms = h->p.t_remote / produced;
        st->wait_ms = h->p.t_net / produced;
    }
    st->n_past = h->p.a->n_past;
    st->n_ctx = h->n_ctx;
    st->reconnects = h->p.n_reconnects;
    return 0;
}

void xjg_local_ips(char *buf, int len) {
    buf[0] = 0;
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa)) return;
    int o = 0;
    for (struct ifaddrs *i = ifa; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || (i->ifa_flags & IFF_LOOPBACK) || !(i->ifa_flags & IFF_UP)) continue;
        if (strncmp(i->ifa_name, "en", 2) != 0) continue;  // Wi‑Fi（en0）和个人热点（bridge 不算）
        char ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, ip, sizeof ip);
        o += snprintf(buf + o, len - o, "%s%s", o ? "\n" : "", ip);
        if (o >= len - 1) break;
    }
    freeifaddrs(ifa);
}
