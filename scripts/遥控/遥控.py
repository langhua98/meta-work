#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""小橘遥控 · 发送端。

在 A 设备（或任意能上网的终端）跑：往云盘收件箱写一条指令，等 B 把回执写回来。
B 设备装了「小橘遥控」App 并开着「待命」。

环境变量：
  XIAOJU_BASE   云盘地址，默认 https://langhua1998-xiaoju-cloud.hf.space
  XIAOJU_TOKEN  云盘令牌 xa_…（必填，要有写权限）
  XIAOJU_PAIR   配对口令，要和 B 手机里填的一样

例子：
  遥控.py 测试机B info
  遥控.py 测试机B photo --lens front
  遥控.py 测试机B audio --seconds 8
  遥控.py 测试机B torch --on
  遥控.py 测试机B torch --off
  遥控.py 测试机B location
  遥控.py 测试机B ring --seconds 5
  遥控.py 测试机B shell --cmd "ls -la /sdcard"
"""
import argparse, base64, json, os, sys, time, urllib.error, urllib.parse, urllib.request, uuid

BASE = os.environ.get("XIAOJU_BASE", "https://langhua1998-xiaoju-cloud.hf.space").rstrip("/")
TOKEN = os.environ.get("XIAOJU_TOKEN", "")
PAIR = os.environ.get("XIAOJU_PAIR", "")


def req(method, path, query=None, data=None, ctype="application/octet-stream"):
    url = BASE + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    r = urllib.request.Request(url, method=method, data=data)
    r.add_header("Authorization", "Bearer " + TOKEN)
    if data is not None:
        r.add_header("Content-Type", ctype)
    with urllib.request.urlopen(r, timeout=120) as resp:
        return resp.read()


def put_file(path, raw, ctype="application/octet-stream"):
    return req("PUT", "/api/agent/v1/files", query={"path": path}, data=raw, ctype=ctype)


def list_dir(path):
    try:
        j = json.loads(req("GET", "/api/agent/v1/items", query={"path": path, "limit": "1000"}))
        return j.get("children") or []
    except Exception:
        return []


def relay_send(box, obj):
    """即时信箱（服务端内存里，长轮询，比写文件快得多）。服务端还没有时返回 False。"""
    try:
        req("POST", "/api/agent/v1/relay", query={"box": box},
            data=json.dumps(obj, ensure_ascii=False).encode("utf-8"), ctype="application/json")
        return True
    except urllib.error.HTTPError as e:
        if e.code in (404, 405, 501):  # 服务端还没上即时信箱
            return False
        raise


def relay_wait(box, seconds):
    j = json.loads(req("GET", "/api/agent/v1/relay", query={"box": box, "wait": str(seconds)}))
    return [m.get("body") for m in j.get("messages") or []]


def download(item_id):
    return req("GET", f"/api/agent/v1/items/{item_id}/content")


def main():
    ap = argparse.ArgumentParser(description="小橘遥控发送端")
    ap.add_argument("device", help="B 设备的名字，和 App 里填的一样")
    ap.add_argument("action", choices=["info", "photo", "audio", "location", "torch", "vibrate", "ring", "shell"])
    ap.add_argument("--lens", choices=["back", "front"], default="back")
    ap.add_argument("--seconds", type=int, default=5)
    ap.add_argument("--on", action="store_true")
    ap.add_argument("--off", action="store_true")
    ap.add_argument("--ms", type=int, default=800)
    ap.add_argument("--cmd", default="")
    ap.add_argument("--save", default=".", help="回执里的文件下载到哪个目录")
    ap.add_argument("--timeout", type=int, default=90, help="等回执最多多少秒")
    a = ap.parse_args()

    if not TOKEN:
        sys.exit("先设置 XIAOJU_TOKEN（云盘令牌）")

    cid = time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6]
    cmd = {"id": cid, "pair": PAIR, "do": a.action}
    if a.action == "photo":
        cmd["lens"] = a.lens
    elif a.action in ("audio", "ring"):
        cmd["seconds"] = a.seconds
    elif a.action == "torch":
        cmd["on"] = not a.off  # 默认开，--off 关
    elif a.action == "vibrate":
        cmd["ms"] = a.ms
    elif a.action == "shell":
        if not a.cmd:
            sys.exit("shell 要用 --cmd 给命令")
        cmd["cmd"] = a.cmd

    sent = time.time()
    via_relay = relay_send(f"遥控/{a.device}/收件", cmd)
    if not via_relay:
        inbox = f"/小橘推送/遥控/{a.device}/收件/{cid}.json"
        put_file(inbox, json.dumps(cmd, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")
    print(f"已发送 [{a.action}] → {a.device}（id {cid}{'' if via_relay else '，走文件信箱'}），等回执…")

    outbox = f"/小橘推送/遥控/{a.device}/回执"
    deadline = time.time() + a.timeout
    while time.time() < deadline:
        r = None
        if via_relay:
            left = max(1, min(25, int(deadline - time.time())))
            got = relay_wait(f"遥控/{a.device}/回执/{cid}", left)
            r = got[0] if got else None
        else:
            time.sleep(1)
            it = next((x for x in list_dir(outbox) if x.get("name") == f"{cid}.json"), None)
            if it:
                r = json.loads(download(it["id"]))
        if not r:
            continue
        print(f"—— 回执（{time.time() - sent:.1f} 秒）——")
        print(r.get("text", ""))
        for fp in r.get("files", []):
            if isinstance(fp, dict):  # 即时信箱：文件直接放在回执里
                out = os.path.join(a.save, f"{cid}-{fp.get('name', 'file')}")
                with open(out, "wb") as f:
                    f.write(base64.b64decode(fp.get("data", "")))
                print("已保存：" + out)
                continue
            name = os.path.basename(fp)
            # 回执里的是云盘路径，再按路径找到文件下载
            folder = os.path.dirname(fp)
            match = next((x for x in list_dir(folder) if x.get("name") == name), None)
            if match:
                out = os.path.join(a.save, f"{cid}-{name}")
                with open(out, "wb") as f:
                    f.write(download(match["id"]))
                print("已下载：" + out)
        return
    print("超时没收到回执。确认 B 手机开着 App 的「待命」、口令一致、设备名一致。")


if __name__ == "__main__":
    main()
