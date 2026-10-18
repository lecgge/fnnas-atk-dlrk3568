#!/bin/bash
# FnNAS 容器数据目录选择器
# FnNAS 的 dockermgr 每次启动都会按 dockermgr.conf 重写 /etc/docker/daemon.json，
# 但它不会把 data-root 写进去（dockermgr.conf 里填了也不生效）。
# 所以这里在 dockerd 启动前把 data-root 合并进 daemon.json，再用官方 ExecStart 启动。
set +e

DR=/var/lib/docker
PICK=$(awk '$2 ~ /^\/vol[0-9]+$/ {print $2}' /proc/mounts 2>/dev/null | sort | head -1)
if [ -n "$PICK" ]; then
    SRC=$(findmnt -n -o SOURCE --target "$PICK" 2>/dev/null)
    RFS=$(findmnt -n -o SOURCE --target / 2>/dev/null)
    if [ -n "$SRC" ] && [ "$SRC" != "$RFS" ]; then
        DR="$PICK/docker"
    fi
fi
mkdir -p "$DR" 2>/dev/null || DR=/var/lib/docker
mkdir -p "$DR" 2>/dev/null

# 合并写 daemon.json：保留 dockermgr 写的键，补上 data-root
python3 - "$DR" <<'PY' 2>/dev/null
import json,sys,os
dr=sys.argv[1]
p='/etc/docker/daemon.json'
d={}
try:
    with open(p) as f: d=json.load(f)
except Exception:
    d={}
if not isinstance(d,dict): d={}
d['data-root']=dr
d.setdefault('storage-driver','overlay2')
os.makedirs('/etc/docker',exist_ok=True)
tmp=p+'.tmp'
with open(tmp,'w') as f: json.dump(d,f)
os.replace(tmp,p)
# 同步给 FnNAS Docker 管理器，让 Web 界面显示正确
try:
    q='/usr/trim/etc/dockermgr.conf'
    c=json.load(open(q))
    if c.get('data-root')!=dr:
        c['data-root']=dr
        json.dump(c,open(q,'w'),ensure_ascii=False)
except Exception:
    pass
PY

echo "[fnnas-dockerd] data-root=$DR" >&2
exec /usr/bin/dockerd --log-level=error --tls=false -H unix:///var/run/docker.sock
