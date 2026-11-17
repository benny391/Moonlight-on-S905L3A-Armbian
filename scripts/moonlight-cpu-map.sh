#!/bin/bash
# Watch the Moonlight stream and pin each thread to its pipeline stage's CPU.
#   CPU3: network receive / RTP reassembly
#   CPU2: video decode + DRM presentation
#   CPU1: audio receive / playback
#   CPU0: control, input, and general kernel work
set -u
LOG=/var/log/moonlight-cpu-map.log
INTERVAL=${INTERVAL:-1}
log() { echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null || true; }

find_pid() { pgrep -f "[m]oonlight stream" | head -1; }

map_pid() {
    local p=$1 d c tid aff want
    for d in /proc/$p/task/*; do
        [ -r "$d/comm" ] || continue
        c=$(cat "$d/comm" 2>/dev/null) || continue
        tid=${d##*/}
        case "$c" in
            VideoRecv|LossStats|VideoPing)          want=3 ;;
            VideoDec|ReqIdrFrame|InvRefFrames)      want=2 ;;
            SDLAudioP2)                              want=1 ;;
            AudioRecv|AudioPing|SDLHotplugALSA)      want=0 ;;
            *)                                      want=0 ;;
        esac
        aff=$(taskset -cp "$tid" 2>/dev/null | awk -F: '{gsub(/ /,"",$2); print $2}')
        [ "$aff" = "$want" ] && continue
        if taskset -cp "$want" "$tid" >/dev/null 2>&1; then
            log "PID $p $c ($tid) -> CPU$want"
        else
            log "PID $p $c ($tid) -> CPU$want FAILED"
        fi
    done
}

last_pid=""
while true; do
    p=$(find_pid)
    if [ -n "$p" ]; then
        if [ "$p" != "$last_pid" ]; then
            log "stream PID $p detected - applying CPU map"
            last_pid=$p
        fi
        map_pid "$p"
    else
        last_pid=""
    fi
    sleep "$INTERVAL"
done
