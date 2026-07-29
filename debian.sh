#!/bin/sh
# ============================================================================
# Debian tiny-node installer for a ~1 GiB disk / 512 MiB RAM node.
# Runs FROM a tiny Alpine live ISO (the 66 MB mini rootfs is enough).
#
# Uses InstallNET.sh to reinstall Debian unattended via network, and passes
# our hardening script through its "-cmd" hook, which InstallNET writes into
# the new system and runs once on first boot (base64-decoded via crontab).
#
# WARNING: the target disk is fully erased. Boot the Alpine ISO, then:
#   wget -qO /tmp/t.sh <this script URL> && sh /tmp/t.sh
# ============================================================================
set -e

# ---- user-tunable settings (env overrides) ---------------------------------
PORT="${PORT:-22}"                       # SSH port
PASSWORD="${PASSWORD:-}"                 # root password; asked if empty
SUITE="${SUITE:-13}"                     # Debian 13 (trixie)
MIRROR="${MIRROR:-http://mirrors.aliyun.com/debian/}"
LOG_TMPFS_SIZE="${LOG_TMPFS_SIZE:-16m}"  # /var/log lives in RAM
TMP_TMPFS_SIZE="${TMP_TMPFS_SIZE:-32m}"  # /tmp lives in RAM
JOURNAL_MAX="${JOURNAL_MAX:-8M}"         # journald RAM cap
ZRAM_MB="${ZRAM_MB:-128}"                # zram swap size (0 disables)
INSTALLNET_URL="${INSTALLNET_URL:-https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh}"

echo '=== Debian tiny-node installer (from Alpine live ISO) ==='
[ "$(id -u)" = 0 ] || { echo 'Error: must run as root.'; exit 1; }

# ---- ask for a root password if not provided -------------------------------
if [ -z "$PASSWORD" ]; then
    printf 'Root password [default: yiwan123]: ' >/dev/tty
    IFS= read -r PASSWORD </dev/tty || PASSWORD=''
    [ -z "$PASSWORD" ] && PASSWORD='yiwan123'
fi
echo "SSH port: $PORT"
echo "Install starts in 5 seconds, Ctrl-C to abort..."
sleep 5

# ---- minimal tooling inside the Alpine live environment --------------------
apk update >/dev/null 2>&1 || true
apk add bash curl >/dev/null 2>&1 || true

# ---- extract current network config to give Debian a STATIC IP -------------
IFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}' | tr -d '[:space:]')"
IPADDR="$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1 | tr -d '[:space:]')"
GATEWAY="$(ip route show default 2>/dev/null | awk '{print $3; exit}' | tr -d '[:space:]')"
CIDR="$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f2 | tr -d '[:space:]')"
echo "Network: iface=$IFACE ip=$IPADDR/$CIDR gw=$GATEWAY"
[ -n "$IPADDR" ] && [ -n "$GATEWAY" ] && [ -n "$CIDR" ] || {
    echo 'Error: could not read network config from the live system.'
    exit 1
}

# ---- the first-boot hardening script (base64-passed via InstallNET -cmd) ---
# NOTE: this runs INSIDE the freshly installed Debian on first boot.
# Values below are expanded NOW (outer heredoc, unquoted EOF), so $-vars that
# must survive until first boot are escaped as \$.
cat > /tmp/firstboot.sh <<EOF
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
exec >/var/log-firstboot.log 2>&1
set -x

# --- dpkg/apt: never keep docs, manpages, locales, .deb archives ---
cat > /etc/dpkg/dpkg.cfg.d/01-nodoc <<'D'
path-exclude /usr/share/doc/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/locale/*
D
cat > /etc/apt/apt.conf.d/99-tiny <<'D'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
APT::Keep-Downloaded-Packages "false";
D

# --- logs: journald RAM-only with hard cap, /var/log + /tmp on tmpfs ---
mkdir -p /etc/systemd/journald.conf.d /etc/systemd/coredump.conf.d
cat > /etc/systemd/journald.conf.d/99-tiny.conf <<'D'
[Journal]
Storage=volatile
RuntimeMaxUse=${JOURNAL_MAX}
MaxFileSec=1day
ForwardToSyslog=no
ForwardToConsole=no
D
cat > /etc/systemd/coredump.conf.d/99-none.conf <<'D'
[Coredump]
Storage=none
ProcessSizeMax=0
D
cat >> /etc/fstab <<'D'
tmpfs /var/log tmpfs rw,nosuid,nodev,noexec,size=${LOG_TMPFS_SIZE},mode=0755 0 0
tmpfs /tmp     tmpfs rw,nosuid,nodev,size=${TMP_TMPFS_SIZE},mode=1777        0 0
D
sed -i 's|^\(UUID=[^ ]*  */  *[a-z0-9]*  *\)\([^ ]*\)\( .*\)\$|\1\2,noatime\3|' /etc/fstab || true

# --- RAM: zram swap + drop useless background services ---
apt-get update -qq
apt-get install -y --no-install-recommends zram-tools curl wget ca-certificates || true
cat > /etc/default/zramswap <<'D'
ALGO=zstd
SIZE=${ZRAM_MB}
PRIORITY=100
D
systemctl enable zramswap >/dev/null 2>&1 || true
systemctl mask apt-daily.service apt-daily.timer apt-daily-upgrade.service \
    apt-daily-upgrade.timer e2scrub_all.timer e2scrub_reap.service >/dev/null 2>&1 || true

# --- sysctl / network tuning ---
cat > /etc/sysctl.d/99-tiny.conf <<'D'
fs.suid_dumpable = 0
kernel.core_pattern = /dev/null
vm.swappiness = 10
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
D
echo tcp_bbr > /etc/modules-load.d/bbr.conf
printf '* soft nofile 65535\n* hard nofile 65535\n' > /etc/security/limits.d/99-nofile.conf

# --- automatic cleanup + disk guard ---
cat > /usr/local/sbin/clean-space <<'D'
#!/bin/sh
apt-get clean 2>/dev/null || true
rm -rf /var/cache/apt/archives/* /root/.cache/* 2>/dev/null || true
journalctl --vacuum-size=4M >/dev/null 2>&1 || true
find /var/log -type f -size +1M -exec truncate -s 0 {} + 2>/dev/null || true
find /usr/local/x-ui -type f -name '*.log' -size +1M -exec truncate -s 0 {} + 2>/dev/null || true
find /tmp /var/tmp -mindepth 1 -mtime +1 -exec rm -rf {} + 2>/dev/null || true
sync
df -h /
D
chmod 755 /usr/local/sbin/clean-space

cat > /usr/local/sbin/disk-guard <<'D'
#!/bin/sh
used="\$(df -P / | awk 'NR==2 {gsub(/%/,"",\$5); print \$5}')"
case "\$used" in ''|*[!0-9]*) exit 0 ;; esac
if [ "\$used" -ge 90 ]; then
    journalctl --vacuum-size=2M >/dev/null 2>&1 || true
    find /var/log -type f -size +256k -exec truncate -s 0 {} + 2>/dev/null || true
    /usr/local/sbin/clean-space >/dev/null 2>&1 || true
fi
exit 0
D
chmod 755 /usr/local/sbin/disk-guard

cat > /etc/systemd/system/clean-space.service <<'D'
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/clean-space
D
cat > /etc/systemd/system/clean-space.timer <<'D'
[Timer]
OnCalendar=daily
RandomizedDelaySec=600
Persistent=true
[Install]
WantedBy=timers.target
D
cat > /etc/systemd/system/disk-guard.service <<'D'
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/disk-guard
D
cat > /etc/systemd/system/disk-guard.timer <<'D'
[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
D
systemctl enable clean-space.timer disk-guard.timer fstrim.timer >/dev/null 2>&1

# --- final trim ---
apt-get clean || true
rm -rf /var/lib/apt/lists/* /root/.cache 2>/dev/null || true
EOF

# InstallNET decodes this into /etc/run.sh and runs it once at first boot.
FIRSTBOOT_B64="$(base64 -w0 /tmp/firstboot.sh)"

# ---- fetch InstallNET and launch the unattended install --------------------
echo 'Downloading InstallNET.sh...'
wget --no-check-certificate -qO /tmp/InstallNET.sh "$INSTALLNET_URL"
chmod a+x /tmp/InstallNET.sh

echo 'Launching Debian installer (unattended, static IP, no swap, BBR)...'
echo 'The machine reboots into the installer; full install takes ~10-20 min,'
echo 'then first boot applies the tiny-node hardening automatically.'
bash /tmp/InstallNET.sh \
    -debian "$SUITE" \
    -port "$PORT" \
    -pwd "$PASSWORD" \
    -mirror "$MIRROR" \
    --ip-addr "$IPADDR" \
    --ip-gate "$GATEWAY" \
    --ip-mask "$CIDR" \
    -swap "0" \
    --bbr \
    --motd \
    -cmd "$FIRSTBOOT_B64"
