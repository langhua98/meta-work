#!/usr/bin/env python3
# 只读 GGUF 文件头（元数据 + 张量表），文件只下了开头一段也能看。用法：gguf_head.py 文件 [张量名正则]
import re, struct, sys
f = open(sys.argv[1], 'rb')
pat = re.compile(sys.argv[2]) if len(sys.argv) > 2 else None
def rd(fmt): return struct.unpack('<' + fmt, f.read(struct.calcsize('<' + fmt)))[0]
def rs(): n = rd('Q'); return f.read(n).decode('utf-8', 'replace')
SC = {0: 'B', 1: 'b', 2: 'H', 3: 'h', 4: 'I', 5: 'i', 6: 'f', 7: '?', 10: 'Q', 11: 'q', 12: 'd'}
def val(t):
    if t == 8: return rs()
    if t == 9:
        at, n = rd('I'), rd('Q')
        items = [val(at) for _ in range(n)]
        return f'[{n} 项] ' + (str(items[:40]) if at != 8 else '')
    return rd(SC[t])
assert f.read(4) == b'GGUF'
ver, nt, nkv = rd('I'), rd('Q'), rd('Q')
print(f'version={ver} tensors={nt} kv={nkv}')
for _ in range(nkv):
    k = rs(); v = val(rd('I'))
    if not k.startswith('tokenizer.') and not k.startswith('quantize.'): print(' ', k, '=', v)
TN = {0: 'F32', 1: 'F16', 8: 'Q8_0', 12: 'Q4_K', 13: 'Q5_K', 14: 'Q6_K', 30: 'BF16'}
for _ in range(nt):
    name = rs(); nd = rd('I'); dims = [rd('Q') for _ in range(nd)]; t = rd('I'); off = rd('Q')
    if pat is None or pat.search(name): print(f'  {name} {dims} {TN.get(t, t)} @{off}')
