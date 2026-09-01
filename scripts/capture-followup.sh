#!/usr/bin/env bash
# capture-followup.sh — closes the two M0 capture gaps and diagnoses the D29 blocker.
#
# The 2026-09-01 capture left three things open:
#   1. smartmontools and nvme-cli were not installed, so there is NO SMART wear or error
#      history. That is a go/no-go input: under RAID0 (D4/D15) either drive's failure loses
#      everything, so their health decides whether striping this pair is sane.
#   2. /sys/power/state read "freeze mem" with no "disk", so hibernation is unavailable and
#      D29 is blocked. The suspected cause is Secure Boot via kernel lockdown, but the
#      original capture did not read the lockdown state, so it stayed an inference.
#   3. nvme-cli was missing, so there is no NVMe-native controller detail.
#
# This script installs the two packages, re-runs the full capture, and prints a short
# DIAGNOSIS you can paste back — roughly 25 lines instead of a 70 KB attachment.
#
# It changes the system in exactly one way: installing smartmontools and nvme-cli via apt.
# Everything else is read-only.
#
# Usage:
#   sudo ./scripts/capture-followup.sh
#   sudo ./scripts/capture-followup.sh --no-install    # diagnose only, install nothing

set -uo pipefail

# ---------------------------------------------------------------------------
# Drive-health thresholds.
#
# These decide whether the DIAGNOSIS calls a drive fit for RAID0. They are a risk
# posture, not a fact, so they are here at the top to be argued with. D15 already
# accepted total loss on single-drive failure, which cuts both ways: it means a
# tired drive is tolerable, AND it means there is no redundancy to catch one.
#
# Defaults are deliberately conservative for a striped pair with no redundancy.
# ---------------------------------------------------------------------------
PCT_USED_WARN=10        # NVMe "Percentage Used" — endurance consumed. >10% on a 4-year-old
                        # laptop drive is worth a second look before striping it.
SPARE_WARN=95           # "Available Spare" %. Anything below 100 means blocks have already
                        # been retired; below the NVMe threshold is a failing drive.
MEDIA_ERR_WARN=0        # "Media and Data Integrity Errors". Under RAID0, non-zero is a real
                        # signal, not noise — there is no second copy.
POWER_ON_HOURS_NOTE=8760  # Purely informational: flag drives past ~1 year of power-on time.


say() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# One line per display connector: name, connected/disconnected, and which driver owns it.
# The driver is the point — it decides whether a given output depends on the NVIDIA stack.
snapshot_connectors() {
    local f conn card drv
    for f in /sys/class/drm/card*-*/status; do
        [[ -e "$f" ]] || continue
        conn="${f%/status}"; conn="${conn##*/}"
        card="${conn%%-*}"
        drv="$(basename "$(readlink -f "/sys/class/drm/$card/device/driver" 2>/dev/null)" 2>/dev/null)"
        printf '%s\t%s\t%s\n' "$conn" "$(cat "$f" 2>/dev/null || echo '?')" "${drv:-?}"
    done | sort
}

snapshot_thunderbolt() {
    find /sys/bus/thunderbolt/devices/ -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort
}

# Prompts for a physical action and waits. Returns 1 if the user skips or there is no
# terminal to prompt on, so the caller can degrade instead of hanging forever.
ask_action() {
    local msg="$1" reply
    if [[ ! -t 0 ]]; then
        echo "  No terminal on stdin — cannot run the interactive dock test."
        return 1
    fi
    printf '\n\033[1;33m>>> ACTION NEEDED: %s\033[0m\n' "$msg"
    printf '    Press ENTER when done  (or type  s  then ENTER to skip the dock test): '
    read -r reply || return 1
    [[ "$reply" =~ ^[sS] ]] && return 1
    printf '    Waiting 3s for the kernel to notice the change...\n'
    sleep 3
    return 0
}


# ---------------------------------------------------------------------------
# Sourcing guard. `source`ing this file defines the helpers and stops, so the diff and
# verdict logic can be unit-tested without root, without apt, and without real hardware.
# Everything below this line is the actual run.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2317  # reachable only when sourced, which shellcheck cannot see
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

INSTALL=1
DOCK_TEST=1
for arg in "$@"; do
    case "$arg" in
        --no-install)     INSTALL=0 ;;
        --skip-dock-test) DOCK_TEST=0 ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "This script needs root: smartctl reads the drives directly, and apt installs packages." >&2
    echo "Re-run as:  sudo $0 ${1:-}" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
warnings=()

# ---------------------------------------------------------------------------
# 1. Install the two missing tools
# ---------------------------------------------------------------------------
if [[ $INSTALL -eq 1 ]]; then
    say "Installing smartmontools and nvme-cli"
    missing=()
    command -v smartctl >/dev/null 2>&1 || missing+=(smartmontools)
    command -v nvme     >/dev/null 2>&1 || missing+=(nvme-cli)

    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "Both already installed; nothing to do."
    else
        echo "Installing: ${missing[*]}"
        export DEBIAN_FRONTEND=noninteractive
        if ! apt-get update -qq; then
            echo "WARNING: 'apt-get update' failed (no network?). Trying install anyway." >&2
            warnings+=("apt-get update failed")
        fi
        if apt-get install -y -qq "${missing[@]}"; then
            echo "Installed."
        else
            echo "ERROR: install failed. The diagnosis below will be incomplete." >&2
            warnings+=("apt-get install failed — SMART data unavailable")
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 2. Re-run the full capture, now that the tools exist
# ---------------------------------------------------------------------------
say "Re-running the full hardware capture"
capture_out=""
if [[ -x "$script_dir/capture-hardware.sh" ]]; then
    # Capture its stdout so we can report where the file landed.
    if capture_log="$("$script_dir/capture-hardware.sh" 2>&1)"; then :; fi
    echo "$capture_log"
    capture_out="$(sed -n 's/^Capture written to: //p' <<<"$capture_log" | head -1)"
else
    echo "capture-hardware.sh not found next to this script — skipping the full re-capture."
    warnings+=("full re-capture skipped")
fi

# ---------------------------------------------------------------------------
# 3. DIAGNOSIS — the part worth pasting back
# ---------------------------------------------------------------------------
say "DIAGNOSIS (paste this back)"

echo "--- hibernation / D29 ---"
sb="$(mokutil --sb-state 2>/dev/null || echo 'unknown')"
lockdown="$(cat /sys/kernel/security/lockdown 2>/dev/null || echo 'unreadable')"
pstate="$(cat /sys/power/state 2>/dev/null || echo 'unreadable')"
msleep="$(cat /sys/power/mem_sleep 2>/dev/null || echo 'unreadable')"
cmdline="$(cat /proc/cmdline 2>/dev/null || echo '')"

printf 'secure boot     : %s\n' "$sb"
printf 'lockdown        : %s\n' "$lockdown"
printf 'power states    : %s\n' "$pstate"
printf 'mem_sleep       : %s\n' "$msleep"
printf 'nohibernate set : %s\n' "$(grep -q 'nohibernate' <<<"$cmdline" && echo yes || echo no)"
printf 'resume= set     : %s\n' "$(grep -qE '(^| )resume=' <<<"$cmdline" && echo yes || echo no)"

# The verdict. "disk" in /sys/power/state is the whole question; everything else explains WHY.
if grep -qw disk <<<"$pstate"; then
    echo "VERDICT         : hibernation IS available. D29 is not blocked by lockdown."
elif grep -q '\[integrity\]\|\[confidential\]' <<<"$lockdown"; then
    echo "VERDICT         : CONFIRMED — kernel lockdown is active and is hiding 'disk'."
    echo "                  Secure Boot -> lockdown -> hibernation blocked. To have hibernation"
    echo "                  on a stock Ubuntu kernel, Secure Boot must be disabled in firmware."
elif grep -q 'nohibernate' <<<"$cmdline"; then
    echo "VERDICT         : hibernation disabled by the 'nohibernate' kernel parameter, NOT lockdown."
    echo "                  Removing it from the kernel command line should restore 'disk'."
elif [[ "$lockdown" == "unreadable" ]]; then
    echo "VERDICT         : INCONCLUSIVE — securityfs is not mounted, so lockdown state is unknown."
    echo "                  Try: mount -t securityfs securityfs /sys/kernel/security"
else
    echo "VERDICT         : UNEXPECTED — lockdown is inactive and nohibernate is unset, yet 'disk'"
    echo "                  is absent. That points at the kernel build (CONFIG_HIBERNATION) rather"
    echo "                  than policy. Worth reporting, because it changes the D29 options."
fi

echo
echo "--- drive health / RAID0 fitness ---"
if ! command -v smartctl >/dev/null 2>&1; then
    echo "smartctl unavailable — cannot assess drive health."
    warnings+=("no SMART data: the RAID0 go/no-go stays open")
else
    mapfile -t drives < <(lsblk -d -n -o NAME,TRAN 2>/dev/null | awk '$2=="nvme"{print "/dev/"$1}')
    if [[ ${#drives[@]} -eq 0 ]]; then
        echo "No NVMe block devices found."
        warnings+=("no NVMe devices detected")
    fi
    for d in "${drives[@]}"; do
        a="$(smartctl -a "$d" 2>/dev/null)"
        get() { sed -n "s/^$1: *//p" <<<"$a" | head -1 | tr -d ' '; }
        health="$(sed -n 's/^SMART overall-health self-assessment test result: *//p' <<<"$a" | head -1)"
        [[ -z "$health" ]] && health="$(sed -n 's/^SMART Health Status: *//p' <<<"$a" | head -1)"
        pct="$(get 'Percentage Used' | tr -d '%')"
        spare="$(get 'Available Spare' | tr -d '%')"
        media="$(get 'Media and Data Integrity Errors' | tr -d ',')"
        hours="$(get 'Power On Hours' | tr -d ',')"
        unsafe="$(get 'Unsafe Shutdowns' | tr -d ',')"
        crit="$(get 'Critical Warning')"
        written="$(sed -n 's/^Data Units Written: *//p' <<<"$a" | head -1)"

        printf '%s\n' "$d"
        printf '  health=%s  critical_warning=%s\n' "${health:-?}" "${crit:-?}"
        printf '  pct_used=%s%%  spare=%s%%  media_errors=%s\n' "${pct:-?}" "${spare:-?}" "${media:-?}"
        printf '  power_on_hours=%s  unsafe_shutdowns=%s\n' "${hours:-?}" "${unsafe:-?}"
        printf '  written=%s\n' "${written:-?}"

        # Threshold checks. Only numeric comparisons when we actually parsed a number.
        [[ "$health" =~ ^PASSED|^OK ]] || warnings+=("$d: SMART health is '${health:-unknown}', not PASSED")
        [[ -n "$crit" && "$crit" != "0x00" ]] && warnings+=("$d: critical warning $crit")
        [[ "$pct"   =~ ^[0-9]+$ ]] && (( pct   >  PCT_USED_WARN ))  && warnings+=("$d: ${pct}% endurance used (> ${PCT_USED_WARN}%)")
        [[ "$spare" =~ ^[0-9]+$ ]] && (( spare <  SPARE_WARN ))     && warnings+=("$d: available spare ${spare}% (< ${SPARE_WARN}%)")
        [[ "$media" =~ ^[0-9]+$ ]] && (( media >  MEDIA_ERR_WARN )) && warnings+=("$d: ${media} media/data-integrity errors — no second copy under RAID0")
        [[ "$hours" =~ ^[0-9]+$ ]] && (( hours >  POWER_ON_HOURS_NOTE )) && echo "  note: past ${POWER_ON_HOURS_NOTE}h power-on time"
    done
fi

echo
echo "--- displays / docking ---"
# The dock question is really "which GPU owns the external output", because that decides
# whether a docked external monitor survives an NVIDIA driver problem the way the internal
# panel does. Answering it needs two observations, so this walks you through both.
echo "Current connector state:"
snapshot_connectors | while IFS=$'\t' read -r conn st drv; do
    printf '  %-18s %-13s driver=%s\n' "$conn" "$st" "$drv"
done

if command -v boltctl >/dev/null 2>&1; then
    echo "thunderbolt:"; boltctl list 2>/dev/null | sed 's/^/  /' | head -20
elif [[ -d /sys/bus/thunderbolt/devices ]]; then
    echo "thunderbolt devices: $(snapshot_thunderbolt | tr '\n' ' ')"
else
    echo "thunderbolt: no bus present"
fi

if [[ $DOCK_TEST -eq 0 ]]; then
    echo
    echo "Dock test skipped (--skip-dock-test)."
    warnings+=("dock test skipped: which GPU drives the external monitor is still unknown")
else
    echo
    echo "Dock test: two observations, undocked then docked. The difference names the"
    echo "connector your dock drives, and therefore which GPU an external monitor needs."

    dock_ok=1
    undocked_conn=""; undocked_tb=""
    if ask_action "UNDOCK the laptop — unplug the docking station and any external monitor cable."; then
        undocked_conn="$(snapshot_connectors)"; undocked_tb="$(snapshot_thunderbolt)"
        echo "    Recorded the undocked state."
    else
        dock_ok=0
    fi

    docked_conn=""; docked_tb=""
    if [[ $dock_ok -eq 1 ]]; then
        if ask_action "Now DOCK the laptop and make sure the external monitor is powered ON."; then
            docked_conn="$(snapshot_connectors)"; docked_tb="$(snapshot_thunderbolt)"
            echo "    Recorded the docked state."
        else
            dock_ok=0
        fi
    fi

    if [[ $dock_ok -eq 0 ]]; then
        echo
        echo "Dock test not completed."
        warnings+=("dock test not completed: which GPU drives the external monitor is still unknown")
    else
        echo
        echo "Connector changes (undocked -> docked):"
        appeared=()
        while IFS=$'\t' read -r conn st drv; do
            [[ -z "$conn" ]] && continue
            prev="$(awk -F'\t' -v c="$conn" '$1==c{print $2}' <<<"$undocked_conn")"
            if [[ "$prev" != "$st" ]]; then
                printf '  %-18s %s -> %s   (driver=%s)\n' "$conn" "${prev:-absent}" "$st" "$drv"
                [[ "$st" == "connected" ]] && appeared+=("$conn|$drv")
            fi
        done <<<"$docked_conn"

        tb_new="$(comm -13 <(printf '%s\n' "$undocked_tb") <(printf '%s\n' "$docked_tb") | tr '\n' ' ')"
        [[ -n "${tb_new// /}" ]] && echo "  new thunderbolt devices: $tb_new"

        echo
        if [[ ${#appeared[@]} -eq 0 ]]; then
            echo "VERDICT (dock)  : NO new connector came up when docked."
            echo "                  Either the dock provides no video, the monitor was off, or the"
            echo "                  link needs longer to train. Re-run and give it a moment before"
            echo "                  pressing ENTER. This is a real finding for R18, not a script bug."
            warnings+=("dock provided no new display output — R18 unproven")
        else
            for entry in "${appeared[@]}"; do
                conn="${entry%%|*}"; drv="${entry##*|}"
                printf 'VERDICT (dock)  : the dock drives %s, owned by driver "%s".\n' "$conn" "$drv"
                case "$drv" in
                    nvidia*)
                        echo "                  That is the NVIDIA GPU. A docked external monitor therefore"
                        echo "                  DEPENDS on the NVIDIA driver — unlike the internal panel,"
                        echo "                  which is on the Intel iGPU. Recovery planning must assume a"
                        echo "                  broken NVIDIA driver costs you the external display." ;;
                    i915|xe)
                        echo "                  That is the Intel iGPU — the same driver as the internal"
                        echo "                  panel. A docked external monitor does NOT depend on the"
                        echo "                  NVIDIA driver, which is the better outcome for recovery." ;;
                    *)
                        echo "                  Unexpected driver; worth reporting." ;;
                esac
            done
        fi

        # Keep the evidence. Connector names are not sensitive, but this lives with the
        # rest of the capture so it is retained and reviewed as one artifact.
        if [[ -n "${capture_out:-}" ]]; then
            dock_file="${capture_out%-raw.md}-dock.md"
            {
                echo "# Dock connector map"
                echo
                echo "Recorded $(date -u '+%Y-%m-%dT%H:%M:%SZ') by capture-followup.sh"
                echo
                echo '## Undocked'; echo '```'; printf '%s\n' "$undocked_conn"; echo '```'
                echo '## Docked';   echo '```'; printf '%s\n' "$docked_conn";   echo '```'
            } > "$dock_file" 2>/dev/null && echo && echo "Dock connector map written to: $dock_file"
        fi
    fi
fi

echo
echo "--- NVMe controllers ---"
if command -v nvme >/dev/null 2>&1; then
    nvme list 2>/dev/null || echo "nvme list failed"
else
    echo "nvme-cli unavailable"
fi

# ---------------------------------------------------------------------------
say "SUMMARY"
if [[ ${#warnings[@]} -eq 0 ]]; then
    echo "No warnings. Both drives look fit for a striped pair on these thresholds."
else
    echo "Warnings (${#warnings[@]}):"
    printf -- '  - %s\n' "${warnings[@]}"
fi

if [[ -n "$capture_out" ]]; then
    echo
    echo "Full capture: $capture_out"
    echo "That file is gitignored and contains serials, MACs, UUIDs and the hostname."
    echo "Paste back only the DIAGNOSIS block above; keep a copy of the full file off-machine."
fi
