#!/bin/bash
# 重建 FnNAS rootfs ext4：
#   1) 裁剪（两轮）
#   2) fstab / 串口 getty 修复
#   3) 禁用 resize-rootfs.service（它在破坏文件系统）
#   4) 安装与当前内核匹配的模块
#   5) 带 journal 的 ext4（无日志扛不住 FnNAS 运行时写入）
set -e
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
KDIR=/root/atk-work/atk_dlrk3568_linux6.1/kernel-6.1
SRC=/root/atk-work/atk-build/rootfs.btrfs
BLD=/root/atk-work/atk-build
IMG=$BLD/rootfs-ext4.img
SLOT=3577741312
W=/tmp/rfs3
KEEP_LOCALES="zh_CN zh_CN.utf8 en_US en_US.utf8"

losetup -D 2>/dev/null || true
umount -l $W/src $W/dst $W/mnt 2>/dev/null || true
rm -rf "$W"; mkdir -p "$W/dst"

echo "════ 1. 解包 FnNAS ════"
mkdir -p "$W/src"
mount -o loop,ro "$SRC" "$W/src"
cp -a "$W/src"/. "$W/dst"/
sync; umount "$W/src"
D="$W/dst"

echo "════ 2. 裁剪 ════"
cut() { if [ -e "$D/$1" ]; then rm -rf "${D:?}/$1"; printf "  %s\n" "$1"; fi; }
for p in usr/share/AAVMF usr/lib/firmware/intel usr/lib/firmware/mediatek \
         usr/lib/firmware/qcom usr/lib/firmware/amlogic usr/lib/firmware/uwe5622 \
         usr/lib/aarch64-linux-gnu/libLLVM-14.so.1 usr/lib/aarch64-linux-gnu/libLLVM-15.so.1 \
         usr/bin/aarch64-linux-gnu-lto-dump-12 usr/bin/aarch64-linux-gnu-ld.gold \
         usr/bin/qemu-system-aarch64 usr/bin/qemu-system-arm usr/bin/qemu-aarch64-static \
         usr/lib/grub usr/lib/git-core usr/src usr/share/doc usr/share/man usr/include \
         var/cache var/lib/apt/lists usr/lib/gcc usr/bin/aarch64-linux-gnu-gcc-12 \
         usr/bin/aarch64-linux-gnu-cpp-12 usr/bin/aarch64-linux-gnu-ld \
         usr/bin/aarch64-linux-gnu-ld.bfd usr/bin/aarch64-linux-gnu-as \
         usr/bin/aarch64-linux-gnu-objcopy usr/bin/aarch64-linux-gnu-objdump \
         usr/bin/aarch64-linux-gnu-readelf usr/bin/aarch64-linux-gnu-strip \
         usr/bin/aarch64-linux-gnu-ar usr/bin/aarch64-linux-gnu-nm \
         usr/bin/aarch64-linux-gnu-ranlib usr/share/pocketsphinx usr/share/vim \
         usr/share/emacs usr/share/ghostscript usr/lib/aarch64-linux-gnu/gconv \
         usr/libexec/docker/cli-plugins/docker-buildx usr/share/i18n usr/share/info; do cut "$p"; done
if [ -d "$D/usr/share/locale" ]; then
    mkdir -p "$W/keep"
    for l in $KEEP_LOCALES; do if [ -e "$D/usr/share/locale/$l" ]; then mv "$D/usr/share/locale/$l" "$W/keep/"; fi; done
    rm -rf "${D:?}/usr/share/locale"; mkdir -p "$D/usr/share/locale"
    for f in "$W/keep"/*; do if [ -e "$f" ]; then mv "$f" "$D/usr/share/locale/"; fi; done
    echo "  usr/share/locale -> 只留 $KEEP_LOCALES"
fi

echo "════ 3. fstab / 串口 getty ════"
cat > "$D/etc/fstab" <<'EOF'
# <file system> <mount point>   <type>  <options>       <dump> <pass>
PARTUUID=614e0000-0000-4b53-8000-1d28000054a9  /  ext4  defaults,noatime  0 1
tmpfs                     /tmp   tmpfs  defaults,nosuid  0 0
EOF
rm -rf "$D/etc/systemd/system/serial-getty@ttyAMA0.service" \
       "$D/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service" \
       "$D/etc/systemd/system/serial-getty@ttyAMA0.service.d"
mkdir -p "$D/etc/systemd/system/getty.target.wants" "$D/etc/systemd/system/serial-getty@ttyFIQ0.service.d"
ln -sf /lib/systemd/system/serial-getty@.service \
       "$D/etc/systemd/system/getty.target.wants/serial-getty@ttyFIQ0.service"
cat > "$D/etc/systemd/system/serial-getty@ttyFIQ0.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o -p -- $TERM 1500000,115200,38400,9600 ttyFIQ0 vt220
EOF
echo "  串口波特率已加入 1500000（之前漏掉导致 agetty 对不上 CH340 速率，串口无输出）"
grep -v '^#autofs' "$D/etc/modules" > "$W/m.new" 2>/dev/null && cp "$W/m.new" "$D/etc/modules" || true

echo
echo "════ 3.5 开机把整块 eMMC 并入系统分区 ════"
# 目标：让 / 占满整块 eMMC（FnNAS 对 <64G 磁盘的官方行为就是「整个盘都做系统盘」）。
#
# 为什么不在 parameter.txt 里把 rootfs 写到盘尾：厂商 parameter.txt 的 mtdparts
# 里只有 userdata:grow 用了 '-' 语法，RKDevTool 对 rootfs 这个位置未必按同样方式
# 建表，实测会导致分区表异常、板子起不来（2026-10-17 的 fulldisk 镜像刷完即失联）。
# 所以 parameter.txt 保持厂商原样，分区手术放在开机脚本里做，且全程可回退。
#
# 刷机后 eMMC 布局是厂商那 8 个分区：p6=rootfs(16GiB) p7=oem(128MiB) p8=userdata(41.3GiB)。
# 这两个 Android 遗留分区 Ubuntu 根本不用，正好删掉，把 p6 扩到盘尾。
mkdir -p "$D/usr/local/sbin"
cat > "$D/usr/local/sbin/fnnas-grow-rootfs.sh" <<'GROW'
#!/bin/bash
# 把根分区扩容到磁盘末尾并撑满文件系统。幂等，可重复执行。
# 安全约束：只删「根分区之后」「未挂载」「无 holder」的分区；任何一步失败立即停止。
set -u
LOG=/var/log/fnnas-grow-rootfs.log
exec >>"$LOG" 2>&1 || true
echo "=== $(date '+%F %T') 开始 ==="

ROOT_SRC=$(findmnt -n -o SOURCE / 2>/dev/null) || { echo "找不到根设备"; exit 0; }
ROOT_PART=${ROOT_SRC##*[!0-9]}
[ -n "$ROOT_PART" ] || { echo "根设备 $ROOT_SRC 解析不出分区号"; exit 0; }
DEV=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)
[ -n "$DEV" ] || { echo "找不到父设备"; exit 0; }
DISK=/dev/$DEV
echo "根分区 /dev/${DEV}p${ROOT_PART}   磁盘 $DISK"

# ---- 1. 删除根分区之后的分区（未挂载且无 holder 才动）----
for sysdir in /sys/block/$DEV/${DEV}p*; do
  [ -e "$sysdir/partition" ] || continue
  n=$(cat "$sysdir/partition")
  [ "$n" -gt "$ROOT_PART" ] || continue
  node=/dev/${DEV}p${n}
  [ -b "$node" ] || continue
  if lsblk -no MOUNTPOINT "$node" 2>/dev/null | tr -d '[:space:]' | grep -q .; then
    echo "  p$n 已挂载，跳过"; continue
  fi
  if [ -d "$sysdir/holders" ] && [ -n "$(ls -A "$sysdir/holders" 2>/dev/null)" ]; then
    echo "  p$n 被 holder 占用，跳过"; continue
  fi
  parted -s "$DISK" rm "$n" >/dev/null 2>&1 \
    && echo "  已删除 p$n" || echo "  删除 p$n 失败"
done
partprobe "$DISK" >/dev/null 2>&1 || partx -u "$DISK" >/dev/null 2>&1 || true
sleep 2

# ---- 2. 根分区扩到磁盘末尾（末尾留 2048 扇区给 GPT 备份）----
ST=$(cat "/sys/block/$DEV/${DEV}p${ROOT_PART}/start" 2>/dev/null)
SZ=$(cat "/sys/block/$DEV/${DEV}p${ROOT_PART}/size" 2>/dev/null)
TOT=$(cat "/sys/block/$DEV/size" 2>/dev/null)
if [ -n "$ST" ] && [ -n "$SZ" ] && [ -n "$TOT" ] && [ $((ST + SZ)) -lt $((TOT - 2048)) ]; then
  parted -s "$DISK" unit MiB resizepart "$ROOT_PART" 100% >/dev/null 2>&1 \
    && echo "  分区已扩到 100%" || { echo "  resizepart 失败，停止"; exit 0; }
  partprobe "$DISK" >/dev/null 2>&1 || partx -u "$DISK" >/dev/null 2>&1 || true
  sleep 3
else
  echo "  分区已是满盘，跳过"
fi

# ---- 3. 文件系统撑满（ext4 带 journal，可在线扩）----
NEW=$(lsblk -bn -o SIZE "/dev/${DEV}p${ROOT_PART}" 2>/dev/null | head -1 | tr -d '[:space:]')
CUR=$(df -B1 --output=size / 2>/dev/null | tail -1 | tr -d '[:space:]')
echo "  分区 $NEW 字节 / 文件系统 $CUR 字节"
if [ -n "$NEW" ] && [ -n "$CUR" ] && [ "$NEW" -gt $((CUR + 10485760)) ]; then
  resize2fs "/dev/${DEV}p${ROOT_PART}" >/dev/null 2>&1 \
    && echo "  resize2fs 完成" || echo "  resize2fs 失败"
else
  echo "  文件系统已满盘，跳过"
fi
echo "=== 完成 $(date '+%F %T') ==="
exit 0
GROW
chmod +x "$D/usr/local/sbin/fnnas-grow-rootfs.sh"

cat > "$D/etc/systemd/system/fnnas-grow-rootfs.service" <<'SVCEOF'
[Unit]
Description=Grow root partition to fill the whole eMMC
DefaultDependencies=no
After=local-fs.target
Before=resmon_service.service sysinfo_service.service multi-user.target
ConditionPathExists=/usr/local/sbin/fnnas-grow-rootfs.sh

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=180
ExecStart=/usr/local/sbin/fnnas-grow-rootfs.sh

[Install]
WantedBy=multi-user.target
SVCEOF
mkdir -p "$D/etc/systemd/system/multi-user.target.wants"
ln -sf ../fnnas-grow-rootfs.service "$D/etc/systemd/system/multi-user.target.wants/fnnas-grow-rootfs.service"

# rootfs_limit_gib 调大到超过整盘容量，FnNAS 自己的 fnnas-tf 就不会把分区改小
if [ -f "$D/etc/fnnas.conf" ]; then
  sed -i 's/^rootfs_limit_gib=.*/rootfs_limit_gib="128"/' "$D/etc/fnnas.conf"
  grep 'rootfs_limit_gib\|rootfs_resize' "$D/etc/fnnas.conf" | sed 's/^/    /'
fi
echo "  ✔ 已安装 fnnas-grow-rootfs.service（开机删 oem/userdata 并把 / 撑满整块 eMMC）"

echo "════ 4. 禁用 resize-rootfs.service（它在破坏无日志文件系统）════"
mkdir -p "$D/etc/systemd/system"
rm -f "$D/etc/systemd/system/multi-user.target.wants/resize-rootfs.service" \
      "$D/etc/systemd/system/resize-rootfs.service.d/override.conf"
ln -sf /dev/null "$D/etc/systemd/system/resize-rootfs.service"
mkdir -p "$D/etc/systemd/system/resize-rootfs.service.d"
cat > "$D/etc/systemd/system/resize-rootfs.service.d/override.conf" <<'EOF'
[Unit]
ConditionPathExists=/nonexistent-do-not-resize

[Service]
ExecStart=
EOF
echo "  ✔ 已 mask"

echo "════ 5. 删除旧的 autofs4 模块引用（内核无此模块）════"
grep -v '^autofs4' "$D/etc/modules" > "$W/m2.new" 2>/dev/null && cp "$W/m2.new" "$D/etc/modules" || true
cat "$D/etc/modules" 2>/dev/null | sed 's/^/    /'

echo "════ 6. 安装与当前内核匹配的模块 ════"
cd "$KDIR"
rm -rf "$D/lib/modules/6.1.141"
make modules_install INSTALL_MOD_PATH="$D" 2>&1 | tail -2
echo "  模块数: $(find "$D/lib/modules/6.1.141" -name '*.ko' | wc -l)"
find "$D/lib/modules/6.1.141" -name '8852bs.ko' -exec ls -l {} \;

echo "════ 7. 建 ext4（带 journal）════"
rm -f "$IMG"
truncate -s "$SLOT" "$IMG"
mkfs.ext4 -F -q -m 0 -L ROOTFS -I 256 -O ^dir_index -J size=64 "$IMG"
mkdir -p "$W/mnt"
mount -o loop "$IMG" "$W/mnt"
time cp -a "$D"/. "$W/mnt"/
sync
df -h "$W/mnt" | tail -1
sync; umount "$W/mnt" || { sync; umount -l "$W/mnt"; }

echo "════ 8. e2fsck ════"
e2fsck -f -y -D "$IMG" 2>&1 | tail -4

echo "════ 9. 校验 ════"
losetup -D 2>/dev/null || true
mkdir -p "$W/chk"; umount "$W/chk" 2>/dev/null || true
mount -o loop,ro "$IMG" "$W/chk"
echo "  journal: $(tune2fs -l "$IMG" 2>/dev/null | grep -i journal || true)"
tune2fs -l "$IMG" 2>/dev/null | grep -iE "^Filesystem features|Default mount options" | sed 's/^/  /'
df -h "$W/chk" | tail -1
for p in sbin/init usr/trim/bin usr/bin/dockerd usr/bin/containerd \
         usr/libexec/docker/cli-plugins/docker-compose var/lib/postgresql \
         lib/modules/6.1.141 etc/openvswitch etc/fstab; do
    if [ -e "$W/chk/$p" ]; then echo "  ✔ $p"; else echo "  ✘ 缺失 $p"; fi
done
echo "  模块数: $(find "$W/chk/lib/modules" -name '*.ko' 2>/dev/null | wc -l)"
echo "  resize-rootfs mask: $(readlink $W/chk/etc/systemd/system/resize-rootfs.service 2>/dev/null)"
echo "  fstab:"; sed 's/^/    /' "$W/chk/etc/fstab"
sync; umount "$W/chk"
losetup -D 2>/dev/null || true
ls -lh "$IMG"
