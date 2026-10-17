#!/bin/bash
set -e
B=/root/atk-work/atk-build
K=/root/atk-work/atk_dlrk3568_linux6.1/kernel-6.1
DUMP=/root/atk-work/atk_dlrk3568_linux6.1/u-boot/tools/dumpimage
cd /tmp

echo "════ 正确语法: -i <image> ════"
rm -f /tmp/res.img
"$DUMP" -i "$B/boot-gz.img" -T flat_dt -p 2 -o /tmp/res.img
ls -l /tmp/res.img
echo "  期望 1142272 字节"
echo "  sha256: $(sha256sum /tmp/res.img | cut -d' ' -f1)"
echo "  FIT 中记录: 13866fed740e34f204ee95c5b029d8d7a557eafe48550dab2dab6aa7b2c3c641"

echo
echo "════ 校验 sha256 是否一致 ════"
GOT=$(sha256sum /tmp/res.img | cut -d' ' -f1)
WANT=13866fed740e34f204ee95c5b029d8d7a557eafe48550dab2dab6aa7b2c3c641
[ "$GOT" = "$WANT" ] && echo "  ✔ 完全一致" || echo "  ✘ 不一致 <<<"

echo
echo "════ 头部结构 ════"
xxd -l 32 /tmp/res.img | sed 's/^/  /'

echo
echo "════ 装到 kernel-6.1/ 下 ════"
cp -f /tmp/res.img "$K/resource.img"
cp -f /tmp/res.img "$B/resource.img"
ls -l "$K/resource.img" "$B/resource.img"
