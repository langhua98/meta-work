#!/usr/bin/env python3
"""把小橘推送 App 的全部源码复制到小橘云盘的 metawork/cloude审阅/小橘推送/。

在 GitHub Actions 里跑（.github/workflows/copy-app-to-cloud.yml），需要 secret XIAOJU_TOKEN（有写权限的 xa_ 令牌）。
云盘里已有同名文件会覆盖成仓库里的版本。
"""
import json, os, sys, urllib.parse, urllib.request, urllib.error

BASE = (os.environ.get("XIAOJU_URL") or "https://node.tail823dbd.ts.net").rstrip("/") + "/api/agent/v1"
TOKEN = os.environ.get("XIAOJU_TOKEN", "")
SOURCES = ["src/xiaoju-push", ".github/workflows/xiaoju-push.yml"]


def call(method, path, body=None, headers=None):
    req = urllib.request.Request(BASE + path, data=body, method=method,
                                 headers={"Authorization": f"Bearer {TOKEN}", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def main():
    if not TOKEN:
        sys.exit("缺少 secret XIAOJU_TOKEN")
    code, b = call("GET", "/items?" + urllib.parse.urlencode({"path": "/", "limit": "1000"}))
    if code != 200:
        sys.exit(f"列云盘根目录失败 {code}: {b[:300]!r}")
    names = [c["name"] for c in json.loads(b).get("children", []) if c["type"] == "folder"]
    root = next((n for n in names if n.replace(" ", "").replace("-", "").lower() == "metawork"), None)
    if not root:
        sys.exit(f"云盘根目录没找到 metawork 文件夹，现有：{names}")
    dest = f"/{root}/cloude审阅/小橘推送"
    print("复制到", dest)

    files = []
    for s in SOURCES:
        if os.path.isfile(s):
            files.append(s)
        for d, _, fs in os.walk(s):
            files += [os.path.join(d, f) for f in fs]
    ok = 0
    for f in sorted(files):
        rel = f[len("src/xiaoju-push/"):] if f.startswith("src/xiaoju-push/") else f
        path = f"{dest}/{rel}"
        data = open(f, "rb").read()
        code, b = call("PUT", "/files?" + urllib.parse.urlencode({"path": path}), data,
                       {"Content-Type": "application/octet-stream"})
        if code == 409:  # 已存在：覆盖
            code, b = call("PUT", "/files?" + urllib.parse.urlencode({"path": path, "overwrite": "true"}), data,
                           {"Content-Type": "application/octet-stream"})
        print(f"{'✓' if code < 300 else '✗'} {code} {path}" + ("" if code < 300 else f"  {b[:200]!r}"))
        ok += code < 300
    print(f"完成：{ok}/{len(files)} 个文件")
    if ok != len(files):
        sys.exit(1)


main()
