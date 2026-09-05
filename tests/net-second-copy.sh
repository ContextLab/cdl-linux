#!/usr/bin/env bash
# The second copy (spec §10.2), proven against the real bucket and the real threat.
#
# T5: the box holds a write-capable token and the bucket has no versioning, so the box can
# erase the backup history. The mitigation is a copy the box cannot reach. This test does
# not check that a pull works; it checks that the copy SURVIVES what it exists to survive:
#
#   1. backup to the bucket, pull the second copy, restore from the LOCAL copy alone
#   2. WIPE the bucket -- restore from the local copy must still work
#   3. re-pull from the wiped bucket -- must succeed and must delete nothing locally
#   4. CORRUPT a file in the bucket -- the pull must FAIL and must not overwrite the good copy
#   5. SAME-SIZE, same-mtime corruption -- the careful attacker. rclone sees no difference
#      and SKIPS the file, so the corruption never reaches the second copy. That is the
#      correct outcome: the puller's job is a trustworthy copy, and auditing the bucket is
#      the box's job (restic check). What is asserted is that the local file stays good
#   6. LOCAL rot with mtime preserved -- real bit-rot changes content, not mtime, so rclone
#      cannot see it. Only the content-hash check can, and it must
#
# Needs network and the [hf] profile in ~/.aws/credentials. Named net-*, not test-*, so
# run-all.sh's suite glob leaves it alone while its lint glob still covers it; run-vm.sh
# calls it.

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULL="$repo/scripts/backup/pull-second-copy.sh"
NS="${CDL_HF_NAMESPACE:-jeremyrmanning}"
BUCKET="${CDL_TEST_BUCKET:-cdl-vm-backup-test}"
PREFIX="second-copy-test-$$"
pass=0; fail=0
ok()  { printf '  \033[32mOK\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
die() { printf '\033[31mFATAL\033[0m %s\n' "$1"; exit 1; }

for t in rclone restic python3; do command -v "$t" >/dev/null || die "$t not installed"; done

work="$(mktemp -d)"
cleanup() {
    RCLONE_CONFIG="$work/rclone.conf" rclone purge "hf:${BUCKET}/${PREFIX}" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

# --- the puller's own rclone config, from this machine's credentials, mode 0600 ---------
# In production this is a DIFFERENT token from the box's (a fine-grained token scoped to
# the bucket). Here both sides use this machine's profile, which does not weaken what is
# under test: the wipe and corruption below are done with the box's capabilities, and the
# question is whether the local copy survives them.
python3 - "$work/rclone.conf" "$NS" <<'PY'
import configparser, os, sys
c = configparser.ConfigParser(); c.read(os.path.expanduser("~/.aws/credentials"))
p = c["hf"]
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(f"[hf]\ntype = s3\nprovider = Other\nendpoint = https://s3.hf.co/{sys.argv[2]}\n"
            f"access_key_id = {p['aws_access_key_id']}\nsecret_access_key = {p['aws_secret_access_key']}\n"
            f"region = us-east-1\nforce_path_style = true\nlist_version = 2\n")
PY
export RCLONE_CONFIG="$work/rclone.conf"
export RESTIC_PASSWORD="second-copy-test-passphrase"
REMOTE="hf:${BUCKET}/${PREFIX}"
SECOND="$work/second-copy/restic"

# --- the box's side: a repository with real content ------------------------------------
src="$work/src"; mkdir -p "$src/.config/tool" "$src/deep/er"
printf 'visible\n'           > "$src/visible.txt"
printf 'hidden\n'            > "$src/.profile"
printf '[tool]\nk=v\n'       > "$src/.config/tool/config"
head -c 300000 /dev/urandom  > "$src/deep/er/blob.bin"
ln -s visible.txt "$src/link"
(cd "$src" && find . -type f -exec shasum -a 256 {} + | sort) > "$work/src.sha"

echo "== box: backup to the bucket =="
restic -r "rclone:${REMOTE}" init -q          >/dev/null 2>&1 || die "restic init failed"
restic -r "rclone:${REMOTE}" backup -q "$src" >/dev/null 2>&1 || die "restic backup failed"
snap="$(restic -r "rclone:${REMOTE}" snapshots --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["short_id"])')"
if [ -n "$snap" ]; then ok "backup exists in the bucket (snapshot $snap)"; else bad "no snapshot"; fi

# --- 1. pull, then restore from the LOCAL copy with no bucket access at all ------------
echo "== puller: first pull =="
if out="$(CDL_PULL_MIN_FREE_GB=1 "$PULL" --remote "$REMOTE" --dest "$SECOND" 2>&1)"; then
    ok "pull succeeds: ${out##*: }"
else bad "pull failed: $out"; fi
if [ -s "$work/second-copy/pull-runs.jsonl" ]; then ok "a run record was written"; else bad "no run record"; fi

restore1="$work/restore1"
if restic -r "$SECOND" restore "$snap" --target "$restore1" -q >/dev/null 2>&1; then
    (cd "$restore1$src" && find . -type f -exec shasum -a 256 {} + | sort) > "$work/r1.sha"
    if diff -q "$work/src.sha" "$work/r1.sha" >/dev/null; then ok "restore from the LOCAL copy is byte-identical"
    else bad "restore from local copy differs"; fi
    if [ -L "$restore1$src/link" ]; then ok "symlink survived"; else bad "symlink lost"; fi
else bad "restore from the local copy failed"; fi

# --- 2. THE THREAT: the box's token wipes the bucket ----------------------------------
echo "== box (or attacker): wipe the bucket =="
rclone purge "$REMOTE" >/dev/null 2>&1
if rclone lsf "$REMOTE" 2>/dev/null | grep -q .; then bad "bucket not actually wiped"
else ok "bucket is empty: the box's backup history is gone"; fi

restore2="$work/restore2"
if restic -r "$SECOND" restore "$snap" --target "$restore2" -q >/dev/null 2>&1; then
    (cd "$restore2$src" && find . -type f -exec shasum -a 256 {} + | sort) > "$work/r2.sha"
    if diff -q "$work/src.sha" "$work/r2.sha" >/dev/null; then ok "AFTER THE WIPE: restore from the second copy is still byte-identical"
    else bad "post-wipe restore differs"; fi
else bad "post-wipe restore FAILED -- the second copy did not survive T5"; fi

# --- 3. re-pull from the wiped bucket: must not delete anything locally ---------------
echo "== puller: pull again from the wiped bucket =="
before="$(find "$SECOND" -type f | wc -l | tr -d ' ')"
if CDL_PULL_MIN_FREE_GB=1 "$PULL" --remote "$REMOTE" --dest "$SECOND" >/dev/null 2>&1; then
    after="$(find "$SECOND" -type f | wc -l | tr -d ' ')"
    if [ "$before" = "$after" ] && [ "$after" -gt 0 ]; then ok "re-pull from an empty bucket deleted nothing ($after files kept)"
    else bad "re-pull changed the local file count: $before -> $after"; fi
else bad "re-pull from an empty bucket failed (it should succeed with nothing to do)"; fi

# --- 4. corruption: a bucket file with the same name but different content -----------
echo "== attacker: corrupt a file in the bucket =="
victim="$(cd "$SECOND" && find . -type f -path './data/*' | head -1 | sed 's|^\./||')"
[ -n "$victim" ] || die "no data file to corrupt"
good_sum="$(shasum -a 256 "$SECOND/$victim" | cut -d' ' -f1)"
printf 'GARBAGE-NOT-A-RESTIC-BLOB-%s\n' "$(date +%s)" > "$work/garbage"
rclone copyto "$work/garbage" "$REMOTE/$victim" >/dev/null 2>&1 || die "could not plant corrupt file"

if out="$(CDL_PULL_MIN_FREE_GB=1 "$PULL" --remote "$REMOTE" --dest "$SECOND" 2>&1)"; then
    bad "pull SUCCEEDED against a corrupted bucket; it must refuse"
else
    if grep -q 'differ from the local copy' <<<"$out"; then ok "pull REFUSES a bucket file that differs from the local one"
    else bad "pull failed for the wrong reason: $out"; fi
fi
now_sum="$(shasum -a 256 "$SECOND/$victim" | cut -d' ' -f1)"
if [ "$good_sum" = "$now_sum" ]; then ok "the good local file was NOT overwritten"; else bad "local file was overwritten with garbage"; fi

# and the repository is still restorable after the attempted corruption
restore3="$work/restore3"
if restic -r "$SECOND" restore "$snap" --target "$restore3" -q >/dev/null 2>&1; then
    ok "second copy still restores after the corruption attempt"
else bad "second copy broken after corruption attempt"; fi

# --- 5. same-size corruption, mtime preserved: the attacker who read the rclone docs ---
echo "== attacker: same-size corruption with the original mtime =="
rclone purge "$REMOTE" >/dev/null 2>&1
rclone copy "$SECOND" "$REMOTE" >/dev/null 2>&1          # put the good repo back in the bucket
victim2="$(cd "$SECOND" && find data -type f | tail -1 | sed 's|^\./||')"
size=$(stat -f %z "$SECOND/$victim2" 2>/dev/null || stat -c %s "$SECOND/$victim2")
head -c "$size" /dev/urandom > "$work/evil2"
touch -r "$SECOND/$victim2" "$work/evil2"                # same mtime as the good file
rclone copyto "$work/evil2" "$REMOTE/$victim2" >/dev/null 2>&1
good2="$(shasum -a 256 "$SECOND/$victim2" | cut -d' ' -f1)"
if out="$(CDL_PULL_MIN_FREE_GB=1 "$PULL" --remote "$REMOTE" --dest "$SECOND" 2>&1)"; then
    ok "pull completes: rclone skipped the look-alike, so it never entered the second copy"
else
    ok "pull refuses the look-alike: ${out##*second-copy FAILED: }"
fi
now2="$(shasum -a 256 "$SECOND/$victim2" | cut -d' ' -f1)"
if [ "$good2" = "$now2" ]; then ok "the good local file survived the careful attacker"; else bad "OVERWRITTEN by same-size corruption"; fi

# --- 6. local rot: corruption already sitting in the second copy ---------------------
echo "== disk: a local file rots =="
rclone purge "$REMOTE" >/dev/null 2>&1
rclone copy "$SECOND" "$REMOTE" >/dev/null 2>&1
rot="$(cd "$SECOND" && find index -type f | head -1)"
cp -p "$SECOND/$rot" "$work/rot.bak"
printf 'X' | dd of="$SECOND/$rot" bs=1 seek=10 conv=notrunc 2>/dev/null
touch -r "$work/rot.bak" "$SECOND/$rot"       # bit-rot does not update mtime; neither does this
if out="$(CDL_PULL_MIN_FREE_GB=1 "$PULL" --remote "$REMOTE" --dest "$SECOND" 2>&1)"; then
    bad "pull reported ok with a rotted local file"
else
    if grep -q 'do not match their content hash' <<<"$out"; then ok "local rot is detected by the content-hash check"
    else bad "wrong failure for local rot: $out"; fi
fi
cp -p "$work/rot.bak" "$SECOND/$rot"

# --- the run record tells the truth about every pull ----------------------------------
results="$(python3 -c "
import json
print(' '.join(json.loads(l)['result'] for l in open('$work/second-copy/pull-runs.jsonl')))")"
if [ "$results" = "ok ok FAILED ok FAILED" ]; then ok "run record reads: $results"
else bad "run record reads: $results (want: ok ok FAILED ok FAILED)"; fi

printf '\n  net-second-copy: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
