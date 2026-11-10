#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""备用通道测试（全在本地）：云盘连不上时，遥控.py 改走 ntfy（这里起一个假的 ntfy），指令和回执都加密。

  1. 加密和安卓 BackupCrypto.kt 对得上（同一组测试值，安卓的 BackupCryptoTest 里也有）
  2. 云盘地址连不上 → 遥控.py 用记下来的密钥走备用通道，收到小回执（消息正文）和大回执（加密附件、带照片）
  3. 假 ntfy 上看到的全是密文，没有指令内容

  python3 scripts/遥控/test/test_backup.py
"""
import base64, http.server, importlib.util, json, os, socket, subprocess, sys, tempfile, threading, time, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
SENDER = os.path.join(HERE, "..", "遥控.py")
spec = importlib.util.spec_from_file_location("yk", SENDER)
yk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(yk)

DEVICE = "A"
KEY = os.urandom(32)


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


class FakeNtfy:
    """最小的 ntfy：POST/PUT /<topic> 发，GET /<topic>/json?since=<unix> 一直读（每条一行 JSON），/file/<id> 取附件。"""

    def __init__(self):
        self.msgs = []        # (topic, dict)
        self.files = {}
        self.raw = []         # 收到的原始正文，检查是不是密文
        self.lock = threading.Condition()
        fake = self

        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a): pass

            def _publish(self):
                topic = self.path.strip("/").split("?")[0]
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                fake.raw.append(body)
                with fake.lock:
                    mid = "m%d" % len(fake.msgs)
                    m = {"id": mid, "time": int(time.time()), "event": "message", "topic": topic}
                    if self.headers.get("Filename") or len(body) > 4096:
                        fid = "f%d" % len(fake.files)
                        fake.files[fid] = body
                        m["message"] = "You received a file"
                        m["attachment"] = {"name": self.headers.get("Filename", "att"), "size": len(body),
                                           "url": "http://127.0.0.1:%d/file/%s" % (fake.port, fid)}
                    else:
                        m["message"] = body.decode()
                    fake.msgs.append((topic, m))
                    fake.lock.notify_all()
                out = json.dumps(m).encode()
                self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers()
                self.wfile.write(out)

            do_POST = _publish
            do_PUT = _publish

            def do_GET(self):
                u = urllib.parse.urlparse(self.path)
                if u.path.startswith("/file/"):
                    d = fake.files[u.path[6:]]
                    self.send_response(200); self.send_header("Content-Length", str(len(d))); self.end_headers()
                    self.wfile.write(d); return
                topic = u.path.strip("/").split("/")[0]
                since = int(urllib.parse.parse_qs(u.query).get("since", ["0"])[0] or 0)
                self.send_response(200)
                self.send_header("Content-Type", "application/x-ndjson")
                self.send_header("Connection", "close")
                self.end_headers()
                sent = 0
                end = time.time() + 30
                try:
                    while time.time() < end:
                        with fake.lock:
                            todo = [m for t, m in fake.msgs[sent:] if t == topic and m["time"] >= since]
                            sent = len(fake.msgs)
                            if not todo:
                                fake.lock.wait(1)
                        for m in todo:
                            self.wfile.write((json.dumps(m) + "\n").encode()); self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.port = free_port()
        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", self.port), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d" % self.port


def fake_phone(ntfy, info, stop):
    """照着安卓 BackupChannel 的做法：收指令信箱，解密，按 at 和 id 检查，回执加密发回（大的当附件）。"""
    import urllib.request
    seen = set()
    while not stop.is_set():
        try:
            with urllib.request.urlopen(f"{ntfy.url}/{info['cmd']}/json?since=0", timeout=5) as r:
                for line in r:
                    m = json.loads(line)
                    plain = yk.bk_open_text(KEY, m.get("message", ""))
                    if not plain:
                        continue
                    cmd = json.loads(plain)
                    if cmd["id"] in seen or abs(time.time() - cmd.get("at", 0)) > 900:
                        continue
                    seen.add(cmd["id"])
                    rec = {"id": cmd["id"], "do": cmd["do"], "ok": True, "text": f"做了 {cmd['do']}"}
                    if cmd["do"] == "photo":
                        rec["files"] = [{"name": "photo.jpg", "data": base64.b64encode(os.urandom(9000)).decode()}]
                    body = json.dumps(rec).encode()
                    text = "xj1." + base64.b64encode(yk.bk_seal(KEY, body)).decode()
                    if len(text) <= 4000:
                        req = urllib.request.Request(f"{ntfy.url}/{info['reply']}", method="POST", data=text.encode())
                    else:
                        req = urllib.request.Request(f"{ntfy.url}/{info['reply']}", method="PUT",
                                                     data=yk.bk_seal(KEY, body), headers={"Filename": "r.bin"})
                    urllib.request.urlopen(req, timeout=5).read()
        except Exception:
            time.sleep(0.2)


def main():
    # 1. 测试值和安卓 BackupCryptoTest 一样
    k = bytes(range(32)); nonce = bytes(range(100, 116))
    v = "xj1." + base64.b64encode(yk.bk_seal(k, ("hello 小橘 " * 7).encode(), nonce)).decode()
    assert v == ("xj1.ZGVmZ2hpamtsbW5vcHFycz+rbKGjAYIadBdOdGXRG8Tt0YDGTKAp2V04AvkTWVriU/svC3uOKSeQ5fmhFCjgGT9dTaQx7UhmYQ9Z"
                 "33ywCEnbe6mA0zcxgURmeObUsBtpjBJoO6QGRXdA4WDLcAgrniV2Q6blqZ95CwfeNwz3+A2aXP82VyTST8DJig=="), v
    assert yk.bk_open_text(k, v) == ("hello 小橘 " * 7).encode()
    assert yk.bk_open_text(os.urandom(32), v) is None
    print("✓ 加密和安卓对得上")

    ntfy = FakeNtfy()
    info = {"v": 1, "server": ntfy.url, "device": DEVICE, "key": base64.b64encode(KEY).decode(),
            "cmd": "xjcmdtopic", "reply": "xjreplytopic"}
    home = tempfile.mkdtemp()
    os.makedirs(os.path.join(home, ".xiaoju-remote"))
    with open(os.path.join(home, ".xiaoju-remote", f"备用通道-{DEVICE}.json"), "w") as f:
        json.dump(info, f)
    stop = threading.Event()
    threading.Thread(target=fake_phone, args=(ntfy, info, stop), daemon=True).start()

    env = dict(os.environ, HOME=home, XIAOJU_TOKEN="xa_test", XIAOJU_BASE="http://127.0.0.1:%d" % free_port())
    ok = True
    for action in ("info", "photo"):
        out_dir = tempfile.mkdtemp()
        p = subprocess.run([sys.executable, SENDER, DEVICE, action, "--timeout", "20", "--save", out_dir],
                           env=env, capture_output=True, text=True, timeout=400)
        good = f"做了 {action}" in p.stdout and "备用通道" in p.stdout
        if action == "photo":
            good = good and any(n.endswith("photo.jpg") for n in os.listdir(out_dir))
        print(("✓ " if good else "✗ ") + f"云盘连不上时 {action} 走备用通道")
        if not good:
            print(p.stdout, p.stderr); ok = False
    stop.set()
    # 3. ntfy 上只有密文
    leaked = [r for r in ntfy.raw if b'"do"' in r or "做了".encode() in r]
    print(("✓ " if not leaked else "✗ ") + "ntfy 上看不到明文")
    ok = ok and not leaked
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
