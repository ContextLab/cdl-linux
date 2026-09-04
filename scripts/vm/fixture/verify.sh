#!/usr/bin/env bash
# Verify, on the booted system, that the migration preserved every fixture property.
# Runs against the manifest recorded before migration; no expectations are restated here.

set -uo pipefail
manifest="${MANIFEST:-/var/log/cdl/fixture-manifest.tsv}"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$*"; }

[ -f "$manifest" ] || { echo "FATAL: no manifest at $manifest"; exit 1; }

# The fixture deliberately does not touch authorized_keys, so the manifest must not carry
# it. If it ever does, the fixture has started clobbering the machine's login credential
# and that is a failure regardless of whether the content matches.
if grep -q '/\.ssh/authorized_keys' "$manifest"; then
    bad "the fixture recorded authorized_keys; it must not touch the real login credential"
fi

while IFS=$'\t' read -r rel kind a uid gid mode nlink; do
    [ -n "$rel" ] || continue
    case "$kind" in
      link)
        if [ ! -L "$rel" ]; then bad "$rel: symlink missing"; continue; fi
        [ "$(readlink "$rel")" = "$a" ] || { bad "$rel: target '$(readlink "$rel")' != '$a'"; continue; }
        [ "$(stat -c %u "$rel")" = "$uid" ] || { bad "$rel: uid"; continue; }
        ok ;;
      dir)
        if [ ! -d "$rel" ]; then bad "$rel: directory missing"; continue; fi
        [ "$(stat -c %u "$rel")" = "$uid" ] || { bad "$rel: uid $(stat -c %u "$rel") != $uid"; continue; }
        [ "$(stat -c %g "$rel")" = "$gid" ] || { bad "$rel: gid"; continue; }
        [ "$(stat -c %a "$rel")" = "$mode" ] || { bad "$rel: mode $(stat -c %a "$rel") != $mode"; continue; }
        ok ;;
      file)
        if [ ! -f "$rel" ]; then bad "$rel: file missing"; continue; fi
        [ "$(sha256sum "$rel" | cut -d' ' -f1)" = "$a" ] || { bad "$rel: content differs"; continue; }
        [ "$(stat -c %u "$rel")" = "$uid" ] || { bad "$rel: uid $(stat -c %u "$rel") != $uid"; continue; }
        [ "$(stat -c %g "$rel")" = "$gid" ] || { bad "$rel: gid"; continue; }
        [ "$(stat -c %a "$rel")" = "$mode" ] || { bad "$rel: mode $(stat -c %a "$rel") != $mode"; continue; }
        [ "$(stat -c %h "$rel")" = "$nlink" ] || { bad "$rel: link count $(stat -c %h "$rel") != $nlink (hardlink broken)"; continue; }
        ok ;;
    esac
done < "$manifest"

# The subvolume split itself: these paths must be on the subvolumes, not inside @.
for spec in "/home:@home" "/srv/models:@models"; do
    p="${spec%%:*}"; want="${spec##*:}"
    if findmnt -no OPTIONS "$p" 2>/dev/null | grep -q "subvol=/$want"; then ok
    else bad "$p is not mounted from $want"; fi
done

if [ -s /var/log/cdl/fixture-xattr.txt ]; then
    if getfattr -d /home/cdl/visible.txt 2>/dev/null | grep -q 'user.cdl.fixture'; then ok
    else bad "xattr user.cdl.fixture did not survive"; fi
fi
if grep -q '^user:1002:' /var/log/cdl/fixture-acl.txt 2>/dev/null; then
    if getfacl -pn /home/cdl/visible.txt 2>/dev/null | grep -q '^user:1002:'; then ok
    else bad "ACL entry for uid 1002 did not survive"; fi
fi

printf '\nfixture: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
