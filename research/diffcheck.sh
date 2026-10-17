#!/bin/bash
# 精确定位成品镜像与源镜像的差异范围，确认只在预期区域内
SRC=/mnt/c/Users/Xuleyu/Documents/work/fn-atk/hdmi_ubuntu26.04.1_update.img
DST=/mnt/c/Users/Xuleyu/Documents/work/fn-atk/out/fnnas_ATK-DLRK3568_FnNAS-final_2026.10.16.img
python3 - "$SRC" "$DST" <<'PY'
import sys
a = open(sys.argv[1],'rb').read()
b = open(sys.argv[2],'rb').read()
print(f"源  {len(a)} 字节")
print(f"成品 {len(b)} 字节")
n = min(len(a), len(b))
BOOT_OFF, FSZ = 0x4F9226, 18189312
ROOT_OFF, RSZ  = 0x5B8C226, 3577741312
SLOT_LO, SLOT_HI = 0x76A26, 0x76A26 + 8 + 492   # parameter.txt 槽位（含 8 字节头）

# 逐段扫描，记录连续差异区间
ranges = []
i = 0
CH = 1 << 20
while i < n:
    if a[i:i+CH] != b[i:i+CH]:
        j = i
        while j < n:
            lo, hi = j, min(j + 65536, n)
            if a[lo:hi] != b[lo:hi]:
                j = hi
            else:
                break
        ranges.append((i, j))
        i = j
    else:
        i += CH

print(f"\n差异区间数: {len(ranges)}")
expected = [
    ("parameter.txt 槽位", SLOT_LO, SLOT_HI),
    ("boot.img",           BOOT_OFF, BOOT_OFF + FSZ),
    ("rootfs.img",         ROOT_OFF, ROOT_OFF + RSZ),
]
for (s, e) in ranges:
    label = "（预期内）"
    for name, s0, e0 in expected:
        if s >= s0 and e <= e0:
            label = f"✔ {name}"
            break
    else:
        label = "✘ 意外区域"
    print(f"  0x{s:08X} - 0x{e:08X}  {e-s:>10,} 字节  {label}")

ok = True
for s, e in ranges:
    if not any(s >= s0 and e <= e0 for _, s0, e0 in expected):
        ok = False
print("\n结论:", "✔ 所有差异都在预期区域内" if ok else "✘ 存在预期外的差异")
PY
