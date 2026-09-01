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

# The property that matters is not "every blocking+= is inside the group" — the redaction
# check legitimately runs after the group closes, and its append works normally there.
# What matters is that SOME blocking+= calls are inside, because that is what makes the
# redirect-versus-pipe distinction load-bearing rather than academic.
open_ln=$(grep -n '^{$' "$repo_root/scripts/capture-followup.sh" | cut -d: -f1)
# shellcheck disable=SC2016  # a literal grep pattern; expansion would break it
close_ln=$(grep -n '^} > "\$diag_file"$' "$repo_root/scripts/capture-followup.sh" | cut -d: -f1)
inside=0
while IFS=: read -r ln _; do
    if [[ "$ln" -gt "$open_ln" && "$ln" -lt "$close_ln" ]]; then inside=$((inside + 1)); fi
done < <(grep -n 'blocking+=' "$repo_root/scripts/capture-followup.sh")
if [[ "$inside" -ge 1 ]]; then
    pass "the group contains blocking+= calls ($inside), so the redirect is load-bearing"
else
    fail "no blocking+= inside the group — the redirect/pipe distinction no longer matters"
fi

# ---------------------------------------------------------------------------
echo
echo "== redaction scanner =="
# ---------------------------------------------------------------------------
# The diagnosis file is advertised as safe to email or push to a PUBLIC repository. That
# claim is checked against the generated file at runtime; these cases check the checker.
leakfile="$tmp/leaky.md"
cat > "$leakfile" <<'LEAKY'
uuid:          00b5cf1e-9f2a-4c3d-a1b2-0123456789ab
link/ether     aa:bb:cc:dd:ee:ff
serial:        S64ANE0R123456
inet 192.168.1.44
LEAKY
# LC_ALL=C so the comparison does not depend on the runner's collation: en_US sorts
# case-insensitively and would order these differently from the C locale.
found="$(diagnosis_leaks "$leakfile" | cut -d: -f1 | LC_ALL=C sort | paste -sd'|' -)"
check "planted MAC, UUID, serial and private IP are all caught" \
    "MAC address|UUID|labelled serial|private IPv4" \
    "$found"

cleanfile="$tmp/clean.md"
cat > "$cleanfile" <<'CLEAN'
secure boot     : SecureBoot enabled
lockdown        : none [integrity] confidential
power states    : freeze mem
/dev/nvme0n1
  health=PASSED  critical_warning=0x00
  pct_used=3%  spare=100%  media_errors=0
hwmon chips      : coretemp nvme
zone temps (m°C) : x86_pkg_temp:47000 acpitz:44000
CLEAN
check "a realistic clean diagnosis produces no findings" "" "$(diagnosis_leaks "$cleanfile")"

# Drive and chassis MODEL numbers must not be mistaken for serials — they are exactly the
# facts the profile is supposed to publish.
modelfile="$tmp/models.md"
printf 'SAMSUNG MZVL21T0HCLR-00B00\nNVIDIA GeForce RTX 3080 Laptop GPU\nTensorBook (late 2021)\n' > "$modelfile"
check "model numbers are not flagged as identifiers" "" "$(diagnosis_leaks "$modelfile")"

# ---------------------------------------------------------------------------
echo
echo "== publish gate =="
# ---------------------------------------------------------------------------
# The script now commits and pushes the diagnosis automatically. The repository may be
# PUBLIC and git history cannot be recalled, so the gate that stops an unsafe push is the
# single most important behaviour in this file. Every case below runs in a throwaway
# directory: none of it can reach the real repository.
pub_tmp="$tmp/publish"; mkdir -p "$pub_tmp"

printf 'some diagnosis content\n' > "$pub_tmp/d.md"
publish_diagnosis "$pub_tmp/d.md" "UUID: 12:uuid 00b5cf1e-..." >/dev/null 2>&1
check "a failed redaction check blocks the push" "1" "$?"

: > "$pub_tmp/empty.md"
publish_diagnosis "$pub_tmp/empty.md" "" >/dev/null 2>&1
check "an empty diagnosis file is refused" "1" "$?"

publish_diagnosis "$pub_tmp/d.md" "" >/dev/null 2>&1
check "a file outside any git repository is refused" "1" "$?"

publish_diagnosis "$pub_tmp/does-not-exist.md" "" >/dev/null 2>&1
check "a missing diagnosis file is refused" "1" "$?"

# A repository with no remote: the commit should succeed and the push should fail, and the
# script must report the failure rather than implying the evidence was shared.
repo="$pub_tmp/repo"
mkdir -p "$repo/notes/hardware"
(
    cd "$repo" || exit 1
    git init -q
    git config user.email test@example.invalid
    git config user.name "Test"
    printf 'notes/hardware/*\n' > .gitignore
    printf 'seed\n' > seed.txt
    git add -A >/dev/null 2>&1
    git commit -qm seed
) >/dev/null 2>&1
printf 'clean diagnosis content\n' > "$repo/notes/hardware/x-diagnosis.md"

publish_diagnosis "$repo/notes/hardware/x-diagnosis.md" "" >/dev/null 2>&1
check "no remote configured is reported as failure, not success" "1" "$?"

tracked="$(git -C "$repo" ls-files notes/hardware/ | tr -d '\n')"
check "the gitignored diagnosis is force-added and committed anyway" \
    "notes/hardware/x-diagnosis.md" "$tracked"

# Re-running must not create an empty commit.
before_count="$(git -C "$repo" rev-list --count HEAD)"
publish_diagnosis "$repo/notes/hardware/x-diagnosis.md" "" >/dev/null 2>&1
after_count="$(git -C "$repo" rev-list --count HEAD)"
check "an unchanged diagnosis does not create a second commit" "$before_count" "$after_count"

# Nothing above may have touched the real repository.
check "the real repository was left alone" "" \
    "$(git -C "$repo_root" status --porcelain -- notes/hardware/ 2>/dev/null | grep -c 'diagnosis' | sed 's/^0$//')"

echo
if [[ $failures -eq 0 ]]; then
    printf '\033[32mAll checks passed.\033[0m\n'
    exit 0
fi
printf '\033[31m%d check(s) failed.\033[0m\n' "$failures"
exit 1
