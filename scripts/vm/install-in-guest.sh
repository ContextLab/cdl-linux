#!/usr/bin/env bash
# Run install.sh inside the booted VM, from a copy of this checkout, and bring the run
# record back. This is the integration test for the workstation build: every module runs
# on a real Ubuntu 26.04 with real systemd, real apt and real services -- on arm64, so the
# GPU modules skip and everything else must work.
#
# Usage: scripts/vm/install-in-guest.sh [install.sh args...]
#   e.g.  scripts/vm/install-in-guest.sh            full run
#         scripts/vm/install-in-guest.sh --module 50-console

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$HERE/lib.sh"

SSH=(ssh -i "$VM_KEY" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
GUEST=cdl@127.0.0.1
"${SSH[@]}" "$GUEST" true 2>/dev/null || die "VM not reachable on 2222; boot it first (scripts/vm/boot.py)"

log "syncing checkout into the guest"
rsync -az --delete -e "${SSH[*]}" \
    --exclude .git --exclude notes/hardware --exclude '*.qcow2' --exclude __pycache__ \
    "$REPO/" "$GUEST:/home/cdl/cdl-linux/" || die "rsync failed"

log "running install.sh ${*:-(all modules)}"
# The sudo password goes in on stdin (never argv: ps is world-readable in the guest).
# CDL_ALLOW_UNSUPPORTED_ARCH is the test-rig switch: arm64, so GPU modules skip.
"${SSH[@]}" "$GUEST" "sudo -S -p '' env CDL_ALLOW_UNSUPPORTED_ARCH=1 NO_COLOR=1 \
    bash -c 'cd /home/cdl/cdl-linux && ./install.sh $*'" <<<"$VM_PASSWORD"
rc=$?

mkdir -p "$VM_WORK/guest-logs"
"${SSH[@]}" "$GUEST" "sudo -S -p '' cat /var/log/cdl/install-runs.jsonl 2>/dev/null" <<<"$VM_PASSWORD" \
    > "$VM_WORK/guest-logs/install-runs.jsonl"
log "install.sh exit $rc; run record: $VM_WORK/guest-logs/install-runs.jsonl"
exit "$rc"
