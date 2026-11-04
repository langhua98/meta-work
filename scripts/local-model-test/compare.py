"""对比考试：原版和训练版跑同一套题，看分数差多少（不会让 CI 失败，只打印成绩）。

两套题：
1. 训练时留出来的 80 道（make_data.py 同样的种子生成，模板句子，模型训练时没见过这 80 句）
2. 30 句手写的口语（不是模板拼的，更像真人说话）

每题看两样：指令选对没有（do），关键参数对不对（任务名 / 路径 / 关键词 / 跳过的文件夹）。
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import run  # noqa: E402

HARD = [
    # (原话, 允许的指令, 要检查的参数 {键: 应包含的文字})
    ("把小橘视频那个项目传上去吧", {"push"}, {"task": "xiaoju-video"}),
    ("meta 那个仓库最近动过啥", {"check"}, {"task": "meta-work"}),
    ("帮我瞅瞅有没有要推的", {"status", "check"}, {}),
    ("上次推了些啥来着", {"history"}, {}),
    ("以后 node_modules 别再推了", {"exclude"}, {"path": "node_modules"}),
    ("这回先别管 docs，其它的都推上去", {"push"}, {"skip": "docs"}),
    ("PushEngine 那个文件在哪", {"find"}, {"keyword": "PushEngine"}),
    ("云盘根目录下都有啥", {"list"}, {}),
    ("建个文件夹叫 草稿", {"mkdir"}, {"path": "草稿"}),
    ("把 /代码/old 扔了", {"trash"}, {"path": "old"}),
    ("把 /代码/demo 改个名叫 demo2", {"rename"}, {"to": "demo2"}),
    ("/归档/a 挪回 /代码", {"move"}, {"path": "/归档/a"}),
    ("记一下：提交说明都用英文", {"remember"}, {}),
    ("这段代码为啥报空指针", {"cloud"}, {}),
    ("写个脚本把图片压缩一下", {"cloud"}, {}),
    ("帮我 review 一下最近的提交", {"cloud"}, {}),
    ("你会干嘛", {"answer"}, {}),
    ("谢谢啦", {"answer"}, {}),
    ("在吗", {"answer"}, {}),
    ("你用的什么模型", {"answer"}, {}),
    ("xiaoju-video 那个 7day 目录这次不用检查", {"check"}, {"task": "xiaoju-video", "skip": "7day"}),
    ("看看 /代码 文件夹里有什么", {"list"}, {"folder": "代码"}),
    ("找找名字里带 config 的文件", {"find"}, {"keyword": "config"}),
    ("把这个函数改成异步", {"cloud"}, {}),
    ("解释一下 Store.swift 是干嘛的", {"cloud"}, {}),
    ("同步一下 meta-work 到 GitHub", {"push"}, {"task": "meta-work"}),
    ("所有项目有没有没推的改动", {"status"}, {}),
    ("删掉 /临时", {"trash"}, {"path": "临时"}),
    ("以后都别推 build 文件夹", {"exclude"}, {"path": "build"}),
    ("今天天气不错", {"answer"}, {}),
]


def parse(out):
    try:
        return json.loads(out[out.index("{"): out.rindex("}") + 1])
    except Exception:
        return {}


def args_ok(o, want):
    for k, v in want.items():
        got = o.get(k)
        if isinstance(got, list):
            got = " ".join(got)
        if not got or v.lower() not in str(got).lower():
            return False
    return True


def hard_set():
    prefix, grammar = run.build()
    ok_do = ok_all = 0
    secs = 0.0
    for text, want_do, want_args in HARD:
        out, t = run.ask(prefix, grammar, text)
        secs += (t.get("prompt_ms", 0) + t.get("predicted_ms", 0)) / 1000
        o = parse(out)
        d = o.get("do") in want_do
        a = d and args_ok(o, want_args)
        ok_do += d
        ok_all += a
        print(f"{'✓' if a else ('△' if d else '✗')} {text}\n   → {out.strip()[:160]}   （期望 {'/'.join(want_do)} {want_args or ''}）")
    n = len(HARD)
    print(f"\n口语题：指令选对 {ok_do}/{n}，参数也对 {ok_all}/{n}，平均 {secs / n:.1f} 秒/题\n")
    return ok_do, ok_all, n


def held_out():
    here = os.path.dirname(__file__)
    gen = os.path.join(here, "..", "finetune", "make_data.py")
    subprocess.run([sys.executable, gen, "1600"], check=True, cwd=os.path.join(here, "..", ".."), stdout=subprocess.DEVNULL)
    path = os.path.join(here, "..", "finetune", "data", "eval.jsonl")
    rows = [json.loads(l) for l in open(path)]
    # 任务名在每题里不一样，语法就放开任务名，只锁 JSON 形状
    _, grammar = run.build()
    import re
    grammar = re.sub(r"^task ::= .*$", "task ::= str", grammar, flags=re.M)
    ok_do = ok_all = 0
    for r in rows:
        prompt, answer = r["text"].rsplit("</think>\n\n", 1)
        prompt += "</think>\n\n"
        want = json.loads(answer.replace("<|im_end|>\n", ""))
        body = json.dumps({"prompt": prompt, "grammar": grammar, "n_predict": 320, "temperature": 0, "top_k": 1,
                           "cache_prompt": True}).encode()
        import urllib.request
        req = urllib.request.Request(run.SERVER + "/completion", body, {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=300) as resp:
            out = json.load(resp)["content"]
        o = parse(out)
        d = o.get("do") == want.get("do")
        keys = [k for k in ("task", "path", "keyword", "to", "folder") if k in want]
        a = d and all(str(o.get(k, "")).strip() == str(want[k]).strip() for k in keys)
        ok_do += d
        ok_all += a
        if not a:
            user = prompt.rsplit("<|im_start|>user\n", 1)[1].split("<|im_end|>")[0].replace("\n", " ")
            print(f"{'△' if d else '✗'} {user[:60]} → {out.strip()[:120]}  期望 {json.dumps(want, ensure_ascii=False)}")
    n = len(rows)
    print(f"\n留出的模板题：指令选对 {ok_do}/{n}，参数也对 {ok_all}/{n}\n")
    return ok_do, ok_all, n


if __name__ == "__main__":
    t0 = time.time()
    a = hard_set()
    b = held_out()
    print(f"== 成绩 == 口语 {a[1]}/{a[2]}（指令 {a[0]}/{a[2]}） · 模板 {b[1]}/{b[2]}（指令 {b[0]}/{b[2]}） · 用时 {time.time() - t0:.0f} 秒")
