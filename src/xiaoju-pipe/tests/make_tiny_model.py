#!/usr/bin/env python3
"""生成一个很小的、随机权重的 Qwen3.5 GGUF（结构和真模型一样：每 4 层 3 层线性注意力 + 1 层全注意力）。

不用联网下载模型，就能在电脑 / CI 上把整条链路跑一遍：单机 vs 拆两段、断线重连后接着算。
权重是随机的，说出来的是乱码，但贪心解码是确定的，可以逐字对照。

    python3 tests/make_tiny_model.py /tmp/tiny.gguf
    python3 tests/make_tiny_model.py /tmp/tiny-mtp.gguf --mtp   # 多一层 MTP（投机解码用），主干权重一样
"""
import struct
import sys

import numpy as np

E, FF, LAYERS = 64, 128, 8
H, HKV, D, NROT = 4, 2, 16, 8          # 全注意力：4 个 query 头、2 个 kv 头、头维度 16
SK, HK, HV = 16, 2, 4                  # 线性注意力：key 头 2 个、value 头 4 个、每头 16 维
D_INNER = HV * SK
CONV_K = 4
CONV_DIM = 2 * SK * HK + D_INNER
ALIGN = 32

rng = np.random.default_rng(20261107)

# ---- 词表：GPT-2 字节映射的 256 个单字节 + 一些合并 + 特殊词 ----
def byte_chars():
    out, n = {}, 0
    for b in range(256):
        vis = 33 <= b <= 126 or 161 <= b <= 172 or 174 <= b <= 255
        out[b] = chr(b) if vis else chr(256 + n)
        if not vis:
            n += 1
    return out

bc = byte_chars()
tokens = [bc[b] for b in range(256)]
merges = []
for pair in ["t h", "th e", "Ġ t", "Ġt he", "i n", "e r", "a n", "o n", "e n", "Ġ a"]:
    a, b = pair.split(" ")
    merges.append(pair)
    tokens.append(a + b)
# 几个汉字（UTF-8 三个字节 → 两次合并）
for ch in "北京你好":
    bs = [bc[x] for x in ch.encode()]
    merges.append(f"{bs[0]} {bs[1]}"); tokens.append(bs[0] + bs[1])
    merges.append(f"{bs[0] + bs[1]} {bs[2]}"); tokens.append("".join(bs))
SPECIAL = ["<|endoftext|>", "<|im_start|>", "<|im_end|>"]
tokens += SPECIAL
tokens = list(dict.fromkeys(tokens))
V = len(tokens) + (-len(tokens)) % 32   # 补齐，输出头行数是 32 的倍数
while len(tokens) < V:
    tokens.append(f"<|pad{len(tokens)}|>")

# ---- 权重 ----
def f32(*shape, scale=None):
    # shape 按 ggml 的顺序：(ne0 = 输入维度, ne1 = 输出维度)
    n_in = shape[0]
    s = scale if scale is not None else 1.0 / np.sqrt(n_in)
    return np.asarray(rng.standard_normal(shape[::-1]) * s, dtype=np.float32)

def q8_0(arr):
    """F32 [rows][cols] → Q8_0 字节（cols 是 32 的倍数）"""
    rows, cols = arr.shape
    out = bytearray()
    for r in range(rows):
        for b in range(0, cols, 32):
            blk = arr[r, b:b + 32]
            amax = float(np.abs(blk).max())
            d = amax / 127 if amax else 0.0
            q = np.zeros(32, np.int8) if d == 0 else np.round(blk / d).astype(np.int8)
            out += struct.pack("<e", d) + q.tobytes()
    return bytes(out)

tensors = []  # (名字, ne 列表, ggml 类型, 字节)

def add(name, arr, typ=0):
    ne = list(arr.shape[::-1])
    data = arr.astype(np.float32).tobytes() if typ == 0 else q8_0(arr)
    tensors.append((name, ne, typ, data))

def norm_w(n):
    return np.asarray(1.0 + 0.1 * rng.standard_normal(n), dtype=np.float32)

add("token_embd.weight", f32(E, V, scale=1.0), 8)
add("output_norm.weight", norm_w(E))
add("output.weight", f32(E, V), 8)
for i in range(LAYERS):
    p = f"blk.{i}."
    add(p + "attn_norm.weight", norm_w(E))
    add(p + "post_attention_norm.weight", norm_w(E))
    add(p + "ffn_gate.weight", f32(E, FF), 8)
    add(p + "ffn_up.weight", f32(E, FF), 8)
    add(p + "ffn_down.weight", f32(FF, E))
    if (i + 1) % 4:
        add(p + "attn_qkv.weight", f32(E, CONV_DIM), 8)
        add(p + "attn_gate.weight", f32(E, D_INNER), 8)
        add(p + "ssm_conv1d.weight", f32(CONV_K, CONV_DIM, scale=0.5))
        add(p + "ssm_dt.bias", np.asarray(rng.standard_normal(HV) * 0.5, dtype=np.float32))
        add(p + "ssm_a", np.asarray(-np.exp(rng.standard_normal(HV) * 0.5), dtype=np.float32))
        add(p + "ssm_beta.weight", f32(E, HV))
        add(p + "ssm_alpha.weight", f32(E, HV))
        add(p + "ssm_norm.weight", norm_w(SK))
        add(p + "ssm_out.weight", f32(D_INNER, E))
    else:
        add(p + "attn_q.weight", f32(E, 2 * H * D), 8)
        add(p + "attn_k.weight", f32(E, HKV * D))
        add(p + "attn_v.weight", f32(E, HKV * D))
        add(p + "attn_output.weight", f32(H * D, E))
        add(p + "attn_q_norm.weight", norm_w(D))
        add(p + "attn_k_norm.weight", norm_w(D))

MTP = "--mtp" in sys.argv[2:]
if MTP:
    # MTP 层：blk.{LAYERS}，一个全注意力层 + nextn.*（和 prithivMLmods 的 Qwen3.5-*-MTP-GGUF 一样的名字）
    p = f"blk.{LAYERS}."
    add(p + "attn_norm.weight", norm_w(E))
    add(p + "post_attention_norm.weight", norm_w(E))
    add(p + "ffn_gate.weight", f32(E, FF), 8)
    add(p + "ffn_up.weight", f32(E, FF), 8)
    add(p + "ffn_down.weight", f32(FF, E))
    add(p + "attn_q.weight", f32(E, 2 * H * D), 8)
    add(p + "attn_k.weight", f32(E, HKV * D))
    add(p + "attn_v.weight", f32(E, HKV * D))
    add(p + "attn_output.weight", f32(H * D, E))
    add(p + "attn_q_norm.weight", norm_w(D))
    add(p + "attn_k_norm.weight", norm_w(D))
    add(p + "nextn.eh_proj.weight", f32(2 * E, E), 8)
    add(p + "nextn.enorm.weight", norm_w(E))
    add(p + "nextn.hnorm.weight", norm_w(E))
    add(p + "nextn.shared_head_norm.weight", norm_w(E))

# ---- 写 GGUF v3 ----
def s(x):
    b = x.encode()
    return struct.pack("<Q", len(b)) + b

U32, F32_, STR, ARR = 4, 6, 8, 9
kvs = [
    ("general.architecture", STR, "qwen35"),
    ("general.name", STR, "xiaoju-tiny-random"),
    ("general.alignment", U32, ALIGN),
    ("qwen35.block_count", U32, LAYERS + (1 if MTP else 0)),
    ("qwen35.context_length", U32, 4096),
    ("qwen35.embedding_length", U32, E),
    ("qwen35.feed_forward_length", U32, FF),
    ("qwen35.attention.head_count", U32, H),
    ("qwen35.attention.head_count_kv", U32, HKV),
    ("qwen35.attention.key_length", U32, D),
    ("qwen35.attention.value_length", U32, D),
    ("qwen35.rope.dimension_count", U32, NROT),
    ("qwen35.rope.freq_base", F32_, 10000000.0),
    ("qwen35.attention.layer_norm_rms_epsilon", F32_, 1e-6),
    ("qwen35.ssm.conv_kernel", U32, CONV_K),
    ("qwen35.ssm.inner_size", U32, D_INNER),
    ("qwen35.ssm.state_size", U32, SK),
    ("qwen35.ssm.group_count", U32, HK),
    ("qwen35.ssm.time_step_rank", U32, HV),
    ("qwen35.full_attention_interval", U32, 4),
] + ([("qwen35.nextn_predict_layers", U32, 1)] if MTP else []) + [
    ("tokenizer.ggml.model", STR, "gpt2"),
    ("tokenizer.ggml.tokens", ARR, (STR, tokens)),
    ("tokenizer.ggml.merges", ARR, (STR, merges)),
    ("tokenizer.ggml.eos_token_id", U32, tokens.index("<|im_end|>")),
]

def kv_bytes(k, t, v):
    out = s(k) + struct.pack("<I", t)
    if t == U32:
        out += struct.pack("<I", v)
    elif t == F32_:
        out += struct.pack("<f", v)
    elif t == STR:
        out += s(v)
    else:
        et, items = v
        out += struct.pack("<IQ", et, len(items)) + b"".join(s(x) for x in items)
    return out

hdr = b"GGUF" + struct.pack("<IQQ", 3, len(tensors), len(kvs))
hdr += b"".join(kv_bytes(*kv) for kv in kvs)
off = 0
offsets = []
for name, ne, typ, data in tensors:
    off = (off + ALIGN - 1) // ALIGN * ALIGN
    offsets.append(off)
    hdr += s(name) + struct.pack("<I", len(ne)) + b"".join(struct.pack("<Q", n) for n in ne)
    hdr += struct.pack("<IQ", typ, off)
    off += len(data)
hdr += b"\0" * ((-len(hdr)) % ALIGN)

with open(sys.argv[1], "wb") as f:
    f.write(hdr)
    for (name, ne, typ, data), o in zip(tensors, offsets):
        f.write(b"\0" * (len(hdr) + o - f.tell()))
        f.write(data)
print(f"{sys.argv[1]}：{LAYERS} 层，词表 {V}，{len(tensors)} 个张量")
