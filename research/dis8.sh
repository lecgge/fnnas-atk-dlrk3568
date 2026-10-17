#!/bin/bash
S=/root/fnnas-re/storage.hdl
OD=aarch64-linux-gnu-objdump
[ -f /tmp/stor.asm ] || $OD -d -C $S > /tmp/stor.asm
A=/tmp/stor.asm

echo "════ 0x39244 ~ 0x399e0 的比较与条件分支 ════"
awk '/^ *39244:/,/^ *399e0:/' $A > /tmp/seg.txt
wc -l /tmp/seg.txt
grep -nE "cmp|cbz|cbnz|b\.eq|b\.ne|b\.lt|b\.gt|b\.le|b\.ge|b\.hi|b\.ls|^\s+[0-9a-f]+:\s+b\s" /tmp/seg.txt | head -50

echo
echo "════ 该区间调用的外部函数 ════"
grep -oE "bl\s+[0-9a-f]+ <[^>]+>" /tmp/seg.txt | sed 's/.*<//;s/>//' | sort | uniq -c | sort -rn | head -40

echo
echo "════ 该区间读到的字符串地址（adrp+add 组合）════"
grep -oE "adrp\s+x[0-9]+, [0-9a-f]+" /tmp/seg.txt | sort -u | head -30
