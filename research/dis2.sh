#!/bin/bash
L=/root/fnnas-re/lib/libndev.so
OD=aarch64-linux-gnu-objdump

echo "════════ is_dev_disk @ 0xad60 ════════"
$OD -d --start-address=0xad60 --stop-address=0xae80 -C $L | sed -n '6,200p'

echo
echo "════════ is_dev_diskmapper @ 0xb6b0 ════════"
$OD -d --start-address=0xb6b0 --stop-address=0xb800 -C $L | sed -n '6,200p'

echo
echo "════════ 相关字符串 ════════"
strings -t x $L | grep -iE "sys/block|/dev/|dm-|md|mdadm|partprefix" | head -40
