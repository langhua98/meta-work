#!/usr/bin/env python3
"""生成 core/xj_nfc.h：NFC 的两两组合表（基字 + 组合符号 → 合成字），分词前做 NFC 用。
Qwen3.5 的 tokenizer.json 有 NFC 规范化：e + U+0301 要先合成 é 再分词。
    python3 tools/gen_nfc.py > core/xj_nfc.h
韩文音节按公式算，不在表里。"""
import unicodedata

pairs = []
for c in range(0x110000):
    if 0xAC00 <= c <= 0xD7A3:
        continue
    d = unicodedata.decomposition(chr(c))
    if not d or d.startswith("<"):
        continue
    parts = [int(x, 16) for x in d.split()]
    if len(parts) != 2:
        continue
    if unicodedata.normalize("NFC", chr(parts[0]) + chr(parts[1])) != chr(c):
        continue  # 组合排除表里的字
    pairs.append((parts[0], parts[1], c))
pairs.sort()
print(f"// 自动生成（tools/gen_nfc.py，Unicode {unicodedata.unidata_version}），别手改。")
print("// NFC 两两组合：{基字, 组合符号, 合成字}，按 (基字, 组合符号) 排好，二分查找。")
print("#pragma once")
print("#include <stdint.h>")
print(f"static const uint32_t xj_nfc_pairs[{len(pairs)}][3] = {{")
for i in range(0, len(pairs), 4):
    print("    " + " ".join("{0x%X,0x%X,0x%X}," % p for p in pairs[i:i + 4]))
print("};")
