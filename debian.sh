cat > /tmp/debian13-mini.sh <<'EOF'
#!/bin/bash
set -e

echo "=== Debian 13 Mini Installer ==="

# 自动找磁盘
DISK=$(lsblk -dpno NAME,SIZE | awk '$2 ~ /[0-9]+G/ {print $1}' | head -1)

if [ -z "$DISK" ]; then
    echo "没有找到目标硬盘"
    lsblk
    exit 1
fi

echo "目标磁盘: $DISK"

read -p "输入 YES 继续格式化: " OK
[ "$OK" = "YES" ] || exit 1


# 安装依赖
apk add --no-cache \
wget \
curl \
bash \
parted \
e2fsprogs \
debootstrap \
util-linux


# 分区
wipefs -af $DISK

parted -s $DISK mklabel msdos
parted -s $DISK mkpart primary ext4 1MiB 100%


sleep 3


PART=${DISK}1


mkfs.ext4 -F $PART


mkdir -p /mnt/debian

mount $PART /mnt/debian


echo "安装 Debian 13..."

debootstrap \
--variant=minbase \
--include=openssh-server,ca-certificates,curl,wget,cron \
trixie \
/mnt/debian \
http://deb.debian.org/debian


echo "配置系统..."


cat > /mnt/debian/etc/fstab <<EOF
$PART / ext4 defaults,noatime 0 1
EOF


cat > /mnt/debian/etc/hostname <<EOF
debian-mini
EOF


cat > /mnt/debian/etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 debian-mini
EOF


# DNS
cp /etc/resolv.conf /mnt/debian/etc/resolv.conf


# 网络 DHCP
cat > /mnt/debian/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF


# SSH配置

mkdir -p /mnt/debian/etc/ssh/sshd_config.d

cat > /mnt/debian/etc/ssh/sshd_config.d/root.conf <<EOF
PermitRootLogin yes
PasswordAuthentication yes
EOF


# 设置密码

echo "设置root密码"

chroot /mnt/debian passwd


# 安装内核

chroot /mnt/debian apt update

chroot /mnt/debian apt install -y \
linux-image-amd64 \
systemd-sysv \
grub-pc


# grub

chroot /mnt/debian grub-install $DISK

chroot /mnt/debian update-grub


# 限制日志

mkdir -p /mnt/debian/etc/systemd/journald.conf.d

cat > /mnt/debian/etc/systemd/journald.conf.d/limit.conf <<EOF
[Journal]
SystemMaxUse=20M
RuntimeMaxUse=10M
EOF


# 禁止core dump

cat > /mnt/debian/etc/security/limits.d/nocore.conf <<EOF
* soft core 0
* hard core 0
EOF


# 自动清理

cat > /mnt/debian/etc/cron.daily/clean-system <<EOF
#!/bin/sh
apt clean
rm -rf /tmp/*
rm -rf /var/cache/apt/*
EOF

chmod +x /mnt/debian/etc/cron.daily/clean-system


sync

echo ""
echo "========================="
echo "Debian 13安装完成"
echo "现在 reboot"
echo "========================="

sleep 5

reboot

EOF


chmod +x /tmp/debian13-mini.sh
bash /tmp/debian13-mini.sh
