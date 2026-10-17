#!/bin/bash
L=/root/fnnas-re/lib
echo "=== libndev.so 基本信息 ==="
ls -l $L/libndev.so* 2>&1
file $L/libndev.so 2>&1
echo
echo "=== 它的符号表里含 disk 的条目 ==="
aarch64-linux-gnu-nm -D $L/libndev.so 2>&1 | grep -iE "disk|partno|free_space" | head -30
echo
echo "=== 静态符号表 ==="
aarch64-linux-gnu-nm $L/libndev.so 2>&1 | grep -iE "disk|partno|free_space" | head -40
echo
echo "=== strings 里相关关键词 ==="
strings $L/libndev.so | grep -iE "sys_disk|free_space_partno|diskmapper|partprefix|external_disk" | head -20
echo
echo "=== 目录里所有文件 ==="
ls $L | head -70
