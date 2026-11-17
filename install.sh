#!/bin/bash
#
# install.sh - deploy this Moonlight thin-client configuration onto an Armbian box.
#
# The script copies scripts/configs/systemd units to their system paths, enables
# the services, and leaves a timestamped backup of every file it overwrites.
# It never touches the moonlight binary, the kernel, or U-Boot itself.
#
# Usage:
#   ./install.sh [--root /mnt/armbian] [--conf FILE] [--uenv FILE] [--dry-run]
#
#   --root DIR     target root filesystem (default: /). Use when installing onto
#                  an eMMC/SD card mounted from another machine.
#   --conf FILE    filled-in moonlight-autostart.conf (from config/*.example).
#                  Required unless --dry-run.
#   --uenv FILE    filled-in uEnv.txt. Optional; skipped if omitted.
#   --dry-run      print every action, write nothing.
#
# The script is idempotent: re-running it just refreshes files (with new backups).

set -euo pipefail

ROOT="/"
CONF=""
UENV=""
DRY=0
HERE="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --root)    ROOT="${2:?--root needs a directory}"; shift 2 ;;
    --conf)    CONF="${2:?--conf needs a file}"; shift 2 ;;
    --uenv)    UENV="${2:?--uenv needs a file}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[ -d "$ROOT" ] || { echo "root '$ROOT' is not a directory" >&2; exit 1; }
ROOT="$(cd "$ROOT" && pwd)"
# normalise optional file args to absolute paths (they're used from HERE's cwd)
[ -n "$CONF" ] && [ -f "$CONF" ] && CONF="$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")"
[ -n "$UENV" ] && [ -f "$UENV" ] && UENV="$(cd "$(dirname "$UENV")" && pwd)/$(basename "$UENV")"
TS="$(date +%Y%m%d-%H%M%S)"
BK=".bak-install-$TS"

# run() prints and (unless dry) executes a shell command
run() {
  if [ "$DRY" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*"
  else
    printf '  + %s\n' "$*"
    eval "$@"
  fi
}

# install_file SRC DEST  - backup existing DEST, then copy SRC over it
install_file() {
  local src="$1" dest="$2" mode="${3:-644}"
  [ -f "$src" ] || { echo "missing source: $src" >&2; exit 1; }
  if [ -e "$ROOT$dest" ]; then
    run "cp -a '$ROOT$dest' '$ROOT$dest$BK'"
  fi
  run "install -m $mode '$src' '$ROOT$dest'"
}

echo "=== Moonlight thin-client install ==="
echo "  target root : $ROOT"
echo "  backup tag  : $BK"
[ "$DRY" -eq 1 ] && echo "  MODE: DRY RUN (nothing will be written)"
echo

if [ "$DRY" -eq 0 ] && [ -z "$CONF" ]; then
  echo "--conf is required (pass a filled-in moonlight-autostart.conf)" >&2
  exit 1
fi

echo "--- scripts (/usr/local/bin) ---"
for s in moonlight-autostart moonlight-cpu-map.sh moonlight-irq-affinity.sh \
         moonlight-latency-apply.sh cec-tv-wake idle-poweroff box-health; do
  install_file "$HERE/scripts/$s" "/usr/local/bin/$s" 755
done
install_file "$HERE/scripts/moonlight-autotune.sh" "/etc/moonlight-autotune.sh" 755

echo "--- config (/etc) ---"
[ -n "$CONF" ] && install_file "$CONF" "/etc/moonlight-autostart.conf" 644
install_file "$HERE/config/cpufrequtils" "/etc/default/cpufrequtils" 644
install_file "$HERE/config/initramfs.conf" "/etc/initramfs-tools/initramfs.conf" 644
install_file "$HERE/config/initramfs-hook-zz-slim" "/etc/initramfs-tools/hooks/zz-slim" 755
install_file "$HERE/config/initramfs-postupdate-99-uboot" "/etc/initramfs/post-update.d/99-uboot" 755
install_file "$HERE/config/journald-volatile.conf" "/etc/systemd/journald.conf.d/10-volatile.conf" 644

echo "--- systemd units ---"
for u in moonlight-autostart moonlight-autotune moonlight-cpu-map \
         moonlight-irq-affinity moonlight-latency; do
  install_file "$HERE/config/$u.service" "/etc/systemd/system/$u.service" 644
done

echo "--- systemd drop-ins ---"
for d in 10-autotune.conf 20-irq-affinity.conf 30-cpu-map.conf; do
  install_file "$HERE/dropins/$d" "/etc/systemd/system/moonlight-autostart.service.d/$d" 644
done
install_file "$HERE/dropins/10-after-cpufreq.conf" \
             "/etc/systemd/system/moonlight-autotune.service.d/10-after-cpufreq.conf" 644

echo "--- U-Boot env (optional) ---"
if [ -n "$UENV" ]; then
  install_file "$UENV" "/boot/uEnv.txt" 755
else
  echo "  (skipped: no --uenv given)"
fi

if [ "$DRY" -eq 1 ]; then
  echo
  echo "=== dry run complete; nothing written ==="
  exit 0
fi

echo "--- enable services (host root only) ---"
if [ "$ROOT" = "/" ]; then
  run "systemctl daemon-reload"
  for u in moonlight-autotune moonlight-irq-affinity moonlight-cpu-map \
           moonlight-latency moonlight-autostart; do
    run "systemctl enable '$u.service'"
  done
  echo
  echo "=== done. Reboot with 'reboot', then run: box-health ==="
else
  echo "  (skipped: --root != /, cannot enable services for a non-running system)"
  echo "  On first boot the services are enabled by their WantedBy= multi-user.target"
  echo "  only if you run 'systemctl enable' there; consider chrooting."
fi
