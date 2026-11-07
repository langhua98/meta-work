// 小橘双机推理：从 GGUF 读出 Qwen3.5 的结构和每层权重的位置。
#include "xj_model.h"

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static bool get_w(const gguf_file *g, const char *name, xj_w *w, bool required, char *err, size_t errlen) {
    memset(w, 0, sizeof(*w));
    const gguf_tensor *t = gguf_find_tensor(g, name);
    if (!t) {
        if (required) snprintf(err, errlen, "模型里没有张量 %s", name);
        return !required;
    }
    if (xj_type_block(t->type, NULL) == 0 || (t->type != XJ_F32 && t->type != XJ_F16 && t->type != XJ_BF16 &&
        t->type != XJ_Q8_0 && t->type != XJ_Q4_K && t->type != XJ_Q5_K && t->type != XJ_Q6_K)) {
        snprintf(err, errlen, "张量 %s 的格式 %s 还不支持", name, xj_type_name(t->type));
        return false;
    }
    w->data = gguf_tensor_data(g, t);
    w->file_off = g->data_off + t->offset;
    w->nbytes = t->nbytes;
    w->type = t->type;
    w->ne0 = t->ne[0];
    w->ne1 = t->ne[1] * t->ne[2] * t->ne[3];
    return true;
}

static bool need_u32(const gguf_file *g, const char *key, int *out, char *err, size_t errlen) {
    uint32_t v;
    if (!gguf_get_u32(g, key, &v)) { snprintf(err, errlen, "模型缺少 %s", key); return false; }
    *out = (int)v;
    return true;
}

static uint64_t fnv(uint64_t h, const void *p, size_t n) {
    const uint8_t *b = p;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ull; }
    return h;
}

// 在词表里按字符串找特殊词（一次顺序扫完）
static void find_special(const gguf_file *g, xj_hparams *hp) {
    const gguf_kv *kv = gguf_find_kv(g, "tokenizer.ggml.tokens");
    hp->eos = hp->eot = UINT32_MAX;
    uint32_t eos;
    if (gguf_get_u32(g, "tokenizer.ggml.eos_token_id", &eos)) hp->eos = eos;
    if (!kv || kv->type != GGUF_ARR || kv->arr_type != GGUF_STR) return;
    const uint8_t *p = kv->data + 12;
    for (uint64_t i = 0; i < kv->arr_n; i++) {
        uint64_t n; memcpy(&n, p, 8);
        const char *s = (const char *)p + 8;
        if (n == 10 && memcmp(s, "<|im_end|>", 10) == 0) hp->eot = (uint32_t)i;
        if (n == 13 && memcmp(s, "<|endoftext|>", 13) == 0 && hp->eos == UINT32_MAX) hp->eos = (uint32_t)i;
        p += 8 + n;
    }
    hp->n_vocab = (int)kv->arr_n;
}

xj_model *xj_model_from_gguf(gguf_file *g, char *err, size_t errlen) {
    const char *arch; uint64_t alen;
    if (!gguf_get_str(g, "general.architecture", &arch, &alen) || alen != 6 || memcmp(arch, "qwen35", 6) != 0) {
        snprintf(err, errlen, "不是 Qwen3.5 稠密模型（general.architecture 要是 qwen35）");
        return NULL;
    }
    xj_model *m = calloc(1, sizeof(*m));
    m->gguf = g;
    xj_hparams *hp = &m->hp;
    int block_count, nextn = 0, key_len, val_len;
    if (!need_u32(g, "qwen35.block_count", &block_count, err, errlen) ||
        !need_u32(g, "qwen35.embedding_length", &hp->n_embd, err, errlen) ||
        !need_u32(g, "qwen35.feed_forward_length", &hp->n_ff, err, errlen) ||
        !need_u32(g, "qwen35.attention.head_count", &hp->n_head, err, errlen) ||
        !need_u32(g, "qwen35.attention.head_count_kv", &hp->n_head_kv, err, errlen) ||
        !need_u32(g, "qwen35.attention.key_length", &key_len, err, errlen) ||
        !need_u32(g, "qwen35.attention.value_length", &val_len, err, errlen) ||
        !need_u32(g, "qwen35.rope.dimension_count", &hp->n_rot, err, errlen) ||
        !need_u32(g, "qwen35.ssm.conv_kernel", &hp->conv_k, err, errlen) ||
        !need_u32(g, "qwen35.ssm.inner_size", &hp->d_inner, err, errlen) ||
        !need_u32(g, "qwen35.ssm.state_size", &hp->s_k, err, errlen) ||
        !need_u32(g, "qwen35.ssm.group_count", &hp->h_k, err, errlen) ||
        !need_u32(g, "qwen35.ssm.time_step_rank", &hp->h_v, err, errlen)) goto fail;
    { uint32_t v; if (gguf_get_u32(g, "qwen35.nextn_predict_layers", &v)) nextn = (int)v; }
    hp->n_layer = block_count - nextn;  // MTP 层只在投机解码时用，这里不算
    hp->full_attn_interval = 4;
    { uint32_t v; if (gguf_get_u32(g, "qwen35.full_attention_interval", &v)) hp->full_attn_interval = (int)v; }
    hp->rope_base = 10000.0f;
    gguf_get_f32(g, "qwen35.rope.freq_base", &hp->rope_base);
    hp->eps = 1e-6f;
    gguf_get_f32(g, "qwen35.attention.layer_norm_rms_epsilon", &hp->eps);
    if (key_len != val_len) { snprintf(err, errlen, "key/value 头维度不一样（%d/%d），不支持", key_len, val_len); goto fail; }
    hp->head_dim = key_len;
    hp->s_v = hp->d_inner / hp->h_v;
    if (hp->s_v != hp->s_k) { snprintf(err, errlen, "线性注意力 key/value 头维度不一样，不支持"); goto fail; }
    if (hp->h_v % hp->h_k) { snprintf(err, errlen, "value 头数不是 key 头数的倍数"); goto fail; }
    hp->key_dim = hp->s_k * hp->h_k;
    hp->conv_dim = 2 * hp->key_dim + hp->d_inner;
    if (hp->n_layer <= 0 || hp->n_layer > XJ_MAX_LAYERS) { snprintf(err, errlen, "层数 %d 不对", hp->n_layer); goto fail; }
    if (hp->n_rot > hp->head_dim || hp->n_rot % 2) { snprintf(err, errlen, "rope 维度 %d 不对", hp->n_rot); goto fail; }
    find_special(g, hp);

    // 是不是线性注意力层：优先读 recurrent_layers 数组，没有就按间隔算（每 4 层第 4 层是全注意力）
    for (int i = 0; i < hp->n_layer; i++) {
        uint32_t r;
        if (gguf_get_arr_u32(g, "qwen35.attention.recurrent_layers", i, &r)) m->layers[i].recurrent = r != 0;
        else m->layers[i].recurrent = (i + 1) % hp->full_attn_interval != 0;
    }

    if (!get_w(g, "token_embd.weight", &m->tok_embd, true, err, errlen) ||
        !get_w(g, "output_norm.weight", &m->output_norm, true, err, errlen) ||
        !get_w(g, "output.weight", &m->output, false, err, errlen)) goto fail;
    if (!m->output.nbytes) m->output = m->tok_embd;  // 共用 embedding（4B 就是这样）
    if (!hp->n_vocab) hp->n_vocab = (int)m->tok_embd.ne1;

    char name[96];
#define W(field, suffix, req) do { snprintf(name, sizeof name, "blk.%d.%s", i, suffix); \
        if (!get_w(g, name, &L->field, req, err, errlen)) goto fail; } while (0)
    for (int i = 0; i < hp->n_layer; i++) {
        xj_layer *L = &m->layers[i];
        W(attn_norm, "attn_norm.weight", true);
        W(post_norm, "post_attention_norm.weight", true);
        W(ffn_gate, "ffn_gate.weight", true);
        W(ffn_up, "ffn_up.weight", true);
        W(ffn_down, "ffn_down.weight", true);
        if (L->recurrent) {
            W(ssm_qkv, "attn_qkv.weight", true);
            W(ssm_gate, "attn_gate.weight", true);
            W(ssm_conv1d, "ssm_conv1d.weight", true);
            W(ssm_dt, "ssm_dt.bias", true);
            W(ssm_a, "ssm_a", true);
            W(ssm_beta, "ssm_beta.weight", true);
            W(ssm_alpha, "ssm_alpha.weight", true);
            W(ssm_norm, "ssm_norm.weight", true);
            W(ssm_out, "ssm_out.weight", true);
            if (L->ssm_qkv.ne1 != hp->conv_dim || L->ssm_conv1d.type != XJ_F32 || L->ssm_conv1d.ne0 != hp->conv_k) {
                snprintf(err, errlen, "第 %d 层线性注意力张量形状不对", i); goto fail;
            }
            if (L->ssm_a.type != XJ_F32 || L->ssm_dt.type != XJ_F32 || L->ssm_norm.type != XJ_F32) {
                snprintf(err, errlen, "第 %d 层 ssm_a / ssm_dt / ssm_norm 要是 F32", i); goto fail;
            }
        } else {
            W(wqkv, "attn_qkv.weight", false);
            if (!L->wqkv.nbytes) {
                W(wq, "attn_q.weight", true);
                W(wk, "attn_k.weight", true);
                W(wv, "attn_v.weight", true);
            }
            W(wo, "attn_output.weight", true);
            W(q_norm, "attn_q_norm.weight", true);
            W(k_norm, "attn_k_norm.weight", true);
        }
        if (L->attn_norm.type != XJ_F32 || L->post_norm.type != XJ_F32) { snprintf(err, errlen, "第 %d 层 norm 要是 F32", i); goto fail; }
    }
#undef W

    uint64_t h = 1469598103934665603ull;
    h = fnv(h, hp, sizeof(*hp));
    for (uint64_t i = 0; i < g->n_tensors; i++) {
        const gguf_tensor *t = &g->tensors[i];
        h = fnv(h, t->name, strlen(t->name));
        h = fnv(h, &t->type, sizeof t->type);
        h = fnv(h, t->ne, sizeof t->ne);
        h = fnv(h, &t->offset, sizeof t->offset);
    }
    m->fingerprint = h;
    return m;
fail:
    free(m);
    return NULL;
}

xj_model *xj_model_load(const char *path, char *err, size_t errlen) {
    gguf_file *g = gguf_open(path, err, errlen);
    if (!g) return NULL;
    xj_model *m = xj_model_from_gguf(g, err, errlen);
    if (!m) gguf_close(g);
    return m;
}

static void fix_ptr(const gguf_file *g, xj_w *w) { if (w->nbytes) w->data = gguf_ptr(g, w->file_off, w->nbytes); }

xj_model *xj_model_load_layers(const char *path, int l0, int l1, bool with_io, char *err, size_t errlen) {
    gguf_file *g = gguf_open_header(path, err, errlen);
    if (!g) return NULL;
    xj_model *m = xj_model_from_gguf(g, err, errlen);
    if (!m) { gguf_close(g); return NULL; }
    if (l0 < 0 || l1 > m->hp.n_layer || l0 >= l1) { snprintf(err, errlen, "层范围 [%d,%d) 不对", l0, l1); xj_model_free(m); return NULL; }
    uint64_t r[512][2];
    int n = xj_model_ranges(m, l0, l1, with_io, r, 512);
    if (n <= 0 || !gguf_map_range(g, r[0][0], r[n - 1][1], err, errlen)) {
        if (n <= 0) snprintf(err, errlen, "这几层没有权重");
        xj_model_free(m);
        return NULL;
    }
    fix_ptr(g, &m->tok_embd); fix_ptr(g, &m->output_norm); fix_ptr(g, &m->output);
    for (int i = 0; i < m->hp.n_layer; i++) {
        xj_w *ws = (xj_w *)&m->layers[i].attn_norm;
        int count = (int)((sizeof(xj_layer) - offsetof(xj_layer, attn_norm)) / sizeof(xj_w));
        for (int k = 0; k < count; k++) fix_ptr(g, &ws[k]);
    }
    return m;
}

void xj_model_free(xj_model *m) {
    if (!m) return;
    gguf_close(m->gguf);
    free(m);
}

static int add_w(const xj_w *w, uint64_t (*r)[2], int n, int max) {
    if (!w->nbytes || n >= max) return n;
    r[n][0] = w->file_off;
    r[n][1] = w->file_off + w->nbytes;
    return n + 1;
}

static int cmp_range(const void *a, const void *b) {
    const uint64_t *x = a, *y = b;
    return x[0] < y[0] ? -1 : x[0] > y[0];
}

int xj_model_ranges(const xj_model *m, int l0, int l1, bool include_embd, uint64_t (*r)[2], int max) {
    int n = 0;
    if (include_embd) {
        n = add_w(&m->tok_embd, r, n, max);
        n = add_w(&m->output_norm, r, n, max);
        if (m->output.file_off != m->tok_embd.file_off) n = add_w(&m->output, r, n, max);
    }
    for (int i = l0; i < l1; i++) {
        const xj_w *ws = (const xj_w *)&m->layers[i].attn_norm;
        int count = (int)((sizeof(xj_layer) - offsetof(xj_layer, attn_norm)) / sizeof(xj_w));
        for (int k = 0; k < count; k++) n = add_w(&ws[k], r, n, max);
    }
    qsort(r, n, sizeof(r[0]), cmp_range);
    int k = 0;
    for (int i = 0; i < n; i++) {
        if (k && r[i][0] <= r[k - 1][1] + 4096) { if (r[i][1] > r[k - 1][1]) r[k - 1][1] = r[i][1]; }
        else { r[k][0] = r[i][0]; r[k][1] = r[i][1]; k++; }
    }
    return k;
}

uint64_t xj_model_layer_bytes(const xj_model *m, int l0, int l1) {
    uint64_t s = 0;
    for (int i = l0; i < l1; i++) {
        const xj_w *ws = (const xj_w *)&m->layers[i].attn_norm;
        int count = (int)((sizeof(xj_layer) - offsetof(xj_layer, attn_norm)) / sizeof(xj_w));
        for (int k = 0; k < count; k++) s += ws[k].nbytes;
    }
    return s;
}
