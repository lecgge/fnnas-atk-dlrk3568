#!/bin/bash
# 分段 md5 比对，快速确认差异只落在预期区域
SRC=/mnt/c/Users/Xuleyu/Documents/work/fn-atk/hdmi_ubuntu26.04.1_update.img
DST=/mnt/c/Users/Xuleyu/Documents/work/fn-atk/out/fnnas_ATK-DLRK3568_FnNAS-final_2026.10.16.img
md5range() { dd if="$1" bs=1M iflag=skip_bytes,count_bytes skip="$2" count="$3" status=none | md5sum | cut -d' ' -f1; }

BOOT_OFF=$((0x4F9226)); FSZ=18189312
ROOT_OFF=$((0x5B8C226)); RSZ=3577741312
SLOT_LO=$((0x76A26)); SLOT_HI=$((SLOT_LO + 8 + 492))

check() {
  local name=$1 lo=$2 len=$3 expect=$4
  local a b
  a=$(md5range "$SRC" $lo $len); b=$(md5range "$DST" $lo $len)
  if [ "$a" = "$b" ]; then r="相同"; else r="不同"; fi
  printf "  %-28s [0x%08X, +%-12d)  %s\n" "$name" "$lo" "$len" "$r"
  if [ "$expect" = "same" ] && [ "$r" != "相同" ]; then echo "    ✘ 预期相同却不同 <<<"; FAILED=1; fi
  if [ "$expect" = "diff" ] && [ "$r" != "不同" ]; then echo "    ✘ 预期不同却相同 <<<"; FAILED=1; fi
}

FAILED=0
echo "════ 分段比对（预期：仅 parameter/boot/rootfs 三段不同）════"
check "RKAF 头 + 引导区"   0                 $SLOT_LO          same
check "parameter.txt 槽位" $SLOT_LO          $((SLOT_HI-SLOT_LO)) diff
check "槽位后到 boot.img"  $SLOT_HI          $((BOOT_OFF-SLOT_HI)) same
check "boot.img"           $BOOT_OFF         $FSZ              diff
check "boot 后到 rootfs"   $((BOOT_OFF+FSZ)) $((ROOT_OFF-BOOT_OFF-FSZ)) same
check "rootfs.img"         $ROOT_OFF         $RSZ              diff
check "rootfs 后到文件尾"  $((ROOT_OFF+RSZ)) 1048576           same

echo
echo "════ parameter.txt 最终内容 ════"
dd if="$DST" bs=1 skip=$((SLOT_LO+8)) count=492 status=none | tr -d '\000'
echo
echo
[ $FAILED -eq 0 ] && echo "结论: ✔ 差异完全落在预期区域内" || echo "结论: ✘ 有预期外差异"
