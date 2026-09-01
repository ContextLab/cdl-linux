#!/usr/bin/env bash
# capture-hardware.sh — one-way pre-wipe hardware capture for CDL Linux (milestone M0).
#
# Every fact this collects becomes unobtainable once the machine is reinstalled, and at least six
# design decisions currently rest on assumptions rather than measurements. See §15 of
# docs/superpowers/specs/2026-08-31-cdl-design.md.
#
# Read-only: this script never writes outside its output file and never modifies the system.
#
# Usage:
#   ./scripts/capture-hardware.sh                 # writes notes/hardware/<host>-<UTC timestamp>-raw.md
#   ./scripts/capture-hardware.sh /path/to/out.md # writes where you say
#
# The default path is timestamped to the second and will NOT be overwritten -- a capture is
# one-way evidence, so the script refuses rather than clobbering. An explicit output path is
# yours to manage and IS overwritten without asking.
#
# Run it with sudo for the full picture; without sudo it still runs and marks the privileged
# items as NOT CAPTURED rather than silently omitting them.
#
# Install these first if they are missing - both answer go/no-go questions:
#   sudo apt install -y smartmontools nvme-cli
# smartmontools in particular: under RAID0 either drive's failure loses everything, so their
# wear and error history is a decision input, not a curiosity.

set -uo pipefail

OUT="${1:-}"
if [[ -z "$OUT" ]]; then
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    mkdir -p "$repo_root/notes/hardware"
    # A capture is ONE-WAY evidence: after the machine is reinstalled it cannot be
    # recreated. An earlier version named the file by date alone, so a second run on the
    # same day silently destroyed the first capture. Two defences, deliberately redundant:
    #   1. a UTC timestamp to the second, so collision needs two runs in the same second;
    #   2. a flat refusal to clobber, so even that collision cannot destroy evidence.
    # The "-raw" suffix is load-bearing: it marks the file as raw capture output, and
    # .gitignore keeps everything in this directory out of git by default.
    OUT="$repo_root/notes/hardware/$(hostname -s 2>/dev/null || echo unknown)-$(date -u +%Y%m%dT%H%M%SZ)-raw.md"
    if [[ -e "$OUT" ]]; then
        echo "Refusing to overwrite an existing capture: $OUT" >&2
        echo "Captures are one-way evidence. Move it aside or pass an explicit output path." >&2
        exit 1
    fi
fi

missing=()
privileged_skipped=()

# capture <heading> <why it matters> <command...>
# Records the command, its availability, and its verbatim output. A tool that is absent is
# recorded as absent — never silently skipped, because a missing fact is itself a finding.
capture() {
    local heading="$1" why="$2"
    shift 2
    local cmd=("$@")

    printf '\n### %s\n\n_%s_\n\n' "$heading" "$why" >>"$OUT"
    printf '```console\n$ %s\n' "${cmd[*]}" >>"$OUT"

    # Availability must be checked on the real binary, not on "sudo" — every machine has sudo.
    # And when we are not already root, force sudo non-interactive so an unprivileged run records
    # a clean NOT CAPTURED instead of blocking forever on a password prompt.
    local bin="${cmd[0]}"
    if [[ "$bin" == "sudo" ]]; then
        bin="${cmd[1]}"
        [[ $EUID -ne 0 ]] && cmd=(sudo -n "${cmd[@]:1}")
    fi

    if ! command -v "$bin" >/dev/null 2>&1; then
        printf 'NOT CAPTURED: %s is not installed on this machine.\n```\n' "$bin" >>"$OUT"
        missing+=("$heading ($bin not installed)")
        return
    fi

    local output status
    output="$("${cmd[@]}" 2>&1)"
    status=$?

    if [[ $status -ne 0 && -z "$output" ]]; then
        printf 'NOT CAPTURED: exited %d with no output.\n' "$status" >>"$OUT"
        missing+=("$heading (exit $status)")
    else
        printf '%s\n' "$output" >>"$OUT"
        if [[ $status -ne 0 ]]; then
            printf '\n[exited %d — output above may be partial]\n' "$status" >>"$OUT"
            missing+=("$heading (exit $status, partial)")
        fi
        # A privileged command that ran as a normal user usually returns a permission complaint
        # rather than failing outright. Flag it so the operator knows to re-run with sudo.
        if [[ $EUID -ne 0 ]] && grep -qiE 'permission denied|must be root|requires root|operation not permitted|password is required|a terminal is required' <<<"$output"; then
            privileged_skipped+=("$heading")
        fi
    fi
    printf '```\n' >>"$OUT"
}

section() { printf '\n---\n\n## %s\n' "$1" >>"$OUT"; }

: >"$OUT"
cat >>"$OUT" <<HEADER
# Hardware capture — $(hostname 2>/dev/null || echo unknown)

**Captured:** $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)
**Captured by:** \`$(basename "${BASH_SOURCE[0]}")\` as $([[ $EUID -eq 0 ]] && echo 'root' || echo "unprivileged user ($(id -un))")
**Kernel:** $(uname -srm 2>/dev/null || echo unknown)

> One-way capture. Everything below becomes unobtainable after reinstallation.
> \`NOT CAPTURED\` markers are deliberate: a missing fact is recorded, never silently omitted.
HEADER

section "Identity and firmware"
capture "Product name" "Confirms the exact Tensorbook model; the striping design assumes a specific drive configuration." \
    sudo dmidecode -s system-product-name
capture "System version" "Distinguishes hardware revisions with different panels and drive layouts." \
    sudo dmidecode -s system-version
capture "BIOS version" "Razer BIOS updates are typically Windows-only; LVFS coverage is poor. Record it before the Windows install is destroyed." \
    sudo dmidecode -s bios-version
capture "BIOS release date" "Dates the firmware, which is how you tell whether a documented chassis quirk has already been fixed upstream." \
    sudo dmidecode -s bios-release-date
capture "Secure Boot state" "Decides whether signed kernel modules are required and whether MOK enrollment joins the interactive install steps." \
    mokutil --sb-state
capture "TPM device nodes" "Gates every TPM option. D7 rejected TPM auto-unlock, so this may be moot — but record it while it is knowable." \
    ls -l /dev/tpm0 /dev/tpmrm0
capture "TPM enrollment capability" "A device node is not the same question as whether systemd can actually enroll against it." \
    sudo systemd-cryptenroll --tpm2-device=list

section "Storage"
capture "NVMe device list" "The striping design assumes BOTH drives are NVMe. At least one documented Tensorbook shipped 1 TB NVMe + 1 TB M.2 SATA, which would make striping actively harmful." \
    sudo nvme list
capture "Block devices with sector sizes" "PHY-SEC/LOG-SEC decide the LUKS --sector-size 4096 tuning; TRAN confirms NVMe vs SATA." \
    lsblk -e7 -o NAME,MODEL,TRAN,ROTA,PHY-SEC,LOG-SEC,SIZE,FSTYPE,MOUNTPOINT
capture "SMART health, drive 0" "Wear and error history before the wipe. RAID0 means either drive's failure loses everything." \
    sudo smartctl -a /dev/nvme0n1
capture "SMART health, drive 1" "As above for the second drive." \
    sudo smartctl -a /dev/nvme1n1
capture "Partition tables" "The existing layout, recorded before it is destroyed." \
    sudo fdisk -l
capture "Filesystem UUIDs" "Existing filesystems and their identifiers." \
    sudo blkid

section "GPU and display topology"
capture "GPU detail" "GPU model, VRAM, driver version, power and thermal limits. Sizes the local-model picker and the sustained-load thermal question." \
    nvidia-smi -q
capture "PCI devices with bound drivers" "The -k flag shows which driver is actually bound, not merely which could be. Decides the wifi firmware package and the console path." \
    lspci -nnk
capture "DRM connectors" "Panel and connector topology; decides whether the console comes from i915/simpledrm or nvidia-drm." \
    ls -l /sys/class/drm/
capture "Display providers" "Confirms the hybrid-graphics arrangement. Absent under a pure console, which is itself informative." \
    xrandr --listproviders
# shellcheck disable=SC2016  # deliberate: the inner sh -c does the expanding, not us
capture "Connector status" "Which outputs are physically connected right now. Run this once undocked and once docked: the diff shows exactly which connector a dock drives, and therefore which GPU has to be alive for an external monitor to work." \
    sh -c 'for f in /sys/class/drm/card*-*/status; do printf "%s: %s\n" "${f%/status}" "$(cat "$f")"; done'
# shellcheck disable=SC2016  # deliberate: the inner sh -c does the expanding, not us
capture "Connector modes" "Available resolutions and refresh rates per connected output; sizes the external-monitor case." \
    sh -c 'for f in /sys/class/drm/card*-*/modes; do [ -s "$f" ] && printf "%s: %s\n" "${f%/modes}" "$(head -3 "$f" | tr "\n" " ")"; done'
capture "Thunderbolt / USB4 devices" "A dock usually arrives over Thunderbolt or USB4. Its authorization state decides whether the dock works at all after a reboot." \
    sh -c 'ls -l /sys/bus/thunderbolt/devices/ 2>/dev/null || echo "no thunderbolt bus"'
capture "Thunderbolt device detail" "Names the attached dock and its security level." \
    boltctl list

section "Memory"
capture "Memory totals" "Swap must be >= RAM for hibernation (D25/D29). The current 72 GiB figure assumes 64 GB from a vendor launch post, NOT from measurement. This command settles the entire LVM layout." \
    free -g
capture "Memory modules" "Installed size, speed and slots — whether RAM is upgradeable, which would change the swap sizing." \
    sudo dmidecode -t memory

section "Power and sleep"
capture "Supported sleep states" "The bracketed entry is active. Distinguishes s2idle from deep S3, which is the root of the known Razer suspend quirks." \
    cat /sys/power/mem_sleep
capture "Supported power states" "Confirms whether 'disk' (hibernate) is offered at all. D29 makes hibernation a launch requirement." \
    cat /sys/power/state
capture "Kernel lockdown state" "Explains a MISSING 'disk' above. The kernel hides hibernation when LOCKDOWN_HIBERNATION is blocked, which Secure Boot triggers via lockdown integrity mode. Without this, an absent 'disk' has no diagnosis." \
    cat /sys/kernel/security/lockdown
capture "Configured resume device" "Whether hibernation has ever been wired up on this install." \
    sh -c 'cat /sys/power/resume /sys/power/resume_offset 2>/dev/null'
capture "Battery design capacity" "Dependency-free sysfs read, so it survives upower being absent." \
    sh -c 'cat /sys/class/power_supply/BAT*/energy_full_design /sys/class/power_supply/BAT*/charge_full_design 2>/dev/null'
capture "Battery state" "Critical-battery behaviour matters: UPower's default chain ends in PowerOff with no hibernation swap, which on an FDE machine means total session loss." \
    upower --dump

section "Thermal and fan control"
# READ-ONLY. Section 16.5 assigns M0 the job of recording what fan-control interfaces this
# chassis exposes, because a verified first-hand report on this model says "I have not been
# able to do any fan control at all" and D28 puts 1-2 local agents on the GPU. Nothing here
# writes to pwm*, fan*, or any thermal setting -- M0 observes, it does not tune.
# shellcheck disable=SC2016  # deliberate: the inner sh -c does the expanding, not us
capture "Hardware monitoring chips" "Names the hwmon devices present. No hwmon entry for the EC means no fan telemetry, let alone fan control." \
    sh -c 'for f in /sys/class/hwmon/hwmon*/name; do printf "%s: %s\n" "${f%/name}" "$(cat "$f" 2>/dev/null)"; done'
# shellcheck disable=SC2016  # deliberate: the inner sh -c does the expanding, not us
capture "Fan and PWM interfaces" "Whether fan speeds are even readable, and whether any writable pwm control exists. Absence here confirms the reported no-fan-control situation rather than leaving it hearsay." \
    sh -c 'found=0; for f in /sys/class/hwmon/hwmon*/fan*_input /sys/class/hwmon/hwmon*/pwm[0-9]*; do [ -e "$f" ] || continue; found=1; printf "%s (mode %s): %s\n" "$f" "$(stat -c %a "$f" 2>/dev/null)" "$(cat "$f" 2>/dev/null || echo unreadable)"; done; [ "$found" = 0 ] && echo "no fan_input or pwm interfaces exposed"'
# shellcheck disable=SC2016  # deliberate: the inner sh -c does the expanding, not us
capture "Thermal zones and trip points" "Current temperatures plus the trip points that decide when throttling starts. The trip points are what a sustained-load policy is written against, so record them while the machine is stock." \
    sh -c 'for f in /sys/class/thermal/thermal_zone*/type; do d="${f%/type}"; printf "%s: %s = %s\n" "$d" "$(cat "$f" 2>/dev/null)" "$(cat "$d/temp" 2>/dev/null)"; for tp in "$d"/trip_point_*_type; do [ -e "$tp" ] || continue; printf "    %s: %s @ %s\n" "${tp##*/}" "$(cat "$tp" 2>/dev/null)" "$(cat "${tp%_type}_temp" 2>/dev/null)"; done; done'
# shellcheck disable=SC2016  # deliberate: the inner sh -c does the expanding, not us
capture "Cooling devices" "What the kernel can actually actuate for cooling, and its current versus maximum state. An empty list is the strongest evidence that fan control is unavailable." \
    sh -c 'found=0; for d in /sys/class/thermal/cooling_device*; do [ -e "$d/type" ] || continue; found=1; printf "%s: %s cur=%s max=%s\n" "${d##*/}" "$(cat "$d/type" 2>/dev/null)" "$(cat "$d/cur_state" 2>/dev/null)" "$(cat "$d/max_state" 2>/dev/null)"; done; [ "$found" = 0 ] && echo "no cooling devices exposed"'
capture "Razer HID devices" "Razer chassis control tools bind to vendor 1532 USB/HID devices. Presence is a NECESSARY condition, not proof of support: it determines whether further compatibility probing is possible. Actual model recognition and supported commands still need a read-only probe from whichever utility is chosen." \
    sh -c 'lsusb 2>/dev/null | grep -i "1532\|razer" || echo "no Razer (1532) USB device found"'
capture "CPU thermal and frequency driver" "Which driver governs CPU throttling, which is the other half of the sustained-load question." \
    sh -c 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "no cpufreq scaling_driver"'

section "Network"
capture "Network controllers" "Wifi chipset determines the firmware package that must ship on the ISO." \
    lspci -nn
capture "USB devices" "Razer-specific USB peripherals (vendor 1532) and any wifi dongle." \
    lsusb
capture "Wireless interfaces" "Confirms the driver actually binds and the interface appears." \
    iw dev
capture "NetworkManager device status" "Current connectivity, and whether NetworkManager is the manager in play." \
    nmcli device status

section "Current boot configuration"
capture "Kernel command line" "Existing workarounds and quirks already applied to this machine." \
    cat /proc/cmdline
capture "Kernel and architecture" "Baseline for comparison against the target 26.04 HWE kernel." \
    uname -a
capture "Loaded modules" "Which drivers this machine actually needs in order to boot and run." \
    lsmod

cat >>"$OUT" <<'FOOTER'

---

## Firmware settings — MANUAL, requires a reboot into setup

These cannot be read from a running system and are not optional. Record the answers here by hand.

- [ ] **Storage mode: Intel VMD/RST, or AHCI?**
      If VMD/RST is enabled and cannot be disabled, a stock installer sees no disks at all and the
      project stops. This is the single highest-consequence firmware fact.
- [ ] **Chipset graphics: "Dedicated GPU Only" or "Dynamic Display Switch"?**
      Decides whether the console is driven by `i915`/`simpledrm` or by `nvidia-drm`, which decides
      the entire session and rescue-console design.
- [ ] **Secure Boot: enabled, and can it be disabled?**
- [ ] **Any BIOS password set?**

FOOTER

{
    printf '\n## Capture completeness\n\n'
    if [[ ${#missing[@]} -eq 0 ]]; then
        printf 'Every command produced output.\n'
    else
        printf 'The following were NOT fully captured:\n\n'
        printf -- '- %s\n' "${missing[@]}"
    fi
    if [[ ${#privileged_skipped[@]} -gt 0 ]]; then
        printf '\n**Re-run with sudo** — these needed privileges:\n\n'
        printf -- '- %s\n' "${privileged_skipped[@]}"
    fi
} >>"$OUT"

echo "Capture written to: $OUT"
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Incomplete: ${#missing[@]} item(s) not captured. See the 'Capture completeness' section." >&2
fi
if [[ $EUID -ne 0 ]]; then
    echo "Note: run with sudo for dmidecode, nvme, smartctl, fdisk and blkid." >&2
fi
