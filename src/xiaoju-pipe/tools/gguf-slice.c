// 从完整模型里只抠出 [l0, l1) 层，写成同样大小的稀疏文件（没用到的地方是空洞，不占磁盘）。
// iPhone 从机 App 用 HTTP Range 下载做的是同一件事，这个工具用来在电脑上测试 / 给从机拷文件。
//   gguf-slice 完整.gguf 输出.gguf 12:20
#include "../core/xj_model.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int copy_range(int in, int out, uint64_t lo, uint64_t hi) {
    static char buf[1 << 20];
    while (lo < hi) {
        size_t n = hi - lo < sizeof buf ? (size_t)(hi - lo) : sizeof buf;
        ssize_t k = pread(in, buf, n, (off_t)lo);
        if (k <= 0 || pwrite(out, buf, (size_t)k, (off_t)lo) != k) return -1;
        lo += (uint64_t)k;
    }
    return 0;
}

int main(int argc, char **argv) {
    int l0, l1;
    if (argc < 4 || sscanf(argv[3], "%d:%d", &l0, &l1) != 2) { fprintf(stderr, "用法: gguf-slice 完整.gguf 输出.gguf 12:20\n"); return 1; }
    char err[256];
    gguf_file *g = gguf_open_header(argv[1], err, sizeof err);
    xj_model *m = g ? xj_model_from_gguf(g, err, sizeof err) : NULL;
    if (!m) { fprintf(stderr, "%s\n", err); return 1; }
    uint64_t r[512][2];
    int n = xj_model_ranges(m, l0, l1, false, r, 512);
    int in = open(argv[1], O_RDONLY), out = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (in < 0 || out < 0 || ftruncate(out, (off_t)g->size)) { fprintf(stderr, "打不开文件\n"); return 1; }
    uint64_t total = g->data_off;
    if (copy_range(in, out, 0, g->data_off)) { fprintf(stderr, "复制头部失败\n"); return 1; }
    for (int i = 0; i < n; i++) {
        if (copy_range(in, out, r[i][0], r[i][1])) { fprintf(stderr, "复制失败\n"); return 1; }
        total += r[i][1] - r[i][0];
    }
    fprintf(stderr, "第 %d–%d 层：%d 段，实际写入 %.0f MB（完整文件 %.0f MB）\n", l0, l1 - 1, n, total / 1048576.0, g->size / 1048576.0);
    close(in); close(out);
    xj_model_free(m);
    return 0;
}
