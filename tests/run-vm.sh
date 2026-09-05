#!/usr/bin/env bash
# The full VM cycle: install, boot, verify the storage layout, verify the migration
# fixture, and round-trip a backup. Minutes, not seconds, which is why it is not in
# run-all.sh.
#
# Usage: tests/run-vm.sh [--keep]
#
# Everything here runs against a virtual machine. Nothing touches the host's disks.

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo" || exit 1

keep=0
[ "${1:-}" = "--keep" ] && keep=1

: "${VM_WORK:=${TMPDIR:-/tmp}/cdl-vm}"
export VM_WORK
mkdir -p "$VM_WORK"

step()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
fatal() { printf '\033[31mFATAL\033[0m %s\n' "$*"; exit 1; }

# Refuse to start on top of a running VM. A blind `pkill -f qemu` once killed an install
# that was in progress; this checks instead of killing.
if pgrep -f 'qemu.*cdl0' >/dev/null 2>&1; then
    fatal "a cdl VM is already running. Stop it first, or wait for it to finish."
fi

step "install"
[ "$keep" -eq 1 ] || rm -f "$VM_WORK/efi-vars.fd"
./scripts/vm/install.sh || fatal "install failed (log: $VM_WORK/install.log)"
grep -q POWEROFF "$VM_WORK/install.log" 2>/dev/null \
    || fatal "the installer did not reach POWEROFF; the run did not complete"

step "boot and unlock"
python3 ./scripts/vm/boot.py || fatal "the installed system did not boot or did not unlock"

step "verify the storage layout"
./scripts/vm/verify.sh || fatal "storage verification failed"

step "verify the migration fixture"
# The manifest was recorded in the installer, before the migration. This compares the same
# measurements on the booted system, so a lost dotfile, a broken hardlink or a dropped
# xattr is a failure rather than something nobody looked at.
./scripts/vm/run-in-guest.sh bash /var/log/cdl/fixture-verify.sh || fatal "fixture verification failed"

step "workstation: install.sh on the booted machine"
# Every module, on real systemd. arm64, so GPU modules must SKIP (exit 2) and nothing else
# may fail. The run record is the arbiter, not the exit code alone.
./scripts/vm/install-in-guest.sh || fatal "install.sh failed in the guest"
python3 - "$VM_WORK/guest-logs/install-runs.jsonl" <<'PY' || fatal "run record has failures"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
last_run = rows[-1]["run"]
this = [r for r in rows if r["run"] == last_run]
bad = [r["module"] for r in this if r["result"] == "failed"]
skipped = [r["module"] for r in this if r["result"] == "skipped"]
print(f"  modules: {len(this)}  ok: {len(this)-len(bad)-len(skipped)}  skipped: {skipped}  failed: {bad}")
sys.exit(1 if bad else 0)
PY

step "workstation: every module's own verifier, inside the guest"
for v in tests/vm/verify-*.sh; do
    [ -e "$v" ] || continue
    printf '  %s\n' "$v"
    ./scripts/vm/run-in-guest.sh bash "/home/cdl/cdl-linux/$v" || fatal "$v failed"
done

step "workstation: a second run changes nothing"
# Idempotence is a claim every module makes; this is where it is checked. The second run's
# output may not contain any of the change markers lib.sh prints when a module acts.
second="$VM_WORK/guest-logs/second-run.txt"
./scripts/vm/install-in-guest.sh > "$second" 2>&1 || fatal "second install.sh run failed"
if grep -E '^\s+(installing:|fetched |created system user|backed up )' "$second"; then
    fatal "the second run changed something (see above)"
fi
echo "  second run: no changes"

step "backup round trip"
./scripts/vm/test-backup.sh || fatal "backup round trip failed"

step "second copy survives the threat it exists for"
# Needs the network and this machine's credentials, not the VM. It lives here rather than
# in run-all.sh because it takes a minute and talks to a real bucket.
./tests/net-second-copy.sh || fatal "second-copy test failed"

printf '\n\033[32mVM CYCLE PASSED\033[0m\n'
