#!/bin/bash
# FnNAS 存储卷自动挂载 + 设备别名（ATK-DLRK3568 适配）
#
# 要解决的两个问题（都是逆向 storage.hdl 得到的硬事实）：
#
# ① 原厂 triminitd::mount_storage() 在本板子恒定报
#      "unable to find record for /dev/dm-N uuid:..."
#    存储空间永远停在「未挂载」，Web 点「去挂载」回 196616 挂载点已存在。
#    → 按 FnNAS 自己的约定补挂：挂载点 = /vol + trim.mount 表的 id，
#      设备 = /dev/mapper/<mount.uuid>。
#
# ② 即使卷挂上了，Web 上仍然显示「未挂载」。原因是 find_vol_mount_info()：
#
#      uint64_t rdev = get_rdev(uuid);     // get_rdev 内部就是
#                                          //   statx(AT_FDCWD, uuid, ...) 判断是否块设备
#      if (rdev != 0) { /* 按 entry->rdev 匹配 —— 正确路径 */ }
#      else           { /* strcmp(设备串, uuid) —— 退化路径 */ }
#
#    传进去的是裸 uuid（trim_xxxx-0），而 trim 进程的 WorkingDirectory 是 /，
#    statx("trim_xxxx-0") 必然 ENOENT → 返回 0 → 只能走退化路径；
#    退化路径拿 /etc/mtab 的原始设备串 /dev/dm-0 去 strcmp 裸 uuid，
#    多了 /dev/mapper/ 或 /dev/ 前缀，必然对不上 → mountpoint 为空 →
#    前端 `if (!e.mountpoint) return 'unmounted'` 命中。
#
#    → 在根目录建一个名为 <uuid> 的块设备节点（与 LV 同 major:minor），
#      statx(uuid) 就能成功，find_vol_mount_info 走 rdev 匹配，界面显示已挂载。
#
# 三条踩过的坑（改之前务必读）：
#   ① 早期版本在结尾无条件 `try-restart trim_main.service`，配 60 秒 timer
#      就是每分钟重启一次 FnNAS 后端，Web 直接不可用。现在只在状态真变了才重启。
#   ② 早期版本每轮都跑 vgchange -ay / udevadm settle，和 FnNAS 设备管理打架。
#      现在无事可做时立刻退出，一个设备栈命令都不执行。
#   ③ 别名节点必须在重启 trim_main 之前建好，否则 trim 读到的是旧缓存。
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
    echo "没有需要处理的存储卷，结束"
    echo "=== 结束 ==="
    exit 0
fi

# ---------- 检查：有没有卷没挂 / 别名节点缺失或不对 ----------
# 注意：/sys/block/<dev>/dev 是十进制 major:minor，stat -c '%t:%T' 是十六进制。
# 直接两边都用 stat 取十六进制来比，避免任何进制转换出错。
: > /tmp/.fnnas-vol-work
echo "$ROWS" | while IFS='|' read -r ID UUID; do
    [ -n "${ID:-}" ] && [ -n "${UUID:-}" ] || continue
    MP="/vol${ID}"
    DEV="/dev/mapper/${UUID}"
    mountpoint -q "$MP" || { echo "UNMOUNTED" >> /tmp/.fnnas-vol-work; continue; }
    REAL=$(readlink -f "$DEV" 2>/dev/null)
    if [ -z "$REAL" ] || [ ! -e "$REAL" ]; then
        echo "NODE" >> /tmp/.fnnas-vol-work; continue
    fi
    WANT=$(stat -c '%t:%T' "$REAL" 2>/dev/null)
    CUR=$(stat -c '%t:%T' "/$UUID" 2>/dev/null)
    [ -z "$WANT" ] && { echo "NODE" >> /tmp/.fnnas-vol-work; continue; }
    if [ -z "$CUR" ] || [ "$CUR" != "$WANT" ]; then
        echo "NODE" >> /tmp/.fnnas-vol-work
    fi
done
WORK=$(wc -l < /tmp/.fnnas-vol-work 2>/dev/null || echo 0)
rm -f /tmp/.fnnas-vol-work

if [ "$WORK" = "0" ]; then
    echo "全部存储卷已挂载且设备别名正常，无需操作"
    echo "=== 结束 ==="
    exit 0
fi
echo "检测到 $WORK 项需要处理"

# ---------- 慢路径 ----------
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
    if [ ! -e "$DEV" ]; then echo "  !! 设备不存在，跳过"; continue; fi

    mkdir -p "$MP"; chmod 0755 "$MP"
    if mountpoint -q "$MP"; then
        echo "  已挂载：$(findmnt -n -o SOURCE "$MP")"
    else
        if mount "$DEV" "$MP" 2>/dev/null; then
            echo "  挂载成功 -> $MP ($(findmnt -n -o FSTYPE "$MP"))"
        else
            echo "  !! 挂载失败 $DEV $MP"; continue
        fi
    fi

    # 关键：在根目录建 <uuid> 块设备节点，让 get_rdev(uuid) 的 statx 成功
    REAL=$(readlink -f "$DEV" 2>/dev/null)
    MAJMIN=$(cat /sys/block/$(basename "$REAL" 2>/dev/null)/dev 2>/dev/null)
    if [ -n "$MAJMIN" ]; then
        MAJ=${MAJMIN%%:*}; MIN=${MAJMIN##*:}
        WANT=$(stat -c '%t:%T' "$REAL" 2>/dev/null)
        CUR=$(stat -c '%t:%T' "/$UUID" 2>/dev/null)
        if [ -z "$CUR" ] || [ "$CUR" != "$WANT" ]; then
            rm -f "/$UUID" 2>/dev/null
            mknod "/$UUID" b "$MAJ" "$MIN" 2>/dev/null \
                && echo "  ✔ 设备别名 /$UUID -> $MAJ:$MIN (major:minor $MAJMIN)，让 FnNAS 走 rdev 匹配" \
                || echo "  !! 建别名节点失败"
        else
            echo "  设备别名 /$UUID 已正确（$CUR）"
        fi
    fi
done

# 清理已不存在的存储卷留下的孤儿别名节点
for f in /trim_*; do
    [ -e "$f" ] || continue
    U=${f#/}
    if ! echo "$ROWS" | grep -q "|$U$"; then
        echo "清理孤儿节点 $f（数据库里已无此存储卷）"
        rm -f "$f"
    fi
done

# 只有状态真的变了，才通知 FnNAS 重建挂载缓存（init_mount_cache 读 /etc/mtab）
if [ "$WORK" != "0" ] && pgrep -x trim >/dev/null 2>&1; then
    echo "  状态已变更，重启 trim_main 刷新挂载缓存"
    systemctl try-restart trim_main.service >/dev/null 2>&1 || true
    sleep 5
fi

echo "当前 /vol* 挂载："
findmnt -o TARGET,SOURCE,FSTYPE 2>/dev/null | grep -E '/vol' || echo "  (无)"
echo "当前设备别名："
ls -la /trim_* 2>/dev/null || echo "  (无)"
echo "=== 结束 ==="
exit 0
