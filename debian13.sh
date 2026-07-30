#!/bin/sh
set -eu

# Debian 13 minimal installer for a roughly 1 GiB x86_64 cloud disk.
# Run this from an Alpine installation ISO. The selected disk is erased.

HOSTNAME="${HOSTNAME:-debian-node}"
SSH_PORT="${SSH_PORT:-22}"
AUTO_REBOOT="${AUTO_REBOOT:-no}"
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
DEBIAN_SECURITY_MIRROR="${DEBIAN_SECURITY_MIRROR:-https://security.debian.org/debian-security}"
KERNEL_PACKAGE="${KERNEL_PACKAGE:-linux-image-cloud-amd64}"
DISK_GUARD_PERCENT="${DISK_GUARD_PERCENT:-90}"
MIN_DISK_MIB="${MIN_DISK_MIB:-950}"
MIN_FINAL_FREE_MIB="${MIN_FINAL_FREE_MIB:-96}"
TARGET=/mnt

ERASED=0
INSTALL_COMPLETE=0
TERMINAL_ECHO_DISABLED=0
ROOT_PASSWORD=''
ROOT_PASSWORD_2=''
ROOT_PART=''
ESP_PART=''

say() { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

restore_terminal() {
    if [ "$TERMINAL_ECHO_DISABLED" -eq 1 ]; then
        stty echo 2>/dev/null || true
        TERMINAL_ECHO_DISABLED=0
        printf '\n' >&2
    fi
}

cleanup_mounts() {
    restore_terminal
    sync 2>/dev/null || true
    umount "$TARGET/boot/efi" 2>/dev/null || true
    umount -R "$TARGET/run" 2>/dev/null || umount "$TARGET/run" 2>/dev/null || true
    umount -R "$TARGET/sys" 2>/dev/null || umount "$TARGET/sys" 2>/dev/null || true
    umount "$TARGET/proc" 2>/dev/null || true
    umount -R "$TARGET/dev" 2>/dev/null || umount "$TARGET/dev/pts" 2>/dev/null || true
    umount "$TARGET/dev" 2>/dev/null || true
    umount "$TARGET" 2>/dev/null || true
}

on_exit() {
    status=$?
    trap - 0 INT TERM HUP
    ROOT_PASSWORD=''
    ROOT_PASSWORD_2=''
    cleanup_mounts
    if [ "$status" -ne 0 ] && [ "$ERASED" -eq 1 ] && [ "$INSTALL_COMPLETE" -eq 0 ]; then
        warn "Installation stopped after the disk was erased. $DISK may not be bootable."
        warn 'Do not reboot until the failure is understood; restart from the Alpine ISO when ready.'
    fi
    exit "$status"
}

trap on_exit 0 INT TERM HUP

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command was not found: $1"
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

partition_by_number() {
    number="$1"
    lsblk -nrpo NAME,TYPE,PARTN "$DISK" | awk -v n="$number" '$2 == "part" && $3 == n { print $1; exit }'
}

assert_sshd_value() {
    key="$1"
    value="$2"
    printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fx "$key $value" >/dev/null 2>&1 || \
        die "Effective SSH setting is not '$key $value'."
}

assert_disk_unused() {
    if lsblk -nrpo NAME,MOUNTPOINT "$DISK" | awk 'NF > 1 { found=1 } END { exit !found }'; then
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS "$DISK" >&2
        die "$DISK or one of its partitions is mounted."
    fi

    for node in $(lsblk -nrpo NAME "$DISK"); do
        if awk -v n="$node" 'NR > 1 && $1 == n { found=1 } END { exit !found }' /proc/swaps; then
            die "$node is active swap."
        fi

        node_name="${node##*/}"
        holders="/sys/class/block/$node_name/holders"
        if [ -d "$holders" ] && [ -n "$(ls -A "$holders" 2>/dev/null)" ]; then
            die "$node has active device-mapper, RAID, or other holders."
        fi
    done

    root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    for node in $(lsblk -nrpo NAME "$DISK"); do
        [ "$root_source" != "$node" ] || die "$DISK contains the currently running root filesystem."
    done
}

prompt_password() {
    while :; do
        printf 'Set root password: '
        stty -echo
        TERMINAL_ECHO_DISABLED=1
        IFS= read -r ROOT_PASSWORD || die 'Could not read the root password.'
        stty echo
        TERMINAL_ECHO_DISABLED=0
        printf '\n'

        [ -n "$ROOT_PASSWORD" ] || {
            warn 'The root password cannot be empty.'
            continue
        }

        printf 'Repeat password: '
        stty -echo
        TERMINAL_ECHO_DISABLED=1
        IFS= read -r ROOT_PASSWORD_2 || die 'Could not read the repeated password.'
        stty echo
        TERMINAL_ECHO_DISABLED=0
        printf '\n'

        [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_2" ] || {
            warn 'Password mismatch.'
            ROOT_PASSWORD=''
            ROOT_PASSWORD_2=''
            continue
        }
        ROOT_PASSWORD_2=''
        break
    done
}

[ "$(id -u)" -eq 0 ] || die 'Run this installer as root.'
[ -r /etc/alpine-release ] || die 'Run this installer from an Alpine installation ISO.'
[ "$(uname -m)" = x86_64 ] || die 'Only x86_64/amd64 systems are supported.'
[ -t 0 ] || die 'Interactive terminal input is required; do not pipe input into this installer.'

[ -n "${DISK:-}" ] || die 'DISK must be specified explicitly, for example: DISK=/dev/vda sh debian13.sh'
[ -b "$DISK" ] || die "$DISK is not a block device."
case "$DISK" in
    /dev/sr*|/dev/loop*) die "$DISK looks like installation media, not a system disk." ;;
esac

# Bring up the temporary Alpine network before apk needs a network mirror.
IFACE="$(ip route 2>/dev/null | awk '/^default / { print $5; exit }')"
if [ -z "$IFACE" ]; then
    for path in /sys/class/net/*; do
        name="${path##*/}"
        [ "$name" = lo ] && continue
        IFACE="$name"
        break
    done
fi
[ -n "$IFACE" ] || die 'No network interface was found.'
ip link set "$IFACE" up 2>/dev/null || true
if ! ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q 'inet '; then
    udhcpc -i "$IFACE" -q -n || die "DHCP failed on $IFACE."
fi

say 'Preparing the Alpine installation environment'
# These operations only modify the temporary Alpine ISO environment, not the target disk.
if ! grep -Eq '^[[:space:]]*https?://' /etc/apk/repositories 2>/dev/null; then
    die 'No Alpine network repository is configured. Run setup-apkrepos, select a mirror, then rerun this installer.'
fi
apk update
apk add --no-cache \
    ca-certificates \
    debootstrap \
    dosfstools \
    e2fsprogs \
    sgdisk \
    util-linux

require_command lsblk
require_command findmnt
require_command blockdev

[ "$(lsblk -dn -o TYPE "$DISK" 2>/dev/null | awk 'NR == 1 { print $1 }')" = disk ] || \
    die 'DISK must refer to a whole disk, not a partition.'

DISK_REAL="$(readlink -f "$DISK")"
DISK_NAME="${DISK_REAL##*/}"
[ -d "/sys/class/block/$DISK_NAME" ] || die "Cannot inspect $DISK."
# Use the canonical /dev node so the same path exists inside the chroot.
DISK="$DISK_REAL"

DISK_BYTES="$(blockdev --getsize64 "$DISK")"
DISK_MIB=$((DISK_BYTES / 1024 / 1024))
[ "$DISK_MIB" -ge "$MIN_DISK_MIB" ] || \
    die "Disk is only ${DISK_MIB} MiB; at least ${MIN_DISK_MIB} MiB is required."

case "$HOSTNAME" in
    ''|.*|*..*|*-|_*|*[^A-Za-z0-9.-]*) die 'HOSTNAME contains unsupported characters.' ;;
esac
[ "${#HOSTNAME}" -le 63 ] || die 'HOSTNAME must be at most 63 characters.'

is_uint "$SSH_PORT" || die 'SSH_PORT must be a number.'
[ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || die 'SSH_PORT must be between 1 and 65535.'
is_uint "$DISK_GUARD_PERCENT" || die 'DISK_GUARD_PERCENT must be a number.'
[ "$DISK_GUARD_PERCENT" -ge 50 ] && [ "$DISK_GUARD_PERCENT" -le 99 ] || \
    die 'DISK_GUARD_PERCENT must be between 50 and 99.'
is_uint "$MIN_FINAL_FREE_MIB" || die 'MIN_FINAL_FREE_MIB must be a number.'
case "$AUTO_REBOOT" in yes|no) ;; *) die 'AUTO_REBOOT must be yes or no.' ;; esac
case "$DEBIAN_SUITE" in trixie) ;; *) die 'This installer is intentionally limited to Debian 13 trixie.' ;; esac
case "$KERNEL_PACKAGE" in linux-image-cloud-amd64|linux-image-amd64) ;;
    *) die 'KERNEL_PACKAGE must be linux-image-cloud-amd64 or linux-image-amd64.' ;;
esac

# Refuse disks with mounted children, active swap, or device-mapper/RAID holders.
assert_disk_unused

LOGICAL_SECTOR_SIZE="$(blockdev --getss "$DISK")"
[ "$LOGICAL_SECTOR_SIZE" -eq 512 ] || \
    die 'This 64 MiB ESP layout requires a disk with 512-byte logical sectors.'

for command in debootstrap sgdisk mkfs.vfat mkfs.ext4 tune2fs wipefs partx lsblk findmnt blkid; do
    require_command "$command"
done
[ -e "/usr/share/debootstrap/scripts/$DEBIAN_SUITE" ] || \
    die "The installed debootstrap package does not support $DEBIAN_SUITE. Use a current Alpine ISO and repository."

say 'Checking Debian repository access, DNS, TLS, and system time'
YEAR="$(date +%Y 2>/dev/null || printf 0)"
is_uint "$YEAR" || die 'Cannot read the system year.'
[ "$YEAR" -ge 2024 ] || die 'System time is too old for reliable HTTPS certificate validation.'
wget -q -O /dev/null "$DEBIAN_MIRROR/dists/$DEBIAN_SUITE/InRelease" || \
    die 'Cannot download Debian InRelease metadata over HTTPS.'
wget -q -O /dev/null "$DEBIAN_SECURITY_MIRROR/dists/${DEBIAN_SUITE}-security/InRelease" || \
    die 'Cannot download Debian security metadata over HTTPS.'

prompt_password

DISK_MODEL="$(lsblk -dn -o MODEL "$DISK" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
DISK_SERIAL="$(lsblk -dn -o SERIAL "$DISK" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"

say 'Installation summary'
printf 'Temporary OS : Alpine %s\n' "$(cat /etc/alpine-release)"
printf 'Target OS    : Debian 13 (%s) amd64, minbase\n' "$DEBIAN_SUITE"
printf 'Target disk  : %s (%s MiB)\n' "$DISK" "$DISK_MIB"
printf 'Disk model   : %s\n' "${DISK_MODEL:-unknown}"
printf 'Disk serial  : %s\n' "${DISK_SERIAL:-unknown}"
printf 'Partitions   : GPT; 2 MiB BIOS Boot + 64 MiB ESP + remaining ext4 root\n'
printf 'Kernel       : %s\n' "$KERNEL_PACKAGE"
printf 'Network      : systemd-networkd DHCP (detected now: %s)\n' "$IFACE"
printf 'Hostname     : %s\n' "$HOSTNAME"
printf 'SSH          : root password login on port %s; TCP forwarding enabled\n' "$SSH_PORT"
printf 'Logs         : volatile journald, maximum 8 MiB\n'
printf 'Swap         : none\n'
printf 'Secure Boot  : NOT supported; it must be disabled\n'
printf 'cloud-init   : not installed\n'
printf 'Auto reboot  : %s\n' "$AUTO_REBOOT"
printf '\nWARNING: ALL DATA ON %s WILL BE ERASED.\n' "$DISK"
printf 'Type ERASE to continue: '
IFS= read -r CONFIRM
[ "$CONFIRM" = ERASE ] || die 'Cancelled without changing the target disk.'

# Recheck immediately before the first destructive write in case device state
# changed while the user reviewed the summary.
assert_disk_unused

say 'Erasing and partitioning the target disk'
ERASED=1
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"
sgdisk \
    --new=1:2048:+2M --typecode=1:ef02 --change-name=1:BIOSBOOT \
    --new=2:0:+64M --typecode=2:ef00 --change-name=2:EFI \
    --new=3:0:0 --typecode=3:8304 --change-name=3:rootfs \
    "$DISK"
sgdisk --verify "$DISK"
partx -u "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
command -v mdev >/dev/null 2>&1 && mdev -s || true

attempt=0
while [ "$attempt" -lt 20 ]; do
    ESP_PART="$(partition_by_number 2)"
    ROOT_PART="$(partition_by_number 3)"
    [ -n "$ESP_PART" ] && [ -b "$ESP_PART" ] && [ -n "$ROOT_PART" ] && [ -b "$ROOT_PART" ] && break
    attempt=$((attempt + 1))
    sleep 1
    partx -u "$DISK" 2>/dev/null || true
    command -v mdev >/dev/null 2>&1 && mdev -s || true
done
[ -n "$ESP_PART" ] && [ -b "$ESP_PART" ] || die 'EFI partition device did not appear.'
[ -n "$ROOT_PART" ] && [ -b "$ROOT_PART" ] || die 'Root partition device did not appear.'
BIOS_PART="$(partition_by_number 1)"
[ -n "$BIOS_PART" ] && [ -b "$BIOS_PART" ] || die 'BIOS Boot partition device did not appear.'

[ "$(lsblk -dn -o PARTTYPE "$BIOS_PART" | tr 'A-F' 'a-f')" = 21686148-6449-6e6f-744e-656564454649 ] || \
    die 'BIOS Boot partition type is incorrect.'
[ "$(lsblk -dn -o PARTTYPE "$ESP_PART" | tr 'A-F' 'a-f')" = c12a7328-f81f-11d2-ba4b-00a0c93ec93b ] || \
    die 'EFI partition type is incorrect.'
[ "$(lsblk -dn -o PARTTYPE "$ROOT_PART" | tr 'A-F' 'a-f')" = 4f68bce3-e8cd-4db1-96e7-fbcaf984b709 ] || \
    die 'Root partition type is incorrect.'

say 'Creating filesystems'
mkfs.vfat -F 32 -n EFI "$ESP_PART"
mkfs.ext4 -F -L rootfs -m 0 -J size=8 "$ROOT_PART"
mkdir -p "$TARGET"
mount "$ROOT_PART" "$TARGET"
mkdir -p "$TARGET/boot/efi"
mount "$ESP_PART" "$TARGET/boot/efi"

say 'Bootstrapping Debian minbase'
debootstrap \
    --arch=amd64 \
    --variant=minbase \
    "$DEBIAN_SUITE" \
    "$TARGET" \
    "$DEBIAN_MIRROR"

mkdir -p "$TARGET/dev" "$TARGET/proc" "$TARGET/sys" "$TARGET/run"
mount --rbind /dev "$TARGET/dev"
mount --make-rslave "$TARGET/dev"
mount -t proc proc "$TARGET/proc"
mount --rbind /sys "$TARGET/sys"
mount --make-rslave "$TARGET/sys"
mount --rbind /run "$TARGET/run"
mount --make-rslave "$TARGET/run"
cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"

cat > "$TARGET/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 755 "$TARGET/usr/sbin/policy-rc.d"

say 'Configuring minimal APT and dpkg policies'
mkdir -p "$TARGET/etc/apt/apt.conf.d" "$TARGET/etc/apt/sources.list.d" "$TARGET/etc/dpkg/dpkg.cfg.d"
rm -f "$TARGET/etc/apt/sources.list"
cat > "$TARGET/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: $DEBIAN_MIRROR
Suites: $DEBIAN_SUITE ${DEBIAN_SUITE}-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: $DEBIAN_SECURITY_MIRROR
Suites: ${DEBIAN_SUITE}-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

cat > "$TARGET/etc/apt/apt.conf.d/99-tiny-disk" <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
Acquire::GzipIndexes "true";
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
EOF

cat > "$TARGET/etc/dpkg/dpkg.cfg.d/01_nodoc" <<'EOF'
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/locale.alias
EOF

say 'Installing the kernel, systemd, SSH, and BIOS/UEFI boot files'
chroot "$TARGET" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
chroot "$TARGET" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "$KERNEL_PACKAGE" \
    ca-certificates \
    e2fsprogs \
    grub-common \
    grub-efi-amd64-bin \
    grub-pc-bin \
    grub2-common \
    iproute2 \
    openssh-server \
    systemd-repart \
    systemd-resolved \
    systemd-sysv \
    systemd-timesyncd \
    tzdata
chroot "$TARGET" apt-mark manual "$KERNEL_PACKAGE"
rm -f "$TARGET/usr/sbin/policy-rc.d"

say 'Configuring hostname, time zone, filesystems, and automatic expansion'
printf '%s\n' "$HOSTNAME" > "$TARGET/etc/hostname"
cat > "$TARGET/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME
::1 localhost ip6-localhost ip6-loopback
EOF
ln -snf /usr/share/zoneinfo/Asia/Shanghai "$TARGET/etc/localtime"
printf 'Asia/Shanghai\n' > "$TARGET/etc/timezone"
chroot "$TARGET" dpkg-reconfigure -f noninteractive tzdata >/dev/null

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
ESP_UUID="$(blkid -s UUID -o value "$ESP_PART")"
[ -n "$ROOT_UUID" ] && [ -n "$ESP_UUID" ] || die 'Could not read filesystem UUIDs.'
cat > "$TARGET/etc/fstab" <<EOF
UUID=$ROOT_UUID  /          ext4  defaults,noatime,errors=remount-ro,x-systemd.growfs  0  1
UUID=$ESP_UUID   /boot/efi  vfat  umask=0077,noatime,nofail,x-systemd.device-timeout=10s  0  0
EOF

mkdir -p "$TARGET/etc/repart.d"
cat > "$TARGET/etc/repart.d/50-root.conf" <<'EOF'
[Partition]
Type=root
GrowFileSystem=yes
EOF

say 'Configuring DHCP networking and DNS'
mkdir -p "$TARGET/etc/systemd/network"
cat > "$TARGET/etc/systemd/network/20-wired-dhcp.network" <<'EOF'
[Match]
Type=ether

[Link]
RequiredForOnline=no

[Network]
DHCP=ipv4
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=yes
UseRoutes=yes
UseHostname=no
EOF
rm -f "$TARGET/etc/resolv.conf"
ln -s /run/systemd/resolve/stub-resolv.conf "$TARGET/etc/resolv.conf"

say 'Setting the root password and preserving the requested SSH behavior'
printf 'root:%s\n' "$ROOT_PASSWORD" | chroot "$TARGET" chpasswd
ROOT_PASSWORD=''

mkdir -p "$TARGET/etc/ssh/sshd_config.d" "$TARGET/run/sshd"
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$TARGET/etc/ssh/sshd_config"; then
    sed -i '1iInclude /etc/ssh/sshd_config.d/*.conf' "$TARGET/etc/ssh/sshd_config"
fi
cat > "$TARGET/etc/ssh/sshd_config.d/00-node.conf" <<EOF
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
chroot "$TARGET" ssh-keygen -A >/dev/null
chroot "$TARGET" /usr/sbin/sshd -t
SSHD_EFFECTIVE="$(chroot "$TARGET" /usr/sbin/sshd -T -C "user=root,host=$HOSTNAME,addr=127.0.0.1")"
assert_sshd_value port "$SSH_PORT"
assert_sshd_value permitrootlogin yes
assert_sshd_value passwordauthentication yes
assert_sshd_value kbdinteractiveauthentication no
assert_sshd_value permitemptypasswords no
assert_sshd_value usedns no
assert_sshd_value x11forwarding no
assert_sshd_value allowtcpforwarding yes
assert_sshd_value gatewayports no
assert_sshd_value clientaliveinterval 300
assert_sshd_value clientalivecountmax 2
assert_sshd_value loglevel INFO

say 'Configuring bounded volatile logs, core dumps, and service limits'
mkdir -p \
    "$TARGET/etc/systemd/journald.conf.d" \
    "$TARGET/etc/systemd/coredump.conf.d" \
    "$TARGET/etc/systemd/system.conf.d" \
    "$TARGET/etc/security/limits.d" \
    "$TARGET/etc/sysctl.d"
cat > "$TARGET/etc/systemd/journald.conf.d/00-tiny-disk.conf" <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=8M
RuntimeMaxFileSize=2M
Compress=yes
ForwardToSyslog=no
EOF
cat > "$TARGET/etc/sysctl.d/99-tiny-disk.conf" <<'EOF'
fs.suid_dumpable = 0
kernel.core_pattern = /dev/null
EOF
cat > "$TARGET/etc/systemd/coredump.conf.d/00-disable.conf" <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
cat > "$TARGET/etc/security/limits.d/99-no-core.conf" <<'EOF'
* soft core 0
* hard core 0
root soft core 0
root hard core 0
EOF
cat > "$TARGET/etc/systemd/system.conf.d/00-tiny-disk.conf" <<'EOF'
[Manager]
DefaultLimitCORE=0
DefaultLimitNOFILE=65535
EOF

say 'Installing safe automatic cleanup and disk guard timers'
mkdir -p "$TARGET/usr/local/sbin" "$TARGET/etc/systemd/system" "$TARGET/etc/tmpfiles.d"
cat > "$TARGET/usr/local/sbin/tiny-disk-clean" <<EOF
#!/bin/sh
set -u
mode="\${1:-daily}"
limit=$DISK_GUARD_PERCENT
usage() {
    df -P / | awk 'NR == 2 { gsub(/%/, "", \$5); print \$5 }'
}
if [ "\$mode" = guard ]; then
    used="\$(usage)"
    case "\$used" in ''|*[!0-9]*) exit 0 ;; esac
    [ "\$used" -ge "\$limit" ] || exit 0
fi
# apt-get clean obtains APT locks. If another package operation is active,
# skip package-cache cleanup instead of deleting files behind its back.
apt-get clean >/dev/null 2>&1 || true
rm -rf /root/.cache/* 2>/dev/null || true
systemd-tmpfiles --clean /etc/tmpfiles.d/tiny-disk.conf >/dev/null 2>&1 || true
find /var/log/apt /var/log -maxdepth 1 -type f -size +512k \
    -exec sh -c ': > "\$1"' sh {} \; 2>/dev/null || true
if [ "\$mode" = guard ]; then
    used="\$(usage)"
    case "\$used" in ''|*[!0-9]*) exit 0 ;; esac
    if [ "\$used" -ge "\$limit" ]; then
        logger -p daemon.warning -t tiny-disk-clean \
            "Root filesystem remains at \${used}% after safe cleanup"
    fi
fi
exit 0
EOF
chmod 755 "$TARGET/usr/local/sbin/tiny-disk-clean"

cat > "$TARGET/etc/tmpfiles.d/tiny-disk.conf" <<'EOF'
d /tmp     1777 root root 1d
d /var/tmp 1777 root root 1d
EOF
cat > "$TARGET/etc/systemd/system/tiny-disk-clean.service" <<'EOF'
[Unit]
Description=Clean safe disposable files on a tiny root disk

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tiny-disk-clean daily
EOF
cat > "$TARGET/etc/systemd/system/tiny-disk-clean.timer" <<'EOF'
[Unit]
Description=Daily tiny disk cleanup

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=45m
Unit=tiny-disk-clean.service

[Install]
WantedBy=timers.target
EOF
cat > "$TARGET/etc/systemd/system/tiny-disk-guard.service" <<'EOF'
[Unit]
Description=Clean disposable files when the root disk is nearly full

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tiny-disk-clean guard
EOF
cat > "$TARGET/etc/systemd/system/tiny-disk-guard.timer" <<'EOF'
[Unit]
Description=Check tiny root disk usage every 15 minutes

[Timer]
OnBootSec=10m
OnUnitActiveSec=15m
AccuracySec=1m
Unit=tiny-disk-guard.service

[Install]
WantedBy=timers.target
EOF

say 'Configuring the cloud initramfs and serial console'
mkdir -p "$TARGET/etc/initramfs-tools"
cat >> "$TARGET/etc/initramfs-tools/modules" <<'EOF'
virtio_pci
virtio_blk
virtio_scsi
virtio_net
nvme
EOF
if [ -f "$TARGET/etc/initramfs-tools/initramfs.conf" ]; then
    sed -i 's/^MODULES=.*/MODULES=most/' "$TARGET/etc/initramfs-tools/initramfs.conf"
fi
mkdir -p "$TARGET/etc/default"
cat > "$TARGET/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=1
GRUB_DISTRIBUTOR=Debian
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF
chroot "$TARGET" update-initramfs -u -k all

KERNEL_CONFIG="$(ls "$TARGET"/boot/config-* 2>/dev/null | sort | tail -n 1)"
[ -n "$KERNEL_CONFIG" ] && [ -f "$KERNEL_CONFIG" ] || die 'No installed kernel configuration was found.'
for option in CONFIG_VIRTIO_PCI CONFIG_VIRTIO_BLK CONFIG_VIRTIO_NET CONFIG_BLK_DEV_NVME; do
    grep -Eq "^${option}=[my]$" "$KERNEL_CONFIG" || die "Installed kernel lacks $option."
done

say 'Installing BIOS and UEFI GRUB'
chroot "$TARGET" grub-install --target=i386-pc --recheck "$DISK"
chroot "$TARGET" grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=debian \
    --no-nvram \
    --recheck
chroot "$TARGET" grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=debian \
    --removable \
    --no-nvram \
    --recheck
chroot "$TARGET" update-grub
chroot "$TARGET" grub-script-check /boot/grub/grub.cfg

say 'Enabling only the required services'
chroot "$TARGET" systemctl enable systemd-networkd.service
chroot "$TARGET" systemctl enable systemd-resolved.service
chroot "$TARGET" systemctl enable systemd-timesyncd.service
chroot "$TARGET" systemctl disable systemd-networkd-wait-online.service >/dev/null 2>&1 || true
chroot "$TARGET" systemctl enable ssh.service
# On first boot, ssh.service pulls in sshd-keygen.service to create host keys.
chroot "$TARGET" systemctl enable tiny-disk-clean.timer
chroot "$TARGET" systemctl enable tiny-disk-guard.timer

say 'Validating the installed system'
[ ! -e "$TARGET/usr/sbin/policy-rc.d" ] || die 'policy-rc.d was not removed.'
[ -f "$TARGET/boot/efi/EFI/BOOT/BOOTX64.EFI" ] || die 'UEFI fallback bootloader is missing.'
[ -d "$TARGET/boot/grub/i386-pc" ] || die 'BIOS GRUB modules are missing.'
[ -d "$TARGET/boot/grub/x86_64-efi" ] || die 'UEFI GRUB modules are missing.'
[ -s "$TARGET/boot/grub/grub.cfg" ] || die 'GRUB configuration is missing.'
[ -z "$(chroot "$TARGET" dpkg --audit)" ] || die 'dpkg reports incomplete package state.'
chroot "$TARGET" apt-get check
chroot "$TARGET" dpkg-query -W -f='${db:Status-Status}\n' "$KERNEL_PACKAGE" | grep -Fx installed >/dev/null || \
    die 'The kernel metapackage is not installed.'
ls "$TARGET"/boot/vmlinuz-* >/dev/null 2>&1 || die 'No kernel image was installed.'
ls "$TARGET"/boot/initrd.img-* >/dev/null 2>&1 || die 'No initramfs was generated.'
chroot "$TARGET" systemd-analyze verify \
    /etc/systemd/system/tiny-disk-clean.service \
    /etc/systemd/system/tiny-disk-clean.timer \
    /etc/systemd/system/tiny-disk-guard.service \
    /etc/systemd/system/tiny-disk-guard.timer
chroot "$TARGET" systemd-analyze cat-config systemd/journald.conf | grep -F 'Storage=volatile' >/dev/null || \
    die 'Volatile journald storage is not effective.'
chroot "$TARGET" systemd-repart --dry-run=yes "$DISK" >/dev/null || \
    die 'systemd-repart rejected the root expansion layout.'

say 'Removing caches, documentation leftovers, and machine-specific identity'
chroot "$TARGET" apt-get clean
rm -rf \
    "$TARGET/var/lib/apt/lists/"* \
    "$TARGET/var/cache/apt/archives/"* \
    "$TARGET/root/.cache/"* \
    "$TARGET/root/.bash_history" \
    "$TARGET/root/.ash_history" \
    "$TARGET/tmp/"* \
    "$TARGET/var/tmp/"* 2>/dev/null || true
find "$TARGET/usr/share/man" "$TARGET/usr/share/info" -mindepth 1 -delete 2>/dev/null || true
find "$TARGET/usr/share/doc" -type f ! -name copyright -delete 2>/dev/null || true
find "$TARGET/usr/share/doc" -depth -type d -empty -delete 2>/dev/null || true
find "$TARGET/usr/share/locale" -mindepth 1 ! -name locale.alias -delete 2>/dev/null || true

# The cloned image receives a unique machine identity on first boot. Keep the
# generated SSH host keys for a directly installed machine; use the sealing
# helper below immediately before turning a tested VM into a reusable image.
printf 'uninitialized\n' > "$TARGET/etc/machine-id"
mkdir -p "$TARGET/var/lib/dbus"
rm -f "$TARGET/var/lib/dbus/machine-id"
ln -s /etc/machine-id "$TARGET/var/lib/dbus/machine-id"
rm -f "$TARGET/var/lib/systemd/random-seed"
rm -rf "$TARGET/run/systemd/netif/leases/"* "$TARGET/var/lib/systemd/network/"* 2>/dev/null || true

cat > "$TARGET/usr/local/sbin/tiny-image-seal" <<'EOF'
#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }
[ -t 0 ] || { echo 'Interactive console input is required.' >&2; exit 1; }
printf 'This removes SSH host keys and machine identity. Type SEAL: '
IFS= read -r answer
[ "$answer" = SEAL ] || { echo 'Cancelled.'; exit 1; }
systemctl stop ssh.service 2>/dev/null || true
rm -f /etc/ssh/ssh_host_* /var/lib/systemd/random-seed
printf 'uninitialized\n' > /etc/machine-id
mkdir -p /var/lib/dbus
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
rm -rf /run/systemd/netif/leases/* /var/lib/systemd/network/* 2>/dev/null || true
apt-get clean >/dev/null 2>&1 || true
rm -rf /var/lib/apt/lists/* /root/.cache/* /tmp/* /var/tmp/* 2>/dev/null || true
rm -f /root/.bash_history /root/.ash_history
sync
echo 'Image sealed. Shut down now and do not boot this source VM again before capture.'
EOF
chmod 755 "$TARGET/usr/local/sbin/tiny-image-seal"

sync
FREE_MIB="$(df -Pm "$TARGET" | awk 'NR == 2 { print $4 }')"
is_uint "$FREE_MIB" || die 'Could not determine final free disk space.'
[ "$FREE_MIB" -ge "$MIN_FINAL_FREE_MIB" ] || \
    die "Only ${FREE_MIB} MiB remains; at least ${MIN_FINAL_FREE_MIB} MiB is required."

say 'Final disk usage before unmounting'
df -h "$TARGET" "$TARGET/boot/efi"
printf 'Installed root partition: %s\n' "$ROOT_PART"
printf 'SSH login: root@SERVER_IP port %s (password authentication enabled)\n' "$SSH_PORT"

cleanup_mounts
if findmnt -rn "$ROOT_PART" >/dev/null 2>&1 || findmnt -rn "$ESP_PART" >/dev/null 2>&1; then
    die 'A target filesystem is still mounted; refusing to run offline filesystem checks.'
fi

say 'Running offline filesystem checks'
e2fsck -fn "$ROOT_PART"
fsck.fat -n "$ESP_PART"
sgdisk --verify "$DISK"

INSTALL_COMPLETE=1
trap - 0 INT TERM HUP
sync
say 'Debian installation completed successfully'
printf 'Disk       : %s\n' "$DISK"
printf 'Root       : %s\n' "$ROOT_PART"
printf 'SSH        : root@SERVER_IP port %s\n' "$SSH_PORT"
printf 'Boot modes : Legacy BIOS and UEFI (Secure Boot must be disabled)\n'
printf 'Important  : detach the Alpine ISO before booting from the target disk.\n'
printf 'Cloud image: the root password is preserved; change it after cloning/importing.\n'

if [ "$AUTO_REBOOT" = yes ]; then
    warn 'Rebooting in 10 seconds. Detach the Alpine ISO now.'
    sleep 10
    reboot
else
    printf '\nAUTO_REBOOT=no, so the machine was not rebooted.\n'
    printf 'Detach the Alpine ISO, then run: reboot\n'
fi
