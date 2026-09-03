#!/usr/bin/env bash
# Shared configuration for the cdl-box VM harness.
#
# The harness exists so the storage layout, the provisioning script and the backup path can
# be tested without the Tensorbook. See scripts/vm/README.md for what it does and does not
# reproduce -- the gap matters and is not small.

# Everything defined here is consumed by the scripts that source this file.
# shellcheck disable=SC2034

set -uo pipefail

# Where large artifacts live. Never inside the repository: the ISO alone is 3 GB.
VM_WORK="${VM_WORK:-${TMPDIR:-/tmp}/cdl-vm}"

UBUNTU_RELEASE="26.04.1"
UBUNTU_ARCH="arm64"                      # host arch; see README on the amd64 gap
ISO_NAME="ubuntu-${UBUNTU_RELEASE}-live-server-${UBUNTU_ARCH}.iso"
ISO_URL="https://cdimage.ubuntu.com/releases/${UBUNTU_RELEASE}/release/${ISO_NAME}"
ISO_SHA256="af78753c94b924c85c4964c670692a853f7c80299a4064e317edad95462e3168"

# Two disks, because the whole point is testing a striped pair.
DISK0="${VM_WORK}/disk0.qcow2"
DISK1="${VM_WORK}/disk1.qcow2"
DISK_SIZE="24G"

VM_MEM="4096"
VM_CPUS="4"
SSH_PORT="2222"

# Test-only. The real machine's passphrase is typed by a human and lives nowhere.
LUKS_PASSPHRASE="cdl-vm-test-passphrase"
VM_USER="cdl"
VM_PASSWORD="cdl-vm-test"          # console/sudo only; SSH is key-only (§7)
VM_KEY="${VM_WORK}/id_cdlvm"       # generated per checkout, never committed

case "$(uname -m)" in
    arm64|aarch64) QEMU="qemu-system-aarch64"; QEMU_MACHINE="virt,accel=hvf,gic-version=3"; QEMU_CPU="host" ;;
    x86_64)        QEMU="qemu-system-x86_64";  QEMU_MACHINE="q35,accel=hvf";                QEMU_CPU="host" ;;
    *)             echo "unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
esac

# UEFI firmware. Homebrew's qemu ships edk2 images; the path moved between versions, so
# look rather than assume.
find_edk2() {
    local name="$1" p
    for p in \
        "$(brew --prefix qemu 2>/dev/null)/share/qemu/${name}" \
        "/opt/homebrew/share/qemu/${name}" \
        "/usr/local/share/qemu/${name}"
    do
        [[ -f "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

require() {
    local missing=0 c
    for c in "$@"; do
        command -v "$c" >/dev/null || { echo "missing required command: $c" >&2; missing=1; }
    done
    [[ $missing -eq 0 ]]
}

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mfatal:\033[0m %s\n' "$*" >&2; exit 1; }
