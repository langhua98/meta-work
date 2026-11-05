"""v3 训练数据新增的几块（make_data.py 调用）。

1. NATURAL：手写的口语说法（不是模板拼的），覆盖所有工具和容易混的情况。下标 %6==5 的只进考试。
2. 纠错提示：App 会把纠错本里最像的几条放在这一句前面（Command.swift 的 fixLines）。
   - 相关的提示：用户的怪说法（只有看了提示才懂），照提示的做法换上这次的参数。
   - 不相关的提示：照常理解，不能照抄提示。
3. 接上一步的追问（上一句 / 上一步），比 v2 多几种。
4. 纠错本：scripts/finetune/data/fixbook.jsonl（训练前从云盘 /小橘推送/纠错本/纠错本.jsonl 拷过来），2 成留给考试。
"""
import json
import os

# {t} 任务的叫法（答案里用任务名），{f} 文件夹，{k} 文件名或关键词
# 答案里 "cloud" 的 text 由调用方换成用户原话
NATURAL = [
    # 推送
    ("{t} 弄完了，传上去吧", {"do": "push", "task": "{t}"}),
    ("把 {t} 的东西发到 GitHub", {"do": "push", "task": "{t}"}),
    ("{t} 可以上线了，推", {"do": "push", "task": "{t}"}),
    ("今天 {t} 写完了 帮我推一下", {"do": "push", "task": "{t}"}),
    ("{t} 那个改好了你推上去", {"do": "push", "task": "{t}"}),
    ("{t} 同步到仓库里", {"do": "push", "task": "{t}"}),
    ("把 {t} 交上去，{f} 这次不带", {"do": "push", "task": "{t}", "skip": ["{f}"]}),
    ("{t} 推了吧 但 {f} 别动", {"do": "push", "task": "{t}", "skip": ["{f}"]}),
    ("{t} 先推，{f} 下回再说", {"do": "push", "task": "{t}", "skip": ["{f}"]}),
    # 检查
    ("{t} 我动了哪些地方", {"do": "check", "task": "{t}"}),
    ("{t} 跟线上比有啥区别", {"do": "check", "task": "{t}"}),
    ("{t} 现在什么情况", {"do": "check", "task": "{t}"}),
    ("帮我看下 {t} 是不是改过", {"do": "check", "task": "{t}"}),
    ("{t} 有新东西没推吗", {"do": "check", "task": "{t}"}),
    ("对一下 {t} 和 GitHub 上的", {"do": "check", "task": "{t}"}),
    ("{t} 看改动，{f} 不算", {"do": "check", "task": "{t}", "skip": ["{f}"]}),
    ("{t} 除了 {f} 都检查下", {"do": "check", "task": "{t}", "skip": ["{f}"]}),
    # 所有任务
    ("我那几个项目哪个要推", {"do": "status"}),
    ("所有项目过一遍", {"do": "status"}),
    ("看看哪个仓库有没推的东西", {"do": "status"}),
    ("全部项目现在啥状态", {"do": "status"}),
    ("今天哪些项目动过", {"do": "status"}),
    ("有没有项目落下没推的", {"do": "status"}),
    # 推送记录
    ("{t} 上回推的是什么时候", {"do": "history", "task": "{t}"}),
    ("{t} 都推过些啥", {"do": "history", "task": "{t}"}),
    ("翻一下 {t} 的推送历史", {"do": "history", "task": "{t}"}),
    ("{t} 最近几次推送", {"do": "history", "task": "{t}"}),
    ("{t} 昨天推成功了没", {"do": "history", "task": "{t}"}),
    ("我上次给 {t} 推了啥", {"do": "history", "task": "{t}"}),
    # 以后不推（v2 的已知错：「以后 node_modules 别再推了」被当成记住）
    ("以后 {f} 别再推了", {"do": "exclude", "task": "{t}", "path": "{f}"}),
    ("{f} 以后别再推上去了", {"do": "exclude", "task": "{t}", "path": "{f}"}),
    ("{t} 的 {f} 再也别推了", {"do": "exclude", "task": "{t}", "path": "{f}"}),
    ("以后推 {t} 都不要带 {f}", {"do": "exclude", "task": "{t}", "path": "{f}"}),
    ("{f} 永远不要传到 GitHub", {"do": "exclude", "task": "{t}", "path": "{f}"}),
    ("下次开始 {f} 都跳过别推", {"do": "exclude", "task": "{t}", "path": "{f}"}),
    ("{t} 里 {f} 这个目录以后不用推", {"do": "exclude", "task": "{t}", "path": "{f}"}),
    ("{f} 不要再出现在推送里了", {"do": "exclude", "task": "{t}", "path": "{f}"}),
    # 记住（和上面对比：说的是习惯、事实，不是哪个文件夹不推）
    ("以后提交说明都用中文写", {"do": "remember", "text": "提交说明都用中文写"}),
    ("以后回答我短一点", {"do": "remember", "text": "回答短一点"}),
    ("下次推之前先让我看改动", {"do": "remember", "text": "推之前先让我看改动"}),
    ("记一下，我的测试都放 tests 目录", {"do": "remember", "text": "测试都放 tests 目录"}),
    ("别忘了 {t} 用的是 main 分支", {"do": "remember", "text": "{t} 用的是 main 分支"}),
    ("你记着，「小项目」说的是 {t}", {"do": "remember", "text": "「小项目」说的是 {t}"}),
    ("以后叫我 William 就行", {"do": "remember", "text": "叫我 William"}),
    ("你刚才错了，删东西前要先问我", {"do": "remember", "text": "删东西前要先问我"}),
    ("记住周末别自动推送", {"do": "remember", "text": "周末别自动推送"}),
    ("以后别用英文回我", {"do": "remember", "text": "别用英文回我"}),
    # 找文件（云盘里按名字找）
    ("{k} 我放哪了来着", {"do": "find", "keyword": "{k}"}),
    ("云盘里搜下 {k}", {"do": "find", "keyword": "{k}"}),
    ("帮我翻翻有没有叫 {k} 的文件", {"do": "find", "keyword": "{k}"}),
    ("{k} 这个文件还在吗", {"do": "find", "keyword": "{k}"}),
    ("我记得有个 {k}，找出来", {"do": "find", "keyword": "{k}"}),
    ("找下名字带 {k} 的东西", {"do": "find", "keyword": "{k}"}),
    # 看文件夹
    ("云盘最外面有什么", {"do": "list", "folder": "/"}),
    ("我云盘里都存了啥", {"do": "list", "folder": "/"}),
    ("把云盘的文件夹列出来", {"do": "list", "folder": "/"}),
    ("/归档 里面都有哪些", {"do": "list", "folder": "/归档"}),
    ("看下 /素材 下面", {"do": "list", "folder": "/素材"}),
    ("/代码 这个文件夹打开看看", {"do": "list", "folder": "/代码"}),
    # 新建 / 改名 / 移动 / 删除
    ("/代码 下面建个 playground", {"do": "mkdir", "path": "/代码/playground"}),
    ("新开一个文件夹 /项目/2027", {"do": "mkdir", "path": "/项目/2027"}),
    ("把 /临时/a 改名叫 b", {"do": "rename", "path": "/临时/a", "to": "b"}),
    ("/写作/草稿 名字换成 初稿", {"do": "rename", "path": "/写作/草稿", "to": "初稿"}),
    ("/下载/截图 挪到 /素材 里", {"do": "move", "path": "/下载/截图", "to": "/素材"}),
    ("把 /代码/old 丢进 /归档", {"do": "move", "path": "/代码/old", "to": "/归档"}),
    ("/临时/test 删了吧", {"do": "trash", "path": "/临时/test"}),
    ("/下载 里那个 temp 不要了", {"do": "trash", "path": "/下载/temp"}),
    # 本机命令（工作区里的代码）
    ("代码里哪里写了 {k}", {"do": "run", "cmd": "grep -rn {k} ."}),
    ("项目里搜一下 {k} 这个词", {"do": "run", "cmd": "grep -rn {k} ."}),
    ("{k} 在代码哪一行", {"do": "run", "cmd": "grep -rn {k} ."}),
    ("看下 README.md 写了啥", {"do": "run", "cmd": "cat README.md"}),
    ("main.py 开头给我看看", {"do": "run", "cmd": "head main.py"}),
    ("工作区里有哪些文件", {"do": "run", "cmd": "ls -la"}),
    ("我本地改了哪些还没提交", {"do": "run", "cmd": "git status"}),
    ("git 上具体改了什么内容", {"do": "run", "cmd": "git diff"}),
    ("最近 5 次提交", {"do": "run", "cmd": "git log --oneline -5"}),
    ("跑一下 test.py 看看过不过", {"do": "run", "cmd": "python3 test.py"}),
    ("用 python 算下 1024 乘 768", {"do": "run", "cmd": "python3 -c \"print(1024*768)\""}),
    ("代码一共多少行", {"do": "run", "cmd": "find . -type f | xargs wc -l | tail -1"}),
    ("有几个 swift 文件", {"do": "run", "cmd": "find . -name \"*.swift\" | wc -l"}),
    ("把改动都 git add 上", {"do": "run", "cmd": "git add -A"}),
    ("提交一下，说明写修复登录", {"do": "run", "cmd": "git commit -m \"修复登录\""}),
    # 上网
    ("网上查查 llama.cpp 最新版本", {"do": "search", "q": "llama.cpp 最新版本"}),
    ("搜下 Xcode 16 这个报错怎么解决", {"do": "search", "q": "Xcode 16 报错 解决"}),
    ("最近有什么新的开源大模型，上网看看", {"do": "search", "q": "最新 开源大模型"}),
    ("百度一下 SwiftData 怎么迁移", {"do": "search", "q": "SwiftData 迁移"}),
    ("帮我查 HF Space 免费额度", {"do": "search", "q": "HF Space 免费额度"}),
    ("查一下 Qwen3.5 有多少参数的版本", {"do": "search", "q": "Qwen3.5 参数 版本"}),
    ("https://github.com/holzschu/a-shell 这个看一下讲啥", {"do": "fetch", "url": "https://github.com/holzschu/a-shell"}),
    ("读读这个链接 https://swift.org/blog", {"do": "fetch", "url": "https://swift.org/blog"}),
    ("打开 example.com 给我看内容", {"do": "fetch", "url": "example.com"}),
    # 快捷指令
    ("跑我的「早报」快捷指令", {"do": "shortcut", "name": "早报"}),
    ("快捷指令 打开热点 运行下", {"do": "shortcut", "name": "打开热点"}),
    ("用捷径执行 备份照片", {"do": "shortcut", "name": "备份照片"}),
    ("运行一下快捷指令每日总结", {"do": "shortcut", "name": "每日总结"}),
    # 交给云端（写代码、解释、审查、看起来像别的指令的）
    ("帮我看看这次改动有没有 bug", {"do": "cloud"}),
    ("{t} 为什么一打开就闪退", {"do": "cloud"}),
    ("给 {t} 写个 README", {"do": "cloud"}),
    ("这个函数能不能写得更简单", {"do": "cloud"}),
    ("检查下我的代码规范不规范", {"do": "cloud"}),
    ("找找代码里有没有安全漏洞", {"do": "cloud"}),
    ("把 {t} 里没用的代码删掉", {"do": "cloud"}),
    ("{t} 加个登录功能", {"do": "cloud"}),
    ("解释一下 git rebase 和 merge 区别", {"do": "cloud"}),
    ("帮我写个提交说明", {"do": "cloud"}),
    ("{t} 的架构画个图", {"do": "cloud"}),
    ("把搜到的资料整理成一份总结", {"do": "cloud"}),
    ("推送通知功能怎么实现", {"do": "cloud"}),
    ("新建一个 Swift 文件写个网络请求类", {"do": "cloud"}),
    ("移动端布局乱了帮我修", {"do": "cloud"}),
    ("给 {t} 写单元测试并跑一下", {"do": "cloud"}),
    # 自己回答
    ("你现在用的是哪个模型", {"do": "answer", "text": "我是 Qwen3.5-4B（小橘版），跑在你的 iPhone 上，不联网。"}),
    ("你在手机上跑的吗", {"do": "answer", "text": "对，我在你手机上跑，不联网；难的事交给云端 OpenCode。"}),
    ("纠错本是干嘛的", {"do": "answer", "text": "我理解错时你点「不对」纠正，会记进纠错本；下次说相似的话我照着做，攒够了还能拿去训新版本地模型。"}),
    ("点了不对会怎样", {"do": "answer", "text": "云端会看你的原话给几个选项，你选对的那个，我照做并记进纠错本，下次就不会错了。"}),
    ("你能连续做好几件事吗", {"do": "answer", "text": "我一次做一件事；要连着做好几步的（比如改代码再推送），说一声交给云端。"}),
    ("好的", {"do": "answer", "text": "好，还要做什么直接说。"}),
    ("没事了", {"do": "answer", "text": "好的，有事再叫我。"}),
    ("你真棒", {"do": "answer", "text": "谢谢！还有要推的吗？"}),
]

# 接上一步 / 上一句（(上下文, 这一句, 答案)）
FOLLOWUPS = [
    ("上一步：检查 {t} 的改动", "除了 {f} 都推上去", {"do": "push", "task": "{t}", "skip": ["{f}"]}),
    ("上一步：检查 {t} 的改动", "{f} 以后都不推", {"do": "exclude", "task": "{t}", "path": "{f}"}),
    ("上一步：检查 {t} 的改动", "行，推吧", {"do": "push", "task": "{t}"}),
    ("上一步：推送 {t}", "{u} 也推一下", {"do": "push", "task": "{u}"}),
    ("上一步：推送 {t}", "{u} 呢，有改动吗", {"do": "check", "task": "{u}"}),
    ("上一步：找文件「{k}」", "去 /代码 里找", {"do": "find", "keyword": "{k}", "folder": "/代码"}),
    ("上一步：跑命令 git status", "具体改了啥", {"do": "run", "cmd": "git diff"}),
    ("上一步：跑命令 git status", "都提交了吧", {"do": "run", "cmd": "git add -A"}),
    ("上一步：跑命令 cat README.md", "再看看 main.py", {"do": "run", "cmd": "cat main.py"}),
    ("上一步：跑命令 grep -rn {k} .", "交给云端看看怎么改", {"do": "cloud", "text": "看看 {k} 这些地方怎么改"}),
    ("上一步：上网搜「{q}」", "整理一下给我", {"do": "cloud", "text": "把搜到的「{q}」资料整理一下"}),
    ("上一步：新建文件夹 /代码/demo", "改名叫 demo2", {"do": "rename", "path": "/代码/demo", "to": "demo2"}),
    ("上一步：新建文件夹 /代码/demo", "算了删掉", {"do": "trash", "path": "/代码/demo"}),
    ("上一步：把 /临时/test 放进回收站", "放回来", {"do": "cloud", "text": "把 /临时/test 从回收站放回来"}),
    ("上一句：给 {t} 加个暗色模式", "你搞不定就让云端来", {"do": "cloud", "text": "给 {t} 加个暗色模式"}),
    ("上一句：{t} 为什么编译不过", "交给大模型", {"do": "cloud", "text": "{t} 为什么编译不过"}),
]
QUERIES = ["SwiftUI 动画", "Qwen3.5 量化", "GitHub Actions 缓存", "iOS 后台下载", "python 异步"]

# 只有看了纠错提示才懂的怪说法：(用户说法模板, 答案模板)。没有提示时不出现在训练里
ODD = [
    ("把 {d}/{x} 收起来", {"do": "move", "path": "{d}/{x}", "to": "/归档"}),
    ("{d}/{x} 清一清", {"do": "trash", "path": "{d}/{x}"}),
    ("{t} 过一遍", {"do": "check", "task": "{t}"}),
    ("{t} 打包发了", {"do": "push", "task": "{t}"}),
    ("{t} 的 {f} 别带上", {"do": "exclude", "task": "{t}", "path": "{f}"}),
    ("翻翻 {d}", {"do": "list", "folder": "{d}"}),
    ("瞄一眼 {k}", {"do": "run", "cmd": "cat {k}"}),
    ("问问度娘 {q}", {"do": "search", "q": "{q}"}),
    ("走一遍{n}", {"do": "shortcut", "name": "{n}"}),
    ("{t} 盘一下", {"do": "history", "task": "{t}"}),
    ("存个底：{m}", {"do": "remember", "text": "{m}"}),
    ("{t} 体检", {"do": "cloud"}),
    ("扫一下 {w}", {"do": "run", "cmd": "grep -rn {w} ."}),
    ("{d} 起个 {x}", {"do": "mkdir", "path": "{d}/{x}"}),
]
ODD_SLOTS = {
    "d": ["/代码", "/项目", "/临时", "/写作", "/下载"],
    "x": ["demo", "旧版", "截图", "草稿", "test", "素材包"],
    "k": ["README.md", "main.py", "config.json", "todo.md", "app.js"],
    "q": ["SwiftUI 列表", "llama.cpp 编译", "Xcode 签名", "HF 免费 GPU"],
    "n": ["早报", "备份照片", "下班打卡", "每日总结"],
    "m": ["分支用 main", "图片都放 /素材", "周末不推送"],
    "w": ["cloudToken", "TODO", "apiKey", "fetchUser", "baseURL"],
}


def fill_obj(o, **kw):
    """把答案模板里的 {x} 换掉"""
    if isinstance(o, str):
        for k, v in kw.items():
            o = o.replace("{" + k + "}", v)
        return o
    if isinstance(o, list):
        return [fill_obj(x, **kw) for x in o]
    return {k: fill_obj(v, **kw) for k, v in o.items()}


def held(i, mode):
    return (i % 6 == 5) == (mode == "eval")


def natural(rnd, mode, task, task_ref, folder, keyword):
    """一条手写口语：(这一句, 答案 dict)。cloud 的 text 由调用方填"""
    items = [x for i, x in enumerate(NATURAL) if held(i, mode)]
    s, a = rnd.choice(items)
    kw = dict(t=task, f=folder, k=keyword)
    return s.replace("{t}", task_ref).replace("{f}", folder).replace("{k}", keyword), fill_obj(a, **kw)


def followup(rnd, mode, task, other, folder, keyword):
    items = [x for i, x in enumerate(FOLLOWUPS) if held(i, mode)] if mode == "eval" else FOLLOWUPS
    ctx, s, a = rnd.choice(items)
    kw = dict(t=task, u=other, f=folder, k=keyword, q=rnd.choice(QUERIES))
    return fill_obj(s, **kw), fill_obj(ctx, **kw), fill_obj(a, **kw)


def odd_pair(rnd, task, folder):
    """同一种怪说法、两组不同的参数：一组当提示，一组是这次要做的"""
    s, a = rnd.choice(ODD)
    def one():
        kw = {k: rnd.choice(v) for k, v in ODD_SLOTS.items()}
        kw.update(t=task, f=folder)
        return fill_obj(s, **kw), fill_obj(a, **kw)
    h = one()
    for _ in range(5):
        u = one()
        if u[0] != h[0]:
            break
    return h, u


def hint_block(lines):
    """和 App 一模一样的提示格式（Command.swift 里的 fixLines）"""
    return "（用户以前纠正过的说法，意思一样就照这样做：\n" + "\n".join(f"{s} → {j}" for s, j in lines) + "）\n"


def fixbook(path):
    """纠错本：[(原话, 上下文, 对的指令 dict)]，按 id 排序后每 5 条留 1 条给考试"""
    if not os.path.exists(path):
        return [], []
    rows = []
    for line in open(path, encoding="utf-8"):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if isinstance(o.get("right"), dict) and o.get("text"):
            rows.append(o)
    # 同一句话被纠正过好几次，只留最后一次
    last = {}
    for o in sorted(rows, key=lambda o: o.get("at", "")):
        last["".join(o["text"].split())] = o
    rows = sorted(last.values(), key=lambda o: o.get("id", ""))
    train, test = [], []
    for i, o in enumerate(rows):
        (test if i % 5 == 4 else train).append((o["text"], o.get("context"), o["right"]))
    return train, test
