#!/bin/sh
set -eu

# Alpine live/minirootfs -> Debian 13 minimal installer for ~1 GiB disks.
# WARNING: InstallNET will erase and reinstall the system disk.

PORT="${PORT:-22}"
PASSWORD="${PASSWORD:-}"
MIRROR="${MIRROR:-http://deb.debian.org/debian/}"
INSTALLNET_URL="${INSTALLNET_URL:-https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh}"
LOG_TMPFS_SIZE="${LOG_TMPFS_SIZE:-12m}"
TMP_TMPFS_SIZE="${TMP_TMPFS_SIZE:-24m}"
JOURNAL_MAX="${JOURNAL_MAX:-6M}"

say() { printf '\n[+] %s\n' "$*"; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "Please run as root."
[ -r /etc/alpine-release ] || die "This script must be run from Alpine live/minirootfs."

say "Preparing Alpine live environment"
# The 66 MB image may have only BusyBox. Install every command used below.
apk update || die "apk update failed; check network and /etc/apk/repositories."
apk add --no-cache bash curl wget ca-certificates iproute2 coreutils grep gawk || \
    die "Failed to install required Alpine packages."
command -v bash >/dev/null 2>&1 || die "bash is still unavailable after apk add."
command -v base64 >/dev/null 2>&1 || die "base64 is unavailable."

if [ -z "$PASSWORD" ]; then
    printf 'Root password [default: 123456]: ' >/dev/tty
    IFS= read -r PASSWORD </dev/tty || PASSWORD=''
    [ -n "$PASSWORD" ] || PASSWORD='123456'
fi

case "$PORT" in ''|*[!0-9]*) die "SSH port must be numeric." ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "SSH port must be 1-65535."

IFACE="$(ip route show default 2>/dev/null | awk '/^default / {print $5; exit}' | tr -d '[:space:]')"
IP_CIDR="$(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}' | tr -d '[:space:]')"
IPADDR="${IP_CIDR%/*}"
CIDR="${IP_CIDR#*/}"
GATEWAY="$(ip route show default 2>/dev/null | awk '/^default / {print $3; exit}' | tr -d '[:space:]')"

[ -n "$IFACE" ] || die "No default-route network interface found."
[ -n "$IPADDR" ] && [ "$IPADDR" != "$IP_CIDR" ] || die "Failed to detect IPv4 address."
[ -n "$CIDR" ] || die "Failed to detect CIDR prefix."
[ -n "$GATEWAY" ] || die "Failed to detect gateway."

printf '\nDebian 13 minimal reinstall\n'
printf 'Interface : %s\n' "$IFACE"
printf 'IPv4      : %s/%s\n' "$IPADDR" "$CIDR"
printf 'Gateway   : %s\n' "$GATEWAY"
printf 'SSH port  : %s\n' "$PORT"
printf 'Mirror    : %s\n' "$MIRROR"
printf '\nWARNING: the system disk will be erased and reinstalled.\n'
printf 'Type ERASE to continue: ' >/dev/tty
IFS= read -r CONFIRM </dev/tty || CONFIRM=''
[ "$CONFIRM" = "ERASE" ] || die "Cancelled."

say "Creating Debian first-boot optimization"
cat > /tmp/debian-firstboot.sh <<FIRSTBOOT
#!/bin/bash
set -u
export DEBIAN_FRONTEND=noninteractive
exec >/var/log/debian-tiny-firstboot.log 2>&1

# Prevent future packages from installing nonessential documentation/locales.
mkdir -p /etc/dpkg/dpkg.cfg.d /etc/apt/apt.conf.d
cat > /etc/dpkg/dpkg.cfg.d/01-tiny-node <<'CFG'
path-exclude /usr/share/doc/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/locale/*
CFG
cat > /etc/apt/apt.conf.d/99-tiny-node <<'CFG'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
APT::Keep-Downloaded-Packages "false";
Binary::apt::APT::Keep-Downloaded-Packages "false";
CFG

# Keep logs in RAM and cap their size.
mkdir -p /etc/systemd/journald.conf.d /etc/systemd/coredump.conf.d
cat > /etc/systemd/journald.conf.d/99-tiny-node.conf <<CFG
[Journal]
Storage=volatile
RuntimeMaxUse=${JOURNAL_MAX}
RuntimeMaxFileSize=2M
MaxRetentionSec=1day
ForwardToSyslog=no
CFG
cat > /etc/systemd/coredump.conf.d/99-disable.conf <<'CFG'
[Coredump]
Storage=none
ProcessSizeMax=0
CFG

# Add tmpfs mounts only once.
grep -qE '^[^#]+[[:space:]]+/var/log[[:space:]]+tmpfs' /etc/fstab || \
  printf 'tmpfs /var/log tmpfs rw,nosuid,nodev,noexec,size=${LOG_TMPFS_SIZE},mode=0755 0 0\n' >> /etc/fstab
grep -qE '^[^#]+[[:space:]]+/tmp[[:space:]]+tmpfs' /etc/fstab || \
  printf 'tmpfs /tmp tmpfs rw,nosuid,nodev,size=${TMP_TMPFS_SIZE},mode=1777 0 0\n' >> /etc/fstab
sed -i '/[[:space:]]\/[[:space:]]/ s/defaults/defaults,noatime/' /etc/fstab 2>/dev/null || true

# Basic node tuning and no core dumps.
mkdir -p /etc/sysctl.d /etc/security/limits.d /etc/modules-load.d
cat > /etc/sysctl.d/99-tiny-node.conf <<'CFG'
fs.suid_dumpable = 0
kernel.core_pattern = /dev/null
vm.swappiness = 10
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
CFG
printf 'tcp_bbr\n' > /etc/modules-load.d/bbr.conf
printf '* soft nofile 65535\n* hard nofile 65535\n' > /etc/security/limits.d/99-nofile.conf

# Reduce background writes on a tiny disk.
systemctl mask apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer \
  e2scrub_all.timer e2scrub_reap.service >/dev/null 2>&1 || true

# Automatic cleanup, including common 3x-ui/Xray log locations.
cat > /usr/local/sbin/clean-space <<'CLEAN'
#!/bin/sh
apt-get clean >/dev/null 2>&1 || true
rm -rf /var/cache/apt/archives/* /var/lib/apt/lists/* /root/.cache/* 2>/dev/null || true
journalctl --vacuum-size=3M >/dev/null 2>&1 || true
find /var/log -type f -size +768k -exec truncate -s 0 {} + 2>/dev/null || true
find /usr/local/x-ui /etc/x-ui /var/log/x-ui -type f -name '*.log' -size +768k -exec truncate -s 0 {} + 2>/dev/null || true
find /tmp /var/tmp -mindepth 1 -mtime +1 -exec rm -rf {} + 2>/dev/null || true
sync
CLEAN
chmod 755 /usr/local/sbin/clean-space

cat > /usr/local/sbin/disk-guard <<'GUARD'
#!/bin/sh
used="$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
case "$used" in ''|*[!0-9]*) exit 0 ;; esac
[ "$used" -ge 88 ] && /usr/local/sbin/clean-space >/dev/null 2>&1
exit 0
GUARD
chmod 755 /usr/local/sbin/disk-guard

cat > /etc/systemd/system/clean-space.service <<'UNIT'
[Unit]
Description=Clean caches and oversized logs
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/clean-space
UNIT
cat > /etc/systemd/system/clean-space.timer <<'UNIT'
[Unit]
Description=Daily tiny-disk cleanup
[Timer]
OnCalendar=daily
RandomizedDelaySec=600
Persistent=true
[Install]
WantedBy=timers.target
UNIT
cat > /etc/systemd/system/disk-guard.service <<'UNIT'
[Unit]
Description=Tiny-disk usage guard
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/disk-guard
UNIT
cat > /etc/systemd/system/disk-guard.timer <<'UNIT'
[Unit]
Description=Check tiny disk every 15 minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable clean-space.timer disk-guard.timer fstrim.timer >/dev/null 2>&1 || true

# Free reserved ext filesystem blocks when root is ext2/3/4.
ROOTDEV="\$(findmnt -n -o SOURCE / 2>/dev/null || true)"
if command -v tune2fs >/dev/null 2>&1 && [ -n "\$ROOTDEV" ]; then
  tune2fs -m 0 "\$ROOTDEV" >/dev/null 2>&1 || true
fi

/usr/local/sbin/clean-space || true
rm -f /etc/run.sh /var/log/debian-tiny-firstboot.log 2>/dev/null || true
FIRSTBOOT
chmod 700 /tmp/debian-firstboot.sh
FIRSTBOOT_B64="$(base64 /tmp/debian-firstboot.sh | tr -d '\n')"
[ -n "$FIRSTBOOT_B64" ] || die "Failed to encode first-boot script."

say "Downloading InstallNET"
wget --no-check-certificate -O /tmp/InstallNET.sh "$INSTALLNET_URL" || die "InstallNET download failed."
chmod 700 /tmp/InstallNET.sh

say "Launching Debian 13 unattended installer"
printf 'The server will reboot. Installation usually takes 10-20 minutes.\n'
exec bash /tmp/InstallNET.sh \
    -debian 13 \
    -port "$PORT" \
    -pwd "$PASSWORD" \
    -mirror "$MIRROR" \
    --ip-addr "$IPADDR" \
    --ip-gate "$GATEWAY" \
    --ip-mask "$CIDR" \
    -swap 0 \
    --cloudkernel 0 \
    --bbr \
    --motd \
    -cmd "$FIRSTBOOT_B64"
