#!/bin/bash
K=/root/.ssh/fnnas_ed25519
NAS() { ssh -i $K -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/known_hosts \
        -o ConnectTimeout=10 xuleyu@192.168.100.131 "$@"; }
mkdir -p /root/fnnas-re/lib
echo "════ 打包 /usr/trim/lib 拉回来 ════"
NAS 'sudo tar -C /usr/trim/lib -cf - --exclude="ai_manager" --exclude="imagesrv" .' \
  | tar -C /root/fnnas-re/lib -xf -
du -sh /root/fnnas-re/lib
ls /root/fnnas-re/lib | wc -l

echo
echo "════ 在哪些库里定义了这几个符号 ════"
for sym in get_sys_disk_free_space_partno is_dev_diskmapper is_sys_disk is_dev_disk set_external_disk_access do_md_list_disks; do
  echo "--- $sym ---"
  for f in /root/fnnas-re/lib/*.so*; do
    [ -f "$f" ] || continue
    if aarch64-linux-gnu-nm -D --defined-only "$f" 2>/dev/null | grep -q " $sym\$"; then
      echo "    $(basename $f)"
    fi
  done
done
