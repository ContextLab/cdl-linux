#!/usr/bin/env bash
# cdl-linux installer.
#
# Turns a stock Ubuntu Server 26.04 machine into the workstation described in
# docs/superpowers/specs/2026-09-02-cdl-box-design.md. Modelled on Lambda Stack: one
# script, vanilla Ubuntu, no custom ISO and no package archive.
#
#   ./install.sh                 run every module in order
#   ./install.sh --list          show the modules and stop
#   ./install.sh --module NAME   re-run exactly one module
#   ./install.sh --dry-run       show what would run, change nothing
#
# WHAT THIS DOES NOT DO. It does not build the storage layout: subvolumes cannot be
# created on a live root, so that belongs to install/autoinstall/ at install time. And
# there is no uninstall. Removing what this configures means reinstalling Ubuntu. That is
# stated rather than half-implemented, because a partial uninstall of a system this
# entangled is more dangerous than none.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# CDL_MODULE_DIR lets the test suite point the runner at fixture modules and exercise
# ordering, failure propagation and the run record without installing anything.
MODULE_DIR="${CDL_MODULE_DIR:-$HERE/install/modules}"
LOG_DIR="${CDL_LOG_DIR:-/var/log/cdl}"
LOCK_FILE="${CDL_LOCK_FILE:-/var/lock/cdl-install.lock}"

# shellcheck source-path=SCRIPTDIR source=install/lib.sh
source "$HERE/install/lib.sh"

CDL_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
export CDL_RUN_ID

only_module=""
dry_run=0
list_only=0

while [ $# -gt 0 ]; do
    case "$1" in
        --list)     list_only=1; shift ;;
        --dry-run)  dry_run=1; shift ;;
        --module)   only_module="${2:-}"; [ -n "$only_module" ] || die "--module needs a name"; shift 2 ;;
        -h|--help)  sed -n '2,20p' "$0" | sed -E 's/^#[[:space:]]?//'; exit 0 ;;
        *)          die "unknown argument '$1' (try --help)" ;;
    esac
done

# --- module discovery ---------------------------------------------------------------------
# Lexical order is the execution order, which is why modules are numbered. A gap in the
# numbering is deliberate: it leaves room to insert without renaming.
mapfile -t modules < <(find "$MODULE_DIR" -maxdepth 1 -name '[0-9][0-9]-*.sh' | sort)
[ "${#modules[@]}" -gt 0 ] || die "no modules found in $MODULE_DIR"

if [ -n "$only_module" ]; then
    match=""
    for m in "${modules[@]}"; do
        b="$(basename "$m" .sh)"
        [ "$b" = "$only_module" ] || [ "${b#*-}" = "$only_module" ] && match="$m"
    done
    [ -n "$match" ] || die "no module matches '$only_module' (try --list)"
    modules=("$match")
fi

if [ "$list_only" -eq 1 ]; then
    log "modules, in execution order:"
    for m in "${modules[@]}"; do printf '  %s\n' "$(basename "$m" .sh)"; done
    exit 0
fi

# --- one at a time -------------------------------------------------------------------------
# Two concurrent runs would interleave apt transactions and file edits. flock refuses the
# second rather than letting them race; -n so it says so instead of hanging.
if [ "$dry_run" -eq 0 ] && [ -z "${CDL_NO_LOCK:-}" ]; then
    # A missing flock and a held lock are different problems and must not report the same
    # message. flock ships in util-linux and is always present on the supported platform,
    # so its absence means the environment is not what this script requires -- say that,
    # rather than claiming a concurrent run that does not exist.
    cdl_have flock || die "flock not found (util-linux). Cannot guarantee a single install
    is running, and two concurrent runs would interleave apt transactions and file edits.
    Set CDL_NO_LOCK=1 to proceed without that guarantee."

    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    exec 9>"$LOCK_FILE" || die "cannot open lock file $LOCK_FILE (need root?)"
    flock -n 9 || die "another cdl-linux install is already running (lock: $LOCK_FILE)"
fi

# --- preflight, before anything mutates -----------------------------------------------------
# 00-preflight is a module so it can be read and re-run like any other, but it is also run
# first and separately: nothing else may execute on an unsupported machine.
if [ -z "$only_module" ]; then
    dim "── preflight ──"
    if ! bash "$MODULE_DIR/00-preflight.sh"; then
        die "preflight failed; nothing has been changed"
    fi
fi

if [ "$dry_run" -eq 1 ]; then
    log "dry run: would execute, in this order:"
    for m in "${modules[@]}"; do printf '  %s\n' "$(basename "$m" .sh)"; done
    exit 0
fi

# --- run -------------------------------------------------------------------------------------
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="$(mktemp -d)"
record="$LOG_DIR/install-runs.jsonl"

declare -a names=() results=()
overall=0

for m in "${modules[@]}"; do
    name="$(basename "$m" .sh)"
    [ "$name" = "00-preflight" ] && [ -z "$only_module" ] && continue

    dim "── $name ──"
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    bash "$m"
    rc=$?

    case "$rc" in
        0)             result=ok ;;
        "$CDL_SKIP")   result=skipped ;;
        *)             result=failed ;;
    esac

    names+=("$name"); results+=("$result")

    printf '{"run":"%s","module":"%s","started":"%s","finished":"%s","result":"%s","exit":%d}\n' \
        "$CDL_RUN_ID" "$name" "$started" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$result" "$rc" \
        >> "$record"

    if [ "$result" = failed ]; then
        overall=1
        err "$name failed (exit $rc)"
        log ""
        log "    Later modules did NOT run: continuing past a failed module would build on"
        log "    a state this script cannot describe. Fix the cause and re-run just this"
        log "    module with:"
        log ""
        log "        sudo $0 --module $name"
        log ""
        log "    Modules are idempotent, so a full re-run is also safe."
        break
    fi
done

# --- summary ------------------------------------------------------------------------------
# Counts come from what actually ran. A module that never executed is absent rather than
# reported as anything.
log ""
dim "── summary (run $CDL_RUN_ID) ──"
n_ok=0; n_skip=0; n_fail=0
for i in "${!names[@]}"; do
    case "${results[$i]}" in
        ok)      ok      "${names[$i]}";       n_ok=$((n_ok+1)) ;;
        skipped) warn    "${names[$i]} (skipped)"; n_skip=$((n_skip+1)) ;;
        failed)  err     "${names[$i]}";       n_fail=$((n_fail+1)) ;;
    esac
done

not_run=$(( ${#modules[@]} - ${#names[@]} ))
[ -z "$only_module" ] && not_run=$(( not_run - 1 ))   # 00-preflight ran outside the loop
[ "$not_run" -lt 0 ] && not_run=0

log ""
log "  ok: $n_ok   skipped: $n_skip   failed: $n_fail   did not run: $not_run"
log "  record: $record"

exit "$overall"
