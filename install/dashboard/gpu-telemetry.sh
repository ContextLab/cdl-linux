#!/usr/bin/env bash
# managed by cdl-linux; edits here are overwritten by ./install.sh
#
# Installed to /opt/cdl/dashboard/gpu-telemetry.sh by install/modules/55-dashboard.sh.
# Runs as root, every 2s, from the cdl-gpu-telemetry timer.
#
# Writes /run/cdl/gpu.json and /run/cdl/smart.json, world-readable. This exists because the
# dashboard service (cdl-dash) is hardened with PrivateDevices=true and so has no
# /dev/nvidia* and no raw block device access at all -- it can only ever read what this
# script, running as root outside that sandbox, already collected. See sec 3.4 and the
# module comments for the full reasoning.
#
# Both files are written atomically (temp file + mv) so the dashboard never reads a partial
# write, and both default every field to null/absent rather than omitting the file, so a
# missing GPU or missing NVMe device is a normal, documented state rather than an error.

set -uo pipefail

RUN_DIR="${CDL_RUN_DIR:-/run/cdl}"
mkdir -p "$RUN_DIR"
chmod 0755 "$RUN_DIR"

write_atomic() {
    local dest="$1" content="$2" tmp
    tmp="$(mktemp "${dest}.XXXXXX")"
    printf '%s\n' "$content" > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$dest"
}

# --- GPU ---------------------------------------------------------------------------------
if command -v nvidia-smi >/dev/null 2>&1; then
    csv="$(nvidia-smi \
        --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
        --format=csv,noheader,nounits 2>/dev/null)"
    if [ -n "$csv" ]; then
        gpus="["
        first=1
        while IFS=',' read -r idx util mem_used mem_total temp power; do
            idx="$(echo "$idx" | xargs)"; util="$(echo "$util" | xargs)"
            mem_used="$(echo "$mem_used" | xargs)"; mem_total="$(echo "$mem_total" | xargs)"
            temp="$(echo "$temp" | xargs)"; power="$(echo "$power" | xargs)"
            [ "$first" -eq 1 ] || gpus+=","
            first=0
            gpus+=$(printf '{"index":%s,"utilization_pct":%s,"memory_used_mib":%s,"memory_total_mib":%s,"temperature_c":%s,"power_draw_w":%s}' \
                "$idx" "$util" "$mem_used" "$mem_total" "$temp" "$power")
        done <<< "$csv"
        gpus+="]"
        write_atomic "$RUN_DIR/gpu.json" "$gpus"
    else
        write_atomic "$RUN_DIR/gpu.json" "null"
    fi
else
    write_atomic "$RUN_DIR/gpu.json" "null"
fi

# --- SMART (sec 2.1: the only early warning on a striped pair) -------------------------
smart="[]"
if command -v smartctl >/dev/null 2>&1; then
    first=1
    smart="["
    shopt -s nullglob 2>/dev/null || true
    for dev in /dev/nvme[0-9]n1; do
        [ -e "$dev" ] || continue
        json="$(smartctl -H -j "$dev" 2>/dev/null)"
        if [ -n "$json" ] && echo "$json" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
            healthy="$(echo "$json" | python3 -c '
import json,sys
d = json.load(sys.stdin)
s = d.get("smart_status", {})
print("true" if s.get("passed") is True else ("false" if s.get("passed") is False else "null"))
' 2>/dev/null)"
            [ -n "$healthy" ] || healthy="null"
        else
            healthy="null"
        fi
        [ "$first" -eq 1 ] || smart+=","
        first=0
        smart+=$(printf '{"device":"%s","healthy":%s}' "$dev" "$healthy")
    done
    smart+="]"
fi
write_atomic "$RUN_DIR/smart.json" "$smart"
