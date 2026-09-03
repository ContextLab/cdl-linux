#!/usr/bin/env bash
# Acceptance checks against a booted cdl-box VM. Run after scripts/vm/boot.py reports SSH.
#
# Every check asserts something the spec claims, and each names the section it is checking,
# so a failure says which claim is wrong rather than only that something is.

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

require ssh sshpass || warn "sshpass missing; will prompt for the VM password"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -p "$SSH_PORT")

# Commands are assembled as strings and evaluated on the VM, which is the point: these are
# assertions about the guest, not the host.
# shellcheck disable=SC2029
sshv() {
    if command -v sshpass >/dev/null; then
        sshpass -p "$VM_PASSWORD" ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "$@"
    else
        ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "$@"
    fi
}

pass=0; fail=0
check() {
    local what="$1" sect="$2" expect="$3"; shift 3
    local got
    got="$(sshv "$@" 2>/dev/null)"
    if [[ "$got" =~ $expect ]]; then
        printf '  \033[32mPASS\033[0m  %-46s (%s)\n' "$what" "$sect"; pass=$((pass+1))
    else
        printf '  \033[31mFAIL\033[0m  %-46s (%s)\n' "$what" "$sect"
        printf '        expected to match: %s\n        got: %s\n' "$expect" "${got:-<empty>}"
        fail=$((fail+1))
    fi
}

log "checking the VM over ssh on port $SSH_PORT"
sshv true 2>/dev/null || die "cannot reach the VM; is it booted?"

printf '\n\033[1m-- storage layout (§2.1) --\033[0m\n'
check "md0 exists and is raid0"        "§2.1" "raid0"        "cat /proc/mdstat"
check "md0 has two members"            "§2.1" "vd[ab][0-9].*vd[ab][0-9]" "cat /proc/mdstat"
check "LUKS is open on md0"            "§2.1" "cryptroot"    "ls /dev/mapper/"
check "the LUKS backing device is md0" "§2.1" "md0"          "sudo cryptsetup status cryptroot | grep device:"
check "root is btrfs"                  "§2.1" "btrfs"        "findmnt -no FSTYPE /"
check "root sits on the mapped device" "§2.1" "cryptroot"    "findmnt -no SOURCE /"
check "/boot is outside the encryption" "§2.1" "ext4"        "findmnt -no FSTYPE /boot"
check "crypttab references md0"        "§2.1" "."            "grep -c . /etc/crypttab"

printf '\n\033[1m-- boot survivability (§12 B1) --\033[0m\n'
check "initramfs carries cryptsetup"   "§12"  "[1-9]"        "lsinitramfs /boot/initrd.img-\$(uname -r) 2>/dev/null | grep -c cryptsetup"
check "initramfs carries md support"   "§12"  "[1-9]"        "lsinitramfs /boot/initrd.img-\$(uname -r) 2>/dev/null | grep -c 'md[a-z]*\\.ko\\|mdadm'"
check "this boot came off the array"   "§12"  "cryptroot"    "findmnt -no SOURCE /"

printf '\n\033[1m-- backup path (§10) --\033[0m\n'
check "restic present"                 "§10"  "restic"       "restic version"
check "rclone present"                 "§10.5" "rclone"      "rclone version | head -1"

printf '\n\033[1m-- headless posture (§1.1) --\033[0m\n'
check "no display server installed"    "§1.1" "^0$"          "dpkg -l 2>/dev/null | grep -cE '^ii +(xserver-xorg|gnome-shell|sway) ' || echo 0"
check "sshd is running"                "§7"   "active"       "systemctl is-active ssh"

printf '\n\033[1m== %d passed, %d failed ==\033[0m\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
