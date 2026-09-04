#!/usr/bin/env bash
# Migrate a freshly installed btrfs root into the @ / @home / @models subvolume layout.
#
# WHERE THIS RUNS: the installer environment, from autoinstall late-commands, with the
# installed system mounted at /target. It does NOT run on a live system, and refuses to.
# Both live approaches were measured and both fail -- see install/modules/15-btrfs-subvolumes.sh.
#
# WHY A SNAPSHOT AND NOT mv: a btrfs subvolume is a separate inode namespace, so rename(2)
# across one returns EXDEV and `mv` silently degrades to copy+unlink. That breaks hardlinks
# between moved files and rewrites every inode. `btrfs subvolume snapshot` is atomic, costs
# no space, and preserves hardlinks, ownership, modes, timestamps, xattrs and ACLs exactly.
# For the two directory-level moves that a snapshot cannot express, `cp -a --reflink=auto`
# is used, which preserves the same set (--preserve=all includes links).
#
# STAGES are recorded on the filesystem itself, so an interrupted run can be diagnosed and
# a completed one is recognised rather than repeated.

set -euo pipefail

# Trace every command, with the line number, into whatever is capturing stderr. This is an
# installer step that runs once, unattended, on a filesystem nobody can inspect afterwards
# if it goes wrong -- the run that motivated this failed with exit 1 and no way to ask which
# line produced it. Verbosity is the cheap half of a destructive procedure.
PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
set -x

TARGET="${TARGET:-/target}"
TOP="${TOP:-/tmp/cdl-top}"
STATE_NAME=".cdl-migration-state"
SUBVOLS=(@ @home @models)

log()  { printf '[migrate-btrfs-root] %s\n' "$*" >&2; }
die()  { printf '[migrate-btrfs-root] FATAL: %s\n' "$*" >&2; exit 1; }

stage() {
    log "stage: $1"
    [ -d "$TOP" ] && printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$TOP/$STATE_NAME" || true
}

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
    local rc=$?
    if mountpoint -q "$TOP" 2>/dev/null; then
        umount "$TOP" 2>/dev/null || true
    fi
    [ -d "$TOP" ] && rmdir "$TOP" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        log "FAILED (exit $rc). The filesystem state is recorded in the top-level subvolume:"
        log "  mount -o subvolid=5 <device> /mnt && cat /mnt/$STATE_NAME"
    fi
    return "$rc"
}
trap cleanup EXIT

# ---------------------------------------------------------------- stage: precheck

[ "$(id -u)" -eq 0 ] || die "must run as root"


mountpoint -q "$TARGET" || die "$TARGET is not a mountpoint"

# ORDER MATTERS HERE. "Already migrated" is checked BEFORE the live-system refusal, because
# it is safe wherever it is true: if root is already on @ there is nothing to do and
# nothing to damage, so exit 0 regardless of what kind of machine this is. Checking the
# refusal first made a re-run against an already-migrated filesystem die instead of
# succeeding, which is the case late-commands hit when they run twice.
cur_opts="$(findmnt -no OPTIONS "$TARGET")"
case "$cur_opts" in
    *subvol=/@,*|*subvol=/@|*subvol=@,*|*subvol=@)
        log "already mounted from @; nothing to do"
        exit 0
        ;;
esac

# Now refuse to run against a live system. /target is the installer's mountpoint; if the
# thing we are about to rearrange is also our own root, we are not in an installer.
if [ "$(findmnt -no SOURCE / 2>/dev/null || true)" = "$(findmnt -no SOURCE "$TARGET" 2>/dev/null || true)" ]; then
    die "$TARGET and / are the same filesystem -- this is not an installer environment"
fi

root_dev="$(findmnt -no SOURCE "$TARGET")"
root_dev="${root_dev%%\[*}"          # strip any [/subvol] suffix
[ -b "$root_dev" ] || die "cannot resolve $TARGET to a block device (got '$root_dev')"

[ "$(findmnt -no FSTYPE "$TARGET")" = btrfs ] || die "$TARGET is not btrfs"

uuid="$(blkid -s UUID -o value "$root_dev")" || die "no UUID for $root_dev"
[ -n "$uuid" ] || die "empty UUID for $root_dev"

# Filesystem health and space. The snapshot itself is free, but the two cp -a moves are not
# bounded by it, so refuse to start without room to fail safely.
btrfs filesystem show "$root_dev" >/dev/null 2>&1 || die "btrfs does not recognise $root_dev"
avail_kb="$(df -Pk "$TARGET" | awk 'NR==2 {print $4}')"
[ "${avail_kb:-0}" -ge 262144 ] || die "less than 256 MiB free on $TARGET; refusing"

log "device=$root_dev uuid=$uuid free=${avail_kb}K"

# ---------------------------------------------------------------- stage: detach

# Deepest first. /target/boot/efi before /target/boot before /target.
for m in "$TARGET/boot/efi" "$TARGET/boot" "$TARGET"; do
    if mountpoint -q "$m"; then
        umount -R "$m" || die "cannot unmount $m"
    fi
done

mkdir -p "$TOP"
mount -o subvolid=5 "$root_dev" "$TOP" || die "cannot mount top-level subvolume"
stage precheck-ok

# A previous run may have left subvolumes behind. Recognise that rather than failing on
# "already exists" halfway through.
partial=0
for s in "${SUBVOLS[@]}"; do
    [ -e "$TOP/$s" ] && partial=1
done
if [ "$partial" -eq 1 ]; then
    if [ -e "$TOP/@/etc/fstab" ]; then
        die "a previous migration left @ populated but $TARGET was not mounted from it.
  This is a partially completed migration and it is not safe to guess.
  Inspect:  mount -o subvolid=5 $root_dev /mnt; cat /mnt/$STATE_NAME
  Recover:  boot the installer, mount subvolid=5, and either finish the move by hand or
            delete @ @home @models and re-run the installation from clean disks."
    fi
    log "found empty leftover subvolumes from an interrupted run; removing them"
    for s in "${SUBVOLS[@]}"; do
        [ -e "$TOP/$s" ] && btrfs subvolume delete "$TOP/$s"
    done
fi

# ---------------------------------------------------------------- stage: subvolumes

# @ is a SNAPSHOT of the top level: atomic, no copying, everything preserved exactly.
btrfs subvolume snapshot "$TOP" "$TOP/@" >/dev/null || die "cannot snapshot top level into @"
btrfs subvolume create "$TOP/@home"   >/dev/null || die "cannot create @home"
btrfs subvolume create "$TOP/@models" >/dev/null || die "cannot create @models"
stage subvolumes-created

# ---------------------------------------------------------------- stage: split home

# Everything in @/home moves into @home, including entries whose names begin with a dot and
# entries whose names begin with two dots. `cp -a` preserves hardlinks, ACLs and xattrs;
# --reflink=auto makes it a CoW clone on btrfs, so it costs no space and no time.
if [ -d "$TOP/@/home" ]; then
    cp -a --reflink=auto "$TOP/@/home/." "$TOP/@home/" || die "cannot copy /home into @home"
    find "$TOP/@/home" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || die "cannot clear @/home"
fi
mkdir -p "$TOP/@/home"
stage home-split

# ---------------------------------------------------------------- stage: split models

# /srv/models may not exist on a fresh install, but if it has contents they move rather than
# being shadowed by an empty mount.
if [ -d "$TOP/@/srv/models" ]; then
    cp -a --reflink=auto "$TOP/@/srv/models/." "$TOP/@models/" || die "cannot copy /srv/models"
    find "$TOP/@/srv/models" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || die "cannot clear models"
fi
mkdir -p "$TOP/@/srv/models"
stage models-split

# ---------------------------------------------------------------- stage: clear top level

# The originals are still at the top level; @ holds the snapshot. Remove them, keeping only
# the three subvolumes and the state file. find, not a glob: this must not depend on shell
# expansion rules for dotfiles.
find "$TOP" -mindepth 1 -maxdepth 1 \
    ! -name '@' ! -name '@home' ! -name '@models' ! -name "$STATE_NAME" \
    -exec rm -rf -- {} + || die "cannot clear the top-level subvolume"
stage toplevel-cleared

# ---------------------------------------------------------------- stage: fstab

fstab="$TOP/@/etc/fstab"
[ -f "$fstab" ] || die "no /etc/fstab in @ -- the snapshot did not contain the installed system"

# `$1 !~ /^#/` on every rule. Ubuntu's installer writes comment lines of the form
# "# / was on /dev/vda3 during installation", in which $1 is "#" and $2 is "/", so a rule
# keyed on $2 alone matches comments as readily as mounts. That is exactly how the /boot
# remount below came to run `mount '#' /target/boot`.
awk -v u="$uuid" '
    $1 ~ /^#/ { print; next }
    $2=="/"           && $3=="btrfs" { next }
    $2=="/home"       && $3=="btrfs" { next }
    $2=="/srv/models" && $3=="btrfs" { next }
    { print }
    END {
        print "UUID=" u " /           btrfs defaults,subvol=/@       0 1"
        print "UUID=" u " /home       btrfs defaults,subvol=/@home   0 2"
        print "UUID=" u " /srv/models btrfs defaults,subvol=/@models 0 2"
    }
' "$fstab" > "$fstab.cdl-new" || die "cannot rewrite fstab"
mv "$fstab.cdl-new" "$fstab"
stage fstab-rewritten

umount "$TOP"

# ---------------------------------------------------------------- stage: remount

mount -o subvol=/@ "$root_dev" "$TARGET" || die "cannot mount @ at $TARGET"
mkdir -p "$TARGET/home" "$TARGET/srv/models"
mount -o subvol=/@home   "$root_dev" "$TARGET/home"       || die "cannot mount @home"
mount -o subvol=/@models "$root_dev" "$TARGET/srv/models" || die "cannot mount @models"

# /boot and /boot/efi come back from the fstab we just wrote.
while read -r dev mnt; do
    [ -n "$dev" ] || continue
    mkdir -p "$TARGET$mnt"
    case "$dev" in
        UUID=*) dev="/dev/disk/by-uuid/${dev#UUID=}" ;;
    esac
    # A parse that goes wrong should say so here rather than at mount(8), whose message
    # ("special device # does not exist") describes the symptom and not the cause.
    [ -b "$dev" ] || die "fstab parse produced '$dev' for $mnt, which is not a block device"
    mount "$dev" "$TARGET$mnt" || die "cannot mount $dev at $TARGET$mnt"
done < <(awk '$1 !~ /^#/ && ($2=="/boot" || $2=="/boot/efi") {print $1, $2}' \
             "$TARGET/etc/fstab" | sort -k2,2)

# ---------------------------------------------------------------- stage: validate

# Nothing below this point may run if any of these is false: update-grub and
# update-initramfs against a half-migrated tree produce a system that does not boot.
fail=0
ok()   { log "  ok    $1"; }
bad()  { log "  FAIL  $1"; fail=1; }

if [ "$(findmnt -no OPTIONS "$TARGET" | tr ',' '\n' | grep -c '^subvol=/@$')" -eq 1 ]
    then ok "root mounted from @"; else bad "root mounted from @"; fi

if findmnt -no OPTIONS "$TARGET/home" | grep -q 'subvol=/@home'
    then ok "/home mounted from @home"; else bad "/home mounted from @home"; fi

if findmnt -no OPTIONS "$TARGET/srv/models" | grep -q 'subvol=/@models'
    then ok "/srv/models mounted from @models"; else bad "/srv/models mounted from @models"; fi

if [ "$(btrfs subvolume list "$TARGET" | grep -cE ' path (@|@home|@models)$')" -eq 3 ]
    then ok "all three subvolumes exist"; else bad "all three subvolumes exist"; fi

if [ -s "$TARGET/etc/fstab" ]
    then ok "system moved: /etc/fstab present"; else bad "system moved: /etc/fstab present"; fi

if [ -d "$TARGET/usr/bin" ]
    then ok "system moved: /usr/bin present"; else bad "system moved: /usr/bin present"; fi

if [ -n "$(ls -A "$TARGET/boot" 2>/dev/null)" ]
    then ok "system moved: /boot populated"; else bad "system moved: /boot populated"; fi

if [ "$(grep -c 'subvol=/@' "$TARGET/etc/fstab")" -eq 3 ]
    then ok "fstab names all three subvolumes"; else bad "fstab names all three subvolumes"; fi

[ "$fail" -eq 0 ] || die "post-migration validation failed; NOT rebuilding the bootloader"
stage validated

# ---------------------------------------------------------------- stage: bootloader

# An explicitly constructed chroot, not `curtin in-target`. /target was unmounted and
# remounted above, so curtin's record of what is mounted is stale and its in-target call
# fails with exit 2. Every subsequent target operation in this installation uses this same
# helper, so there is one answer to "how do we run something in the target".
for v in proc sys dev dev/pts run; do
    mkdir -p "$TARGET/$v"
    mount --rbind "/$v" "$TARGET/$v" 2>/dev/null || mount --bind "/$v" "$TARGET/$v" || die "cannot bind /$v"
done

chroot "$TARGET" update-grub                 || die "update-grub failed"
chroot "$TARGET" update-initramfs -u -k all  || die "update-initramfs failed"

for v in run dev/pts dev sys proc; do
    umount -R "$TARGET/$v" 2>/dev/null || true
done
stage bootloader-rebuilt

# ---------------------------------------------------------------- evidence

mkdir -p "$TARGET/var/log/cdl"
{
    echo "migrated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "device   $root_dev"
    echo "uuid     $uuid"
    echo
    echo "== subvolumes =="
    btrfs subvolume list "$TARGET"
    echo
    echo "== fstab =="
    cat "$TARGET/etc/fstab"
    echo
    echo "== mounts =="
    findmnt -R "$TARGET" -o TARGET,SOURCE,FSTYPE,OPTIONS
} > "$TARGET/var/log/cdl/migration.txt" 2>&1

log "migration complete"
exit 0
