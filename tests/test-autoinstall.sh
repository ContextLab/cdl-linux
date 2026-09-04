#!/usr/bin/env bash
# The autoinstall seed and its validator.
#
# The validator exists because two defects reached a running installer: a missing storage
# section (the installer silently fell back to guided LVM and reported zero errors) and a
# duplicated key (YAML keeps the last value and says nothing). Both are asserted here
# against fixtures, and the second is asserted against the actual commit that carried it.

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V="$repo/scripts/validate-autoinstall.py"
SEED="$repo/scripts/vm/autoinstall/user-data"
pass=0; fail=0
ok()  { printf '  \033[32mOK\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

if python3 "$V" "$SEED" >/dev/null 2>&1; then ok "the committed seed validates"
else bad "the committed seed does not validate: $(python3 "$V" "$SEED" 2>&1 | tail -3)"; fi

# --- duplicate keys ---
printf 'autoinstall:\n  version: 1\n  version: 2\n' > "$work/dup.yaml"
if out="$(python3 "$V" "$work/dup.yaml" 2>&1)"; then bad "a duplicate key was accepted"
elif grep -q "duplicate key 'version'" <<<"$out"; then ok "a duplicate key is caught and named"
else bad "duplicate rejected without naming the key: $out"; fi

# The real one: the seed as it was committed before the dedup.
if git -C "$repo" show 613544f:scripts/vm/autoinstall/user-data > "$work/real.yaml" 2>/dev/null; then
    if out="$(python3 "$V" "$work/real.yaml" 2>&1)"; then
        bad "the historical seed with a duplicated 'shutdown' key was accepted"
    elif grep -q "duplicate key 'shutdown'" <<<"$out"; then
        ok "the duplicate that actually shipped is caught"
    else bad "historical seed rejected for the wrong reason: $out"; fi
fi

# --- missing sections ---
python3 - "$SEED" "$work/nostorage.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
del d["autoinstall"]["storage"]
yaml.safe_dump(d, open(sys.argv[2], "w"))
PY
if python3 "$V" "$work/nostorage.yaml" >/dev/null 2>&1; then
    bad "a seed with no storage section was accepted -- this is the guided-LVM failure"
else ok "a seed with no storage section is refused"; fi

python3 - "$SEED" "$work/nopkg.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
del d["autoinstall"]["packages"]
yaml.safe_dump(d, open(sys.argv[2], "w"))
PY
if python3 "$V" "$work/nopkg.yaml" >/dev/null 2>&1; then bad "a seed with no packages was accepted"
else ok "a seed with no packages is refused"; fi

# --- dangling storage references ---
python3 - "$SEED" "$work/dangling.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for e in d["autoinstall"]["storage"]["config"]:
    if e.get("type") == "format":
        e["volume"] = "does-not-exist"
        break
yaml.safe_dump(d, open(sys.argv[2], "w"))
PY
if python3 "$V" "$work/dangling.yaml" >/dev/null 2>&1; then bad "a dangling storage reference was accepted"
else ok "a dangling storage reference is refused"; fi

# --- the seed delivers the scripts, by a mechanism that actually reaches the installer ---
# cloud-init write_files was tried and does NOT reach subiquity's late-commands environment:
# the files were absent and the guards fired. Delivery is base64 decoded in late-commands.
if python3 - "$SEED" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert "write_files" not in d, "write_files does not reach the installer; do not use it"
cmds = "\n".join(c if isinstance(c, str) else " ".join(c)
                  for c in d["autoinstall"]["late-commands"])
for ph in ("@@CDL_B64_MIGRATE@@", "@@CDL_B64_FIXTURE@@", "@@CDL_B64_VERIFY@@"):
    assert ph in cmds, f"{ph} is not substituted into late-commands"
assert "base64 -d" in cmds, "no base64 decode step"
# Match the expansion, not the word: the file explains in a comment why this bashism is
# not used, and an assertion that cannot tell use from mention forbids documenting it.
assert "${PIPESTATUS" not in cmds, "PIPESTATUS is expanded; late-commands run under sh"
# /run is noexec in the installer: a decoded script executed directly exits 126 whatever
# its mode bits say. Every delivered script must be handed to an interpreter instead.
for script in ("fixture-create.sh", "migrate-btrfs-root.sh"):
    assert f"bash /run/cdl/{script}" in cmds, f"{script} is executed directly; /run is noexec"
    assert f"\n    - /run/cdl/{script}" not in cmds, f"{script} still invoked directly"
PY
then ok "scripts are delivered by base64 decode, not write_files"
else bad "script delivery mechanism is wrong"; fi

# --- every late-command that needs a delivered script checks for it ---
if python3 - "$SEED" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
cmds = [c if isinstance(c, str) else " ".join(c) for c in d["autoinstall"]["late-commands"]]
joined = "\n".join(cmds)
assert "seed did not deliver" in joined, "no guard on undelivered scripts"
assert "curtin in-target" not in joined, "curtin in-target is used after the remount"
PY
then ok "late-commands check for delivered scripts and never use curtin in-target"
else bad "late-commands are missing a check, or still use curtin in-target"; fi

# --- the production profile ---
TB="$repo/install/autoinstall/tensorbook.yaml"
if python3 "$V" "$TB" >/dev/null 2>&1; then ok "the Tensorbook profile validates"
else bad "Tensorbook profile invalid: $(python3 "$V" "$TB" 2>&1 | tail -3)"; fi

# This repository is public. A committed passphrase is a published passphrase, and rotating
# a LUKS passphrase afterwards does not un-publish the one the disk was created with.
if python3 - "$TB" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
a = d["autoinstall"]
key = next(e["key"] for e in a["storage"]["config"] if e.get("type") == "dm_crypt")
assert key.startswith("@@") and key.endswith("@@"), f"LUKS key is not a placeholder: {key!r}"
assert a["identity"]["password"].startswith("@@"), "password hash is not a placeholder"
for k in a["ssh"]["authorized-keys"]:
    assert k.startswith("@@"), f"a real SSH key is committed: {k[:40]}"
assert a["ssh"]["allow-pw"] is False, "password SSH is enabled"
PY
then ok "the production profile commits no secret, only placeholders"
else bad "the production profile carries something that should not be committed"; fi

# The two profiles must not share a credential: the VM's passphrase protects nothing.
vm_key="$(python3 -c "
import yaml
d=yaml.safe_load(open('$SEED'))
print(next(e['key'] for e in d['autoinstall']['storage']['config'] if e.get('type')=='dm_crypt'))")"
if grep -qF "$vm_key" "$TB"; then bad "the Tensorbook profile reuses the VM test passphrase"
else ok "the Tensorbook profile does not reuse the VM test passphrase"; fi

# Disks matched by identity, not by enumeration order.
if python3 - "$TB" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
disks = [e for e in d["autoinstall"]["storage"]["config"] if e.get("type") == "disk"]
assert disks, "no disks"
for e in disks:
    assert "path" not in e, f"disk {e['id']} is matched by path {e.get('path')}, not identity"
    assert "match" in e, f"disk {e['id']} has no match directive"
early = "\n".join(d["autoinstall"]["early-commands"])
assert "exactly 2 NVMe" in early, "no guard on the number of NVMe disks"
assert "CDL_EXPECTED_SERIALS" in early, "no optional serial check"
PY
then ok "production disks are matched by identity with a count guard"
else bad "production disks are matched by enumeration order"; fi

printf '\n  test-autoinstall: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
