#!/bin/bash
# FnNAS 存储卷自动挂载（ATK-DLRK3568 适配）
#
# 为什么需要它：
#   FnNAS 约定 挂载点 = /vol + (trim.mount 表的 id)，设备 = /dev/mapper/<mount.uuid>。
#   原厂 triminitd::mount_storage() 在本板子恒定报
#     "unable to find record for /dev/dm-N uuid:..."
#   导致存储空间永远停在「未挂载」，Web 点「去挂载」回 196616 挂载点已存在。
#
# 重要教训（v1 版本踩过）：
#   ① 早期版本在脚本结尾无条件 `try-restart trim_main.service`，
#      配上 60 秒的 timer 就变成每分钟重启一次 FnNAS 后端，Web 直接不可用。
#      现在只在「本轮真的挂上了新卷」时才重启。
#   ② 早期版本每轮都跑 vgchange/udevadm settle，会和 FnNAS 的设备管理打架。
#      现在先判断是否全部已挂载，是就直接退出，什么都不做。
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
    [ -f "$CACHE" ] && ROWS=$(cat "$CACHE")
fi

if [ -z "$ROWS" ]; then
    echo "没有需要挂载的存储卷，结束"
    echo "=== 结束 ==="
    exit 0
fi

# ---- 快路径：全部已挂载就直接退出，绝不碰设备栈 ----
PENDING=0
echo "$ROWS" | while IFS='|' read -r ID UUID; do
    [ -n "${ID:-}" ] && [ -n "${UUID:-}" ] || continue
    mountpoint -q "/vol${ID}" || echo "1" >> /tmp/.fnnas-vol-pending
done
[ -s /tmp/.fnnas-vol-pending ] && PENDING=1
rm -f /tmp/.fnnas-vol-pending

if [ "$PENDING" != "1" ]; then
    echo "全部存储卷均已挂载，无需操作"
    echo "=== 结束 ==="
    exit 0
fi

# ---- 慢路径：确实有卷没挂上，才去做 LVM/md 的准备动作 ----
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
