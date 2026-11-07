#!/usr/bin/env python3
"""拿 core/xj_tok.c 的分词结果和官方分词器（Hugging Face tokenizers + tokenizer.json）逐条对照。

    python3 tests/tok_check.py 模型.gguf tokenizer.json [tests/tok_corpus.jsonl]

语料每行一个 JSON 字符串（这样可以带换行、制表符）。有不一致就打印出来并以 1 退出。
"""
import json
import subprocess
import sys

from tokenizers import Tokenizer

gguf, tj = sys.argv[1], sys.argv[2]
corpus = sys.argv[3] if len(sys.argv) > 3 else "tests/tok_corpus.jsonl"
tok = Tokenizer.from_file(tj)

cases = [json.loads(l) for l in open(corpus, encoding="utf-8") if l.strip()]
bad = 0
for text in cases:
    want = tok.encode(text, add_special_tokens=False).ids
    out = subprocess.run(["./build/xjpipe-tok", gguf], input=text.encode(), capture_output=True, check=True)
    got = [int(x) for x in out.stdout.split()]
    if got != want:
        bad += 1
        # 找到第一个不一样的位置，前后各打几个
        i = next((k for k in range(min(len(got), len(want))) if got[k] != want[k]), min(len(got), len(want)))
        show = lambda ids: " ".join(repr(tok.decode([x])) for x in ids[max(0, i - 2):i + 4])
        print(f"不一致：{text!r}")
        print(f"  官方 {len(want)} 个：…{show(want)}")
        print(f"  我们 {len(got)} 个：…{show(got)}")
print(f"{len(cases)} 条里 {len(cases) - bad} 条和官方分词器一致")
sys.exit(1 if bad else 0)
