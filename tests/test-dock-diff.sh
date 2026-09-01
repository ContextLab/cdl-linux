#!/usr/bin/env bash
# Regression test for the dock connector-diff logic in scripts/capture-followup.sh.
#
# That logic decides which GPU drives a docked external monitor (R18/D35), which in turn
# decides whether a docked display survives an NVIDIA driver failure. It cannot be tested
# on the target hardware without physically docking and undocking, so it is tested here
# against synthetic connector snapshots — including the cases that are easy to get wrong.
#
# Runs anywhere bash runs. No root, no hardware, no network.
#
# Usage: tests/test-dock-diff.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/capture-followup.sh"
failures=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failures=$((failures + 1)); }

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$name"
    else
        fail "$name"
        printf '        expected: %s\n        actual:   %s\n' "$expected" "$actual"
    fi
}

echo "== sourcing guard =="
# Sourcing must define the helpers WITHOUT running the main body — no root check, no apt.
# If this regresses, the whole file becomes untestable.
# shellcheck source=/dev/null
source "$script"
if [[ "$(type -t snapshot_connectors)" == "function" ]]; then
    pass "helpers defined when sourced"
else
    fail "helpers not defined when sourced"
fi
if [[ "$(type -t ask_action)" == "function" ]]; then
    pass "ask_action defined when sourced"
else
    fail "ask_action not defined when sourced"
fi

# Mirrors the diff block in capture-followup.sh. Prints the connectors that newly came up.
appeared_for() {
    local undocked_conn="$1" docked_conn="$2"
    local -a appeared=()
    local conn st drv prev
    while IFS=$'\t' read -r conn st drv; do
        [[ -z "$conn" ]] && continue
        prev="$(awk -F'\t' -v c="$conn" '$1==c{print $2}' <<<"$undocked_conn")"
        if [[ "$prev" != "$st" && "$st" == "connected" ]]; then
            appeared+=("$conn|$drv")
        fi
    done <<<"$docked_conn"
    printf '%s' "${appeared[*]:-<none>}"
}

# The real topology measured on the Tensorbook, 2026-09-01: internal panel on the Intel
# iGPU (card1), external outputs split across both GPUs.
UNDOCKED=$'card0-DP-5\tdisconnected\tnvidia\ncard0-HDMI-A-1\tdisconnected\tnvidia\ncard1-DP-1\tdisconnected\ti915\ncard1-eDP-1\tconnected\ti915'

echo
echo "== connector diff =="

check "dock on an NVIDIA DisplayPort is attributed to nvidia" \
    "card0-DP-5|nvidia" \
    "$(appeared_for "$UNDOCKED" $'card0-DP-5\tconnected\tnvidia\ncard0-HDMI-A-1\tdisconnected\tnvidia\ncard1-DP-1\tdisconnected\ti915\ncard1-eDP-1\tconnected\ti915')"

check "dock on an Intel DisplayPort is attributed to i915" \
    "card1-DP-1|i915" \
    "$(appeared_for "$UNDOCKED" $'card0-DP-5\tdisconnected\tnvidia\ncard0-HDMI-A-1\tdisconnected\tnvidia\ncard1-DP-1\tconnected\ti915\ncard1-eDP-1\tconnected\ti915')"

check "no change reports nothing rather than inventing an output" \
    "<none>" \
    "$(appeared_for "$UNDOCKED" "$UNDOCKED")"

# The case most likely to produce a wrong answer in practice: docking with the lid shut.
# The internal panel disconnects at the same moment the external one appears, and only the
# latter may be reported as the dock's output.
check "lid closed while docking does not misattribute the dropped internal panel" \
    "card0-DP-5|nvidia" \
    "$(appeared_for "$UNDOCKED" $'card0-DP-5\tconnected\tnvidia\ncard0-HDMI-A-1\tdisconnected\tnvidia\ncard1-DP-1\tdisconnected\ti915\ncard1-eDP-1\tdisconnected\ti915')"

check "two displays on a dock are both reported" \
    "card0-DP-5|nvidia card0-HDMI-A-1|nvidia" \
    "$(appeared_for "$UNDOCKED" $'card0-DP-5\tconnected\tnvidia\ncard0-HDMI-A-1\tconnected\tnvidia\ncard1-DP-1\tdisconnected\ti915\ncard1-eDP-1\tconnected\ti915')"

# A connector that only exists once docked (some docks expose new sysfs nodes) must still
# be caught; its previous state is empty rather than "disconnected".
check "a connector absent when undocked is still detected" \
    "card0-DP-9|nvidia" \
    "$(appeared_for "$UNDOCKED" $'card0-DP-9\tconnected\tnvidia\ncard1-eDP-1\tconnected\ti915')"

echo
if [[ $failures -eq 0 ]]; then
    printf '\033[32mAll checks passed.\033[0m\n'
    exit 0
fi
printf '\033[31m%d check(s) failed.\033[0m\n' "$failures"
exit 1
