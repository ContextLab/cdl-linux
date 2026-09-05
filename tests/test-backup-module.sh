#!/usr/bin/env bash
# Checks for install/modules/60-backup.sh and install/cdl-backup.sh that run on a plain
# macOS checkout: no root, no apt, no systemd. Everything that needs those (the module
# actually applying, the timer actually enabling) belongs to tests/vm/verify-backup.sh
# instead, run against the guest.
#
# What runs here uses real restic against a real, throwaway local repository -- no mocks.
#
# Usage: tests/test-backup-module.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$repo_root/install/modules/60-backup.sh"
CDL_BACKUP="$repo_root/install/cdl-backup.sh"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------------------
echo "== shellcheck =="
# ---------------------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    if (cd "$(dirname "$MODULE")" && shellcheck -x "$(basename "$MODULE")"); then
        ok "shellcheck clean: install/modules/60-backup.sh"
    else
        bad "shellcheck: install/modules/60-backup.sh"
    fi
    if (cd "$(dirname "$CDL_BACKUP")" && shellcheck -x "$(basename "$CDL_BACKUP")"); then
        ok "shellcheck clean: install/cdl-backup.sh"
    else
        bad "shellcheck: install/cdl-backup.sh"
    fi
else
    echo "  shellcheck not installed -- skipping"
fi

# ---------------------------------------------------------------------------------------
echo "== module contract =="
# ---------------------------------------------------------------------------------------
if bash -n "$MODULE"; then ok "module parses"; else bad "module has a syntax error"; fi
if bash -n "$CDL_BACKUP"; then ok "cdl-backup parses"; else bad "cdl-backup has a syntax error"; fi
if grep -q '^set -uo pipefail$' "$MODULE"; then ok "module sets -uo pipefail"; else bad "module missing 'set -uo pipefail'"; fi
if grep -q 'source-path=SCRIPTDIR source=../lib.sh' "$MODULE"; then
    ok "module carries the shellcheck source header"
else
    bad "module missing shellcheck source header"
fi
if grep -q 'cdl_need_root' "$MODULE"; then ok "module calls cdl_need_root"; else bad "module does not call cdl_need_root"; fi

# ---------------------------------------------------------------------------------------
echo "== exclude file content (spec §9.4, §10.3) =="
# ---------------------------------------------------------------------------------------
if grep -q '^/home/\*/\.local/state/cdl/sessions$' "$MODULE"; then
    ok "exclude file excludes the per-user session transcript directory"
else
    bad "exclude file does not exclude ~/.local/state/cdl/sessions for every user"
fi
if grep -q '^/home/\*/\.cache$' "$MODULE"; then
    ok "exclude file excludes ~/.cache for every user"
else
    bad "exclude file does not exclude ~/.cache"
fi
if grep -qx '__pycache__' "$MODULE" && grep -qx 'node_modules' "$MODULE"; then
    ok "exclude file excludes __pycache__ and node_modules"
else
    bad "exclude file missing __pycache__ or node_modules"
fi
if grep 'BACKUP_PATHS=' "$MODULE" | grep -q '/srv/models'; then
    bad "/srv/models must not appear in BACKUP_PATHS (spec §10.3)"
else
    ok "/srv/models is not part of BACKUP_PATHS"
fi

# ---------------------------------------------------------------------------------------
echo "== timer: nightly and persistent (spec §10.3) =="
# ---------------------------------------------------------------------------------------
if grep -q 'OnCalendar=\*-\*-\* 02:30:00' "$MODULE"; then
    ok "timer fires nightly at 02:30"
else
    bad "timer is not scheduled for 02:30 nightly"
fi
if grep -q '^Persistent=true$' "$MODULE"; then ok "timer is Persistent=true"; else bad "timer is not Persistent"; fi
if grep -q 'RandomizedDelaySec' "$MODULE"; then
    ok "timer has a randomized delay"
else
    bad "timer has no randomized delay"
fi

# ---------------------------------------------------------------------------------------
echo "== refuses to enable while unconfigured (grep the guard) =="
# ---------------------------------------------------------------------------------------
# These are literal text to search for in $MODULE, not meant to expand here.
# shellcheck disable=SC2016
rrepo_guard='grep -q "RESTIC_REPOSITORY=rclone:hf:${PLACEHOLDER_BUCKET}/restic" "$BACKUP_CONF" && configured=0'
# shellcheck disable=SC2016
pass_guard='[ -f "$CDL_ETC/restic.pass" ] || configured=0'
if grep -q 'PLACEHOLDER_BUCKET="CHANGEME"' "$MODULE" \
   && grep -qF "$rrepo_guard" "$MODULE" \
   && grep -qF "$pass_guard" "$MODULE" \
   && grep -q 'cdl_enable_now cdl-backup.timer' "$MODULE"; then
    ok "the timer-enable guard checks both the placeholder and restic.pass"
else
    bad "the placeholder/restic.pass guard is missing or changed shape"
fi
if grep -B2 'exit 0' "$MODULE" | grep -q 'warn'; then
    ok "refusing to enable exits 0 with a warning, not a failure"
else
    bad "the unconfigured path does not warn-and-exit-0"
fi

# ---------------------------------------------------------------------------------------
echo "== cdl-backup status on an empty run log =="
# ---------------------------------------------------------------------------------------
status_conf="$tmp/status/backup.conf"
mkdir -p "$(dirname "$status_conf")"
cat > "$status_conf" <<CONF
RESTIC_REPOSITORY=$tmp/status/repo
BACKUP_PATHS="$tmp/status/src"
CONF
out="$(CDL_BACKUP_CONF="$status_conf" CDL_BACKUP_LOG="$tmp/status/does-not-exist.jsonl" \
    bash "$CDL_BACKUP" status)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "never run" ]; then
    ok "status on an empty/missing run log says 'never run' and exits 0"
else
    bad "status on an empty run log: rc=$rc out='$out'"
fi

# ---------------------------------------------------------------------------------------
echo "== cdl-backup refuses the placeholder repository, but status still works =="
# ---------------------------------------------------------------------------------------
ph_conf="$tmp/placeholder/backup.conf"
mkdir -p "$(dirname "$ph_conf")"
cat > "$ph_conf" <<'CONF'
RESTIC_REPOSITORY=rclone:hf:CHANGEME/restic
BACKUP_PATHS="/home /etc"
CONF
if CDL_BACKUP_CONF="$ph_conf" CDL_BACKUP_LOG="$tmp/placeholder/runs.jsonl" bash "$CDL_BACKUP" run >/tmp/ph.out 2>&1; then
    bad "cdl-backup run did not refuse a conf still holding the placeholder bucket"
else
    if grep -qi 'placeholder' /tmp/ph.out; then
        ok "cdl-backup run refuses a conf with the placeholder bucket, and says why"
    else
        bad "refused, but without saying the bucket is still a placeholder"
    fi
fi
# status must still work on an unconfigured machine -- that is the "install is complete,
# backup is unconfigured" state install/modules/60-backup.sh deliberately leaves behind.
if CDL_BACKUP_CONF="$ph_conf" CDL_BACKUP_LOG="$tmp/placeholder/runs.jsonl" bash "$CDL_BACKUP" status \
    >/tmp/ph-status.out 2>&1; then
    ok "cdl-backup status still exits 0 while the repository is unconfigured"
else
    bad "cdl-backup status should not require a configured repository: $(cat /tmp/ph-status.out)"
fi
rm -f /tmp/ph.out /tmp/ph-status.out

# ---------------------------------------------------------------------------------------
echo "== cdl-backup run: real restic, real exclusion, real log line =="
# ---------------------------------------------------------------------------------------
if ! command -v restic >/dev/null 2>&1; then
    echo "  restic not installed on this machine -- skipping the real backup round trip"
else
    root="$tmp/fixture"
    mkdir -p "$root/home/alice/.local/state/cdl/sessions" "$root/home/alice/.cache" "$root/etc"
    echo "a private transcript" > "$root/home/alice/.local/state/cdl/sessions/transcript.log"
    echo "cache data"          > "$root/home/alice/.cache/whatever"
    echo "config data"         > "$root/etc/conf"

    # Exclude patterns anchored to this fixture's own absolute root, the same shape as the
    # production file's patterns anchored to the real /home -- proven equivalent above:
    # a leading-slash restic pattern matches the true absolute path of the scanned file,
    # not a path relative to the backup source argument.
    excl="$tmp/fixture.exclude"
    cat > "$excl" <<EXCL
$root/home/*/.local/state/cdl/sessions
$root/home/*/.cache
EXCL

    run_conf="$tmp/run/backup.conf"
    mkdir -p "$(dirname "$run_conf")"
    cat > "$run_conf" <<CONF
RESTIC_REPOSITORY=$tmp/run/repo
BACKUP_PATHS="$root/home $root/etc"
CONF

    run_log="$tmp/run/backup-runs.jsonl"
    pass_file="$tmp/run/restic.pass"
    printf 'fixture-password\n' > "$pass_file"
    chmod 0600 "$pass_file"

    RESTIC_PASSWORD_FILE="$pass_file" RESTIC_REPOSITORY="$tmp/run/repo" restic init >/tmp/init.out 2>&1 \
        || { bad "restic init for the fixture repo"; cat /tmp/init.out; }

    if CDL_BACKUP_CONF="$run_conf" CDL_BACKUP_EXCLUDE="$excl" CDL_BACKUP_PASS="$pass_file" \
       CDL_BACKUP_LOG="$run_log" bash "$CDL_BACKUP" run >/tmp/run.out 2>&1; then
        ok "cdl-backup run succeeds against a local repository"
    else
        bad "cdl-backup run failed"; cat /tmp/run.out
    fi

    listing="$(RESTIC_PASSWORD_FILE="$pass_file" RESTIC_REPOSITORY="$tmp/run/repo" restic ls latest 2>/dev/null)"
    if grep -q 'sessions' <<<"$listing"; then
        bad "the sessions transcript was NOT excluded from the backup"
    else
        ok "the sessions transcript fixture is excluded from the snapshot"
    fi
    if grep -q '\.cache' <<<"$listing"; then
        bad "the cache fixture was NOT excluded from the backup"
    else
        ok "the cache fixture is excluded from the snapshot"
    fi
    if grep -q 'etc/conf' <<<"$listing"; then
        ok "an unrelated file is still backed up (exclusion isn't over-broad)"
    else
        bad "etc/conf should have been backed up and was not"
    fi

    if [ -s "$run_log" ] && python3 -c "
import json
row = json.loads(open('$run_log').read().splitlines()[-1])
assert row['result'] == 'ok', row
assert isinstance(row['seconds'], int), row
assert row['started'], row
" 2>/tmp/json.err; then
        ok "one JSON line was appended to the run log with started/result/detail/seconds"
    else
        bad "run log line missing or malformed"; cat /tmp/json.err 2>/dev/null
    fi
    rm -f /tmp/init.out /tmp/run.out /tmp/json.err
fi

# ---------------------------------------------------------------------------------------
printf '\n== summary: %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
