#!/usr/bin/env bash
# Tests that write to real hardware. Never run by run-all.sh, never run by run-vm.sh, and
# refused unless the caller says out loud which machine they mean.
#
# Usage: tests/run-destructive.sh --i-understand-this-erases /dev/nvmeXn1 [...]
#
# There is exactly one of these so far. The point of the file existing now is that a
# destructive test has somewhere to go that is not the suite everyone runs by reflex.

set -uo pipefail

if [ "${1:-}" != "--i-understand-this-erases" ]; then
    cat >&2 <<'MSG'
This suite erases the drives it is pointed at.

  tests/run-destructive.sh --i-understand-this-erases /dev/nvme0n1 /dev/nvme1n1

Before running it on the Tensorbook, spec §10 requires a restore-tested backup AND a
second copy the machine holds no credential for. RAID0 has no redundancy: a mistake here
is not recoverable from the array.
MSG
    exit 1
fi
shift

[ $# -gt 0 ] || { echo "name the devices" >&2; exit 1; }
for d in "$@"; do
    [ -b "$d" ] || { echo "not a block device: $d" >&2; exit 1; }
done

echo "no destructive tests are implemented yet; refusing to guess what to do with: $*" >&2
exit 1
