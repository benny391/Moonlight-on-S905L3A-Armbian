#!/bin/bash
# Pin Moonlight-relevant hard IRQs and their threaded handlers to dedicated CPUs.
#   CPU3: eth0
#   CPU2: vdec / esparser / meson / HDMI
set -u
LOG=/var/log/moonlight-irq-affinity.log
log() { echo "$(date "+%F %T") $*" >> "$LOG" 2>/dev/null || true; }

set_irq_cpu() {
    local n=$1 cpu=$2 name eff
    [ -d "/proc/irq/$n" ] || { log "IRQ $n absent - skipped"; return; }
    name=$(awk -v n="$n" "\$1==n\":\" {print \$NF; exit}" /proc/interrupts 2>/dev/null)
    if printf "%s\n" "$cpu" > "/proc/irq/$n/smp_affinity_list" 2>/dev/null; then
        eff=$(cat "/proc/irq/$n/effective_affinity_list" 2>/dev/null || echo "?")
        log "IRQ $n (${name:-?}) hardirq -> CPU$eff"
    else
        log "IRQ $n (${name:-?}) hardirq write FAILED"
    fi
}

# Single-pass threaded handler / NAPI pinning.
# Previously pin_threads() was called once per name pattern (7 patterns), each
# walking all of /proc/*/task/* -> ~0.75s per pass, ~5.3s at boot. One walk now
# classifies each thread by comm via case; end state is identical.
pin_threads_once() {
    local d c tid aff cpu
    for d in /proc/[0-9]*/task/*; do
        [ -r "$d/comm" ] || continue
        c=$(cat "$d/comm" 2>/dev/null) || continue
        case "$c" in
            irq/15*|irq/18*|irq/21*|irq/24*|irq/25*|irq/26*) cpu=2 ;;
            napi/eth0-*) cpu=3 ;;
            *) continue ;;
        esac
        tid=${d##*/}
        aff=$(taskset -cp "$tid" 2>/dev/null | awk -F: "{gsub(/ /,\"\",\$2); print \$2}")
        [ "$aff" = "$cpu" ] && continue
        if taskset -cp "$cpu" "$tid" >/dev/null 2>&1; then
            log "thread $c ($tid) -> CPU$cpu"
        else
            log "thread $c ($tid) -> CPU$cpu FAILED"
        fi
    done
}

[ -d /proc/irq ] || { log "/proc/irq unavailable - abort"; exit 0; }

# Hard interrupt lines
set_irq_cpu 14 3   # eth0
set_irq_cpu 15 2   # HDMI TX
set_irq_cpu 21 2   # CEC
set_irq_cpu 24 2   # vdec
set_irq_cpu 25 2   # esparser
set_irq_cpu 26 2   # meson / DRM
set_irq_cpu 18 2   # audio controller (kept off CPU1: RT50 IRQ starves the RT30 playback thread)

# Threaded IRQ handlers (changing hardirq affinity does NOT move these)
# Threaded NAPI: keep network RX processing on the NICs CPU
pin_threads_once
exit 0
