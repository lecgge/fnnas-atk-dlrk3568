#!/bin/bash
# 从上一版可用配置出发，最小化合并 DM/MD 片段，并验证没有丢掉任何既有能力
set -e
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
K=/root/atk-work/atk_dlrk3568_linux6.1/kernel-6.1
cd "$K"

echo "════ 0. 备份上一版可用配置 ════"
cp .config /root/cfg-prev-good.config
grep -E "^CONFIG_(OPENVSWITCH|BTRFS_FS|OVERLAY_FS|BLK_DEV_DM|BLK_DEV_MD)" .config | sed 's/^/  原有: /'

echo
echo "════ 1. 只合并 DM/MD 片段 ════"
scripts/kconfig/merge_config.sh -m -O . .config \
  /root/atk-work/atk_dlrk3568_linux6.1/device/rockchip/.chips/rk3566_rk3568/dm-md-only.config \
  >/dev/null 2>&1 || true

# 片段若不存在，就从 fnnas.config 里抽出 DM/MD 段生成
FRAG=/root/atk-work/atk_dlrk3568_linux6.1/device/rockchip/.chips/rk3566_rk3568/dm-md-only.config
if [ ! -f "$FRAG" ]; then
  grep -E '^CONFIG_(BLK_DEV_DM|DM_|BLK_DEV_MD|MD_)' \
    /root/atk-work/atk_dlrk3568_linux6.1/device/rockchip/.chips/rk3566_rk3568/fnnas.config > "$FRAG"
  echo "  已从 fnnas.config 抽取 DM/MD 段"
fi
cat "$FRAG" | sed 's/^/  /'

scripts/kconfig/merge_config.sh -m -O . .config "$FRAG" >/dev/null 2>&1
make olddefconfig >/dev/null 2>&1
cp .config /root/cfg-dm-md.config
echo "  合并 + olddefconfig 完成"

echo
echo "════ 2. DM / MD 是否真的生效（kconfig 会静默丢弃不合法符号）════"
for s in BLK_DEV_DM DM_BUFIO DM_BIO_PRISON DM_SNAPSHOT DM_THIN_PROVISIONING DM_CRYPT \
         BLK_DEV_MD MD_LINEAR MD_RAID0 MD_RAID1 MD_RAID10 BLK_DEV_LOOP; do
  if grep -q "^CONFIG_$s=" .config; then
    printf "  ✔ CONFIG_%-26s = %s\n" "$s" "$(grep "^CONFIG_$s=" .config | cut -d= -f2)"
  else
    printf "  ✘ CONFIG_%-26s 未生效 <<<\n" "$s"
  fi
done

echo
echo "════ 3. 既有能力是否保住（与上一版逐项 diff，只看非 DM/MD 差异）════"
DIFF=$(diff <(grep -E "^CONFIG_|^# CONFIG_" /root/cfg-prev-good.config | sort) \
            <(grep -E "^CONFIG_|^# CONFIG_" /root/cfg-dm-md.config | sort) \
       | grep -viE "DM_|BLK_DEV_MD|^MD_|^[0-9]|^---$" || true)
if [ -z "$DIFF" ]; then
  echo "  ✔ 除 DM/MD 外，没有任何配置变化"
else
  echo "  ⚠ 以下非 DM/MD 差异需确认："
  echo "$DIFF" | sed 's/^/    /'
fi

echo
echo "════ 4. 关键能力抽查 ════"
for s in OPENVSWITCH OPENVSWITCH_COMPAT BTRFS_FS BTRFS_FS_ZSTD OVERLAY_FS CRYPTO \
         DRM_ROCKCHIP NVME_CORE SND_ROCKCHIP_SOC MMC_DW_ROCKCHIP STMMAC_DRM_ROCKCHIP \
         PANFROST ARM_GIC_V3_ITS USB_DWC3 USB_STORAGE SCSI_DOS_PARTITION \
         NFS_FS CIFS NFSD CGROUPS BRIDGE; do
  if grep -q "^CONFIG_$s=" .config; then printf "  ✔ %-26s = %s\n" "$s" "$(grep "^CONFIG_$s=" .config | cut -d= -f2)";
  else printf "  ✘ %-26s 丢失 <<<\n" "$s"; fi
done
