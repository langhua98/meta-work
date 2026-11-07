// 小橘双机：给 Swift 用的薄封装（C 接口，Swift 通过桥接头直接调用）。
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*xjg_log_fn)(void *ctx, const char *msg);
// 返回 1 表示停止生成
typedef int (*xjg_piece_fn)(void *ctx, const char *utf8, int len);

typedef struct {
    int n_layer, n_embd;
    double layer_mb[128];       // 每层权重多少 MB
    double io_mb;               // embedding + 输出头
    double out_mb;              // 输出头（和 embedding 共用时就是 embedding），主机算每个字都要整个读一遍
    uint64_t total_bytes;
} xjg_model_info;

// ---- 下载规划（从机只下载自己那几层）----
// 给一段文件开头的字节，算出 [l0,l1) 层要下载的字节范围。头部不够时返回 0 并把 *need 设成需要的字节数。
// 成功返回范围个数（ranges 每项 [起点, 终点)），出错返回 -1。
int xjg_plan(const uint8_t *head, uint64_t len, int l0, int l1, uint64_t (*ranges)[2], int max,
             uint64_t *need, uint64_t *data_off, xjg_model_info *info, char *err, int errlen);
// 读本地文件的结构（不映射权重）
int xjg_model_info_of(const char *path, xjg_model_info *info, char *err, int errlen);

// ---- 从机 ----
void *xjg_worker_new(const char *path, int l0, int l1, uint32_t pin, xjg_log_fn log, void *ctx, char *err, int errlen);
int   xjg_worker_run(void *w, int port, char *err, int errlen);   // 阻塞，放后台线程
void  xjg_worker_stop(void *w);
void  xjg_worker_free(void *w);
uint64_t xjg_free_memory(void);                                    // 这台手机现在还能用多少内存
const char *xjg_gpu_name(void);

// ---- 主机 ----
typedef struct {
    int    prompt_tokens, gen_tokens;
    double prefill_s, gen_s;
    double local_ms, remote_ms, wait_ms;   // 每个生成 token 的平均耗时
    int    n_past, n_ctx;
    int    reconnects;                     // 连上以来从机断线后自动恢复了几次
    int    spec_steps, spec_drafted, spec_accepted;   // 投机解码：几步、猜了几个、猜中几个
    double draft_ms;                       // MTP 猜字平均每步多少毫秒
} xjg_stats;

// worker_host 为空：整个模型都在本机跑。s1 = s2 = 0：用从机准备好的层。
// mtp_path：带 MTP 头的 GGUF（可以只下了文件头和 MTP 层），draft > 0 时用它做投机解码，每步猜 draft 个字；
// 为空或 draft = 0 就不投机。info 里写一句「从机 xxx，第 a–b 层」之类的说明。
void *xjg_host_new(const char *path, const char *worker_host, int port, uint32_t pin, int s1, int s2,
                   int n_ctx, const char *mtp_path, int draft, char *info, int infolen, char *err, int errlen);
// 带 MTP 的 GGUF 文件头 → MTP 层的字节范围 [lo, hi)。头不够长时返回 0 并在 need 里给出要多少字节；出错 -1。
int xjg_mtp_plan(const uint8_t *head, uint64_t len, uint64_t *lo, uint64_t *hi, uint64_t *need, uint64_t *data_off,
                 char *err, int errlen);
// 发一句话，流式回调吐出回答的文字。返回 0 成功，-1 出错（err 里有原因）。
int   xjg_host_chat(void *h, const char *user, float temperature, int max_tokens,
                    xjg_piece_fn cb, void *ctx, xjg_stats *stats, char *err, int errlen);
int   xjg_host_reset(void *h, char *err, int errlen);   // 新对话
double xjg_host_ping(void *h);                           // 到从机的往返延迟（毫秒），没有从机返回 -1
// 从机断线时的提示（「从机出错……第 1 次重连」「已重连，正在重放……」），在 chat 的线程里回调
void  xjg_host_set_status(void *h, xjg_log_fn fn, void *ctx);
void  xjg_host_free(void *h);

// 本机的局域网 IP（给从机界面显示），多个用换行隔开
void xjg_local_ips(char *buf, int len);

#ifdef __cplusplus
}
#endif
