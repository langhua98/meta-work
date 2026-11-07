// 小橘双机推理：GGUF 文件读取。格式见 ggml 的 docs/gguf.md（v2 / v3）。
#include "gguf.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int xj_type_block(uint32_t type, int *block_bytes) {
    int n = 0, b = 0;
    switch (type) {
        case XJ_F32:  n = 1;   b = 4;   break;
        case XJ_F16:  n = 1;   b = 2;   break;
        case XJ_BF16: n = 1;   b = 2;   break;
        case XJ_Q4_0: n = 32;  b = 18;  break;
        case XJ_Q4_1: n = 32;  b = 20;  break;
        case XJ_Q5_0: n = 32;  b = 22;  break;
        case XJ_Q5_1: n = 32;  b = 24;  break;
        case XJ_Q8_0: n = 32;  b = 34;  break;
        case XJ_Q2_K: n = 256; b = 84;  break;
        case XJ_Q3_K: n = 256; b = 110; break;
        case XJ_Q4_K: n = 256; b = 144; break;
        case XJ_Q5_K: n = 256; b = 176; break;
        case XJ_Q6_K: n = 256; b = 210; break;
        default: break;
    }
    if (block_bytes) *block_bytes = b;
    return n;
}

const char *xj_type_name(uint32_t type) {
    switch (type) {
        case XJ_F32: return "F32";   case XJ_F16: return "F16";   case XJ_BF16: return "BF16";
        case XJ_Q4_0: return "Q4_0"; case XJ_Q4_1: return "Q4_1"; case XJ_Q5_0: return "Q5_0";
        case XJ_Q5_1: return "Q5_1"; case XJ_Q8_0: return "Q8_0"; case XJ_Q2_K: return "Q2_K";
        case XJ_Q3_K: return "Q3_K"; case XJ_Q4_K: return "Q4_K"; case XJ_Q5_K: return "Q5_K";
        case XJ_Q6_K: return "Q6_K";
        default: return "?";
    }
}

uint64_t xj_row_bytes(uint32_t type, int64_t n) {
    int bb = 0;
    int bn = xj_type_block(type, &bb);
    if (bn == 0) return 0;
    return (uint64_t)(n / bn) * (uint64_t)bb;
}

// ---- 解析 ----

typedef struct {
    const uint8_t *p, *end;
    bool short_read;
} rd;

static bool rd_need(rd *r, uint64_t n) {
    if ((uint64_t)(r->end - r->p) < n) { r->short_read = true; return false; }
    return true;
}
static bool rd_u32(rd *r, uint32_t *v) { if (!rd_need(r, 4)) return false; memcpy(v, r->p, 4); r->p += 4; return true; }
static bool rd_u64(rd *r, uint64_t *v) { if (!rd_need(r, 8)) return false; memcpy(v, r->p, 8); r->p += 8; return true; }
static bool rd_str(rd *r, const uint8_t **s, uint64_t *n) {
    if (!rd_u64(r, n)) return false;
    if (!rd_need(r, *n)) return false;
    *s = r->p; r->p += *n; return true;
}

static int vsize(uint32_t t) {
    switch (t) {
        case GGUF_U8: case GGUF_I8: case GGUF_BOOL: return 1;
        case GGUF_U16: case GGUF_I16: return 2;
        case GGUF_U32: case GGUF_I32: case GGUF_F32: return 4;
        case GGUF_U64: case GGUF_I64: case GGUF_F64: return 8;
        default: return 0;
    }
}

static bool skip_value(rd *r, uint32_t t, uint32_t *arr_t, uint64_t *arr_n) {
    if (t == GGUF_STR) { const uint8_t *s; uint64_t n; return rd_str(r, &s, &n); }
    if (t == GGUF_ARR) {
        uint32_t et; uint64_t n;
        if (!rd_u32(r, &et) || !rd_u64(r, &n)) return false;
        if (arr_t) *arr_t = et;
        if (arr_n) *arr_n = n;
        if (et == GGUF_STR) {
            for (uint64_t i = 0; i < n; i++) { const uint8_t *s; uint64_t l; if (!rd_str(r, &s, &l)) return false; }
            return true;
        }
        if (et == GGUF_ARR) return false;  // 推理用不到嵌套数组
        int es = vsize(et);
        if (es == 0) return false;
        if (n > UINT64_MAX / (uint64_t)es) return false;
        if (!rd_need(r, n * es)) return false;
        r->p += n * es;
        return true;
    }
    int s = vsize(t);
    if (s == 0 || !rd_need(r, s)) return false;
    r->p += s;
    return true;
}

static gguf_file *parse(const uint8_t *buf, uint64_t len, uint64_t *need, char *err, size_t errlen) {
    rd r = { buf, buf + len, false };
    gguf_file *f = NULL;
    uint32_t magic, version;
    if (need) *need = 0;
    if (!rd_u32(&r, &magic) || !rd_u32(&r, &version)) goto short_read;
    if (magic != 0x46554747u) { snprintf(err, errlen, "不是 GGUF 文件"); return NULL; }
    if (version < 2 || version > 3) { snprintf(err, errlen, "GGUF 版本 %u 不支持", version); return NULL; }

    f = calloc(1, sizeof(*f));
    f->fd = -1;
    f->map = NULL; f->hdr = NULL;
    f->alignment = 32;
    if (!rd_u64(&r, &f->n_tensors) || !rd_u64(&r, &f->n_kv)) goto short_read;
    if (f->n_kv > 1u << 20 || f->n_tensors > 1u << 20) { snprintf(err, errlen, "GGUF 头部数量异常"); goto fail; }

    f->kv = calloc(f->n_kv ? f->n_kv : 1, sizeof(gguf_kv));
    f->tensors = calloc(f->n_tensors ? f->n_tensors : 1, sizeof(gguf_tensor));

    // 先量一下名字总长，一次分配
    size_t pool = 0;
    const uint8_t *save = r.p;
    for (uint64_t i = 0; i < f->n_kv; i++) {
        const uint8_t *s; uint64_t n; uint32_t t;
        if (!rd_str(&r, &s, &n) || !rd_u32(&r, &t)) goto short_read;
        pool += n + 1;
        if (!skip_value(&r, t, NULL, NULL)) { if (r.short_read) goto short_read; snprintf(err, errlen, "GGUF 键值类型 %u 不认识", t); goto fail; }
    }
    for (uint64_t i = 0; i < f->n_tensors; i++) {
        const uint8_t *s; uint64_t n; uint32_t nd, ty; uint64_t d, off;
        if (!rd_str(&r, &s, &n) || !rd_u32(&r, &nd)) goto short_read;
        if (nd > 4) { snprintf(err, errlen, "张量维度 %u 超过 4", nd); goto fail; }
        for (uint32_t k = 0; k < nd; k++) if (!rd_u64(&r, &d)) goto short_read;
        if (!rd_u32(&r, &ty) || !rd_u64(&r, &off)) goto short_read;
        pool += n + 1;
    }
    f->strpool = malloc(pool ? pool : 1);
    char *sp = f->strpool;

    r.p = save;
    for (uint64_t i = 0; i < f->n_kv; i++) {
        const uint8_t *s; uint64_t n;
        rd_str(&r, &s, &n);
        memcpy(sp, s, n); sp[n] = 0;
        gguf_kv *kv = &f->kv[i];
        kv->key = sp; sp += n + 1;
        rd_u32(&r, &kv->type);
        kv->data = r.p;
        skip_value(&r, kv->type, &kv->arr_type, &kv->arr_n);
        if (kv->type == GGUF_U32 && strcmp(kv->key, "general.alignment") == 0) memcpy(&f->alignment, kv->data, 4);
    }
    if (f->alignment == 0 || (f->alignment & (f->alignment - 1))) { snprintf(err, errlen, "对齐值 %u 不对", f->alignment); goto fail; }

    for (uint64_t i = 0; i < f->n_tensors; i++) {
        gguf_tensor *t = &f->tensors[i];
        const uint8_t *s; uint64_t n;
        rd_str(&r, &s, &n);
        memcpy(sp, s, n); sp[n] = 0;
        t->name = sp; sp += n + 1;
        rd_u32(&r, &t->n_dims);
        for (int k = 0; k < 4; k++) t->ne[k] = 1;
        for (uint32_t k = 0; k < t->n_dims; k++) { uint64_t d = 1; rd_u64(&r, &d); t->ne[k] = (int64_t)d; }
        rd_u32(&r, &t->type);
        rd_u64(&r, &t->offset);
        int bb = 0, bn = xj_type_block(t->type, &bb);
        if (bn == 0) { t->nbytes = 0; continue; }  // 不认识的类型：用到时报错
        if (t->ne[0] % bn) { snprintf(err, errlen, "张量 %s 行长 %lld 不是块大小的倍数", t->name, (long long)t->ne[0]); goto fail; }
        t->nbytes = xj_row_bytes(t->type, t->ne[0]) * (uint64_t)(t->ne[1] * t->ne[2] * t->ne[3]);
    }

    uint64_t hdr = (uint64_t)(r.p - buf);
    f->data_off = (hdr + f->alignment - 1) / f->alignment * f->alignment;
    return f;

short_read:
    if (need) *need = len < 4096 ? 4096 : len * 2;
    snprintf(err, errlen, "GGUF 头部不完整");
fail:
    gguf_close(f);
    return NULL;
}

gguf_file *gguf_parse_header(const uint8_t *buf, uint64_t len, uint64_t *need, char *err, size_t errlen) {
    return parse(buf, len, need, err, errlen);
}

gguf_file *gguf_open(const char *path, char *err, size_t errlen) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { snprintf(err, errlen, "打不开 %s", path); return NULL; }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 16) { close(fd); snprintf(err, errlen, "文件太小"); return NULL; }
    void *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { close(fd); snprintf(err, errlen, "mmap 失败"); return NULL; }
    gguf_file *f = parse(m, (uint64_t)st.st_size, NULL, err, errlen);
    if (!f) { munmap(m, (size_t)st.st_size); close(fd); return NULL; }
    f->fd = fd;
    f->map = m;
    f->map_off = 0;
    f->map_len = (uint64_t)st.st_size;
    f->size = (uint64_t)st.st_size;
    for (uint64_t i = 0; i < f->n_tensors; i++) {
        const gguf_tensor *t = &f->tensors[i];
        if (f->data_off + t->offset + t->nbytes > f->size) {
            snprintf(err, errlen, "张量 %s 超出文件末尾（文件没下完？）", t->name);
            gguf_close(f);
            return NULL;
        }
    }
    return f;
}

gguf_file *gguf_open_header(const char *path, char *err, size_t errlen) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { snprintf(err, errlen, "打不开 %s", path); return NULL; }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 16) { close(fd); snprintf(err, errlen, "文件太小"); return NULL; }
    uint64_t want = 16u << 20;
    for (;;) {
        if (want > (uint64_t)st.st_size) want = (uint64_t)st.st_size;
        uint8_t *buf = malloc(want);
        if (!buf) { close(fd); snprintf(err, errlen, "内存不够"); return NULL; }
        uint64_t got = 0;
        while (got < want) {
            ssize_t k = pread(fd, buf + got, want - got, (off_t)got);
            if (k <= 0) break;
            got += (uint64_t)k;
        }
        uint64_t need = 0;
        gguf_file *f = parse(buf, got, &need, err, errlen);
        if (f) {
            f->fd = fd; f->hdr = buf; f->size = (uint64_t)st.st_size;
            return f;
        }
        free(buf);
        if (!need || got < want || want >= (uint64_t)st.st_size) { close(fd); return NULL; }
        want = need;
    }
}

bool gguf_map_range(gguf_file *f, uint64_t lo, uint64_t hi, char *err, size_t errlen) {
    if (f->map) { snprintf(err, errlen, "已经映射过了"); return false; }
    if (hi > f->size || lo >= hi) { snprintf(err, errlen, "映射范围超出文件（文件没下完？）"); return false; }
    uint64_t page = (uint64_t)getpagesize();
    uint64_t start = lo / page * page;
    void *m = mmap(NULL, (size_t)(hi - start), PROT_READ, MAP_SHARED, f->fd, (off_t)start);
    if (m == MAP_FAILED) { snprintf(err, errlen, "映射 %llu MB 失败（地址空间不够？少分几层试试）", (unsigned long long)((hi - start) >> 20)); return false; }
    f->map = m; f->map_off = start; f->map_len = hi - start;
    return true;
}

const void *gguf_ptr(const gguf_file *f, uint64_t file_off, uint64_t nbytes) {
    if (!f->map || file_off < f->map_off || file_off + nbytes > f->map_off + f->map_len) return NULL;
    return f->map + (file_off - f->map_off);
}

void gguf_close(gguf_file *f) {
    if (!f) return;
    if (f->map) munmap((void *)f->map, (size_t)f->map_len);
    if (f->fd >= 0) close(f->fd);
    free(f->hdr);
    free(f->kv); free(f->tensors); free(f->strpool);
    free(f);
}

const gguf_kv *gguf_find_kv(const gguf_file *f, const char *key) {
    for (uint64_t i = 0; i < f->n_kv; i++) if (strcmp(f->kv[i].key, key) == 0) return &f->kv[i];
    return NULL;
}

const gguf_tensor *gguf_find_tensor(const gguf_file *f, const char *name) {
    for (uint64_t i = 0; i < f->n_tensors; i++) if (strcmp(f->tensors[i].name, name) == 0) return &f->tensors[i];
    return NULL;
}

const void *gguf_tensor_data(const gguf_file *f, const gguf_tensor *t) {
    return gguf_ptr(f, f->data_off + t->offset, t->nbytes);
}

static bool scalar_u32(uint32_t type, const uint8_t *p, uint32_t *out) {
    switch (type) {
        case GGUF_U8:  *out = p[0]; return true;
        case GGUF_I8:  *out = (uint32_t)(int8_t)p[0]; return true;
        case GGUF_U16: { uint16_t v; memcpy(&v, p, 2); *out = v; return true; }
        case GGUF_I16: { int16_t v; memcpy(&v, p, 2); *out = (uint32_t)v; return true; }
        case GGUF_U32: case GGUF_I32: memcpy(out, p, 4); return true;
        case GGUF_U64: case GGUF_I64: { uint64_t v; memcpy(&v, p, 8); *out = (uint32_t)v; return true; }
        case GGUF_BOOL: *out = p[0] != 0; return true;
        default: return false;
    }
}

bool gguf_get_u32(const gguf_file *f, const char *key, uint32_t *out) {
    const gguf_kv *kv = gguf_find_kv(f, key);
    return kv && scalar_u32(kv->type, kv->data, out);
}

bool gguf_get_f32(const gguf_file *f, const char *key, float *out) {
    const gguf_kv *kv = gguf_find_kv(f, key);
    if (!kv) return false;
    if (kv->type == GGUF_F32) { memcpy(out, kv->data, 4); return true; }
    if (kv->type == GGUF_F64) { double d; memcpy(&d, kv->data, 8); *out = (float)d; return true; }
    uint32_t u;
    if (scalar_u32(kv->type, kv->data, &u)) { *out = (float)u; return true; }
    return false;
}

bool gguf_get_str(const gguf_file *f, const char *key, const char **s, uint64_t *len) {
    const gguf_kv *kv = gguf_find_kv(f, key);
    if (!kv || kv->type != GGUF_STR) return false;
    memcpy(len, kv->data, 8);
    *s = (const char *)kv->data + 8;
    return true;
}

bool gguf_get_arr_u32(const gguf_file *f, const char *key, uint64_t i, uint32_t *out) {
    const gguf_kv *kv = gguf_find_kv(f, key);
    if (!kv || kv->type != GGUF_ARR || i >= kv->arr_n) return false;
    int es = vsize(kv->arr_type);
    if (es == 0) return false;
    return scalar_u32(kv->arr_type, kv->data + 12 + i * es, out);
}

bool gguf_get_arr_str(const gguf_file *f, const char *key, uint64_t i, const char **s, uint64_t *len) {
    const gguf_kv *kv = gguf_find_kv(f, key);
    if (!kv || kv->type != GGUF_ARR || kv->arr_type != GGUF_STR || i >= kv->arr_n) return false;
    // 字符串数组只能顺序走；词表查询走 xj_vocab（tools/tok.c）里建的索引，这里只给偶尔用
    const uint8_t *p = kv->data + 12;
    for (uint64_t k = 0; k < i; k++) { uint64_t n; memcpy(&n, p, 8); p += 8 + n; }
    memcpy(len, p, 8);
    *s = (const char *)p + 8;
    return true;
}
