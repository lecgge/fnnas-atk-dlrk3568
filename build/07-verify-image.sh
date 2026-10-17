#!/bin/bash
# 最终成品镜像独立校验（dd 抽取法，避开 cmp -i 的大文件/seek 语义坑）
IMG=/mnt/c/Users/Xuleyu/Documents/work/fn-atk/out/fnnas_ATK-DLRK3568_FnNAS-final_2026.10.16.img
FIT=/root/atk-work/atk-build/boot-gz.img
RFS=/root/atk-work/atk-build/rootfs-ext4.img
BOOT_OFF=$((0x4F9226)); ROOT_OFF=$((0x5B8C226))
ROOT_SLOT=3577741312
FSZ=$(stat -c%s "$FIT"); RSZ=$(stat -c%s "$RFS")
IMGSZ=$(stat -c%s "$IMG")

echo "════ 尺寸 ════"
printf "  成品     : %d\n  boot FIT: %d\n  rootfs   : %d\n" "$IMGSZ" "$FSZ" "$RSZ"

echo "════ 1. 成品 boot 段抽取比对 ════"
dd if="$IMG" of=/tmp/v_boot bs=1M iflag=skip_bytes,count_bytes \
   skip=$BOOT_OFF count=$FSZ status=none
cmp -s /tmp/v_boot "$FIT" && echo "  ✔ boot 段一致" || echo "  ✘ boot 段不一致 <<<"

echo "════ 2. 成品 rootfs 段前 64MB 抽取比对 ════"
dd if="$IMG" of=/tmp/v_rfs_head bs=1M iflag=skip_bytes,count_bytes \
   skip=$ROOT_OFF count=$((64*1024*1024)) status=none
dd if="$RFS" of=/tmp/r_rfs_head bs=1M count=64 status=none
cmp -s /tmp/v_rfs_head /tmp/r_rfs_head && echo "  ✔ rootfs 头部 64MB 一致" || echo "  ✘ rootfs 头部不一致 <<<"

echo "════ 3. 成品 rootfs 段末尾 64MB 抽取比对 ════"
dd if="$IMG" of=/tmp/v_rfs_tail bs=1M iflag=skip_bytes,count_bytes \
   skip=$((ROOT_OFF + RSZ - 64*1024*1024)) count=$((64*1024*1024)) status=none
dd if="$RFS" of=/tmp/r_rfs_tail bs=1M iflag=skip_bytes,count_bytes \
   skip=$((RSZ - 64*1024*1024)) count=$((64*1024*1024)) status=none
cmp -s /tmp/v_rfs_tail /tmp/r_rfs_tail && echo "  ✔ rootfs 尾部 64MB 一致" || echo "  ✘ rootfs 尾部不一致 <<<"

echo "════ 4. 成品里的 ext4 超级块（应显示 has_journal）════"
dd if="$IMG" of=/tmp/v_sb bs=1M iflag=skip_bytes,count_bytes \
   skip=$ROOT_OFF count=2 status=none
e2fsck -fn /tmp/v_sb 2>&1 | grep -iE 'has_journal|Filesystem features' | sed 's/^/  /'
tune2fs -l /tmp/v_sb 2>/dev/null | grep -i 'journal' | sed 's/^/  /' || echo "  (超级块位于 part 内，tune2fs 不适用)"

echo "════ 5. RKAF 头尾指纹 ════"
echo -n "  head : "; head -c 4 "$IMG" | xxd -p
echo -n "  tail : "; tail -c 4  "$IMG" | xxd -p
rm -f /tmp/v_boot /tmp/v_rfs_head /tmp/r_rfs_head /tmp/v_rfs_tail /tmp/r_rfs_tail /tmp/v_sb
echo "════ 完成 ════"
