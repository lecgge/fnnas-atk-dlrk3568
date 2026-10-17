#!/bin/bash
S=/root/fnnas-re/storage.hdl
OD=aarch64-linux-gnu-objdump
A=/tmp/stor.asm

echo "════ 0x391c0 所在的函数 ════"
awk 'NR<=52016 && /^[0-9a-f]{16} </ {fn=$0; ln=NR} END{}' $A >/dev/null
sed -n '1,52016p' $A | grep -E "^[0-9a-f]{16} <" | tail -2

echo
echo "════ 该函数入口到调用点的指令 ════"
sed -n '51900,52060p' $A

echo
echo "════ 该函数内引用的字符串地址 ════"
sed -n '51900,52600p' $A | grep -oE "adrp\s+x[0-9]+, [0-9a-f]+" | sort -u | head -20
