sh <<'INSTALL_EOF'
#!/bin/sh
set -eu

# ==================== 可修改配置 ====================

DISK="/dev/vda"
HOSTNAME="alpine"

# 必须修改，不能保留默认值
ROOT_PASSWORD="CHANGE_THIS_PASSWORD"

# 自动根据当前 ISO 版本选择 v3.24、v3.25 等目录
MIRROR_BASE="http://mirrors.aliyun.com/alpine"

# 1GB 硬盘不要装太多东西
# BusyBox 已经自带 wget 和 vi
EXTRA_PKGS="bash curl ca-certificates nano"

# 安装完自动关机，方便卸载 ISO
AUTO_POWEROFF="yes"

# ====================================================

log() {
    printf '\n[+] %s\n' "$*"
}

die() {
    printf '\n[错误] %s\n' "$*" >&2
    exit 1
}

cleanup() {
    umount /mnt/proc 2>/dev/null || true
    umount /mnt/dev 2>/dev/null || true
    umount /mnt 2>/dev/null || true
}

# ---------- 基础检查 ----------

[ "$(id -u)" -eq 0 ] || die "必须使用 root 运行"

[ -b "$DISK" ] || die "没有找到磁盘 $DISK，请先检查磁盘名称"

[ -r /etc/alpine-release ] || die "当前环境不像 Alpine 安装 ISO"

case "$ROOT_PASSWORD" in
    ""|"CHANGE_THIS_PASSWORD")
        die "请先修改脚本顶部的 ROOT_PASSWORD"
        ;;
    *:*)
        die "密码中暂时不要包含英文冒号"
        ;;
esac

DISK_NAME="${DISK##*/}"

[ -r "/sys/class/block/$DISK_NAME/size" ] ||
    die "无法读取 $DISK 的容量"

DISK_MB=$(( $(cat "/sys/class/block/$DISK_NAME/size") / 2048 ))

[ "$DISK_MB" -ge 800 ] ||
    die "磁盘容量只有约 ${DISK_MB}MB，空间不足"

# 自动寻找第一块非 lo 网卡
IFACE=""

for NET_PATH in /sys/class/net/*; do
    NET_NAME="${NET_PATH##*/}"

    [ "$NET_NAME" = "lo" ] && continue

    IFACE="$NET_NAME"
    break
done

[ -n "$IFACE" ] || die "没有找到可用网卡"

# 从 3.24.1 自动得到 3.24
ALPINE_BRANCH="$(cut -d. -f1,2 /etc/alpine-release)"

case "$ALPINE_BRANCH" in
    [0-9]*.[0-9]*)
        ;;
    *)
        die "无法识别 Alpine 版本：$(cat /etc/alpine-release)"
        ;;
esac

REPO="${MIRROR_BASE}/v${ALPINE_BRANCH}"

log "检测结果"
echo "Alpine 版本：$(cat /etc/alpine-release)"
echo "系统磁盘：$DISK，约 ${DISK_MB}MB"
echo "网络接口：$IFACE"
echo "软件源：$REPO"
echo
echo "警告：5 秒后将清空 $DISK 的全部数据"
sleep 5

# ---------- 生成 Alpine 自动安装配置 ----------

cat > /tmp/alpine-answer <<ANSWERS_EOF
KEYMAPOPTS="us us"
HOSTNAMEOPTS="$HOSTNAME"
DEVDOPTS="mdev"

INTERFACESOPTS="auto lo
iface lo inet loopback

auto $IFACE
iface $IFACE inet dhcp
    hostname $HOSTNAME"

DNSOPTS="223.5.5.5 8.8.8.8"
TIMEZONEOPTS="Asia/Shanghai"
PROXYOPTS="none"

APKREPOSOPTS="$REPO/main $REPO/community"

USEROPTS="none"
SSHDOPTS="openssh"

NTPOPTS="busybox"

DISKOPTS="-m sys -s 0 $DISK"

LBUOPTS="none"
APKCACHEOPTS="none"
ANSWERS_EOF

# ERASE_DISKS 允许 setup-disk 非交互清空目标磁盘
export ERASE_DISKS="$DISK"

log "开始安装 Alpine"

# -e：安装阶段暂时允许空 root 密码
# 稍后会在新系统中写入正式密码
setup-alpine -e -f /tmp/alpine-answer

sync
sleep 2

# ---------- 自动识别根分区 ----------

ROOT_PART=""
ROOT_PART_SIZE=0

for PART_PATH in /sys/class/block/${DISK_NAME}*; do
    [ -f "$PART_PATH/partition" ] || continue

    CURRENT_SIZE="$(cat "$PART_PATH/size")"

    if [ "$CURRENT_SIZE" -gt "$ROOT_PART_SIZE" ]; then
        ROOT_PART_SIZE="$CURRENT_SIZE"
        ROOT_PART="/dev/${PART_PATH##*/}"
    fi
done

[ -b "$ROOT_PART" ] ||
    die "安装完成，但未能自动识别根分区"

log "检测到根分区：$ROOT_PART"

# ---------- 修改新系统 ----------

cleanup
trap cleanup EXIT

mkdir -p /mnt
mount "$ROOT_PART" /mnt

mkdir -p /mnt/dev /mnt/proc
mount -o bind /dev /mnt/dev
mount -t proc proc /mnt/proc

# 确保 chroot 中可以解析域名
cp /etc/resolv.conf /mnt/etc/resolv.conf

log "设置 root 密码"

printf 'root:%s\n' "$ROOT_PASSWORD" |
    chroot /mnt chpasswd

log "配置 SSH 密码登录"

# 删除旧配置，避免 OpenSSH 前面的配置优先生效
sed -i \
    -e '/PermitRootLogin/d' \
    -e '/PasswordAuthentication/d' \
    /mnt/etc/ssh/sshd_config

cat >> /mnt/etc/ssh/sshd_config <<'SSHD_EOF'

# Added by Alpine auto installer
PermitRootLogin yes
PasswordAuthentication yes
SSHD_EOF

log "写入软件源"

printf '%s\n%s\n' \
    "$REPO/main" \
    "$REPO/community" \
    > /mnt/etc/apk/repositories

log "安装精简常用软件"

# 不安装 util-linux、parted、grub、vim 等大包
chroot /mnt apk add --no-cache $EXTRA_PKGS

log "生成 SSH 主机密钥"

chroot /mnt ssh-keygen -A

log "确保服务开机启动"

chroot /mnt rc-update add networking boot >/dev/null 2>&1 || true
chroot /mnt rc-update add sshd default >/dev/null 2>&1 || true
chroot /mnt rc-update add ntpd default >/dev/null 2>&1 || true

# 检查 SSH 配置
mkdir -p /mnt/run/sshd
chroot /mnt /usr/sbin/sshd -t

# ---------- 1GB 硬盘空间优化 ----------

log "清理安装缓存"

rm -rf /mnt/var/cache/apk/*
rm -rf /mnt/tmp/*
rm -rf /mnt/root/.cache 2>/dev/null || true

# 将 ext4 默认预留空间从 5% 调低到 1%
if command -v tune2fs >/dev/null 2>&1; then
    tune2fs -m 1 "$ROOT_PART" >/dev/null 2>&1 || true
fi

echo
df -h /mnt || true

sync
cleanup
trap - EXIT

echo
echo "========================================"
echo " Alpine 安装完成"
echo " 系统盘：$DISK"
echo " 根分区：$ROOT_PART"
echo " SSH 用户：root"
echo " SSH 端口：22"
echo "========================================"
echo
echo "接下来需要："
echo "1. 从虚拟机中卸载 Alpine ISO"
echo "2. 将硬盘设置为第一启动项"
echo "3. 启动虚拟机"
echo "4. 使用 SSH 连接服务器 IP"

if [ "$AUTO_POWEROFF" = "yes" ]; then
    echo
    echo "系统将在 5 秒后关机，请随后卸载 ISO"
    sleep 5
    poweroff
fi

INSTALL_EOF
