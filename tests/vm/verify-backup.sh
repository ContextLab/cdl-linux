#!/usr/bin/env bash
# Verify, on the booted system, that install/modules/60-backup.sh did what spec §10 asks.
#
# Runs INSIDE the guest as root (tests/run-vm.sh drives it there via
# scripts/vm/run-in-guest.sh, which already carries sudo). The guest is left deliberately
# unconfigured by install/autoinstall -- no restic.pass, no rclone.conf, the placeholder
# bucket name untouched -- so "unconfigured, and the timer knows it" is exactly what this
# checks. The real backup round trip against a throwaway bucket is
# scripts/vm/test-backup.sh, which needs credentials this script does not have.

set -uo pipefail
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$*"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$*"; }

if command -v restic >/dev/null 2>&1; then ok "restic is installed"; else bad "restic is not installed"; fi
if command -v rclone >/dev/null 2>&1; then ok "rclone is installed"; else bad "rclone is not installed"; fi

if [ -f /etc/cdl/backup.conf ]; then
    mode="$(stat -c%a /etc/cdl/backup.conf)"
    if [ "$mode" = "600" ]; then
        ok "/etc/cdl/backup.conf is mode 0600"
    else
        bad "/etc/cdl/backup.conf is mode $mode, want 0600"
    fi
else
    bad "/etc/cdl/backup.conf does not exist"
fi

if [ -f /etc/cdl/backup.exclude ]; then
    if grep -q 'sessions' /etc/cdl/backup.exclude; then
        ok "backup.exclude carries the session transcript path"
    else
        bad "backup.exclude does not mention the session transcript path"
    fi
else
    bad "/etc/cdl/backup.exclude does not exist"
fi

state="$(systemctl is-enabled cdl-backup.timer 2>&1)"
case "$state" in
    disabled|*"not-found"*|*"No such file"*) ok "cdl-backup.timer is not enabled while unconfigured (got '$state')" ;;
    *) bad "cdl-backup.timer should not be enabled yet (got '$state')" ;;
esac

if command -v cdl-backup >/dev/null 2>&1; then
    if cdl-backup status >/tmp/cdl-backup-status.out 2>&1; then
        ok "cdl-backup status exits 0"
    else
        bad "cdl-backup status exited nonzero: $(cat /tmp/cdl-backup-status.out)"
    fi
    rm -f /tmp/cdl-backup-status.out
else
    bad "cdl-backup is not on PATH"
fi

printf '\n== backup verification: %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
