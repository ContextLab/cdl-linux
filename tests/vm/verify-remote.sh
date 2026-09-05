#!/usr/bin/env bash
# Runs INSIDE an installed guest, as root, after ./install.sh has run there.
#
# Checks the claims 45-remote.sh makes about the *effective* running state (spec §7, §7.1,
# §12 H1a) -- not the drop-in file, since an Include or Match could make the two differ.
# The guest logs in over SSH as user cdl (scripts/vm/lib.sh's VM_USER), so this is also
# where a broken lockout guard would show up: if 45-remote ever left cdl out of group cdl,
# the harness's own SSH access would be the first thing to break.
#
# Invoked by tests/run-vm.sh.

set -uo pipefail

pass=0; fail=0
ok()  { printf '  \033[32mOK\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

[ "$(id -u)" -eq 0 ] || { printf 'verify-remote: must run as root inside the guest\n' >&2; exit 1; }

MODULE=/home/cdl/cdl-linux/install/modules/45-remote.sh

# --- what the run record says happened -------------------------------------------------------
RECORD=/var/log/cdl/install-runs.jsonl
if [ -f "$RECORD" ]; then
    result="$(python3 - "$RECORD" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
# The module's most recent record, whatever run it belongs to: requiring it in the LAST run
# fails under per-module iteration, where the last run is whichever module ran most recently.
mine = [r for r in rows if r["module"] == "45-remote"]
print(mine[-1]["result"] if mine else "did-not-run")
PY
)"
    if [ "$result" = ok ]; then ok "45-remote recorded 'ok'"; else bad "45-remote recorded '$result'"; fi
else
    bad "no run record at $RECORD"
fi

# --- effective sshd config, not the file (§7 B1a) ----------------------------------------------
effective="$(sshd -T 2>/dev/null)"
if [ -n "$effective" ]; then
    ok "sshd -T produced output"
else
    bad "sshd -T produced no output"
fi

if grep -i '^passwordauthentication' <<<"$effective" | grep -qiw no; then
    ok "effective passwordauthentication is no"
else
    bad "effective passwordauthentication is not no: $(grep -i passwordauthentication <<<"$effective")"
fi

allowgroups_line="$(grep -i '^allowgroups' <<<"$effective")"
if grep -qw cdl <<<"$allowgroups_line"; then
    ok "effective AllowGroups contains cdl ($allowgroups_line)"
else
    bad "effective AllowGroups does not contain cdl: $allowgroups_line"
fi

# --- the lockout guard did not lock out the harness's own login user --------------------------
if id cdl >/dev/null 2>&1; then
    if id -nG cdl | tr ' ' '\n' | grep -qx cdl; then
        ok "user cdl is a member of group cdl"
    else
        bad "user cdl exists but is NOT in group cdl: $(id cdl)"
    fi
else
    bad "user cdl does not exist in this guest"
fi

# --- the key-or-AuthorizedKeysCommand guard: this is *why* the harness could still log in -----
cdl_home="$(getent passwd cdl | cut -d: -f6)"
if [ -s "$cdl_home/.ssh/authorized_keys" ] && grep -Eq '^(ssh-|ecdsa-|sk-)' "$cdl_home/.ssh/authorized_keys"; then
    ok "cdl has a usable key in $cdl_home/.ssh/authorized_keys (the guard's precondition held)"
else
    bad "cdl has no usable authorized_keys line at $cdl_home/.ssh/authorized_keys"
fi

# --- tailscale --------------------------------------------------------------------------------
if systemctl is-active -q tailscaled 2>/dev/null; then
    ok "tailscaled is active"
else
    bad "tailscaled is not active: $(systemctl is-active tailscaled 2>&1)"
fi
if command -v tailscale >/dev/null 2>&1; then ok "tailscale CLI is installed"; else bad "tailscale CLI is missing"; fi

# --- mosh ---------------------------------------------------------------------------------------
if command -v mosh-server >/dev/null 2>&1; then
    ok "mosh-server is present"
else
    bad "mosh-server is not installed"
fi

# --- cdl-net-check --------------------------------------------------------------------------------
if [ -x /usr/local/bin/cdl-net-check ]; then
    ok "cdl-net-check is installed and executable"
    if out="$(/usr/local/bin/cdl-net-check 2>&1)"; then
        ok "cdl-net-check exits 0"
    else
        bad "cdl-net-check exited nonzero: $out"
    fi
else
    bad "/usr/local/bin/cdl-net-check is not installed"
fi

# --- idempotence, for this module specifically -------------------------------------------------
second="$(bash "$MODULE" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then ok "a second 45-remote run exits 0"; else bad "a second 45-remote run exited $rc: $second"; fi
if grep -qE '^\s+(installing:|fetched |created group cdl)' <<<"$second"; then
    bad "a second 45-remote run changed something: $second"
else
    ok "a second 45-remote run changed nothing"
fi
if grep -q 'sshd reloaded with the new drop-in' <<<"$second"; then
    bad "a second run reloaded sshd; the drop-in should already have been up to date"
else
    ok "a second run did not reload sshd (drop-in already up to date)"
fi

printf '\n  verify-remote: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
