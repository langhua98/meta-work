// 不需要模型文件的单元测试：半精度转换、量化块解码、消息收发、GGUF 头部解析。
//   make test
#include "../core/gguf.h"
#include "../core/xj_net.h"
#include "../core/xj_quant.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; fprintf(stderr, "失败 %s:%d ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static void test_f16(void) {
    const float v[] = { 0.0f, 1.0f, -2.5f, 65504.0f, 6.1035156e-05f, 5.9604645e-08f, 0.33325195f, -1e-3f };
    for (size_t i = 0; i < sizeof v / sizeof v[0]; i++) {
        float back = xj_f16(xj_to_f16(v[i]));
        CHECK(fabsf(back - v[i]) <= fabsf(v[i]) * 1e-3f + 1e-7f, "f16 %g -> %g", v[i], back);
    }
    CHECK(isinf(xj_f16(xj_to_f16(1e6f))), "溢出应该是 inf");
}

// 用定义手搓 Q8_0 / Q4_K 块，看解码是否等于公式
static void test_quant(void) {
    uint8_t b8[34];
    uint16_t d = xj_to_f16(0.5f);
    memcpy(b8, &d, 2);
    for (int i = 0; i < 32; i++) b8[2 + i] = (uint8_t)(int8_t)(i - 16);
    float y[256];
    xj_dequant_row(XJ_Q8_0, b8, y, 32);
    for (int i = 0; i < 32; i++) CHECK(y[i] == 0.5f * (i - 16), "q8_0 第 %d 个 %g", i, y[i]);

    uint8_t b4[144] = {0};
    uint16_t d1 = xj_to_f16(0.25f), dm = xj_to_f16(1.0f);
    memcpy(b4, &d1, 2); memcpy(b4 + 2, &dm, 2);
    // 子块 0..3：scale = j+1，min = j；子块 4..7：scale = 2，min = 1（走高位拼接那条路）
    for (int j = 0; j < 4; j++) { b4[4 + j] = (uint8_t)(j + 1); b4[8 + j] = (uint8_t)j; }
    for (int j = 4; j < 8; j++) b4[12 + j - 4] = (uint8_t)(2 | (1 << 4));
    for (int i = 0; i < 128; i++) b4[16 + i] = (uint8_t)((i % 16) | ((15 - i % 16) << 4));
    xj_dequant_row(XJ_Q4_K, b4, y, 256);
    for (int e = 0; e < 256; e++) {
        int j = e / 32, l = e % 32, g = j / 2;
        int q = (j & 1) ? (b4[16 + 32 * g + l] >> 4) : (b4[16 + 32 * g + l] & 15);
        float sc = j < 4 ? j + 1 : 2, mn = j < 4 ? j : 1;
        float want = 0.25f * sc * q - 1.0f * mn;
        CHECK(fabsf(y[e] - want) < 1e-6f, "q4_K 第 %d 个 %g 应为 %g", e, y[e], want);
        if (fabsf(y[e] - want) >= 1e-6f) break;
    }
}

static void test_frames(void) {
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0, "socketpair");
    float payload[100];
    for (int i = 0; i < 100; i++) payload[i] = i * 0.5f;
    uint8_t hdr[12] = {1, 2, 3};
    CHECK(xj_send_msg(sv[0], XJ_MSG_FORWARD, 7, hdr, 12, payload, sizeof payload) == 0, "发送");
    void *buf = NULL; uint32_t cap = 0, len = 0, seq = 0; char err[128];
    int t = xj_recv_msg(sv[1], &buf, &cap, &len, &seq, err, sizeof err);
    CHECK(t == XJ_MSG_FORWARD && seq == 7 && len == 12 + sizeof payload, "收到 type=%d seq=%u len=%u", t, seq, len);
    CHECK(!memcmp((uint8_t *)buf + 12, payload, sizeof payload), "内容");
    // 坏头部要报错，不能当成正常消息
    uint8_t junk[16] = "GET / HTTP/1.1\r";
    CHECK(write(sv[0], junk, 16) == 16, "写");
    t = xj_recv_msg(sv[1], &buf, &cap, &len, &seq, err, sizeof err);
    CHECK(t < 0, "坏头部应失败");
    free(buf);
    close(sv[0]); close(sv[1]);
}

static void test_gguf_header(void) {
    // 最小的 GGUF：1 个键值、1 个张量
    uint8_t b[256], *o = b;
    uint32_t u; uint64_t q;
    u = 0x46554747u; memcpy(o, &u, 4); o += 4;
    u = 3; memcpy(o, &u, 4); o += 4;
    q = 1; memcpy(o, &q, 8); o += 8;   // 张量数
    q = 1; memcpy(o, &q, 8); o += 8;   // 键值数
    q = 4; memcpy(o, &q, 8); o += 8; memcpy(o, "test", 4); o += 4;
    u = GGUF_U32; memcpy(o, &u, 4); o += 4; u = 42; memcpy(o, &u, 4); o += 4;
    q = 1; memcpy(o, &q, 8); o += 8; memcpy(o, "w", 1); o += 1;
    u = 2; memcpy(o, &u, 4); o += 4;
    q = 64; memcpy(o, &q, 8); o += 8; q = 3; memcpy(o, &q, 8); o += 8;
    u = XJ_Q8_0; memcpy(o, &u, 4); o += 4;
    q = 0; memcpy(o, &q, 8); o += 8;
    char err[128]; uint64_t need;
    gguf_file *g = gguf_parse_header(b, (uint64_t)(o - b), &need, err, sizeof err);
    CHECK(g != NULL, "解析失败：%s", err);
    if (g) {
        uint32_t v = 0;
        CHECK(gguf_get_u32(g, "test", &v) && v == 42, "键值");
        const gguf_tensor *t = gguf_find_tensor(g, "w");
        CHECK(t && t->ne[0] == 64 && t->ne[1] == 3 && t->nbytes == 3 * 2 * 34, "张量形状");
        CHECK(g->data_off % 32 == 0, "数据区对齐");
        gguf_close(g);
    }
    g = gguf_parse_header(b, 30, &need, err, sizeof err);
    CHECK(g == NULL && need > 30, "头部不全时要报需要多少字节");
}

int main(void) {
    test_f16();
    test_quant();
    test_frames();
    test_gguf_header();
    if (fails) { fprintf(stderr, "%d 项失败\n", fails); return 1; }
    printf("全部通过\n");
    return 0;
}
