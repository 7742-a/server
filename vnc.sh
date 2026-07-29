#!/bin/sh
set -eu

# Alpine 3.24+ minimal node server installer for a 1 GiB disk.
# WARNING: The selected disk will be erased completely.

DISK="${DISK:-/dev/vda}"
HOSTNAME="${HOSTNAME:-alpine-node}"
MIRROR_BASE="${MIRROR_BASE:-https://mirrors.aliyun.com/alpine}"
SSH_PORT="${SSH_PORT:-22}"
LOG_TMPFS_SIZE="${LOG_TMPFS_SIZE:-8m}"
SYSLOG_FILE_KB="${SYSLOG_FILE_KB:-128}"
SYSLOG_BACKUPS="${SYSLOG_BACKUPS:-2}"
AUTO_POWEROFF="${AUTO_POWEROFF:-yes}"

# Compatibility packages for common node installation scripts.
# BusyBox already provides wget, vi, tar, gzip, unzip, ip, ping, sed and awk.
TARGET_PACKAGES="${TARGET_PACKAGES:-bash curl ca-certificates}"

say() { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

cleanup_mounts() {
    umount /mnt/run 2>/dev/null || true
    umount /mnt/sys 2>/dev/null || true
    umount /mnt/proc 2>/dev/null || true
    umount /mnt/dev 2>/dev/null || true
    umount /mnt 2>/dev/null || true
}

prompt_password() {
    [ -n "${ROOT_PASSWORD:-}" ] && return 0

    while :; do
        printf 'Set the new root password: '
        stty -echo 2>/dev/null || true
        IFS= read -r ROOT_PASSWORD
        stty echo 2>/dev/null || true
        printf '\nRepeat the root password: '
        stty -echo 2>/dev/null || true
        IFS= read -r ROOT_PASSWORD_2
        stty echo 2>/dev/null || true
        printf '\n'

        [ -n "$ROOT_PASSWORD" ] || { warn 'Password cannot be empty.'; continue; }
        [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_2" ] || { warn 'The two passwords do not match.'; continue; }
        case "$ROOT_PASSWORD" in
            *:*) warn 'Do not use a colon in the password for this installer.'; continue ;;
        esac
        unset ROOT_PASSWORD_2
        break
    done
}

[ "$(id -u)" -eq 0 ] || die 'Run this installer as root.'
[ -r /etc/alpine-release ] || die 'This must be run from an Alpine installation ISO.'
[ -b "$DISK" ] || die "Disk $DISK was not found. Check /proc/partitions first."

case "$DISK" in
    /dev/sr*|/dev/loop*) die "$DISK looks like installation media, not a system disk." ;;
esac

DISK_NAME="${DISK##*/}"
[ -r "/sys/class/block/$DISK_NAME/size" ] || die "Cannot read the capacity of $DISK."
DISK_MB=$(( $(cat "/sys/class/block/$DISK_NAME/size") / 2048 ))
[ "$DISK_MB" -ge 850 ] || die "Disk is only about ${DISK_MB} MiB; at least about 850 MiB is required."

# Prefer the interface carrying the default route; otherwise use the first non-loopback interface.
IFACE="$(ip route 2>/dev/null | awk '/^default / {print $5; exit}')"
if [ -z "$IFACE" ]; then
    for p in /sys/class/net/*; do
        n="${p##*/}"
        [ "$n" = lo ] && continue
        IFACE="$n"
        break
    done
fi
[ -n "$IFACE" ] || die 'No network interface was found.'

# Bring networking up when booted from a bare ISO.
ip link set "$IFACE" up 2>/dev/null || true
if ! ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q 'inet '; then
    udhcpc -i "$IFACE" -q -n 2>/dev/null || die "DHCP failed on $IFACE."
fi

# Verify both routing and DNS before erasing the disk.
ping -c 1 -W 3 223.5.5.5 >/dev/null 2>&1 || die 'No external network connectivity.'
nslookup mirrors.aliyun.com >/dev/null 2>&1 || die 'DNS resolution failed.'

ALPINE_RELEASE="$(cat /etc/alpine-release)"
ALPINE_BRANCH="$(printf '%s\n' "$ALPINE_RELEASE" | awk -F. '{print $1"."$2}')"
case "$ALPINE_BRANCH" in
    [0-9]*.[0-9]*) ;;
    *) die "Cannot determine Alpine branch from $ALPINE_RELEASE." ;;
esac
REPO="$MIRROR_BASE/v$ALPINE_BRANCH"

# alpine-virt ISO 可能不自带 setup-alpine，自动补装
if ! command -v setup-alpine >/dev/null 2>&1; then
    say 'setup-alpine is missing; installing alpine-conf automatically'

    # 先尝试使用 ISO 自带的本地软件仓库
    if [ -d /media/cdrom/apks ]; then
        printf '%s\n' '/media/cdrom/apks' > /etc/apk/repositories
        apk add alpine-conf >/dev/null 2>&1 || true
    fi

    # ISO 中没有 alpine-conf 时，改用官方网络仓库
    if ! command -v setup-alpine >/dev/null 2>&1; then
        printf '%s\n' \
            "https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_BRANCH/main" \
            > /etc/apk/repositories

        apk update
        apk add alpine-conf
    fi

    command -v setup-alpine >/dev/null 2>&1 ||
        die 'Could not install setup-alpine automatically.'
fi

case "$SSH_PORT" in
    ''|*[!0-9]*) die 'SSH_PORT must be a number.' ;;
esac
[ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || die 'SSH_PORT must be between 1 and 65535.'

prompt_password

say 'Installation summary'
printf 'Alpine ISO : %s\n' "$ALPINE_RELEASE"
printf 'Target disk: %s (%s MiB)\n' "$DISK" "$DISK_MB"
printf 'Interface  : %s (DHCP)\n' "$IFACE"
printf 'Repository : %s\n' "$REPO"
printf 'SSH port   : %s\n' "$SSH_PORT"
printf 'Packages   : %s\n' "$TARGET_PACKAGES"
printf 'Logs       : /var/log tmpfs %s, messages %s KiB x %s\n' \
    "$LOG_TMPFS_SIZE" "$SYSLOG_FILE_KB" "$((SYSLOG_BACKUPS + 1))"
printf '\nWARNING: ALL DATA ON %s WILL BE ERASED.\n' "$DISK"
printf 'Type ERASE to continue: '
IFS= read -r CONFIRM
[ "$CONFIRM" = ERASE ] || die 'Cancelled.'

cat > /tmp/alpine-answer <<EOF
KEYMAPOPTS=none
HOSTNAMEOPTS="$HOSTNAME"
DEVDOPTS=mdev
INTERFACESOPTS="auto lo
iface lo inet loopback

auto $IFACE
iface $IFACE inet dhcp
    hostname $HOSTNAME
"
DNSOPTS=none
TIMEZONEOPTS="Asia/Shanghai"
PROXYOPTS=none
APKREPOSOPTS="$REPO/main $REPO/community"
USEROPTS=none
SSHDOPTS=openssh
NTPOPTS=busybox
DISKOPTS="-m sys -s 0 $DISK"
LBUOPTS=none
APKCACHEOPTS=none
EOF

# Permit unattended destruction only for the exact target disk.
export ERASE_DISKS="$DISK"
export SWAP_SIZE=0

say 'Installing the minimal Alpine system'
setup-alpine -e -f /tmp/alpine-answer
sync
sleep 2

# The no-swap layout makes the largest partition the root filesystem.
ROOT_PART=''
ROOT_SECTORS=0
for p in /sys/class/block/${DISK_NAME}*; do
    [ -f "$p/partition" ] || continue
    sectors="$(cat "$p/size")"
    if [ "$sectors" -gt "$ROOT_SECTORS" ]; then
        ROOT_SECTORS="$sectors"
        ROOT_PART="/dev/${p##*/}"
    fi
done
[ -n "$ROOT_PART" ] && [ -b "$ROOT_PART" ] || die 'Could not identify the installed root partition.'

cleanup_mounts
trap cleanup_mounts EXIT
mkdir -p /mnt
mount "$ROOT_PART" /mnt

for d in dev proc sys run; do mkdir -p "/mnt/$d"; done
mount -o bind /dev /mnt/dev
mount -o bind /proc /mnt/proc
mount -o bind /sys /mnt/sys
mount -o bind /run /mnt/run
cp /etc/resolv.conf /mnt/etc/resolv.conf

say 'Setting the root password'
printf 'root:%s\n' "$ROOT_PASSWORD" | chroot /mnt chpasswd
unset ROOT_PASSWORD

say 'Writing minimal repositories and installing only compatibility tools'
printf '%s\n%s\n' "$REPO/main" "$REPO/community" > /mnt/etc/apk/repositories
if [ -n "$TARGET_PACKAGES" ]; then
    chroot /mnt apk add --no-cache $TARGET_PACKAGES
fi

say 'Configuring SSH'
mkdir -p /mnt/etc/ssh/sshd_config.d /mnt/run/sshd
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /mnt/etc/ssh/sshd_config; then
    sed -i '1iInclude /etc/ssh/sshd_config.d/*.conf' /mnt/etc/ssh/sshd_config
fi
cat > /mnt/etc/ssh/sshd_config.d/00-node.conf <<EOF
Port $SSH_PORT
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
EOF
chroot /mnt ssh-keygen -A >/dev/null 2>&1 || true
chroot /mnt /usr/sbin/sshd -t
chroot /mnt rc-update add sshd default >/dev/null 2>&1 || true

say 'Keeping only small, useful services'
# Keep: networking, seedrng, syslog, crond, busybox ntpd and sshd.
# acpid is retained when installed because cloud platforms may use it for graceful shutdown.
chroot /mnt rc-update add networking boot >/dev/null 2>&1 || true
chroot /mnt rc-update add syslog boot >/dev/null 2>&1 || true
chroot /mnt rc-update add crond default >/dev/null 2>&1 || true
chroot /mnt rc-update add ntpd default >/dev/null 2>&1 || true

say 'Limiting logs and moving standard logs to RAM'
mkdir -p /mnt/var/log /mnt/etc/conf.d
cat > /mnt/etc/conf.d/syslog <<EOF
SYSLOGD_OPTS="-C64 -O /var/log/messages -s $SYSLOG_FILE_KB -b $SYSLOG_BACKUPS"
KLOGD_OPTS=""
EOF

# A hard upper bound prevents standard logs from consuming the 1 GiB disk.
if ! grep -qE '^[^#]+[[:space:]]+/var/log[[:space:]]+tmpfs' /mnt/etc/fstab; then
    printf 'tmpfs\t/var/log\ttmpfs\trw,nosuid,nodev,noexec,size=%s,mode=0755\t0\t0\n' \
        "$LOG_TMPFS_SIZE" >> /mnt/etc/fstab
fi
rm -rf /mnt/var/log/*

say 'Reducing disk writes and blocking core dumps'
# Add noatime without discarding the installer's existing mount options.
awk 'BEGIN { OFS="\t" }
    /^[[:space:]]*#/ || NF < 4 { print; next }
    $2 == "/" {
        if ($4 == "defaults") $4 = "defaults,noatime"
        else if ($4 !~ /(^|,)noatime(,|$)/) $4 = $4 ",noatime"
    }
    { print }
' /mnt/etc/fstab > /mnt/etc/fstab.new
mv /mnt/etc/fstab.new /mnt/etc/fstab

mkdir -p /mnt/etc/sysctl.d /mnt/etc/profile.d
cat > /mnt/etc/sysctl.d/99-tiny-disk.conf <<'EOF'
fs.suid_dumpable = 0
kernel.core_pattern = /dev/null
EOF
cat > /mnt/etc/profile.d/no-coredump.sh <<'EOF'
ulimit -c 0 2>/dev/null || true
EOF
chmod 644 /mnt/etc/profile.d/no-coredump.sh

# Raise file descriptor allowance for proxy/node daemons started by OpenRC.
if ! grep -q '^rc_ulimit=' /mnt/etc/rc.conf 2>/dev/null; then
    printf '\nrc_ulimit="-n 65535"\n' >> /mnt/etc/rc.conf
fi

say 'Installing automatic cache cleanup and disk guard'
mkdir -p /mnt/usr/local/sbin /mnt/etc/periodic/daily /mnt/etc/periodic/15min
cat > /mnt/usr/local/sbin/clean-space <<'EOF'
#!/bin/sh
rm -rf /var/cache/apk/* /root/.cache/* 2>/dev/null || true
find /tmp /var/tmp -mindepth 1 -mtime +1 -exec rm -rf {} + 2>/dev/null || true
find /var/log -type f -size +512k -exec sh -c ': > "$1"' sh {} \; 2>/dev/null || true
sync
df -h /
EOF
chmod 755 /mnt/usr/local/sbin/clean-space

cat > /mnt/etc/periodic/daily/tiny-disk-clean <<'EOF'
#!/bin/sh
/usr/local/sbin/clean-space >/dev/null 2>&1
EOF
chmod 755 /mnt/etc/periodic/daily/tiny-disk-clean

cat > /mnt/etc/periodic/15min/tiny-disk-guard <<'EOF'
#!/bin/sh
used="$(df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
case "$used" in
    ''|*[!0-9]*) exit 0 ;;
esac
[ "$used" -ge 90 ] && /usr/local/sbin/clean-space >/dev/null 2>&1
exit 0
EOF
chmod 755 /mnt/etc/periodic/15min/tiny-disk-guard

say 'Removing caches and installation leftovers'
rm -rf \
    /mnt/var/cache/apk/* \
    /mnt/root/.cache \
    /mnt/root/.ash_history \
    /mnt/tmp/* \
    /mnt/var/tmp/* \
    /mnt/etc/apk/cache 2>/dev/null || true

# Release the ext4 blocks normally reserved for non-root users (usually about 5%).
if ! command -v tune2fs >/dev/null 2>&1; then
    apk add --no-cache e2fsprogs-extra >/dev/null 2>&1 || \
        apk add --no-cache e2fsprogs >/dev/null 2>&1 || true
fi
if command -v tune2fs >/dev/null 2>&1 && blkid "$ROOT_PART" 2>/dev/null | grep -q 'TYPE="ext[234]"'; then
    tune2fs -m 0 "$ROOT_PART" >/dev/null 2>&1 || true
fi

sync
say 'Final disk usage'
df -h /mnt || true
printf '\nInstalled root partition: %s\n' "$ROOT_PART"
printf 'SSH login: root@SERVER_IP port %s\n' "$SSH_PORT"
printf 'After shutdown, detach the ISO and boot from %s.\n' "$DISK"

cleanup_mounts
trap - EXIT

if [ "$AUTO_POWEROFF" = yes ]; then
    printf '\nPowering off in 10 seconds. Detach the ISO before the next boot.\n'
    sleep 10
    reboot
fi
