"""造 小橘推送 本地模型的训练数据：一句中文 → 一条 JSON 工具调用。

系统提示直接用 App 里那份（从 Command.swift 抠出来，和手机上一模一样），任务列表每条随机换，
让模型学会看列表而不是背名字。输出 train.jsonl / eval.jsonl，每行 {"text": 完整对话}。

用法：python3 scripts/finetune/make_data.py [条数，默认 1600]
"""
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "local-model-test"))
import run  # noqa: E402  build() 拼系统提示

MODEL = "Qwen3.5-4B"
rnd = random.Random(42)

# 任务名池（名字, 云盘路径, 仓库）
TASK_POOL = [
    ("meta-work", "/meta work", "langhua98/meta-work"),
    ("xiaoju-video", "/代码/xiaoju-video", "langhua98/xiaoju-video"),
    ("xiaoju-cloud", "/代码/xiaoju-cloud", "langhua98/xiaoju-cloud"),
    ("open-code", "/open-code", "langhua98/open-code"),
    ("pocketpal-ai", "/代码/pocketpal-ai", "langhua98/pocketpal-ai"),
    ("blog", "/写作/blog", "langhua98/blog"),
    ("小程序", "/项目/小程序", "langhua98/mini-app"),
    ("douyin-proxy", "/hf/douyin-proxy", "langhua98/douyin-proxy"),
    ("记账", "/代码/记账", "langhua98/ledger"),
    ("官网", "/项目/官网", "langhua98/website"),
]
FOLDERS = ["7day", "docs", "cloude审阅", "build", "node_modules", "测试数据", "old", "assets", "备份", "dist", "temp", "截图"]
FILES = ["PushEngine", "ChatView.swift", "README", "config.json", "main.py", "index.html", "Theme", "部署说明", "package.json",
         "LocalModel.swift", "设计稿", "todo.md", "app.js", "requirements.txt"]
CLOUD_DIRS = ["/代码", "/归档", "/项目", "/写作", "/meta work", "/hf", "/临时"]
FACTS = ["提交说明用中文", "meta-work 的代码在 /meta work", "推送前先给我看改动", "7day 文件夹永远不推", "我喜欢简短的回答",
         "测试代码放在 tests 目录", "周末不要自动推送", "分支用 main"]
CODE_ASKS = ["帮我写个登录页面", "这段代码为什么报错", "解释一下 PushEngine 是干什么的", "给 {t} 加个单元测试", "优化一下 {t} 的启动速度",
             "帮我审查一下 {t} 最近的改动", "写个提交说明", "把这个函数改成异步", "{t} 的 README 帮我重写", "帮我看看有没有内存泄漏",
             "这个项目用的什么框架", "为什么推送失败了", "给 {t} 加个暗色模式", "帮我修一下编译错误", "画个架构图给我",
             "把 {t} 里的 print 都换成日志", "帮我把这些文件整理一下目录结构", "怎么在 iOS 上跑 llama.cpp"]


def pick(xs):
    return rnd.choice(xs)


def maybe_space(t):
    return t if rnd.random() < 0.6 else t.replace(" ", "")


def J(**kw):
    return json.dumps(kw, ensure_ascii=False, separators=(",", ":"))


def example(tasks, current):
    """返回 (用户这句, 上下文或 None, 期望 JSON)"""
    names = [n for n, _, _ in tasks]
    t = pick(names)
    kind = rnd.choices(
        ["push", "push_skip", "check", "check_skip", "status", "history", "exclude", "find", "list", "list_dir", "mkdir",
         "rename", "move", "trash", "remember", "cloud", "handoff", "answer", "say"],
        weights=[7, 4, 8, 6, 4, 4, 4, 6, 6, 4, 3, 3, 3, 3, 4, 10, 4, 10, 3])[0]
    f, g = rnd.sample(FOLDERS, 2)
    if kind == "push":
        s = pick(["推送 {t}", "把 {t} 推上去", "{t} 推一下", "帮我把 {t} 提交到 GitHub", "同步 {t} 到 github", "{t} 可以推了",
                  "把 {t} 的改动推送", "push {t}", "推一下 {t} 吧"]).format(t=t)
        return s, None, J(do="push", task=t)
    if kind == "push_skip":
        s = pick(["推送 {t}，{f} 先别推", "把 {t} 推上去，跳过 {f}", "{t} 推一下，除了 {f} 文件夹", "推送 {t} 但是不要推 {f} 和 {g}"])
        s = s.format(t=t, f=f, g=g)
        skip = [f, g] if "{g}" in s or g in s else [f]
        return s, None, J(do="push", task=t, skip=skip)
    if kind == "check":
        s = pick(["{t} 改了什么", "检查一下 {t}", "看看 {t} 有什么改动", "{t} 有没有新改动", "{t} 这次动了哪些文件", "检查 {t} 的代码",
                  "对比一下 {t} 和 GitHub", "{t} 和线上有什么不一样"]).format(t=t)
        return s, None, J(do="check", task=t)
    if kind == "check_skip":
        s = pick(["检查 {t} 除了子目录下的 {f} 文件夹不需要检查", "检查一下 {t}，{f} 不用管", "看看 {t} 改了什么，跳过 {f} 和 {g}",
                  "检查云盘代码 除了 {f} 不需要检查", "{t} 检查一下，{f} 文件夹别看", "检查 {t}，忽略 {f}"]).format(t=t, f=f, g=g)
        if "云盘代码" in s:
            t = current or t
        skip = [f, g] if g in s else [f]
        return s, None, J(do="check", task=t, skip=skip)
    if kind == "status":
        return pick(["所有任务有改动吗", "哪些任务要推", "看看各个项目的状态", "现在有什么待推的", "全部任务检查一遍",
                     "我的项目都怎么样了"]), None, J(do="status")
    if kind == "history":
        s = pick(["{t} 的推送记录", "{t} 上次推了什么", "看看 {t} 的历史", "{t} 推过哪些东西", "最近 {t} 推送了几次"]).format(t=t)
        return s, None, J(do="history", task=t)
    if kind == "exclude":
        s = pick(["以后 {t} 的 {f} 都不要推", "{t} 以后一直别推 {f}", "{f} 文件夹以后永远不推（{t}）", "{t} 里的 {f} 从此不要提交"])
        return s.format(t=t, f=f), None, J(do="exclude", task=t, path=f)
    if kind == "find":
        k = pick(FILES)
        s = pick(["找一下 {k}", "{k} 在哪", "搜一下 {k} 文件", "帮我找找 {k}", "云盘里有没有 {k}", "{k} 放哪了"]).format(k=k)
        return s, None, J(do="find", keyword=k)
    if kind == "list":
        s = pick(["查看一下云盘有哪些文件夹", "读取小橘云盘列出所有文件夹", "本地模型去读取小橘云盘列出所有文件夹", "看看云盘里有什么",
                  "列一下云盘根目录", "云盘里都有哪些东西", "读取一下云盘有哪些文件夹", "小橘云盘的目录结构给我看看"])
        return s, None, J(do="list", folder="/")
    if kind == "list_dir":
        d = pick(CLOUD_DIRS)
        s = pick(["{d} 里有什么文件", "看看 {d} 下面有哪些文件夹", "列出 {d} 里的东西", "打开 {d} 看看"]).format(d=d)
        return s, None, J(do="list", folder=d)
    if kind == "mkdir":
        d, x = pick(CLOUD_DIRS), pick(["新项目", "demo", "备份", "素材", "test"])
        s = pick(["在 {d} 下面新建一个 {x} 文件夹", "{d} 里建个 {x}", "帮我创建 {d}/{x}"]).format(d=d, x=x)
        return s, None, J(do="mkdir", path=f"{d}/{x}")
    if kind == "rename":
        d, x, y = pick(CLOUD_DIRS), pick(["demo", "旧版", "test"]), pick(["demo2", "存档", "测试"])
        s = pick(["把 {d}/{x} 改名为 {y}", "{d}/{x} 重命名成 {y}", "{d}/{x} 改成叫 {y}"]).format(d=d, x=x, y=y)
        return s, None, J(do="rename", path=f"{d}/{x}", to=y)
    if kind == "move":
        d, x = pick(CLOUD_DIRS), pick(["demo", "旧版", "截图", "草稿"])
        s = pick(["把 {d}/{x} 移到 /归档", "{d}/{x} 挪到 /归档 去", "把 {d}/{x} 放进 /归档"]).format(d=d, x=x)
        return s, None, J(do="move", path=f"{d}/{x}", to="/归档")
    if kind == "trash":
        d, x = pick(CLOUD_DIRS), pick(["temp", "旧版", "test.txt", "草稿"])
        s = pick(["删掉 {d}/{x}", "把 {d}/{x} 放回收站", "{d}/{x} 不要了", "清理一下 {d}/{x}"]).format(d=d, x=x)
        return s, None, J(do="trash", path=f"{d}/{x}")
    if kind == "remember":
        x = pick(FACTS)
        s = pick(["记住{x}", "记一下：{x}", "以后{x}", "你记错了，{x}"]).format(x=x)
        return s, None, J(do="remember", text=x)
    if kind == "cloud":
        s = pick(CODE_ASKS).format(t=t)
        return s, None, J(do="cloud", text=s)
    if kind == "handoff":
        prev = pick(CODE_ASKS).format(t=t)
        s = pick(["交给云端模型处理", "让云端来做", "交给 OpenCode", "你搞不定就交给大模型", "问问云端"])
        return s, f"上一句：{prev}", J(do="cloud", text=prev)
    if kind == "say":
        if current or len(names) == 1:
            return example(tasks, current)
        s = pick(["推送", "检查一下", "看看推送记录"])
        return s, None, J(do="say", text="是哪个任务？有：" + "、".join(names))
    # answer
    qa = [
        ("你是谁", f"我是小橘推送里的本地模型 {MODEL}，在你手机上跑，不联网。"),
        ("你是什么模型", f"我是 {MODEL}，跑在你的 iPhone 上，不联网。"),
        ("你现在是什么模型", f"我是 {MODEL}，跑在你的 iPhone 上，不联网。"),
        ("你好", "你好！要推送、检查改动、找文件，还是交给云端写代码？"),
        ("在吗", "在的，直接说要做什么就行。"),
        ("早上好", "早上好！今天要推哪个项目？"),
        ("谢谢", "不客气，有事再叫我。"),
        ("你能做什么", "我能检查改动、推送到 GitHub、看推送记录、在云盘找文件和整理文件、记住你的约定；写代码改 bug 交给云端 OpenCode。"),
        ("你可以调用哪些工具", "推送、检查改动、推送记录、找文件、看文件夹、新建/改名/移动/删除文件、记住约定，还有交给云端 OpenCode。"),
        ("列举你可以调用的技能", "推送、检查改动、看推送记录、找文件、列文件夹、整理云盘文件、记住约定；难的交给云端 OpenCode。"),
        ("这个 App 怎么用", "直接说一句话就行，比如「推送 meta-work」「找一下 README」。会改东西的都会先出确认卡片。"),
        ("你联网吗", "我不联网，在你手机上跑；要联网查东西或写代码会交给云端 OpenCode。"),
        ("你好笨", "抱歉，没听懂的话可以说具体一点，或者让我交给云端处理。"),
        ("1+1等于几", "等于 2。"),
        ("今天天气怎么样", "我不联网，看不了天气。代码上的事随时叫我。"),
    ]
    q, a = pick(qa)
    return q, None, J(do="answer", text=a)


def render(prefix, user, ctx, answer):
    last = f"（{ctx}）\n" if ctx else ""
    return (prefix + f"<|im_start|>user\n{last}{user}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
            + answer + "<|im_end|>\n")


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 1600
    rows = []
    for _ in range(n):
        tasks = rnd.sample(TASK_POOL, rnd.randint(1, 4))
        current = rnd.choice([None, None, rnd.choice(tasks)[0]])
        prefix, _ = run.build(tasks=tasks, current=current)
        prefix = prefix.replace("Qwen3.5-2B", MODEL)
        user, ctx, ans = example(tasks, current)
        json.loads(ans)  # 必须是合法 JSON
        rows.append({"text": render(prefix, maybe_space(user), ctx, ans)})
    rnd.shuffle(rows)
    cut = max(50, n // 20)
    out = os.path.join(HERE, "data")
    os.makedirs(out, exist_ok=True)
    for name, part in (("eval.jsonl", rows[:cut]), ("train.jsonl", rows[cut:])):
        with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
            for r in part:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"train {n - cut} 条，eval {cut} 条 → {out}")


if __name__ == "__main__":
    main()
