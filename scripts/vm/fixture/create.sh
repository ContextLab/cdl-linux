#!/usr/bin/env bash
# Create the migration fixture in the installed target, BEFORE the subvolume migration runs,
# and record a manifest of every property the migration must preserve.
#
# The manifest is the point. Writing expectations here and again in the verifier would let
# the two drift and would let a wrong expectation be "verified"; instead this records what
# is actually on disk beforehand, and verify.sh diffs the same measurement afterwards.

set -euo pipefail
TARGET="${TARGET:-/target}"
H="$TARGET/home"
M="$TARGET/srv/models"

mkdir -p "$H/cdl/.ssh" "$H/cdl/.config/tool" "$H/cdl/empty-dir" "$M"

# Hidden state that a naive `mv dir/*` would leave behind.
printf 'ssh-ed25519 AAAAFIXTUREKEY fixture@cdl\n' > "$H/cdl/.ssh/authorized_keys"
chmod 600 "$H/cdl/.ssh/authorized_keys"; chmod 700 "$H/cdl/.ssh"
printf 'export CDL_FIXTURE=1\n'   > "$H/cdl/.profile"
printf 'fixture-bashrc\n'         > "$H/cdl/.bashrc"
printf '[tool]\nkey = value\n'    > "$H/cdl/.config/tool/config"

# A hidden entry directly in /home -- the case the old glob-based migration actually missed.
printf 'hidden-at-home-root\n' > "$H/.hidden-at-home-root"
mkdir -p "$H/.hidden-dir-at-home-root"
printf 'nested\n' > "$H/.hidden-dir-at-home-root/file"

# Ordinary content, awkward names, links.
printf 'visible\n'                     > "$H/cdl/visible.txt"
printf 'spaces and unicode\n'          > "$H/cdl/a file with spaces & ünicode.txt"
printf 'dotdot-prefixed\n'             > "$H/cdl/..double-dot-prefix"
printf 'hardlink target\n'             > "$H/cdl/hardlink-a"
ln    "$H/cdl/hardlink-a"                "$H/cdl/hardlink-b"
ln -s 'visible.txt'                      "$H/cdl/symlink-relative"
ln -s '/etc/hostname'                    "$H/cdl/symlink-absolute"
ln -s 'nowhere-at-all'                   "$H/cdl/symlink-dangling"

# A second user with different ownership. uid/gid need not exist as accounts for the
# ownership check to be meaningful -- what matters is that the numbers survive.
mkdir -p "$H/second/.config"
printf 'second user\n' > "$H/second/.config/state"
chown -R 1001:1001 "$H/second"
chmod 700 "$H/second"

# Model weights: contents must move, not be shadowed by an empty mount.
printf 'MODEL-WEIGHTS-FIXTURE-CONTENT\n' > "$M/model-a.bin"
mkdir -p "$M/nested/dir"
printf 'nested model\n' > "$M/nested/dir/model-b.bin"

# xattrs and ACLs, where the filesystem supports them.
setfattr -n user.cdl.fixture -v present "$H/cdl/visible.txt" 2>/dev/null || true
setfacl  -m u:1002:r--       "$H/cdl/visible.txt" 2>/dev/null || true

chown -R 1000:1000 "$H/cdl"

# ---- manifest: measure what is actually there now -------------------------------------
mkdir -p "$TARGET/var/log/cdl"
manifest="$TARGET/var/log/cdl/fixture-manifest.tsv"

{
    # path relative to /, then the properties that must survive
    find "$H" "$M" -mindepth 1 \( -type f -o -type d -o -type l \) -print0 |
    sort -z |
    while IFS= read -r -d '' p; do
        rel="${p#"$TARGET"}"
        if [ -L "$p" ]; then
            printf '%s\tlink\t%s\t%s\t%s\t%s\t%s\n' \
                "$rel" "$(readlink "$p")" \
                "$(stat -c %u "$p")" "$(stat -c %g "$p")" "-" "-"
        elif [ -d "$p" ]; then
            printf '%s\tdir\t-\t%s\t%s\t%s\t%s\n' \
                "$rel" "$(stat -c %u "$p")" "$(stat -c %g "$p")" "$(stat -c %a "$p")" "-"
        else
            printf '%s\tfile\t%s\t%s\t%s\t%s\t%s\n' \
                "$rel" "$(sha256sum "$p" | cut -d' ' -f1)" \
                "$(stat -c %u "$p")" "$(stat -c %g "$p")" "$(stat -c %a "$p")" \
                "$(stat -c %h "$p")"
        fi
    done
} > "$manifest"

# xattr and ACL are recorded separately, since not every kernel/filesystem carries them.
getfattr -d "$H/cdl/visible.txt" 2>/dev/null | grep -v '^#' | grep . \
    > "$TARGET/var/log/cdl/fixture-xattr.txt" || : > "$TARGET/var/log/cdl/fixture-xattr.txt"
getfacl -pn "$H/cdl/visible.txt" 2>/dev/null | grep -v '^#' | grep . \
    > "$TARGET/var/log/cdl/fixture-acl.txt"   || : > "$TARGET/var/log/cdl/fixture-acl.txt"

printf 'fixture: %s entries recorded\n' "$(wc -l < "$manifest")" >&2
