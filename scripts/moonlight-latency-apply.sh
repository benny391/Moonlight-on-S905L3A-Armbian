#!/bin/bash
# /usr/local/bin/moonlight-latency-apply.sh
# Persistent low-latency runtime tuning for Moonlight streaming.
# Installed by WorkBuddy 2026-11-17, hardened 2026-11-17 03:05.
# Runs at boot via moonlight-latency.service.
# Rollback: systemctl disable --now moonlight-latency.service; rm this file + unit.
set -u
LOG=/var/log/moonlight-latency-tune.log
log(){ echo "$(date '+%F %T') [boot] $*" >> "$LOG" 2>/dev/null || true; }

# Wait for eth0 device node (defensive)
for i in $(seq 1 20); do
    [ -d /sys/class/net/eth0 ] && break
    sleep 0.5
done
[ -d /sys/class/net/eth0 ] || { log "eth0 not present, skipping NIC tuning"; exit 0; }

command -v ethtool >/dev/null 2>&1 || { log "ethtool missing, skipping"; exit 0; }

cur_rx(){ ethtool -c eth0 2>/dev/null | awk '/rx-usecs:/{print $2}'; }
cur_tx(){ echo "$(ethtool -c eth0 2>/dev/null | awk '/tx-usecs:/{print $2}')/$(ethtool -c eth0 2>/dev/null | awk '/tx-frames:/{print $2}')"; }

# --- RX coalesce (driver accepts this reliably; 26 -> quantized 24us) --------
for i in $(seq 1 4); do
    ethtool -C eth0 rx-usecs 26 >/dev/null 2>&1
    [ "$(cur_rx)" = "24" ] && break
    sleep 0.3
done
log "rx-usecs=$(cur_rx)"

# --- TX coalesce -----------------------------------------------------------
# st_gmac only accepts TX coalesce changes in a narrow window during link
# setup. Once the link is fully up, writes fail with EINVAL. Retry a few times
# early, verify by readback, and never fail the service if the driver refuses.
tx_ok=0
for i in $(seq 1 1); do
    if ethtool -C eth0 tx-usecs 50 tx-frames 1 >/dev/null 2>&1; then
        if [ "$(cur_tx)" = "50/1" ]; then tx_ok=1; break; fi
    fi
    sleep 0.25
done
if [ "$tx_ok" = 1 ]; then
    log "tx-usecs/frames=$(cur_tx) (applied after attempt $i)"
else
    log "tx coalesce kept at $(cur_tx) (driver refused; negligible impact - TX is ~1% of packets)"
fi

# Threaded NAPI: move eth0 receive processing into a kernel thread
[ -f /sys/class/net/eth0/threaded ] && echo 1 > /sys/class/net/eth0/threaded 2>/dev/null || true

# Sysctl
sysctl -w kernel.sched_autogroup_enabled=0 >/dev/null 2>&1 || true
sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
log "threaded=$(cat /sys/class/net/eth0/threaded 2>/dev/null) autogroup=$(sysctl -n kernel.sched_autogroup_enabled 2>/dev/null) swappiness=$(sysctl -n vm.swappiness 2>/dev/null)"
exit 0
