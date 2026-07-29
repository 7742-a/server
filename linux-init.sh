#!/usr/bin/env bash
# Linux Universal Initialization Script
# Debian / Ubuntu / CentOS / Rocky / Alma / Fedora / Arch / Alpine / openSUSE

set -e

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

info(){ echo -e "${BLUE}[信息]${RESET} $1"; }
ok(){ echo -e "${GREEN}[完成]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[注意]${RESET} $1"; }

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 运行"
    exit 1
fi

. /etc/os-release

OS_ID=$ID
PKG=""

case "$OS_ID" in
    debian|ubuntu|linuxmint)
        PKG="apt"
        ;;
    centos|rhel|rocky|almalinux|fedora)
        command -v dnf >/dev/null 2>&1 && PKG="dnf" || PKG="yum"
        ;;
    arch|manjaro)
        PKG="pacman"
        ;;
    alpine)
        PKG="apk"
        ;;
    opensuse*|sles)
        PKG="zypper"
        ;;
    *)
        warn "未知系统: $OS_ID"
        ;;
esac

echo "================================"
echo "Linux 初始化脚本"
echo "系统: $PRETTY_NAME"
echo "架构: $(uname -m)"
echo "包管理器: $PKG"
echo "================================"

# 设置root密码
echo
read -p "是否设置root密码? (y/n): " SETPASS
if [[ "$SETPASS" =~ ^[Yy]$ ]]; then
    passwd root
fi

# SSH配置
SSH_FILE="/etc/ssh/sshd_config"

if [ -f "$SSH_FILE" ]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$SSH_FILE"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSH_FILE"

    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    ok "SSH root登录和密码登录已开启"
fi

# 更新源
echo
read -p "是否运行 LinuxMirrors 更换软件源? (y/n): " MIRROR
if [[ "$MIRROR" =~ ^[Yy]$ ]]; then
    bash <(curl -sSL https://linuxmirrors.cn/main.sh) || warn "换源失败"
fi

# 安装基础软件
install_packages(){

case "$PKG" in
apt)
    apt update
    apt install -y curl wget vim nano bash git unzip zip tar gzip \
    htop lsof jq rsync tree tmux screen \
    net-tools iproute2 dnsutils traceroute mtr-tiny \
    python3 python3-pip build-essential ca-certificates
;;
dnf|yum)
    $PKG install -y curl wget vim nano bash git unzip zip tar gzip \
    htop lsof jq rsync tree tmux screen \
    net-tools iproute bind-utils \
    python3 gcc gcc-c++ make
;;
pacman)
    pacman -Sy --noconfirm
    pacman -S --noconfirm curl wget vim nano bash git unzip zip tar gzip \
    htop lsof jq rsync tree tmux screen \
    net-tools python python-pip
;;
apk)
    apk update
    apk add curl wget vim nano bash git unzip zip tar gzip \
    htop lsof jq rsync tree tmux screen \
    net-tools iproute2 python3 py3-pip build-base
;;
zypper)
    zypper refresh
    zypper install -y curl wget vim nano bash git unzip zip tar gzip \
    htop lsof jq rsync tree tmux screen python3 gcc make
;;
*)
    warn "跳过软件安装"
;;
esac
}

install_packages

# fastfetch
if ! command -v fastfetch >/dev/null 2>&1; then
    case "$PKG" in
        apt) apt install -y fastfetch 2>/dev/null || true ;;
        dnf|yum) $PKG install -y fastfetch 2>/dev/null || true ;;
        pacman) pacman -S --noconfirm fastfetch 2>/dev/null || true ;;
        apk) apk add fastfetch 2>/dev/null || true ;;
        zypper) zypper install -y fastfetch 2>/dev/null || true ;;
    esac
fi

# Docker
echo
read -p "是否安装Docker? (y/n): " DOCKER
if [[ "$DOCKER" =~ ^[Yy]$ ]]; then
    if command -v curl >/dev/null; then
        bash <(curl -sSL https://linuxmirrors.cn/docker.sh) || warn "Docker安装失败"
    fi
fi

# 开启IP转发
cat >/etc/sysctl.d/99-linux-init.conf <<EOF
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null 2>&1 || true

# BBR
cat >/etc/modules-load.d/bbr.conf <<EOF
tcp_bbr
EOF

# 快捷命令
cat >/usr/local/bin/sysinfo <<'EOF'
#!/bin/bash
echo "系统: $(hostnamectl 2>/dev/null | grep Operating | cut -d: -f2)"
echo "内核: $(uname -r)"
echo "CPU: $(nproc)核"
echo "内存:"
free -h
echo "磁盘:"
df -h /
echo "IP:"
curl -s ifconfig.me || hostname -I
EOF
chmod +x /usr/local/bin/sysinfo

cat >/usr/local/bin/clean <<'EOF'
#!/bin/bash
command -v apt >/dev/null && apt clean
command -v dnf >/dev/null && dnf clean all
command -v yum >/dev/null && yum clean all
command -v apk >/dev/null && apk cache clean
journalctl --vacuum-time=7d 2>/dev/null || true
EOF
chmod +x /usr/local/bin/clean

echo
read -p "是否SSH登录自动显示fastfetch? (y/n): " FF
if [[ "$FF" =~ ^[Yy]$ ]]; then
    grep -qxF "fastfetch" ~/.bashrc || echo "fastfetch" >> ~/.bashrc
fi

echo
echo "================================"
echo "初始化完成"
echo "系统: $PRETTY_NAME"
echo "快捷命令:"
echo " sysinfo  查看系统信息"
echo " clean    清理缓存"
echo " fastfetch 查看机器信息"
echo "================================"
