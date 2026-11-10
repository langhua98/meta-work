#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""小橘遥控 · 发送端。

在 A 设备（或任意能上网的终端）跑：往云盘收件箱写一条指令，等 B 把回执写回来。
B 设备装了「小橘遥控」App 并开着「待命」。

环境变量：
  XIAOJU_BASE   云盘地址，默认 https://node.tail823dbd.ts.net
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
  遥控.py 测试机B gimbal                       （大疆云台状态）
  遥控.py 测试机B gimbal --go turn --yaw 30     （往右转 30°，闭环）
  遥控.py 测试机B gimbal --go look --yaw -45 --pitch 10   （转到相对归位点的方向）
  遥控.py 测试机B gimbal --go move --yaw 20 --ms 1000     （按 20°/s 转 1 秒）
  遥控.py 测试机B gimbal --go center          （回到归位点）

备用通道（安卓 0.31+）：云盘（家里电脑）连不上时，指令和回执改走公共信箱 ntfy.sh，内容加密。
密钥是手机生成的，云盘正常时存在 /小橘推送/遥控/<设备名>/备用通道.json；这个脚本云盘正常时取一份
存到 ~/.xiaoju-remote/备用通道-<设备名>.json，云盘停了就用它。算法和安卓的 BackupCrypto.kt 一样。
"""
import argparse, base64, hashlib, hmac, json, os, sys, time, urllib.error, urllib.parse, urllib.request, uuid

BASE = os.environ.get("XIAOJU_BASE", "https://node.tail823dbd.ts.net").rstrip("/")
TOKEN = os.environ.get("XIAOJU_TOKEN", "")
PAIR = os.environ.get("XIAOJU_PAIR", "0")  # 法莉娅（安卓）默认口令是 0


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


# ---- 备用通道（ntfy.sh，加密）----

BACKUP_DIR = os.path.expanduser("~/.xiaoju-remote")


def _h(key, *parts):
    m = hmac.new(key, digestmod=hashlib.sha256)
    for p in parts:
        m.update(p)
    return m.digest()


def _stream(enc, nonce, data):
    out = bytearray(len(data))
    for blk in range((len(data) + 31) // 32):
        ks = _h(enc, nonce, blk.to_bytes(4, "big"))
        s = blk * 32
        for i in range(min(32, len(data) - s)):
            out[s + i] = data[s + i] ^ ks[i]
    return bytes(out)


def bk_seal(key, plain, nonce=None):
    """nonce(16) ‖ 明文 XOR 密钥流 ‖ tag(32)，见安卓 BackupCrypto.kt"""
    nonce = nonce or os.urandom(16)
    ct = _stream(_h(key, b"xj-enc"), nonce, plain)
    return nonce + ct + _h(_h(key, b"xj-mac"), nonce, ct)


def bk_open(key, sealed):
    if len(sealed) < 48:
        return None
    nonce, ct, tag = sealed[:16], sealed[16:-32], sealed[-32:]
    if not hmac.compare_digest(tag, _h(_h(key, b"xj-mac"), nonce, ct)):
        return None
    return _stream(_h(key, b"xj-enc"), nonce, ct)


def bk_open_text(key, text):
    if not text.startswith("xj1."):
        return None
    try:
        return bk_open(key, base64.b64decode(text[4:]))
    except Exception:
        return None


def backup_path(device):
    return os.path.join(BACKUP_DIR, f"备用通道-{device}.json")


def backup_refresh(device):
    """云盘正常时取手机存的备用通道密钥，记到本机。取不到不要紧。"""
    try:
        it = next((x for x in list_dir(f"/小橘推送/遥控/{device}") if x.get("name") == "备用通道.json"), None)
        if not it:
            return
        info = json.loads(download(it["id"]))
        if len(base64.b64decode(info.get("key", ""))) != 32:
            return
        os.makedirs(BACKUP_DIR, exist_ok=True)
        fd = os.open(backup_path(device), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(info, f)
    except Exception:
        pass


def backup_info(device):
    try:
        with open(backup_path(device)) as f:
            return json.load(f)
    except Exception:
        return None


def backup_send(info, cmd):
    c = dict(cmd, at=int(time.time()))  # 手机拒绝 15 分钟以前的指令
    key = base64.b64decode(info["key"])
    body = ("xj1." + base64.b64encode(bk_seal(key, json.dumps(c, ensure_ascii=False).encode("utf-8"))).decode()).encode()
    r = urllib.request.Request(f"{info['server']}/{info['cmd']}", method="POST", data=body)
    with urllib.request.urlopen(r, timeout=30) as resp:
        resp.read()


def backup_wait(info, cid, since, deadline):
    """在 ntfy 的回执信箱里等这条指令的回执（跳过「收到了」）。"""
    key = base64.b64decode(info["key"])
    url = f"{info['server']}/{info['reply']}/json?since={int(since) - 5}"
    while time.time() < deadline:
        try:
            # ntfy 大约每 45 秒发一次 keepalive，90 秒没东西就当断了
            with urllib.request.urlopen(url, timeout=90) as resp:
                for raw in resp:
                    if time.time() >= deadline:
                        return None
                    try:
                        m = json.loads(raw)
                    except Exception:
                        continue
                    if m.get("event") != "message":
                        continue
                    att = m.get("attachment") or {}
                    if att.get("url"):
                        with urllib.request.urlopen(att["url"], timeout=120) as a:
                            plain = bk_open(key, a.read())
                    else:
                        plain = bk_open_text(key, m.get("message", ""))
                    if not plain:
                        continue
                    r = json.loads(plain)
                    if r.get("id") == cid and not r.get("pending"):
                        return r
        except Exception:
            time.sleep(3)
    return None


def main():
    ap = argparse.ArgumentParser(description="小橘遥控发送端")
    ap.add_argument("device", help="B 设备的名字，和 App 里填的一样")
    ap.add_argument("action", choices=["info", "photo", "audio", "location", "torch", "vibrate", "ring", "shell", "gimbal",
                                       "update"])
    ap.add_argument("--lens", choices=["back", "front"], default="back")
    ap.add_argument("--seconds", type=int, default=5)
    ap.add_argument("--on", action="store_true")
    ap.add_argument("--off", action="store_true")
    ap.add_argument("--ms", type=int, default=800)
    ap.add_argument("--cmd", default="")
    ap.add_argument("--go", default="status",
                    choices=["status", "connect", "disconnect", "turn", "look", "move", "stop", "center", "home"],
                    help="gimbal 的动作")
    ap.add_argument("--yaw", type=float, help="gimbal：左右（度，或 move 时的度每秒）")
    ap.add_argument("--pitch", type=float, help="gimbal：上下（度，或 move 时的度每秒）")
    ap.add_argument("--save", default=".", help="回执里的文件下载到哪个目录")
    ap.add_argument("--check", action="store_true", help="update：只看有没有新版本，不下载")
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
    elif a.action == "update":  # 安卓被控端（法莉娅）0.19+：查云盘「软件包」，有新版本就下载、安装
        if a.check:
            cmd["check"] = True
        a.timeout = max(a.timeout, 300)  # 要下载安装包，慢一点
    elif a.action == "shell":
        if not a.cmd:
            sys.exit("shell 要用 --cmd 给命令")
        cmd["cmd"] = a.cmd
    elif a.action == "gimbal":
        cmd["action"] = a.go
        if a.yaw is not None:
            cmd["yaw"] = a.yaw
        if a.pitch is not None:
            cmd["pitch"] = a.pitch
        if a.go == "move":
            cmd["ms"] = a.ms

    sent = time.time()
    try:
        via_relay = relay_send(f"遥控/{a.device}/收件", cmd)
        if not via_relay:
            inbox = f"/小橘推送/遥控/{a.device}/收件/{cid}.json"
            put_file(inbox, json.dumps(cmd, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")
        backup_refresh(a.device)  # 云盘好着：顺便取一下备用通道的密钥
        backup = None
    except (urllib.error.URLError, OSError) as e:
        if isinstance(e, urllib.error.HTTPError) and e.code < 500:
            raise
        # 云盘连不上（家里电脑关机）：改走备用通道
        backup = backup_info(a.device)
        if not backup:
            sys.exit(f"云盘连不上（{e}），备用通道也还没准备好：云盘正常时先发一次指令，才会取到密钥")
        backup_send(backup, cmd)
        via_relay = False
    print(f"已发送 [{a.action}] → {a.device}（id {cid}"
          f"{'，云盘连不上，走备用通道（手机切过来可能要等一会儿）' if backup else ('' if via_relay else '，走文件信箱')}），等回执…")

    outbox = f"/小橘推送/遥控/{a.device}/回执"
    deadline = time.time() + a.timeout + (300 if backup else 0)
    while time.time() < deadline:
        r = None
        if backup:
            r = backup_wait(backup, cid, sent, deadline)
            if not r:
                break
        elif via_relay:
            left = max(1, min(25, int(deadline - time.time())))
            got = relay_wait(f"遥控/{a.device}/回执/{cid}", left)
            r = got[0] if got else None
        elif not backup:
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
