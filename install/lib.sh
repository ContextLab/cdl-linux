#!/usr/bin/env bash
# Shared helpers for install.sh and its modules. Sourced, never executed.
#
# Every module runs as its own process with this sourced, so a module cannot leak shell
# state into the next one, and a module that calls `exit` ends itself rather than the run.

# --- output ------------------------------------------------------------------------------
# Colour only when stdout is a terminal: a piped or logged run must stay greppable.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_OK=; C_WARN=; C_ERR=; C_DIM=; C_OFF=
fi

log()  { printf '%s\n' "$*" >&2; }
ok()   { printf '%s  ok  %s%s\n'   "$C_OK"   "$C_OFF" "$*" >&2; }
warn() { printf '%swarn%s %s\n'    "$C_WARN" "$C_OFF" "$*" >&2; }
err()  { printf '%sFAIL%s %s\n'    "$C_ERR"  "$C_OFF" "$*" >&2; }
dim()  { printf '%s%s%s\n'         "$C_DIM"  "$*"     "$C_OFF" >&2; }
die()  { err "$*"; exit 1; }

# --- module exit contract ----------------------------------------------------------------
# 0  the module's work is done (whether it acted or found nothing to do)
# 2  the module does not apply to this machine, and that is not an error
# *  failure: the run stops, and later modules do not run
CDL_SKIP=2
skip() { warn "$*"; exit "$CDL_SKIP"; }

# --- environment -------------------------------------------------------------------------
# CDL_OS_RELEASE exists so the preflight can be exercised against a fixture without
# pretending to be a different machine. It is never set in normal use.
cdl_os_release() { printf '%s' "${CDL_OS_RELEASE:-/etc/os-release}"; }

cdl_os_id()      { awk -F= '$1=="ID"{gsub(/"/,"",$2);print $2}'         "$(cdl_os_release)" 2>/dev/null; }
cdl_os_version() { awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2);print $2}' "$(cdl_os_release)" 2>/dev/null; }
cdl_arch()       { printf '%s' "${CDL_ARCH:-$(uname -m)}"; }

cdl_is_root()        { [ "$(id -u)" -eq 0 ]; }
cdl_need_root()      { cdl_is_root || die "$1 needs root; re-run with sudo"; }
cdl_is_interactive() { [ -t 0 ] && [ -t 1 ]; }

# --- idempotence helpers -----------------------------------------------------------------
# Back up before modifying, once per run, keeping the original mode and owner. A module
# that edits a file the user may have written must call this first.
cdl_backup_file() {
    local f="$1" stamp="${CDL_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
    [ -e "$f" ] || return 0
    local b="${f}.cdl-backup-${stamp}"
    [ -e "$b" ] && return 0
    cp -a "$f" "$b" && dim "    backed up $f -> $b"
}

# Write content to a file only if it differs, so a second run reports no change.
# Returns 0 if it wrote, 1 if the file was already correct.
cdl_write_if_changed() {
    local f="$1"; shift
    local new; new="$(cat)"
    if [ -f "$f" ] && [ "$(cat "$f")" = "$new" ]; then
        return 1
    fi
    cdl_backup_file "$f"
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$new" > "$f"
    return 0
}

cdl_have()        { command -v "$1" >/dev/null 2>&1; }
cdl_pkg_present() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }
