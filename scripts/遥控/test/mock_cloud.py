#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假的小橘云盘：实现 CloudFiles / 遥控.py 用到的那几个接口。只在本地测试用。
  GET  /api/agent/v1/me
  GET  /api/agent/v1/items?path=P&limit=N   -> {item, children, next_cursor}
  GET  /api/agent/v1/items/{id}/content
  PUT  /api/agent/v1/files?path=P            (原始字节)
  POST /api/agent/v1/relay?box=B             即时信箱（RELAY=True 时才有，模拟新服务端；False 时 404，模拟旧服务端）
  GET  /api/agent/v1/relay?box=B&wait=S
"""
import json, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
FILES = {}          # clean_path -> bytes
IDS = {}            # id -> clean_path
PATH2ID = {}        # clean_path -> id
_next = [1]
RELAY = False       # 是否模拟带即时信箱的新服务端
BOXES = {}          # box -> [message]
COND = threading.Condition(LOCK)


def clean(p):
    segs = [s for s in p.split("/") if s and s not in (".", "..")]
    return "/" + "/".join(segs)


def ensure_id(path):
    if path not in PATH2ID:
        i = str(_next[0]); _next[0] += 1
        PATH2ID[path] = i; IDS[i] = path
    return PATH2ID[path]


def entry(path, is_folder):
    return {"id": ensure_id(path), "name": path.rsplit("/", 1)[-1],
            "type": "folder" if is_folder else "file",
            "path": path, "size": (0 if is_folder else len(FILES.get(path, b""))),
            "etag": "e" + ensure_id(path)}


def children_of(folder):
    folder = clean(folder)
    prefix = "" if folder == "/" else folder
    kids, seen = [], set()
    for p in list(FILES.keys()):
        if p.startswith(prefix + "/"):
            rest = p[len(prefix) + 1:]
            if "/" in rest:                      # 子文件夹
                sub = prefix + "/" + rest.split("/", 1)[0]
                if sub not in seen:
                    seen.add(sub); kids.append(entry(sub, True))
            else:
                kids.append(entry(p, False))
    return kids


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # 安静
        pass

    def _send(self, code, obj=None, raw=None):
        self.send_response(code)
        if raw is not None:
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers(); self.wfile.write(raw)
        else:
            body = json.dumps(obj or {}).encode()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)

    def _auth_ok(self):
        # 真云盘要 Authorization: Bearer xa_… ；这里只要求非空，模拟「少令牌就 401」
        h = self.headers.get("Authorization", "")
        return h.startswith("Bearer ") and len(h) > len("Bearer ")

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if not self._auth_ok():
            return self._send(401, {"code": "unauthorized", "error": "missing agent token"})
        if u.path == "/api/agent/v1/me":
            return self._send(200, {"agent": {"name": "mock云盘"}})
        if u.path.startswith("/api/agent/v1/items/") and u.path.endswith("/content"):
            fid = u.path.split("/")[-2]
            with LOCK:
                p = IDS.get(fid)
                if p is None or p not in FILES:
                    return self._send(404, {"message": "没有这个文件"})
                return self._send(200, raw=FILES[p])
        if u.path == "/api/agent/v1/relay" and RELAY:
            box = q.get("box", [""])[0]
            wait = min(int(q.get("wait", ["0"])[0] or 0), 25)
            with COND:
                COND.wait_for(lambda: BOXES.get(box), timeout=wait)
                msgs = BOXES.pop(box, [])
            return self._send(200, {"messages": [{"at": "now", "body": m} for m in msgs]})
        if u.path == "/api/agent/v1/items":
            path = clean(q.get("path", ["/"])[0])
            with LOCK:
                if path in FILES:                # 是文件
                    return self._send(200, {"item": entry(path, False), "children": None, "next_cursor": None})
                kids = children_of(path)         # 当文件夹
                item = entry(path, True) if (kids or path == "/") else None
                return self._send(200, {"item": item, "children": kids, "next_cursor": None})
        return self._send(404, {"message": "没有这个"})

    def do_PUT(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if not self._auth_ok():
            return self._send(401, {"code": "unauthorized", "error": "missing agent token"})
        if u.path == "/api/agent/v1/files":      # 真云盘的上传接口（不是 /files）
            n = int(self.headers.get("Content-Length", 0))
            data = self.rfile.read(n)
            path = clean(q.get("path", [""])[0])
            with LOCK:
                FILES[path] = data; ensure_id(path)
            return self._send(200, {"ok": True, "path": path})
        return self._send(404, {"message": "没有这个"})


    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if not self._auth_ok():
            return self._send(401, {"code": "unauthorized", "error": "missing agent token"})
        if u.path == "/api/agent/v1/relay" and RELAY:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            with COND:
                BOXES.setdefault(q.get("box", [""])[0], []).append(body)
                COND.notify_all()
            return self._send(200, {"ok": True})
        return self._send(404, {"message": "没有这个"})


def serve(port):
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


if __name__ == "__main__":
    import sys
    serve(int(sys.argv[1])); import time; time.sleep(3600)
