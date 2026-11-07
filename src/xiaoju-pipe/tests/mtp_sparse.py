#!/usr/bin/env python3
"""模拟 App 只下 MTP 层：从带 MTP 的 GGUF 里只拷文件头和 MTP 那一层，其余留空洞（和原文件一样大）。

    python3 tests/mtp_sparse.py 带MTP的.gguf 输出.gguf
"""
import struct
import sys

src, dst = sys.argv[1], sys.argv[2]
f = open(src, "rb")


def rd(fmt):
    return struct.unpack("<" + fmt, f.read(struct.calcsize("<" + fmt)))[0]


def rs():
    return f.read(rd("Q")).decode("utf-8", "replace")


SC = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}


def val(t):
    if t == 8:
        return rs()
    if t == 9:
        at, n = rd("I"), rd("Q")
        return [val(at) for _ in range(n)]
    return rd(SC[t])


assert f.read(4) == b"GGUF"
rd("I")
nt, nkv = rd("Q"), rd("Q")
kv = {}
for _ in range(nkv):
    k = rs()
    kv[k] = val(rd("I"))
align = kv.get("general.alignment", 32)
bc = kv["qwen35.block_count"]
pre = f"blk.{bc - 1}."
offs = []
for _ in range(nt):
    name = rs()
    nd = rd("I")
    [rd("Q") for _ in range(nd)]
    rd("I")
    off = rd("Q")
    offs.append((off, name))
data_off = (f.tell() + align - 1) // align * align
offs.sort()
size = f.seek(0, 2)
lo = hi = None
for i, (off, name) in enumerate(offs):
    if name.startswith(pre):
        end = offs[i + 1][0] if i + 1 < len(offs) else size - data_off
        lo = off if lo is None else min(lo, off)
        hi = end if hi is None else max(hi, end)
assert lo is not None, "没有 MTP 层"
with open(dst, "wb") as o:
    o.truncate(size)
    f.seek(0)
    o.write(f.read(data_off))
    f.seek(data_off + lo)
    o.seek(data_off + lo)
    o.write(f.read(hi - lo))
print(f"{dst}：文件头 {data_off} 字节 + MTP 层 {(hi - lo) / 1048576:.1f} MB（第 {bc - 1} 层），其余空洞")
