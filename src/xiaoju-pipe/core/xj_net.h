// 小橘双机推理：两台手机之间的协议（局域网 TCP，小端）。
//
// 每条消息 = 16 字节头 + 内容：
//   u32 magic 'XJP1' | u16 type | u16 flags | u32 len（内容字节数） | u32 seq
//
// 主机 → 从机                               从机 → 主机
//   HELLO   版本、模型指纹、层范围、配对码        HELLO_OK  设备名、后端、可用内存
//   RESET   清空 KV 缓存和递推状态（新对话）       ACK
//   FORWARD 起始位置、T、要哪些输出、T×n_embd 个 float   FORWARD_OUT 过完从机那几层的隐藏向量
//   PING    任意内容                               PONG 原样返回（测往返延迟）
//   BYE                                            ERROR 一段中文原因
#pragma once
#include "xj_stage.h"

#ifdef __cplusplus
extern "C" {
#endif

#define XJ_PROTO_VERSION 2   // 2：投机解码（FORWARD 带存档标记，位置往回退 = 回滚）
#define XJ_DEFAULT_PORT  47321
#define XJ_MAGIC 0x31504A58u  // "XJP1"

enum {
    XJ_MSG_HELLO = 1, XJ_MSG_HELLO_OK, XJ_MSG_RESET, XJ_MSG_ACK, XJ_MSG_FORWARD, XJ_MSG_FORWARD_OUT,
    XJ_MSG_ERROR, XJ_MSG_PING, XJ_MSG_PONG, XJ_MSG_BYE,
};

// FORWARD 的 want：从机回传哪些 token 的结果。低 8 位是下面三种之一，再或上 XJ_WANT_KEEP：
// 这批每个 token 之后的状态都留存档。下一条 FORWARD 的起始位置比从机当前位置小时，从机先退回那里（只能退到存档里）。
enum { XJ_WANT_ALL = 0, XJ_WANT_LAST = 1, XJ_WANT_NONE = 2, XJ_WANT_KEEP = 0x100 };

typedef struct {
    uint32_t version;
    uint32_t pin;          // 从机屏幕上显示的配对码，对不上就拒绝
    uint64_t fingerprint;  // 模型文件结构指纹（xj_model.fingerprint）
    uint32_t l0, l1, n_ctx, max_batch;
} xj_hello;

typedef struct {
    uint32_t version;
    uint64_t fingerprint;
    uint32_t l0, l1;
    uint64_t free_mem;     // 从机还能用多少内存（字节，0 = 不知道）
    uint64_t weight_bytes; // 这几层权重多大
    char     backend[16];  // "metal" / "cpu"
    char     device[64];   // 比如 "Apple A10 GPU"
} xj_hello_ok;

typedef struct {
    uint32_t pos, n_tokens, want, compute_us;  // compute_us 只在回包里有：从机算了多久
} xj_fwd_hdr;

// ---- 底层收发 ----
int  xj_send_msg(int fd, uint16_t type, uint32_t seq, const void *a, uint32_t alen, const void *b, uint32_t blen);
// 收一条消息，内容放进 *buf（按需扩大）。返回 type，出错返回 -1
int  xj_recv_msg(int fd, void **buf, uint32_t *cap, uint32_t *len, uint32_t *seq, char *err, size_t errlen);

// ---- 从机 ----
typedef struct {
    const xj_model *model;
    int have_l0, have_l1;                 // 这台手机上有哪些层（主机 HELLO 里层范围填 0,0 就用这个）
    uint32_t pin;                         // 0 = 不要配对码
    int max_ctx, max_batch_limit;
    // 按层范围建一个 stage（iOS 上建 Metal 的，命令行里可以选 CPU）
    xj_stage *(*make_stage)(void *ctx, const xj_model *m, int l0, int l1, int n_ctx, int max_batch, char *err, size_t errlen);
    uint64_t (*free_mem)(void *ctx);
    void (*log)(void *ctx, const char *msg);   // 状态文字，给界面显示
    void *ctx;
    volatile int stop;                    // 置 1 后 serve 返回
    int listen_fd, conn_fd;
} xj_worker;

// 在 port 上等主机连，一次服务一台。阻塞直到 stop。
int  xj_worker_serve(xj_worker *w, int port, char *err, size_t errlen);
void xj_worker_stop(xj_worker *w);

// ---- 主机 ----
// 连到从机，握手后得到一个「远程 stage」，用法和本地 stage 一样。
// l0 = l1 = 0：让从机用它准备好的那几层（握手后 stage 的 l0/l1 就是从机报的范围）。
xj_stage *xj_remote_stage_new(const char *host, int port, uint32_t pin, const xj_model *m, int l0, int l1,
                              int n_ctx, int max_batch, xj_hello_ok *info, char *err, size_t errlen);
// 预填充流水线用：只发不等 / 再收回来
int  xj_remote_send(xj_stage *s, const float *x, int T, int want, char *err, size_t errlen);
int  xj_remote_recv(xj_stage *s, float *x, int *T_out, uint32_t *compute_us, char *err, size_t errlen);
// 往返延迟（毫秒），失败返回负数
double xj_remote_ping(xj_stage *s);
// 断线后重新连上同一台从机、按原来的层范围再握手一次。成功后从机那边是空的（n_past = 0），
// 调用方要把之前的 token 重新喂一遍（xj_pipeline_eval 会自动做）。
int  xj_remote_reconnect(xj_stage *s, char *err, size_t errlen);
bool xj_stage_is_remote(const xj_stage *s);

// 主机上的一整条流水线：本地 [0,s1) → 从机 [s1,s2) → 本地 [s2,L) + 输出头
typedef struct {
    const xj_model *m;
    xj_stage *a, *r, *b;       // a、b 本地；r 远程（可以为空：整个模型都在本地）
    float *x;                  // [max_batch][n_embd]
    float *xr;                 // 流水线里转一手的缓冲
    int max_batch;
    // 统计（毫秒）
    double t_local, t_remote, t_net;

    // 断线重连：Wi‑Fi 抖一下、从机 App 被切到后台再切回来，主机自动重连，
    // 把这次对话已经喂过的 token 重新过一遍从机（重建它的 KV 缓存和递推状态），然后接着算。
    int32_t *hist; int n_hist, hist_cap;  // 已经喂进去的 token
    float *scratch_logits;                // 重放时用的临时 logits
    int reconnect_tries;                  // 每次出错最多重连几次（0 = 不重连，直接报错）
    int n_reconnects;                     // 总共重连成功了几次（给界面显示）
    bool remote_failed;                   // 内部用：这次失败是不是从机 / 网络的问题
    void (*on_status)(void *ctx, const char *msg);  // 「从机断了，正在重连……」这类提示
    void *status_ctx;
} xj_pipeline;

// 默认 reconnect_tries = 5；不想自动重连就在 init 之后改成 0
int  xj_pipeline_init(xj_pipeline *p, const xj_model *m, xj_stage *a, xj_stage *r, xj_stage *b);
// 喂一串 token（预填充或一个新词），最后一个 token 的 logits 写到 logits。
// hid 不为空时，每个 token 过完最后一层（未过 output_norm）的隐藏向量写到 hid[n][n_embd]（MTP 要用）。
// 从机断了会自动重连并重放之前的 token（见上面），重连不上才返回 -1。
int  xj_pipeline_eval(xj_pipeline *p, const int32_t *tokens, int n, float *logits, float *hid, char *err, size_t errlen);
// 投机解码的验证：n（≤ max_batch）个 token 一批过完整条流水线，每个 token 的 logits 都要（logits[n][n_vocab]），
// 隐藏向量写到 hid[n][n_embd]；每段都给每个 token 留状态存档，之后可以用 xj_pipeline_rollback 退回。
int  xj_pipeline_verify(xj_pipeline *p, const int32_t *tokens, int n, float *logits, float *hid, char *err, size_t errlen);
// 退回到 n_past（猜错的字作废）。只能退到上一次 verify 的那批里。
int  xj_pipeline_rollback(xj_pipeline *p, int n_past, char *err, size_t errlen);
int  xj_pipeline_reset(xj_pipeline *p, char *err, size_t errlen);
void xj_pipeline_free(xj_pipeline *p);

#ifdef __cplusplus
}
#endif
