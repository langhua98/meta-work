#!/usr/bin/env python3
"""把编好的安装包传到小橘云盘「软件包」，再把同一个软件的旧包删掉（DELETE 只进回收站）。

    python3 scripts/upload_package.py XiaojuPipe-0.2-build14.ipa XiaojuPipe-

第二个参数是这个软件安装包的文件名前缀：/软件包/ 里以它开头、又不是这次新传的文件，都当旧包删掉，
文件夹里每个软件只留最新一版（AGENTS.md 的约定）。
需要环境变量 XIAOJU_TOKEN（有写权限的 xa_ 令牌）。
"""
import json, os, sys, urllib.parse, urllib.request, urllib.error

BASE = (os.environ.get("XIAOJU_URL") or "https://langhua1998-xiaoju-cloud.hf.space").rstrip("/") + "/api/agent/v1"
TOKEN = os.environ.get("XIAOJU_TOKEN", "")
FOLDER = "/软件包"


def call(method, path, body=None, headers=None):
    req = urllib.request.Request(BASE + path, data=body, method=method,
                                 headers={"Authorization": f"Bearer {TOKEN}", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    if not TOKEN:
        sys.exit("缺少 XIAOJU_TOKEN")
    path, prefix = sys.argv[1], sys.argv[2]
    name = os.path.basename(path)
    if not name.startswith(prefix):
        sys.exit(f"{name} 不是以 {prefix} 开头，删旧包会删错，停下")
    data = open(path, "rb").read()
    dest = f"{FOLDER}/{name}"
    q = {"path": dest}
    code, b = call("PUT", "/files?" + urllib.parse.urlencode(q), data, {"Content-Type": "application/octet-stream"})
    if code == 409:  # 同名已存在（同一次构建重跑）：覆盖
        q["overwrite"] = "true"
        code, b = call("PUT", "/files?" + urllib.parse.urlencode(q), data, {"Content-Type": "application/octet-stream"})
    if code >= 300:
        sys.exit(f"上传失败 {code}: {b[:300]!r}")
    print(f"已上传 {dest}（{len(data) / 1048576:.1f} MB）")

    code, b = call("GET", "/items?" + urllib.parse.urlencode({"path": FOLDER, "limit": "1000"}))
    if code != 200:
        sys.exit(f"列 {FOLDER} 失败 {code}: {b[:300]!r}")
    for c in json.loads(b).get("children", []):
        if c.get("type") == "folder" or c["name"] == name or not c["name"].startswith(prefix):
            continue
        h = {"If-Match": c["etag"]} if c.get("etag") else {}
        code, b = call("DELETE", f"/items/{c['id']}", headers=h)
        print(f"{'已删旧包' if code < 300 else '删旧包失败'} {c['name']}" + ("" if code < 300 else f" {code}: {b[:200]!r}"))


main()
