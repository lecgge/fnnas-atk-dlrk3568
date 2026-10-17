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
| 系统盘容量 | ✅ **56.39 GB**（整块 eMMC 已并入根分区） |
| device-mapper / LVM / mdadm | ✅ 内核已启用 |
| **FnNAS 存储空间（创建卷）** | ❌ **仍需外接 USB/NVMe 硬盘**，详见第五节 |
| **FnNAS 在线更新** | ❌ 架构不匹配，**切勿点击「立即更新」** |
| 串口 console | ⚠️ 固件侧已配置正确，但需自行确认接线 |

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

# 2026-10-17 追加 —— 见第四节「存储空间」章节
CONFIG_BLK_DEV_DM=y
CONFIG_DM_BUFIO / DM_BIO_PRISON / DM_SNAPSHOT / DM_THIN_PROVISIONING / DM_CRYPT
CONFIG_BLK_DEV_MD=y
CONFIG_MD_LINEAR / MD_RAID0 / MD_RAID1 / MD_RAID10
```

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

## 六、没有解决的问题（重要）

### 1. FnNAS 存储空间仍必须外接硬盘 🔴

这是投入最大、仍未攻克的问题。

**现象**：FnNAS「存储空间管理 → 创建存储空间」始终提示「当前暂无可用于创建存储空间的硬盘」。

**已经查明的**：

- `get_sys_disk_free_space_partno()` 期望的「系统盘剩余空间」分区号 = 根分区号 + 1 = **7**
- 它通过 `/sys/block/mmcblk0/mmcblk0p7/{start,size}` 读取容量，`access()` 失败才降级去读 p6
- strace 实测：**p7 被正确找到，size 成功读到**（`/sys/block/mmcblk0/mmcblk0p7/size` 打开成功、`statx("/dev/mmcblk0p7")` 返回 0）
- `stor_set_disk_info()` 被反复调用，说明 FnNAS 确实在组装磁盘信息
- **但在纯内存判断处被丢弃** —— gdb 下在 `list_block_device()` 的判定分支上设断点，一次都没命中

**结论**：`is_dev_disk()` 的白名单只有 `sd`/`nvme`/`hd`/`vd`/`mmc` 五个前缀。eMMC 上分出来的任何空间（含 dm-linear、loop 伪装）都不被当作独立硬盘。

**唯一可靠的解**：插一块 USB 移动硬盘 / U 盘 / USB-SATA 盒子里的 SSD。带 `/sys/block/<dev>/device/` 的真实块设备是 FnNAS 唯一认的类型，插上后 FnNAS 会识别成 `/dev/sda`，四种存储模式、应用中心、文件共享全部可用。

> 顺带一提：DTX 的 dm-linear 方案之所以失败，根本原因是 **dm 设备和 loop 设备都没有 `device/` 目录**，而 `mmcblk0`/`mmcblk0boot0` 有 —— 这条对比数据就是判定依据。

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

### 5. Docker 默认仍写系统盘 ⚠️

没有存储空间时 `/var/lib/docker` 仍在 56GB 系统盘里。容量够用但不理想，**存储空间建成后建议手动切过去**。

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
安装 fnnas-grow-rootfs.service
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
3. 「升级固件」页 → 选择 `fnnas_ATK-DLRK3568_FnNAS-grow_2026.10.17.img` → 升级
4. **断电重新上电**（不能只看 RKDevTool 提示）
5. 网线插 **`end1`**（不是 `end0`）
6. 浏览器访问 `http://<板子IP>:5666`

### 首次验证

```bash
df -h /                                   # 应显示 ~56G
cat /var/log/fnnas-grow-rootfs.log        # 应看到 删p7/删p8/扩到100%/resize2fs完成
systemctl is-active fnnas-grow-rootfs    # active
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT /dev/mmcblk0   # 应只剩 p1~p6
```

---

## 十、目录结构

```
.
├── hdmi_ubuntu26.04.1_update.img        # 正点原厂镜像（只读参照）
├── out/
│   ├── fnnas_ATK-DLRK3568_FnNAS-grow_2026.10.17.img   # ★ 成品
│   ├── MiniLoaderAll.bin                # MASKROM 救砖用
│   └── uboot.img                        # 厂商 u-boot（参考）
└── tools/                               # 构建与诊断脚本
```

> `out/` 目录里还留着开发过程中的历史镜像，可自行删除。

---

## 十一、致谢与参考

- **正点原子 ATK-DLRK3568** —— RK3568 开发板与官方 SDK
- **[ophub/fnnas](https://github.com/ophub/fnnas)** —— FnNAS 社区维护工具链，`resize-rootfs.sh`(=`fnnas-tf`) 与镜像重建流程的主要参考
- **[ophub/kernel](https://github.com/ophub/kernel)** —— RK3568 等平台的 prebuilt 内核与 rootfs 构件
- **飞牛私有云 FnNAS** —— 用户空间与 Web 界面

---

## 十二、如果你想继续推进

按投入产出排序：

1. **插一块 USB 硬盘** —— 最快解决存储空间问题，FnNAS 会直接识别 `/dev/sda`
2. **修串口接线** —— 串口是救砖时唯一的救命通道，值得花十分钟验证
3. **搭 ophub 重建流水线** —— 实现飞牛版本跟进，这是长期维护的关键
4. **继续逆向 `listFreeDisk`** —— 需要更深入地追 `list_block_device()` 里的 JSON 组装逻辑。strace + gdb + 符号表 + 反汇编的工具链已经就位（见 `tools/` 目录下的 `dis*.sh`、`pull-bin.sh`），但最终那道判断分支至今没有命中过

---

## 十三、镜像下载

GitHub Release 单个附件上限 **2 GB**，而本镜像是 3.5 GB，因此拆成两个分卷：

### 下载

从仓库的 **Releases** 页面下载这两个文件：

```
fnnas_ATK-DLRK3568_FnNAS-grow_2026.10.17.img.part0   1,847,353,637 字节
fnnas_ATK-DLRK3568_FnNAS-grow_2026.10.17.img.part1   1,847,353,637 字节
```

### 合并（Windows）

```powershell
# PowerShell
Get-Content part0, part1 -AsByteStream -ReadCount 0 | Set-Content fnnas.img -AsByteStream
# 或用 CMD
copy /b part0+part1 fnnas.img
```

### 合并（Linux / macOS）

```bash
cat fnnas_ATK-DLRK3568_FnNAS-grow_2026.10.17.img.part* > fnnas_ATK-DLRK3568_FnNAS-grow_2026.10.17.img
```

### 校验

```bash
md5sum    fnnas_ATK-DLRK3568_FnNAS-grow_2026.10.17.img
# 期望: 105bbbe34c62288413f28c2f00c04bbd
sha256sum fnnas_ATK-DLRK3568_FnNAS-grow_2026.10.17.img
```

### 自行构建

本镜像是**完全可复现**的 —— 所有构建脚本都在 `build/` 目录：

```bash
bash build/00-build-all.sh
```

详见 [构建说明](#七环境与工具链)。

> ⚠️ 构建需要正点原子官方 SDK 和一份原厂 `hdmi_ubuntu26.04.1_update.img`（含 FnNAS ARM 用户空间）。
> 该原厂镜像受正点原子版权保护，**不随本仓库分发**，请自行从正点原子渠道获取。

---

## 十四、仓库结构

```
.
├── README.md                    ← 本文档
├── LICENSE
├── .gitignore
├── docs/
│   └── porting-notes.md         ← 踩坑记录（见第四节）
├── kernel/
│   ├── fnnas.config             ← FnNAS 必需的内核配置片段
│   ├── dm-md-fragment.config    ← device-mapper / MD 片段
│   └── dm-md-only.config        ← 仅 DM/MD 部分（增量合并用）
├── build/                       ← 可复现构建流水线
│   ├── 00-build-all.sh          ← 一键构建
│   ├── 01-apply-kernel-config.sh
│   ├── 02-build-kernel.sh
│   ├── 03-build-dtb.sh
│   ├── 04-extract-resource.sh
│   ├── 05-build-rootfs.sh
│   ├── 06-pack-image.sh
│   └── 07-verify-image.sh
├── research/                    ← FnNAS 存储子系统逆向（非构建必需）
│   ├── README.md                ← 逆向结论与工具用法
│   └── *.sh
└── tools-serial/                ← 串口记录/诊断脚本（Windows）
```

## License

本仓库的**脚本与文档**以 [GPL-2.0](LICENSE) 发布（与 Linux 内核配置片段的许可保持一致）。

镜像中包含的正点原子原厂二进制（u-boot、DTB、resource.img、FnNAS 用户空间）
**版权归各自所有者所有**，本仓库仅作技术研究用途分发其二进制产物。
