# ATK-DLRK3568 × FnNAS —— 让飞牛私有云跑在正点原子 RK3568 上

> 把飞牛私有云 FnNAS 官方 ARM 用户空间，移植到正点原子 ATK-DLRK3568（RK3568B2 / 4GB LPDDR4 / 64GB eMMC）上运行。
>
> **成品镜像**：`out/fnnas_ATK-DLRK3568_FnNAS-grow_2026.10.17.img`（3.5GB，RKAF 格式，RKDevTool 升级固件页直刷）

---

## ⚠️ 免责声明

本项目属于非官方移植，飞牛私有云官方从未支持过这块板子。使用前请知悉：

- 本镜像**未经官方验证**，任何数据丢失、硬件损伤、系统无法启动的后果由使用者自行承担
- **刷机前务必准备好救砖手段**：`out/MiniLoaderAll.bin`（481,728 字节），配合 RKDevTool 进入 MASKROM 模式重新刷写
- 每次刷机前**必须关闭并重新打开 RKDevTool**，否则它会使用缓存中的旧镜像（这是本项目最常见的翻车原因）
- 刷完必须**断电重新上电**，不能只看 RKDevTool 的完成提示
- 官方 ROM 与本镜像的固件格式可能不兼容，**刷本镜像前请先备份重要数据**
- 如需回到官方状态，用原厂 `hdmi_ubuntu26.04.1_update.img` 重新刷写即可

---

## 一、成品能做什么

| 能力 | 状态 |
|---|---|
| FnNAS Web 界面（fnOS 1.2.0701） | ✅ 正常 |
| 29 个 FnNAS 核心服务（文件存储、用户、权限、分享等） | ✅ 全部 running |
| PostgreSQL 15（用户/权限/配置库） | ✅ 正常 |
| Open vSwitch + containerd | ✅ 正常（内核已编译 `CONFIG_OPENVSWITCH`） |
| Docker 引擎（CLI 拉镜像、跑容器） | ✅ 可用 |
| 板载 WiFi（RTL8852BS / 8852bs） | ✅ 驱动正常 |
| 板载蓝牙 | ✅ 固件保留 |
| HDMI 输出（Panfrost GPU） | ✅ DTB 用正点原厂 `panfrost-hdmi` |
| 系统盘容量 | ✅ **57.4 GB**（整块 eMMC 已并入根分区，开机自动扩容） |
| device-mapper / LVM / mdadm / btrfs | ✅ 内核已启用（`CONFIG_BLK_DEV_DM` / `CONFIG_BLK_DEV_MD` 全家桶） |
| **FnNAS 存储空间（创建 → 挂载 → 建共享）** | ✅ **M.2 NVMe 实测全流程通过**，详见第五节 |
| **Docker 跑容器** | ✅ `hello-world` 实测通过，`data-root` 自动落在存储卷 |
| **FnNAS 在线更新** | ❌ 架构不匹配，**切勿点击「立即更新」** |
| 串口 console | ⚠️ 固件侧已配置正确，但需自行确认接线 |

**一句话**：插一块 M.2 NVMe 进板子，刷上这个镜像，FnNAS 开箱即用 —— 建存储空间、挂载、建共享、跑容器全流程实测通过。

---

## 二、整体思路

**不重写 FnNAS，只换内核。**

正点原厂镜像 `hdmi_ubuntu26.04.1_update.img` 里本来就带着一份**可用的飞牛 ARM 用户空间**（fnOS 1.2.0701）。所以我们完全保留它，只做两件事：

1. 用自编内核 + external FIT 替换原厂的 `boot.img`
2. 重建一个更瘦、带 journal 的 ext4 rootfs 替换原厂 `rootfs.img`

其余字节**一个都不动**（分区表由 RKDevTool 依据厂商 `parameter.txt` 生成）。

### 关键前提：厂商 u-boot 是 next-dev 分支

```
U-Boot next-dev-g83b0a16 #alientek (Aug 27 2026)
```

Rockchip 2017.09 那套玩法（`boot.scr` / `extlinux.conf` / `distro_bootcmd`）在这里**完全不适用**。next-dev 分支只认两样东西：

- 厂商 `parameter.txt` 定义的分区布局
- `boot` 分区里的 **external FIT**（U-Boot 侧代码见 `arch/arm/mach-rockchip/fit.c:139`，`part_get_info_by_name(dev_desc, PART_BOOT="boot", ...)` 是**大小写敏感的精确匹配**）

### 镜像结构

```
hdmi_ubuntu26.04.1_update.img  (RKAF / "RKFW" 头)
├── [0x00000000 ... ]  RKAF 头 + package-file + parameter.txt + uboot.img + boot.img ...
│
├── @0x4F9226   boot.img     ← 替换为我们的 external FIT（槽位上限 40,579,584 字节）
├── @0x5B8C226   rootfs.img   ← 替换为我们的 ext4 rootfs（槽位上限 3,577,741,312 字节）
└── [rootfs 末尾 ... 文件尾]  不动
```

`afptool` / `rkImageMaker` 不可用（Rockchip 独立 tools 仓库指向内网 `192.168.1.71`），无法重新打包 RKAF，所以只能**原位替换两个定长槽位**。

### external FIT 布局

```
FIT
├── Image 0 (fdt)       rk3568-alientek-panfrost-hdmi.dtb   179,535 字节
│                       sha256 264c6fd1...736e1（与厂商启动日志打印的完全一致）
├── Image 1 (kernel)    Image.gz（gzip 压缩，厂商 next-dev u-boot 支持）
└── Image 2 (resource)  resource.img  1,142,272 字节
```

构建命令：

```bash
rkbin/tools/mkimage -f boot-gz.its -E -p 0x800 boot-gz.img
```

`-E` = 数据放在 FIT 结构之外，`-p 0x800` = 数据起始位置。

---

## 三、内核改动

配置文件：`device/rockchip/.chips/rk3566_rk3568/fnnas.config`

### FnNAS 运行必需

| 配置 | 为什么 |
|---|---|
| `CONFIG_CRYPTO_*` / `CONFIG_ZSTD_*` | btrfs 的 ZSTD/LZO/LZ4 压缩在 `fs/btrfs/Kconfig` 里都 `depends on CRYPTO`，不开 CRYPTO 这三个会被 kconfig **静默丢弃** |
| `CONFIG_BTRFS_FS` + `_ZSTD/_LZO/_LZ4/_DUMP` | FnNAS rootfs 用 btrfs（我们最终改成 ext4，但保留以兼容官方镜像） |
| `CONFIG_OVERLAY_FS` + `_REDIRECT_DIR` | Docker 的存储驱动 |
| `CONFIG_TMPFS_XATTR` | 容器运行时 |

### Docker / 容器

`CGROUPS_*`、`NAMESPACES`（UTS/IPC/PID/NET/USER）、`SECCOMP*`、`MEMCG*`、`NET_NS`、`VETH`、`BRIDGE`、`IP_VS`、`NETFILTER_XT_MATCH_{ADDRTYPE,CONNTRACK,IPVS}`

### NAS 存储（核心）

```conf
CONFIG_BLK_DEV_NVME / CONFIG_NVME_CORE / CONFIG_NVME
CONFIG_SCSI_UFSHCD / CONFIG_UFS_FS
CONFIG_PARTITION_ADVANCED

# 2026-10-17 追加 —— 见第五节「存储空间」章节
CONFIG_BLK_DEV_DM=y
CONFIG_DM_BUFIO / DM_BIO_PRISON / DM_SNAPSHOT / DM_THIN_PROVISIONING / DM_CRYPT
CONFIG_BLK_DEV_MD=y
CONFIG_MD_LINEAR / MD_RAID0 / MD_RAID1 / MD_RAID10

# 容器必需（cgroup v2 没有 device 控制器，Docker 起容器依赖 BPF）
CONFIG_BPF_SYSCALL / CONFIG_BPF_JIT / CONFIG_BPF_JIT_DEFAULT_ON
CONFIG_BPF_EVENTS / CONFIG_CGROUP_BPF

# FnNAS 的网络栈（nftables + 配额 + 文件监控）
CONFIG_NF_TABLES / NF_TABLES_IPV4 / NF_TABLES_IPV6
CONFIG_NFT_NAT / NFT_MASQ / NFT_CT / NFT_COMPAT / NFT_HASH / NFT_LOG / NFT_LIMIT / NFT_QUOTA / NFT_REJECT
CONFIG_IP_NF_NAT / IP_NF_IPTABLES / IP_NF_FILTER
CONFIG_IP_NF_TARGET_MASQUERADE / IP_NF_TARGET_REDIRECT
CONFIG_NETFILTER_XT_TARGET_MASQUERADE / NETFILTER_XT_TARGET_REDIRECT
CONFIG_NETFILTER_XT_MATCH_STATE / CONNTRACK / MULTIPORT / PHYSDEV
CONFIG_BRIDGE_NETFILTER / CONFIG_VLAN_8021Q

# 文件系统与配额
CONFIG_BTRFS_FS / CONFIG_BTRFS_FS_DEVEL / CONFIG_BTRFS_FS_ZSTD / CONFIG_BTRFS_FS_XATTR
CONFIG_OVERLAY_FS / CONFIG_TMPFS_XATTR
CONFIG_FANOTIFY / CONFIG_FANOTIFY_ACCESS_PERMISSIONS
CONFIG_QUOTA / CONFIG_QUOTACTL
CONFIG_CIFS / CONFIG_NFS_FS / CONFIG_NFSD / CONFIG_9P_FS / CONFIG_USB_STORAGE

### 网络与文件服务

`CIFS`、`NFS_FS`、`NFSD`、`9P_FS`、`NETFILTER_XT_MATCH_CONNTRACK`

### Open vSwitch（Docker 的硬依赖）

```conf
CONFIG_OPENVSWITCH=y
CONFIG_OPENVSWITCH_COMPAT=y
CONFIG_NETFILTER_NETLINK=y
CONFIG_NF_CONNTRACK=y
CONFIG_BRIDGE=y
CONFIG_TUN=y
CONFIG_VSOCKETS=y
```

> 没有 `CONFIG_OPENVSWITCH` 时 `ovs-vswitchd` 会 FAILED，而 `docker.service` 依赖它 —— 表现为「Docker 装不上/起不来」。

---

## 四、我们踩过的坑（也是最有价值的部分）

### 1. kconfig 会静默丢弃非法符号

内核 6.1 里 `BTRFS_FS_ZSTD` **不需要显式设置**（三种压缩算法被 `CRYPTO` 无条件 select），但 `MD_RAID1` 在 6.1 就是这个名字（6.5 才改名）。

**教训**：改完配置必须

```bash
make olddefconfig
grep -E '^CONFIG_(BLK_DEV_DM|BLK_DEV_MD|MD_RAID1)=' .config   # 逐条确认
```

不能假设写进去就生效。对照 `kernel-6.1/drivers/md/Kconfig` 核实符号名是最稳的做法。

### 2. 增量编译会产生「坏 FIT」

增量编译后构建的 FIT 里 ITS 节点 `shr` 参数变成 `1`，u-boot 报 `shr 0→1`，**所有驱动失效**。

配置 diff 证明内核配置没问题，是构建产物不一致。**必须 `make clean` 后全量重编。**

### 3. 内核 / 模块 / rootfs 必须同批编译

模块 ABI 不匹配时，WiFi 驱动一加载就 panic：

```
8852bs: collect_bss_info ... __memcpy ... Kernel panic
```

每次内核重编后都要：

```bash
make modules
make modules_install INSTALL_MOD_PATH=<rootfs 目录>
```

### 4. `make clean` 会连带清掉 dtb 和 resource.img

两者都要单独处理：

- **DTB**：`make dtbs`，产物在 `arch/arm64/boot/dts/rockchip/rk3568-alientek-panfrost-hdmi.dtb`
- **resource.img**：`make clean` 后只能从上一版 FIT 里按索引 2 抽出来
  ```bash
  u-boot/tools/dumpimage -i boot-gz.img -T flat_dt -p 2 -o resource.img resource
  ```
  抽出来的 sha256 必须与 FIT 里记录的 `13866fed...2c3c641` 一致

### 5. ext4 必须带 journal，且必须 mask `resize-rootfs`

这是最隐蔽也最致命的一个坑。早期版本用**无 journal** 的 ext4，FnNAS 一跑起来就：

```
[7.699358] EXT4-fs error (device mmcblk0p6): ext4_mb_clear_bb:
           Filesystem failed CRC
[FAILED] Failed to start postgresql@15-main.service
```

而 FnNAS 自带的 `/usr/trim/bin/resize-rootfs.sh`（ophub/fnnas 的 `fnnas-tf`）**每次开机都会主动改写文件系统元数据**，等于雪上加霜。

**最终方案**：

```bash
mkfs.ext4 -F -m 0 -I 256 -O ^dir_index -J size=64 ...   # 带 64MB journal
ln -sf /dev/null /etc/systemd/system/resize-rootfs.service   # mask 掉
sed -i 's/^rootfs_limit_gib=.*/rootfs_limit_gib="128"/' /etc/fnnas.conf
```

### 6. `umount -l`（惰性卸载）会留下脏标志

懒卸载不会真正同步超级块，`Filesystem state` 不会回到 `clean`，下次挂载就报 `mounting unchecked filesystem`。**脚本里一律用 `sync` + 普通 `umount`。**

### 7. PowerShell 会吞掉 shell 元字符

`$(...)`、heredoc、反斜杠、`2>&1`、`<` 重定向在 `bash -lc "..."` 里会被 PowerShell 先解析掉，导致命令静默失败。

**本项目所有 WSL 命令都写成独立 `.sh` 文件再执行**，这是硬性约定。

### 8. `is_dev_disk()` 的前缀白名单

逆向 `libndev.so` 得到的判定逻辑：

```c
bool is_dev_disk(const char *name) {
    if (name[0]=='s' && name[1]=='d')    return true;   // sd
    if (strncmp(name, "nvme", 4) == 0)    return true;   // nvme
    if (name[0]=='h' && name[1]=='d')    return true;   // hd
    if (name[0]=='v' && name[1]=='d')    return true;   // vd (virtio)
    if (name[0]=='m' && name[1]=='m' && name[2]=='c') return true; // mmc
    return false;
}
bool is_dev_diskmapper(const char *name) { return name[0]=='d'&&name[1]=='m'&&name[2]=='-'; }
```

以及「系统盘剩余空间」的分区号算法：

```c
int get_sys_disk_free_space_partno() {
    static int partno = 0;
    if (partno > 0) return partno + 1;
    string s = get_mount_dev("/");          // → "/dev/mmcblk0p6"
    partno = get_partition_number(s.c_str()); // → 6
    return partno + 1;                        // → 7
}
```

### 9. 我自己犯的八个错（全部有代价）

这一节记录的是**我自己在这次适配里犯的低级错误**，不是 FnNAS/正点原厂的问题。它们的共同点是：症状出现在很远的地方，根因在很近的地方。

**① 改 `parameter.txt` 把 `rootfs` 改成 `-@0x00078000(rootfs)` → 刷完板子直接失联**

`-` 语法在厂商文件里只用于 `userdata:grow`，RKDevTool 对 rootfs 这个位置不按同样方式建表。**改厂商分区描述符是高危操作**，本项目最终选择：一个字节都不动，分区手术放到开机脚本里做。

**② `make olddefconfig` 忘了 `export ARCH=arm64` → `.config` 被重生成成 x86_64**

```bash
# 错：
make olddefconfig
# 对：
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make olddefconfig
```
Rockchip SDK 的内核 Makefile 靠环境变量判断架构，漏了就会按宿主机的 x86_64 重新生成配置，编出来的东西能过编译但完全不是 ARM。

**③ 构建脚本里路径写错 → 差点把上一版旧镜像当新版交付**

`rm -f "$B/../out/..."` 里的相对路径基于 `$B` 而不是脚本位置，实际没删掉旧文件，后续步骤把旧镜像重新打包了一份。**教训：清理产物要用绝对路径，并在打包后强制比对时间戳和 md5。**

**④ shim 脚本里构建期路径和运行时路径混用 → 兼容层静默失效**

`install_compat` 里写 `$D$orig`（构建期的 rootfs 暂存目录）还是 `$orig`（运行时真实路径），两个概念混在一行里。结果是 shim 文件写到了错误位置，**软链指向空文件，脚本 exit 127 被 FnNAS 当成「命令失败」，表现成「加了兼容层但完全没变化」**。

> **硬性约定**：`$D` 前缀只能出现在构建期路径，运行时路径一个都不能带。

**⑤ shim 里用 `command -v umount` 兜底 → 无限 fork，板子进程耗尽**

`/bin` 是 `/usr/bin` 的软链，`command -v umount` 在 PATH 里**先命中 shim 自己**，于是 shim 递归调用自己，进程表瞬间打满，板子彻底失去响应。

> **硬性约定**：写 shim 时**参数空间必须整个覆盖**，不能用「找不到就 fallback 到同名命令」这种写法。

**⑥ `umount` shim 没防无参调用 → util-linux 无参 umount 给全系统发 `SIGUSR1`**

util-linux 的 `umount` 在**不传任何参数**时不是打印用法，而是**给除自己以外的所有进程发送 `SIGUSR1`**（提醒它们卸载了文件系统）。FnNAS 有一个周期性调用是无参的，于是所有服务被 `SIGUSR1` 打断、循环重启，表现为「Web 时通时断、进程数忽高忽低」。

正确写法：

```bash
# 无参直接返回 0，什么都不做
if [ $# -eq 0 ]; then exit 0; fi
```

**⑦（附带）`fuser -km /vol1` 把 FnNAS 服务全杀了**

这条不是镜像问题，是我在实机验证时犯的。FnNAS 各服务的 cwd 都在 `/vol1` 下（用户 home、缩略图目录），`fuser -km` 一次性干掉了 PostgreSQL、imagesrv、mediasrv、rpc_broker 等几十个进程，SSH 也被踢掉。

> **硬性约定**：在 FnNAS 上做「卸载后重挂」这类验证，**绝不能用 `fuser -km`**。先停掉依赖服务，或改用 `umount` + 单独杀持有者 PID 的方式。

**⑧ systemd `oneshot` + `RemainAfterExit=yes` 配 timer 等于没有 timer**

服务跑完一次后停在 `active (exited)`，定时器再触发也不会重跑。现象极具迷惑性：`systemctl list-timers` 显示一切正常、`systemctl is-active` 也是 active，但功能就是不工作。

> **硬性约定**：oneshot + timer 就**不要**加 `RemainAfterExit=yes`。

---

## 五、已解决的问题

| 现象 | 根因 | 解法 |
|---|---|---|
| 刷完进 MASKROM、串口无输出 | 自制裸 GPT 镜像布局不被 next-dev u-boot 识别 | 改用厂商 `update.img` 原位替换两段 |
| `Unable to mount root fs (179,6) error -30` | 内核无 btrfs 却要挂 btrfs rootfs | 改用 ext4（走已验证的写入路径） |
| 进 emergency mode | `fstab` 的 `/boot` 条目引用不存在的 UUID | 删除该条目，根分区改用 `PARTUUID` |
| `serial-getty@ttyAMA0` 白等 90 秒 | 板子是 PL330（`ttyFIQ0`）不是 AMBA | 改挂 `ttyFIQ0`，波特率列表加 `1500000` |
| ext4 只剩 18MB，ovsdb/containerd/postgresql 起不来 | rootfs 太大 | 两轮裁剪共省约 1.9GB；inode 改 256 字节 |
| `ovs-vswitchd` FAILED → Docker 依赖断 | 内核缺 `CONFIG_OPENVSWITCH` | 加配置后全量重编 |
| ITS `shr 0→1`、驱动全瘫 | 增量编译产物不一致 | `make clean` 全量重编 |
| WiFi `8852bs` panic | 模块与内核不同批编译 | `make modules` + `modules_install` 同步 160 个模块 |
| `EXT4-fs error: Filesystem failed CRC` → postgresql 挂 | 无 journal + `resize-rootfs` 破坏元数据 | 加 64MB journal + mask 该服务 |
| `dmsetup` 报 `open failed: No such device` | 内核无 device-mapper | 打开 `CONFIG_BLK_DEV_DM` |
| mdadm / LVM 全部不可用 | 内核无 MD | 打开 `CONFIG_BLK_DEV_MD` + RAID0/1/10 |
| eMMC 剩 41GB 无法使用 | 厂商 `parameter.txt` 把 `oem`+`userdata` 铺满 | 开机脚本删 p7/p8、p6 扩到盘尾、`resize2fs` 撑满 |
| 创建存储空间报「暂无可用硬盘」 | 内核无 DM/MD，FnNAS 探测不到任何堆叠设备 | 打开 `CONFIG_BLK_DEV_DM` / `CONFIG_BLK_DEV_MD` 全家桶 |
| 创建存储空间探测 ZFS 失败 | 原厂内核编了 out-of-tree ZFS，重编编不出来 | `zpool`/`zfs` 兼容层 shim |
| `mdadm: --bitmap=lockless 不被支持` | mdadm 4.5 拒绝旧参数 | `mdadm` 兼容层 shim 剔除该参数 |
| eMMC 健康检查不过，不让建存储空间 | `/dev/mmcblk0: Unable to detect device type, rc=1` | `smartctl` 兼容层 shim |
| 点「去挂载」报 196616「挂载点已存在」 | 原厂 `triminitd` 开机自动挂载报 `unable to find record`，卷从未挂上 | 见下方「挂载点已存在」的完整拆解 |
| Docker 起容器失败（cgroup v2 无 device 控制器） | 内核无 BPF | 打开 `CONFIG_BPF_SYSCALL` + `BPF_JIT` + `BPF_EVENTS` |
| Docker 数据写在 eMMC 上 | `dockermgr` 不会把 `data-root` 写进 `daemon.json` | `fnnas-dockerd.sh` 包装器在 dockerd 启动前合并写入 |

### 存储空间：七步故障链（每一步都有实机证据）

在 RK3568 上让 FnNAS 真正创建出一个可挂载的存储空间，依次踩了七个坑：

| # | 现象 | 根因 | 处理 |
|---|---|---|---|
| ① | `zpool status` 探测失败，存储空间建不出来 | 内核无 ZFS（out-of-tree，SDK 编不出） | `zpool`/`zfs` shim，无池时返回 `{"pools":{}}` rc=0 |
| ② | `mdadm --create ... --bitmap=lockless` 被拒 | mdadm 4.5 移除该参数 | `mdadm` shim 剔除 `--bitmap=lockless` |
| ③ | 提示「硬盘健康检查未通过」 | `smartctl` 认不出 eMMC：`Unable to detect device type, rc=1` | `smartctl` shim：eMMC 返回 `smart_support.available=false` + `smart_status.passed=true`，nvme/sd 原样透传 |
| ④ | 挂载预清理阶段直接中止 | `umount` 在「本来没挂载」时返回非 0，被当致命错误 | `umount` shim 返回 0；**无参调用直接 exit 0**（见坑 11） |
| ⑤ | 每次失败留下 `/vol00` 空壳，下次直接报「挂载点已存在」 | 失败回滚不干净 | 清理 `/vol00` |
| ⑥ | Docker 起容器报 cgroup 相关错误 | 内核无 BPF，cgroup v2 没有 device 控制器 | `CONFIG_BPF_SYSCALL` |
| ⑦ | 卷建出来了但永远「未挂载」 | 原厂 `triminitd` 自动挂载失败（见下） | `fnnas-vol-mount.service` 自愈 |

成功后的实际设备栈：

```
nvme0n1 (931.5G, KIOXIA EXCERIA G2)
└─ nvme0n1p1   linux_raid_member
   └─ md127    raid1 (1/1)
      └─ trim_c31fedb1_7213_4324_99e1_a1bebb46a145-0   btrfs  → /vol1
```

### 「挂载点已存在」的完整拆解

这是最难的一个，报错码 `196616 = E_MOUNTPOINT_EXISTS`。

**排查手段**：板子上没有 strace/gdb，于是自己编了一个 `LD_PRELOAD` 探针（`libfnnastrace.so`），hook `popen/system/stat/lstat/statx/fstatat/realpath/mkdir/open/openat/access/mount/umount2/setmntent/opendir`，只记录路径里含 `vol` / `trim_` / `dm-` / `nvme` 的调用。

**第一手现场**：

```
[trim] [1]/dev/nvme0n1
[trim] [2]/vol00/KIOXIA-EXCERIA G2 SSD
[trim] popen_read2: WEXITSTATUS=12, mount ]]
```

—— FnNAS 在开机时执行的是 `mount /dev/nvme0n1 /vol00/...`，把**整块盘**往**可移动磁盘目录**里塞。

**继续反查关键函数**（`storage.hdl` / `triminitd` / `libndev.so`）：

- `storage.hdl` 是 `ELF 64-bit LSB shared object, ARM aarch64, not stripped`
- `init_mount_cache()` 读的是 **`/etc/mtab`**（不是 `/proc/mounts`，本机 `/etc/mtab -> /proc/self/mounts`）
- `find_mount_info_by_mount_point()` → `util::is_same_inode()` → `is_same_inode_by_realpath()`：先 `realpath()` 比字符串，任一路径不存在就返回 false
- `req_mount_disk()` 收的字段是 **`disk`**（设备），op=2 → `removable_disk_mount()` —— 那是**可移动磁盘**通道，不是存储空间通道
- 存储空间真正的入口是 **`req_remount_storage({uuid, comment})`** → op=23 → **`stor_mount(reqid, uuid, path, out)`**
- `triminitd` 的开机自动挂载逻辑最清楚：

```sql
SELECT id,uuid,pool_type from mount WHERE id<>0 and id is NOT NULL
UPDATE mount SET uuid=$1 WHERE uuid=$2
SELECT id,sync_speed_min,sync_speed_max,stripe_cache_size from mount WHERE uuid=$1
```

**结论 —— FnNAS 的挂载点约定**：

> 挂载点 = **`/vol` + `mount` 表的 `id`**；`id = 0` 是系统卷（对应目录 `/vol00`，也就是可移动磁盘的根），用户存储卷从 `id = 1` → `/vol1` 开始。
> 设备 = `/dev/mapper/<mount.uuid>`（即 LVM LV 名）。

本机 `id=1`，所以卷应该挂在 **`/vol1`**；而 `/vol1` 从来不存在。原厂 `triminitd::mount_storage()` 在这台板子上直接失败：

```
/usr/trim/logs/triminit.log:
  [E] unable to find record for /dev/dm-0 uuid:trim_c31fedb1_7213_4324_99e1_a1bebb46a145-0
```

于是 Web 上点「去挂载」永远失败。

**解法**：按 FnNAS 自己的约定补挂载，并做成开机 + 每 60 秒的自愈。

```bash
# /usr/local/sbin/fnnas-vol-mount.sh
# 1) 等 PostgreSQL / LVM 就绪，必要时 mdadm --run 拉起 md
# 2) SELECT id||'|'||uuid FROM mount WHERE id<>0     —— 拿不到就用上次成功的缓存
# 3) 对每条记录：mkdir /vol<id>; mount /dev/mapper/<uuid> /vol<id>
# 4) 挂上后 try-restart trim_main，让它重建挂载缓存（init_mount_cache 读 /etc/mtab）
```

配套 `fnnas-vol-mount.service` + `.timer`（`OnBootSec=120s`、`OnUnitActiveSec=60s`）。

> ⚠️ **oneshot + `RemainAfterExit=yes` 配 timer 是无效的**：服务跑一次后永久保持 `active (exited)`，定时器再也拉不动它。这个坑踩过一次，表现是「定时器明明 active 却从没触发」。

验证：挂上 `/vol1` 后，FnNAS 立刻在卷上自动建出了用户目录 `/vol1/1000`、`/vol1/thumb`、`/vol1/@timemachine`，探针里也能看到 `realpath /vol1 -> /vol1` 被反复命中 —— 说明 FnNAS 侧已经完全认得这个卷。

### 整盘占用的实现

厂商 `parameter.txt` 的 `mtdparts` 是：

```
...0x02000000@0x00078000(rootfs),0x00040000@0x02078000(oem),-@0x020B8000(userdata:grow)
```

`oem`(128MiB) 和 `userdata`(41.3GiB) 是 Android 遗留，Ubuntu 根本不用。

> ⚠️ **踩坑警告**：曾经尝试把 `rootfs` 改成 `-@0x00078000(rootfs)`（`-` 表示延伸到盘尾）想让 RKDevTool 直接建好整盘分区，**刷完板子直接失联**。`-` 语法在厂商文件里只用于 `userdata:grow`，RKDevTool 对 rootfs 这个位置未必按同样方式建表。

**最终采用的稳妥方案**：`parameter.txt` **一个字节都不动**，分区手术放到开机脚本里做，且全程可观测、可回退。

```bash
# /usr/local/sbin/fnnas-grow-rootfs.sh（随镜像预置）
# 1) 删除根分区之后的所有分区 —— 但只删「未挂载且无 holder」的
# 2) parted resizepart <根分区号> 100%
# 3) 在线 resize2fs（ext4 带 journal，安全）
# 每一步失败立即停止，不做后续破坏性操作
# 全部日志写入 /var/log/fnnas-grow-rootfs.log
```

对应 systemd 单元 `fnnas-grow-rootfs.service`，在 `resmon_service` / `sysinfo_service` 之前执行。

---

## 六、遗留问题与边界

### 1. 存储空间只能建在真实块设备上（已绕开）🟡

`is_dev_disk()` 的白名单只有 `sd`/`nvme`/`hd`/`vd`/`mmc` 五个前缀（见第四节坑 8）。所以**在 eMMC 上凭空造不出「独立硬盘」** —— dm-linear、loop 伪装都不行，根因是 **dm 设备和 loop 设备都没有 `/sys/block/<dev>/device/` 目录**，而 `mmcblk0` / `mmcblk0boot0` 有。

**现状**：M.2 槽的 NVMe SSD（`nvme0n1`）前缀命中白名单，FnNAS 能正常识别为硬盘，创建存储空间 → 挂载 → 建共享 → 跑容器**全部实测通过**。eMMC 只作系统盘，整块 64GB 通过开机扩容脚本占满。

**如果板子上没有 NVMe**：插一块 USB 移动硬盘 / U 盘 / USB-SATA 盒子里的 SSD，同样可用。

### 2. 在线更新不可用 🔴

「系统设置 → 更新和还原」列出的更新包是：

```
linux-image-6.18.18.c1145-trim   34.26M
内核版本升级至 6.18.18 #1145
```

**6.18 是飞牛官方基于 Debian 的 x86_64 内核**，我们跑的是正点原厂 ARM64 6.1.141。更新服务器按设备 ID 下发，我们的设备 ID 不是飞牛注册的整机型号，所以只能拿到通用 x86 包。

**⚠️ 不要点击「立即更新」。** 飞牛更新是一体化打包，会连带处理引导链；我们这套是 u-boot 直接从 `boot` 分区读 FIT，没有 grub。一旦它按 x86 的方式写引导，板子就起不来了。

**同步飞牛版本的正确做法**：用 [ophub/fnnas](https://github.com/ophub/fnnas) 的重建工具 —— 拉取新版 FnNAS rootfs 构件、替换用户空间、重新生成镜像，**内核保持自编的 6.1.141 不动**。

### 3. 串口 console 未验证 ⚠️

固件侧配置是正确的（`serial-getty@ttyFIQ0`，波特率列表含 `1500000`，UART2 = GPIO0_D0/D1），但**实测整个会话期间串口都是 0 字节**，包括系统正常运行、SSH 可用的时候。

> 如果只是波特率不对，应该收到**乱码**而不是 **0 字节**。0 字节说明信号根本没到 CH340 —— 大概率是接线问题（TX/RX 接反、没共地、接错排针）。

**自测方法**：把 CH340 模块的 TXD 和 RXD 短接，做回环测试，能读到就说明 PC 侧没问题，锅在接线。

板载 UART 是 **UART2**：`GPIO0_D0 = RX`、`GPIO0_D1 = TX`（pinctrl `uart2m0_xfer`），CH340 在板上以 3.3V TTL 连出。

### 4. 硬件扩展限制 ⚠️

- **没有 PCIe**：`/sys/bus/pci/devices/` 为空，`pcie-rkep` 未加载 → **M.2 NVMe 不可用**
- **USB 3.0 主机口 × 2**（5Gbps xHCI + DWC3）→ 这是唯一可行的外接存储途径
- 运行内存仅 4GB

### 5. Docker 数据目录自动跟随存储卷 ✅

`dockermgr` 每次启动都会按 `dockermgr.conf` 重写 `/etc/docker/daemon.json`，但**它不会把 `data-root` 写进去** —— 在 `dockermgr.conf` 里填了也不生效。

因此加了启动包装器 `/usr/local/sbin/fnnas-dockerd.sh`（通过 `docker.service.d/10-fnnas-datadir.conf` 接管 `ExecStart`）：启动前检测有没有挂载在 `/volN` 的**独立文件系统**，有就把 `data-root` 合并写进 `daemon.json`（保留 dockermgr 写的其他键），并同步回 `dockermgr.conf` 让 Web 界面显示正确。

> ⚠️ 两个坑：
> ① dockerd **不允许** `data-root` 同时出现在命令行和 `daemon.json`，会直接退出 1（`the following directives are specified both as a flag and in the configuration file`）。所以只能改配置文件，不能加命令行参数。
> ② `dockermgr` 会覆盖 `daemon.json`，所以包装器必须在**每次** dockerd 启动前重写，不能只在构建时写一次。

没有存储卷时自动回落到 `/var/lib/docker`，行为与原来一致。

### 6. `fnnas-tf` 行为变化 ⚠️

我们已经把整块 eMMC 并入 `/`，并把 `rootfs_limit_gib` 调到 128。ophub 的 `fnnas-tf` 在这种布局下的行为与原本设计不同，后续若要重新分区需要注意。

---

## 七、环境与工具链

| 组件 | 版本 |
|---|---|
| 主机 | Windows + WSL2 Ubuntu 24.04 |
| SDK | `atk_dlrk3568_linux6.1`（正点原子官方） |
| 交叉编译器 | `aarch64-linux-gnu-gcc 13.3.0 (Ubuntu 13.3.0)` |
| 内核 | Linux 6.1.141 |
| u-boot | `next-dev-g83b0a16 #alientek (Aug 27 2026)` |
| FnNAS | fnOS 1.2.0701（厂商 ARM 用户空间，原样沿用） |
| RKDevTool | v3.37 for Windows |

### 关键产物尺寸

| 产物 | 大小 |
|---|---|
| `Image` | 46,635,520 字节 |
| `Image.gz` | 16,863,833 字节 |
| `rk3568-alientek-panfrost-hdmi.dtb` | 179,535 字节（sha256 `264c6fd1...736e1`） |
| `boot-gz.img`（external FIT） | 18,189,312 字节（槽位上限 40,579,584） |
| `rootfs-ext4.img` | 3,577,741,312 字节（槽位上限 3,577,741,312，**刚好占满**） |
| 最终镜像 | 3,694,707,274 字节 |
| 内核模块 | 160 个 |
| `MiniLoaderAll.bin` | 481,728 字节 |

---

## 八、构建流程

```
fnnas.config 合并
      ↓
make clean && make Image && make modules     ← 必须全量，且与 rootfs 同批
      ↓
make dtbs                                    ← make clean 会清掉，必须单独编
      ↓
gzip -9 Image → Image.gz
      ↓
mkimage -f boot-gz.its -E -p 0x800 boot-gz.img
      ↓
裁剪 FnNAS rootfs（两轮，约省 1.9GB）
      ↓
修 fstab / 串口 getty / mask resize-rootfs
      ↓
安装 fnnas-grow-rootfs.service（整块 eMMC 并入 /）
      ↓
安装 5 层 FnNAS 兼容层 + fnnas-docker-heal.service
      ↓
安装 fnnas-vol-mount.{service,timer} + fnnas-dockerd.sh
      ↓
make modules_install（160 个模块，与内核同批）
      ↓
mkfs.ext4 -I 256 -O ^dir_index -J size=64
      ↓
e2fsck -f -D
      ↓
原位替换 update.img 的 boot.img + rootfs.img 两段
      ↓
分段 md5 校验（确认差异只落在预期区域）
```

### 校验方法

打包后逐段比对，确认只有三处与厂商原镜像不同：

```
[0x00000000, +485926 )            相同   ← RKAF 头 + 引导区
[0x004F9226, +18189312)           不同   ← boot.img
[0x05B8C226, +3577741312)         不同   ← rootfs.img
```

---

## 九、刷机步骤

1. **关闭并重新打开 RKDevTool**（必须，否则会用缓存里的旧镜像）
2. **拔掉 TF/SD 卡**（SPL 优先枚举 MMC2，插着会抢启动顺序）
3. 「升级固件」页 → 选择 `fnnas_ATK-DLRK3568_FnNAS-v2_2026.10.18.img` → 升级
4. **断电重新上电**（不能只看 RKDevTool 提示）
5. 网线插 **`end1`**（不是 `end0`）
6. 浏览器访问 `http://<板子IP>:5666`

> ⚠️ 板子上 `/home/<user>/.ssh/` 在每次刷机后都会被冲掉，需要重新安装公钥或改用串口。

### 首次验证

**基础**

```bash
df -h /                                   # 应显示 ~57G
cat /var/log/fnnas-grow-rootfs.log        # 应看到 删p7/删p8/扩到100%/resize2fs 完成
systemctl is-active fnnas-grow-rootfs     # active
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT /dev/mmcblk0   # 应只剩 p1~p6
systemctl is-active fnnas-docker-heal     # active
```

**存储空间（插了 M.2 NVMe 的情况下）**

Web → 存储空间 → 创建存储空间 → 选 NVMe → Basic / RAID1 → 确认。
建完之后**不需要**做任何手工操作：

```bash
systemctl is-active fnnas-vol-mount.timer       # active
tail -20 /var/log/fnnas-vol-mount.log          # 应看到 "挂载成功 -> /vol1 (btrfs)"
findmnt -o TARGET,SOURCE,FSTYPE | grep /vol     # /vol1  /dev/mapper/trim_xxx  btrfs
ls /vol1                                       # 应出现 1000 / thumb / @timemachine
```

**Docker**

```bash
docker info | grep 'Docker Root Dir'           # 应为 /vol1/docker
docker run --rm hello-world                    # 应打印 Hello from Docker!
docker compose version                         # v2.x
```

---

## 十、镜像内新增的 systemd 组件

| 组件 | 作用 |
|---|---|
| `fnnas-grow-rootfs.service` | 删掉根分区之后的 Android 遗留分区，把 `/` 扩到整块 eMMC 末尾并 `resize2fs` |
| `fnnas-docker-heal.service` | 开机检查 5 个 Docker 文件，缺失就从 xz 备份恢复 |
| `fnnas-vol-mount.service` + `.timer` | 按 FnNAS 约定把存储卷挂到 `/vol<id>`，开机 + 每 60 秒自愈 |
| `fnnas-dockerd.sh` + `docker.service.d/10-fnnas-datadir.conf` | 把 Docker `data-root` 指向存储卷 |
| `fnnas-unfix.sh` | 一键撤销全部兼容层与自愈（还原成原厂行为） |

**日志位置**：`/var/log/fnnas-grow-rootfs.log`、`/var/log/fnnas-docker-heal.log`、`/var/log/fnnas-vol-mount.log`

### 本仓库目录结构

```
.
├── hdmi_ubuntu26.04.1_update.img        # 正点原厂镜像（只读参照）
├── out/
│   ├── fnnas_ATK-DLRK3568_FnNAS-v2_2026.10.18.img   # ★ 成品（3,694,707,274 字节）
│   │                                                  #   md5 78386d6e9321b81dfa3108e190607fc0
│   ├── fnnas_ATK-DLRK3568_FnNAS-v1_2026.10.18.img   # 上一版（无存储卷自愈）
│   ├── MiniLoaderAll.bin                             # MASKROM 救砖用
│   └── uboot.img                                     # 厂商 u-boot（参考）
├── kernel/
│   └── fnnas.config                     # 内核配置片段（129 行 CONFIG）
└── build/                               # 构建与诊断脚本
    ├── 87-rebuild-rootfs-final.sh        # rootfs 构建主脚本
    ├── 89-diag-shell-image.sh           # 原位替换打包
    ├── 90-verify-final-image.sh         # 分段校验
    └── 95-build-all-dm-md.sh            # 一键全流程
```

---

## 十一、致谢与参考

- **正点原子 ATK-DLRK3568** —— RK3568 开发板与官方 SDK
- **[ophub/fnnas](https://github.com/ophub/fnnas)** —— FnNAS 社区维护工具链，`resize-rootfs.sh`(=`fnnas-tf`) 与镜像重建流程的主要参考
- **[ophub/kernel](https://github.com/ophub/kernel)** —— RK3568 等平台的 prebuilt 内核与 rootfs 构件
- **飞牛私有云 FnNAS** —— 用户空间与 Web 界面

---

## 十二、如果你想继续推进

按投入产出排序：

1. **修串口接线** —— 串口是救砖时唯一的救命通道，值得花十分钟验证（TX/RX 短接做回环测试最快定位）
2. **搭 ophub 重建流水线** —— 实现飞牛版本跟进，这是长期维护的关键
3. **让 FnNAS 原生「去挂载」按钮可用** —— 目前靠 `fnnas-vol-mount.timer` 每 60 秒兜底。`stor_mount()` 内部对挂载点的具体校验分支还没追到底，值得继续逆 `storage.hdl`
4. **串口 getty 与 FnNAS 系统日志打通** —— 目前只能靠 SSH 抓 `journalctl` 和 `/usr/trim/logs/`，有个串口会方便很多
