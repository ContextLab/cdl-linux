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

step "backup round trip"
./scripts/vm/test-backup.sh || fatal "backup round trip failed"

printf '\n\033[32mVM CYCLE PASSED\033[0m\n'
