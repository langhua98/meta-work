// 小橘双机推理：协议实现（见 xj_net.h 开头）。
#include "xj_net.h"

#include <arpa/inet.h>
#include <errno.h>
#include <stdarg.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#define XJ_MAX_MSG (64u << 20)

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec * 1e-6;
}

static void sock_opts(int fd) {
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    int buf = 1 << 20;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, sizeof buf);
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, sizeof buf);
}

static int write_all(int fd, const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) {
        ssize_t k = send(fd, b, n, MSG_NOSIGNAL);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return -1;
        b += k; n -= (size_t)k;
    }
    return 0;
}

static int read_all(int fd, void *p, size_t n) {
    uint8_t *b = p;
    while (n) {
        ssize_t k = recv(fd, b, n, 0);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return -1;
        b += k; n -= (size_t)k;
    }
    return 0;
}

// 小端读写（两台都是 ARM，主机测试用 x86，都是小端；这里显式写出来不依赖结构体布局）
static void p32(uint8_t **o, uint32_t v) { memcpy(*o, &v, 4); *o += 4; }
static void p64(uint8_t **o, uint64_t v) { memcpy(*o, &v, 8); *o += 8; }
static uint32_t g32(const uint8_t **i) { uint32_t v; memcpy(&v, *i, 4); *i += 4; return v; }
static uint64_t g64(const uint8_t **i) { uint64_t v; memcpy(&v, *i, 8); *i += 8; return v; }

int xj_send_msg(int fd, uint16_t type, uint32_t seq, const void *a, uint32_t alen, const void *b, uint32_t blen) {
    uint8_t h[16], *o = h;
    uint16_t flags = 0;
    p32(&o, XJ_MAGIC);
    memcpy(o, &type, 2); o += 2;
    memcpy(o, &flags, 2); o += 2;
    p32(&o, alen + blen);
    p32(&o, seq);
    if (write_all(fd, h, 16)) return -1;
    if (alen && write_all(fd, a, alen)) return -1;
    if (blen && write_all(fd, b, blen)) return -1;
    return 0;
}

int xj_recv_msg(int fd, void **buf, uint32_t *cap, uint32_t *len, uint32_t *seq, char *err, size_t errlen) {
    uint8_t h[16];
    if (read_all(fd, h, 16)) { snprintf(err, errlen, "连接断了"); return -1; }
    const uint8_t *i = h;
    uint32_t magic = g32(&i);
    uint16_t type; memcpy(&type, i, 2); i += 4;
    uint32_t n = g32(&i);
    *seq = g32(&i);
    if (magic != XJ_MAGIC) { snprintf(err, errlen, "对方不是小橘双机（协议头不对）"); return -1; }
    if (n > XJ_MAX_MSG) { snprintf(err, errlen, "消息太大（%u 字节）", n); return -1; }
    if (n > *cap) {
        void *nb = realloc(*buf, n);
        if (!nb) { snprintf(err, errlen, "内存不够"); return -1; }
        *buf = nb; *cap = n;
    }
    if (n && read_all(fd, *buf, n)) { snprintf(err, errlen, "连接断了"); return -1; }
    *len = n;
    return type;
}

static void send_error(int fd, uint32_t seq, const char *msg) {
    xj_send_msg(fd, XJ_MSG_ERROR, seq, msg, (uint32_t)strlen(msg), NULL, 0);
}

// ================= 从机 =================

static void wlog(xj_worker *w, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void wlog(xj_worker *w, const char *fmt, ...) {
    char b[512];
    va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
    if (w->log) w->log(w->ctx, b);
}

static void serve_conn(xj_worker *w, int fd, const char *peer) {
    const xj_model *m = w->model;
    const int E = m->hp.n_embd;
    xj_stage *st = NULL;
    void *buf = NULL; uint32_t cap = 0, len = 0, seq = 0;
    float *x = NULL;
    char err[256];
    uint64_t n_tok = 0;
    double busy = 0, t_start = now_ms();

    for (;;) {
        // 等下一条消息的同时看着监听端口：主机断线重连时，旧连接可能还没被发现是死的
        // （Wi‑Fi 断开时对方来不及发 FIN），这时新连接优先，旧的直接丢掉。
        struct pollfd pf[2] = { { fd, POLLIN, 0 }, { w->listen_fd, POLLIN, 0 } };
        int np = w->listen_fd >= 0 ? 2 : 1;
        if (poll(pf, (nfds_t)np, -1) < 0) { if (errno == EINTR) continue; break; }
        if (w->stop) break;
        if (np == 2 && pf[1].revents && !pf[0].revents) { wlog(w, "有新的连接进来，先断开 %s 的旧连接", peer); break; }
        int type = xj_recv_msg(fd, &buf, &cap, &len, &seq, err, sizeof err);
        if (type < 0 || w->stop) break;
        const uint8_t *in = buf;
        if (type == XJ_MSG_HELLO) {
            if (len < 36) { send_error(fd, seq, "HELLO 太短"); break; }
            xj_hello h;
            h.version = g32(&in); h.pin = g32(&in); h.fingerprint = g64(&in);
            h.l0 = g32(&in); h.l1 = g32(&in); h.n_ctx = g32(&in); h.max_batch = g32(&in);
            if (h.version != XJ_PROTO_VERSION) { send_error(fd, seq, "两边 App 版本不一样，先都更新到最新"); break; }
            if (w->pin && h.pin != w->pin) { send_error(fd, seq, "配对码不对"); wlog(w, "%s 配对码不对，拒绝", peer); break; }
            if (h.fingerprint != m->fingerprint) { send_error(fd, seq, "两台手机上的模型文件不一样"); break; }
            if (h.l0 == 0 && h.l1 == 0) { h.l0 = (uint32_t)w->have_l0; h.l1 = (uint32_t)w->have_l1; }
            if (h.l0 >= h.l1 || h.l1 > (uint32_t)m->hp.n_layer) { send_error(fd, seq, "层范围不对"); break; }
            if ((int)h.l0 < w->have_l0 || (int)h.l1 > w->have_l1) {
                snprintf(err, sizeof err, "从机只准备了第 %d–%d 层，主机要的是第 %u–%u 层", w->have_l0, w->have_l1 - 1, h.l0, h.l1 - 1);
                send_error(fd, seq, err); break;
            }
            if (h.n_ctx < 16 || h.n_ctx > (uint32_t)w->max_ctx) { snprintf(err, sizeof err, "上下文长度要在 16 到 %d 之间", w->max_ctx); send_error(fd, seq, err); break; }
            if (h.max_batch < 1 || h.max_batch > (uint32_t)w->max_batch_limit) { snprintf(err, sizeof err, "一批最多 %d 个 token", w->max_batch_limit); send_error(fd, seq, err); break; }
            if (st) { st->destroy(st); st = NULL; }
            wlog(w, "%s 连上了，加载第 %u–%u 层……", peer, h.l0, h.l1 - 1);
            st = w->make_stage(w->ctx, m, (int)h.l0, (int)h.l1, (int)h.n_ctx, (int)h.max_batch, err, sizeof err);
            if (!st) { send_error(fd, seq, err); wlog(w, "加载失败：%s", err); break; }
            free(x);
            x = malloc(sizeof(float) * E * h.max_batch);
            uint8_t out[128], *o = out;
            memset(out, 0, sizeof out);
            p32(&o, XJ_PROTO_VERSION); p64(&o, m->fingerprint); p32(&o, h.l0); p32(&o, h.l1);
            p64(&o, w->free_mem ? w->free_mem(w->ctx) : 0);
            p64(&o, xj_model_layer_bytes(m, (int)h.l0, (int)h.l1));
            strncpy((char *)o, st->backend, 15); o += 16;
#ifdef __APPLE__
            if (!strcmp(st->backend, "metal")) strncpy((char *)o, xj_metal_device_name(), 63);
            else
#endif
            strncpy((char *)o, "CPU", 63);
            o += 64;
            xj_send_msg(fd, XJ_MSG_HELLO_OK, seq, out, (uint32_t)(o - out), NULL, 0);
            wlog(w, "就绪：第 %u–%u 层（%s）", h.l0, h.l1 - 1, st->backend);
        } else if (type == XJ_MSG_RESET) {
            if (st) st->reset(st);
            xj_send_msg(fd, XJ_MSG_ACK, seq, NULL, 0, NULL, 0);
        } else if (type == XJ_MSG_FORWARD) {
            if (!st) { send_error(fd, seq, "还没握手"); break; }
            if (len < 12) { send_error(fd, seq, "FORWARD 太短"); break; }
            uint32_t pos = g32(&in), T = g32(&in), want = g32(&in);
            const bool keep = want & XJ_WANT_KEEP;
            want &= 0xff;
            if (T < 1 || T > (uint32_t)st->max_batch || len != 12 + (uint64_t)T * E * 4) { send_error(fd, seq, "FORWARD 长度不对"); break; }
            // 投机解码猜错了：主机从更早的位置接着算，先退回去
            if (pos < (uint32_t)st->n_past && st->rollback(st, (int)pos, err, sizeof err)) { send_error(fd, seq, err); continue; }
            if (pos != (uint32_t)st->n_past) {
                snprintf(err, sizeof err, "位置对不上（主机 %u，从机 %d），请重新开始对话", pos, st->n_past);
                send_error(fd, seq, err);
                continue;
            }
            memcpy(x, in, (size_t)T * E * 4);
            st->keep = keep ? (int)T : 0;
            double t0 = now_ms();
            if (st->forward(st, x, (int)T, err, sizeof err)) { send_error(fd, seq, err); continue; }
            double dt = now_ms() - t0;
            busy += dt; n_tok += T;
            uint8_t hdr[16], *o = hdr;
            uint32_t n_out = want == XJ_WANT_ALL ? T : want == XJ_WANT_LAST ? 1 : 0;
            p32(&o, pos); p32(&o, n_out); p32(&o, want); p32(&o, (uint32_t)(dt * 1000));
            const float *src = want == XJ_WANT_LAST ? x + (size_t)(T - 1) * E : x;
            if (xj_send_msg(fd, XJ_MSG_FORWARD_OUT, seq, hdr, 16, src, n_out * E * 4)) break;
        } else if (type == XJ_MSG_PING) {
            xj_send_msg(fd, XJ_MSG_PONG, seq, buf, len > 65536 ? 65536 : len, NULL, 0);
        } else if (type == XJ_MSG_BYE) {
            break;
        } else {
            send_error(fd, seq, "不认识的消息");
            break;
        }
    }
    double wall = (now_ms() - t_start) / 1000;
    wlog(w, "%s 断开。算了 %llu 个 token，计算 %.1f 秒 / 连接 %.0f 秒", peer, (unsigned long long)n_tok, busy / 1000, wall);
    if (st) st->destroy(st);
    free(buf); free(x);
}

// 让从机的 Wi‑Fi 别睡。连着 iPhone 热点时，手机网卡一闲下来就进省电模式，热点发来的包要攒到下一次
// 唤醒（约 100 ms）才收得到，实测往返 116 ms，比从机算 10 层还慢。从机每 10 ms 往主机发一个 1 字节的 UDP
// （发到 discard 端口，主机不用收），网卡就一直醒着。只在有连接时发，流量约 3 KB/s。
typedef struct { struct sockaddr_storage to; socklen_t tl; volatile int run; pthread_t th; } waker;

static void *waker_main(void *p) {
    waker *k = p;
    int u = socket(k->to.ss_family, SOCK_DGRAM, 0);
    if (u < 0) return NULL;
    if (k->to.ss_family == AF_INET6) ((struct sockaddr_in6 *)&k->to)->sin6_port = htons(9);
    else ((struct sockaddr_in *)&k->to)->sin_port = htons(9);
    const char b = 0;
    while (k->run) {
        sendto(u, &b, 1, MSG_NOSIGNAL, (struct sockaddr *)&k->to, k->tl);
        struct timespec ts = { 0, 10 * 1000000 };
        nanosleep(&ts, NULL);
    }
    close(u);
    return NULL;
}

int xj_worker_serve(xj_worker *w, int port, char *err, size_t errlen) {
    int lf = socket(AF_INET6, SOCK_STREAM, 0);
    bool v6 = lf >= 0;
    if (!v6) lf = socket(AF_INET, SOCK_STREAM, 0);
    if (lf < 0) { snprintf(err, errlen, "建不了 socket"); return -1; }
    int one = 1, zero = 0;
    setsockopt(lf, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    int rc;
    if (v6) {
        setsockopt(lf, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof zero);  // 同时收 IPv4
        struct sockaddr_in6 a; memset(&a, 0, sizeof a);
        a.sin6_family = AF_INET6; a.sin6_port = htons((uint16_t)port); a.sin6_addr = in6addr_any;
        rc = bind(lf, (struct sockaddr *)&a, sizeof a);
    } else {
        struct sockaddr_in a; memset(&a, 0, sizeof a);
        a.sin_family = AF_INET; a.sin_port = htons((uint16_t)port); a.sin_addr.s_addr = htonl(INADDR_ANY);
        rc = bind(lf, (struct sockaddr *)&a, sizeof a);
    }
    if (rc || listen(lf, 2)) { snprintf(err, errlen, "端口 %d 被占用了", port); close(lf); return -1; }
    w->listen_fd = lf;
    w->conn_fd = -1;
    wlog(w, "等主机连接（端口 %d）", port);
    while (!w->stop) {
        struct sockaddr_storage ss; socklen_t sl = sizeof ss;
        int fd = accept(lf, (struct sockaddr *)&ss, &sl);
        if (fd < 0) { if (errno == EINTR) continue; break; }
        char peer[64] = "主机";
        char host[NI_MAXHOST];
        if (!getnameinfo((struct sockaddr *)&ss, sl, host, sizeof host, NULL, 0, NI_NUMERICHOST)) snprintf(peer, sizeof peer, "%.60s", host);
        sock_opts(fd);
        w->conn_fd = fd;
        waker *k = calloc(1, sizeof *k);
        bool waking = false;
        if (k) {
            memcpy(&k->to, &ss, sl); k->tl = sl; k->run = 1;
            waking = pthread_create(&k->th, NULL, waker_main, k) == 0;
        }
        serve_conn(w, fd, peer);
        if (waking) { k->run = 0; pthread_join(k->th, NULL); }
        free(k);
        w->conn_fd = -1;
        close(fd);
    }
    close(lf);
    w->listen_fd = -1;
    return 0;
}

void xj_worker_stop(xj_worker *w) {
    w->stop = 1;
    if (w->listen_fd >= 0) shutdown(w->listen_fd, SHUT_RDWR);
    if (w->conn_fd >= 0) shutdown(w->conn_fd, SHUT_RDWR);
}

// ================= 主机：远程 stage =================

typedef struct {
    int fd;
    char *host; int port; uint32_t pin;   // 重连用
    int n_ctx;
    uint32_t seq;
    void *buf; uint32_t cap;
    int pending;            // 已发出、还没收的 FORWARD 个数
    double last_net_ms;     // 最近一次往返里，扣掉从机计算的部分
    double sent_at;
} remote_impl;

static int expect(remote_impl *r, int want_type, uint32_t *len, char *err, size_t errlen) {
    uint32_t seq;
    int t = xj_recv_msg(r->fd, &r->buf, &r->cap, len, &seq, err, errlen);
    if (t < 0) return -1;
    if (t == XJ_MSG_ERROR) {
        snprintf(err, errlen, "从机：%.*s", (int)(*len > 200 ? 200 : *len), (const char *)r->buf);
        return -1;
    }
    if (t != want_type) { snprintf(err, errlen, "从机回了意外的消息 %d", t); return -1; }
    return 0;
}

int xj_remote_send(xj_stage *s, const float *x, int T, int want, char *err, size_t errlen) {
    if (s->keep) { want |= XJ_WANT_KEEP; s->keep = 0; }
    remote_impl *r = s->impl;
    if (T < 1 || T > s->max_batch) { snprintf(err, errlen, "一批 %d 个 token 超过上限", T); return -1; }
    if (r->fd < 0) { snprintf(err, errlen, "和从机的连接断了"); return -1; }
    uint8_t hdr[12], *o = hdr;
    p32(&o, (uint32_t)s->n_past); p32(&o, (uint32_t)T); p32(&o, (uint32_t)want);
    r->sent_at = now_ms();
    if (xj_send_msg(r->fd, XJ_MSG_FORWARD, ++r->seq, hdr, 12, x, (uint32_t)(T * s->m->hp.n_embd * 4))) {
        snprintf(err, errlen, "发给从机失败（连接断了）");
        return -1;
    }
    s->n_past += T;
    r->pending++;
    return 0;
}

int xj_remote_recv(xj_stage *s, float *x, int *T_out, uint32_t *compute_us, char *err, size_t errlen) {
    remote_impl *r = s->impl;
    uint32_t len;
    if (!r->pending) { snprintf(err, errlen, "没有在等的结果"); return -1; }
    r->pending--;
    if (expect(r, XJ_MSG_FORWARD_OUT, &len, err, errlen)) return -1;
    const uint8_t *in = r->buf;
    if (len < 16) { snprintf(err, errlen, "从机回包太短"); return -1; }
    g32(&in);
    uint32_t n = g32(&in);
    g32(&in);
    uint32_t us = g32(&in);
    const int E = s->m->hp.n_embd;
    if (len != 16 + (uint64_t)n * E * 4) { snprintf(err, errlen, "从机回包长度不对"); return -1; }
    if (x && n) memcpy(x, in, (size_t)n * E * 4);
    if (T_out) *T_out = (int)n;
    if (compute_us) *compute_us = us;
    r->last_net_ms = now_ms() - r->sent_at - us / 1000.0;
    return 0;
}

static int remote_forward(xj_stage *s, float *x, int T, char *err, size_t errlen) {
    if (xj_remote_send(s, x, T, XJ_WANT_ALL, err, errlen)) return -1;
    return xj_remote_recv(s, x, NULL, NULL, err, errlen);
}

static int remote_logits(xj_stage *s, const float *x, int T, float *logits, char *err, size_t errlen) {
    snprintf(err, errlen, "输出头在主机上算");
    return -1;
}

// 只记下位置；从机在收到下一条 FORWARD（起始位置更小）时自己退回存档
static int remote_rollback(xj_stage *s, int n_past, char *err, size_t errlen) {
    if (n_past > s->n_past || n_past < 0) { snprintf(err, errlen, "从机退不到位置 %d", n_past); return -1; }
    s->n_past = n_past;
    return 0;
}

static void remote_reset(xj_stage *s) {
    remote_impl *r = s->impl;
    char err[128]; uint32_t len;
    s->n_past = 0;
    if (r->fd < 0) { r->pending = 0; return; }  // 断着：下次 eval 会重连
    while (r->pending) { r->pending--; expect(r, XJ_MSG_FORWARD_OUT, &len, err, sizeof err); }
    if (xj_send_msg(r->fd, XJ_MSG_RESET, ++r->seq, NULL, 0, NULL, 0) || expect(r, XJ_MSG_ACK, &len, err, sizeof err)) {
        close(r->fd); r->fd = -1;  // 下次 eval 重连
    }
    s->n_past = 0;
}

static void remote_destroy(xj_stage *s) {
    if (!s) return;
    remote_impl *r = s->impl;
    if (r) {
        if (r->fd >= 0) { xj_send_msg(r->fd, XJ_MSG_BYE, ++r->seq, NULL, 0, NULL, 0); close(r->fd); }
        free(r->buf); free(r->host); free(r);
    }
    free(s);
}

bool xj_stage_is_remote(const xj_stage *s) { return s && s->forward == remote_forward; }

double xj_remote_ping(xj_stage *s) {
    remote_impl *r = s->impl;
    char err[128]; uint32_t len;
    if (r->fd < 0) return -1;
    double t0 = now_ms();
    uint8_t pay[64] = {0};
    if (xj_send_msg(r->fd, XJ_MSG_PING, ++r->seq, pay, sizeof pay, NULL, 0)) return -1;
    if (expect(r, XJ_MSG_PONG, &len, err, sizeof err)) return -1;
    return now_ms() - t0;
}

static int connect_to(const char *host, int port, char *err, size_t errlen) {
    struct addrinfo hints, *res = NULL, *ai;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char ps[16]; snprintf(ps, sizeof ps, "%d", port);
    if (getaddrinfo(host, ps, &hints, &res) || !res) { snprintf(err, errlen, "找不到 %s", host); return -1; }
    int fd = -1;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        struct timeval tv = { 5, 0 };
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd); fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) { snprintf(err, errlen, "连不上 %s:%d（从机开着吗？在同一个 Wi‑Fi 吗？）", host, port); return -1; }
    struct timeval tv0 = { 0, 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv0, sizeof tv0);
    // 从机第一次加载权重可能要几十秒，收超时放宽到 3 分钟
    struct timeval tv = { 180, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    sock_opts(fd);
    return fd;
}

// 发 HELLO、收 HELLO_OK，把从机报的层范围写回 s
static int handshake(xj_stage *s, int l0, int l1, xj_hello_ok *info, char *err, size_t errlen) {
    remote_impl *r = s->impl;
    uint8_t hello[36], *o = hello;
    p32(&o, XJ_PROTO_VERSION); p32(&o, r->pin); p64(&o, s->m->fingerprint);
    p32(&o, (uint32_t)l0); p32(&o, (uint32_t)l1); p32(&o, (uint32_t)r->n_ctx); p32(&o, (uint32_t)s->max_batch);
    uint32_t len;
    if (xj_send_msg(r->fd, XJ_MSG_HELLO, ++r->seq, hello, sizeof hello, NULL, 0)) { snprintf(err, errlen, "发给从机失败（连接断了）"); return -1; }
    if (expect(r, XJ_MSG_HELLO_OK, &len, err, errlen)) return -1;
    if (len < 116) { snprintf(err, errlen, "从机握手回包太短"); return -1; }
    xj_hello_ok tmp, *hi = info ? info : &tmp;
    const uint8_t *in = r->buf;
    hi->version = g32(&in); hi->fingerprint = g64(&in); hi->l0 = g32(&in); hi->l1 = g32(&in);
    hi->free_mem = g64(&in); hi->weight_bytes = g64(&in);
    memcpy(hi->backend, in, 16); hi->backend[15] = 0; in += 16;
    memcpy(hi->device, in, 64); hi->device[63] = 0;
    s->l0 = (int)hi->l0; s->l1 = (int)hi->l1;
    s->n_past = 0;
    r->pending = 0;
    // 握手完了收超时收紧到 1 分钟：Wi‑Fi 断了要能较快发现、去重连
    // （一块预填充在 A10 上也就一两秒，第一次读权重慢一点也够）
    struct timeval tv = { 60, 0 };
    setsockopt(r->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    return 0;
}

xj_stage *xj_remote_stage_new(const char *host, int port, uint32_t pin, const xj_model *m, int l0, int l1,
                              int n_ctx, int max_batch, xj_hello_ok *info, char *err, size_t errlen) {
    int fd = connect_to(host, port, err, errlen);
    if (fd < 0) return NULL;
    xj_stage *s = calloc(1, sizeof(*s));
    remote_impl *r = calloc(1, sizeof(*r));
    r->fd = fd;
    r->host = strdup(host); r->port = port; r->pin = pin; r->n_ctx = n_ctx;
    s->m = m; s->l0 = l0; s->l1 = l1; s->n_ctx = n_ctx; s->max_batch = max_batch;
    s->backend = "remote";
    s->forward = remote_forward; s->logits = remote_logits; s->reset = remote_reset; s->destroy = remote_destroy;
    s->rollback = remote_rollback;
    s->impl = r;
    if (handshake(s, l0, l1, info, err, errlen)) { remote_destroy(s); return NULL; }
    return s;
}

int xj_remote_reconnect(xj_stage *s, char *err, size_t errlen) {
    remote_impl *r = s->impl;
    if (r->fd >= 0) { close(r->fd); r->fd = -1; }
    r->pending = 0;
    s->n_past = 0;
    int fd = connect_to(r->host, r->port, err, errlen);
    if (fd < 0) return -1;
    r->fd = fd;
    const int l0 = s->l0, l1 = s->l1;
    if (handshake(s, l0, l1, NULL, err, errlen)) { close(r->fd); r->fd = -1; return -1; }
    if (s->l0 != l0 || s->l1 != l1) {  // 不会发生：HELLO 里明确要了这几层
        snprintf(err, errlen, "从机重连后层范围变了");
        close(r->fd); r->fd = -1;
        return -1;
    }
    return 0;
}

// ================= 主机：流水线 =================

int xj_pipeline_init(xj_pipeline *p, const xj_model *m, xj_stage *a, xj_stage *r, xj_stage *b) {
    memset(p, 0, sizeof(*p));
    p->m = m; p->a = a; p->r = r; p->b = b;
    p->max_batch = a->max_batch;
    if (r && r->max_batch < p->max_batch) p->max_batch = r->max_batch;
    if (b && b->max_batch < p->max_batch) p->max_batch = b->max_batch;
    p->x = malloc(sizeof(float) * m->hp.n_embd * p->max_batch);
    p->xr = malloc(sizeof(float) * m->hp.n_embd * p->max_batch);
    p->reconnect_tries = 5;
    return p->x && p->xr ? 0 : -1;
}

void xj_pipeline_free(xj_pipeline *p) {
    free(p->x); free(p->xr); free(p->hist); free(p->scratch_logits);
    p->x = p->xr = p->scratch_logits = NULL;
    p->hist = NULL; p->n_hist = p->hist_cap = 0;
}

int xj_pipeline_reset(xj_pipeline *p, char *err, size_t errlen) {
    p->n_hist = 0;
    p->a->reset(p->a);
    if (p->r) p->r->reset(p->r);
    if (p->b) p->b->reset(p->b);
    return 0;
}

static xj_stage *head_of(xj_pipeline *p) { return p->b ? p->b : p->a; }

// 流水线预填充：从机算第 c 块的时候，主机同时算第 c+1 块的前半段。
// 任何时候最多一块在从机上，两边都不会因为缓冲区满了互相卡住。
// nlog：最后几个 token 要 logits（普通 1 个；验证时整批）。hid：每个 token 的最后一层输出（可以为空）。
// keep：投机解码验证（整批一块，每段都留存档）。
// 从机 / 网络出的错会置 p->remote_failed，外面据此决定要不要重连。
static int eval_once(xj_pipeline *p, const int32_t *tok, int n, float *logits, int nlog, float *hid, bool keep,
                     char *err, size_t errlen) {
    const int E = p->m->hp.n_embd, B = p->max_batch;
    const bool b_layers = p->b && p->b->l1 > p->b->l0;
    double t;
    if (n <= 0) { snprintf(err, errlen, "没有 token"); return -1; }
    if (keep && n > B) { snprintf(err, errlen, "验证一批 %d 个超过上限 %d", n, B); return -1; }
    if (nlog < 1) nlog = 1;

    if (!p->r) {
        for (int i = 0; i < n; i += B) {
            int T = n - i < B ? n - i : B;
            for (int k = 0; k < T; k++) xj_embed(p->m, tok[i + k], p->x + (size_t)k * E);
            t = now_ms();
            if (keep) { p->a->keep = T; if (p->b && p->b->l1 > p->b->l0) p->b->keep = T; }
            if (p->a->forward(p->a, p->x, T, err, errlen)) return -1;
            if (p->b && p->b->forward(p->b, p->x, T, err, errlen)) return -1;
            p->t_local += now_ms() - t;
            if (hid) memcpy(hid + (size_t)i * E, p->x, sizeof(float) * T * E);
            if (i + T == n) {
                const int nl = nlog < T ? nlog : T;
                t = now_ms();
                if (head_of(p)->logits(head_of(p), p->x + (size_t)(T - nl) * E, nl, logits, err, errlen)) return -1;
                p->t_local += now_ms() - t;
            }
        }
        return 0;
    }

    if (!p->b) { snprintf(err, errlen, "有从机时主机后半段（带输出头）不能为空"); return -1; }
    const bool all = b_layers || hid || nlog > 1;
    int prevT = 0, prevI = 0;  // 在从机上的那一块有几个 token（0 = 没有）、从第几个开始
    for (int i = 0;;) {
        const int T = i < n ? (n - i < B ? n - i : B) : 0;
        if (T) {
            for (int k = 0; k < T; k++) xj_embed(p->m, tok[i + k], p->x + (size_t)k * E);
            t = now_ms();
            if (keep) p->a->keep = T;
            if (p->a->forward(p->a, p->x, T, err, errlen)) return -1;
            p->t_local += now_ms() - t;
        }
        if (prevT) {
            int got = 0; uint32_t us = 0;
            t = now_ms();
            if (xj_remote_recv(p->r, p->xr, &got, &us, err, errlen)) { p->remote_failed = true; return -1; }
            p->t_remote += us / 1000.0;
            p->t_net += now_ms() - t;  // 主机在这里干等的时间（含从机还没算完的部分）
        }
        if (T) {
            const bool last = i + T >= n;
            const int want = all ? XJ_WANT_ALL : (last ? XJ_WANT_LAST : XJ_WANT_NONE);
            if (keep) p->r->keep = T;
            if (xj_remote_send(p->r, p->x, T, want, err, errlen)) { p->remote_failed = true; return -1; }
        }
        if (prevT) {
            // 上一块从机的结果过后半段（要所有 token 的结果，后半段的 KV 缓存才完整）
            const int rows = all ? prevT : 1;
            t = now_ms();
            if (keep && b_layers) p->b->keep = rows;
            if (b_layers && p->b->forward(p->b, p->xr, rows, err, errlen)) return -1;
            if (hid) memcpy(hid + (size_t)prevI * E, p->xr, sizeof(float) * rows * E);
            if (!T) {
                const int nl = nlog < rows ? nlog : rows;
                if (p->b->logits(p->b, p->xr + (size_t)(rows - nl) * E, nl, logits, err, errlen)) return -1;
            }
            p->t_local += now_ms() - t;
        }
        if (!T) break;
        prevT = T;
        prevI = i;
        i += T;
    }
    return 0;
}

static void pstatus(xj_pipeline *p, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void pstatus(xj_pipeline *p, const char *fmt, ...) {
    if (!p->on_status) return;
    char b[384];
    va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
    p->on_status(p->status_ctx, b);
}

static void sleep_ms(int ms) {
    struct timespec t = { ms / 1000, (long)(ms % 1000) * 1000000L };
    while (nanosleep(&t, &t) && errno == EINTR) {}
}

// 重连从机，所有段清空，再把 hist 里的 token 全部重新过一遍
static int recover(xj_pipeline *p, char *err, size_t errlen) {
    if (xj_remote_reconnect(p->r, err, errlen)) { p->remote_failed = true; return -1; }
    p->a->reset(p->a);
    p->b->reset(p->b);
    if (!p->n_hist) return 0;
    if (!p->scratch_logits) p->scratch_logits = malloc(sizeof(float) * p->m->hp.n_vocab);
    if (!p->scratch_logits) { snprintf(err, errlen, "内存不够"); return -1; }
    pstatus(p, "已重连，正在重放之前的 %d 个 token……", p->n_hist);
    p->remote_failed = false;
    return eval_once(p, p->hist, p->n_hist, p->scratch_logits, 1, NULL, false, err, errlen);
}

static int eval_retry(xj_pipeline *p, const int32_t *tok, int n, float *logits, int nlog, float *hid, bool keep,
                      char *err, size_t errlen) {
    int attempt = 0;
    for (;;) {
        p->remote_failed = false;
        if (!eval_once(p, tok, n, logits, nlog, hid, keep, err, errlen)) break;
        // 不是从机的问题（比如上下文满了），或者不让重连：直接报错
        for (;;) {
            if (!p->r || !p->remote_failed || attempt >= p->reconnect_tries) return -1;
            attempt++;
            pstatus(p, "从机出错：%s。%d 秒后第 %d 次重连……", err, attempt < 3 ? attempt : 3, attempt);
            sleep_ms(1000 * (attempt < 3 ? attempt : 3));
            if (!recover(p, err, errlen)) break;
        }
        p->n_reconnects++;
        pstatus(p, "从机恢复了，接着算");
    }
    // 记下来，断线后重放用
    if (p->r) {
        if (p->n_hist + n > p->hist_cap) {
            int cap = (p->n_hist + n) * 2;
            int32_t *nh = realloc(p->hist, sizeof(int32_t) * cap);
            if (!nh) { snprintf(err, errlen, "内存不够"); return -1; }
            p->hist = nh; p->hist_cap = cap;
        }
        memcpy(p->hist + p->n_hist, tok, sizeof(int32_t) * n);
        p->n_hist += n;
    }
    return 0;
}

int xj_pipeline_eval(xj_pipeline *p, const int32_t *tok, int n, float *logits, float *hid, char *err, size_t errlen) {
    return eval_retry(p, tok, n, logits, 1, hid, false, err, errlen);
}

int xj_pipeline_verify(xj_pipeline *p, const int32_t *tok, int n, float *logits, float *hid, char *err, size_t errlen) {
    return eval_retry(p, tok, n, logits, n, hid, true, err, errlen);
}

int xj_pipeline_rollback(xj_pipeline *p, int n_past, char *err, size_t errlen) {
    if (p->a->rollback(p->a, n_past, err, errlen)) return -1;
    if (p->r && p->r->rollback(p->r, n_past, err, errlen)) return -1;
    if (p->b && p->b->l1 > p->b->l0 && p->b->rollback(p->b, n_past, err, errlen)) return -1;
    if (p->r && p->n_hist > n_past) p->n_hist = n_past;
    return 0;
}
