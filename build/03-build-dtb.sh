#!/bin/bash
# 定位并重新编译 rk3568-alientek-panfrost-hdmi.dtb
K=/root/atk-work/atk_dlrk3568_linux6.1/kernel-6.1
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
cd "$K"

echo "════ 1. 全盘找同名 dtb / dts ════"
find /root/atk-work -name 'rk3568-alientek-panfrost-hdmi.*' 2>/dev/null | sed 's/^/  /'
echo "  --- alientek 相关 dts ---"
find arch/arm64/boot/dts -name '*alientek*' 2>/dev/null | sed 's/^/  /'

echo
echo "════ 2. 编译 dtbs ════"
make dtbs -j"$(nproc)" 2>&1 | tail -5

echo
echo "════ 3. 查找产物 ════"
DT=$(find arch/arm64/boot/dts -name 'rk3568-alientek-panfrost-hdmi.dtb' | head -1)
echo "  找到: ${DT:-没有}"
if [ -z "$DT" ]; then
  echo "  --- arch/arm64/boot/dts/rockchip 下所有 alientek/panfrost 产物 ---"
  ls arch/arm64/boot/dts/rockchip/ 2>/dev/null | grep -iE 'alientek|panfrost' | sed 's/^/    /'
  exit 1
fi

echo
echo "════ 4. 校验哈希（应与厂商启动日志一致 264c6fd11c437d982f93eeba5277b99febccdc70cbf3879c51d4aae67a9736e1）════"
sha256sum "$DT" | sed 's/^/  /'
echo "  大小: $(stat -c%s "$DT") 字节 (厂商 175.33 KiB)"
