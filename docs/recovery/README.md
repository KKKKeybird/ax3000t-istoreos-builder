# AX3000T 救机记录（汇总）

设备：小米 AX3000T / RD03，MT7981B，原厂 U-Boot（stock bootloader 布局），iStoreOS 24.10.8 / 内核 6.6.144
记录日期：2026-09-19

本目录汇总两次**实际发生并已解决**的启动故障。两份原始记录：

| 文件 | 内容 |
|---|---|
| [`AX3000T-救机操作文档.md`](AX3000T-救机操作文档.md) | 本次（9/19）完整操作记录：串口、U-Boot 菜单、TFTP、卷修复、验收清单 |
| [`AX3000T-恢复记录与关键点.md`](AX3000T-恢复记录与关键点.md) | 两种故障的对比、判别规则、TTL/TFTP 参数与操作细节 |
| [`ROOT-CAUSE-sysupgrade-rootfs.md`](ROOT-CAUSE-sysupgrade-rootfs.md) | **根因定因报告**：为什么 sysupgrade 会留下没有 rootfs 的状态，以及修复 |

> 两份文档中的 Windows 用户名已泛化为 `<user>`，其余内容保持原文。

---

## 1. 两次事故是**完全不同**的性质

| # | 故障 | 现象 | 正确处理 |
|---|---|---|---|
| ① | **错误的外部内核模块被开机自动加载** | 内核已启动，随后在加载 `.ko` / UU / 防火墙模块时 panic | 固件本体完好 → 从恢复系统挂载**原 overlay**，删掉错误模块与自动加载项 |
| ② | **`rootfs` 卷不在它该在的分区**（本次） | 启动失败、循环重启 | 必须 TTL 进 U-Boot → TFTP 启动恢复系统 → **重建卷** → `sysupgrade -n` 装回正式固件 |

**判别规则（先看串口，别猜灯色）：**

| 串口现象 | 故障层级 | 处理 |
|---|---|---|
| 内核已启动，加载 `.ko`/插件时 panic | overlay / 模块 | 挂载原 overlay 清理错误模块 |
| `Reading from volume 'kernel' ... size 0x0` 后 `Wrong Image Format` | 固件 / UBI 卷问题 | U-Boot 菜单 4 + TFTP，然后 `sysupgrade -n` |
| U-Boot 菜单都不出现，BL2/FIP 阶段报错 | 引导链 | 本文方案不适用，**不要**自行刷菜单 5/6 |

---

## 2. 本次故障的真实根因

> ⚠️ 这一条与事前的猜测**不一致**，是本轮最重要的更正。

事前怀疑是"`sysupgrade` 保留了旧 `/etc` 导致配置冲突"。**实际不是**，真正的原因是
**没有加 `-n` 导致 `/overlay` 未被卸载、`rootfs_data` 无法释放**，导致新 rootfs 放不下——
完整定因见 [`ROOT-CAUSE-sysupgrade-rootfs.md`](ROOT-CAUSE-sysupgrade-rootfs.md)。
（配置冲突只是次要风险，不是本次故障原因。）
串口 + 内存恢复系统调查出的现场状态是：

```text
Linux ubi0 -> mtd9 / ubi  (78 MiB)
  卷 1  rootfs_data   存在
  卷 0  rootfs        缺失        <-- 问题在这里

Linux ubi1 -> mtd8 / ubi_kernel  (34 MiB)
  卷 0  kernel        存在且有效
  卷 1  rootfs        内容有效，但位于错误的区域
```

也就是：**`sysupgrade` 之后，`rootfs` 卷没有落在 mtd9(`ubi`)，而是和 `kernel` 一起留在了 mtd8(`ubi_kernel`)。
Linux 只在 mtd9 找 `rootfs`，找不到 → 启动失败 → 看门狗复位 → 循环重启。**

这解释了三个现象：

- 橘灯慢闪（启动失败循环）
- 网口"可识别/不可识别"交替（重启循环中交换芯片与 PHY 被反复初始化）
- 反复按 Reset 无效（Reset 只能清 overlay，**不能凭空重建缺失的卷**）

### 修复动作（本次实际执行的，非通用脚本）

在内存恢复系统中：

```sh
# 1. 只读备份原数据分区，并把备份校验着落到电脑
mount -t ubifs -o ro /dev/ubi0_1 /mnt/saved
tar czf /tmp/saved-overlay.tgz -C /mnt/saved .
# 下载到电脑后用 Get-FileHash 复核一致，才继续

# 2. 核实源数据（必须与记录中的哈希完全一致才继续）
head -c 17582080 /dev/ubi1_1 > /tmp/rootfs-repair.bin
sha256sum /tmp/rootfs-repair.bin     # 期望 85de95ad…528407

# 3. 在正确的分区重建缺失的卷并写回
ubimkvol /dev/ubi0 -n 0 -N rootfs -s 17582080
ubiupdatevol /dev/ubi0_0 /tmp/rootfs-repair.bin
sync
head -c 17582080 /dev/ubi0_0 | sha256sum    # 读回必须与源一致

# 4. 重启
umount /mnt/saved; sync; reboot
```

**关键约束**：卷 ID 0 必须确认空闲；不能用删除现有卷的方式去凑命令；
写入后必须**按镜像原始长度读回比对哈希**（卷容量会按 LEB 向上取整，
不能对填充后的整卷求哈希）。

---

## 3. 当前状态（诚实记录）

✅ 已从闪存正常启动 iStoreOS 24.10.8 / 内核 6.6.144
✅ 原有可写数据分区保留，双频 `502` 与 `502-IoT` 恢复
✅ SSH、管理页、dnsmasq 正常，OpenClash 核心进程存在
✅ 管理地址 `http://192.168.100.1`

⚠️ **恢复的是此前可用的旧版本，不是 9/19 的新镜像**
⚠️ 验收时 WAN 未取得上游地址 → **外网、代理节点、UU 加速效果均未验证**
⚠️ 启动日志有 Ruby 内存申请失败提示（随后核心正常运行，约 114 秒时可用内存 ~53 MiB，未观察到 OOM 杀进程，仍需后续负载观察）
⚠️ 5 GHz 自动选到信道 52，有 60 秒 DFS CAC 等待后 `AP-ENABLED` —— **这段等待不是无线故障**

### 未决问题（不要当成已解决）

**普通 `sysupgrade` 路径为什么会留下"缺失 rootfs"的状态，尚未完整定位。**
救活一次 ≠ 升级缺陷已修复。再次升级前至少要做到：

1. 先备份当前完整配置、插件数据与关键分区，并**校验电脑端副本**
2. 查清升级脚本为何在 `Performing system upgrade...` 之后留下缺失 rootfs 的状态，**不要预设原因是旧配置**
3. 核对 sysupgrade 包里的 kernel/rootfs、目标 UBI 分区、内核模块 ABI 与 rootfs 工具是否**成套**
4. 区分 `initramfs-kernel.bin`、factory UBI 和 sysupgrade tar 包，**不要互相改名冒充格式**
5. 卷写入必须在内存升级环境里做，**不要在仍挂载使用的闪存根文件系统上**执行
6. 保持串口可用；写入后读回校验，重启后再确认配置持久化与网络

---

## 4. 铁律（踩过的坑）

| ❌ 不能再做 | 为什么 |
|---|---|
| 把 `size 0x0` 当成"内核为空"的铁证 | **成功启动时也出现过同样输出**；必须结合实际字节长度和 FIT 校验判断 |
| 认为 `ubi_kernel` 与 U-Boot 的 `ubi` 名字不同 ⇒ 启动槽一定错了 | 按**物理范围与容量**对照：本机两者指向**同一区域**（mtd8，34 MiB） |
| 认为 rootfs 放进 U-Boot 的 `ubi` 就够了 | 本机 Linux 从**另一段 78 MiB 的 `ubi`**（mtd9）找 rootfs |
| 镜像哈希通过 ⇒ 安装布局正确 | **数据完整性与写入位置必须分别验证** |
| 橙灯闪 ⇒ 插件冲突 | 无法证明。先分清 U-Boot / 内核 / 根文件系统 / 服务 四个阶段 |
| 反复按 Reset 碰运气 | 早期启动失败时无效；`rootfs` 缺失时更无效 |
| 看到一次网卡 Disconnected 就说网线没插好 | 重启循环会反复重置网口，要结合串口与持续链路观察 |
| 向带默认值的提示直接输入新 IP | 曾追加成无效地址（`192.168.10.1002`）。**先用 `Ctrl+U` 清空整行**，或改用 `setenv` |
| 对每个未知提示自动发 Enter | 可能接受错误文件或选项，必须识别每一级实际提示 |
| 用自写的简易 TFTP 一直重试 | 曾出现 **timeout OACK 协商不兼容**、**第 256 块附近重复 ACK**；改用成熟的 **Tftpd64 4.70** 后成功 |
| 串口命令文件偶尔被锁就退出整个监听器 | 应处理瞬时 IO 错误，或用已验证的单会话方式 |
| SSH 指纹变化就关闭所有校验 | 恢复系统与原系统主机密钥可能不同；应经串口确认，用任务专用 `known_hosts` |
| 无差别恢复旧 `/etc` | 脚本/插件文件可能与新镜像不匹配；**先保留数据、再检查兼容性** |
| 手工复制别处构建的 `.ko` | 见第 5 节，会直接 kernel panic |
| `opkg --force-depends` 强装内核模块 | 同上，包管理器报依赖不匹配时应**重新构建固件** |

---

## 5. 为什么内核模块必须来自同一次构建

OpenWrt/iStoreOS 的 kmod 不只是内核版本号要相同，**还必须匹配该次构建的内核配置与 ABI/hash**。
即使两边都显示 `6.6.144`，不同构建产出的模块也可能不兼容。

错误模块的后果不是"插件打不开"，而是**模块加载时直接 kernel panic → 整机循环重启**（这正是事故 ①）。

因此：

- 需要 `kmod-nft-compat`、`kmod-nf-ipt` 这类模块时，**加入同一次固件构建**
- **不要**从公网源、别的设备或别的固件里抽 `.ko` 塞进 `/lib/modules/`
- 包管理器报依赖不匹配 → **停下重新构建固件**，不要用 `--force-depends` 绕过

---

## 6. 连接与工具参数

| 项 | 值 |
|---|---|
| 串口 | `115200 8N1`，无流控；**只接 GND/TX/RX，不要接 3.3V/5V**，TX/RX 交叉、共地 |
| 串口编号 | 会变（9/15 是 COM4，9/19 是 COM5），**每次重新确认** |
| 路由器 U-Boot IP | `192.168.10.1/24` |
| 电脑 TFTP 地址 | `192.168.10.100/24`，不填网关和 DNS |
| 请求文件名 | `firmware_ubi.bin` |
| 网络 | **必须有线直连**；U-Boot 阶段没有 Wi-Fi |
| 推荐 TFTP 工具 | **Tftpd64 4.70**（自写实现有 OACK/ACK 兼容问题） |
| 截停自动启动 | 见 `Hit any key to stop autoboot` 时发 `Ctrl+C`；菜单退出后还有一层倒计时，再发一次，直到出现 `RD03>` |
| 升级菜单 | 选 **`4. Upgrade firmware`** |
| ⛔ 危险菜单 | **菜单 5（Upgrade ATF BL2）/ 菜单 6（Upgrade ATF FIP）绝对不能选**，会触碰引导链 |

电源：路由器用**原装电源**供电，不要用串口转接器的电源脚。

---

## 7. 最短恢复清单

1. 接 TTL（GND/TX/RX），确认 COM 号，`115200 8N1`
2. 电脑有线网卡设为 `192.168.10.100/24`
3. 启动 Tftpd64，目录指向恢复镜像所在目录，接口选 `192.168.10.100`
4. 路由器上电，在 `Hit any key to stop autoboot` 时打断，确认出现 `RD03>`
5. **先只读观察**：`cat /proc/mtd`、`ubinfo -a`，确认 U-Boot/Linux 的卷名映射
6. 需要时 `tftpboot 0x46000000 recovery.bin` → `iminfo 0x46000000` 校验 → `bootm 0x46000000`
7. 进入内存系统后**先备份原数据分区并校验到电脑**，再动任何写操作
8. 按第 2 节重建卷，读回校验
9. 重启后按验收清单确认（`uptime`、`mount`、`df -h /overlay`、`iw dev`、服务状态、`logread`）
10. 稳定后再**选择性**恢复配置，**不要整体覆盖 `/etc`**，**不要手工复制任何 `.ko`**

---

## 8. 一句话经验

> **先用串口确定故障发生在 U-Boot、kernel 还是 overlay，再选择修复层级。**
> **看到启动失败就走串口，不要靠 Reset 和删配置碰运气。**
