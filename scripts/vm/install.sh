#!/usr/bin/env bash
# Install cdl-box into a fresh VM, unattended, from scripts/vm/autoinstall/user-data.
#
# Running this twice from a clean state and getting the same machine both times is the
# reproducibility claim spec §12 (S2) asks for. Nothing here is interactive.

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$HERE/lib.sh"

require qemu-img "$QEMU" hdiutil curl shasum tar || die "install the missing tools first"

mkdir -p "$VM_WORK"
ISO="$VM_WORK/$ISO_NAME"

# --- 1. the installer image -------------------------------------------------------------

if [[ ! -f "$ISO" ]]; then
    log "downloading $ISO_NAME (about 3 GB)"
    curl -fL --progress-bar -o "$ISO" "$ISO_URL" || die "download failed"
fi

log "verifying ISO checksum"
actual="$(shasum -a 256 "$ISO" | awk '{print $1}')"
[[ "$actual" == "$ISO_SHA256" ]] || die "checksum mismatch: got $actual, expected $ISO_SHA256"

# --- 2. the cloud-init seed -------------------------------------------------------------
# Subiquity reads its autoinstall config from a volume labelled cidata. The label is what
# cloud-init looks for, so it is not cosmetic.

# The harness authenticates with a key, not a password: it is what §7 of the spec requires,
# and an earlier version of this harness enabled SSH password auth for the guest, which the
# audit flagged. The key is generated per checkout and never committed.
if [[ ! -f "$VM_KEY" ]]; then
    log "generating a harness ssh key"
    ssh-keygen -t ed25519 -N '' -C 'cdl-vm-harness' -f "$VM_KEY" >/dev/null || die "ssh-keygen failed"
fi

# Validate the autoinstall before spending twenty minutes discovering it is wrong. An edit
# to the identity block once deleted the entire storage section, and the installer silently
# fell back to its default guided LVM layout: no md, no LUKS, ext4 root. Nothing failed, and
# only the verifier noticed. Required keys are cheap to assert and this is where to do it.
log "validating the autoinstall config"
python3 "$REPO/scripts/validate-autoinstall.py" "$HERE/autoinstall/user-data" \
    || die "autoinstall config is not valid"

log "building the cloud-init seed"
seed_dir="$VM_WORK/seed"
rm -rf "$seed_dir" && mkdir -p "$seed_dir"
# Substitute this checkout's public key into the seed. The committed file carries a
# placeholder so that a clone does not inherit somebody else's key.
pubkey="$(cat "${VM_KEY}.pub")"

# The installer-side scripts are carried into the seed as base64. They live in the
# repository as ordinary executable files -- shellcheck'd and runnable -- rather than as
# text inside YAML, and base64 means no indentation rule can corrupt them in transit.
b64() { base64 < "$1" | tr -d '\n'; }
migrate_b64="$(b64 "$REPO/install/installer/migrate-btrfs-root.sh")"
fixture_b64="$(b64 "$HERE/fixture/create.sh")"
verify_b64="$(b64 "$HERE/fixture/verify.sh")"

sed -e "s|@@CDL_VM_PUBKEY@@|${pubkey}|" \
    -e "s|@@CDL_B64_MIGRATE@@|${migrate_b64}|" \
    -e "s|@@CDL_B64_FIXTURE@@|${fixture_b64}|" \
    -e "s|@@CDL_B64_VERIFY@@|${verify_b64}|" \
    "$HERE/autoinstall/user-data" > "$seed_dir/user-data"

for ph in CDL_VM_PUBKEY CDL_B64_MIGRATE CDL_B64_FIXTURE CDL_B64_VERIFY; do
    grep -q "@@${ph}@@" "$seed_dir/user-data" && die "substitution failed for ${ph}"
done

# Validate the SUBSTITUTED seed too. The template validates with placeholders in place;
# this checks what the installer will actually read.
python3 "$REPO/scripts/validate-autoinstall.py" "$seed_dir/user-data" \
    || die "substituted seed is not valid"
printf 'instance-id: cdl-box-vm\nlocal-hostname: cdl-box-vm\n' > "$seed_dir/meta-data"
rm -f "$VM_WORK/seed.iso"
hdiutil makehybrid -quiet -iso -joliet -default-volume-name CIDATA \
    -o "$VM_WORK/seed.iso" "$seed_dir" || die "could not build seed ISO"

# --- 3. kernel and initrd ---------------------------------------------------------------
# The `autoinstall` kernel argument is what stops subiquity pausing for confirmation, and
# a kernel argument means booting the ISO's kernel directly rather than via its bootloader.
#
# It is `autoinstall` ALONE, with no `ds=` override. An earlier version passed
# `ds=nocloud-net;s=/cdrom/`, which points cloud-init at the install ISO -- a disc that
# contains no user-data -- and so prevented it from discovering the CIDATA-labelled seed
# volume that does. The installer then came up interactive and sat at a prompt. Letting
# NoCloud find the seed by its volume label is both simpler and the thing that works.

if [[ ! -f "$VM_WORK/vmlinuz" || ! -f "$VM_WORK/initrd" ]]; then
    log "extracting kernel and initrd from the ISO"
    # bsdtar reads ISO9660 directly, which matters because macOS cannot mount an Ubuntu
    # hybrid ISO at all: hdiutil reports "no mountable file systems". Extracting rather
    # than mounting also removes the detach-on-failure path entirely.
    ( cd "$VM_WORK" && tar -xf "$ISO" casper/vmlinuz casper/initrd ) \
        || die "could not extract casper/vmlinuz and casper/initrd from the ISO"
    mv "$VM_WORK/casper/vmlinuz" "$VM_WORK/vmlinuz"
    mv "$VM_WORK/casper/initrd"  "$VM_WORK/initrd"
    rmdir "$VM_WORK/casper" 2>/dev/null || true
fi

# --- 4. blank disks ---------------------------------------------------------------------

log "creating two blank ${DISK_SIZE} disks"
rm -f "$DISK0" "$DISK1"
qemu-img create -f qcow2 "$DISK0" "$DISK_SIZE" >/dev/null || die "qemu-img failed"
qemu-img create -f qcow2 "$DISK1" "$DISK_SIZE" >/dev/null || die "qemu-img failed"

# --- 5. UEFI firmware -------------------------------------------------------------------

if [[ "$QEMU" == "qemu-system-aarch64" ]]; then
    code="$(find_edk2 edk2-aarch64-code.fd)" || die "edk2-aarch64-code.fd not found"
    vars="$VM_WORK/efi-vars.fd"
    # aarch64 pflash images must be exactly 64 MiB.
    [[ -f "$vars" ]] || { dd if=/dev/zero of="$vars" bs=1m count=64 2>/dev/null; }
    FIRMWARE=(-drive "if=pflash,format=raw,readonly=on,file=$code"
              -drive "if=pflash,format=raw,file=$vars")
else
    code="$(find_edk2 edk2-x86_64-code.fd)" || die "edk2-x86_64-code.fd not found"
    FIRMWARE=(-drive "if=pflash,format=raw,readonly=on,file=$code")
fi

# --- 6. run the installer ---------------------------------------------------------------

log "installing (unattended; this takes a while and prints the installer's console)"
"$QEMU" \
    -machine "$QEMU_MACHINE" -cpu "$QEMU_CPU" -smp "$VM_CPUS" -m "$VM_MEM" \
    "${FIRMWARE[@]}" \
    -kernel "$VM_WORK/vmlinuz" -initrd "$VM_WORK/initrd" \
    -append "console=ttyAMA0 autoinstall ---" \
    -drive "if=none,id=hd0,format=qcow2,file=$DISK0" -device virtio-blk-pci,drive=hd0,serial=cdl0 \
    -drive "if=none,id=hd1,format=qcow2,file=$DISK1" -device virtio-blk-pci,drive=hd1,serial=cdl1 \
    -drive "if=none,id=cd0,format=raw,media=cdrom,readonly=on,file=$ISO" -device virtio-blk-pci,drive=cd0 \
    -drive "if=none,id=cd1,format=raw,media=cdrom,readonly=on,file=$VM_WORK/seed.iso" -device virtio-blk-pci,drive=cd1 \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" -device virtio-net-pci,netdev=net0 \
    -nographic

rc=$?
log "installer exited with status $rc"
log "disks are at $DISK0 and $DISK1; boot with scripts/vm/boot.sh"
exit $rc
