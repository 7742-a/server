#!/usr/bin/env bash
# Linux Universal Init Script v1.1.0
# Debian Ubuntu CentOS Rocky Alma Fedora Arch Alpine openSUSE

set -e

VERSION="1.1.0"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

info(){ echo -e "${BLUE}[信息]${RESET} $1"; }
ok(){ echo -e "${GREEN}[完成]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[注意]${RESET} $1"; }

[[ "$(id -u)" != "0" ]] && {
    echo "请使用 root 运行"
    exit 1
}

command -v curl >/dev/null 2>&1 || {
    echo "curl不存在，请先安装curl"
    exit 1
}

. /etc/os-release

OS_ID=$ID
PKG=""

case "$OS_ID" in
debian|ubuntu|linuxmint) PKG="apt" ;;
centos|rhel|rocky|almalinux|fedora)
    command -v dnf >/dev/null 2>&1 && PKG="dnf" || PKG="yum"
;;
arch|manjaro) PKG="pacman" ;;
alpine) PKG="apk" ;;
opensuse*|sles) PKG="zypper" ;;
*)
    warn "未知系统 $OS_ID"
;;
esac

show_info(){
echo "================================"
echo "Linux Universal Init $VERSION"
echo "系统: $PRETTY_NAME"
echo "架构: $(uname -m)"
echo "包管理: $PKG"
echo "================================"
}

setup_ssh(){
    local file="/etc/ssh/sshd_config"
    [ ! -f "$file" ] && return

    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$file"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$file"

    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    ok "SSH root登录已开启"
}

set_root_password(){
    passwd root
}

change_mirror(){
    bash <(curl -sSL https://linuxmirrors.cn/main.sh) || warn "换源失败"
}

install_tools(){
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
net-tools bind-utils python3 gcc gcc-c++ make
;;
pacman)
pacman -Sy --noconfirm
pacman -S --noconfirm curl wget vim nano bash git unzip zip tar gzip \
htop lsof jq rsync tree tmux screen python python-pip
;;
apk)
apk update
apk add curl wget vim nano bash git unzip zip tar gzip \
htop lsof jq rsync tree tmux screen net-tools \
python3 py3-pip build-base
;;
zypper)
zypper refresh
zypper install -y curl wget vim nano bash git unzip zip tar gzip \
htop lsof jq rsync tree tmux screen python3 gcc make
;;
esac

ok "基础工具安装完成"
}

install_fastfetch(){
case "$PKG" in
apt) apt install -y fastfetch 2>/dev/null || true ;;
dnf|yum) $PKG install -y fastfetch 2>/dev/null || true ;;
pacman) pacman -S --noconfirm fastfetch 2>/dev/null || true ;;
apk) apk add fastfetch 2>/dev/null || true ;;
zypper) zypper install -y fastfetch 2>/dev/null || true ;;
esac
}

install_docker(){
bash <(curl -sSL https://linuxmirrors.cn/docker.sh) || warn "Docker安装失败"
}

enable_network(){
cat >/etc/sysctl.d/99-linux-init.conf <<EOF
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null 2>&1 || true
}

create_commands(){
cat >/usr/local/bin/sysinfo <<'EOF'
#!/bin/bash
echo "系统:"
hostnamectl 2>/dev/null | grep "Operating System"
echo "内核: $(uname -r)"
echo "CPU: $(nproc) 核"
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
apt clean 2>/dev/null || true
dnf clean all 2>/dev/null || true
yum clean all 2>/dev/null || true
apk cache clean 2>/dev/null || true
journalctl --vacuum-time=7d 2>/dev/null || true
EOF

chmod +x /usr/local/bin/clean
}

interactive(){
show_info

read -p "设置root密码? (y/n): " a
[[ "$a" =~ ^[Yy]$ ]] && set_root_password

read -p "开启root SSH登录? (y/n): " a
[[ "$a" =~ ^[Yy]$ ]] && setup_ssh

read -p "更换软件源? (y/n): " a
[[ "$a" =~ ^[Yy]$ ]] && change_mirror

read -p "安装基础工具? (y/n): " a
[[ "$a" =~ ^[Yy]$ ]] && install_tools

install_fastfetch

read -p "安装Docker? (y/n): " a
[[ "$a" =~ ^[Yy]$ ]] && install_docker

enable_network
create_commands
}

all(){
setup_ssh
install_tools
install_fastfetch
install_docker
enable_network
create_commands
}

case "$1" in
--all)
all
;;
--ssh)
setup_ssh
;;
--tools)
install_tools
install_fastfetch
;;
--docker)
install_docker
;;
--mirror)
change_mirror
;;
*)
interactive
;;
esac

echo
echo "================================"
echo "初始化完成"
echo "版本: $VERSION"
echo "快捷命令:"
echo " sysinfo"
echo " clean"
echo " fastfetch"
echo "================================"
