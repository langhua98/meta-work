// 小橘双机推理：命令行工具用的分词器（见 xj_tok.c 开头的说明）
#pragma once
#include "gguf.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct xj_tok xj_tok;

xj_tok *xj_tok_new(const gguf_file *g, char *err, size_t errlen);
void    xj_tok_free(xj_tok *t);
// 文字 → token；<|im_start|> 这类特殊词直接认出来。返回 token 个数
int     xj_tok_encode(const xj_tok *t, const char *text, int32_t *out, int max);
// token → 原始字节（可能是半个汉字，调用方自己拼）
int     xj_tok_piece(const xj_tok *t, int32_t id, char *out, int max);
int32_t xj_tok_find(const xj_tok *t, const char *s);

#ifdef __cplusplus
}
#endif
