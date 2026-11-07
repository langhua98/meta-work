// 小橘双机推理：投机解码（MTP）。
//
// Qwen3.5 训练时自带一个 MTP（多 token 预测）层：拿主干最后一层的输出 + 下一个字，猜再下一个字。
// 每一步：MTP 连猜 k 个字（只在主机上算一层，很便宜）→ 把「这一个字 + k 个猜的字」一批送进整条流水线验证
// （两台手机都只读一遍权重，和算一个字差不多慢）→ 从头比对，猜对几个就一次出几个字，第一个猜错的位置换成主干自己采样的字。
// 输出和不投机时完全同分布（贪心时一字不差）：每个字都是主干在那个位置采样出来的，MTP 只决定一批能走多远。
// 猜错时用每段的状态存档退回去（线性注意力层是递推的，不能像 KV 缓存那样直接截断）。
#pragma once
#include "xj_net.h"

#ifdef __cplusplus
extern "C" {
#endif

#define XJ_SPEC_MAXK 4

// 采样：从 logits[n_vocab] 选一个字
typedef int (*xj_sample_fn)(void *ctx, const float *logits, int n_vocab);

typedef struct {
    xj_pipeline *p;
    xj_stage *mtp;          // MTP 段（主机上）；NULL = 不投机，一次一个字
    const xj_model *m;
    int k;                  // 每步最多猜几个字
    float *last_logits;     // 主干最后一个位置的 logits
    int forced;             // 上一步验证时已经采样好的下一个字（-1 = 从 last_logits 采样）
    // 还没喂给 MTP 的位置（连续，从 mtp->n_past 开始）：主干隐藏向量 + 这个位置后面那个字（-1 = 还不知道）
    float *ph; int32_t *pt; int n_ph, ph_cap;
    float *logits;          // [k+1][n_vocab]
    float *hid;             // 预填充 / 验证时每个位置的隐藏向量
    int hid_cap;
    float *mx;              // MTP 输入 [max_batch][2*n_embd]
    float *mlog;            // MTP 的 logits
    // 主干隐藏向量 / MTP 自己的输出喂回 MTP 前要不要先过 norm（output_norm / shared_head_norm）。
    // 默认按 CI 实测猜中率最高的选（环境变量 XJ_MTP_MAIN_POST、XJ_MTP_CHAIN_POST = 0/1 可以改）
    bool main_post, chain_post;
    // 测试用：知道正确答案时拿它当「猜的字」（每隔 oracle_miss 个故意猜错一个），把全猜对 / 猜对一半的路径都走到
    const int32_t *oracle; int n_oracle, oracle_miss;
    long n_gen;             // 已经出了几个字（对 oracle 用）
    // 统计
    long n_steps, n_drafted, n_accepted;
    long acc_at[XJ_SPEC_MAXK];   // 第 j 个猜的字被接受了几次
    double t_draft_ms;      // MTP 猜字花的时间
} xj_spec;

int  xj_spec_init(xj_spec *sp, xj_pipeline *p, xj_stage *mtp, int k);
void xj_spec_free(xj_spec *sp);
void xj_spec_reset(xj_spec *sp);   // 新对话（流水线另外 reset）
// 喂一串已知的字（提示词），主干和 MTP 都过一遍
int  xj_spec_feed(xj_spec *sp, const int32_t *tok, int n, char *err, size_t errlen);
// 生成：出 1..k+1 个字写到 out，返回个数。最后一个字是 eos / eot 时它没有喂进模型（和普通解码一样，由调用方收尾）。
// room：上下文和长度限制下最多还能出几个字（≥ 1）。
int  xj_spec_next(xj_spec *sp, xj_sample_fn sample, void *sctx, int32_t *out, int room, char *err, size_t errlen);

#ifdef __cplusplus
}
#endif
