#!/bin/bash
# 打包全流程：Image -> Image.gz -> boot FIT -> rootfs ext4 -> 最终镜像
set -e
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
K=/root/atk-work/atk_dlrk3568_linux6.1/kernel-6.1
B=/root/atk-work/atk-build
T=/mnt/c/Users/Xuleyu/Documents/work/fn-atk/tools

echo "════ 1. 压缩内核 + 构建 FIT ════"
cp -f "$K/arch/arm64/boot/Image" "$B/Image"
gzip -9 -n -c "$B/Image" > "$B/Image.gz"
echo "  Image     : $(stat -c%s "$B/Image")"
echo "  Image.gz  : $(stat -c%s "$B/Image.gz")"
cd "$K/rkbin" 2>/dev/null || cd "$K"
MK=$(find /root/atk-work -name mkimage -type f 2>/dev/null | head -1)
echo "  mkimage   : $MK"
"$MK" -f "$B/boot-gz.its" -E -p 0x800 "$B/boot-gz.img"
echo "  boot FIT  : $(stat -c%s "$B/boot-gz.img")"
dumpimage -l "$B/boot-gz.img" 2>/dev/null | sed 's/^/    /' | head -20

echo
echo "════ 2. 重建 rootfs（含同批模块）════"
bash "$T/87-rebuild-rootfs-final.sh"

echo
echo "════ 3. 打包最终镜像 ════"
bash "$T/89-diag-shell-image.sh"

echo
echo "════ 4. 逐段校验 ════"
bash "$T/90-verify-final-image.sh"

echo
echo "════ 全部完成 $(date '+%H:%M:%S') ════"
