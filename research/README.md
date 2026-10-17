# 研究笔记：FnNAS 存储子系统逆向

这个目录是我为了搞清楚「为什么 FnNAS 不肯用 eMMC 上的空间做存储空间」而做的一些逆向工具和结论汇总。
**不是构建镜像所必需的**，放这里是为了给后来者省时间。

## 逆向对象

| 文件 | 说明 |
|---|---|
| `/usr/trim/bin/handlers/storage.hdl` | 存储子系统主体（ARM64 ELF，未 strip） |
| `/usr/trim/lib/libndev.so` | 块设备判定库（`is_dev_disk` 等函数的实现处） |
| `/usr/trim/bin/handlers/device_watch.hdl` | 热插拔监听 |

## 关键结论

### 1. `is_dev_disk()` 的前缀白名单

在 `libndev.so` 的 `0xad60`，逐指令还原：

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

`dm-*` 和 `loop*` 都不在前缀白名单里 —— 这是「用 dm-linear 把 eMMC 尾部伪装成独立盘」失败的直接原因。

### 2. 「系统盘剩余空间」的分区号算法

`libndev.so` 的 `0xaaa0`，`get_sys_disk_free_space_partno()`：

```c
int get_sys_disk_free_space_partno() {
    static int partno = 0;
    if (partno > 0) return partno + 1;          // 缓存
    string s = get_mount_dev("/");              // → "/dev/mmcblk0p6"
    partno = get_partition_number(s.c_str());   // → 6
    return partno + 1;                          // → 7
}
```

即：**期望的剩余空间分区号 = 挂载 `/` 的分区号 + 1**。

### 3. 它怎么读容量

`storage.hdl` 的 `0x391b4` 附近：

```c
get_disk_partprefix(dev);                       // → "mmcblk0p"（完整前缀，不是 "p"）
int fp = get_sys_disk_free_space_partno();      // → 7
snprintf(buf,  128, "%s%d", partprefix, fp);                    // "mmcblk0p7"
snprintf(buf2, 512, "/sys/block/%s/%s/size", dev, buf);        // sysfs 路径
if (access(buf2, F_OK) != 0) goto fallback;    // 读不到就退回读 p(7-1)=6
get_file_text(buf2, &s, 15);
start = strtoll(s) << 9;
```

**注意：`get_disk_partprefix()` 返回的是完整分区名前缀 `mmcblk0p` 而不是 `p`。** 这点是从 strace 实际抓到的路径 `/sys/block/mmcblk0/mmcblk0p7/size` 反推确认的。

### 4. strace 实测：p7 确实被正确识别

```
faccessat("/sys/block/mmcblk0/mmcblk0p7", F_OK)      = 0
openat("/sys/block/mmcblk0/mmcblk0p7/size")         = 64
statx("/dev/mmcblk0p7")                             = 0
statfs("/")                                         = 0
faccessat("/sys/block/mmcblk0/md/array_state")      = -1 ENOENT
```

**它找到了 p7、读到了 size、继续往下走**，但最终 UI 仍然报「暂无可用硬盘」。

### 5. gdb 断点：判定分支一次没命中

在 `list_block_device()`（`storage.hdl` 的 `0x37314`）内下断点：

| 地址 | 用途 | 结果 |
|---|---|---|
| `0x39218` | `access()` 结果分支 | ❌ 未命中 |
| `0x39244` | 构建 JSON 条目前 | ❌ 未命中 |
| `0x396fc` | `strcasecmp` | ✅ 命中（`A=""`、`B="ext4"`） |
| `0x397dc` | `strcmp` | ✅ 命中（`A="SSD"`、`B="zpool"`） |
| `stor_set_disk_info` | 磁盘信息组装 | ✅ 被反复调用 |

说明磁盘列表是由**多条代码路径拼出来的**，而我们需要的那条判定分支在当前调用路径上根本没走到。**这最后一道门禁至今没有定位到。**

## 结论

FnNAS 的存储空间**必须建立在带 `/sys/block/<dev>/device/` 的真实块设备上**（SCSI/USB/NVMe/MMC）。

对比证据：

```
mmcblk0       device/ = 有   ← FnNAS 列出
mmcblk0boot0  device/ = 有   ← FnNAS 列出
loop0~7       device/ = 无   ← 不列出
zram0         device/ = 无   ← 不列出
dm-0          device/ = 无   ← 不列出
```

**唯一可行的解：插 USB 硬盘。**

## 工具用法

```bash
# 1. 从板子上把二进制拉回本地
bash research/pull-bin.sh

# 2. 找出关键符号定义在哪个库
bash research/findlib2.sh

# 3. 全文搜索符号
bash research/symsearch.sh

# 4. 逐个反汇编（dis2 = is_dev_disk, dis5 = get_sys_disk_free_space_partno, dis8 = 判定分支）
bash research/dis2.sh
bash research/dis5.sh
bash research/dis8.sh

# 5. 精确还原 is_dev_disk 的机器码
bash research/libndev.sh
```

依赖：`aarch64-linux-gnu-objdump` / `-nm` / `-readelf`（SDK 自带），或在任意装了 `binutils-multiarch` 的 Linux 上。

## 如果你想继续

未攻克的那道判断在 `list_block_device()`（约 10KB 代码）内部。建议的下一步：

1. 给板子装 `gdb`，在 `access()` 之后的每一条条件分支上打断点
2. 用 `finish` 拿到返回值，而不是只看有没有命中
3. 重点关注 `strcasecmp(A="", B="ext4")` 里那个**空串 fstype** 是从哪来的 —— 那可能才是真正的拦路虎
