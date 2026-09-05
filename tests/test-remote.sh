#!/usr/bin/env bash
# 45-remote.sh: static checks that run on macOS, without apt/systemd/sshd. The module's
# actual effect on a real machine is exercised by tests/vm/verify-remote.sh, in the guest.

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$repo/install/modules/45-remote.sh"
pass=0; fail=0
ok()  { printf '  \033[32mOK\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

if [ ! -f "$S" ]; then
    bad "install/modules/45-remote.sh does not exist"
    printf '\n  test-remote: %d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi

# has(): a source-file grep, reported as one ok/bad line.
has() {
    local desc="$1" pattern="$2"
    if grep -qE "$pattern" "$S"; then ok "$desc"; else bad "$desc"; fi
}
lacks() {
    local desc="$1" pattern="$2"
    if grep -qE "$pattern" "$S"; then bad "$desc"; else ok "$desc"; fi
}

# --- module contract ---------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    sc_out="$(shellcheck -x "$S" 2>&1)"
    if [ -z "$sc_out" ]; then
        ok "shellcheck -x is clean"
    else
        bad "shellcheck -x reported issues:"
        while IFS= read -r line; do printf '        %s\n' "$line"; done <<<"$sc_out"
    fi
else
    bad "shellcheck not installed; cannot verify"
fi

has "sets -uo pipefail"                              '^set -uo pipefail'
has "has the source-path shellcheck directive"       '# shellcheck source-path=SCRIPTDIR source=\.\./lib\.sh'
# shellcheck disable=SC2016  # a literal grep pattern; expansion is exactly what must not happen
has "sources ../lib.sh"                              'source "\$\(dirname "\$0"\)/\.\./lib\.sh"'
has "calls cdl_need_root"                            'cdl_need_root'
has "exits 0 on success"                             '^exit 0$'

# --- (a) tailscale ------------------------------------------------------------------------
has "adds the tailscale apt source via cdl_apt_source" 'cdl_apt_source tailscale'
has "points at the real tailscale apt repo"            'pkgs\.tailscale\.com/stable/ubuntu'
has "uses the .noarmor.gpg key form"                   'noarmor\.gpg'
has "installs the tailscale package"                   'cdl_apt_install tailscale'
has "enables tailscaled"                               'cdl_enable_now tailscaled'
has "prints the exact enrolment command for the operator" 'sudo tailscale up'
lacks "the module does not run tailscale up itself"    '^[[:space:]]*tailscale up'
has "notes that key expiry is disabled in the admin console (§7.1)" '[Kk]ey expiry'

# --- (b) sshd -------------------------------------------------------------------------------
for directive in 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PubkeyAuthentication yes' 'PermitRootLogin no' 'AllowGroups cdl'; do
    if grep -qF "$directive" "$S"; then ok "drop-in sets '$directive'"; else bad "drop-in is missing '$directive'"; fi
done
# shellcheck disable=SC2016  # a literal grep pattern; expansion is exactly what must not happen
has "the drop-in carries the CDL_MANAGED header" '\$CDL_MANAGED'
has "writes the drop-in at the specified path"   '/etc/ssh/sshd_config\.d/10-cdl\.conf'

# The lockout guard: group membership must be established and checked BEFORE the drop-in is
# written, and a failed check must die rather than proceed.
has "a die() names the lockout risk" 'die.*lock'

# shellcheck disable=SC2016  # literal grep patterns; expansion is exactly what must not happen
guard_line="$(grep -n 'id -nG "\$candidate"' "$S" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016
write_line="$(grep -n 'cdl_write_if_changed "\$dropin"' "$S" | head -1 | cut -d: -f1)"
if [ -n "$guard_line" ] && [ -n "$write_line" ] && [ "$guard_line" -lt "$write_line" ]; then
    ok "group membership is verified before the drop-in is written"
else
    bad "cannot confirm the group check runs before the drop-in write (guard@${guard_line:-?} write@${write_line:-?})"
fi
has "adds the candidate user to group cdl" 'usermod -aG cdl'
if grep -q 'SUDO_USER' "$S" && grep -q 'getent passwd 1000' "$S"; then
    ok "picks the candidate user from \$SUDO_USER or uid 1000"
else
    bad "does not derive the candidate user from \$SUDO_USER / uid 1000"
fi

has "validates with sshd -t before reloading"       'sshd -t'
has "verifies the EFFECTIVE config with sshd -T"    'sshd -T'
# shellcheck disable=SC2016  # a literal grep pattern; expansion is exactly what must not happen
has "dies unless the effective passwordauthentication is no" '\$pwauth" = "no"'

sshT_line="$(grep -n 'sshd -T' "$S" | tail -1 | cut -d: -f1)"
sshTest_line="$(grep -n 'sshd -t ' "$S" | head -1 | cut -d: -f1)"
if [ -n "$sshTest_line" ] && [ -n "$sshT_line" ] && [ "$sshTest_line" -lt "$sshT_line" ]; then
    ok "sshd -t runs before sshd -T (validate before verify-and-reload)"
else
    bad "sshd -t / sshd -T ordering looks wrong (t@${sshTest_line:-?} T@${sshT_line:-?})"
fi

has "reloads sshd only through systemctl reload"        'systemctl reload ssh'
# shellcheck disable=SC2016  # a literal grep pattern; expansion is exactly what must not happen
has "reload is gated on the drop-in actually changing"   'if \[ "\$changed" -eq 1 \]'

# --- (c) mosh -------------------------------------------------------------------------------
has "installs mosh"                                  'cdl_apt_install mosh'
has "documents mosh's UDP range"                     '60000-61000'
has "documents the tailnet-only requirement for mosh" '[Tt]ailnet only|tailscale0'

# --- (d) cdl-net-check ------------------------------------------------------------------------
has "ships /usr/local/bin/cdl-net-check"          '/usr/local/bin/cdl-net-check'
has "makes cdl-net-check executable"              'chmod 0755 /usr/local/bin/cdl-net-check'
has "cdl-net-check reports tailscale status"      'tailscale status'
has "cdl-net-check reports 'not enrolled'"        'not enrolled'
has "cdl-net-check checks port 11434"             '11434'
has "cdl-net-check checks port 8081"              '8081'
has "cdl-net-check inspects tcp sockets"          'ss -tlnp'
has "cdl-net-check inspects udp sockets"          'ss -ulnp'
# shellcheck disable=SC2016  # a literal grep pattern; expansion is exactly what must not happen
if grep -q 'FAIL: PasswordAuthentication is enabled' "$S" && grep -q '"\$pwauth" = "yes"' "$S" && grep -q 'exit 1' "$S"; then
    ok "cdl-net-check exits nonzero when password auth is enabled"
else
    bad "cdl-net-check does not exit nonzero on password auth"
fi

printf '\n  test-remote: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
