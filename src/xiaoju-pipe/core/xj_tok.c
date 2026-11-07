// 小橘双机推理：命令行工具用的分词器（Qwen3.5 的 byte-level BPE）。
// 和官方一样先做 NFC（e + U+0301 → é），特殊词（<|im_end|>、<think> 这类 control / user_defined 词）原样认出来；
// 预分词按 tokenizer.json 里的正则手写；非 ASCII 字符只粗分「标点 / 空白 / 文字」，
// 少数罕见字符切法可能和官方不同（不影响能不能跑）。
// CI 里用 tests/tok_check.py 和官方 tokenizer.json 逐条对照（见 .github/workflows/xiaoju-pipe.yml）。
#include "xj_tok.h"
#include "xj_nfc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const char *s; uint32_t n; int32_t v; } ent;

struct xj_tok {
    ent *vocab; uint32_t vcap;       // 字符串 → id
    ent *merge; uint32_t mcap;       // "左 右" → 排名
    const char **id_str; uint32_t *id_len; int n_vocab;
    char *pool;
    int32_t *special; int n_special;  // 特殊词 id，按长度从长到短
    uint8_t *is_special;              // [n_vocab]
    uint8_t special_first[256];       // 特殊词的首字节（快速跳过）
    int byte_cp[256];                // 字节 → GPT-2 的可见字符
    int cp_byte[512];                // 反过来（码点 < 512）
};

static uint64_t hs(const char *s, uint32_t n) {
    uint64_t h = 1469598103934665603ull;
    for (uint32_t i = 0; i < n; i++) { h ^= (uint8_t)s[i]; h *= 1099511628211ull; }
    return h;
}

static void put(ent *t, uint32_t cap, const char *s, uint32_t n, int32_t v) {
    uint32_t i = (uint32_t)hs(s, n) & (cap - 1);
    while (t[i].s) { if (t[i].n == n && !memcmp(t[i].s, s, n)) return; i = (i + 1) & (cap - 1); }
    t[i].s = s; t[i].n = n; t[i].v = v;
}

static int32_t get(const ent *t, uint32_t cap, const char *s, uint32_t n) {
    uint32_t i = (uint32_t)hs(s, n) & (cap - 1);
    while (t[i].s) { if (t[i].n == n && !memcmp(t[i].s, s, n)) return t[i].v; i = (i + 1) & (cap - 1); }
    return -1;
}

static uint32_t pow2(uint64_t n) { uint32_t c = 1; while (c < n * 2) c <<= 1; return c; }

static int utf8_enc(int cp, char *o) {
    if (cp < 0x80) { o[0] = (char)cp; return 1; }
    if (cp < 0x800) { o[0] = (char)(0xC0 | cp >> 6); o[1] = (char)(0x80 | (cp & 63)); return 2; }
    if (cp < 0x10000) { o[0] = (char)(0xE0 | cp >> 12); o[1] = (char)(0x80 | ((cp >> 6) & 63)); o[2] = (char)(0x80 | (cp & 63)); return 3; }
    o[0] = (char)(0xF0 | cp >> 18); o[1] = (char)(0x80 | ((cp >> 12) & 63)); o[2] = (char)(0x80 | ((cp >> 6) & 63)); o[3] = (char)(0x80 | (cp & 63)); return 4;
}

static int utf8_dec(const char *s, int n, int *cp) {
    const uint8_t *u = (const uint8_t *)s;
    if (u[0] < 0x80 || n < 2) { *cp = u[0]; return 1; }
    if ((u[0] & 0xE0) == 0xC0) { *cp = ((u[0] & 31) << 6) | (u[1] & 63); return 2; }
    if ((u[0] & 0xF0) == 0xE0 && n >= 3) { *cp = ((u[0] & 15) << 12) | ((u[1] & 63) << 6) | (u[2] & 63); return 3; }
    if (n >= 4) { *cp = ((u[0] & 7) << 18) | ((u[1] & 63) << 12) | ((u[2] & 63) << 6) | (u[3] & 63); return 4; }
    *cp = u[0]; return 1;
}

xj_tok *xj_tok_new(const gguf_file *g, char *err, size_t errlen) {
    const gguf_kv *tk = gguf_find_kv(g, "tokenizer.ggml.tokens");
    const gguf_kv *mk = gguf_find_kv(g, "tokenizer.ggml.merges");
    if (!tk || !mk || tk->type != GGUF_ARR || mk->type != GGUF_ARR) { snprintf(err, errlen, "模型里没有词表"); return NULL; }
    xj_tok *t = calloc(1, sizeof(*t));
    t->n_vocab = (int)tk->arr_n;
    t->vcap = pow2(tk->arr_n); t->vocab = calloc(t->vcap, sizeof(ent));
    t->mcap = pow2(mk->arr_n); t->merge = calloc(t->mcap, sizeof(ent));
    t->id_str = calloc(tk->arr_n, sizeof(char *)); t->id_len = calloc(tk->arr_n, 4);
    const uint8_t *p = tk->data + 12;
    for (uint64_t i = 0; i < tk->arr_n; i++) {
        uint64_t n; memcpy(&n, p, 8);
        t->id_str[i] = (const char *)p + 8; t->id_len[i] = (uint32_t)n;
        put(t->vocab, t->vcap, (const char *)p + 8, (uint32_t)n, (int32_t)i);
        p += 8 + n;
    }
    p = mk->data + 12;
    for (uint64_t i = 0; i < mk->arr_n; i++) {
        uint64_t n; memcpy(&n, p, 8);
        put(t->merge, t->mcap, (const char *)p + 8, (uint32_t)n, (int32_t)i);
        p += 8 + n;
    }
    // GPT-2 的字节映射：可见字符映射到自己，其余依次映射到 256 以后
    int n = 0;
    for (int b = 0; b < 256; b++) {
        bool vis = (b >= 33 && b <= 126) || (b >= 161 && b <= 172) || (b >= 174 && b <= 255);
        t->byte_cp[b] = vis ? b : 256 + n++;
    }
    for (int b = 0; b < 256; b++) t->cp_byte[t->byte_cp[b]] = b;

    // 特殊词：token_type 是 3（control）或 4（user_defined）的；没有 token_type 就认 <|…|>
    t->is_special = calloc(tk->arr_n, 1);
    t->special = malloc(sizeof(int32_t) * (tk->arr_n ? tk->arr_n : 1));
    const bool have_type = gguf_find_kv(g, "tokenizer.ggml.token_type") != NULL;
    for (uint64_t i = 0; i < tk->arr_n; i++) {
        uint32_t ty = 0, n = t->id_len[i];
        const char *s = t->id_str[i];
        bool sp;
        if (have_type) sp = gguf_get_arr_u32(g, "tokenizer.ggml.token_type", i, &ty) && (ty == 3 || ty == 4);
        else sp = n > 4 && s[0] == '<' && s[1] == '|' && s[n - 2] == '|' && s[n - 1] == '>';
        if (!sp || n == 0) continue;
        t->is_special[i] = 1;
        t->special[t->n_special++] = (int32_t)i;
        t->special_first[(uint8_t)s[0]] = 1;
    }
    // 长的先匹配（插入排序，特殊词只有几十个）
    for (int i = 1; i < t->n_special; i++) {
        int32_t v = t->special[i]; int j = i;
        while (j > 0 && t->id_len[t->special[j - 1]] < t->id_len[v]) { t->special[j] = t->special[j - 1]; j--; }
        t->special[j] = v;
    }
    return t;
}

void xj_tok_free(xj_tok *t) {
    if (!t) return;
    free(t->vocab); free(t->merge); free(t->id_str); free(t->id_len);
    free(t->special); free(t->is_special); free(t);
}

int32_t xj_tok_find(const xj_tok *t, const char *s) { return get(t->vocab, t->vcap, s, (uint32_t)strlen(s)); }

// ---- 预分词 ----
enum { C_OTHER, C_LETTER, C_DIGIT, C_SPACE, C_NL };

static int cls(int cp) {
    if (cp == '\r' || cp == '\n') return C_NL;
    if (cp == ' ' || cp == '\t' || cp == '\v' || cp == '\f' || cp == 0x3000 || cp == 0xA0 || (cp >= 0x2000 && cp <= 0x200A)) return C_SPACE;
    if (cp < 0x80) {
        if ((cp | 32) >= 'a' && (cp | 32) <= 'z') return C_LETTER;
        if (cp >= '0' && cp <= '9') return C_DIGIT;
        return C_OTHER;
    }
    if (cp >= 0xFF10 && cp <= 0xFF19) return C_DIGIT;
    if ((cp >= 0x2010 && cp <= 0x206F) || (cp >= 0x3001 && cp <= 0x303F) || (cp >= 0xFF01 && cp <= 0xFF0F) ||
        (cp >= 0xFF1A && cp <= 0xFF20) || (cp >= 0xFF3B && cp <= 0xFF40) || (cp >= 0xFF5B && cp <= 0xFF65) ||
        (cp >= 0x00A1 && cp <= 0x00BF) || cp == 0x00D7 || cp == 0x00F7 || (cp >= 0x2190 && cp <= 0x2BFF) ||
        (cp >= 0x1F000 && cp <= 0x1FAFF) || (cp >= 0xFE30 && cp <= 0xFE4F))
        return C_OTHER;
    return C_LETTER;  // 汉字、假名、带音调的拉丁字母等都当文字
}

typedef struct { int cp, len, cls; } ch;

// 按正则切出下一段，返回这段包含几个字符
static int next_piece(const ch *c, int n, int i) {
    // '[sS]|'[tT]|'re|'ve|'m|'ll|'d
    if (c[i].cp == '\'' && i + 1 < n) {
        int a = c[i + 1].cp | 32, b = i + 2 < n ? (c[i + 2].cp | 32) : 0;
        if (a == 's' || a == 't' || a == 'm' || a == 'd') return 2;
        if ((a == 'r' && b == 'e') || (a == 'v' && b == 'e') || (a == 'l' && b == 'l')) return 3;
    }
    // [^\r\n\p{L}\p{N}]?\p{L}+
    {
        int j = i;
        if (c[j].cls != C_LETTER && c[j].cls != C_DIGIT && c[j].cls != C_NL && j + 1 < n && c[j + 1].cls == C_LETTER) j++;
        if (c[j].cls == C_LETTER) { while (j < n && c[j].cls == C_LETTER) j++; return j - i; }
    }
    if (c[i].cls == C_DIGIT) return 1;  // \p{N}
    // ' ?[^\s\p{L}\p{N}]+[\r\n]*'
    {
        int j = i;
        if (c[j].cp == ' ' && j + 1 < n && c[j + 1].cls == C_OTHER) j++;
        if (c[j].cls == C_OTHER) {
            while (j < n && c[j].cls == C_OTHER) j++;
            while (j < n && c[j].cls == C_NL) j++;
            return j - i;
        }
    }
    // \s*[\r\n]+
    {
        int j = i, last_nl = -1;
        while (j < n && (c[j].cls == C_SPACE || c[j].cls == C_NL)) { if (c[j].cls == C_NL) last_nl = j; j++; }
        if (last_nl >= 0) { int k = last_nl; while (k + 1 < n && c[k + 1].cls == C_NL) k++; return k + 1 - i; }
        // \s+(?!\S)：空白后面跟着非空白时，最后一个空白留给下一段
        if (j - i > 1 && j < n) return j - i - 1;
        return j - i > 0 ? j - i : 1;
    }
}

// 一段做 BPE，结果追加到 out
static int bpe(const xj_tok *t, const char *piece, int plen, int32_t *out, int max) {
    // 转成 GPT-2 字符，每个字节一个「符号」
    char buf[4096];
    int bl = 0, starts[1024], lens[1024], ns = 0;
    for (int i = 0; i < plen && ns < 1023 && bl < 4000; i++) {
        starts[ns] = bl;
        lens[ns] = utf8_enc(t->byte_cp[(uint8_t)piece[i]], buf + bl);
        bl += lens[ns++];
    }
    // 反复合并排名最小的一对
    char key[512];
    for (;;) {
        int best = -1, bi = -1;
        for (int i = 0; i + 1 < ns; i++) {
            int kl = lens[i] + 1 + lens[i + 1];
            if (kl >= (int)sizeof key) continue;
            memcpy(key, buf + starts[i], lens[i]); key[lens[i]] = ' ';
            memcpy(key + lens[i] + 1, buf + starts[i + 1], lens[i + 1]);
            int r = get(t->merge, t->mcap, key, (uint32_t)kl);
            if (r >= 0 && (best < 0 || r < best)) { best = r; bi = i; }
        }
        if (bi < 0) break;
        lens[bi] += lens[bi + 1];  // 两个符号在 buf 里本来就挨着
        for (int k = bi + 1; k + 1 < ns; k++) { starts[k] = starts[k + 1]; lens[k] = lens[k + 1]; }
        ns--;
    }
    int n = 0;
    for (int i = 0; i < ns && n < max; i++) {
        int32_t id = get(t->vocab, t->vcap, buf + starts[i], (uint32_t)lens[i]);
        if (id >= 0) out[n++] = id;
        else {  // 理论上不会：单字节都在词表里
            for (int k = 0; k < lens[i] && n < max; k++) {
                int32_t b = get(t->vocab, t->vcap, buf + starts[i] + k, 1);
                if (b >= 0) out[n++] = b;
            }
        }
    }
    return n;
}

static int encode_plain(const xj_tok *t, const char *s, int len, int32_t *out, int max) {
    ch *c = malloc(sizeof(ch) * (len + 1));
    int n = 0;
    for (int i = 0; i < len;) {
        int cp, l = utf8_dec(s + i, len - i, &cp);
        c[n].cp = cp; c[n].len = l; c[n].cls = cls(cp); n++; i += l;
    }
    int nout = 0, byte = 0;
    for (int i = 0; i < n && nout < max;) {
        int k = next_piece(c, n, i), bytes = 0;
        for (int j = i; j < i + k; j++) bytes += c[j].len;
        // 太长的一段（比如一长串汉字）分块做 BPE，避免平方级的合并
        for (int off = 0; off < bytes && nout < max;) {
            int chunk = bytes - off;
            if (chunk > 900) { chunk = 900; while (chunk > 0 && ((uint8_t)s[byte + off + chunk] & 0xC0) == 0x80) chunk--; }
            nout += bpe(t, s + byte + off, chunk, out + nout, max - nout);
            off += chunk;
        }
        byte += bytes; i += k;
    }
    free(c);
    return nout;
}

// ---- NFC（只做两两组合，够分词用）----
static int nfc_pair(int a, int b) {
    if (a >= 0x1100 && a <= 0x1112 && b >= 0x1161 && b <= 0x1175)  // 韩文 L + V
        return 0xAC00 + ((a - 0x1100) * 21 + (b - 0x1161)) * 28;
    if (a >= 0xAC00 && a <= 0xD7A3 && (a - 0xAC00) % 28 == 0 && b >= 0x11A8 && b <= 0x11C2)  // LV + T
        return a + (b - 0x11A7);
    int lo = 0, hi = (int)(sizeof xj_nfc_pairs / sizeof xj_nfc_pairs[0]) - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        const uint32_t *p = xj_nfc_pairs[mid];
        if (p[0] == (uint32_t)a && p[1] == (uint32_t)b) return (int)p[2];
        if (p[0] < (uint32_t)a || (p[0] == (uint32_t)a && p[1] < (uint32_t)b)) lo = mid + 1; else hi = mid - 1;
    }
    return -1;
}

// 把 s 做 NFC 组合写进 out（out 至少 len + 1 字节；组合只会让 UTF-8 变短或不变）
static int nfc(const char *s, int len, char *out) {
    int o = 0, last = -1, last_cp = 0;  // last：上一个字在 out 里的起点
    for (int i = 0; i < len;) {
        int cp, l = utf8_dec(s + i, len - i, &cp);
        int c = last >= 0 ? nfc_pair(last_cp, cp) : -1;
        char tmp[4];
        if (c >= 0 && utf8_enc(c, tmp) <= o - last + l) {
            o = last + utf8_enc(c, out + last);
            last_cp = c;
        } else {
            last = o;
            last_cp = cp;
            memcpy(out + o, s + i, l);  // 原样拷字节（不合法的 UTF-8 也保留）
            o += l;
        }
        i += l;
    }
    out[o] = 0;
    return o;
}

int xj_tok_encode(const xj_tok *t, const char *raw, int32_t *out, int max) {
    int rl = (int)strlen(raw);
    char *text = malloc(rl + 1);
    int len = nfc(raw, rl, text);
    // 先认出特殊词（长的优先），其余按普通文字切
    int n = 0, start = 0;
    for (int i = 0; i < len; i++) {
        if (!t->special_first[(uint8_t)text[i]]) continue;
        for (int k = 0; k < t->n_special; k++) {
            int32_t id = t->special[k];
            uint32_t sl = t->id_len[id];
            if (sl > (uint32_t)(len - i) || memcmp(text + i, t->id_str[id], sl)) continue;
            n += encode_plain(t, text + start, i - start, out + n, max - n);
            if (n < max) out[n++] = id;
            i += (int)sl - 1; start = i + 1;
            break;
        }
    }
    n += encode_plain(t, text + start, len - start, out + n, max - n);
    free(text);
    return n;
}

int xj_tok_piece(const xj_tok *t, int32_t id, char *out, int max) {
    if (id < 0 || id >= t->n_vocab) return 0;
    const char *s = t->id_str[id];
    int len = (int)t->id_len[id], n = 0;
    if (t->is_special[id]) {  // 特殊词原样输出
        if (len > max) len = max;
        memcpy(out, s, len); return len;
    }
    for (int i = 0; i < len && n < max;) {
        int cp, l = utf8_dec(s + i, len - i, &cp);
        out[n++] = (char)(cp < 512 ? t->cp_byte[cp] : '?');
        i += l;
    }
    return n;
}
