#!/usr/bin/env bash
# The GPU lock: `cdl-gpu train` (spec §6.1).
#
# One policy, stated once: inference stops for training, and comes back afterwards. The
# thing that makes it trustworthy is *how* it comes back. §6.1 requires the restart on
# "normal exit, non-zero exit, signal termination and SIGKILL -- the last being the case a
# shell trap would miss", so the restart is a systemd unit's ExecStopPost. The job runs as a
# transient unit created by systemd-run; systemd, not the wrapper, runs the restore when the
# unit stops, and it runs it whether the job exited 0, exited 3, was SIGTERMed or was
# SIGKILLed, because in every one of those cases the *unit* stops and systemd owns that
# transition. A trap in the wrapper cannot survive the wrapper being killed, which is why
# the restore lives in /usr/local/lib/cdl/gpu-restore and is invoked by systemd.
#
# This module does NOT skip on a machine with no NVIDIA GPU. The contract it installs is
# about serving-versus-training, not about CUDA: the arm64 VM exercises every branch of it
# (tests/vm/verify-models.sh) precisely because none of it needs a GPU to be correct.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

cdl_need_root "35-gpu-lock"

changed=0

# §6.1: the lock file is mode 0664, group `cdl`. The group is what lets an operator account
# take the lock without being root; membership is the console slice's business (§9.1), not
# this module's.
if ! getent group cdl >/dev/null; then
    groupadd --system cdl || die "cannot create group cdl"
    dim "    created group cdl"
    changed=1
fi

# /run is a tmpfs: without a tmpfiles.d rule the lock and the holder record vanish at boot
# and the first caller after a reboot creates them with whatever mode it happens to have.
if cdl_write_if_changed /etc/tmpfiles.d/cdl-gpu.conf <<'GPU_TMPFILES'; then changed=1; fi
# managed by cdl-linux; edits here are overwritten by ./install.sh
# spec §6.1: the lock file, and the directory holding the holder record and the list of
# services a running job stopped.
d /run/cdl     0755 root cdl -
d /run/cdl/gpu 0770 root cdl -
f /run/cdl/gpu.lock 0664 root cdl -
GPU_TMPFILES

# --- the restore, which systemd calls ------------------------------------------------------
# Separate file, because ExecStopPost= needs something it can exec after the job is gone.
# The delimiter is a contract with tests/test-models-gpu-lock.sh, which extracts and lints it.
mkdir -p /usr/local/lib/cdl
if cdl_write_if_changed /usr/local/lib/cdl/gpu-restore <<'CDL_GPU_RESTORE_SH'; then changed=1; fi
#!/usr/bin/env bash
# managed by cdl-linux; edits here are overwritten by ./install.sh
#
# Restart exactly the services `cdl-gpu train` stopped for one job, and forget the job.
#
#   gpu-restore <job-id>
#
# systemd runs this as the transient unit's ExecStopPost, so it runs on every way a job can
# end -- exit 0, exit non-zero, SIGTERM, SIGKILL -- because all four stop the unit and
# systemd owns that transition (spec §6.1). It is deliberately dull and never fails the
# unit: a service that will not come back is reported, loudly, and the next one is still
# tried.

set -uo pipefail

id="${1:-}"
[ -n "$id" ] || { echo "usage: gpu-restore <job-id>" >&2; exit 64; }

run_dir="${CDL_GPU_RUN:-/run/cdl/gpu}"
state="$run_dir/stopped-$id"

say() {
    printf 'cdl-gpu: %s\n' "$*"
    command -v logger >/dev/null 2>&1 && logger -t cdl-gpu -- "$*"
}

if [ ! -f "$state" ]; then
    # Nothing recorded: either the job stopped nothing, or a previous restore already ran.
    # Both are fine, and neither is a failure.
    say "job $id: no services were recorded as stopped; nothing to restart"
else
    while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        if systemctl start "$unit"; then
            say "job $id: restarted $unit (result=${SERVICE_RESULT:-unknown} status=${EXIT_STATUS:-unknown})"
        else
            say "job $id: FAILED to restart $unit -- start it by hand: systemctl start $unit"
        fi
    done < "$state"
    rm -f "$state"
fi

# The holder record belongs to whichever job is running now. Remove it only if it is still
# this job's, so a restore arriving late cannot erase a newer job's record.
holder="$run_dir/holder"
if [ -f "$holder" ] && grep -qx "job=$id" "$holder" 2>/dev/null; then
    rm -f "$holder"
fi
exit 0
CDL_GPU_RESTORE_SH
chmod 0755 /usr/local/lib/cdl/gpu-restore

# --- the wrapper ------------------------------------------------------------------------------
if cdl_write_if_changed /usr/local/bin/cdl-gpu <<'CDL_GPU_SH'; then changed=1; fi
#!/usr/bin/env bash
# managed by cdl-linux; edits here are overwritten by ./install.sh
#
# The GPU lock (spec §6.1). Inference stops for training, and comes back afterwards.
#
#   cdl-gpu train [--force] [--dry-run] -- <command...>
#   cdl-gpu status
#
# --force     skip the confirmation. Required when there is no terminal to ask at.
# --dry-run   print the plan -- what would be stopped, the unit name, the command -- and
#             change nothing: no lock, no stop, no job.
#
# How the restart survives SIGKILL. The job is a transient systemd unit whose ExecStopPost
# is /usr/local/lib/cdl/gpu-restore. systemd runs that when the unit stops, which happens on
# a clean exit, a non-zero exit, SIGTERM and SIGKILL alike. A shell trap in this script
# would miss the last one, so the trap here is only a safety net for the window before the
# job exists, and it disarms itself the moment the job starts.

set -uo pipefail

CDL_GPU_LOCK="${CDL_GPU_LOCK:-/run/cdl/gpu.lock}"
CDL_GPU_RUN="${CDL_GPU_RUN:-/run/cdl/gpu}"
CDL_GPU_RESTORE="${CDL_GPU_RESTORE:-/usr/local/lib/cdl/gpu-restore}"
# Overridable so the fixture test can point it at services that do not exist.
read -r -a CDL_GPU_SERVICE_LIST <<<"${CDL_GPU_SERVICES:-ollama.service llama-swap.service}"

die() { printf 'cdl-gpu: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '4,14p' "$0" | sed -E 's/^#[[:space:]]?//'
}

# --- the one piece of logic worth a unit test --------------------------------------------
# Which model services are running right now, one per line, in the order they are listed.
# `activating` and `reloading` count as running: a service in either state will be stopped
# by `systemctl stop`, so it must also be on the list of things to bring back, or a job
# started during a boot would silently leave the endpoint down.
gpu_active_services() {
    local unit state
    for unit in "${CDL_GPU_SERVICE_LIST[@]}"; do
        state="$(systemctl is-active "$unit" 2>/dev/null)"
        case "$state" in
            active|activating|reloading) printf '%s\n' "$unit" ;;
            *) ;;
        esac
    done
    return 0
}

# Who holds the lock, as recorded in the holder file. Empty if nobody has written one.
gpu_holder_report() {
    [ -f "$CDL_GPU_RUN/holder" ] && cat "$CDL_GPU_RUN/holder"
}

# --- status -------------------------------------------------------------------------------
cmd_status() {
    local held=1
    if [ -e "$CDL_GPU_LOCK" ]; then
        # A separate fd in a subshell: taking and dropping the lock here must not disturb
        # this process's own state.
        if ( exec 8>>"$CDL_GPU_LOCK"; flock -n 8 ) 2>/dev/null; then held=0; fi
    fi

    if [ "$held" -eq 0 ]; then
        printf 'gpu lock:  free (%s)\n' "$CDL_GPU_LOCK"
    else
        printf 'gpu lock:  HELD (%s)\n' "$CDL_GPU_LOCK"
    fi

    local holder
    holder="$(gpu_holder_report)"
    if [ -n "$holder" ]; then
        printf 'holder:\n'
        printf '%s\n' "$holder" | sed 's/^/  /'
    elif [ "$held" -eq 1 ]; then
        printf 'holder:    held, but no record in %s/holder\n' "$CDL_GPU_RUN"
    fi

    local stopped found=0 f
    printf 'stopped for the running job:\n'
    for f in "$CDL_GPU_RUN"/stopped-*; do
        [ -e "$f" ] || continue
        found=1
        stopped="$(tr '\n' ' ' < "$f")"
        printf '  %s: %s\n' "$(basename "$f" | sed 's/^stopped-//')" "$stopped"
    done
    [ "$found" -eq 1 ] || printf '  (nothing)\n'

    printf 'services now:\n'
    local unit
    for unit in "${CDL_GPU_SERVICE_LIST[@]}"; do
        printf '  %-20s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || echo unknown)"
    done
}

# --- train ---------------------------------------------------------------------------------
launched=0
job_id=""

# The window this covers is small and real: between recording what we stopped and systemd
# owning the job, nothing else would put the services back. Once the job exists, systemd's
# ExecStopPost is the only restore path and this one disarms -- two restores racing to start
# the same units is exactly the confusion §6.1 wants to avoid.
safety_net() {
    [ "$launched" -eq 1 ] && return 0
    [ -n "$job_id" ] || return 0
    [ -f "$CDL_GPU_RUN/stopped-$job_id" ] || return 0
    printf 'cdl-gpu: the job never started; restoring the services it stopped\n' >&2
    "$CDL_GPU_RESTORE" "$job_id"
}

cmd_train() {
    local force=0 dry=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --force)     force=1; shift ;;
            --dry-run)   dry=1; shift ;;
            -h|--help)   usage; exit 0 ;;
            --)          shift; break ;;
            -*)          die "unknown option '$1' (try: cdl-gpu train --help)" ;;
            *)           break ;;
        esac
    done
    [ $# -gt 0 ] || die "nothing to run. Usage: cdl-gpu train [--force] -- <command...>"

    local running=()
    while IFS= read -r unit; do [ -n "$unit" ] && running+=("$unit"); done < <(gpu_active_services)

    job_id="$(date +%Y%m%d-%H%M%S)-$$"
    local unit_name="cdl-train-$job_id"

    if [ "$dry" -eq 1 ]; then
        printf 'would stop:     %s\n' "${running[*]:-(nothing running)}"
        printf 'would take:     %s (exclusive)\n' "$CDL_GPU_LOCK"
        printf 'would run as:   %s\n' "$unit_name"
        printf 'would restore:  %s %s   (as ExecStopPost)\n' "$CDL_GPU_RESTORE" "$job_id"
        printf 'command:        %s\n' "$*"
        printf '\ndry run: nothing was stopped, locked or started.\n'
        exit 0
    fi

    [ "$(id -u)" -eq 0 ] || die "training needs root, to stop the model services and create the job unit. Try: sudo cdl-gpu train -- $*"
    command -v systemd-run >/dev/null 2>&1 || die "systemd-run not found; the restart-on-SIGKILL guarantee needs it"

    mkdir -p "$CDL_GPU_RUN"

    # §6.1: exclusive, always, and released by the kernel when this process ends however it
    # ends. fd 9 stays open for the life of the run.
    exec 9>>"$CDL_GPU_LOCK" || die "cannot open the lock file $CDL_GPU_LOCK"
    if ! flock -n 9; then
        printf 'cdl-gpu: the GPU is already held. Refusing to start a second training run.\n' >&2
        local holder
        holder="$(gpu_holder_report)"
        [ -n "$holder" ] && printf '%s\n' "$holder" | sed 's/^/  /' >&2
        printf '  see it with: cdl-gpu status\n' >&2
        exit 1
    fi

    # §6.1: the endpoint may be serving another device mid-request, so name what will stop
    # and ask. Without a terminal there is nobody to ask, and guessing "yes" on a machine
    # answering requests from elsewhere is not a default worth having.
    if [ "${#running[@]}" -gt 0 ] && [ "$force" -eq 0 ]; then
        printf 'This will stop, for the duration of the job:\n' >&2
        printf '  %s\n' "${running[@]}" >&2
        if [ -t 0 ]; then
            local reply=""
            printf 'Continue? [y/N] ' >&2
            read -r reply
            case "$reply" in y|Y|yes|YES) ;; *) die "cancelled; nothing was stopped" ;; esac
        else
            die "refusing to stop a live endpoint without being asked. Re-run with --force."
        fi
    fi

    trap safety_net EXIT

    printf 'job=%s\n' "$job_id"                       > "$CDL_GPU_RUN/holder"
    {
        printf 'unit=%s\n' "$unit_name"
        printf 'user=%s\n' "${SUDO_USER:-root}"
        printf 'started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'command=%s\n' "$*"
        printf 'stopped=%s\n' "${running[*]:-none}"
    } >> "$CDL_GPU_RUN/holder"

    # Written before the stop, so a crash between the two still leaves a record a person --
    # or the safety net -- can act on.
    : > "$CDL_GPU_RUN/stopped-$job_id"
    if [ "${#running[@]}" -gt 0 ]; then
        printf '%s\n' "${running[@]}" > "$CDL_GPU_RUN/stopped-$job_id"
        printf 'cdl-gpu: stopping %s\n' "${running[*]}" >&2
        # systemctl stop is synchronous: it returns when the units have exited, which is
        # what §6.1 means by "waits for them to exit, then takes the lock".
        systemctl stop "${running[@]}" || die "could not stop ${running[*]}; nothing else was done"
    fi

    local run_args=(
        systemd-run --collect --wait --unit "$unit_name"
        --description "cdl training job $job_id"
        -p "ExecStopPost=$CDL_GPU_RESTORE $job_id"
        -p "WorkingDirectory=${PWD:-/}"
    )
    # Keep the operator's identity: `sudo cdl-gpu train -- python train.py` must not write
    # checkpoints owned by root into their home.
    [ -n "${SUDO_USER:-}" ] && run_args+=(-p "User=$SUDO_USER")
    # --pty when there is a terminal, so an interactive run behaves like the command did;
    # --pipe otherwise, so a scripted run's output still goes to the caller's stdout rather
    # than only to the journal. Both propagate the job's exit status.
    if [ -t 1 ]; then run_args+=(--pty); else run_args+=(--pipe); fi

    launched=1
    "${run_args[@]}" -- "$@"
    local rc=$?

    # systemd-run --wait returns after the unit has fully stopped, and ExecStopPost runs as
    # part of that stop, so by here the services are back.
    printf 'cdl-gpu: job %s finished (exit %d)\n' "$job_id" "$rc" >&2
    exit "$rc"
}

# --- main ------------------------------------------------------------------------------------
cdl_gpu_main() {
    case "${1:-}" in
        train)          shift; cmd_train "$@" ;;
        status)         shift; cmd_status "$@" ;;
        -h|--help|help) usage ;;
        "")             usage; exit 1 ;;
        *)              die "unknown command '$1' (try: train, status)" ;;
    esac
}

# Sourceable, so tests/test-models-gpu-lock.sh can exercise gpu_active_services against a
# fixture systemctl instead of asserting on a grep of this file.
[ -n "${CDL_GPU_LIB_ONLY:-}" ] || cdl_gpu_main "$@"
CDL_GPU_SH
chmod 0755 /usr/local/bin/cdl-gpu

if cdl_have_systemd; then
    systemd-tmpfiles --create /etc/tmpfiles.d/cdl-gpu.conf \
        || die "systemd-tmpfiles could not create the lock file and its directory"
    [ -e /run/cdl/gpu.lock ] || die "the tmpfiles rule ran but /run/cdl/gpu.lock is missing"
else
    warn "no systemd here: the tmpfiles rule is written but /run/cdl was not created"
fi

if [ "$changed" -eq 0 ]; then
    ok "35-gpu-lock: already installed; nothing changed"
else
    ok "35-gpu-lock: cdl-gpu installed; restart is systemd's ExecStopPost, not a shell trap"
fi
exit 0
