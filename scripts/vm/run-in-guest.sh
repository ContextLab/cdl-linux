#!/usr/bin/env bash
# Run a command inside the booted VM over SSH, as root, without putting anything sensitive
# on a command line that shows up in the guest's process list.
#
# Usage: scripts/vm/run-in-guest.sh <command> [args...]

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$HERE/lib.sh"

[ $# -gt 0 ] || { echo "usage: $0 <command> [args...]" >&2; exit 1; }

# The sudo password goes in on stdin, never in the command. Anything the guest needs as an
# environment variable is passed the same way, for the same reason: `ps` is world-readable.
ssh -i "$VM_KEY" -p 2222 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    cdl@127.0.0.1 "sudo -S -p '' $*" <<< "$VM_PASSWORD"
