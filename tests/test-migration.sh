#!/usr/bin/env bash
# The parts of the btrfs migration that can be checked without a Linux machine: its fstab
# parsing, and the invariants that must hold before it touches a bootloader.
#
# The full migration is exercised by tests/run-vm.sh. This suite exists because one of its
# defects was pure text processing and cost a 25-minute VM cycle to find.

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$repo/install/installer/migrate-btrfs-root.sh"
pass=0; fail=0
ok()  { printf '  \033[32mOK\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# A real curtin-written fstab. The comment lines are the point: curtin writes
# "# /boot was on /dev/vda2 during curtin installation", where $1 is "#" and $2 is "/boot",
# so any rule keyed on $2 alone matches a comment as readily as a mount. That produced
# `mount '#' /target/boot` and killed an installation.
cat > "$work/fstab" <<'FSTAB'
# /etc/fstab: static file system information.
# / was on /dev/vda3 during curtin installation
/dev/mapper/cryptroot / btrfs defaults 0 1
# /boot was on /dev/vda2 during curtin installation
UUID=aaaa-bbbb /boot ext4 defaults 0 1
# /boot/efi was on /dev/vda1 during curtin installation
UUID=CCCC-DDDD /boot/efi vfat defaults 0 1
FSTAB

# --- the /boot remount parse ---
got="$(awk '$1 !~ /^#/ && ($2=="/boot" || $2=="/boot/efi") {print $1}' "$work/fstab")"
want="$(printf 'UUID=aaaa-bbbb\nUUID=CCCC-DDDD')"
if [ "$got" = "$want" ]; then ok "the /boot parse skips comment lines"
else bad "the /boot parse returned: $(tr '\n' ' ' <<<"$got")"; fi

if grep -q "awk '\$1 !~ /\^#/ && (\$2==\"/boot\"" "$S"; then
    ok "the script's own /boot parse carries the comment guard"
else bad "the script's /boot parse has no comment guard"; fi

# --- the fstab rewrite preserves comments and replaces only real mounts ---
uuid="890d67aa-4a4b-4a4b-bafe-96c157066345"
out="$(awk -v u="$uuid" '
    $1 ~ /^#/ { print; next }
    $2=="/"           && $3=="btrfs" { next }
    $2=="/home"       && $3=="btrfs" { next }
    $2=="/srv/models" && $3=="btrfs" { next }
    { print }
    END {
        print "UUID=" u " /           btrfs defaults,subvol=/@       0 1"
        print "UUID=" u " /home       btrfs defaults,subvol=/@home   0 2"
        print "UUID=" u " /srv/models btrfs defaults,subvol=/@models 0 2"
    }' "$work/fstab")"

n_comments_in="$(grep -c '^#' "$work/fstab")"
if [ "$(grep -c '^#' <<<"$out")" -eq "$n_comments_in" ]
    then ok "the rewrite keeps every comment line ($n_comments_in)"
    else bad "comments lost: $(grep -c '^#' <<<"$out") of $n_comments_in"; fi

if [ "$(grep -c 'subvol=/@' <<<"$out")" -eq 3 ]
    then ok "the rewrite adds exactly three subvolume mounts"
    else bad "wrong subvol count: $(grep -c 'subvol=/@' <<<"$out")"; fi

if grep -q '^/dev/mapper/cryptroot / btrfs' <<<"$out"
    then bad "the old btrfs root line survived the rewrite"
    else ok "the old btrfs root line is replaced, not duplicated"; fi

if grep -q '^UUID=aaaa-bbbb /boot ext4' <<<"$out"
    then ok "the /boot line is left alone"
    else bad "the /boot line was altered"; fi

# --- invariants that must be in the script, because getting them wrong is unrecoverable ---
# shellcheck disable=SC2016  # these are literal needles to grep for, not expansions
declare -a musts=(
  'refuses when /target is the live root:this is not an installer environment'
  'validates before rebuilding the bootloader:NOT rebuilding the bootloader'
  'rejects a non-block device from the fstab parse:is not a block device'
  'creates @ by snapshot, not by moving files:btrfs subvolume snapshot'
  'uses cp -a --reflink for the splits:cp -a --reflink=auto'
  'traverses with find, not a shell glob:-mindepth 1 -maxdepth 1'
  'has an EXIT trap:trap cleanup EXIT'
  'records stages on the filesystem:STATE_NAME'
  # Partial and broken states. These were exercised against a live machine on 2026-09-04
  # and each behaved correctly, but a manual run is not a test: it does not survive an edit.
  'recognises a partially completed migration:partially completed migration'
  'names the state file when refusing:cat /mnt/$STATE_NAME'
  'offers two recovery routes, not a dead end:delete @ @home @models and re-run'
  'clears empty leftovers rather than failing:empty leftover subvolumes'
  'exits 0 when already migrated (re-run):already mounted from @'
  'checks the filesystem before starting:btrfs filesystem show'
  'checks free space before starting:refusing'
  'does not stack a bind over an existing mount:mountpoint -q "$TARGET/$v" && continue'
  'unmounts until actually free, not once:still mounted after'
)
for entry in "${musts[@]}"; do
    desc="${entry%%:*}"; needle="${entry#*:}"
    if grep -qF -- "$needle" "$S"; then ok "$desc"; else bad "$desc (no match for: $needle)"; fi
done

# The bootloader rebuild must come after the validation gate, not before it.
v_line=$(grep -n 'NOT rebuilding the bootloader' "$S" | cut -d: -f1)
g_line=$(grep -n 'update-grub' "$S" | grep chroot | cut -d: -f1 | head -1)
if [ -n "$v_line" ] && [ -n "$g_line" ] && [ "$v_line" -lt "$g_line" ]; then
    ok "the validation gate precedes update-grub"
else bad "update-grub is not gated by the validation (gate:$v_line grub:$g_line)"; fi

# "Already migrated" must be checked BEFORE the live-system refusal. When it was the other
# way round, a re-run against an already-migrated filesystem died instead of exiting 0 --
# which is exactly the case late-commands hit when they run twice, and one of V4's exit
# criteria. Ordering, not presence, was the defect, so presence alone cannot guard it.
already_line=$(grep -n 'already mounted from @' "$S" | cut -d: -f1 | head -1)
live_line=$(grep -n 'this is not an installer environment' "$S" | cut -d: -f1 | head -1)
if [ -n "$already_line" ] && [ -n "$live_line" ] && [ "$already_line" -lt "$live_line" ]; then
    ok "the already-migrated check precedes the live-system refusal"
else
    bad "check order wrong (already:$already_line live:$live_line); a re-run would die"
fi

printf '\n  test-migration: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
