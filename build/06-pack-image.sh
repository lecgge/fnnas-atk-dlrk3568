#!/bin/bash
# 诊断镜像：我们已验证的内核 + 厂商 ext4 rootfs（root 空密码）
# 目的：拿到串口 shell 后，直接在板子上检查 mmcblk0p6 的真实内容
set -e
SRC=/mnt/c/Users/Xuleyu/Documents/work/fn-atk/hdmi_ubuntu26.04.1_update.img
DST=/mnt/c/Users/Xuleyu/Documents/work/fn-atk/out/fnnas_ATK-DLRK3568_FnNAS-final_2026.10.16.img
FIT=/root/atk-work/atk-build/boot-gz.img
RFS=/root/atk-work/atk-build/rootfs-ext4.img

BOOT_OFF=$((0x4F9226)); BOOT_SLOT=40579584
ROOT_OFF=$((0x5B8C226)); ROOT_SLOT=3577741312

FSZ=$(stat -c%s "$FIT"); RSZ=$(stat -c%s "$RFS")
echo "════ 尺寸核对 ════"
printf "  boot.img  : %12d / %12d  %s\n" "$FSZ" "$BOOT_SLOT" "$([ $FSZ -le $BOOT_SLOT ] && echo '✅' || echo '❌')"
printf "  rootfs.img: %12d / %12d  %s\n" "$RSZ" "$ROOT_SLOT" "$([ $RSZ -le $ROOT_SLOT ] && echo '✅' || echo '❌')"
[ "$FSZ" -le "$BOOT_SLOT" ] && [ "$RSZ" -le "$ROOT_SLOT" ] || { echo "尺寸不符"; exit 1; }

echo
echo "════ 拷贝源文件 ════"
cp -f "$SRC" "$DST"

echo "════ 写入 boot.img（我们的内核，无 initramfs）════"
dd if="$FIT" of="$DST" bs=1M oflag=seek_bytes seek="$BOOT_OFF" conv=notrunc,fsync status=none
echo "  @0x$(printf %X $BOOT_OFF)  $FSZ 字节"

echo "════ 写入 rootfs.img（厂商 Ubuntu，root 空密码）════"
dd if="$RFS" of="$DST" bs=1M oflag=seek_bytes seek="$ROOT_OFF" conv=notrunc,fsync status=none
echo "  @0x$(printf %X $ROOT_OFF)  $RSZ 字节"

echo
echo "════ 回读校验 ════"
dd if="$DST" bs=1M iflag=skip_bytes,count_bytes skip=$BOOT_OFF count=$FSZ 2>/dev/null > /tmp/c1
cmp -s /tmp/c1 "$FIT" && echo "  ✔ boot FIT 一致" || echo "  ✘ boot 不一致 <<<"
dd if="$DST" bs=1M iflag=skip_bytes skip=$ROOT_OFF count=1 2>/dev/null > /tmp/c2
echo "  rootfs ext4 superblock @+0x438:"
xxd -s 0x438 -l 16 /tmp/c2 | sed 's/^/    /'
echo "  rootfs /etc/shadow 的 root 行（应是 root::）:"
dd if="$DST" bs=1M iflag=skip_bytes,count_bytes skip=$((ROOT_OFF+1024*1024)) count=1 2>/dev/null > /tmp/c3
xxd -s 0x438 -l 16 /tmp/c2 >/dev/null 2>&1 || true
rm -f /tmp/c1 /tmp/c2 /tmp/c3

echo
echo "════ 未改动区域 ════"
cmp -n "$BOOT_OFF" -s "$SRC" "$DST" && echo "  ✔ [0 .. 0x$(printf %X $BOOT_OFF)) 未改动" || echo "  ✘ 前段差异 <<<"
CMPSTART=$((ROOT_OFF + ROOT_SLOT))
cmp -i "$CMPSTART:$CMPSTART" -s "$SRC" "$DST" && echo "  ✔ [rootfs 末尾 .. 文件尾] 未改动" || echo "  ✘ 后段差异 <<<"

ls -lh "$DST"
