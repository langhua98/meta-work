// 分词对照用：从标准输入读一段文字，按模型里的词表分词，输出 token id（空格隔开）。
//   xjpipe-tok 模型.gguf < 文字.txt
// tests/tok_check.py 拿它和官方分词器（Hugging Face tokenizers）的结果逐条比。
#include "../core/gguf.h"
#include "../core/xj_tok.h"

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "用法: xjpipe-tok 模型.gguf < 文字.txt\n"); return 1; }
    char err[256];
    gguf_file *g = gguf_open_header(argv[1], err, sizeof err);
    if (!g) { fprintf(stderr, "%s\n", err); return 1; }
    xj_tok *t = xj_tok_new(g, err, sizeof err);
    if (!t) { fprintf(stderr, "%s\n", err); return 1; }
    size_t cap = 1 << 16, n = 0;
    char *buf = malloc(cap);
    for (size_t k; (k = fread(buf + n, 1, cap - n - 1, stdin)) > 0;) {
        n += k;
        if (n + 1 >= cap) buf = realloc(buf, cap *= 2);
    }
    buf[n] = 0;
    int max = (int)n + 16;
    int32_t *ids = malloc(sizeof(int32_t) * max);
    int m = xj_tok_encode(t, buf, ids, max);
    for (int i = 0; i < m; i++) printf(i ? " %d" : "%d", ids[i]);
    printf("\n");
    return 0;
}
