#!/usr/bin/env bash
# install.sh: ordering, failure propagation, idempotence reporting and the run record.
#
# Uses fixture modules via CDL_MODULE_DIR, so nothing is installed and the checks run on
# any machine. What cannot be tested here -- the flock refusal (no flock on macOS) and real
# apt behaviour -- belongs to tests/run-vm.sh, and is not silently skipped: it is absent.

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  \033[32mOK\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mods="$work/modules"; mkdir -p "$mods"
# No flock on macOS. Real lock contention is tested in the VM, where flock exists; here
# the lock is disabled explicitly and its absence is asserted separately below.
export CDL_MODULE_DIR="$mods" CDL_LOG_DIR="$work/log" CDL_LOCK_FILE="$work/lock" CDL_NO_LOCK=1

# A preflight that passes, so the run loop itself is what is under test.
printf '#!/usr/bin/env bash\nexit 0\n' > "$mods/00-preflight.sh"

printf '#!/usr/bin/env bash\necho ran-10\nexit 0\n'  > "$mods/10-first.sh"
printf '#!/usr/bin/env bash\necho ran-20\nexit 2\n'  > "$mods/20-skipper.sh"
printf '#!/usr/bin/env bash\necho ran-30\nexit 7\n'  > "$mods/30-broken.sh"
printf '#!/usr/bin/env bash\necho ran-40\nexit 0\n'  > "$mods/40-after.sh"
chmod +x "$mods"/*.sh

out="$("$repo/install.sh" 2>&1)"; rc=$?

check "a failed module makes the run exit nonzero" "$rc" "1"
if grep -q 'ran-10' <<<"$out"; then ok "modules run in lexical order (10 ran)"; else bad "10 did not run"; fi
if grep -q 'ran-40' <<<"$out"; then bad "40 ran after a failure"; else ok "a failed module stops later modules"; fi
if grep -q 'did not run: 1' <<<"$out"; then ok "summary counts the module that did not run"; else bad "summary 'did not run' wrong: $(grep 'did not run' <<<"$out")"; fi
if grep -q 'ok: 1   skipped: 1   failed: 1' <<<"$out"; then ok "summary counts are truthful"; else bad "summary: $(grep 'ok:' <<<"$out")"; fi
if grep -q -- '--module 30-broken' <<<"$out"; then ok "failure names the command that re-runs it"; else bad "no re-run instruction"; fi

# Machine-readable record
rec="$work/log/install-runs.jsonl"
if [ -f "$rec" ]; then ok "a run record is written"; else bad "no run record at $rec"; fi
check "record has one line per module that ran" "$(wc -l < "$rec" | tr -d ' ')" "3"
if python3 -c "
import json,sys
rows=[json.loads(l) for l in open('$rec')]
assert [r['module'] for r in rows]==['10-first','20-skipper','30-broken'], rows
assert [r['result'] for r in rows]==['ok','skipped','failed'], rows
assert rows[2]['exit']==7
assert len({r['run'] for r in rows})==1
" 2>/dev/null; then ok "run record is valid JSON with correct results"; else bad "run record content wrong"; fi

# Re-running one module skips preflight and runs only that one
out2="$("$repo/install.sh" --module 10-first 2>&1)"; rc2=$?
check "re-running a single module succeeds" "$rc2" "0"
if grep -q 'ran-20' <<<"$out2"; then bad "--module ran more than one module"; else ok "--module runs exactly one module"; fi

# Unknown module names are refused rather than silently doing nothing
"$repo/install.sh" --module nope >/dev/null 2>&1
check "an unknown --module is refused" "$?" "1"

# --dry-run changes nothing
rm -rf "$work/log"
"$repo/install.sh" --dry-run >/dev/null 2>&1
if [ -f "$work/log/install-runs.jsonl" ]; then bad "--dry-run wrote a run record"; else ok "--dry-run changes nothing"; fi

# --- preflight refuses unsupported machines, before any mutation ---
osr="$work/osr"
printf 'ID=debian\nVERSION_ID="12"\n' > "$osr"
CDL_OS_RELEASE="$osr" CDL_ARCH=x86_64 bash "$repo/install/modules/00-preflight.sh" >/dev/null 2>&1
check "preflight refuses a non-Ubuntu machine" "$?" "1"

printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$osr"
CDL_OS_RELEASE="$osr" CDL_ARCH=x86_64 bash "$repo/install/modules/00-preflight.sh" >/dev/null 2>&1
check "preflight refuses the wrong Ubuntu release" "$?" "1"

printf 'ID=ubuntu\nVERSION_ID="26.04"\n' > "$osr"
msg="$(CDL_OS_RELEASE="$osr" CDL_ARCH=aarch64 bash "$repo/install/modules/00-preflight.sh" 2>&1)"
if grep -q 'architecture is aarch64' <<<"$msg"; then ok "preflight names the wrong architecture"; else bad "arch message unclear"; fi

# --- the btrfs module is a guard, not an attempt ---
msg="$(bash "$repo/install/modules/15-btrfs-subvolumes.sh" 2>&1)"; rc3=$?
# Exit 2 (skip), not 1: a machine without the subvolume layout is fully supported in
# portable mode, and exit 1 here stopped every later module on exactly that machine. The
# earlier assertion of "1" encoded the bug.
check "15-btrfs-subvolumes SKIPS (exit 2) on a non-@ root, so later modules run" "$rc3" "2"
if grep -q 'reinstall' <<<"$msg"; then ok "the guard says how to get the layout"; else bad "guard gives no route forward"; fi

# A missing flock must be reported as a missing flock, not as a concurrent run.
if ! command -v flock >/dev/null 2>&1; then
    msg="$(env -u CDL_NO_LOCK "$repo/install.sh" 2>&1)"
    if grep -q 'flock not found' <<<"$msg"; then ok "a missing flock is named, not mistaken for a held lock"
    else bad "missing flock misreported: $(head -1 <<<"$msg")"; fi
fi

printf '\n  test-install-framework: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
