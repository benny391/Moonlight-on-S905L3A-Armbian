#!/bin/bash
# =============================================================================
# /etc/moonlight-autotune.sh
# CM311-1A / S905L3A  (Armbian, kernel 5.15)  --  Moonlight 2K60 H.265 tuning
#
# Rules:
#   * NEVER pin all cores to "performance" - the passive heatsink cannot take it.
#   * CPU is FIXED to one mid bin (LOCK_FREQ=1704000) under the userspace
#     governor. This is deliberate: schedutil's runtime clk_set_rate() calls
#     meson_clk_pll_set_rate() on the 6 GHz sys_pll, which holds a regmap
#     spinlock long enough to starve eth0 -> NETDEV WATCHDOG -> adapter reset
#     -> Moonlight control-stream loss (2026-11-17 root cause). One static
#     frequency = zero runtime PLL reprogramming = no more watchdog resets.
#     1704 MHz sits midway between the 1.5G and 1.9G bins; idle is >90% so a
#     single static mid frequency costs nothing in throughput.
#   * Thermal watchdog is an extreme safety net ONLY. At normal temperature
#     (~50 C) it writes nothing at all. It acts (with PLL change) only when
#     temp > 70 C (drop to 1512000) and restores LOCK_FREQ once < 55 C again.
#     10 s poll. Kernel trip points (85/95/110 C) remain the last resort.
#   * The daemon also re-asserts the static lock if another service changes
#     governor/frequency behind our back (loadcpufreq at boot, resume, etc.).
#     When nothing drifted this is a read-only check: no sysfs writes, no PLL
#     work. Only a real drift triggers a one-time re-pin.
#   * DDR / VPU nodes are probed and skipped-with-log when absent, as before.
#   * VPU hardware decode is requested by the launcher (-platform aml /
#     -codec hevc per the user's config); this script never changes stream args.
#
# Usage:
#   apply   one-shot CPU/DDR/VPU tuning (default)
#   daemon  foreground thermal watchdog loop
#   start   apply once, then spawn the watchdog in the background
#   stop    stop a background watchdog
# =============================================================================

LOG=/var/log/moonlight-autotune.log
PIDFILE=/run/moonlight-autotune.pid
THERM=/sys/class/thermal/thermal_zone0/temp
LOCK_FREQ=1704000  # WorkBuddy 2026-11-17: fixed mid bin between 1512000 & 1908000
HOT_TEMP=70000
COOL_TEMP=55000
HOT_FREQ=1512000   # down-clock target when >70 C (valid bin for requested 1.5G)
INTERVAL=10

# Named at_ so that sourcing this file does not clobber the autostart
# wrapper's own log() function.
at_log() {
    local line
    line="$(date '+%F %T') [autotune] $*"
    echo "$line" >> "$LOG" 2>/dev/null || true
    echo "$line" >&2
    logger -t moonlight-autotune -- "$*" 2>/dev/null || true
}

cpufreq_policies() {
    local p
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$p" ] && printf '%s\n' "$p"
    done
}

# This policy only exposes fixed bins (1000000 / 1200000 / 1398000 /
# 1512000 / 1608000 / 1704000 / 1800000 / 1908000). When a requested kHz
# value is not a real bin, take the lowest bin that is still >= the request.
resolve_freq() {
    local want=$1 freqs=$2 f best=
    for f in $freqs; do
        if [ "$f" -ge "$want" ] 2>/dev/null; then
            if [ -z "$best" ] || [ "$f" -lt "$best" ]; then best=$f; fi
        fi
    done
    printf '%s\n' "${best:-$want}"
}

# Pin one policy to an exact frequency under the userspace governor.
# Order matters: when raising, lift the ceiling before the floor; when
# lowering, drop the floor before the ceiling - otherwise the kernel rejects
# min>max. The actual clock change happens on the scaling_setspeed write.
pin_freq() {
    local p=$1 target=$2 cur
    cur=$(cat "$p/scaling_cur_freq" 2>/dev/null)
    if [ -n "$cur" ] && [ "$target" -gt "$cur" ] 2>/dev/null; then
        printf '%s\n' "$target" > "$p/scaling_max_freq" 2>/dev/null
        printf '%s\n' "$target" > "$p/scaling_min_freq" 2>/dev/null
    else
        printf '%s\n' "$target" > "$p/scaling_min_freq" 2>/dev/null
        printf '%s\n' "$target" > "$p/scaling_max_freq" 2>/dev/null
    fi
    printf '%s\n' "$target" > "$p/scaling_setspeed" 2>/dev/null
}

# Re-assert the static lock if something else changed the governor or the
# frequency behind our back (boot-time cpufreq module load, resume, a stray
# cpufrequtils invocation). Read-only when everything is already correct:
# no sysfs writes = no PLL reprogramming during normal streaming.
# $1 = the frequency that SHOULD be pinned right now (lock bin or hot bin).
ensure_lock() {
    local want=$1 p name gov cur mn mx freqs lock changed=0
    for p in $(cpufreq_policies); do
        name=$(basename "$p")
        gov=$(cat "$p/scaling_governor" 2>/dev/null)
        cur=$(cat "$p/scaling_cur_freq" 2>/dev/null)
        mn=$(cat "$p/scaling_min_freq" 2>/dev/null)
        mx=$(cat "$p/scaling_max_freq" 2>/dev/null)
        freqs=$(cat "$p/scaling_available_frequencies" 2>/dev/null)
        lock=$(resolve_freq "$want" "$freqs")
        if [ "$gov" = userspace ] && [ "$cur" = "$lock" ] \
           && [ "$mn" = "$lock" ] && [ "$mx" = "$lock" ]; then
            continue
        fi
        if [ "$gov" != userspace ]; then
            printf 'userspace\n' > "$p/scaling_governor" 2>/dev/null
        fi
        pin_freq "$p" "$lock"
        at_log "LOCK REPAIR: $name was gov=${gov:-?} cur=${cur:-?} min=${mn:-?} max=${mx:-?} -> userspace/$lock"
        changed=1
    done
    return $changed
}

# ------------------------------------------------------------------ CPU ---
# Static lock under userspace governor: no sugov thread, no runtime PLL change.
apply_cpu() {
    local p freqs lock name any=0
    for p in $(cpufreq_policies); do
        any=1
        name=$(basename "$p")
        if [ -w "$p/scaling_governor" ]; then
            printf 'userspace\n' > "$p/scaling_governor" 2>/dev/null \
                && at_log "$name: governor=userspace (runtime PLL changes disabled)" \
                || at_log "$name: WARNING cannot set governor"
        else
            at_log "$name: governor node not writable - skip"
        fi

        freqs=$(cat "$p/scaling_available_frequencies" 2>/dev/null)
        lock=$(resolve_freq "$LOCK_FREQ" "$freqs")
        pin_freq "$p" "$lock"
        at_log "$name: locked min=max=setspeed=$lock Hz (requested ${LOCK_FREQ}; single static bin)"
    done
    [ "$any" -eq 1 ] || at_log "no cpufreq policy found - CPU tuning skipped"
}

# ------------------------------------------------------------------ DDR ---
# Some Amlogic 5.15 trees expose no dmc devfreq at all; on this box the only
# devfreq client is the GPU. Missing node is a normal, logged condition.
apply_ddr() {
    local base=/sys/class/devfreq/dmc
    local freqs target n i
    local -a arr

    if [ ! -e "$base/governor" ]; then
        at_log "DDR: $base/governor absent - skipped (no dmc devfreq on this kernel)"
        return 0
    fi

    freqs=$(cat "$base/available_frequencies" 2>/dev/null)
    read -r -a arr <<< "$freqs"
    n=${#arr[@]}
    if [ "$n" -lt 2 ]; then
        at_log "DDR: fewer than 2 frequencies available ($freqs) - skipped"
        return 0
    fi
    i=$((n - 2))                 # second highest, not the very top bin
    target=${arr[$i]}

    if printf 'userspace\n' > "$base/governor" 2>/dev/null \
       && printf '%s\n' "$target" > "$base/userspace_set_freq" 2>/dev/null; then
        at_log "DDR: governor=userspace freq=$target Hz (2nd highest of: $freqs)"
    else
        at_log "DDR: WARNING could not set userspace/$target - left unchanged"
    fi
}

# ------------------------------------------------------------------ VPU ---
apply_vpu() {
    local d name node rate
    for d in /sys/class/devfreq/*; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        case "$name" in
            *vpu*|*VPU*)
                if printf 'performance\n' > "$d/governor" 2>/dev/null; then
                    at_log "VPU: devfreq $name governor=performance"
                    return 0
                fi
                ;;
        esac
    done

    # No devfreq client: try the legacy debugfs clock. Read the rate only -
    # never write a higher value (no overclock on a passive-cooled box).
    for node in /sys/kernel/debug/clk/vpu_clk /sys/kernel/debug/clk/vpu; do
        [ -e "$node" ] || continue
        if [ ! -w "$node" ]; then
            at_log "VPU: $node exists but is not writable - skipped"
            continue
        fi
        if [ -d "$node" ] && [ -r "$node/clk_rate" ]; then
            rate=$(cat "$node/clk_rate" 2>/dev/null)
        else
            rate=$(cat "$node" 2>/dev/null | tr '\n' ' ')
        fi
        at_log "VPU: $node present; keeping current rate (${rate:-unknown}) - no overclock"
        return 0
    done
    at_log "VPU: no devfreq/vpu_clk node found - skipped"
}

# --------------------------------------------------------- thermal guard ---
# Extreme safety net only. At normal temperature it performs ZERO writes, so
# the PLL is never touched during normal streaming. A state machine + 15 C of
# hysteresis (70/55) prevents write churn near a single threshold. Crucially,
# "restore" only fires if we actually went HOT - so a cold boot at 50 C does
# not write the frequency a second time.
thermal_daemon() {
    local temp state=NORMAL p freqs target name want
    echo "$$" > "$PIDFILE" 2>/dev/null || true
    trap 'rm -f "$PIDFILE"' EXIT INT TERM
    at_log "thermal daemon started: >${HOT_TEMP}mC drop to ${HOT_FREQ}Hz, <${COOL_TEMP}mC restore to ${LOCK_FREQ}Hz, interval=${INTERVAL}s, idle at normal temp; lock self-heal enabled"

    while :; do
        temp=$(cat "$THERM" 2>/dev/null)
        case "$temp" in
            ''|*[!0-9]*) sleep "$INTERVAL"; continue ;;
        esac

        if [ "$temp" -gt "$HOT_TEMP" ] && [ "$state" != HOT ]; then
            for p in $(cpufreq_policies); do
                name=$(basename "$p")
                freqs=$(cat "$p/scaling_available_frequencies" 2>/dev/null)
                target=$(resolve_freq "$HOT_FREQ" "$freqs")
                pin_freq "$p" "$target"
                at_log "THERMAL HOT: ${temp}mC (>70C) - $name pinned to $target Hz (one-time PLL change)"
            done
            state=HOT

        elif [ "$temp" -lt "$COOL_TEMP" ] && [ "$state" = HOT ]; then
            for p in $(cpufreq_policies); do
                name=$(basename "$p")
                freqs=$(cat "$p/scaling_available_frequencies" 2>/dev/null)
                target=$(resolve_freq "$LOCK_FREQ" "$freqs")
                pin_freq "$p" "$target"
                at_log "THERMAL COOL: ${temp}mC (<55C) - $name restored to $target Hz (locked bin)"
            done
            state=NORMAL
        fi

        # Self-heal the static lock: re-assert whichever bin the current
        # thermal state expects. This is a pure read (zero sysfs writes) when
        # governor/frequencies are already correct, so a healthy stream sees
        # no extra PLL activity. It repairs boot-time resets by loadcpufreq,
        # resume events, or any stray governor write.
        if [ "$state" = HOT ]; then
            want=$HOT_FREQ
        else
            want=$LOCK_FREQ
        fi
        ensure_lock "$want"

        sleep "$INTERVAL"
    done
}

# ------------------------------------------------------ launch priority ---
# Sourced by /usr/local/bin/moonlight-autostart. Realtime I/O needs
# CAP_SYS_NICE (we run as root); fall back if the block layer refuses -c1.
moonlight_launch() {
    if ionice -c1 -n0 true >/dev/null 2>&1; then
        nice -n -5 ionice -c1 -n0 "$@"
    else
        at_log "ionice -c1 unavailable - falling back to -c2 -n0"
        nice -n -5 ionice -c2 -n0 "$@"
    fi
}

apply_all() {
    apply_cpu
    apply_ddr
    apply_vpu
}

main() {
    case "${1:-apply}" in
        apply|once)
            apply_all
            ;;
        daemon)
            thermal_daemon
            ;;
        start)
            apply_all
            if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
                at_log "thermal daemon already running (pid $(cat "$PIDFILE"))"
            else
                "$0" daemon >> "$LOG" 2>&1 < /dev/null &
                at_log "thermal daemon started in background (pid $!)"
            fi
            ;;
        stop)
            if [ -f "$PIDFILE" ]; then
                pid=$(cat "$PIDFILE")
                kill "$pid" 2>/dev/null && at_log "thermal daemon $pid stopped"
                rm -f "$PIDFILE"
            else
                at_log "no background daemon to stop"
            fi
            ;;
        *)
            echo "Usage: $0 {apply|daemon|start|stop}" >&2
            exit 2
            ;;
    esac
}

# Safe to source from the autostart wrapper: main() only runs when executed.
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
