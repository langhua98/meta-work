// 小橘双机推理：量化格式解码（CPU 版）。块格式和 ggml 的 ggml-common.h 完全一样，
// Metal 内核（metal/xj_kernels.metal）用同样的位运算。
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>
#include "gguf.h"

static inline float xj_f16(uint16_t h) {
    uint32_t sign = (uint32_t)(h & 0x8000) << 16;
    uint32_t exp = (h >> 10) & 0x1f, man = h & 0x3ff, bits;
    if (exp == 0) {
        if (man == 0) bits = sign;
        else {  // 非规格化数
            exp = 127 - 15 + 1;
            while (!(man & 0x400)) { man <<= 1; exp--; }
            man &= 0x3ff;
            bits = sign | (exp << 23) | (man << 13);
        }
    } else if (exp == 31) bits = sign | 0x7f800000u | (man << 13);
    else bits = sign | ((exp + 127 - 15) << 23) | (man << 13);
    float f; memcpy(&f, &bits, 4); return f;
}

static inline uint16_t xj_to_f16(float f) {
    uint32_t x; memcpy(&x, &f, 4);
    uint32_t sign = (x >> 16) & 0x8000;
    int32_t exp = (int32_t)((x >> 23) & 0xff) - 127 + 15;
    uint32_t man = x & 0x7fffff;
    if (((x >> 23) & 0xff) == 0xff) return (uint16_t)(sign | 0x7c00 | (man ? 0x200 : 0));
    if (exp >= 31) return (uint16_t)(sign | 0x7c00);
    if (exp <= 0) {
        if (exp < -10) return (uint16_t)sign;
        man |= 0x800000;
        uint32_t shift = (uint32_t)(14 - exp);
        uint32_t h = man >> shift, rem = man & ((1u << shift) - 1), half = 1u << (shift - 1);
        if (rem > half || (rem == half && (h & 1))) h++;
        return (uint16_t)(sign | h);
    }
    uint32_t h = sign | ((uint32_t)exp << 10) | (man >> 13), rem = man & 0x1fff;
    if (rem > 0x1000 || (rem == 0x1000 && (h & 1))) h++;
    return (uint16_t)h;
}

static inline float xj_bf16(uint16_t h) { uint32_t b = (uint32_t)h << 16; float f; memcpy(&f, &b, 4); return f; }

static inline uint16_t rd16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }

static inline void xj_scale_min_k4(int j, const uint8_t *q, uint8_t *d, uint8_t *m) {
    if (j < 4) { *d = q[j] & 63; *m = q[j + 4] & 63; }
    else { *d = (q[j + 4] & 0xF) | ((q[j - 4] >> 6) << 4); *m = (q[j + 4] >> 4) | ((q[j] >> 6) << 4); }
}

// 一整行解码成 float（n 个元素）
static inline void xj_dequant_row(uint32_t type, const void *src, float *y, int64_t n) {
    const uint8_t *b = src;
    switch (type) {
    case XJ_F32: memcpy(y, src, n * 4); return;
    case XJ_F16: for (int64_t i = 0; i < n; i++) y[i] = xj_f16(rd16(b + 2 * i)); return;
    case XJ_BF16: for (int64_t i = 0; i < n; i++) y[i] = xj_bf16(rd16(b + 2 * i)); return;
    case XJ_Q8_0:
        for (int64_t i = 0; i < n / 32; i++, b += 34) {
            float d = xj_f16(rd16(b));
            const int8_t *q = (const int8_t *)(b + 2);
            for (int l = 0; l < 32; l++) *y++ = d * q[l];
        }
        return;
    case XJ_Q4_K:
        for (int64_t i = 0; i < n / 256; i++, b += 144) {
            float d = xj_f16(rd16(b)), dmin = xj_f16(rd16(b + 2));
            const uint8_t *sc = b + 4, *q = b + 16;
            for (int j = 0; j < 8; j += 2, q += 32) {
                uint8_t s, m;
                xj_scale_min_k4(j, sc, &s, &m);
                float d1 = d * s, m1 = dmin * m;
                xj_scale_min_k4(j + 1, sc, &s, &m);
                float d2 = d * s, m2 = dmin * m;
                for (int l = 0; l < 32; l++) *y++ = d1 * (q[l] & 0xF) - m1;
                for (int l = 0; l < 32; l++) *y++ = d2 * (q[l] >> 4) - m2;
            }
        }
        return;
    case XJ_Q5_K:
        for (int64_t i = 0; i < n / 256; i++, b += 176) {
            float d = xj_f16(rd16(b)), dmin = xj_f16(rd16(b + 2));
            const uint8_t *sc = b + 4, *qh = b + 16, *ql = b + 48;
            for (int j = 0; j < 8; j += 2, ql += 32) {
                uint8_t s, m;
                xj_scale_min_k4(j, sc, &s, &m);
                float d1 = d * s, m1 = dmin * m;
                xj_scale_min_k4(j + 1, sc, &s, &m);
                float d2 = d * s, m2 = dmin * m;
                uint8_t u1 = (uint8_t)(1u << j), u2 = (uint8_t)(2u << j);
                for (int l = 0; l < 32; l++) *y++ = d1 * ((ql[l] & 0xF) + (qh[l] & u1 ? 16 : 0)) - m1;
                for (int l = 0; l < 32; l++) *y++ = d2 * ((ql[l] >> 4) + (qh[l] & u2 ? 16 : 0)) - m2;
            }
        }
        return;
    case XJ_Q6_K:
        for (int64_t i = 0; i < n / 256; i++, b += 210) {
            const uint8_t *ql = b, *qh = b + 128;
            const int8_t *sc = (const int8_t *)(b + 192);
            float d = xj_f16(rd16(b + 208));
            for (int h = 0; h < 2; h++, y += 128, ql += 64, qh += 32, sc += 8) {
                for (int l = 0; l < 32; l++) {
                    int is = l / 16;
                    int q1 = ((ql[l] & 0xF) | (((qh[l] >> 0) & 3) << 4)) - 32;
                    int q2 = ((ql[l + 32] & 0xF) | (((qh[l] >> 2) & 3) << 4)) - 32;
                    int q3 = ((ql[l] >> 4) | (((qh[l] >> 4) & 3) << 4)) - 32;
                    int q4 = ((ql[l + 32] >> 4) | (((qh[l] >> 6) & 3) << 4)) - 32;
                    y[l] = d * sc[is] * q1;
                    y[l + 32] = d * sc[is + 2] * q2;
                    y[l + 64] = d * sc[is + 4] * q3;
                    y[l + 96] = d * sc[is + 6] * q4;
                }
            }
        }
        return;
    default:
        memset(y, 0, n * 4);
    }
}
