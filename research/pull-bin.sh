#!/bin/bash
# 把 storage.hdl 拉到 WSL，用交叉工具链反汇编 listFreeDisk
set -e
K=/root/.ssh/fnnas_ed25519
NAS() { ssh -i $K -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/known_hosts \
        -o ConnectTimeout=10 xuleyu@192.168.100.131 "$@"; }

mkdir -p /root/fnnas-re
echo "════ 拉取二进制 ════"
NAS 'sudo cat /usr/trim/bin/handlers/storage.hdl' > /root/fnnas-re/storage.hdl
NAS 'sudo cat /usr/trim/bin/handlers/device_watch.hdl' > /root/fnnas-re/device_watch.hdl
NAS 'sudo cat /usr/trim/bin/handlers/appcgi.hdl'   > /root/fnnas-re/appcgi.hdl
ls -l /root/fnnas-re/
file /root/fnnas-re/storage.hdl

OBJDUMP=$(command -v aarch64-linux-gnu-objdump)
NM=$(command -v aarch64-linux-gnu-nm)
echo "objdump: $OBJDUMP"
echo "nm     : $NM"

echo
echo "════ listFreeDisk 相关符号 ════"
$NM -C -D /root/fnnas-re/storage.hdl 2>/dev/null | grep -iE "freedisk|listsdisk|listsstor|getsyspart" | head -20
echo "--- 全部导出符号里含 Disk 的 ---"
$NM -C -D /root/fnnas-re/storage.hdl 2>/dev/null | grep -i disk | head -30
