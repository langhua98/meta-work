// 打印 GGUF 的元数据（数组只打印长度）和张量表，看模型结构用。
#include "../core/gguf.h"
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "用法: gguf-dump 模型.gguf [张量名前缀]\n"); return 1; }
    char err[256];
    gguf_file *f = gguf_open(argv[1], err, sizeof err);
    if (!f) { fprintf(stderr, "%s\n", err); return 1; }
    printf("kv=%llu tensors=%llu data_off=%llu align=%u\n", (unsigned long long)f->n_kv,
           (unsigned long long)f->n_tensors, (unsigned long long)f->data_off, f->alignment);
    for (uint64_t i = 0; i < f->n_kv; i++) {
        const gguf_kv *kv = &f->kv[i];
        printf("  %s = ", kv->key);
        uint32_t u; float x; const char *s; uint64_t n;
        if (kv->type == GGUF_ARR) printf("[array type=%u n=%llu]", kv->arr_type, (unsigned long long)kv->arr_n);
        else if (kv->type == GGUF_STR && gguf_get_str(f, kv->key, &s, &n)) printf("\"%.*s\"", (int)(n > 80 ? 80 : n), s);
        else if ((kv->type == GGUF_F32 || kv->type == GGUF_F64) && gguf_get_f32(f, kv->key, &x)) printf("%g", x);
        else if (gguf_get_u32(f, kv->key, &u)) printf("%u", u);
        printf("\n");
        if (kv->type == GGUF_ARR && kv->arr_type != GGUF_STR && kv->arr_n <= 64) {
            printf("      ");
            for (uint64_t k = 0; k < kv->arr_n; k++) { gguf_get_arr_u32(f, kv->key, k, &u); printf("%u ", u); }
            printf("\n");
        }
    }
    const char *pre = argc > 2 ? argv[2] : "";
    for (uint64_t i = 0; i < f->n_tensors; i++) {
        const gguf_tensor *t = &f->tensors[i];
        if (strncmp(t->name, pre, strlen(pre))) continue;
        printf("%-36s %-5s [%lld %lld %lld] %.2f MB\n", t->name, xj_type_name(t->type),
               (long long)t->ne[0], (long long)t->ne[1], (long long)t->ne[2], t->nbytes / 1048576.0);
    }
    gguf_close(f);
    return 0;
}
