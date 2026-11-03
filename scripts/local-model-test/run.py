"""用手机上同一个本地模型（Qwen3.5-2B Q4_K_M）、同一份提示词和语法，跑一组问题，看它是不是该自己答的自己答。

提示词和语法直接从 App 源码 Command.swift 里抠出来，App 改了这里自动跟着变。
需要一个跑着的 llama-server（默认 http://127.0.0.1:8080）。
"""
import json
import re
import sys
import textwrap
import urllib.request

SRC = "src/xiaoju-push/App/Assistant/Command.swift"
SERVER = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"

TASKS = [("meta-work", "/meta work", "langhua98/meta-work"), ("xiaoju-video", "/代码/xiaoju-video", "langhua98/xiaoju-video")]

# (问题, 期望的指令)
CASES = [
    ("你是什么模型", {"answer"}),
    ("介绍一下你自己", {"answer"}),
    ("你可以使用什么工具", {"answer"}),
    ("你能帮我做什么", {"answer"}),
    ("这个 App 怎么用", {"answer"}),
    ("你好，今天怎么样", {"answer"}),
    ("推送 meta-work", {"push"}),
    ("meta-work 这次改了什么", {"check"}),
    ("找一下 PushEngine", {"find"}),
    ("把 /代码/demo 移到 /归档", {"move"}),
    ("帮我看看这次改动有没有 bug", {"cloud"}),
    ("给 xiaoju-video 写个 README", {"cloud"}),
]


def swift_string(src, start):
    """从 start 之后取第一个 Swift 多行字符串（\"\"\" 或 #\"\"\"），按收尾缩进去掉前导空格。"""
    m = re.compile(r'(#?)"""\n(.*?)\n([ ]*)"""\1', re.S).search(src, start)
    body, indent = m.group(2), len(m.group(3))
    return "\n".join(l[indent:] if l.startswith(" " * indent) else l.lstrip() for l in body.split("\n"))


def build():
    src = open(SRC, encoding="utf-8").read()
    task_lines = "\n".join(f"- {n}：云盘 {c} → {r}" for n, c, r in TASKS)
    i = src.index("var sys = \"\"\"")
    sys_ = swift_string(src, i).replace('\\(taskLines.isEmpty ? "（还没有任务）" : taskLines)', task_lines)
    j = src.index("sys += \"\"\"", i)
    sys_ += swift_string(src, j)
    assert "\\(" not in sys_, "提示词里还有没替换的插值：" + sys_[sys_.index("\\("):][:60]
    k = src.index("return #\"\"\"")
    names = " | ".join('"\\"' + n + '\\""' for n, _, _ in TASKS)
    grammar = swift_string(src, k).replace("TASKS", names)
    prefix = f"<|im_start|>system\n{sys_}<|im_end|>\n"
    return prefix, grammar


def ask(prefix, grammar, text):
    prompt = prefix + f"<|im_start|>user\n{text}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    body = json.dumps({"prompt": prompt, "grammar": grammar, "n_predict": 320, "temperature": 0,
                       "top_k": 1, "cache_prompt": True}).encode()
    req = urllib.request.Request(SERVER + "/completion", body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        out = json.load(r)
    return out["content"], out.get("timings", {})


def main():
    prefix, grammar = build()
    print("提示词", len(prefix), "字符\n")
    bad = 0
    for text, want in CASES:
        out, t = ask(prefix, grammar, text)
        try:
            got = json.loads(out[out.index("{"): out.rindex("}") + 1]).get("do")
        except Exception:
            got = None
        ok = got in want
        bad += not ok
        secs = (t.get("prompt_ms", 0) + t.get("predicted_ms", 0)) / 1000
        print(f"{'✓' if ok else '✗'} {text}\n   → {out.strip()}   ({secs:.1f} 秒，期望 {'/'.join(want)})\n")
    print(f"{len(CASES) - bad}/{len(CASES)} 通过")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
