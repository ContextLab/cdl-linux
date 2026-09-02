#!/usr/bin/env bash
#
# verify-firmware.sh — post-firmware-change verification for the M0 firmware gate.
#
# Run on the Tensorbook AFTER the firmware walk (notes/hardware/firmware-gate-checklist.md),
# once the machine has booted back into Linux. Answers the questions the firmware menus could
# NOT answer, writes a redaction-checked file, and pushes it so it can be read from another
# machine — the operator drives the firmware from the laptop itself, so pasting output into a
# session running elsewhere is not possible.
#
# Three of these are live questions, not ceremony:
#
#   1. VT-d / IOMMU state. This firmware exposes NO VT-d toggle (checklist item 10), so its
#      state is unknown from the firmware side. The hardware profile asserts it is enabled,
#      citing boltd's stored `policy: iommu` — strong but indirect. /sys/class/iommu is the
#      direct read. If it is empty, the profile's Thunderbolt DMA-protection reasoning is
#      wrong and must be revised.
#   2. Whether an OS-side throttle lever exists. Item 5 established there is NO fan control
#      anywhere, firmware or OS, so §16.5's sustained-load policy must rest entirely on
#      throttling. That policy is only implementable if intel_pstate exposes the controls.
#   3. Which wake sources are armed. Item 7 established there is no firmware wake control, so
#      the spurious-XHC-wake hypothesis for the 65–66 unsafe shutdowns can only be tested here.
#
# Read-only except for the file it writes. Usage:  sudo scripts/verify-firmware.sh
set -uo pipefail

# Runs a command as the user who invoked sudo. Git under sudo would use root's config and
# credentials — usually no identity and no GitHub access — and would leave root-owned objects
# in a repository owned by someone else. Outside sudo this is a straight pass-through.
as_user() {
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        sudo -u "$SUDO_USER" -- "$@"
    else
        "$@"
    fi
}

# Reports identifiers found in a file about to be pushed to a PUBLIC repository, one
# "label: line" per finding, empty when clean. Same pattern set as capture-followup.sh:
# a leak reaching public git history cannot be recalled.
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

# Commits and pushes ONE file, refusing loudly if anything is unsafe. Never reports success
# it did not achieve: a silent "pushed" that did not push would send the operator away
# believing the evidence was shared.
publish() {
    local file="$1" leaks="$2" repo branch

    # HARD GATE. Nothing below runs unless the redaction scan came back empty.
    if [[ -n "$leaks" ]]; then
        echo "NOT pushing: the redaction check found identifiers in $file." >&2
        printf '  %s\n' "$leaks" >&2
        return 1
    fi
    [[ -s "$file" ]] || { echo "NOT pushing: $file is missing or empty." >&2; return 1; }
    command -v git >/dev/null 2>&1 || { echo "NOT pushing: git is not installed." >&2; return 1; }

    repo="$(as_user git -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null)" || repo=""
    [[ -n "$repo" ]] || { echo "NOT pushing: $file is not inside a git repository." >&2; return 1; }

    # Hand ownership back before touching git, so a sudo run does not leave root-owned files
    # in a repository the operator has to keep working in afterwards.
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        chown "$SUDO_USER" "$file" 2>/dev/null || true
    fi

    branch="$(as_user git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    echo "Publishing $(basename "$file") to $branch..."

    as_user git -C "$repo" pull --rebase --quiet 2>/dev/null \
        || echo "  note: pull --rebase failed or was unnecessary; continuing." >&2

    # -f is required because notes/hardware/ is gitignored fail-closed, which keeps the RAW
    # capture out of git. Forcing is safe only because the redaction gate above passed.
    as_user git -C "$repo" add -f "$file" 2>/dev/null \
        || { echo "NOT pushing: git add failed." >&2; return 1; }

    if as_user git -C "$repo" diff --cached --quiet -- "$file" 2>/dev/null; then
        echo "  nothing new to commit — this verification is already recorded."
    elif ! as_user git -C "$repo" commit --quiet \
            -m "M0 firmware verification: $(basename "$file")" -- "$file" 2>/dev/null; then
        echo "NOT pushing: git commit failed (is user.name/user.email configured?)." >&2
        return 1
    fi

    if as_user git -C "$repo" push --quiet 2>/dev/null; then
        echo "  pushed. Nothing further needed — the verification is in the repository."
        return 0
    fi
    echo "PUSH FAILED — the commit exists locally but did NOT reach the remote." >&2
    echo "  Either run:  git -C $repo push" >&2
    echo "  or copy this file across by hand:  $file" >&2
    return 1
}

# Prints "label: value", or a stated placeholder when the path is unreadable. An unreadable
# path is a finding, not a blank — silence would be indistinguishable from a passing check.
show() {
    local label="$1" path="$2" val
    val="$(tr '\n' ' ' <"$path" 2>/dev/null)" || val=""
    printf '%-34s: %s\n' "$label" "${val:-UNREADABLE ($path)}"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$repo_root/notes/hardware/tensorbook-$(date -u +%Y%m%dT%H%M%SZ)-firmware-verify.md"
mkdir -p "$(dirname "$out")"

{
echo "# Tensorbook — post-firmware verification"
echo
echo "Generated by \`scripts/verify-firmware.sh\` at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
echo "Kernel: $(uname -r). Closes item 11 of \`notes/hardware/firmware-gate-checklist.md\`."
echo
echo '## 1. VT-d / IOMMU — checklist item 10, the open question'
echo
echo '```'
iommu_dirs="$(ls -1 /sys/class/iommu/ 2>/dev/null)"
if [[ -n "$iommu_dirs" ]]; then
    printf '%-34s: %s\n' "/sys/class/iommu entries" "$(tr '\n' ' ' <<<"$iommu_dirs")"
    printf '%-34s: %s\n' "VERDICT" "VT-d is ACTIVE. The profile's claim is confirmed by direct read."
else
    printf '%-34s: %s\n' "/sys/class/iommu entries" "EMPTY"
    printf '%-34s: %s\n' "VERDICT" "NO IOMMU. The profile's Thunderbolt DMA reasoning needs revision."
fi
show "TB domain0 DMA protection" /sys/bus/thunderbolt/devices/domain0/iommu_dma_protection
echo "-- DMAR/IOMMU kernel messages --"
dmesg 2>/dev/null | grep -iE "DMAR|IOMMU" | head -6 || echo "(none, or dmesg restricted)"
echo '```'
echo
echo '## 2. Thermal throttle levers — checklist item 5'
echo
echo 'Item 5 established there is NO fan control anywhere. §16.5 policy must rest on'
echo 'throttling, which is only implementable if these controls exist.'
echo
echo '```'
show "intel_pstate no_turbo" /sys/devices/system/cpu/intel_pstate/no_turbo
show "intel_pstate max_perf_pct" /sys/devices/system/cpu/intel_pstate/max_perf_pct
show "scaling driver (cpu0)" /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
printf '%-34s: %s\n' "fan inputs (expect 0)" "$(find /sys/class/hwmon -name 'fan*_input' 2>/dev/null | wc -l | tr -d ' ')"
printf '%-34s: %s\n' "writable PWM (expect 0)" "$(find /sys/class/hwmon -name 'pwm[0-9]' -writable 2>/dev/null | wc -l | tr -d ' ')"
echo '```'
echo
echo '## 3. Wake sources — checklist item 7, the unsafe-shutdown hypothesis'
echo
echo 'No firmware wake control exists, so any fix must be made here and made persistent'
echo '(/proc/acpi/wakeup resets every boot).'
echo
echo '```'
cat /proc/acpi/wakeup 2>/dev/null || echo "UNREADABLE (/proc/acpi/wakeup)"
echo '```'
echo
echo '## 4. State that must NOT have changed'
echo
echo '```'
show "mem_sleep (expect s2idle [deep])" /sys/power/mem_sleep
show "power/state (expect freeze mem)" /sys/power/state
show "lockdown (expect [integrity])" /sys/kernel/security/lockdown
if command -v mokutil >/dev/null 2>&1; then
    printf '%-34s: %s\n' "Secure Boot" "$(mokutil --sb-state 2>&1 | head -1)"
else
    printf '%-34s: %s\n' "Secure Boot" "mokutil not installed"
fi
echo '```'
echo
echo '## 5. boltd — checklist item 8 hard dependency'
echo
echo 'Firmware exposes no Thunderbolt security policy, so authorisation lives ENTIRELY in the'
echo 'OS. If boltd is absent the dock cannot be authorised and no firmware setting can rescue'
echo 'it. Device count only: a full boltctl listing prints uuid, serial and key material.'
echo
echo '```'
if command -v boltctl >/dev/null 2>&1; then
    printf '%-34s: %s\n' "boltctl" "present"
    # Count one line per device. An earlier version matched the bullet glyph that prefixes
    # each entry; that is multibyte, so the bracket expression was locale-dependent and
    # counted 0 against a populated list. `uuid:` appears exactly once per device and is
    # plain ASCII. Counted only — never printed, because it identifies the device.
    # grep -c always prints a number and exits 1 on zero matches, so no `|| echo 0`: that
    # appended a SECOND zero to the field.
    bolt_n="$(boltctl list 2>/dev/null | grep -c 'uuid:')"
    printf '%-34s: %s\n' "stored/known devices" "${bolt_n:-0}"
    # The domain's security level is what firmware would have set. Firmware exposes no
    # Thunderbolt policy at all (checklist item 8), so this is the only place it is visible.
    show "TB domain0 security level" /sys/bus/thunderbolt/devices/domain0/security
else
    printf '%-34s: %s\n' "boltctl" "MISSING — hard dependency per checklist item 8"
fi
echo '```'
} > "$out"

echo "Wrote $out"
echo
leaks="$(diagnosis_leaks "$out")"
if [[ -n "$leaks" ]]; then
    echo "REDACTION CHECK FAILED — not publishing:" >&2
    printf '  %s\n' "$leaks" >&2
    exit 1
fi
echo "Redaction check: clean."
publish "$out" "$leaks"
