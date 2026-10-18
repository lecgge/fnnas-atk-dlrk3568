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

echo
echo "════ 3.7 固化 FnNAS 兼容层与自愈 ════"
# 以下都是 2026-10-17 在真机上逐条实测出来的必要补丁，固化进镜像后刷完即生效。
# 还原脚本：/usr/local/sbin/fnnas-unfix.sh
mkdir -p "$D/usr/local/sbin/fnnas-compat"

# ---- ① zpool / zfs：内核无 ZFS 模块，FnNAS 建阵列前的探测会致命失败 ----
# ZFS 是 out-of-tree 模块，不在 Linux 主线源码树里，make 编不出来。
# FnNAS 建 RAID 前会跑 `zpool status` 探测已有池，失败即中止整个建卷流程。
# 本机确实一块 ZFS 池都没有，所以如实返回「空池列表」并退出 0。
cat > "$D/usr/local/sbin/fnnas-compat/zpool" <<'SHIM'
#!/bin/bash
# FnNAS 兼容层：无 ZFS 内核模块时，如实返回「无池」
case "$1" in
  status|list|get) echo '{"output_version":"1.0","pools":{},"remove_pools":{}}' ;;
  version)         echo "zfs 2.2.2" ;;
  import|scrub)    ;;
  *)               echo '{}' ;;
esac
exit 0
SHIM
chmod 755 "$D/usr/local/sbin/fnnas-compat/zpool"

cat > "$D/usr/local/sbin/fnnas-compat/zfs" <<'SHIM'
#!/bin/bash
# FnNAS 兼容层：同 zpool
case "$1" in
  list|get)  echo '{"output_version":"1.0","pools":{}}' ;;
  version)   echo "zfs 2.2.2" ;;
  *)         echo '{}' ;;
esac
exit 0
SHIM
chmod 755 "$D/usr/local/sbin/fnnas-compat/zfs"

# ---- ② mdadm：FnNAS 固定传 --bitmap=lockless，mdadm 4.5 已拒绝该选项 ----
# bitmap 只用于重同步加速，非必需，剔除不影响功能与数据安全。
cat > "$D/usr/local/sbin/fnnas-compat/mdadm" <<'SHIM'
#!/bin/bash
# FnNAS 兼容层：剔除 --bitmap=<type>（mdadm 4.5 拒绝 lockless）
ARGS=()
for a in "$@"; do
  case "${a%%=*}" in
    --bitmap) ;;
    *) ARGS+=("$a") ;;
  esac
done
/usr/trim/bin/mdadm.real ${ARGS[@]+"${ARGS[@]}"}
exit $?
SHIM
chmod 755 "$D/usr/local/sbin/fnnas-compat/mdadm"

# ---- 接管原始路径：原文件改名 .real，用软链指向兼容层 ----
# 用法：install_compat <原始路径，如 /usr/sbin/zpool>
# 三个路径概念不能混用：
#   $D$orig                     构建期实际文件（rootfs 暂存目录里的）
#   /usr/local/sbin/fnnas-compat/<name>   运行时软链的目标
#   $orig                       运行时被替换的路径
install_compat() {
  local orig="$1" name path src_target link_target
  name=$(basename "$orig")
  path="$D$orig"
  src_target="$D/usr/local/sbin/fnnas-compat/$name"
  link_target="/usr/local/sbin/fnnas-compat/$name"
  if [ ! -e "$path" ]; then
    echo "  ⚠ 构建期找不到 $path，跳过"
    return 0
  fi
  if [ ! -f "$src_target" ]; then
    echo "  ⚠ 兼容层 $src_target 不存在，跳过"
    return 0
  fi
  if [ ! -e "$path.real" ]; then
    cp -a "$path" "$path.real" || { echo "  ✘ 备份 $path 失败"; return 1; }
  fi
  rm -f "$path"
  ln -s "$link_target" "$path"
  if [ -L "$path" ] && [ "$(readlink "$path")" = "$link_target" ] && [ -f "$path.real" ]; then
    echo "  ✔ $orig -> $(readlink "$path")  （原件 ${path##*/}.real, $(stat -c%s "$path.real") 字节）"
  else
    echo "  ✘ $orig 软链创建失败 <<<"
    return 1
  fi
}
cat > "$D/usr/local/sbin/fnnas-compat/umount" <<'SHIM'
#!/bin/bash
# FnNAS 兼容层：umount 在「本来就没挂载」时返回非 0，
# 而 FnNAS 挂载存储空间前会先调 umount 预清理，把这个当成致命错误直接中止，
# 后面的 mount 根本不执行 —— 表现为「存储空间挂载失败」/「挂载点已存在」。
# 处理：「本来就没挂载」等同于「卸载成功」，返回 0；其它真实错误照常透传。
#
# ⚠️ 关键安全约束：绝不以「无参数」调用真实 umount。
#    util-linux 的 umount 在不带参数时会向系统中所有进程发送 SIGUSR1
#    并阻塞等待它们退出 —— 那会把整个系统扫一遍，导致服务反复被杀、
#    systemd 重启后再次触发，形成循环，表现为「web 时通时断」。
#
# 另一条约束：REAL 必须固定，不能用 `command -v umount` 兜底 —— /bin 是
# /usr/bin 的软链，那条兜底会找到本 shim 自己，造成无限 fork。
REAL=/usr/bin/umount.real
if [ $# -eq 0 ]; then
  # 无参调用一律不落到真实 umount，直接成功返回
  exit 0
fi
[ -x "$REAL" ] || { echo "umount.real 缺失" >&2; exit 127; }
ERR=$("$REAL" "$@" 2>&1 >/dev/null)
RC=$?
ERR=${ERR//umount.real:/umount:}   # util-linux 用 argv[0] 拼消息，还原成 umount
if [ $RC -eq 0 ]; then exit 0; fi
case "$ERR" in
  *"not mounted"*|*"not currently mounted"*|*"no mount point specified"*)
    [ -n "$ERR" ] && echo "$ERR" >&2
    exit 0 ;;
esac
[ -n "$ERR" ] && echo "$ERR" >&2
exit $RC
SHIM
chmod 755 "$D/usr/local/sbin/fnnas-compat/umount"

# ---- ④ smartctl：eMMC 不支持 ATA SMART ----
# FnNAS 在挂载/建卷前做硬盘健康检查 smartctl -a --json <dev>，
# eMMC 没有 ATA SMART 接口，smartctl 报 "Unable to detect device type" 退出 1，
# FnNAS 读不到 smart_status.passed 就判定「硬盘不健康」而拒绝操作。
# 只对 mmcblk* 生效，且只在真实 smartctl 已经失败时补一份输出，
# 语义是「不支持 SMART、未检测到健康异常」；nvme/sd* 原样透传。
cat > "$D/usr/local/sbin/fnnas-compat/smartctl" <<'SHIM'
#!/bin/bash
# FnNAS 兼容层：eMMC 无 ATA SMART，如实报告「不支持」而非「不健康」
REAL=/usr/sbin/smartctl.real
[ -x "$REAL" ] || { echo "smartctl.real 缺失" >&2; exit 127; }

DEV=""; prev=""
for a in "$@"; do
  case "$prev" in -d|--device) DEV="$a" ;; esac
  case "$a" in /dev/*) DEV="$a" ;; esac
  case "$a" in -*) ;; *) prev="$a" ;; esac
done
case "$DEV" in
  ""|/dev/mmcblk*) ;;
  *) exec "$REAL" "$@" ;;
esac

if OUT=$("$REAL" "$@" 2>/dev/null) && [ $? -eq 0 ]; then
  printf '%s\n' "$OUT"; exit 0
fi

JSON=no
for a in "$@"; do [ "$a" = "--json" ] && JSON=yes; done
if [ "$JSON" = yes ]; then
  cat <<JSONEOF
{
  "json_format_version": [ 1, 0 ],
  "smartctl": {
    "version": [ 7, 3 ],
    "platform_info": "fnnas-compat",
    "argv": [ "smartctl", "$DEV" ],
    "exit_status": 0
  },
  "device": {
    "name": "$DEV",
    "info_name": "$DEV",
    "type": "scsi",
    "protocol": "SCSI"
  },
  "smart_support": { "available": false, "enabled": false },
  "smart_status": { "passed": true }
}
JSONEOF
else
  echo "$DEV:  该设备不支持 SMART（eMMC 无 ATA SMART 接口）"
  echo "SMART Support is:      Unavailable - device does not support SMART"
  echo "fnnas-compat: 未检测到健康异常，按通过处理。"
fi
exit 0
SHIM
chmod 755 "$D/usr/local/sbin/fnnas-compat/smartctl"

install_compat /usr/sbin/zpool
install_compat /usr/sbin/zfs
install_compat /usr/trim/bin/mdadm
install_compat /usr/bin/umount
install_compat /usr/sbin/smartctl

# ---- ③ Docker 文件自愈 ----
# 实测：新刷的板子开机会丢掉 /usr/bin/dockerd、docker、docker-proxy、
#       /usr/libexec/docker/docker-init、docker-compose 共 5 个文件（约 200MB），
#       而镜像里这些文件完整、e2fsck 干净 —— 是开机早期被清掉的，
#       触发点尚未查明。这里做兜底。
# 注意：raw 副本要 193MB，会把 3.28GB 的 rootfs 塞爆（只剩 26MB），
#       所以一律用 xz -3 压缩存放，原始 193MB -> 约 47MB。
mkdir -p "$D/usr/local/share/fnnas-docker-files/usr/bin"
mkdir -p "$D/usr/local/share/fnnas-docker-files/usr/libexec/docker/cli-plugins"
BACKUP_BYTES=0
for f in usr/bin/docker usr/bin/dockerd usr/bin/docker-proxy \
         usr/libexec/docker/docker-init usr/libexec/docker/cli-plugins/docker-compose; do
  if [ -f "$D/$f" ]; then
    RAW=$(stat -c%s "$D/$f")
    xz -3 -c "$D/$f" > "$D/usr/local/share/fnnas-docker-files/$f.xz"
    CP=$(stat -c%s "$D/usr/local/share/fnnas-docker-files/$f.xz")
    BACKUP_BYTES=$((BACKUP_BYTES + CP))
    printf "  ✔ 备份 %-50s %9s -> %9s 字节\n" "$f" "$RAW" "$CP"
  fi
done
echo "  备份合计: $((BACKUP_BYTES / 1024 / 1024)) MiB（原 193 MiB）"

cat > "$D/usr/local/sbin/fnnas-docker-heal.sh" <<'HEAL'
#!/bin/bash
# Docker 文件自愈：板子开机会丢失这 5 个文件，缺失就从 xz 备份解压补回。
set -u
exec >>/var/log/fnnas-docker-heal.log 2>&1 || true
echo "=== $(date '+%F %T') ==="
SRC=/usr/local/share/fnnas-docker-files
FIXED=0
for f in usr/bin/docker usr/bin/dockerd usr/bin/docker-proxy \
         usr/libexec/docker/docker-init usr/libexec/docker/cli-plugins/docker-compose; do
  if [ ! -e "/$f" ] && [ -f "$SRC/$f.xz" ]; then
    mkdir -p "$(dirname "/$f")"
    xz -dc "$SRC/$f.xz" > "/$f" && chmod 755 "/$f" \
      && { echo "  已恢复 /$f ($(stat -c%s "/$f") 字节)"; FIXED=$((FIXED+1)); }
  fi
done
[ $FIXED -gt 0 ] && echo "共恢复 $FIXED 个文件" || echo "无需恢复"
exit 0
HEAL
chmod +x "$D/usr/local/sbin/fnnas-docker-heal.sh"

cat > "$D/etc/systemd/system/fnnas-docker-heal.service" <<'HEALSVC'
[Unit]
Description=Restore Docker binaries if missing
After=local-fs.target
Before=docker.service trim_main.service multi-user.target
ConditionPathExists=/usr/local/sbin/fnnas-docker-heal.sh

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=120
ExecStart=/usr/local/sbin/fnnas-docker-heal.sh

[Install]
WantedBy=multi-user.target
HEALSVC
mkdir -p "$D/etc/systemd/system/multi-user.target.wants"
ln -sf ../fnnas-docker-heal.service "$D/etc/systemd/system/multi-user.target.wants/fnnas-docker-heal.service"
# 刻意不用 sysinit.target：那一层里出现 WaitOn 依赖容易拖慢/扰乱整个引导顺序

# ---- 还原脚本 ----
cat > "$D/usr/local/sbin/fnnas-unfix.sh" <<'UNFIX'
#!/bin/bash
# 撤销本镜像所有兼容层 / 自愈改动
echo "还原 FnNAS 兼容层..."
for b in /usr/sbin/zpool /usr/bin/zpool /sbin/zpool \
         /usr/trim/bin/mdadm /usr/bin/umount /usr/sbin/smartctl; do
  if [ -e "$b.real" ]; then mv -f "$b.real" "$b"; echo "  还原 $b"; fi
done
systemctl disable fnnas-docker-heal.service 2>/dev/null
rm -f /etc/systemd/system/fnnas-docker-heal.service \
      /etc/systemd/system/multi-user.target.wants/fnnas-docker-heal.service
echo "完成。注意：还原后 FnNAS 将无法创建存储空间（zpool 探测与 mdadm 都会失败）。"
UNFIX
chmod +x "$D/usr/local/sbin/fnnas-unfix.sh"
echo "  ✔ 已安装 zpool/zfs/mdadm 兼容层 + Docker 自愈 + fnnas-unfix.sh"

echo
echo "════ 3.8 存储卷自动挂载自愈 + Docker 数据目录 ════"
# 逆向结论：FnNAS 的挂载点约定是「/vol + mount 表 id」，id=0 是系统卷 /vol00，
# 用户卷设备为 /dev/mapper/<mount.uuid>。原厂 triminitd::mount_storage() 在本板子
# 报 "unable to find record for /dev/dm-N"，存储空间永远停在「未挂载」，
# Web 点「去挂载」则回 196616 挂载点已存在。这里按同一约定补挂。
install -d "$D/usr/local/sbin"
cat > "$D/usr/local/sbin/fnnas-vol-mount.sh" <<'VOLMNT'
#!/bin/bash
# FnNAS 存储卷自动挂载（ATK-DLRK3568 适配）
#
# 为什么需要它：
#   FnNAS 约定 挂载点 = /vol + (trim.mount 表的 id)，设备 = /dev/mapper/<mount.uuid>。
#   原厂 triminitd::mount_storage() 在本板子恒定报
#     "unable to find record for /dev/dm-N uuid:..."
#   导致存储空间永远停在「未挂载」，Web 点「去挂载」回 196616 挂载点已存在。
#
# 两条踩过的坑（改之前务必读）：
#   ① 早期版本在结尾无条件 `try-restart trim_main.service`。配上 60 秒的 timer
#      就变成每分钟重启一次 FnNAS 后端，Web 页面直接不可用（能 ping 通、端口开着，
#      但页面永远转圈）。现在只在「本轮真的挂上了新卷」时才重启。
#   ② 早期版本每轮都跑 vgchange -ay / udevadm settle，会和 FnNAS 的设备管理打架。
#      现在先判断是否全部已挂载，是就直接退出，一个设备栈命令都不执行。
set +u
LOG=/var/log/fnnas-vol-mount.log
exec >>"$LOG" 2>&1
echo "=== $(date '+%F %T') 开始 ==="

PSQL="su -s /bin/bash postgres -c"
DB=trim
CACHE=/var/lib/fnnas-vol-mount/map
mkdir -p "$(dirname "$CACHE")"

ROWS=$($PSQL "psql -d $DB -tAc \"select id||'|'||uuid from mount where id<>0 and uuid is not null order by id\"" 2>/dev/null | tr -d ' ' | grep '|')
if [ -n "$ROWS" ]; then
    printf '%s\n' "$ROWS" > "$CACHE"
else
    echo "PG 不可用或 mount 表为空，尝试缓存 $CACHE"
    [ -f "$CACHE" ] && ROWS=$(cat "$CACHE")
fi

if [ -z "$ROWS" ]; then
    echo "没有需要挂载的存储卷，结束"
    echo "=== 结束 ==="
    exit 0
fi

# 快路径：全部已挂载就直接退出，绝不碰设备栈
: > /tmp/.fnnas-vol-pending
echo "$ROWS" | while IFS='|' read -r ID UUID; do
    [ -n "${ID:-}" ] && [ -n "${UUID:-}" ] || continue
    mountpoint -q "/vol${ID}" || echo 1 >> /tmp/.fnnas-vol-pending
done
PENDING=0
[ -s /tmp/.fnnas-vol-pending ] && PENDING=1
rm -f /tmp/.fnnas-vol-pending

if [ "$PENDING" != "1" ]; then
    echo "全部存储卷均已挂载，无需操作"
    echo "=== 结束 ==="
    exit 0
fi

# 慢路径：确实有卷没挂上，才做 LVM/md 准备
vgchange -ay >/dev/null 2>&1 || true
udevadm settle >/dev/null 2>&1 || true
if [ -f /proc/mdstat ]; then
    for m in /dev/md*; do
        [ -b "$m" ] || continue
        grep -q "$(basename "$m") " /proc/mdstat 2>/dev/null && continue
        mdadm --run "$m" >/dev/null 2>&1 || true
    done
fi
sleep 2

: > /tmp/.fnnas-vol-mounted
echo "$ROWS" | while IFS='|' read -r ID UUID; do
    [ -n "${ID:-}" ] && [ -n "${UUID:-}" ] || continue
    MP="/vol${ID}"
    DEV="/dev/mapper/${UUID}"
    echo "--- id=$ID uuid=$UUID -> $MP ---"
    if [ ! -e "$DEV" ]; then
        for d in /dev/dm-* /dev/md*; do
            [ -e "$d" ] || continue
            n=$(cat /sys/block/$(basename "$d")/dm/name 2>/dev/null)
            [ "$n" = "$UUID" ] && { DEV="$d"; break; }
        done
    fi
    [ -e "$DEV" ] || { echo "  !! 设备不存在：$DEV"; continue; }
    mkdir -p "$MP"; chmod 0755 "$MP"
    if mountpoint -q "$MP"; then
        echo "  已挂载：$(findmnt -n -o SOURCE "$MP")"
        continue
    fi
    if mount "$DEV" "$MP" 2>/dev/null; then
        echo "  挂载成功 -> $MP ($(findmnt -n -o FSTYPE "$MP"))"
        echo 1 >> /tmp/.fnnas-vol-mounted
    else
        echo "  !! 挂载失败 $DEV $MP"
    fi
done

MOUNTED=0
[ -s /tmp/.fnnas-vol-mounted ] && MOUNTED=1
rm -f /tmp/.fnnas-vol-mounted

# 只有真的新挂上了卷，才让 FnNAS 重建挂载缓存（init_mount_cache 读 /etc/mtab）
if [ "$MOUNTED" = "1" ] && pgrep -x trim >/dev/null 2>&1; then
    echo "  本轮新挂载，重启 trim_main 刷新挂载缓存"
    systemctl try-restart trim_main.service >/dev/null 2>&1 || true
    sleep 5
else
    echo "  本轮无新挂载，不打扰 trim_main"
fi

echo "当前 /vol* 挂载："
findmnt -o TARGET,SOURCE,FSTYPE 2>/dev/null | grep -E '/vol' || echo "  (无)"
echo "=== 结束 ==="
exit 0
VOLMNT
chmod 0755 "$D/usr/local/sbin/fnnas-vol-mount.sh"

cat > "$D/etc/systemd/system/fnnas-vol-mount.service" <<'VOLSVC'
[Unit]
Description=FnNAS storage volume auto-mount (ATK-DLRK3568 fix)
After=postgresql.service lvm2-monitor.service
Wants=trim_main.service
Requires=postgresql.service

[Service]
Type=oneshot
TimeoutStartSec=180
ExecStart=/usr/local/sbin/fnnas-vol-mount.sh

[Install]
WantedBy=multi-user.target
VOLSVC

cat > "$D/etc/systemd/system/fnnas-vol-mount.timer" <<'VOLTMR'
[Unit]
Description=FnNAS storage volume auto-mount timer (ATK-DLRK3568 fix)

[Timer]
OnBootSec=120s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=fnnas-vol-mount.service

[Install]
WantedBy=timers.target
VOLTMR

mkdir -p "$D/etc/systemd/system/multi-user.target.wants" \
         "$D/etc/systemd/system/timers.target.wants" \
         "$D/var/lib/fnnas-vol-mount"
ln -sf ../fnnas-vol-mount.service "$D/etc/systemd/system/multi-user.target.wants/fnnas-vol-mount.service"
ln -sf ../fnnas-vol-mount.timer   "$D/etc/systemd/system/timers.target.wants/fnnas-vol-mount.timer"

# ---- Docker data-root 跟随存储卷 ----
# FnNAS 的 dockermgr 每次启动都会按 dockermgr.conf 重写 /etc/docker/daemon.json，
# 但它并不会把 data-root 写进去（dockermgr.conf 填了也不生效）。
# 所以在 dockerd 启动前把 data-root 合并进 daemon.json。
cat > "$D/usr/local/sbin/fnnas-dockerd.sh" <<'DOCKERD'
#!/bin/bash
# 选择 Docker data-root：优先放到 FnNAS 存储卷上，没有存储卷才回落系统盘。
set +e
DR=/var/lib/docker
PICK=$(awk '$2 ~ /^\/vol[0-9]+$/ {print $2}' /proc/mounts 2>/dev/null | sort | head -1)
if [ -n "$PICK" ]; then
    SRC=$(findmnt -n -o SOURCE --target "$PICK" 2>/dev/null)
    RFS=$(findmnt -n -o SOURCE --target / 2>/dev/null)
    if [ -n "$SRC" ] && [ "$SRC" != "$RFS" ]; then DR="$PICK/docker"; fi
fi
mkdir -p "$DR" 2>/dev/null || DR=/var/lib/docker
mkdir -p "$DR" 2>/dev/null
python3 - "$DR" <<'PY' 2>/dev/null
import json,sys,os
dr=sys.argv[1]; p='/etc/docker/daemon.json'; d={}
try:
    with open(p) as f: d=json.load(f)
except Exception: d={}
if not isinstance(d,dict): d={}
d['data-root']=dr
d.setdefault('storage-driver','overlay2')
os.makedirs('/etc/docker',exist_ok=True)
tmp=p+'.tmp'
with open(tmp,'w') as f: json.dump(d,f)
os.replace(tmp,p)
try:
    q='/usr/trim/etc/dockermgr.conf'
    c=json.load(open(q))
    if c.get('data-root')!=dr:
        c['data-root']=dr
        json.dump(c,open(q,'w'),ensure_ascii=False)
except Exception: pass
PY
echo "[fnnas-dockerd] data-root=$DR" >&2
exec /usr/bin/dockerd --log-level=error --tls=false -H unix:///var/run/docker.sock
DOCKERD
chmod 0755 "$D/usr/local/sbin/fnnas-dockerd.sh"

mkdir -p "$D/etc/systemd/system/docker.service.d"
cat > "$D/etc/systemd/system/docker.service.d/10-fnnas-datadir.conf" <<'DOCKERDROPDOWN'
[Unit]
Wants=fnnas-vol-mount.service
After=fnnas-vol-mount.service

[Service]
ExecStart=
ExecStart=/usr/local/sbin/fnnas-dockerd.sh
DOCKERDROPDOWN
echo "  ✔ 已安装 fnnas-vol-mount.{service,timer} + fnnas-dockerd.sh + docker drop-in"

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
