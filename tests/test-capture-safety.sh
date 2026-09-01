#!/usr/bin/env bash
# Regression tests for the capture-script hazards found in review round five, plus the
# structural property the diagnosis file depends on.
#
#   1. Overwrite protection. A hardware capture is ONE-WAY evidence — after the machine is
#      reinstalled it cannot be recreated. An earlier version named the output file by date
#      alone, so a second run on the same day silently destroyed the first capture. This was
#      reproduced as real data loss before being fixed.
#
#   2. SMART field validation. smartctl exiting 0 is not the same as smartctl producing
#      usable output: a wrong device type, a USB bridge, or a permissions problem yields
#      empty fields while the command still succeeds. --strict must fail on that rather than
#      reporting a clean bill of health for drives it never actually read.
#
# Runs anywhere bash runs. No root, no hardware, no network.
#
# Usage: tests/test-capture-safety.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failures=$((failures + 1)); }

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$name"
    else
        fail "$name"
        printf '        expected: [%s]\n        actual:   [%s]\n' "$expected" "$actual"
    fi
}

# ---------------------------------------------------------------------------
echo "== capture overwrite protection =="
# ---------------------------------------------------------------------------
mkdir -p "$tmp/repo/scripts" "$tmp/repo/notes/hardware"
cp "$repo_root/scripts/capture-hardware.sh" "$tmp/repo/scripts/"
cd "$tmp/repo" || exit 1

# Stand in for a capture that already exists and must never be destroyed.
sentinel="notes/hardware/existing-20260101T000000Z-raw.md"
printf 'IRREPLACEABLE ORIGINAL CAPTURE\n' > "$sentinel"

./scripts/capture-hardware.sh >/dev/null 2>&1
check "an unrelated existing capture is left untouched" \
    "IRREPLACEABLE ORIGINAL CAPTURE" \
    "$(head -1 "$sentinel")"

# Two runs a second apart must produce two files, not one overwritten one.
sleep 1
./scripts/capture-hardware.sh >/dev/null 2>&1
produced=$(find notes/hardware -name '*-raw.md' ! -name 'existing-*' | wc -l | tr -d ' ')
check "two runs produce two distinct captures" "2" "$produced"

# The default path must refuse to clobber even on a same-second collision.
collide="notes/hardware/$(hostname -s 2>/dev/null || echo unknown)-$(date -u +%Y%m%dT%H%M%SZ)-raw.md"
printf 'SECOND IRREPLACEABLE CAPTURE\n' > "$collide"
./scripts/capture-hardware.sh >/dev/null 2>&1
rc=$?
check "same-second collision refuses rather than clobbering" \
    "SECOND IRREPLACEABLE CAPTURE" \
    "$(head -1 "$collide")"
check "and it signals refusal with a non-zero exit" "1" "$rc"

# An explicit path is the caller's to manage, and documented as overwritable.
printf 'OLD\n' > "$tmp/explicit.md"
./scripts/capture-hardware.sh "$tmp/explicit.md" >/dev/null 2>&1
if [[ "$(head -1 "$tmp/explicit.md")" != "OLD" ]]; then
    pass "an explicit output path is still overwritten, as documented"
else
    fail "an explicit output path should be overwritten, as documented"
fi

cd "$repo_root" || exit 1

# ---------------------------------------------------------------------------
echo
echo "== SMART field validation (--strict) =="
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$repo_root/scripts/capture-followup.sh"

joined() { smart_unparsed_fields "$@" | paste -sd'|' -; }

check "fully parseable output reports nothing missing" \
    "" \
    "$(joined "PASSED" "0x00" "3" "100" "0")"

check "smartctl that produced nothing flags all five fields" \
    "overall health|critical warning|percentage used|available spare|media/data-integrity errors" \
    "$(joined "" "" "" "" "")"

check "a missing health line alone is caught" \
    "overall health" \
    "$(joined "" "0x00" "3" "100" "0")"

# The realistic failure: smartctl prints a header and exits 0, but the NVMe log is absent,
# so numeric fields come back as "N/A" rather than empty.
check "non-numeric N/A values are treated as unparseable, not as zero" \
    "percentage used|available spare|media/data-integrity errors" \
    "$(joined "PASSED" "0x00" "N/A" "N/A" "N/A")"

check "zero is a valid reading and must not be flagged" \
    "" \
    "$(joined "PASSED" "0x00" "0" "0" "0")"

check "a partially populated log flags only the absent fields" \
    "available spare|media/data-integrity errors" \
    "$(joined "PASSED" "0x00" "5" "" "")"

# ---------------------------------------------------------------------------
echo
echo "== diagnosis file is written by a redirected group, not a pipe =="
# ---------------------------------------------------------------------------
# The DIAGNOSIS block appends to the `blocking` array while writing to the diagnosis file.
# A redirected group keeps those appends; piping the same block to `tee` would run it in a
# subshell and silently discard every one of them, leaving --strict unable to fail. This
# guards the structure, because the pipe version looks tidier and would pass every other test.
arr_redirect=()
{ echo ignored; arr_redirect+=(x); } > /dev/null
check "a redirected group preserves array appends" "1" "${#arr_redirect[@]}"

arr_pipe=()
# shellcheck disable=SC2030,SC2031  # losing the value IS the assertion here
{ echo ignored; arr_pipe+=(x); } | cat > /dev/null
# shellcheck disable=SC2031  # reading the LOST value is the assertion
check "a piped group loses them (this is why the script must not use a pipe)" "0" "${#arr_pipe[@]}"

grp_open=$(grep -c '^{$' "$repo_root/scripts/capture-followup.sh")
# shellcheck disable=SC2016  # a literal grep pattern; expansion would break it
grp_close=$(grep -c '^} > "\$diag_file"$' "$repo_root/scripts/capture-followup.sh")
check "capture-followup.sh opens exactly one such group" "1" "$grp_open"
check "and closes it with a redirect, not a pipe" "1" "$grp_close"

if grep -qE '^\} \| *tee' "$repo_root/scripts/capture-followup.sh"; then
    fail "the diagnosis group is piped to tee — --strict would silently stop working"
else
    pass "the diagnosis group is not piped to tee"
fi

# Every blocking+= call must sit inside that group, or it cannot influence --strict.
open_ln=$(grep -n '^{$' "$repo_root/scripts/capture-followup.sh" | cut -d: -f1)
# shellcheck disable=SC2016  # a literal grep pattern; expansion would break it
close_ln=$(grep -n '^} > "\$diag_file"$' "$repo_root/scripts/capture-followup.sh" | cut -d: -f1)
outside=0
while IFS=: read -r ln _; do
    if [[ "$ln" -lt "$open_ln" || "$ln" -gt "$close_ln" ]]; then outside=$((outside + 1)); fi
done < <(grep -n 'blocking+=' "$repo_root/scripts/capture-followup.sh")
check "every blocking+= call sits inside the diagnosis group" "0" "$outside"

echo
if [[ $failures -eq 0 ]]; then
    printf '\033[32mAll checks passed.\033[0m\n'
    exit 0
fi
printf '\033[31m%d check(s) failed.\033[0m\n' "$failures"
exit 1
