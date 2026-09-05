#!/usr/bin/env bash
# Pull the second copy of the backup repository to local storage.
#
# THIS RUNS ON THE PULLER, NEVER ON THE BOX. The whole point (spec §10.2) is a copy that
# the box cannot reach: the Hugging Face bucket has no versioning and no lifecycle rules,
# so a write-capable token on the box can erase the backup history in one command. This
# machine holds its own token, in its own rclone config, and the box holds nothing for
# this machine's storage.
#
# Three things are the safety argument, and none is optional:
#
#   copy          never `sync`. sync propagates deletions; a bucket wiped on Monday would
#                 wipe the second copy on Tuesday. copy only ever adds.
#   --immutable   never overwrite an existing local file. A restic repository is
#                 content-addressed and its files never legitimately change, so a source
#                 file that differs from the local one is corruption or an attack, and
#                 rclone must FAIL rather than replace a good copy with a bad one.
#   sha256 check  every restic file is NAMED by the SHA-256 of its content (measured:
#                 keys, index, snapshots and data all match). So after the pull, every
#                 local file is hashed and compared to its own name. This needs no
#                 repository password, and it is the check that actually holds: rclone's
#                 --immutable compares size and mtime, the HF gateway offers no content
#                 hash (so --checksum makes things WORSE -- "no hash" reads as "same"),
#                 and an attacker who preserves size and mtime gets past it. They cannot
#                 get past SHA-256.
#
# Usage:
#   pull-second-copy.sh                       uses the environment below
#   pull-second-copy.sh --dest DIR --remote REMOTE:PATH
#
# Environment:
#   RCLONE_CONFIG       this machine's rclone config, holding this machine's token
#   CDL_PULL_REMOTE     rclone remote and path, e.g. hf:cdl-backup/restic
#   CDL_PULL_DEST       local directory to pull into
#   CDL_PULL_MIN_FREE_GB  refuse to start below this much free space (default 20)
#   CDL_PULL_RECORD     JSONL run record (default: $CDL_PULL_DEST/../pull-runs.jsonl)
#   CDL_PULL_NOTIFY     optional command run with the one-line result as $1, for alerting

set -uo pipefail

remote="${CDL_PULL_REMOTE:-}"
dest="${CDL_PULL_DEST:-}"
min_free_gb="${CDL_PULL_MIN_FREE_GB:-20}"

while [ $# -gt 0 ]; do
    case "$1" in
        --remote) remote="$2"; shift 2 ;;
        --dest)   dest="$2"; shift 2 ;;
        --min-free-gb) min_free_gb="$2"; shift 2 ;;
        -h|--help) sed -n '2,40p' "$0" | sed -E 's/^#[[:space:]]?//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
t0=$(date +%s)
record="${CDL_PULL_RECORD:-${dest:+$(dirname "$dest")/pull-runs.jsonl}}"

finish() {
    local result="$1" detail="$2"
    local dur=$(( $(date +%s) - t0 ))
    local line="second-copy $result: $detail (${dur}s, $remote -> $dest)"
    if [ -n "$record" ]; then
        mkdir -p "$(dirname "$record")" 2>/dev/null
        printf '{"started":"%s","result":"%s","detail":"%s","remote":"%s","dest":"%s","seconds":%d}\n' \
            "$started" "$result" "${detail//\"/\\\"}" "$remote" "$dest" "$dur" >> "$record"
    fi
    echo "$line"
    [ -n "${CDL_PULL_NOTIFY:-}" ] && "$CDL_PULL_NOTIFY" "$line"
    [ "$result" = ok ]
}

# ---------------------------------------------------------------- preflight

[ -n "$remote" ] || { finish FAILED "no remote given (CDL_PULL_REMOTE or --remote)"; exit 2; }
[ -n "$dest" ]   || { finish FAILED "no destination given (CDL_PULL_DEST or --dest)"; exit 2; }
command -v rclone >/dev/null || { finish FAILED "rclone is not installed"; exit 2; }

[ -n "${RCLONE_CONFIG:-}" ] && [ -r "$RCLONE_CONFIG" ] \
    || { finish FAILED "RCLONE_CONFIG is unset or unreadable; this machine needs its own token"; exit 2; }

# The config must not be world-readable: it holds a token.
perms="$(stat -f %Lp "$RCLONE_CONFIG" 2>/dev/null || stat -c %a "$RCLONE_CONFIG" 2>/dev/null)"
case "$perms" in
    *[0-9][1-7]) finish FAILED "RCLONE_CONFIG is readable by group or other (mode $perms)"; exit 2 ;;
esac

mkdir -p "$dest" || { finish FAILED "cannot create $dest"; exit 2; }

# A second copy that silently stops for want of space is worse than none, because it is
# believed in. Refuse before starting, loudly.
free_kb="$(df -Pk "$dest" | awk 'NR==2 {print $4}')"
free_gb=$(( free_kb / 1048576 ))
[ "$free_gb" -ge "$min_free_gb" ] \
    || { finish FAILED "only ${free_gb} GB free at $dest, below the ${min_free_gb} GB floor"; exit 2; }

rclone lsd "$remote" >/dev/null 2>&1 \
    || { finish FAILED "cannot list $remote; token, network or path"; exit 2; }

# ---------------------------------------------------------------- pull

before="$(find "$dest" -type f | wc -l | tr -d ' ')"
log="$(mktemp -t cdl-pull)"
pull_problem=""
if ! rclone copy --immutable -v "$remote" "$dest" >"$log" 2>&1; then
    # --immutable failing is an alarm, not noise: a bucket file differs from a local file
    # that should never change. The local copy is untouched; whether it is TRUSTWORTHY is
    # a separate question, answered by the hash check below, which runs regardless.
    if grep -q 'immutable file modified' "$log"; then
        n="$(grep -c 'immutable file modified' "$log")"
        pull_problem="$n bucket file(s) differ from the local copy (not overwritten)"
    else
        pull_problem="rclone copy failed: $(grep -iE 'error|failed' "$log" | head -1)"
    fi
fi
rm -f "$log"
after="$(find "$dest" -type f | wc -l | tr -d ' ')"
transferred=$(( after - before ))

# ---------------------------------------------------------------- verify: integrity

# ALWAYS, whatever rclone said. Hash every local file and compare to its name. `config`
# is the one file restic does not name by content. A mismatch is corruption -- arrived
# through a pull, or local disk rot, which changes content and not mtime and is therefore
# invisible to rclone -- and the copy cannot be trusted until it is explained.
sha() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
bad_files=()
checked=0
while IFS= read -r -d '' f; do
    name="$(basename "$f")"
    case "$name" in config) continue ;; esac
    checked=$((checked + 1))
    [ "$(sha "$f")" = "$name" ] || bad_files+=("${f#"$dest"/}")
done < <(find "$dest" -type f -print0)

if [ "${#bad_files[@]}" -gt 0 ]; then
    printf '  CORRUPT: %s\n' "${bad_files[@]}" >&2
    finish FAILED "${#bad_files[@]} of $checked local file(s) do not match their content hash; the second copy is NOT trustworthy${pull_problem:+ (also: $pull_problem)}"
    exit 1
fi

if [ -n "$pull_problem" ]; then
    finish FAILED "$pull_problem; all $checked local file(s) verify by content hash, so the LOCAL copy is sound and the BUCKET is suspect. Investigate before pulling again"
    exit 1
fi

# ---------------------------------------------------------------- verify: presence

# Every file in the bucket is present locally. One-way: extra local files are expected,
# since copy never deletes and the box may have pruned.
if ! rclone check --one-way "$remote" "$dest" >/dev/null 2>&1; then
    finish FAILED "post-pull check: not every bucket file is present locally"
    exit 1
fi

finish ok "${transferred} file(s) transferred, ${after} held locally, ${checked} verified by content hash"
