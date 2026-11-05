"""造 小橘推送 本地模型的训练数据（第二版）：一句中文 → 一条 JSON 工具调用。

系统提示直接用 App 里那份（从 Command.swift 抠出来，和手机上一模一样），每条随机换：
任务列表、当前任务、记忆、连接器里关掉的工具。

比第一版多了：
- 说法更像真人：口头禅、语气词、语音识别没标点、大小写乱、半截任务名、用仓库名或云盘路径指任务
- 容易混的：「检查代码有没有 bug」「推荐个库」「删掉这行代码」是交给云端，不是检查 / 推送 / 删除
- 接着上一步说的：「再移回来」「那推上去吧」「看看它的推送记录」
- 记忆里的别名：「主项目」指 meta-work
- 连接器关掉了某个工具：选不到，被问到就说一声
- William 实测说过的原话（real_cases）
- 回答类问题更多、按连接器分开答
- 考试题用训练时没出现过的说法（每类说法留一部分只进考试）

用法：python3 scripts/finetune/make_data.py [条数，默认 3000]
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
MODE = "train"  # 或 "eval"：只用留给考试的说法

# 任务名池（名字, 云盘路径, 仓库, 口头叫法）
TASK_POOL = [
    ("meta-work", "/meta work", "langhua98/meta-work", ["meta work", "meta", "metawork"]),
    ("xiaoju-video", "/代码/xiaoju-video", "langhua98/xiaoju-video", ["小橘视频", "xiaoju video", "视频那个项目"]),
    ("xiaoju-cloud", "/代码/xiaoju-cloud", "langhua98/xiaoju-cloud", ["小橘云", "xiaoju cloud", "网盘那个项目"]),
    ("open-code", "/open-code", "langhua98/open-code", ["opencode", "open code"]),
    ("pocketpal-ai", "/代码/pocketpal-ai", "langhua98/pocketpal-ai", ["pocketpal", "口袋助手"]),
    ("blog", "/写作/blog", "langhua98/blog", ["博客"]),
    ("小程序", "/项目/小程序", "langhua98/mini-app", ["mini-app", "微信小程序"]),
    ("douyin-proxy", "/hf/douyin-proxy", "langhua98/douyin-proxy", ["抖音代理", "douyin proxy"]),
    ("记账", "/代码/记账", "langhua98/ledger", ["ledger", "记账本"]),
    ("官网", "/项目/官网", "langhua98/website", ["website", "网站"]),
    ("splat-relay", "/hf/splat-relay", "langhua98/splat-relay", ["splat", "中继"]),
    ("dotfiles", "/配置/dotfiles", "langhua98/dotfiles", ["配置文件", "dot files"]),
]
FOLDERS = ["7day", "docs", "cloude审阅", "build", "node_modules", "测试数据", "old", "assets", "备份", "dist", "temp", "截图",
           "Pods", ".venv", "logs", "素材", "草稿", "vendor", "outputs", "模型"]
FILES = ["PushEngine", "ChatView.swift", "README", "config.json", "main.py", "index.html", "Theme", "部署说明", "package.json",
         "LocalModel.swift", "设计稿", "todo.md", "app.js", "requirements.txt", "Dockerfile", "封面.png", ".env.example",
         "Store.swift", "train.ipynb", "会议记录", "logo.svg", "nginx.conf"]
CLOUD_DIRS = ["/代码", "/归档", "/项目", "/写作", "/meta work", "/hf", "/临时", "/素材", "/7day", "/配置", "/下载"]
NEW_NAMES = ["新项目", "demo", "备份", "素材", "test", "2026", "草稿", "实验", "截图", "old"]
FACTS = ["提交说明用中文", "meta-work 的代码在 /meta work", "推送前先给我看改动", "7day 文件夹永远不推", "我喜欢简短的回答",
         "测试代码放在 tests 目录", "周末不要自动推送", "分支用 main", "「主项目」指 meta-work", "截图都放 /素材/截图",
         "回答别用英文", "删除前先问我"]
CODE_ASKS = ["帮我写个登录页面", "这段代码为什么报错", "解释一下 PushEngine 是干什么的", "给 {t} 加个单元测试",
             "优化一下 {t} 的启动速度", "帮我审查一下 {t} 最近的改动", "写个提交说明", "把这个函数改成异步",
             "{t} 的 README 帮我重写", "帮我看看有没有内存泄漏", "这个项目用的什么框架", "为什么推送失败了",
             "给 {t} 加个暗色模式", "帮我修一下编译错误", "画个架构图给我", "把 {t} 里的 print 都换成日志",
             "帮我把这些文件整理一下目录结构", "怎么在 iOS 上跑 llama.cpp", "写个脚本把图片压缩一下", "这个 bug 怎么修",
             "解释一下 Store.swift", "帮我 review 一下最近的提交", "{t} 为什么编译不过", "加个下拉刷新",
             "把接口改成 async/await", "这个正则什么意思", "帮我生成一个 Dockerfile", "{t} 怎么部署到 HF",
             "用 Python 写个爬虫", "这段 SQL 有没有注入风险", "帮我翻译一下这段注释", "{t} 的依赖要不要升级"]
# 看起来像别的指令，其实是写代码 / 问问题，要交给云端
CONFUSABLE = ["检查一下代码有没有 bug", "检查下 {t} 的逻辑对不对", "推荐几个好用的 Swift 库", "推荐个 Python 日志库",
              "找找 {t} 里的性能问题", "找出哪里内存泄漏了", "删掉没用的 import", "把这行代码删了", "把这个变量改个名",
              "把这个函数移到工具类里", "记录一下每次请求的耗时（加日志）", "看看 {t} 的代码写得怎么样", "这次改动安全吗",
              "推送通知怎么做", "怎么实现消息推送", "把文件夹结构重新设计一下", "新建一个 SwiftUI 页面",
              "给 {t} 新建一个设置页", "检查下这个函数的边界情况", "移动端适配怎么做"]

FILL_PRE = ["", "", "", "帮我", "麻烦", "你", "嗯", "那个", "好的，", "哎，", "请", "小橘，", "现在", "快"]
FILL_SUF = ["", "", "", "吧", "一下", "呗", "，谢谢", "！", "。", "啊", "哈", "好吗", "可以吗"]


def pick(xs):
    """每类说法：下标 %6==5 的留给考试，其他训练用"""
    if len(xs) >= 6:
        part = [x for i, x in enumerate(xs) if (i % 6 == 5) == (MODE == "eval")]
        if part:
            return rnd.choice(part)
    return rnd.choice(xs)


def J(**kw):
    return json.dumps(kw, ensure_ascii=False, separators=(",", ":"))


def noisy(s):
    """像真人打字或语音识别出来的样子"""
    r = rnd.random()
    if r < 0.2:  # 语音识别：没标点、没空格
        for ch in "，。！？、：,!? ":
            s = s.replace(ch, "")
    elif r < 0.45:
        s = s.replace(" ", "")
    if rnd.random() < 0.15:
        s = s.replace("GitHub", rnd.choice(["github", "Github", "git hub", "GITHUB"]))
    if rnd.random() < 0.1:
        s = s.replace("云盘", rnd.choice(["网盘", "云端盘", "云盘里"]))
    return s


def fill(s):
    if rnd.random() < 0.45:
        s = rnd.choice(FILL_PRE) + s
    if rnd.random() < 0.45:
        s = s + rnd.choice(FILL_SUF)
    return s


def ref(t):
    """用户怎么叫这个任务：名字、半截、仓库名、口头叫法"""
    name, path, repo, alias = t
    r = rnd.random()
    if r < 0.55:
        return name if rnd.random() < 0.7 else name.upper() if name.isascii() else name
    if r < 0.8:
        return rnd.choice(alias)
    if r < 0.9:
        return repo
    return path.rsplit("/", 1)[-1]


SRC_FILES = ["README.md", "ChatView.swift", "config.json", "main.py", "package.json", "Dockerfile", "requirements.txt",
             "todo.md", "app.js", "nginx.conf", "Store.swift", "project.yml", "index.html", ".gitignore", "LocalModel.swift"]
KEYWORDS = ["cloudToken", "TODO", "PushEngine", "fetchUser", "apiKey", "localhost", "ShellRunner", "viewDidLoad", "FIXME",
            "password", "baseURL", "print(", "useState", "@MainActor", "timeout"]
EXTS = [("swift", "swift"), ("py", "Python"), ("js", "js"), ("md", "Markdown"), ("json", "json"), ("html", "html")]
LITERAL = ["ls -la", "pwd", "git status", "git log --oneline -5", "wc -l README.md", "cat package.json", "grep -rn TODO .",
           "find . -name \"*.swift\"", "echo hello", "head -n 30 main.py", "du -sh .", "git diff --stat", "python3 main.py",
           "python3 --version"]
PY_ASKS = [("用 python 算一下 2 的 100 次方", 'python3 -c "print(2**100)"'), ("python 跑一下 main.py", "python3 main.py"),
           ("运行 test.py", "python3 test.py"), ("用 python 看看 config.json 格式对不对", "python3 -m json.tool config.json"),
           ("python 版本是多少", "python3 --version"), ("跑一下 scripts/build.py", "python3 scripts/build.py"),
           ("用 Python 数一下 main.py 有几个函数", "grep -c \"def \" main.py"), ("执行一下这个脚本 tools/check.py", "python3 tools/check.py"),
           ("用 python 算 365 乘 24", 'python3 -c "print(365*24)"'), ("今天几号，用 python 看", 'python3 -c "import datetime;print(datetime.date.today())"'),
           ("python 运行 app.py", "python3 app.py"), ("帮我跑 hello.py", "python3 hello.py")]


def run_example():
    k = rnd.choice(KEYWORDS)
    f = rnd.choice(SRC_FILES)
    ext, ename = rnd.choice(EXTS)
    n = rnd.choice([10, 20, 30, 50])
    r = rnd.random()
    if r < 0.3:
        s = pick(["代码里哪里用了 {k}", "搜一下 {k} 在哪些文件里", "{k} 在哪定义的", "grep 一下 {k}", "哪些文件提到了 {k}",
                  "全局搜索 {k}", "代码里有没有 {k}", "查一下哪里调用了 {k}", "在代码里找 {k}", "搜代码 {k}",
                  "{k} 出现在哪几行", "帮我 grep {k}"]).format(k=k)
        return s, "grep -rn " + (f'"{k}"' if "(" in k or " " in k else k) + " ."
    if r < 0.48:
        s = pick(["看看 {f} 写了什么", "打开 {f}", "显示 {f} 的内容", "{f} 里面是什么", "cat 一下 {f}", "读一下 {f}",
                  "把 {f} 给我看看", "{f} 内容是啥", "看下 {f}", "{f} 写的什么", "输出 {f}", "我想看 {f}"]).format(f=f)
        return s, "cat " + f
    if r < 0.56:
        s = pick(["{f} 前 {n} 行", "看下 {f} 开头", "{f} 最前面几行", "head 一下 {f}", "{f} 开头 {n} 行给我看",
                  "只看 {f} 前面一点"]).format(f=f, n=n)
        return s, f"head -n {n} {f}" if str(n) in s else f"head {f}"
    if r < 0.64:
        s = pick(["{f} 有多少行", "数一下 {f} 几行", "{f} 多长", "{f} 一共几行代码", "wc 一下 {f}", "{f} 行数"]).format(f=f)
        return s, "wc -l " + f
    if r < 0.72:
        s = pick(["这个项目有多少个 {e} 文件", "数一下有几个 {x} 文件", "列出所有 {x} 文件", "有哪些 .{x} 文件",
                  "找出全部 {e} 文件", "代码里一共几个 {x} 文件"]).format(e=ename, x=ext)
        c = f'find . -name "*.{ext}"'
        return s, c + " | wc -l" if ("多少" in s or "几个" in s) else c
    if r < 0.8:
        s = pick(["代码文件夹里有哪些文件", "ls 一下", "列一下代码目录", "当前目录有什么", "项目根目录有啥文件",
                  "代码里都有哪些文件", "列出代码文件夹", "目录结构看一下"])
        return s, "ls -la" if "ls" in s or rnd.random() < 0.5 else "ls"
    if r < 0.84:
        s, c = pick(PY_ASKS)
        return s, c
    if r < 0.9:
        s = pick(["git 状态", "git status 看下", "工作区 git 改了哪些", "git 最近提交了什么", "看下 git log", "git 有没有没提交的",
                  "最近几次 git 提交", "git diff 看看"])
        if "log" in s or "提交了" in s or "几次" in s:
            return s, "git log --oneline -10"
        return s, "git diff" if "diff" in s else "git status"
    c = rnd.choice(LITERAL)
    s = pick(["$ {c}", "运行命令 {c}", "跑一下 {c}", "执行 {c}", "帮我跑 {c}", "{c}", "运行 {c}", "跑命令 {c}",
              "执行命令：{c}", "命令 {c} 跑一下"]).format(c=c)
    return s, c


def example(tasks, current, disabled, memory):
    """返回 (用户这句, 上下文或 None, 期望 JSON)"""
    names = [t[0] for t in tasks]
    T = rnd.choice(tasks)
    t, tr = T[0], ref(T)
    f, g = rnd.sample(FOLDERS, 2)
    weights = {
        "push": 7, "push_skip": 3, "check": 7, "check_skip": 4, "status": 4, "history": 4, "exclude": 4, "find": 6,
        "list": 4, "list_dir": 4, "mkdir": 3, "rename": 3, "move": 3, "trash": 3, "remember": 4, "cloud": 12,
        "confusable": 7, "handoff": 4, "followup": 6, "answer": 12, "connector_q": 4, "say": 4, "current": 4, "run": 12,
        "alias": 2 if "主项目" in memory else 0, "disabled_ask": 6 if disabled else 0,
    }
    kind = rnd.choices(list(weights), weights=list(weights.values()))[0]
    # 关掉的工具不会作为正确答案出现
    if kind in ("push", "push_skip") and "push" in disabled or kind in ("check", "check_skip", "current") and "check" in disabled:
        kind = "disabled_ask"
    if kind in disabled:
        kind = "disabled_ask"

    if kind == "push":
        s = pick(["推送 {t}", "把 {t} 推上去", "{t} 推一下", "把 {t} 提交到 GitHub", "同步 {t} 到 GitHub", "{t} 可以推了",
                  "把 {t} 的改动推送", "push {t}", "推一下 {t}", "{t} 传到 GitHub", "{t} 发上去", "{t} 改完了，推吧",
                  "把 {t} 更新到仓库", "{t} 上传 GitHub", "把 {t} 弄到 GitHub 上", "{t} 的代码推到远程",
                  "{t} 提交一下", "{t} 帮忙 push"]).format(t=tr)
        return fill(s), None, J(do="push", task=t)
    if kind == "push_skip":
        s = pick(["推送 {t}，{f} 先别推", "把 {t} 推上去，跳过 {f}", "{t} 推一下，除了 {f} 文件夹", "推送 {t} 但是不要推 {f} 和 {g}",
                  "{t} 推上去，这次 {f} 不要", "这回先别管 {f}，{t} 其它的推上去", "{t} 除了 {f} 都推了"]).format(t=tr, f=f, g=g)
        skip = [f, g] if "{g}" not in s and g in s else [f]
        return fill(s), None, J(do="push", task=t, skip=skip)
    if kind == "check":
        s = pick(["{t} 改了什么", "检查一下 {t}", "看看 {t} 有什么改动", "{t} 有没有新改动", "{t} 这次动了哪些文件",
                  "检查 {t} 的改动", "对比一下 {t} 和 GitHub", "{t} 和线上有什么不一样", "{t} 最近动过啥", "{t} 有要推的吗",
                  "{t} 本地和仓库差多少", "瞅瞅 {t} 改了哪些", "{t} 哪些文件变了", "{t} 有没有没推的"]).format(t=tr)
        return fill(s), None, J(do="check", task=t)
    if kind == "check_skip":
        s = pick(["检查 {t} 除了子目录下的 {f} 文件夹不需要检查", "检查一下 {t}，{f} 不用管", "看看 {t} 改了什么，跳过 {f} 和 {g}",
                  "{t} 检查一下，{f} 文件夹别看", "检查 {t}，忽略 {f}", "{t} 那个 {f} 目录这次不用检查",
                  "{t} 有啥改动，{f} 别算进去"]).format(t=tr, f=f, g=g)
        skip = [f, g] if g in s else [f]
        return fill(s), None, J(do="check", task=t, skip=skip)
    if kind == "current" and current:
        # 没说任务名：用当前任务
        r = rnd.random()
        if r < 0.4:
            s = pick(["检查一下有什么改动", "改了啥", "看看改动", "检查云盘代码", "有什么要推的", "对比一下线上"])
            return fill(s), None, J(do="check", task=current)
        if r < 0.6:
            s = pick(["检查云盘代码 除了子目录下的 {f} 文件夹不需要检查", "检查一下，{f} 不用看", "看看改动，跳过 {f}"]).format(f=f)
            return fill(s), None, J(do="check", task=current, skip=[f])
        if r < 0.85:
            s = pick(["推送", "推上去", "可以推了", "push", "提交吧", "推一下"])
            return fill(s), None, J(do="push", task=current)
        return fill(pick(["推送记录", "上次推了啥", "看看推送历史"])), None, J(do="history", task=current)
    if kind == "status":
        s = pick(["所有任务有改动吗", "哪些任务要推", "看看各个项目的状态", "现在有什么待推的", "全部任务检查一遍",
                  "我的项目都怎么样了", "所有项目有没有没推的改动", "帮我瞅瞅有没有要推的", "全部扫一遍", "哪个项目改了"])
        return fill(s), None, J(do="status")
    if kind == "history":
        s = pick(["{t} 的推送记录", "{t} 上次推了什么", "看看 {t} 的历史", "{t} 推过哪些东西", "最近 {t} 推送了几次",
                  "{t} 什么时候推的", "{t} 之前推了些啥来着"]).format(t=tr)
        return fill(s), None, J(do="history", task=t)
    if kind == "exclude":
        s = pick(["以后 {t} 的 {f} 都不要推", "{t} 以后一直别推 {f}", "{f} 文件夹以后永远不推（{t}）", "{t} 里的 {f} 从此不要提交",
                  "以后都别推 {t} 的 {f} 了", "{t} 的 {f} 一直跳过", "把 {f} 加到 {t} 的不推列表"]).format(t=tr, f=f)
        return fill(s), None, J(do="exclude", task=t, path=f)
    if kind == "find":
        k = rnd.choice(FILES)
        s = pick(["找一下 {k}", "{k} 在哪", "搜一下 {k}", "帮我找找 {k}", "云盘里有没有 {k}", "{k} 放哪了",
                  "{k} 那个文件在哪", "找找名字里带 {k} 的", "{k} 在云盘哪个位置", "我的 {k} 去哪了"]).format(k=k)
        return fill(s), None, J(do="find", keyword=k)
    if kind == "list":
        s = pick(["查看一下云盘有哪些文件夹", "读取小橘云盘列出所有文件夹", "看看云盘里有什么", "列一下云盘根目录",
                  "云盘里都有哪些东西", "云盘根目录下都有啥", "小橘云盘的目录结构给我看看", "云盘有哪些文件夹",
                  "打开云盘看看", "列出云盘所有文件夹"])
        return fill(s), None, J(do="list", folder="/")
    if kind == "list_dir":
        d = rnd.choice(CLOUD_DIRS)
        s = pick(["{d} 里有什么文件", "看看 {d} 下面有哪些文件夹", "列出 {d} 里的东西", "打开 {d} 看看", "{d} 文件夹里有啥",
                  "{d} 下面都放了什么", "看下 {d} 目录"]).format(d=d)
        return fill(s), None, J(do="list", folder=d)
    if kind == "mkdir":
        d, x = rnd.choice(CLOUD_DIRS), rnd.choice(NEW_NAMES)
        s = pick(["在 {d} 下面新建一个 {x} 文件夹", "{d} 里建个 {x}", "帮我创建 {d}/{x}", "新建文件夹 {d}/{x}",
                  "{d} 加个文件夹叫 {x}", "在 {d} 弄个 {x} 目录"]).format(d=d, x=x)
        return fill(s), None, J(do="mkdir", path=f"{d}/{x}")
    if kind == "rename":
        d, x, y = rnd.choice(CLOUD_DIRS), rnd.choice(["demo", "旧版", "test", "草稿", "新建文件夹"]), rnd.choice(["demo2", "存档", "测试", "v1", "定稿"])
        s = pick(["把 {d}/{x} 改名为 {y}", "{d}/{x} 重命名成 {y}", "{d}/{x} 改成叫 {y}", "{d}/{x} 名字换成 {y}",
                  "把 {d}/{x} 改个名叫 {y}", "{d}/{x} 改叫 {y}"]).format(d=d, x=x, y=y)
        return fill(s), None, J(do="rename", path=f"{d}/{x}", to=y)
    if kind == "move":
        d, x = rnd.choice(CLOUD_DIRS), rnd.choice(["demo", "旧版", "截图", "草稿", "a", "素材包"])
        to = rnd.choice([c for c in CLOUD_DIRS if c != d])
        s = pick(["把 {d}/{x} 移到 {to}", "{d}/{x} 挪到 {to} 去", "把 {d}/{x} 放进 {to}", "{d}/{x} 搬到 {to}",
                  "{d}/{x} 挪回 {to}", "把 {d}/{x} 归档到 {to}"]).format(d=d, x=x, to=to)
        return fill(s), None, J(do="move", path=f"{d}/{x}", to=to)
    if kind == "trash":
        d, x = rnd.choice(CLOUD_DIRS), rnd.choice(["temp", "旧版", "test.txt", "草稿", "test", "临时文件"])
        s = pick(["删掉 {d}/{x}", "把 {d}/{x} 放回收站", "{d}/{x} 不要了", "删除 {d}/{x}", "{d}/{x} 扔了",
                  "把 {d}/{x} 删了", "删除云盘 {x} 文件夹"]).format(d=d, x=x)
        path = f"/{x}" if "删除云盘" in s else f"{d}/{x}"
        return fill(s), None, J(do="trash", path=path)
    if kind == "remember":
        x = rnd.choice(FACTS)
        s = pick(["记住{x}", "记一下：{x}", "以后{x}", "你记错了，{x}", "帮我记着，{x}", "记下来：{x}", "别忘了{x}"]).format(x=x)
        return fill(s), None, J(do="remember", text=x)
    if kind == "run":
        s, c = run_example()
        return (s if s.startswith("$") or s == c else fill(s)), None, J(do="run", cmd=c)
    if kind == "cloud":
        s = fill(pick(CODE_ASKS).format(t=tr))
        return s, None, J(do="cloud", text=s)
    if kind == "confusable":
        s = fill(pick(CONFUSABLE).format(t=tr))
        return s, None, J(do="cloud", text=s)
    if kind == "handoff":
        prev = pick(CODE_ASKS).format(t=tr)
        s = pick(["交给云端模型处理", "让云端来做", "交给 OpenCode", "你搞不定就交给大模型", "问问云端", "给云端吧",
                  "这个让 DeepSeek 做", "交给云端"])
        return s, f"上一句：{prev}", J(do="cloud", text=prev)
    if kind == "followup":
        r = rnd.random()
        if r < 0.3:
            d, x = rnd.choice(CLOUD_DIRS), rnd.choice(["demo", "草稿", "截图"])
            to = rnd.choice([c for c in CLOUD_DIRS if c != d])
            s = pick(["再移回来", "放回原来的地方", "挪回去", "撤回刚才的移动"])
            return s, f"上一步：移动 {d}/{x} → {to}", J(do="move", path=f"{to}/{x}", to=d)
        if r < 0.6:
            s = pick(["那推上去吧", "没问题，推吧", "可以，推送", "推", "好，提交"])
            return s, f"上一步：检查 {t} 的改动", J(do="push", task=t)
        if r < 0.8:
            s = pick(["看看它的推送记录", "它之前推过什么", "看下记录"])
            return s, f"上一步：推送 {t}", J(do="history", task=t)
        s = pick(["这个也检查一下", "再检查一遍", "重新检查"])
        return s, f"上一步：检查 {t} 的改动", J(do="check", task=t)
    if kind == "alias":
        s = pick(["推送主项目", "主项目改了什么", "检查一下主项目"])
        do = "push" if "推送" in s else "check"
        return fill(s), None, J(do=do, task="meta-work")
    if kind == "say":
        if current or len(names) == 1:
            return example(tasks, current, disabled, memory)
        s = pick(["推送", "检查一下", "看看推送记录", "推一下", "改了什么"])
        return s, None, J(do="say", text="是哪个任务？有：" + "、".join(names))
    if kind == "disabled_ask":
        k = rnd.choice(sorted(disabled))
        asks = {
            "push": "推送 {t}", "check": "检查一下 {t}", "status": "所有任务有改动吗", "history": "{t} 的推送记录",
            "exclude": "以后 {t} 的 {f} 都不要推", "find": "找一下 README", "list": "看看云盘里有什么", "mkdir": "在 /代码 新建一个 demo",
            "rename": "把 /代码/demo 改名为 demo2", "move": "把 /代码/demo 移到 /归档", "trash": "删掉 /临时/test",
            "remember": "记住提交说明用中文", "cloud": "帮我写个登录页面", "run": "代码里哪里用了 apiKey",
        }
        s = asks[k].format(t=tr, f=f)
        label = run.LABELS[k]
        conn = label.split(" · ")[0]
        return fill(s), None, J(do="answer", text=f"「{label}」在连接器里关掉了，要用就去「设置 → 连接器 → {conn}」打开。")
    if kind == "connector_q":
        qa = [
            (["列举你可以对小橘云盘的工具调用操作有哪些", "小橘云盘能做什么", "云盘那边你能干嘛", "你能对云盘做哪些操作",
              "云盘有哪些工具", "网盘这块你会什么"], "云盘这边我能：找文件、看文件夹、新建/改名/移动文件、放进回收站、读写记忆。推送、检查改动是 GitHub 那边的。"),
            (["GitHub 那边能干嘛", "列举一下 GitHub 的工具", "你对 GitHub 能做什么操作", "GitHub 连接器有什么用",
              "GitHub 那边你能做什么"], "GitHub 这边我能：检查改动、推送、看推送记录、设置不推的文件夹。"),
            (["OpenCode 能做什么", "云端模型能干嘛", "云端那个大模型会什么", "DeepSeek 能帮我干啥"],
             "云端 OpenCode 能写代码、改 bug、解释代码、跑命令，这些我会交给它。"),
            (["有哪些连接器", "连接器是什么", "你连了哪些服务"],
             "四个：小橘云盘、GitHub、本机命令、云端 OpenCode。在「设置 → 连接器」里能看和开关每个工具。"),
            (["本机命令能干嘛", "你能跑命令吗", "手机上能执行什么命令", "命令行能用吗", "本机命令有什么用", "你会用终端吗"],
             "能在当前任务的代码文件夹里跑命令：grep 搜代码、cat/head 看文件、ls/find 列文件、wc 数行数、git status/log、python3 跑脚本（只有标准库）。没有 npm、pip。"),
        ]
        qs, a = rnd.choice(qa)
        return fill(pick(qs)), None, J(do="answer", text=a)
    # answer：简单问题自己答
    ALL = "小橘云盘：找文件、看文件夹、新建/改名/移动文件、放回收站、读写记忆；GitHub：检查改动、推送、推送记录、设置不推的文件夹；难的交给云端 OpenCode。"
    qa = [
        (["你是谁", "介绍一下你自己", "你叫什么"], f"我是小橘推送里的本地模型 {MODEL}，在你手机上跑，不联网。"),
        (["你是什么模型", "你现在是什么模型", "你用的什么模型", "你是哪个模型"], f"我是 {MODEL}（小橘版），跑在你的 iPhone 上，不联网。"),
        (["你好", "嗨", "hello", "哈喽"], "你好！要推送、检查改动、找文件，还是交给云端写代码？"),
        (["在吗", "在不在", "有人吗"], "在的，直接说要做什么就行。"),
        (["早上好", "早"], "早上好！今天要推哪个项目？"),
        (["晚安", "我睡了"], "晚安，明天见。"),
        (["谢谢", "谢谢啦", "辛苦了", "多谢"], "不客气，有事再叫我。"),
        (["你能做什么", "你会干嘛", "你有什么功能", "你可以调用哪些工具", "列举你可以调用的技能", "你可以调用什么工具", "你有哪些技能"], ALL),
        (["测试一下你的每项技能", "测试一下你的每一项技能", "把你的功能都试一遍", "所有工具都跑一遍", "挨个演示一下你的功能"], "我一次只做一件事，可以挨个试：「检查 meta-work」「找一下 README」「看看云盘有哪些文件夹」「meta-work 的推送记录」；写代码的就说「交给云端：…」。"),
        (["这个 App 怎么用", "怎么用你", "我该怎么跟你说"], "直接说一句话就行，比如「推送 meta-work」「找一下 README」。会改东西的都会先出确认卡片。"),
        (["你联网吗", "你能上网吗"], "我不联网，在你手机上跑；要联网查东西或写代码会交给云端 OpenCode。"),
        (["你好笨", "你又错了", "怎么这么蠢"], "抱歉，可以说具体一点，或者说「交给云端」让大模型来。"),
        (["1+1等于几", "3乘4是多少"], "等于 2。" if True else ""),
        (["今天天气怎么样", "今天天气不错", "外面下雨了吗"], "我不联网，看不了天气。代码上的事随时叫我。"),
        (["删除会不会永久删掉", "删了还能找回来吗"], "不会，删除只放进云盘回收站，随时能放回来。"),
        (["推送前会问我吗", "你会不会乱推"], "会先给你看改了哪些文件，你点确认才推。"),
        (["怎么关掉某个工具", "工具在哪关"], "去「设置 → 连接器」，点进对应的连接器，每个工具都能单独开关。"),
        (["内存够不够用", "你占多少内存"], "看屏幕底部的内存浮标：左边是 App 占用，「余」是还能用的。4B 大概占 3 GB。"),
    ]
    qs, a = rnd.choice(qa)
    q = pick(qs)
    if q == "3乘4是多少":
        a = "等于 12。"
    return fill(q), None, J(do="answer", text=a)


# William 实测说过的话（每条多放几遍，任务列表随机）
REAL = [
    ("删除云盘test文件夹", None, {"do": "trash", "path": "/test"}),
    ("列举你可以对小橘云盘的工具调用操作有哪些", None,
     {"do": "answer", "text": "云盘这边我能：找文件、看文件夹、新建/改名/移动文件、放进回收站、读写记忆。推送、检查改动是 GitHub 那边的。"}),
    ("查看一下云盘有哪些文件夹", None, {"do": "list", "folder": "/"}),
    ("读取小橘云盘列出所有文件夹", None, {"do": "list", "folder": "/"}),
    ("本地模型去读取小橘云盘列出所有文件夹", None, {"do": "list", "folder": "/"}),
    ("问云端模型他是谁", None, {"do": "cloud", "text": "问云端模型他是谁"}),
    ("你可以调用什么工具", None, {"do": "answer", "text": "小橘云盘：找文件、看文件夹、新建/改名/移动文件、放回收站、读写记忆；GitHub：检查改动、推送、推送记录、设置不推的文件夹；难的交给云端 OpenCode。"}),
    ("测试一下你的每项技能", None, {"do": "answer", "text": "我一次只做一件事，可以挨个试：「检查 meta-work」「找一下 README」「看看云盘有哪些文件夹」「meta-work 的推送记录」；写代码的就说「交给云端：…」。"}),
    ("测试一下你的每一项技能", None, {"do": "answer", "text": "我一次只做一件事，可以挨个试：「检查 meta-work」「找一下 README」「看看云盘有哪些文件夹」「meta-work 的推送记录」；写代码的就说「交给云端：…」。"}),
    ("交给云端模型处理", "上一句：给 xiaoju-video 写个 README", {"do": "cloud", "text": "给 xiaoju-video 写个 README"}),
]


def render(prefix, user, ctx, answer):
    last = f"（{ctx}）\n" if ctx else ""
    return (prefix + f"<|im_start|>user\n{last}{user}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
            + answer + "<|im_end|>\n")


def one():
    tasks = [t for t in rnd.sample(TASK_POOL, rnd.randint(1, 5))]
    if rnd.random() < 0.3 and not any(t[0] == "meta-work" for t in tasks):
        tasks[0] = TASK_POOL[0]
    current = rnd.choice([None, None, rnd.choice(tasks)[0]])
    memory = ""
    if rnd.random() < 0.25:
        memory = "\n".join("- " + x for x in rnd.sample(FACTS, rnd.randint(1, 4)))
    disabled = ()
    if rnd.random() < 0.15:
        disabled = tuple(rnd.sample(["push", "trash", "move", "rename", "mkdir", "exclude", "remember", "cloud", "history"], rnd.randint(1, 3)))
    prefix, _ = run.build(tasks=[t[:3] for t in tasks], current=current, disabled=disabled, memory=memory)
    prefix = prefix.replace("Qwen3.5-2B", MODEL)
    user, ctx, ans = example(tasks, current, disabled, memory)
    user = noisy(user)
    a = json.loads(ans)
    if a["do"] == "cloud" and ctx is None:
        a["text"] = user  # 交给云端的是用户原话，一个字不改
        ans = J(**a)
    return render(prefix, user, ctx, ans)


def main():
    global MODE
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    n_eval = max(80, n // 20)
    MODE = "train"
    train = [one() for _ in range(n - n_eval)]
    # 实测原话：每句 6 遍
    for user, ctx, ans in REAL:
        for _ in range(6):
            tasks = rnd.sample(TASK_POOL, rnd.randint(1, 4))
            if "xiaoju-video" in (ctx or "") and not any(t[0] == "xiaoju-video" for t in tasks):
                tasks[0] = TASK_POOL[1]
            prefix, _ = run.build(tasks=[t[:3] for t in tasks], current=rnd.choice([None, tasks[0][0]]))
            prefix = prefix.replace("Qwen3.5-2B", MODEL)
            train.append(render(prefix, user, ctx, J(**ans)))
    MODE = "eval"
    rnd.seed(7)
    evals = [one() for _ in range(n_eval)]
    rnd.shuffle(train)
    out = os.path.join(HERE, "data")
    os.makedirs(out, exist_ok=True)
    for name, part in (("eval.jsonl", evals), ("train.jsonl", train)):
        with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
            for r in part:
                fh.write(json.dumps({"text": r}, ensure_ascii=False) + "\n")
    print(f"train {len(train)} 条，eval {len(evals)} 条（考试只用留出来的说法）→ {out}")


if __name__ == "__main__":
    main()
