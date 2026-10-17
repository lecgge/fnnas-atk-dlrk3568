#!/bin/bash
# 符号名核对 + 全量重编（DM/MD 版）
set -e
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
K=/root/atk-work/atk_dlrk3568_linux6.1/kernel-6.1
cd "$K"

echo "════ A. 第4步那几个符号在 6.1 里的真实名字 ════"
for pat in OPENVSWITCH BTRFS SND_SOC_ROCKCHIP STMMAC DRM_PANFROST MALI DOS_PART; do
  echo "  --- $pat ---"
  grep -E "^CONFIG_[A-Z_0-9]*${pat}[A-Z_0-9]*=" .config | head -4 | sed 's/^/      /'
done

echo
echo "════ B. 对比上一版：确认这些符号本来就存在且未变 ════"
for s in BTRFS_FS_ZSTD OPENVSWITCH_COMPAT SND_SOC_ROCKCHIP STMMAC_DRM_ROCKCHIP DRM_PANFROST PANFROST SCSI_DOS_PARTITION; do
  a=$(grep -E "^CONFIG_${s}=" /root/cfg-prev-good.config || echo "(原配置就没有)")
  b=$(grep -E "^CONFIG_${s}=" .config || echo "(本次也没有)")
  printf "  %-24s 上一版:%-28s 本次:%s\n" "$s" "$(echo "$a" | cut -d= -f2-)" "$(echo "$b" | cut -d= -f2-)"
done

echo
echo "════ C. make clean ════"
cp .config /root/cfg-final-dm-md.config
make clean >/dev/null 2>&1
echo "  已清理，开始全量编译 $(date '+%H:%M:%S')"

echo
echo "════ D. 编译 Image ════"
make Image -j"$(nproc)" KCFLAGS=-Wno-error 2>&1 | tail -4
echo "  完成 $(date '+%H:%M:%S')"

echo
echo "════ E. 编译 modules ════"
make modules -j"$(nproc)" KCFLAGS=-Wno-error 2>&1 | tail -4
echo "  完成 $(date '+%H:%M:%S')"

echo
echo "════ F. 产物核对 ════"
ls -l arch/arm64/boot/Image
strings arch/arm64/boot/Image | grep -m1 "Linux version"
echo "  OVS 符号数  : $(strings arch/arm64/boot/Image | grep -c -iE 'openvswitch|ovs_')"
echo "  DM 符号数   : $(strings arch/arm64/boot/Image | grep -c -E 'device-mapper|dm_table|dm_get_device')"
echo "  MD 符号数   : $(strings arch/arm64/boot/Image | grep -c -E 'md_raid1|md_linear|md_run')"
echo "  BTRFS 符号数: $(strings arch/arm64/boot/Image | grep -c -iE 'btrfs_')"
echo "  模块总数    : $(find . -name '*.ko' | wc -l)"
find . -name '*8852*.ko' -o -name 'openvswitch.ko' | sed 's/^/  /'
echo "  dm-mod.ko   : $(find . -name 'dm-mod.ko' | head -1)"
echo "  dm-crypt.ko : $(find . -name 'dm-crypt.ko' | head -1)"
