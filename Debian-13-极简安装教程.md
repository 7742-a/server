# Debian 13 极简安装教程（约 1 GiB 硬盘）

本教程配套桌面上的 `debian13.sh` 使用。

该脚本会从 **Alpine 临时安装系统** 中，将指定硬盘完整擦除并安装为极简 Debian 13。目标是先在 VM 中测试，再用于阿里云 ECS。

> ⚠️ **这是破坏性安装脚本**
>
> - 目标硬盘上的分区和数据会被全部删除；
> - 第一次测试必须使用可随时删除的一次性虚拟磁盘；
> - 不要在有重要数据的机器上直接运行；
> - 不要根据设备名猜测目标盘，运行前必须用 `lsblk` 确认；
> - 当前方案不支持 Secure Boot，UEFI 环境必须关闭 Secure Boot。

---

## 1. 安装后的系统包含什么

脚本安装：

- Debian 13 `trixie` amd64；
- `debootstrap --variant=minbase` 极简基础系统；
- 默认使用 Debian cloud 内核；
- OpenSSH Server；
- systemd-networkd DHCP；
- systemd-resolved DNS；
- systemd-timesyncd 时间同步；
- Legacy BIOS 和 UEFI 双启动；
- 自动扩展根分区和 ext4 文件系统；
- 8 MiB 内存日志上限；
- 自动缓存清理和 90% 磁盘占用守卫。

为了节省空间，默认不安装：

- `curl`、`wget`；
- `nano`、`vim`；
- `git`、`jq`；
- `sudo`；
- `cron`、`rsyslog`；
- `cloud-init`；
- `qemu-guest-agent`；
- `unattended-upgrades`。

需要额外软件时，应先确认剩余空间：

```sh
df -h /
```

---

## 2. 保留的 SSH 配置

安装后的 SSH 配置保存在：

```text
/etc/ssh/sshd_config.d/00-node.conf
```

配置行为为：

```text
Port 自定义端口
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UseDNS no
X11Forwarding no
AllowTcpForwarding yes
GatewayPorts no
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel INFO
```

也就是说：

- 可以直接使用 `root` 登录；
- 使用安装时输入的密码认证；
- 保留 SSH TCP forwarding；
- 可以通过 `SSH_PORT` 修改端口。

> 修改 SSH 端口只能减少扫描噪声，不能代替安全防护。请使用足够长的随机密码，并在阿里云安全组中只允许可信 IP 访问 SSH 端口。

---

## 3. 支持范围

### 支持

- x86_64/amd64；
- 从 Alpine 临时 ISO 启动；
- KVM、VirtIO、NVMe 等常见云虚拟硬件；
- Legacy BIOS；
- UEFI（Secure Boot 关闭，且固件支持标准 `EFI/BOOT/BOOTX64.EFI` fallback 路径）；
- DHCP 网络；
- GPT 系统盘；
- 约 1 GiB 或更大的、512 字节逻辑扇区的磁盘。

### 不支持

- ARM/ARM64；
- Secure Boot；
- LVM、RAID、LUKS；
- 静态 IP 自动配置；
- cloud-init 的密码、SSH key 和 user-data 注入；
- 自动选择安装磁盘。

---

## 4. 为什么必须指定 DISK

脚本不会自动选择磁盘，避免在多硬盘机器中擦错盘。

先运行：

```sh
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
```

常见系统盘名称：

- `/dev/vda`：KVM VirtIO；
- `/dev/sda`：SATA/SCSI；
- `/dev/nvme0n1`：NVMe。

请确认：

1. 目标是整个磁盘，不是 `/dev/vda1` 这样的分区；
2. 目标盘容量与新建的测试盘一致；
3. 目标盘没有挂载点；
4. 目标盘不包含 Alpine 临时系统或 ISO；
5. 目标盘中没有需要保留的数据。

---

## 5. 第一次 VM 测试的建议配置

建议创建一台一次性测试 VM：

| 项目 | 建议值 |
|---|---|
| 架构 | x86_64 |
| 内存 | 至少 1 GiB |
| 临时 ISO | Alpine `alpine-virt` |
| 系统盘 | 新建 1 GiB VirtIO 磁盘 |
| 网卡 | VirtIO，DHCP |
| 第一次固件 | SeaBIOS/Legacy BIOS |
| 第二次固件 | OVMF/UEFI，Secure Boot 关闭 |

如果实际磁盘只有十进制 1 GB，系统通常会显示约 953 MiB。脚本默认最低允许 950 MiB，但安装成功还要求最终至少剩余约 96 MiB。

该布局使用 64 MiB FAT32 ESP，只支持 **512 字节逻辑扇区** 的磁盘。脚本会用 `blockdev --getss` 检查；4Kn 磁盘会在擦盘前拒绝安装。

> 96 MiB 只是“安装完成”的最低门槛，不代表有足够空间安全地进行内核升级。完整升级前应先把虚拟磁盘扩到至少 2 GiB。

---

## 6. 在 Alpine 临时系统中配置网络

查看网卡：

```sh
ip link
```

假设网卡是 `eth0`：

```sh
ip link set eth0 up
udhcpc -i eth0
```

配置 Alpine 网络软件仓库（原始 `alpine-virt` ISO 往往只配置了安装介质仓库）：

```sh
setup-apkrepos
```

选择与当前 Alpine 版本匹配的 HTTPS 镜像，然后执行：

```sh
apk update
```

如果不配置网络仓库，脚本会在擦盘前停止，并提示找不到 Alpine 网络仓库。

检查地址和路由：

```sh
ip a
ip route
```

测试 Debian 仓库域名：

```sh
ping -c 3 deb.debian.org
```

即使服务器禁用了 Ping，脚本仍会使用 HTTPS 实际访问 Debian 仓库进行最终判断。

---

## 7. 将脚本下载到临时系统

如果以后把脚本放到：

```text
https://linux.7742.cc.cd/debian13.sh
```

可以下载为：

```sh
busybox wget -O /tmp/debian13.sh https://linux.7742.cc.cd/debian13.sh
```

下载后先检查：

```sh
ls -l /tmp/debian13.sh
sed -n '1,120p' /tmp/debian13.sh
```

确认下载的是 Shell 脚本，而不是 HTML、404 或验证页面。

> 当前文件只是生成在桌面上。在你实际上传到该网址以前，以上下载地址不会自动生效。

---

## 8. 运行安装脚本

### 默认 SSH 端口 22

如果目标盘是 `/dev/vda`：

```sh
DISK=/dev/vda sh /tmp/debian13.sh
```

### 自定义 SSH 端口

例如使用 `2222`：

```sh
DISK=/dev/vda SSH_PORT=2222 sh /tmp/debian13.sh
```

### 自定义主机名

```sh
DISK=/dev/vda HOSTNAME=debian-node SSH_PORT=2222 sh /tmp/debian13.sh
```

### 自动重启

默认不会自动重启，避免还没有卸载 Alpine ISO 就再次进入安装环境。

测试稳定后，可以显式开启：

```sh
DISK=/dev/vda SSH_PORT=2222 AUTO_REBOOT=yes sh /tmp/debian13.sh
```

第一次测试不要使用 `AUTO_REBOOT=yes`。

---

## 9. 安装过程中的交互

脚本会：

1. 检查 Alpine、架构、目标盘和网络；
2. 在临时 Alpine 中安装 `debootstrap` 和分区工具；
3. 要求输入两次 root 密码；
4. 显示磁盘型号、序列号、容量、分区和 SSH 摘要；
5. 要求输入：

```text
ERASE
```

只有完全输入 `ERASE`，脚本才会开始擦除磁盘。

输入其他内容会退出，不会修改目标盘。

---

## 10. 磁盘布局

安装器创建 GPT：

| 分区 | 大小 | 用途 |
|---|---:|---|
| 1 | 2 MiB | BIOS Boot Partition |
| 2 | 64 MiB | FAT32 EFI System Partition |
| 3 | 剩余全部 | ext4 Debian 根分区 |

特点：

- 不创建 Swap；
- 不使用 LVM；
- 不创建独立 `/boot`；
- ext4 保留小型 journal；
- 根分区使用 `noatime`；
- ext4 保留块调整为 0%；
- 导入更大的 ECS 系统盘后，尝试自动扩大根分区和 ext4。

---

## 11. 安装完成后启动

看到：

```text
Debian installation completed successfully
```

才表示脚本完成了全部硬校验。

如果默认 `AUTO_REBOOT=no`：

1. 在 VM 控制台卸载 Alpine ISO；
2. 确认系统盘为第一启动设备；
3. 执行：

```sh
reboot
```

如果安装中途失败，而且脚本已经擦除磁盘，会提示目标盘可能不可启动。此时不要把它当成安装成功；应保留 Alpine ISO，确认错误后重新运行。

---

## 12. 首次启动后检查

在控制台执行：

```sh
systemctl --failed
systemctl status systemd-networkd
systemctl status systemd-resolved
systemctl status systemd-timesyncd
systemctl status ssh
networkctl
resolvectl status
ip a
ip route
ss -ltnp
df -h /
```

查看本次启动的警告：

```sh
journalctl -b -p warning
```

> 日志存储在 RAM 中，重启后会消失，这是为了避免 1 GiB 硬盘被日志写满。

---

## 13. 测试 SSH 密码登录

假设服务器地址为 `192.168.1.100`，端口为 `2222`：

```sh
ssh -p 2222 \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  root@192.168.1.100
```

如果使用端口 22：

```sh
ssh root@192.168.1.100
```

检查 root 登录上下文中的实际配置（把 `2222` 替换成你的端口）：

```sh
SSHD_EFFECTIVE="$(sshd -T -C "user=root,host=$(hostname),addr=127.0.0.1")" || exit 1
printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fx 'port 2222'
printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fx 'permitrootlogin yes'
printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fx 'passwordauthentication yes'
printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fx 'kbdinteractiveauthentication no'
printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fx 'permitemptypasswords no'
printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fx 'allowtcpforwarding yes'
printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fx 'gatewayports no'
```

所有命令都应成功且打印对应行。

---

## 14. 测试 SSH TCP forwarding

例如将本机 `18080` 转发到服务器的 `127.0.0.1:80`：

```sh
ssh -p 2222 -L 18080:127.0.0.1:80 root@SERVER_IP
```

`AllowTcpForwarding yes` 表示允许建立转发；`GatewayPorts no` 表示远程转发默认不会向所有外部地址开放监听。

---

## 15. 必须执行的 VM 测试

### 测试 A：Legacy BIOS

- 1 GiB VirtIO 系统盘；
- SeaBIOS/Legacy BIOS；
- 验证启动、DHCP、DNS、SSH 密码登录和 TCP forwarding。

### 测试 B：UEFI

- 同样的系统盘或克隆盘；
- OVMF/UEFI；
- Secure Boot 关闭；
- 验证 `/EFI/BOOT/BOOTX64.EFI` fallback 可以启动。

### 测试 C：NVMe

- 使用 1 GiB NVMe 系统盘；
- 验证 cloud 内核能够识别根盘和网卡。

### 测试 D：扩容

把克隆盘从 1 GiB 扩大，例如扩到 8 GiB 或 20 GiB，然后启动并检查：

```sh
lsblk
df -h /
journalctl -b -u systemd-repart.service
```

根分区和 ext4 应自动使用新增空间。

### 测试 E：系统更新

**不要直接在 1 GiB 磁盘上做完整升级。** 先完成“测试 D”，把虚拟磁盘扩到至少 2 GiB，并确认根分区和 ext4 已经扩容：

```sh
df -h /
```

先模拟升级：

```sh
apt-get update
apt-get -s upgrade
```

确认空间足够后再执行：

```sh
apt-get upgrade
```

更新后再次检查空间并重启，验证 BIOS 和 UEFI 仍然可以启动。

> 内核升级会暂时同时保存新旧内核、下载包和 initramfs，是小磁盘系统最容易空间不足的操作。脚本的 96 MiB 最终门槛只表示安装完成，不表示可以安全升级内核。

---

## 16. 自动磁盘清理

系统包含两个 timer：

```sh
systemctl status tiny-disk-clean.timer
systemctl status tiny-disk-guard.timer
```

作用：

- 每天清理 APT 下载缓存、旧临时文件和 root cache；
- 每 15 分钟检查根分区；
- 达到 90% 时触发清理；
- 不自动删除内核、已安装软件或用户文件。

手动执行日常清理：

```sh
/usr/local/sbin/tiny-disk-clean daily
```

手动执行空间守卫：

```sh
/usr/local/sbin/tiny-disk-clean guard
```

---

## 17. 安装其他软件前注意

APT 索引会在安装结束时被删除，因此安装软件前先运行：

```sh
apt-get update
```

再检查空间：

```sh
df -h /
```

然后安装，例如：

```sh
apt-get install --no-install-recommends curl
```

安装完成后清理：

```sh
apt-get clean
rm -rf /var/lib/apt/lists/*
```

不建议在 1 GiB 系统中安装：

- Docker；
- 编译工具链；
- Node/npm 大型依赖树；
- 桌面环境；
- 大量语言包和开发文档。

---

## 18. 制作可复用云镜像前封装

脚本会安装：

```text
/usr/local/sbin/tiny-image-seal
```

当 VM 已完成测试、准备转换为阿里云自定义镜像时，请通过 VM 控制台执行：

```sh
/usr/local/sbin/tiny-image-seal
```

然后输入：

```text
SEAL
```

它会：

- 停止 SSH；
- 删除 SSH host keys；
- 重置 machine-id；
- 删除 DHCP lease 和随机种子；
- 清理 APT、临时文件和历史记录。

完成后应立即关机：

```sh
poweroff
```

> 执行 seal 后不要再次启动这个源 VM。若重新启动，系统会生成新的 host keys 和 machine-id，封装前需要再次 seal。

root 密码不会被 seal 删除，因为你要求通过 root 密码登录。由这个镜像创建的实例会共享初始 root 密码，因此必须使用强随机密码，并在创建实例后尽快修改：

```sh
passwd
```

---

## 19. 导入阿里云 ECS 前的注意事项

1. VM 中完成 BIOS、UEFI、NVMe、更新和扩容测试；
2. 执行 `tiny-image-seal`；
3. 关机后转换为阿里云支持的 RAW 或 QCOW2；
4. 上传到 OSS 并导入自定义镜像；
5. 架构选择 x86_64；
6. 操作系统选择 Debian 13 或最接近的自定义 Linux；
7. Secure Boot 必须关闭；
8. 优先先测试 UEFI，再测试 BIOS/UEFI-Preferred；
9. 安全组放行脚本中设置的 `SSH_PORT`；
10. 使用阿里云 VNC/串口控制台观察首次启动；
11. 检查系统盘是否自动扩容；
12. 首次登录后修改 root 密码。

因为没有安装 cloud-init：

- 不要依赖控制台自动注入 SSH key；
- 不要依赖 user-data；
- 不要依赖 cloud-init 修改 hostname；
- 不要假设控制台重置密码一定能写入系统；
- DHCP、DNS、时间同步和扩盘由本系统自己的 systemd 配置负责。

---

## 20. 常见问题

### 脚本提示必须设置 DISK

正确示例：

```sh
DISK=/dev/vda sh /tmp/debian13.sh
```

### 提示目标不是整个磁盘

不要使用：

```sh
DISK=/dev/vda1
```

应该使用：

```sh
DISK=/dev/vda
```

### 提示磁盘已挂载或正在使用

不要强制绕过。先用下面的命令确认磁盘关系：

```sh
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
findmnt
cat /proc/swaps
```

### 安装后不能从 UEFI 启动

检查：

- Secure Boot 是否关闭；
- VM 是否使用 x86_64 UEFI；
- EFI 分区是否存在；
- `/boot/efi/EFI/BOOT/BOOTX64.EFI` 是否存在。

### 安装后没有网络

通过控制台检查：

```sh
systemctl status systemd-networkd
networkctl
ip link
ip a
ip route
```

### SSH 连接被拒绝

检查：

```sh
systemctl status ssh
ss -ltnp
sshd -t
```

如果是阿里云，还要确认安全组放行实际 SSH 端口。

### 系统盘空间不足

执行：

```sh
df -h /
/usr/local/sbin/tiny-disk-clean daily
du -x -h -d 1 / 2>/dev/null
```

不要直接删除 `/boot`、`/lib/modules`、`/var/lib/dpkg` 或 APT 数据库。

---

## 21. 推荐的首次运行命令

假设：

- 目标盘为 `/dev/vda`；
- SSH 端口为 `2222`；
- 主机名为 `debian-node`；
- 第一次测试不自动重启。

执行：

```sh
DISK=/dev/vda \
SSH_PORT=2222 \
HOSTNAME=debian-node \
AUTO_REBOOT=no \
sh /tmp/debian13.sh
```

安装完成后卸载 Alpine ISO，再执行：

```sh
reboot
```

---

## 22. 最后提醒

- 1 GiB Debian 是极限用途，不是 Debian 官方建议的常规服务器容量；
- 默认 cloud 内核适合多数 KVM、VirtIO、NVMe 云环境，但仍必须在目标 ECS 实例族测试；
- 如果 cloud 内核缺少驱动，可以用通用内核重新安装：

```sh
DISK=/dev/vda KERNEL_PACKAGE=linux-image-amd64 sh /tmp/debian13.sh
```

通用内核更大，1 GiB 下可能无法满足最终空间要求；
- 不要降低最终空间检查来“让安装显示成功”，否则后续 APT 或内核更新很容易写满磁盘；
- 本教程和脚本不会上传或修改远程仓库，需要你确认本地测试通过后再发布。
