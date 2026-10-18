#!/bin/bash
set +e
IMG=/mnt/c/Users/Xuleyu/Documents/work/fn-atk/out/fnnas_ATK-DLRK3568_FnNAS-v4_2026.10.18.img
B=/root/atk-work/atk-build
BOOT_OFF=$((0x4F9226))
ROOT_OFF=$((0x5B8C226))
W=/tmp/vfy6
rm -rf $W; mkdir -p $W/mnt

echo "════ 1. 成品里的 boot 段 vs 构建产物 ════"
echo "  boot 槽位偏移 = $BOOT_OFF (0x$(printf %X $BOOT_OFF))"
dd if="$IMG" of=$W/boot.img bs=1M iflag=skip_bytes,count_bytes \
   skip=$BOOT_OFF count=$(stat -c%s $B/boot-gz.img) status=none
cmp -s $W/boot.img $B/boot-gz.img && echo "  ✔ boot 段与 boot-gz.img 完全一致" || echo "  ✘ boot 段不一致"
sha256sum $W/boot.img $B/boot-gz.img | sed 's/^/    /'
echo "  --- FIT 内容 ---"
dumpimage -l $W/boot.img 2>/dev/null | grep -iE 'Image|Size|Type' | head -12

echo
echo "════ 2. 成品里的 rootfs 段 vs 构建产物 ════"
echo "  rootfs 槽位偏移 = $ROOT_OFF (0x$(printf %X $ROOT_OFF))"
dd if="$IMG" of=$W/rootfs.img bs=1M iflag=skip_bytes,count_bytes \
   skip=$ROOT_OFF count=$(stat -c%s $B/rootfs-ext4.img) status=none
cmp -s $W/rootfs.img $B/rootfs-ext4.img && echo "  ✔ rootfs 段与 rootfs-ext4.img 完全一致" || echo "  ✘ rootfs 段不一致"

echo
echo "════ 3. 挂载 rootfs 检查文件 ════"
mount -o loop,ro $W/rootfs.img $W/mnt && echo "  挂载 OK" || echo "  !! 挂载失败"

check() {
  if [ -e "$W/mnt$1" ]; then
    printf "  ✔ %-56s %8s 字节\n" "$1" "$(stat -c%s "$W/mnt$1")"
  else
    printf "  ✘ %-56s 缺失\n" "$1"
  fi
}
echo "--- 新增：存储卷自愈 + Docker data-root ---"
check /usr/local/sbin/fnnas-vol-mount.sh
check /usr/local/sbin/fnnas-dockerd.sh
check /etc/systemd/system/fnnas-vol-mount.service
check /etc/systemd/system/fnnas-vol-mount.timer
check /etc/systemd/system/docker.service.d/10-fnnas-datadir.conf
check /etc/systemd/system/timers.target.wants/fnnas-vol-mount.timer
echo "--- 回归：原有组件 ---"
check /usr/local/sbin/fnnas-grow-rootfs.sh
check /usr/local/sbin/fnnas-docker-heal.sh
check /usr/local/sbin/fnnas-unfix.sh
check /etc/systemd/system/fnnas-grow-rootfs.service
check /usr/local/sbin/fnnas-compat/zpool
check /usr/local/sbin/fnnas-compat/mdadm
check /usr/local/sbin/fnnas-compat/umount
check /usr/local/sbin/fnnas-compat/smartctl
check /usr/sbin/zpool.real
check /usr/bin/umount.real
check /usr/sbin/smartctl.real
check /usr/bin/dockerd
check /usr/libexec/docker/cli-plugins/docker-compose

echo "--- 兼容层软链 ---"
for l in /usr/sbin/zpool /usr/sbin/zfs /usr/trim/bin/mdadm /usr/bin/umount /usr/sbin/smartctl; do
  t=$(readlink $W/mnt$l 2>/dev/null)
  printf "  %-24s -> %s %s\n" "$l" "${t:-✘ 不是软链}" "$([ -e "$W/mnt$l" ] && echo ✔ || echo ✘)"
done
echo "--- 启用软链 ---"
for e in /etc/systemd/system/multi-user.target.wants/fnnas-vol-mount.service \
         /etc/systemd/system/timers.target.wants/fnnas-vol-mount.timer \
         /etc/systemd/system/multi-user.target.wants/fnnas-grow-rootfs.service \
         /etc/systemd/system/multi-user.target.wants/fnnas-docker-heal.service \
         /etc/systemd/system/resize-rootfs.service; do
  printf "  %-66s %s\n" "$e" "$([ -L "$W/mnt$e" ] && echo "✔ -> $(readlink $W/mnt$e)" || echo ✘)"
done
echo "--- 模块 ---"
echo "  模块数: $(find $W/mnt/lib/modules/6.1.141 -name '*.ko' | wc -l)"

echo
echo "════ 4. 关键内容抽检 ════"
echo "--- fnnas-vol-mount.service（必须没有 RemainAfterExit） ---"
grep -vE '^\s*$' $W/mnt/etc/systemd/system/fnnas-vol-mount.service 2>/dev/null | sed 's/^/    /'
echo "--- docker drop-in ---"
sed 's/^/    /' $W/mnt/etc/systemd/system/docker.service.d/10-fnnas-datadir.conf 2>/dev/null
echo "--- 挂载 SQL ---"
grep -o 'select id.*order by id' $W/mnt/usr/local/sbin/fnnas-vol-mount.sh 2>/dev/null | sed 's/^/    /'
echo "--- fstab ---"
grep -vE '^\s*$|^\s*#' $W/mnt/etc/fstab 2>/dev/null | sed 's/^/    /'
echo "--- umount shim 无参保护 ---"
head -20 $W/mnt/usr/local/sbin/fnnas-compat/umount 2>/dev/null | grep -nE '\-eq 0|exit 0' | sed 's/^/    /'
echo "--- 存储卷自愈脚本：设备别名 + 只在变更时重启 ---"
grep -cE 'mknod "/\$UUID"' $W/mnt/usr/local/sbin/fnnas-vol-mount.sh | sed 's/^/    mknod 别名节点 出现次数: /'
grep -cE 'RemainAfterExit' $W/mnt/etc/systemd/system/fnnas-vol-mount.service | sed 's/^/    RemainAfterExit(应为0): /'
grep -nE 'try-restart trim_main' $W/mnt/usr/local/sbin/fnnas-vol-mount.sh | sed 's/^/    /'
echo "--- docker 包装器 ---"
grep -c 'data-root' $W/mnt/usr/local/sbin/fnnas-dockerd.sh | sed 's/^/    data-root 处理行数: /'

echo
echo "════ 5. ext4 特性 ════"
dumpe2fs -h $W/rootfs.img 2>/dev/null | grep -E 'Filesystem features|Inode size|Block size|Filesystem state' | sed 's/^/  /'

sync; umount $W/mnt 2>/dev/null

echo
echo "════ 6. 成品指纹 ════"
ls -la "$IMG"
md5sum "$IMG"
echo "  基线 DTB     sha256=264c6fd11c437d982f93eeba5277b99febccdc70cbf3879c51d4aae67a9736e1"
echo "  基线 resource sha256=13866fed740e34f204ee95c5b029d8d7a557eafe48550dab2dab6aa7b2c3c641"
echo "════ DONE-VFY6 ════"
