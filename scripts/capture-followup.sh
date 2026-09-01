#!/usr/bin/env bash
# capture-followup.sh — closes the remaining command-capturable M0 gaps and diagnoses the
# D29 blocker. Firmware observations are a separate manual gate and are NOT covered here.
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
# This script installs the two packages, re-runs the full capture, and writes a small
# DIAGNOSIS file — a few KB rather than the 70 KB raw capture.
#
# SHARING THE RESULT. There is no shared clipboard between the Tensorbook and the machine
# running the design work, so the diagnosis is written to its own file, built to be sent:
# it carries no serial numbers, MAC addresses or filesystem UUIDs, so it needs no
# redaction before emailing or committing. Its path is printed in a banner at the end.
# The RAW capture is a separate, much larger file that is NOT safe to share as-is.
#
# It changes the system in exactly one way: installing smartmontools and nvme-cli via apt.
# Everything else is read-only.
#
# Usage:
#
#   TO FINISH M0 — this is the command to run now:
#     sudo ./scripts/capture-followup.sh --skip-dock-test
#   It needs no docking station, installs smartmontools and nvme-cli, and answers the two
#   questions M0 still owes: drive health and why hibernation is unavailable.
#
#   DURING M2, when the machine is docked in normal use:
#     sudo ./scripts/capture-followup.sh
#   The full run adds the interactive dock test, which needs you to physically undock and
#   dock. The overview defers that to M2 deliberately (section 16.6) — it answers which GPU
#   drives an external monitor, and nothing before M2 depends on it.
#
#   Other options:
#     --no-install       diagnose only; install nothing
#     --skip-dock-test   skip the interactive dock steps
#     --keep-raw PATH    also copy the raw capture somewhere (a USB stick, say)
#     --strict           exit non-zero if essential M0 evidence is still missing,
#                        instead of only printing warnings. For scripted or CI use.
#                        NOTE: --strict covers MACHINE-READABLE capture evidence only.
#                        The firmware observations (VMD/RST vs AHCI, graphics mode,
#                        whether Secure Boot can be disabled, BIOS password) need a
#                        reboot into setup and remain a separate manual M0 gate that no
#                        exit code can speak to.

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

# Names the SMART fields that are missing or unparseable, one per line, empty if all are
# usable. Extracted so it can be tested: smartctl succeeding is not the same as smartctl
# producing usable output, and that difference is exactly what --strict must catch.
# Args: health critical_warning percentage_used available_spare media_errors
smart_unparsed_fields() {
    local health="$1" crit="$2" pct="$3" spare="$4" media="$5"
    [[ -z "$health" ]] && echo "overall health"
    [[ -z "$crit"   ]] && echo "critical warning"
    [[ "$pct"   =~ ^[0-9]+$ ]] || echo "percentage used"
    [[ "$spare" =~ ^[0-9]+$ ]] || echo "available spare"
    [[ "$media" =~ ^[0-9]+$ ]] || echo "media/data-integrity errors"
    return 0
}

# Reports identifiers found in a file that is about to be emailed or pushed to a PUBLIC
# repository, one "label: line" per finding, empty output when clean. Extracted so it can
# be tested against planted leaks: a redaction claim should be checked against the file,
# not trusted to the code that wrote it, because a leak reaching public git history cannot
# be recalled.
diagnosis_leaks() {
    local file="$1" label pattern hits
    while IFS='|' read -r label pattern; do
        [[ -z "$label" ]] && continue
        hits="$(grep -nEi "$pattern" "$file" 2>/dev/null | head -5)"
        [[ -n "$hits" ]] && printf '%s: %s\n' "$label" "$(head -1 <<<"$hits")"
    done <<'PATTERNS'
MAC address|([0-9a-f]{2}:){5}[0-9a-f]{2}
UUID|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}
labelled serial|(serial|sn)[[:space:]]*[:=][[:space:]]*[a-z0-9]{6,}
private IPv4|(^|[^0-9.])(10|172|192|100)\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}
PATTERNS
    return 0
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
STRICT=0
KEEP_RAW=""
KEEP_RAW_NEXT=0
for arg in "$@"; do
    case "$arg" in
        --no-install)     INSTALL=0 ;;
        --skip-dock-test) DOCK_TEST=0 ;;
        --strict)         STRICT=1 ;;
        --keep-raw)       KEEP_RAW_NEXT=1 ;;
        /*|./*|~*)        if [[ $KEEP_RAW_NEXT -eq 1 ]]; then KEEP_RAW="$arg"; KEEP_RAW_NEXT=0
                          else echo "unexpected path argument: $arg" >&2; exit 2; fi ;;
        -h|--help)
            sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d; s/^#\{1,\} \{0,1\}//; s/^#$//'
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "This script needs root: smartctl reads the drives directly, and apt installs packages." >&2
    echo "Re-run as:  sudo $0 $*" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
warnings=()   # worth knowing
blocking=()   # essential M0 evidence that is still missing — M0 cannot be called complete

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
# The whole point of this file is that it can be emailed: small, self-contained, and
# carrying no serial numbers, MAC addresses, filesystem UUIDs or hostname beyond the
# machine label already used in the committed profile.
if [[ -n "${capture_out:-}" ]]; then
    diag_file="${capture_out%-raw.md}-diagnosis.md"
else
    diag_file="$script_dir/../notes/hardware/diagnosis-$(date -u +%Y%m%dT%H%M%SZ).md"
fi
mkdir -p "$(dirname "$diag_file")" 2>/dev/null

if [[ -n "$KEEP_RAW" && -n "${capture_out:-}" ]]; then
    if cp "$capture_out" "$KEEP_RAW" 2>/dev/null; then
        echo "Raw capture also copied to: $KEEP_RAW"
    else
        echo "WARNING: could not copy the raw capture to $KEEP_RAW" >&2
        warnings+=("--keep-raw copy to $KEEP_RAW failed")
    fi
fi

say "DIAGNOSIS"
{
echo "# M0 follow-up diagnosis"
echo
echo "Generated $(date -u '+%Y-%m-%dT%H:%M:%SZ') by capture-followup.sh"
echo "Kernel: $(uname -srm 2>/dev/null)"
echo
echo "Deliberately free of serial numbers, MAC addresses and filesystem UUIDs, so this"
echo "file can be emailed or committed without redaction. The full raw capture is a"
echo "separate, much larger file that is NOT safe to share as-is."
echo
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
    blocking+=("lockdown state unreadable: the cause of the missing 'disk' stays an inference")
else
    echo "VERDICT         : UNEXPECTED — lockdown is inactive and nohibernate is unset, yet 'disk'"
    echo "                  is absent. That points at the kernel build (CONFIG_HIBERNATION) rather"
    echo "                  than policy. Worth reporting, because it changes the D29 options."
fi

echo
echo "--- drive health / RAID0 fitness ---"
if ! command -v smartctl >/dev/null 2>&1; then
    echo "smartctl unavailable — cannot assess drive health."
    blocking+=("no SMART data: the RAID0 drive-health go/no-go stays open")
else
    mapfile -t drives < <(lsblk -d -n -o NAME,TRAN 2>/dev/null | awk '$2=="nvme"{print "/dev/"$1}')
    if [[ ${#drives[@]} -eq 0 ]]; then
        echo "No NVMe block devices found."
        # Blocking, not advisory: this machine is known to have two NVMe drives, so finding
        # none means the capture is wrong, not that the hardware changed.
        blocking+=("no NVMe devices detected — SMART evidence cannot be collected")
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

        # smartctl existing is not the same as smartctl producing usable output: a wrong
        # device type, a USB bridge, or a permissions problem yields empty fields while the
        # command still succeeds. Strict mode must fail on that, not report a clean bill.
        mapfile -t unparsed < <(smart_unparsed_fields "$health" "$crit" "$pct" "$spare" "$media")
        if [[ ${#unparsed[@]} -gt 0 ]]; then
            printf '  UNPARSEABLE: %s\n' "$(IFS=', '; echo "${unparsed[*]}")"
            blocking+=("$d: SMART output missing or unparseable for: $(IFS=', '; echo "${unparsed[*]}")")
        fi

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
    # `boltctl list` prints per-device uuid, serial and key material. Those identify this
    # specific unit and its specific dock, and this file is meant to be sendable, so they
    # are stripped here. The model, vendor, type and authorization status all survive,
    # which is everything the design actually needs.
    echo "thunderbolt (uuid/serial/key stripped — see the raw capture for full detail):"
    boltctl list 2>/dev/null \
        | grep -viE '(uuid|serial|[[:space:]]key)[[:space:]]*:' \
        | sed 's/^/  /' | head -20
elif [[ -d /sys/bus/thunderbolt/devices ]]; then
    # sysfs device names here are bus positions like "0-1", not identifiers.
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
echo "--- NVMe namespace format (settles sector geometry) ---"
if ! command -v nvme >/dev/null 2>&1; then
    echo "nvme-cli unavailable"
    blocking+=("nvme-cli unavailable — NVMe-native sector geometry unconfirmed")
else
    # Deliberately NOT `nvme list`: that prints drive serial numbers, and this block is
    # meant to be pasteable. The LBA format is what the design actually needs — it says
    # whether a 4096-byte format exists and which one is in use, which is exactly the
    # 512n-versus-512e question the profile got wrong once already.
    mapfile -t nsdrives < <(lsblk -d -n -o NAME,TRAN 2>/dev/null | awk '$2=="nvme"{print "/dev/"$1}')
    for d in "${nsdrives[@]}"; do
        printf '%s\n' "$d"
        nvme id-ns -H "$d" 2>/dev/null | grep -i "LBA Format" | sed 's/^/  /' \
            || echo "  could not read namespace format"
    done
    [[ ${#nsdrives[@]} -eq 0 ]] && echo "  no NVMe namespaces found"
fi

echo
echo "--- thermal and fan control (16.5 input) ---"
# Compact form of what capture-hardware.sh records in full. An empty fan/pwm list is the
# finding, not a gap: it is the strongest evidence for the reported no-fan-control situation.
hw_names="$(for f in /sys/class/hwmon/hwmon*/name; do [[ -e "$f" ]] && cat "$f"; done 2>/dev/null | sort -u | tr '\n' ' ')"
printf 'hwmon chips      : %s\n' "${hw_names:-none}"
fan_ct=$(find /sys/class/hwmon -name 'fan*_input' 2>/dev/null | wc -l | tr -d ' ')
pwm_ct=$(find /sys/class/hwmon -name 'pwm[0-9]' 2>/dev/null | wc -l | tr -d ' ')
cool_ct=$(find /sys/class/thermal -maxdepth 1 -name 'cooling_device*' 2>/dev/null | wc -l | tr -d ' ')
printf 'fan inputs       : %s\n' "$fan_ct"
printf 'writable pwm     : %s\n' "$pwm_ct"
printf 'cooling devices  : %s\n' "$cool_ct"
if [[ "$fan_ct" == "0" && "$pwm_ct" == "0" ]]; then
    echo "NOTE            : no fan telemetry or control exposed — this CONFIRMS the reported"
    echo "                  'no fan control at all' on this chassis, rather than leaving it hearsay."
fi
hot="$(for z in /sys/class/thermal/thermal_zone*; do [[ -r "$z/temp" ]] && printf '%s:%s ' "$(cat "$z/type" 2>/dev/null)" "$(cat "$z/temp" 2>/dev/null)"; done 2>/dev/null)"
printf 'zone temps (m°C) : %s\n' "${hot:-none}"
printf 'cpufreq driver   : %s\n' "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo none)"

} > "$diag_file"
cat "$diag_file"

# ---------------------------------------------------------------------------
# Redaction self-check. The diagnosis is advertised as safe to email or push to a PUBLIC
# repository, and that claim should be verified against the generated file rather than
# trusted to the code that wrote it. Anything found here is blocking: a leak that reaches
# a public git history cannot be recalled.
# ---------------------------------------------------------------------------
leaks="$(diagnosis_leaks "$diag_file")"
if [[ -n "$leaks" ]]; then
    printf '\n\033[1;31mREDACTION CHECK FAILED — do NOT email or push this file yet:\033[0m\n'
    printf '%s\n' "$leaks" | sed 's/^/  /'
    blocking+=("diagnosis file contains identifiers — see the redaction check above")
else
    printf '\nRedaction check: clean (no MACs, UUIDs, labelled serials or private IPs).\n'
fi

# ---------------------------------------------------------------------------
say "SUMMARY"
if [[ ${#blocking[@]} -gt 0 ]]; then
    echo "ESSENTIAL M0 EVIDENCE STILL MISSING (${#blocking[@]}) — M0 is not complete:"
    printf -- '  ! %s\n' "${blocking[@]}"
    echo
fi
if [[ ${#warnings[@]} -gt 0 ]]; then
    echo "Warnings (${#warnings[@]}):"
    printf -- '  - %s\n' "${warnings[@]}"
elif [[ ${#blocking[@]} -eq 0 ]]; then
    echo "No warnings. Both drives look fit for a striped pair on these thresholds."
fi

if [[ ${#blocking[@]} -eq 0 ]]; then
    echo
    echo "Machine-readable M0 evidence is complete. Still needed to close M0 — a separate"
    echo "manual gate, requiring a reboot into firmware setup, that --strict cannot check:"
    echo "  - Intel VMD/RST vs AHCI          - graphics mode"
    echo "  - can Secure Boot be disabled?   - BIOS password set?"
fi

echo
printf '\033[1m===============================================================\033[0m\n'
printf '\033[1m SEND THIS ONE FILE:\033[0m\n'
printf '   %s\n' "$diag_file"
printf '   (%s)\n' "$(du -h "$diag_file" 2>/dev/null | cut -f1 | tr -d ' ') — small enough to attach or paste"
echo
echo " It is redaction-safe: no serials, MACs or UUIDs. Email it, or if this"
echo " machine has the repo checked out and push access, simply:"
echo
echo "     git add -f \"$diag_file\" && git commit -m 'M0 follow-up diagnosis' && git push"
echo
echo " (-f is needed because notes/hardware/ is gitignored by default, which is"
echo "  deliberate: the RAW capture must never be committed.)"
printf '\033[1m===============================================================\033[0m\n'

if [[ -n "${capture_out:-}" ]]; then
    echo
    echo "Full raw capture (do NOT email or commit this one): $capture_out"
    echo "It contains serials, MACs, UUIDs and the hostname. Keep a copy off-machine."
fi

# Default is diagnostic: report and exit 0, because a partial answer still has value.
# --strict turns missing ESSENTIAL evidence into a failure, for scripted or gated use.
if [[ $STRICT -eq 1 && ${#blocking[@]} -gt 0 ]]; then
    echo
    echo "--strict: exiting non-zero because essential M0 evidence is missing." >&2
    exit 1
fi
exit 0
