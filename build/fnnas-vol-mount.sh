#!/bin/bash
# FnNAS 存储卷开机/定时自动挂载
# 背景（逆向结论）：
#   FnNAS 约定 —— 挂载点 = /vol + (mount 表 id)；id=0 是系统卷 /vol00。
#   设备 = /dev/mapper/<mount.uuid>（LVM LV 名）。
#   原厂 triminitd::mount_storage() 在本板子报 "unable to find record for /dev/dm-N"，
#   导致存储空间永远停在「未挂载」。这里按同一约定补挂。
# 兜底：PG 不可用时用上次成功的 uuid→id 映射缓存。
set +u
LOG=/var/log/fnnas-vol-mount.log
exec >>"$LOG" 2>&1
echo "=== $(date '+%F %T') 开始 ==="

PSQL="su -s /bin/bash postgres -c"
DB=trim
CACHE=/var/lib/fnnas-vol-mount/map
mkdir -p "$(dirname "$CACHE")"

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

ROWS=$($PSQL "psql -d $DB -tAc \"select id||'|'||uuid from mount where id<>0 and uuid is not null order by id\"" 2>/dev/null | tr -d ' ' | grep '|')

if [ -n "$ROWS" ]; then
    printf '%s\n' "$ROWS" > "$CACHE"
else
    echo "PG 不可用或 mount 表为空，尝试缓存 $CACHE"
    [ -f "$CACHE" ] && ROWS=$(cat "$CACHE")
fi

if [ -z "$ROWS" ]; then
    echo "没有可挂载的存储卷，跳过"
    echo "=== 结束 ==="
    exit 0
fi

CHANGED=0
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
    else
        echo "  !! 挂载失败 $DEV $MP"
    fi
done

if grep -qE '^/dev/(dm-|md|mapper)' /etc/mtab 2>/dev/null; then
    # 让 FnNAS 重建挂载缓存（init_mount_cache 读 /etc/mtab）
    if pgrep -x trim >/dev/null 2>&1; then
        systemctl try-restart trim_main.service >/dev/null 2>&1 || true
        sleep 5
    fi
fi

echo "当前 /vol* 挂载："
findmnt -o TARGET,SOURCE,FSTYPE 2>/dev/null | grep -E '/vol' || echo "  (无)"
echo "=== 结束 ==="
exit 0
