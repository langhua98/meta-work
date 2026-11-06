#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""端到端跑通测试（全在本地，不碰真云盘）：
  1. 起假云盘
  2. 起「被控端模拟器」（照搬 RemoteCenter 的逻辑：轮询收件→执行→写回执/照片）
  3. 用真实的 scripts/遥控/遥控.py 当控制端发指令，验证能收到回执和照片
控制端 App（RemoteControl.swift）用的是和 遥控.py 完全一样的接口与信箱路径，所以这测的就是那条链路。
"""
import json, os, socket, subprocess, sys, threading, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", "..", ".."))  # 回到 meta-work
SENDER = None
for base in (os.getcwd(), "/home/user/meta-work"):
    cand = os.path.join(base, "scripts", "遥控", "遥控.py")
    if os.path.exists(cand):
        SENDER = cand; break

sys.path.insert(0, HERE)
import mock_cloud  # noqa

DEVICE = "测试机B"
PAIR = "secret"


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def api(base, method, path, data=None):
    req = urllib.request.Request(base + path, method=method, data=data)
    req.add_header("Authorization", "Bearer xa_test")
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read()


JPEG = bytes.fromhex("ffd8ffe000104a46494600010100000100010000ffdb004300"
                     "0806060706060807070709090807") + b"\x00" * 40 + bytes.fromhex("ffd9")


def slave_loop(base, stop):
    """被控端模拟器：照搬 RemoteCenter.loop/handle 的流程。"""
    seen = set()
    inbox = f"/小橘推送/遥控/{DEVICE}/收件"
    outbox = f"/小橘推送/遥控/{DEVICE}/回执"
    fdir = f"/小橘推送/遥控/{DEVICE}/文件"
    while not stop.is_set():
        try:
            j = json.loads(api(base, "GET", f"/api/agent/v1/items?path={urlq(inbox)}&limit=200"))
            for it in (j.get("children") or []):
                if it["type"] == "folder" or not it["name"].endswith(".json"):
                    continue
                if it["id"] in seen:
                    continue
                seen.add(it["id"])
                handle(base, it, outbox, fdir)
        except Exception as e:
            pass
        time.sleep(1)


def urlq(p):
    import urllib.parse
    return urllib.parse.quote(p)


def handle(base, it, outbox, fdir):
    cmd = json.loads(api(base, "GET", f"/api/agent/v1/items/{it['id']}/content"))
    cid = cmd.get("id") or it["name"][:-5]
    if cmd.get("pair") not in (None, PAIR):
        receipt = {"id": cid, "ok": False, "text": "配对口令不对"}
        api(base, "PUT", f"/files?path={urlq(outbox + '/' + cid + '.json')}", json.dumps(receipt).encode())
        return
    do = cmd.get("do")
    files = []
    if do == "photo":
        p = f"{fdir}/{cid}-photo.jpg"
        api(base, "PUT", f"/files?path={urlq(p)}", JPEG)
        files = [p]
        text = f"拍了一张（{'前' if cmd.get('lens')=='front' else '后'}摄，{len(JPEG)//1024 or 1} KB）"
    elif do == "info":
        text = "型号：iPhone\n系统：iOS 18\n电量：88%"
    elif do == "torch":
        text = "手电筒已" + ("打开" if cmd.get("on", True) else "关闭")
    elif do == "location":
        text = "纬度 31.23，经度 121.47，精度 10 米"
    elif do == "ring":
        text = "响了"
    else:
        text = f"做了：{do}"
    receipt = {"id": cid, "do": do, "ok": True, "text": text, "files": files, "at": "now"}
    api(base, "PUT", f"/files?path={urlq(outbox + '/' + cid + '.json')}", json.dumps(receipt).encode())


def run_sender(base, args, save):
    env = {k: v for k, v in os.environ.items()
           if k.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
    env.update({"XIAOJU_BASE": base, "XIAOJU_TOKEN": "xa_test", "XIAOJU_PAIR": PAIR,
                "no_proxy": "*", "NO_PROXY": "*"})
    cmd = [sys.executable, SENDER, DEVICE] + args + ["--save", save, "--timeout", "30"]
    return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=60)


def main():
    assert SENDER, "找不到 遥控.py"
    port = free_port()
    mock_cloud.serve(port)
    base = f"http://127.0.0.1:{port}"
    time.sleep(0.3)
    # 自检
    assert json.loads(api(base, "GET", "/api/agent/v1/me"))["agent"]["name"]

    stop = threading.Event()
    threading.Thread(target=slave_loop, args=(base, stop), daemon=True).start()

    save = os.path.join(HERE, "out"); os.makedirs(save, exist_ok=True)
    results = []
    ok = True

    # 1) 拍照：要有回执 + 下载到照片
    r = run_sender(base, ["photo", "--lens", "front"], save)
    got_photo = any(f.endswith(".jpg") for f in os.listdir(save))
    passed = r.returncode == 0 and "回执" in r.stdout and got_photo
    results.append(("拍照(前摄)+取图", passed, r.stdout.strip().replace("\n", " | ")))
    ok &= passed

    # 2) 信息
    r = run_sender(base, ["info"], save)
    passed = r.returncode == 0 and "电量" in r.stdout
    results.append(("设备信息", passed, r.stdout.strip().replace("\n", " | ")))
    ok &= passed

    # 3) 手电
    r = run_sender(base, ["torch", "--on"], save)
    passed = r.returncode == 0 and "手电筒已打开" in r.stdout
    results.append(("手电筒开", passed, r.stdout.strip().replace("\n", " | ")))
    ok &= passed

    # 4) 定位
    r = run_sender(base, ["location"], save)
    passed = r.returncode == 0 and "纬度" in r.stdout
    results.append(("定位", passed, r.stdout.strip().replace("\n", " | ")))
    ok &= passed

    # 5) 口令不对要被拒
    env_bad = {k: v for k, v in os.environ.items() if k.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
    env_bad.update({"XIAOJU_BASE": base, "XIAOJU_TOKEN": "xa_test", "XIAOJU_PAIR": "wrong",
                    "no_proxy": "*", "NO_PROXY": "*"})
    rb = subprocess.run([sys.executable, SENDER, DEVICE, "info", "--timeout", "15"],
                        env=env_bad, capture_output=True, text=True, timeout=40)
    passed = "口令不对" in rb.stdout
    results.append(("错口令被拒", passed, rb.stdout.strip().replace("\n", " | ")))
    ok &= passed

    stop.set()
    print("\n==== 结果 ====")
    for name, p, out in results:
        print(f"[{'通过' if p else '失败'}] {name}")
        print(f"        {out[:200]}")
    print("\n总判定:", "全部通过 ✅" if ok else "有失败 ❌")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
