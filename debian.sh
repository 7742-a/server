#!/bin/sh
set -eu

# ============================================================================
# Debian tiny-node installer for a ~1 GiB disk (converted from the Alpine
# vnc.sh approach). Run from a Debian Live ISO / rescue shell as root.
# It also works from an Alpine ISO (debootstrap is auto-installed via apk).
# Installs the OS only; extra software (3x-ui etc.) is installed after login.
#
# WARNING: The selected disk will be erased completely.
#
# Common overrides:
#   DISK=/dev/vda SUITE=trixie SSH_PORT=22 sh debian-tiny.sh
# ============================================================================

DISK="${DISK:-/dev/vda}"
HOSTNAME="${HOSTNAME:-debian-node}"
SUITE="${SUITE:-trixie}"                       # Debian 13 (stable). bookworm also works.
MIRROR="${MIRROR:-http://mirrors.aliyun.com/debian}"
SEC_MIRROR="${SEC_MIRROR:-http://mirrors.aliyun.com/debian-security}"
SSH_PORT="${SSH_PORT:-22}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
LOG_TMPFS_SIZE="${LOG_TMPFS_SIZE:-16m}"        # /var/log lives in RAM
TMP_TMPFS_SIZE="${TMP_TMPFS_SIZE:-32m}"        # /tmp lives in RAM
JOURNAL_MAX="${JOURNAL_MAX:-8M}"               # journald volatile cap
KERNEL_PKG="${KERNEL_PKG:-linux-image-cloud-amd64}"   # small cloud kernel
AUTO_REBOOT="${AUTO_REBOOT:-yes}"

# 512MB RAM node: a small zram swap prevents OOM under load peaks.
ZRAM_SIZE_MB="${ZRAM_SIZE_MB:-128}"

# Minimal compatibility tools for node install scripts (busybox equivalents
# are already in the base system; these are the usual missing ones).
EXTRA_PACKAGES="${EXTRA_PACKAGES:-bash curl wget ca-certificates}"

say()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

cleanup_mounts() {
    umount /mnt/boot/efi 2>/dev/null || true
    umount /mnt/run  2>/dev/null || true
    umount /mnt/sys  2>/dev/null || true
    umount /mnt/proc 2>/dev/null || true
    umount /mnt/dev  2>/dev/null || true
    umount /mnt      2>/dev/null || true
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

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die 'Run this installer as root.'
[ -b "$DISK" ]       || die "Disk $DISK was not found. Check /proc/partitions first."
[ "$(uname -m)" = x86_64 ] || die 'This installer currently supports x86_64 only.'

case "$DISK" in
    /dev/sr*|/dev/loop*) die "$DISK looks like installation media, not a system disk." ;;
esac

DISK_NAME="${DISK##*/}"
[ -r "/sys/class/block/$DISK_NAME/size" ] || die "Cannot read the capacity of $DISK."
DISK_MB=$(( $(cat "/sys/class/block/$DISK_NAME/size") / 2048 ))
[ "$DISK_MB" -ge 900 ] || die "Disk is only about ${DISK_MB} MiB; at least about 900 MiB is required."

if [ -d /sys/firmware/efi ]; then BOOT_MODE=uefi; else BOOT_MODE=bios; fi

# Network must be up before we wipe anything.
IFACE="$(ip route 2>/dev/null | awk '/^default / {print $5; exit}')"
if [ -z "$IFACE" ]; then
    for p in /sys/class/net/*; do
        n="${p##*/}"; [ "$n" = lo ] && continue; IFACE="$n"; break
    done
fi
[ -n "$IFACE" ] || die 'No network interface was found.'
ip link set "$IFACE" up 2>/dev/null || true
if ! ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q 'inet '; then
    if command -v dhclient   >/dev/null 2>&1; then dhclient -1 "$IFACE"   || die "DHCP failed on $IFACE."
    elif command -v udhcpc   >/dev/null 2>&1; then udhcpc -i "$IFACE" -q -n || die "DHCP failed on $IFACE."
    elif command -v dhcpcd   >/dev/null 2>&1; then dhcpcd -1 "$IFACE"     || die "DHCP failed on $IFACE."
    else die 'No DHCP client available in the live environment.'; fi
fi
ping -c 1 -W 3 223.5.5.5 >/dev/null 2>&1 || die 'No external network connectivity.'
getent hosts mirrors.aliyun.com >/dev/null 2>&1 || die 'DNS resolution failed.'

# ---------------------------------------------------------------------------
# Live-environment tooling (debootstrap, filesystem tools)
# ---------------------------------------------------------------------------
need_live_pkgs=''
command -v debootstrap >/dev/null 2>&1 || need_live_pkgs="$need_live_pkgs debootstrap"
command -v sfdisk      >/dev/null 2>&1 || need_live_pkgs="$need_live_pkgs sfdisk"
command -v mkfs.ext4   >/dev/null 2>&1 || need_live_pkgs="$need_live_pkgs mkfs.ext4"
if [ "$BOOT_MODE" = uefi ]; then
    command -v mkfs.vfat >/dev/null 2>&1 || need_live_pkgs="$need_live_pkgs mkfs.vfat"
fi
command -v curl >/dev/null 2>&1 || need_live_pkgs="$need_live_pkgs curl"

if [ -n "$need_live_pkgs" ]; then
    say "Installing live-environment tools:$need_live_pkgs"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        # shellcheck disable=SC2086
        apt-get install -y --no-install-recommends $need_live_pkgs fdisk dosfstools e2fsprogs >/dev/null
    elif command -v apk >/dev/null 2>&1; then
        # Alpine ISO: debootstrap lives in the community repo. Make sure the
        # network repositories are configured AND the apk index is refreshed
        # (a bare ISO often only lists the cdrom, and an added repo is
        # invisible until `apk update` runs).
        REL="$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || echo 3.20)"
        ALPINE_MIRROR="${ALPINE_MIRROR:-https://mirrors.aliyun.com/alpine}"
        if ! grep -qE '^\s*http' /etc/apk/repositories 2>/dev/null; then
            printf '%s\n%s\n' \
                "$ALPINE_MIRROR/v$REL/main" \
                "$ALPINE_MIRROR/v$REL/community" \
                >> /etc/apk/repositories
        elif ! grep -q 'community' /etc/apk/repositories 2>/dev/null; then
            printf '%s\n' "$ALPINE_MIRROR/v$REL/community" >> /etc/apk/repositories
        fi
        apk update
        apk add debootstrap util-linux e2fsprogs dosfstools curl sfdisk 2>/dev/null \
            || apk add debootstrap util-linux e2fsprogs dosfstools curl
    else
        die "Cannot install:$need_live_pkgs — no apt-get or apk in this live environment."
    fi
fi
command -v debootstrap >/dev/null 2>&1 || die 'debootstrap is unavailable.'

case "$SSH_PORT" in ''|*[!0-9]*) die 'SSH_PORT must be a number.' ;; esac
[ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || die 'SSH_PORT must be between 1 and 65535.'

prompt_password

say 'Installation summary'
printf 'Boot mode  : %s\n' "$BOOT_MODE"
printf 'Suite      : %s (%s)\n' "$SUITE" "$MIRROR"
printf 'Target disk: %s (%s MiB)\n' "$DISK" "$DISK_MB"
printf 'Interface  : %s (DHCP)\n' "$IFACE"
printf 'Kernel     : %s\n' "$KERNEL_PKG"
printf 'SSH port   : %s\n' "$SSH_PORT"
printf 'Logs       : /var/log tmpfs %s, journald volatile %s, daily cleanup\n' \
    "$LOG_TMPFS_SIZE" "$JOURNAL_MAX"
printf '\nWARNING: ALL DATA ON %s WILL BE ERASED.\n' "$DISK"
printf 'Type ERASE to continue: '
IFS= read -r CONFIRM
[ "$CONFIRM" = ERASE ] || die 'Cancelled.'

# ---------------------------------------------------------------------------
# Partition + format (no swap, ext4 with 0%% reserved blocks)
# ---------------------------------------------------------------------------
say "Partitioning $DISK"
wipefs -a "$DISK" >/dev/null 2>&1 || true
if [ "$BOOT_MODE" = uefi ]; then
    sfdisk --quiet "$DISK" <<'EOF'
label: gpt
unit: MiB

start=1, size=64, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="efi"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root"
EOF
else
    sfdisk --quiet "$DISK" <<'EOF'
label: dos
unit: MiB

start=1, type=83, bootable
EOF
fi
partprobe "$DISK" 2>/dev/null || true
sleep 2
udevadm settle 2>/dev/null || true

part_by_num() {
    for p in /sys/class/block/"$DISK_NAME"*; do
        [ -f "$p/partition" ] || continue
        [ "$(cat "$p/partition")" = "$1" ] && { printf '/dev/%s\n' "${p##*/}"; return 0; }
    done
    return 1
}

if [ "$BOOT_MODE" = uefi ]; then
    EFI_PART="$(part_by_num 1)";  [ -b "$EFI_PART" ]  || die 'EFI partition not found.'
    ROOT_PART="$(part_by_num 2)"; [ -b "$ROOT_PART" ] || die 'Root partition not found.'
    mkfs.vfat -F 32 -n EFI "$EFI_PART" >/dev/null
else
    EFI_PART=''
    ROOT_PART="$(part_by_num 1)"; [ -b "$ROOT_PART" ] || die 'Root partition not found.'
fi
mkfs.ext4 -F -m 0 -L root "$ROOT_PART" >/dev/null

cleanup_mounts
trap cleanup_mounts EXIT
mkdir -p /mnt
mount "$ROOT_PART" /mnt
if [ -n "$EFI_PART" ]; then
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
fi

# ---------------------------------------------------------------------------
# Space-saving dpkg/apt policy is written BEFORE debootstrap so even the
# base system skips docs/manpages/locales and never keeps .deb archives.
# ---------------------------------------------------------------------------
mkdir -p /mnt/etc/dpkg/dpkg.cfg.d /mnt/etc/apt/apt.conf.d
cat > /mnt/etc/dpkg/dpkg.cfg.d/01-nodoc <<'EOF'
path-exclude /usr/share/doc/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
path-exclude /usr/share/locale/*
EOF
cat > /mnt/etc/apt/apt.conf.d/99-tiny <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
APT::Keep-Downloaded-Packages "false";
DPkg::Post-Invoke {"rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb 2>/dev/null || true";};
APT::Update::Post-Invoke {"rm -f /var/cache/apt/archives/*.deb 2>/dev/null || true";};
EOF

# ---------------------------------------------------------------------------
# Bootstrap the base system
# ---------------------------------------------------------------------------
say "Bootstrapping Debian $SUITE (minbase)"
debootstrap --variant=minbase --arch=amd64 "$SUITE" /mnt "$MIRROR"

for d in dev proc sys run; do mkdir -p "/mnt/$d"; done
mount -o bind /dev  /mnt/dev
mount -o bind /proc /mnt/proc
mount -o bind /sys  /mnt/sys
mount -o bind /run  /mnt/run
cp -L /etc/resolv.conf /mnt/etc/resolv.conf

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
EFI_UUID=''
[ -n "$EFI_PART" ] && EFI_UUID="$(blkid -s UUID -o value "$EFI_PART")"

# ---------------------------------------------------------------------------
# In-chroot post-installation script
# ---------------------------------------------------------------------------
say 'Writing post-install configuration'
cat > /mnt/root/postinstall.sh <<'POSTEOF'
#!/bin/bash
set -eu
export DEBIAN_FRONTEND=noninteractive

echo '[chroot] apt sources + initramfs policy'
cat > /etc/apt/sources.list <<EOF
deb $MIRROR $SUITE main
deb $MIRROR $SUITE-updates main
deb $SEC_MIRROR $SUITE-security main
EOF
# Small initramfs: only modules needed by this machine (~saves 50+ MB).
mkdir -p /etc/initramfs-tools/conf.d
echo 'MODULES=dep' > /etc/initramfs-tools/conf.d/tiny.conf

echo '[chroot] installing minimal packages'
apt-get update -qq
if [ "$BOOT_MODE" = uefi ]; then GRUB_PKG=grub-efi-amd64; else GRUB_PKG=grub-pc; fi
if [ "$GRUB_PKG" = grub-pc ]; then
    printf 'grub-pc grub-pc/install_devices multiselect %s\n' "$DISK" | debconf-set-selections
    printf 'grub-pc grub-pc/install_devices_disks_changed multiselect %s\n' "$DISK" | debconf-set-selections
fi
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends \
    systemd-sysv udev dbus openssh-server zram-tools \
    "$KERNEL_PKG" "$GRUB_PKG" \
    $EXTRA_PACKAGES

echo '[chroot] zram swap (compressed RAM swap, no disk wear)'
cat > /etc/default/zramswap <<EOF
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
# Hard cap so zram never exceeds the configured size on larger-RAM machines.
if [ -n "$ZRAM_SIZE_MB" ] && [ "$ZRAM_SIZE_MB" -gt 0 ] 2>/dev/null; then
    printf 'SIZE=%s\n' "$ZRAM_SIZE_MB" >> /etc/default/zramswap
fi
systemctl enable zramswap >/dev/null 2>&1 || true

echo '[chroot] trim memory-hungry services for a 512MB node'
# None of these are needed on a headless proxy node.
systemctl mask \
    apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer \
    e2scrub_all.timer e2scrub_reap.service \
    systemd-logind.service >/dev/null 2>&1 || true
# Note: apt-daily is masked because background apt updates would spike both
# RAM and disk on a 1GB machine. Run `apt-get update && apt-get upgrade`
# manually when you actually want updates.

echo '[chroot] identity, timezone, root password'
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
EOF
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd

echo '[chroot] SSH'
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-node.conf <<EOF
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

echo '[chroot] networking via systemd-networkd + resolved (no ifupdown/NM)'
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/20-dhcp.network <<'EOF'
[Match]
Name=en* eth* ens* enp*

[Network]
DHCP=yes
DNS=223.5.5.5
DNS=119.29.29.29

[DHCPv4]
UseDNS=false
EOF
systemctl enable systemd-networkd systemd-resolved >/dev/null 2>&1
rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

echo '[chroot] journald: RAM-only, hard size cap'
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-tiny.conf <<EOF
[Journal]
Storage=volatile
RuntimeMaxUse=$JOURNAL_MAX
MaxFileSec=1day
ForwardToSyslog=no
ForwardToConsole=no
EOF
mkdir -p /etc/systemd/coredump.conf.d
cat > /etc/systemd/coredump.conf.d/99-none.conf <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

echo '[chroot] sysctl + limits + BBR'
mkdir -p /etc/sysctl.d /etc/security/limits.d /etc/systemd/system.conf.d /etc/modules-load.d
cat > /etc/sysctl.d/99-tiny-node.conf <<'EOF'
# no core dumps eating the disk
fs.suid_dumpable = 0
kernel.core_pattern = /dev/null
vm.swappiness = 10
# proxy/node friendly TCP settings
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
EOF
echo 'tcp_bbr' > /etc/modules-load.d/bbr.conf
cat > /etc/security/limits.d/99-nofile.conf <<'EOF'
* soft nofile 65535
* hard nofile 65535
EOF
cat > /etc/systemd/system.conf.d/99-nofile.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=65535
EOF

echo '[chroot] fstab: noatime, /var/log and /tmp in RAM'
cat > /etc/fstab <<EOF
UUID=$ROOT_UUID  /          ext4   rw,noatime,errors=remount-ro            0 1
tmpfs            /var/log   tmpfs  rw,nosuid,nodev,noexec,size=$LOG_TMPFS_SIZE,mode=0755 0 0
tmpfs            /tmp       tmpfs  rw,nosuid,nodev,size=$TMP_TMPFS_SIZE,mode=1777        0 0
EOF
if [ -n "$EFI_UUID" ]; then
    printf 'UUID=%s  /boot/efi  vfat  rw,noatime,umask=0077  0 1\n' "$EFI_UUID" >> /etc/fstab
fi

echo '[chroot] bootloader'
mkdir -p /etc/default/grub.d
printf 'GRUB_TIMEOUT=2\nGRUB_RECORDFAIL_TIMEOUT=2\n' > /etc/default/grub.d/15-timeout.cfg
if [ "$BOOT_MODE" = uefi ]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram
else
    grub-install "$DISK"
fi
update-grub

echo '[chroot] automatic cleanup + disk guard (systemd timers)'
cat > /usr/local/sbin/clean-space <<'EOF'
#!/bin/sh
# Frees disk/RAM-log space. Safe to run any time.
apt-get clean 2>/dev/null || true
rm -rf /var/cache/apt/archives/* /root/.cache/* 2>/dev/null || true
journalctl --vacuum-size=4M >/dev/null 2>&1 || true
# Truncate any oversized log file.
find /var/log -type f -size +1M -exec truncate -s 0 {} + 2>/dev/null || true
find /tmp /var/tmp -mindepth 1 -mtime +1 -exec rm -rf {} + 2>/dev/null || true
sync
df -h /
EOF
chmod 755 /usr/local/sbin/clean-space

cat > /usr/local/sbin/disk-guard <<'EOF'
#!/bin/sh
# If / is >= 90% full, clean aggressively.
used="$(df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
case "$used" in ''|*[!0-9]*) exit 0 ;; esac
if [ "$used" -ge 90 ]; then
    journalctl --vacuum-size=2M >/dev/null 2>&1 || true
    find /var/log -type f -size +256k -exec truncate -s 0 {} + 2>/dev/null || true
    /usr/local/sbin/clean-space >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 755 /usr/local/sbin/disk-guard

cat > /etc/systemd/system/clean-space.service <<'EOF'
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/clean-space
EOF
cat > /etc/systemd/system/clean-space.timer <<'EOF'
[Timer]
OnCalendar=daily
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/disk-guard.service <<'EOF'
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/disk-guard
EOF
cat > /etc/systemd/system/disk-guard.timer <<'EOF'
[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
systemctl enable clean-space.timer disk-guard.timer fstrim.timer >/dev/null 2>&1

echo '[chroot] final cleanup'
apt-get clean || true
rm -rf /var/lib/apt/lists/* /var/cache/apt/* \
       /var/cache/debconf/*-old \
       /root/.cache /root/.bash_history \
       /tmp/* /var/tmp/* 2>/dev/null || true
rm -f /root/postinstall.sh
POSTEOF
chmod 755 /mnt/root/postinstall.sh

say 'Running post-install inside chroot'
chroot /mnt env \
    BOOT_MODE="$BOOT_MODE" DISK="$DISK" HOSTNAME="$HOSTNAME" \
    MIRROR="$MIRROR" SEC_MIRROR="$SEC_MIRROR" SUITE="$SUITE" \
    SSH_PORT="$SSH_PORT" TIMEZONE="$TIMEZONE" ROOT_PASSWORD="$ROOT_PASSWORD" \
    LOG_TMPFS_SIZE="$LOG_TMPFS_SIZE" TMP_TMPFS_SIZE="$TMP_TMPFS_SIZE" \
    JOURNAL_MAX="$JOURNAL_MAX" KERNEL_PKG="$KERNEL_PKG" \
    EXTRA_PACKAGES="$EXTRA_PACKAGES" EFI_UUID="$EFI_UUID" \
    ZRAM_SIZE_MB="$ZRAM_SIZE_MB" \
    bash /root/postinstall.sh
unset ROOT_PASSWORD

sync
say 'Final disk usage'
df -h /mnt
printf '\nInstalled root partition: %s (boot mode: %s)\n' "$ROOT_PART" "$BOOT_MODE"
printf 'SSH login: root@SERVER_IP port %s\n' "$SSH_PORT"
printf 'After shutdown, detach the ISO and boot from %s.\n' "$DISK"

cleanup_mounts
trap - EXIT

if [ "$AUTO_REBOOT" = yes ]; then
    printf '\nRebooting in 10 seconds. Detach the ISO before the next boot.\n'
    sleep 10
    reboot
fi
