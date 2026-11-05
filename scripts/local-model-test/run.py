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

# (问题, 期望的指令[, 上一句 / 上一步, 期望 skip 里有的文件夹])
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
    ("你好", {"answer"}),
    ("查看一下云盘有哪些文件夹", {"list"}),
    ("读取小橘云盘列出所有文件夹", {"list"}),
    ("检查云盘代码 除了子目录下的7day文件夹不需要检查", {"check"}, None, "7day"),
    ("交给云端模型处理", {"cloud"}, "上一句：给 xiaoju-video 写个 README"),
    ("搜一下代码里哪里有 TODO", {"run"}),
    ("main.py 里面是什么", {"run"}),
    ("这个项目有多少个 swift 文件", {"run"}),
    ("运行命令 pwd", {"run"}),
]


def swift_string(src, start):
    """从 start 之后取第一个 Swift 多行字符串（\"\"\" 或 #\"\"\"），按收尾缩进去掉前导空格。"""
    m = re.compile(r'(#?)"""\n(.*?)\n([ ]*)"""\1', re.S).search(src, start)
    body, indent = m.group(2), len(m.group(3))
    return "\n".join(l[indent:] if l.startswith(" " * indent) else l.lstrip() for l in body.split("\n"))


# 和 Connectors.swift 一致：指令 → 「连接器 · 工具」
LABELS = {
    "find": "小橘云盘 · 找文件", "list": "小橘云盘 · 看文件夹", "mkdir": "小橘云盘 · 新建文件夹", "rename": "小橘云盘 · 改名",
    "move": "小橘云盘 · 移动", "trash": "小橘云盘 · 放进回收站", "remember": "小橘云盘 · 读写记忆",
    "check": "GitHub · 检查改动", "status": "GitHub · 检查改动", "history": "GitHub · 推送记录", "push": "GitHub · 推送",
    "exclude": "GitHub · 设置不推的文件夹", "run": "本机命令 · 运行命令", "cloud": "OpenCode（云端） · 交给云端处理",
}
ALL_KINDS = ["push", "check", "status", "history", "exclude", "find", "list", "mkdir", "rename", "move", "trash", "remember", "run", "cloud", "say", "answer"]


def build(tasks=None, current=None, disabled=(), memory=""):
    """返回（系统提示前缀, 语法）。tasks 默认用 TASKS；current 是当前任务名；disabled 是连接器里关掉的指令。"""
    tasks = tasks or TASKS
    src = open(SRC, encoding="utf-8").read()
    task_lines = "\n".join(f"- {n}：云盘 {c} → {r}" for n, c, r in tasks)
    i = src.index("var sys = \"\"\"")
    sys_ = swift_string(src, i).replace('\\(taskLines.isEmpty ? "（还没有任务）" : taskLines)', task_lines)
    if current:
        sys_ += f"\n当前任务：{current}"
    if memory.strip():
        sys_ += "\n记忆（用户的约定，路径以这里为准）：\n" + memory.strip()[:1200]
    j = src.index("sys += \"\"\"", i)
    sys_ += swift_string(src, j)
    if disabled:
        off = list(disabled)
        sys_ = "\n".join(l for l in sys_.split("\n") if not any('{"do":"%s"' % k in l for k in off))
        sys_ += "\n这些事用户关掉了，做不了，被问到就用 answer 说一声：" + "、".join(LABELS[k] for k in off if k in LABELS)
    assert "\\(" not in sys_, "提示词里还有没替换的插值：" + sys_[sys_.index("\\("):][:60]
    k = src.index("return #\"\"\"")
    names = " | ".join('"\\"' + n + '\\""' for n, _, _ in tasks)
    alts = " | ".join(k for k in ALL_KINDS if k not in disabled)
    grammar = swift_string(src, k).replace("TASKS", names).replace("ALTS", alts)
    prefix = f"<|im_start|>system\n{sys_}<|im_end|>\n"
    return prefix, grammar


def ask(prefix, grammar, text, ctx=None):
    last = f"（{ctx}）\n" if ctx else ""
    prompt = prefix + f"<|im_start|>user\n{last}{text}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
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
    for case in CASES:
        text, want = case[0], case[1]
        ctx = case[2] if len(case) > 2 else None
        skip = case[3] if len(case) > 3 else None
        out, t = ask(prefix, grammar, text, ctx)
        try:
            o = json.loads(out[out.index("{"): out.rindex("}") + 1])
            got = o.get("do")
        except Exception:
            o, got = {}, None
        ok = got in want and (skip is None or any(skip in x for x in o.get("skip", [])))
        bad += not ok
        secs = (t.get("prompt_ms", 0) + t.get("predicted_ms", 0)) / 1000
        print(f"{'✓' if ok else '✗'} {text}\n   → {out.strip()}   ({secs:.1f} 秒，期望 {'/'.join(want)})\n")
    print(f"{len(CASES) - bad}/{len(CASES)} 通过")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
