#!/usr/bin/env bash
# Remote access: Tailscale, key-only sshd, mosh (spec §7, §7.1, §7.2, §7.3; §12 H1a).
#
# --- tailscale up is not run here -----------------------------------------------------------
# `tailscale up` needs an interactive browser login the first time a node enrols, and this
# script may run unattended (--dry-run aside, install.sh itself never prompts). This module
# installs and enables tailscaled, then prints the exact command for the operator to run at
# the console. Key expiry is disabled per node in the Tailscale admin console (§7.1), not
# here -- there is no CLI flag for it, only an API/UI toggle scoped to the node once it
# exists, which it does not until `tailscale up` has run.
#
# --- the lockout guard -----------------------------------------------------------------------
# AllowGroups cdl + PasswordAuthentication no + PermitRootLogin no is only "key-only SSH" if
# someone is actually in group cdl. Getting the order wrong -- write the drop-in, then find
# out nobody qualifies -- locks out everyone including the console (console login is a
# separate password path per §7, but that does not help a machine reached only over SSH).
# So group membership is established and *verified* before the drop-in is ever written.
#
# --- mosh and firewalling, a decision, not an oversight --------------------------------------
# §7 requires mosh reachable "on the tailnet only". mosh-server has no host-bind flag old
# enough to rely on here, so that boundary can only be enforced by a firewall rule scoping
# UDP 60000-61000 to the tailscale0 interface. This module does not add one: nftables/ufw
# state is a single shared resource (one ruleset, one set of chains), and every module that
# starts poking at it independently is how that ruleset ends up self-contradictory. That
# belongs to one dedicated module that owns the whole box's firewall, once one exists -- not
# here. Until then the tailnet-only claim for mosh is unenforced at the network layer, and
# that gap is real: say so, rather than leaving it silently assumed. sshd's own AllowGroups
# and key-only auth are unaffected either way.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

cdl_need_root "45-remote"

# --- (a) Tailscale, from its own apt repo -----------------------------------------------------
# Verified against the real repo (2026-09): pkgs.tailscale.com/stable/ubuntu/resolute.* exists
# and resolves for "resolute", the codename 00-preflight's supported release (26.04) reports as
# VERSION_CODENAME in /etc/os-release. Read from the machine rather than hard-coded so a later
# 26.04 point release with the same codename needs no change here.
codename="$(awk -F= '$1=="VERSION_CODENAME"{gsub(/"/,"",$2);print $2}' /etc/os-release 2>/dev/null)"
[ -n "$codename" ] || die "45-remote: cannot read VERSION_CODENAME from /etc/os-release"

cdl_apt_source tailscale \
    "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" \
    "Types: deb
URIs: https://pkgs.tailscale.com/stable/ubuntu
Suites: $codename
Components: main"

cdl_apt_install tailscale

if cdl_have_systemd; then
    cdl_enable_now tailscaled
    ok "tailscaled enabled"
else
    warn "45-remote: no systemd here; tailscale installed but tailscaled was not started"
fi

log ""
log "    Tailscale is installed but NOT enrolled: that step needs an interactive login and"
log "    cannot run unattended. At the console or over the LAN, run:"
log ""
log "        sudo tailscale up"
log ""
log "    Then, in the Tailscale admin console, disable key expiry for this node (spec §7.1)"
log "    -- it is a server, and a node that logs itself out on a timer with nobody in the"
log "    building is a machine that needs a car journey. Until enrolled, the machine stays"
log "    reachable on the LAN (sshd is not tailnet-only; see §7.1)."
log ""

# --- (b) sshd: key-only, gated to group cdl ---------------------------------------------------
# Who ends up in group cdl. Prefer the human who invoked sudo; fall back to uid 1000, the
# first normal account on a fresh Ubuntu install. Refusing here, before any file is written,
# is what makes the guard below meaningful rather than theatre.
candidate="${SUDO_USER:-}"
if [ -z "$candidate" ] || [ "$candidate" = root ]; then
    candidate="$(getent passwd 1000 | cut -d: -f1)"
fi
if [ -z "$candidate" ] || ! id "$candidate" >/dev/null 2>&1; then
    die "45-remote: no candidate user found (checked \$SUDO_USER and uid 1000); refusing to write an sshd config that would leave nobody in AllowGroups cdl"
fi

getent group cdl >/dev/null 2>&1 || { groupadd cdl || die "45-remote: cannot create group cdl"; dim "    created group cdl"; }
usermod -aG cdl "$candidate" || die "45-remote: cannot add $candidate to group cdl"

id -nG "$candidate" | tr ' ' '\n' | grep -qx cdl \
    || die "45-remote: $candidate is still not in group cdl after usermod; refusing to write AllowGroups cdl (this would lock out all SSH access)"
ok "user $candidate is in group cdl"

# Group membership is necessary but not sufficient: PasswordAuthentication no means
# $candidate also needs a way to actually authenticate. If there is no key and no
# AuthorizedKeysCommand, writing the drop-in trades a working password login for nothing.
candidate_home="$(getent passwd "$candidate" | cut -d: -f6)"
authorized_keys="$candidate_home/.ssh/authorized_keys"
has_key_line=0
if [ -s "$authorized_keys" ] && grep -Eq '^(ssh-|ecdsa-|sk-)' "$authorized_keys"; then
    has_key_line=1
fi
akc_line="$(sshd -T 2>/dev/null | awk '$1=="authorizedkeyscommand"{$1="";print}')"
has_akc=0
case "$akc_line" in ''|' none') has_akc=0 ;; *) has_akc=1 ;; esac

if [ "$has_key_line" -eq 0 ] && [ "$has_akc" -eq 0 ]; then
    if [ "${CDL_SSH_FORCE:-}" = "1" ]; then
        warn "45-remote: $candidate has no key in $authorized_keys and no AuthorizedKeysCommand is configured; proceeding anyway because CDL_SSH_FORCE=1 -- add a key now or you will be locked out of SSH"
    else
        die "45-remote: $candidate has no key in $authorized_keys and sshd has no AuthorizedKeysCommand configured. Writing this drop-in now would lock out all SSH access (PasswordAuthentication is being set to no). Add a public key first, e.g.:
    sudo -u $candidate mkdir -p $candidate_home/.ssh && sudo chmod 700 $candidate_home/.ssh
    echo '<your public key>' | sudo -u $candidate tee -a $authorized_keys && sudo chmod 600 $authorized_keys
Then re-run this module. To proceed anyway (not recommended), set CDL_SSH_FORCE=1."
    fi
else
    ok "$candidate has SSH key access configured (authorized_keys or AuthorizedKeysCommand)"
fi

dropin=/etc/ssh/sshd_config.d/10-cdl.conf
dropin_existed=0
[ -f "$dropin" ] && dropin_existed=1

changed=0
if cdl_write_if_changed "$dropin" <<EOF
$CDL_MANAGED
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
AllowGroups cdl
EOF
then changed=1; fi

# Validate the file BEFORE touching the running daemon (spec §7 B1a). A bad write here is
# reverted rather than left for the next reboot to discover.
sshd_t_err="$(mktemp)"
if ! sshd -t 2>"$sshd_t_err"; then
    err "sshd -t rejected the new config:"
    sed 's/^/    /' "$sshd_t_err" >&2
    rm -f "$sshd_t_err"
    if [ "$dropin_existed" -eq 1 ]; then
        # Backup filenames end in a UTC timestamp (see cdl_backup_file), which sorts
        # lexically in the same order as chronologically -- so the glob's own (sorted)
        # order picks out the most recent one, with no need for `ls -t`.
        shopt -s nullglob
        backups=("${dropin}".cdl-backup-*)
        shopt -u nullglob
        if [ "${#backups[@]}" -gt 0 ]; then
            cp -a "${backups[-1]}" "$dropin"
        else
            rm -f "$dropin"
        fi
    else
        rm -f "$dropin"
    fi
    die "45-remote: refusing to reload sshd with an invalid config; previous state restored"
fi
rm -f "$sshd_t_err"

if [ "$changed" -eq 1 ] && cdl_have_systemd; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
        || die "45-remote: sshd config changed but neither ssh.service nor sshd.service could be reloaded"
    ok "sshd reloaded with the new drop-in"
elif [ "$changed" -eq 1 ]; then
    warn "45-remote: no systemd here; sshd config written but not reloaded"
else
    ok "sshd drop-in already up to date"
fi

# Assert the EFFECTIVE config, not the file: an Include or Match elsewhere can differ from
# what was just written (§7 B1a).
effective="$(sshd -T 2>/dev/null)"
[ -n "$effective" ] || die "45-remote: sshd -T produced no output; cannot verify the effective config"

pwauth="$(awk '$1=="passwordauthentication"{print $2}' <<<"$effective")"
[ "$pwauth" = "no" ] || die "45-remote: effective sshd config has passwordauthentication=$pwauth, not no"

allowgroups="$(awk '$1=="allowgroups"{$1="";print}' <<<"$effective")"
case " $allowgroups " in
    *' cdl '*) : ;;
    *) die "45-remote: effective sshd config's AllowGroups ('$allowgroups') does not include cdl" ;;
esac
ok "effective sshd config: passwordauthentication no, AllowGroups includes cdl"

# --- (c) mosh --------------------------------------------------------------------------------
cdl_apt_install mosh
ok "mosh installed (UDP 60000-61000, per-session; see the firewalling note above)"
warn "45-remote: mosh's UDP 60000-61000 is NOT restricted to the tailnet by this module; it is reachable from the LAN too until a firewall rule is added elsewhere (see the comment at the top of this file)"

# --- (d) cdl-net-check -------------------------------------------------------------------------
cdl_write_if_changed /usr/local/bin/cdl-net-check <<'EOF'
#!/usr/bin/env bash
# managed by cdl-linux; edits here are overwritten by ./install.sh
#
# One place to answer "is this box reachable the way spec §7 says it should be": Tailscale
# enrolment, sshd's *effective* auth settings, and what is actually bound where. Exits
# nonzero if password authentication is enabled -- everything else here is informational.
set -uo pipefail

echo "== tailscale =="
if ! command -v tailscale >/dev/null 2>&1; then
    echo "tailscale not installed"
elif tailscale status >/dev/null 2>&1; then
    tailscale status
else
    echo "not enrolled"
fi

echo
echo "== sshd effective auth settings (sshd -T) =="
effective="$(sshd -T 2>/dev/null)"
awk '$1=="passwordauthentication" || $1=="kbdinteractiveauthentication" || \
     $1=="pubkeyauthentication"    || $1=="permitrootlogin"             || \
     $1=="allowgroups"' <<<"$effective"

echo
echo "== listening sockets: 22 (ssh), 11434 (ollama), 8081 (llama-swap), mosh (UDP 60000-61000) =="
{ ss -tlnp 2>/dev/null; ss -ulnp 2>/dev/null; } | awk '
NR==1 { next }
{
    if (match($0, /:(22|11434|8081)[[:space:]]/)) { print; next }
    # mosh only ever opens ports inside 60000-61000; a plain 6#### match is precise enough
    # in practice without parsing the address:port field out by column.
    if (match($0, /:6[0-9][0-9][0-9][0-9][[:space:]]/)) { print }
}'

pwauth="$(awk '$1=="passwordauthentication"{print $2}' <<<"$effective")"
if [ "$pwauth" = "yes" ]; then
    echo
    echo "FAIL: PasswordAuthentication is enabled" >&2
    exit 1
fi
exit 0
EOF
chmod 0755 /usr/local/bin/cdl-net-check
ok "cdl-net-check installed"

exit 0
