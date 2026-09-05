#!/usr/bin/env bash
# cdl-backup: restic over rclone, against the Hugging Face bucket (spec §10).
# managed by cdl-linux; edits here are overwritten by ./install.sh
#
# Usage: cdl-backup {run|check|restore <snapshot> <target>|status}
#
# Installed to /usr/local/bin/cdl-backup by install/modules/60-backup.sh.
#
# Paths are overridable by environment variable so this can be exercised against a
# throwaway repository in tests, exactly as the rest of this codebase's scripts do
# (CDL_MODULE_DIR, CDL_OS_RELEASE, ...). Production never sets them.

set -uo pipefail

CONF="${CDL_BACKUP_CONF:-/etc/cdl/backup.conf}"
EXCLUDE_FILE="${CDL_BACKUP_EXCLUDE:-/etc/cdl/backup.exclude}"
PASS_FILE="${CDL_BACKUP_PASS:-/etc/cdl/restic.pass}"
LOG_FILE="${CDL_BACKUP_LOG:-/var/log/cdl/backup-runs.jsonl}"
RCLONE_CONF="${CDL_BACKUP_RCLONE_CONF:-/root/.config/rclone/rclone.conf}"

die() { printf 'cdl-backup: %s\n' "$*" >&2; exit 1; }

[ -f "$CONF" ] || die "$CONF not found; run ./install.sh --module 60-backup first"
# shellcheck disable=SC1090
source "$CONF"

# Portable (GNU and BSD/macOS) octal file mode.
file_mode() { stat -c%a "$1" 2>/dev/null || stat -f%Lp "$1" 2>/dev/null; }

# Only run/check/restore touch the repository, so only they need it configured. `status`
# reads nothing but the local run log and must work (and exit 0) on a freshly installed,
# not-yet-configured machine -- that is what says "unconfigured" rather than "broken".
require_configured() {
    [ -n "${RESTIC_REPOSITORY:-}" ] || die "$CONF does not set RESTIC_REPOSITORY"
    case "$RESTIC_REPOSITORY" in
        *CHANGEME*) die "$CONF still has the placeholder bucket name; edit RESTIC_REPOSITORY there first" ;;
    esac
    export RESTIC_REPOSITORY
    export RESTIC_PASSWORD_FILE="$PASS_FILE"
    case "$RESTIC_REPOSITORY" in
        rclone:*)
            [ -f "$RCLONE_CONF" ] || die "$RCLONE_CONF not found; configure rclone's [hf] profile there (spec §10.1)"
            export RCLONE_CONFIG="$RCLONE_CONF"
            ;;
    esac
}

require_pass_file() {
    [ -f "$PASS_FILE" ] || die "$PASS_FILE not found; create it (mode 0600) with the restic repository password"
    [ "$(file_mode "$PASS_FILE")" = "600" ] || die "$PASS_FILE must be mode 0600"
}

log_run() {
    local result="$1" detail="$2" seconds="$3" started="$4"
    mkdir -p "$(dirname "$LOG_FILE")"
    jq -nc --arg started "$started" --arg result "$result" --arg detail "$detail" --argjson seconds "$seconds" \
        '{started: $started, result: $result, detail: $detail, seconds: $seconds}' >> "$LOG_FILE"
}

cmd_run() {
    require_configured
    require_pass_file
    local started start_epoch end_epoch seconds out rc
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    start_epoch="$(date +%s)"
    # Intentional word-splitting: BACKUP_PATHS is a space-separated list, not one path.
    # shellcheck disable=SC2206
    local -a paths=(${BACKUP_PATHS:-/home /etc})
    if out="$(restic backup "${paths[@]}" --exclude-file="$EXCLUDE_FILE" --exclude-caches 2>&1 \
        && restic forget --keep-daily 30 --prune 2>&1 \
        && restic check 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    end_epoch="$(date +%s)"; seconds=$((end_epoch - start_epoch))
    if [ "$rc" -eq 0 ]; then
        log_run ok "backup, forget --prune and check all succeeded" "$seconds" "$started"
        printf '%s\n' "$out"
    else
        log_run failed "$(printf '%s' "$out" | tail -c 500)" "$seconds" "$started"
        printf '%s\n' "$out" >&2
        return 1
    fi
}

cmd_check() {
    require_configured
    require_pass_file
    restic check
}

cmd_restore() {
    require_configured
    require_pass_file
    local snap="${1:-}" target="${2:-}"
    [ -n "$snap" ] && [ -n "$target" ] || die "usage: cdl-backup restore <snapshot> <target>"
    restic restore "$snap" --target "$target"
}

cmd_status() {
    if [ ! -s "$LOG_FILE" ]; then
        echo "never run"
        return 0
    fi
    tail -n1 "$LOG_FILE" | jq -r '"\(.started)  \(.result)  \(.seconds)s  \(.detail)"'
}

case "${1:-}" in
    run)     shift; cmd_run "$@" ;;
    check)   shift; cmd_check "$@" ;;
    restore) shift; cmd_restore "$@" ;;
    status)  shift; cmd_status "$@" ;;
    *) die "usage: cdl-backup {run|check|restore <snapshot> <target>|status}" ;;
esac
