// 小橘双机推理：GGUF 文件读取（只读，mmap）。
// 只实现推理要用的部分：元数据键值、张量表、张量数据位置。
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ggml 的张量类型编号（和 ggml.h 里的 enum ggml_type 一致）
enum xj_type {
    XJ_F32 = 0, XJ_F16 = 1, XJ_Q4_0 = 2, XJ_Q4_1 = 3, XJ_Q5_0 = 6, XJ_Q5_1 = 7,
    XJ_Q8_0 = 8, XJ_Q2_K = 10, XJ_Q3_K = 11, XJ_Q4_K = 12, XJ_Q5_K = 13, XJ_Q6_K = 14,
    XJ_BF16 = 30,
};

enum gguf_vtype {
    GGUF_U8 = 0, GGUF_I8, GGUF_U16, GGUF_I16, GGUF_U32, GGUF_I32, GGUF_F32, GGUF_BOOL,
    GGUF_STR, GGUF_ARR, GGUF_U64, GGUF_I64, GGUF_F64,
};

typedef struct {
    const char *name;      // 指向内部字符串，以 0 结尾
    uint32_t    n_dims;
    int64_t     ne[4];     // ne[0] 是一行的元素个数
    uint32_t    type;      // enum xj_type
    uint64_t    offset;    // 相对数据区起点
    uint64_t    nbytes;
} gguf_tensor;

typedef struct {
    const char *key;
    uint32_t    type;      // enum gguf_vtype
    uint32_t    arr_type;  // type == GGUF_ARR 时元素类型
    uint64_t    arr_n;
    const uint8_t *data;   // 值在文件里的位置
} gguf_kv;

typedef struct {
    int         fd;
    const uint8_t *map;     // mmap 的起点（只读）；对应文件偏移 map_off
    uint64_t    map_off, map_len;
    uint8_t    *hdr;        // 只映射一部分时，头部单独读进来放这里
    uint64_t    size;       // 文件大小
    uint64_t    data_off;   // 数据区在文件里的偏移
    uint32_t    alignment;
    uint64_t    n_kv, n_tensors;
    gguf_kv    *kv;
    gguf_tensor *tensors;
    char       *strpool;    // 键名、张量名
} gguf_file;

// 打开并解析，整个文件 mmap；失败返回 NULL，err 里写原因
gguf_file *gguf_open(const char *path, char *err, size_t errlen);
// 只读头部（不映射权重），之后用 gguf_map_range 只映射要用的那段。
// iPhone 7 Plus 上用这个：整个 5.7 GB 映射进来可能超出 App 的地址空间。
gguf_file *gguf_open_header(const char *path, char *err, size_t errlen);
bool gguf_map_range(gguf_file *f, uint64_t lo, uint64_t hi, char *err, size_t errlen);
// 文件偏移 → 映射里的指针；不在映射范围里返回 NULL
const void *gguf_ptr(const gguf_file *f, uint64_t file_off, uint64_t nbytes);
// 只解析已经在内存里的头部（用来从网络先拿头部算出要下载哪些字节）。
// 头部不全时返回 NULL，*need 写需要的最少字节数。
gguf_file *gguf_parse_header(const uint8_t *buf, uint64_t len, uint64_t *need, char *err, size_t errlen);
void gguf_close(gguf_file *f);

const gguf_kv     *gguf_find_kv(const gguf_file *f, const char *key);
const gguf_tensor *gguf_find_tensor(const gguf_file *f, const char *name);
const void        *gguf_tensor_data(const gguf_file *f, const gguf_tensor *t);

bool     gguf_get_u32(const gguf_file *f, const char *key, uint32_t *out);   // 接受各种整数类型
bool     gguf_get_f32(const gguf_file *f, const char *key, float *out);
bool     gguf_get_str(const gguf_file *f, const char *key, const char **s, uint64_t *len);
// 整数数组的第 i 个元素
bool     gguf_get_arr_u32(const gguf_file *f, const char *key, uint64_t i, uint32_t *out);
// 字符串数组的第 i 个元素（词表用）
bool     gguf_get_arr_str(const gguf_file *f, const char *key, uint64_t i, const char **s, uint64_t *len);

// 每种类型一个块多少元素、多少字节
int      xj_type_block(uint32_t type, int *block_bytes);
const char *xj_type_name(uint32_t type);
uint64_t xj_row_bytes(uint32_t type, int64_t n);

#ifdef __cplusplus
}
#endif
