#!/bin/bash
echo "=== storage.hdl 依赖的库 ==="
aarch64-linux-gnu-readelf -d /root/fnnas-re/storage.hdl | grep NEEDED
echo
echo "=== 全量搜索符号定义（含静态符号表）==="
for sym in get_sys_disk_free_space_partno is_dev_diskmapper is_sys_disk do_md_list_disks set_external_disk_access is_dev_disk; do
  echo "--- $sym ---"
  for f in /root/fnnas-re/lib/*.so* /root/fnnas-re/*.hdl; do
    [ -f "$f" ] || continue
    if aarch64-linux-gnu-nm -C "$f" 2>/dev/null | grep -qE "[TtWw] ${sym}\$"; then
      echo "    $(basename "$f")"
    fi
  done
done
