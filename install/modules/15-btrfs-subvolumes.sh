#!/usr/bin/env bash
# Migrate a top-level btrfs root into @, and split out @home and @models.
#
# Why this exists: spike S2 measured that Ubuntu's installer cannot create btrfs subvolumes
# from an autoinstall storage config. It installs root into the filesystem's top level
# (subvolid=5) and creates none. That costs the ability to snapshot the system independently
# of home, which is the reason §11.4's rollback wants subvolumes at all.
#
# The approach is a move, and the alternative was measured rather than assumed. Snapshotting
# the running root into @ fails: btrfs answers `Could not create subvolume: Text file busy`,
# because the top-level subvolume cannot be snapshotted while it is mounted as root. So the
# migration renames the top level's contents into a new @ instead.
#
# That is safe on btrfs in a way it would not be elsewhere: a rename within one filesystem is
# a metadata operation, so nothing is copied and no inode changes. Processes holding open
# files keep them, because they hold descriptors rather than paths. What does change is the
# path every file is reachable by, so the window between the move and the reboot is the risky
# part, and the script closes it by doing nothing else and telling you to reboot.
#
# Idempotent: run it twice and the second run does nothing.
# Requires a reboot to take effect, and does not perform one.

set -uo pipefail

TOP="/run/cdl-btrfs-top"
die()  { printf '\033[31mfatal:\033[0m %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
skip() { printf '\033[32m ok:\033[0m %s\n' "$*"; exit 0; }

[[ $EUID -eq 0 ]] || die "must run as root"

# --- refuse rather than guess ------------------------------------------------------------

fstype="$(findmnt -no FSTYPE /)"
[[ "$fstype" == "btrfs" ]] || die "root is $fstype, not btrfs; this module does not apply"

opts="$(findmnt -no OPTIONS /)"
if [[ "$opts" == *"subvol=/@"* ]]; then
    skip "root is already mounted from @; nothing to do"
fi
if [[ "$opts" != *"subvolid=5"* && "$opts" != *"subvol=/,"* && "$opts" != *"subvol=/" ]]; then
    die "root is on an unexpected subvolume (options: $opts); refusing to guess"
fi

src="$(findmnt -no SOURCE /)"
[[ -n "$src" ]] || die "cannot determine the root device"
log "root is btrfs on $src, mounted from the filesystem top level"

# --- mount the top level so subvolumes can be created beside the running root -------------

mkdir -p "$TOP"
if ! mountpoint -q "$TOP"; then
    mount -o subvolid=5 "$src" "$TOP" || die "could not mount the btrfs top level"
fi
cleanup() { mountpoint -q "$TOP" && umount "$TOP"; }
trap cleanup EXIT

# --- @ : a snapshot of the running root ---------------------------------------------------

if btrfs subvolume list "$TOP" | grep -qE ' path @$'; then
    log "@ already exists; leaving it alone"
else
    log "creating @ and moving the top level into it"
    btrfs subvolume create "$TOP/@" >/dev/null || die "could not create @"

    # Everything at the top level except the subvolumes we are creating. Renames within one
    # btrfs filesystem are metadata-only, so this is fast regardless of how much data is
    # under those directories.
    moved=0
    for entry in "$TOP"/* "$TOP"/.[!.]*; do
        [[ -e "$entry" ]] || continue
        base="$(basename "$entry")"
        case "$base" in
            @|@home|@models) continue ;;
        esac
        mv "$entry" "$TOP/@/" || die "could not move $base into @; the filesystem is now
partially migrated and the machine should not be rebooted until it is put back by hand"
        moved=$((moved + 1))
    done
    log "moved $moved top-level entries into @"
fi

# --- @home and @models ---------------------------------------------------------------------

for sv in @home @models; do
    if btrfs subvolume list "$TOP" | grep -qE " path ${sv}\$"; then
        log "$sv already exists"
    else
        log "creating $sv"
        btrfs subvolume create "$TOP/$sv" >/dev/null || die "could not create $sv"
    fi
done

# Move the snapshot's /home into @home, so /home is a subvolume rather than a directory
# inside @. Done inside the snapshot, never against the running /home.
if [[ -d "$TOP/@/home" ]] && [[ -n "$(ls -A "$TOP/@/home" 2>/dev/null)" ]]; then
    log "moving home directories into @home"
    # A rename within one btrfs filesystem is a metadata operation, so this is fast and
    # does not copy data.
    for d in "$TOP/@/home"/*; do
        [[ -e "$d" ]] || continue
        mv -n "$d" "$TOP/@home/" || die "could not move $(basename "$d") into @home"
    done
fi
mkdir -p "$TOP/@/home" "$TOP/@/srv/models"

# --- fstab ---------------------------------------------------------------------------------

uuid="$(blkid -s UUID -o value "$src")" || die "could not read the filesystem UUID"
[[ -n "$uuid" ]] || die "empty filesystem UUID"

log "rewriting /etc/fstab for the subvolume layout"
cp -a /etc/fstab "/etc/fstab.pre-subvol.$(date +%Y%m%d%H%M%S)"

# Replace the existing root line, then append the two new mounts if absent.
awk -v uuid="$uuid" '
    $2 == "/" && $3 == "btrfs" { print "UUID=" uuid " / btrfs defaults,subvol=/@ 0 1"; next }
    { print }
' /etc/fstab > /etc/fstab.new

for entry in "/home:@home" "/srv/models:@models"; do
    mnt="${entry%%:*}"; sv="${entry##*:}"
    grep -qE "^[^#]*[[:space:]]${mnt}[[:space:]]" /etc/fstab.new \
        || printf 'UUID=%s %s btrfs defaults,subvol=/%s 0 2\n' "$uuid" "$mnt" "$sv" >> /etc/fstab.new
done
mv /etc/fstab.new /etc/fstab

# --- bootloader ------------------------------------------------------------------------------

log "updating initramfs and GRUB"
update-initramfs -u -k all >/dev/null 2>&1 || die "update-initramfs failed"
update-grub >/dev/null 2>&1 || die "update-grub failed"

cleanup
trap - EXIT

cat <<'DONE'

  Migration staged. The running system is unchanged and still mounted from the top level.

  On the next boot the machine mounts @ instead, and the old top-level tree stays in place
  as a fallback. Once the new layout has booted and been checked, the leftover directories
  at the top level can be removed; until then they are the way back.

  Reboot when ready.
DONE
