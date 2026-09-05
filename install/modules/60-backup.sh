#!/usr/bin/env bash
# Nightly backup: restic over rclone, to a Hugging Face Storage Bucket (spec §10).
#
# restic cannot initialise a repository against the bucket directly (§10.5: its native S3
# backend mis-addresses the gateway); rclone's S3 backend can, and restic runs over it via
# the `rclone:` backend. Both packages are therefore installed here.
#
# This module writes configuration and the run tooling. It never writes a credential: the
# restic repository password goes in /etc/cdl/restic.pass by a person, and rclone's [hf]
# profile goes in /root/.config/rclone/rclone.conf by a person (§10.1). Until both exist --
# and until the placeholder bucket name in backup.conf is replaced -- the nightly timer is
# not enabled, because a timer that fires and fails every night is worse than one that
# never ran.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

cdl_need_root "60-backup"

cdl_apt_install restic rclone

# --- /etc/cdl/backup.conf ------------------------------------------------------------------
BACKUP_CONF="$CDL_ETC/backup.conf"
PLACEHOLDER_BUCKET="CHANGEME"

# The operator edits this file, so the installer must never rewrite it. It writes the
# CURRENT template to backup.conf.default on every run, and seeds backup.conf from it only
# when absent. (Cold review: cdl_write_if_changed here reverted RESTIC_REPOSITORY to the
# placeholder on the next ./install.sh while the timer stayed enabled -- nightly failures.)
cdl_write_if_changed "$BACKUP_CONF.default" <<CONF
# cdl-linux seeds this file once and never rewrites it; the installer's current template is
# beside it as backup.conf.default.
#
# cdl-backup (run|check|restore|status) reads this file. Edit it in place; no restart is
# needed, the next invocation picks it up.
#
# --- destination ---------------------------------------------------------------------
# restic reaches the bucket through rclone, not through its own S3 backend (spec §10.5:
# direct S3 cannot initialise a repository against the gateway). rclone's [hf] profile
# belongs at /root/.config/rclone/rclone.conf -- see spec §10.1 for the exact stanza
# (endpoint, region, force_path_style, list_version -- all required, not defaults). This
# file never holds a token; the credential lives only in that rclone config.
#
# Replace ${PLACEHOLDER_BUCKET} with the bucket name before backups can run.
RESTIC_REPOSITORY=rclone:hf:${PLACEHOLDER_BUCKET}/restic

# --- what is backed up ------------------------------------------------------------------
# /srv/models is deliberately absent (spec §10.3): weights are re-downloadable, and the
# one part that is not (/srv/models/keep) is out of scope for this backup.
BACKUP_PATHS="/home /etc"
CONF
chmod 0600 "$BACKUP_CONF.default"
if [ ! -e "$BACKUP_CONF" ]; then
    cp "$BACKUP_CONF.default" "$BACKUP_CONF"
    dim "    seeded $BACKUP_CONF (edited by hand from here on; the installer will not touch it)"
fi
chmod 0600 "$BACKUP_CONF"

# --- /etc/cdl/backup.exclude ---------------------------------------------------------------
EXCLUDE_FILE="$CDL_ETC/backup.exclude"

cdl_write_if_changed "$EXCLUDE_FILE" <<'EXCL'
# managed by cdl-linux; edits here are overwritten by ./install.sh
#
# Session transcripts are sensitive (spec §9.4) and are excluded from every backup, not
# merely a default one. Anchored with a leading / so it matches only the real /home tree,
# not any directory happening to share the name deeper in the path.
/home/*/.local/state/cdl/sessions

# Caches: re-creatable, so excluding them keeps the repository from growing forever.
# restic's --exclude-caches flag (used by cdl-backup run) also drops any directory tagged
# with CACHEDIR.TAG, which covers the Hugging Face model cache for free.
/home/*/.cache
__pycache__
node_modules
EXCL
chmod 0644 "$EXCLUDE_FILE"

# --- /usr/local/bin/cdl-backup --------------------------------------------------------------
# The script lives at install/cdl-backup.sh, a standalone file rather than a heredoc here,
# so it can be shellchecked and unit-tested directly.
CDL_BACKUP_BIN=/usr/local/bin/cdl-backup

cdl_write_if_changed "$CDL_BACKUP_BIN" < "$(dirname "$0")/../cdl-backup.sh"
chmod 0755 "$CDL_BACKUP_BIN"

# --- systemd unit + timer -------------------------------------------------------------------
if cdl_have_systemd; then
    cdl_write_unit cdl-backup.service <<UNIT
$CDL_MANAGED
[Unit]
Description=cdl-linux nightly backup (restic over rclone, spec §10)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$CDL_BACKUP_BIN run
UNIT

    cdl_write_unit cdl-backup.timer <<'UNIT'
# managed by cdl-linux; edits here are overwritten by ./install.sh
[Unit]
Description=Nightly cdl-linux backup timer (spec §10.3)

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
UNIT
else
    warn "60-backup: no systemd here; wrote the unit files but cannot enable the timer"
fi

# --- gate: only enable the timer once it is actually configured ----------------------------
configured=1
grep -q "RESTIC_REPOSITORY=rclone:hf:${PLACEHOLDER_BUCKET}/restic" "$BACKUP_CONF" && configured=0
[ -f "$CDL_ETC/restic.pass" ] || configured=0

if [ "$configured" -eq 0 ]; then
    warn "60-backup: install is complete, but backup is not configured yet. Before the nightly timer can run:"
    warn "  1. edit $BACKUP_CONF and replace ${PLACEHOLDER_BUCKET} in RESTIC_REPOSITORY with the real bucket name"
    warn "  2. create $CDL_ETC/restic.pass (mode 0600) holding the restic repository password"
    warn "  3. create /root/.config/rclone/rclone.conf with the [hf] profile (spec §10.1)"
    warn "  then re-run: ./install.sh --module 60-backup"
    exit 0
fi

if cdl_have_systemd; then
    cdl_enable_now cdl-backup.timer
    ok "60-backup: configured; cdl-backup.timer enabled (nightly at 02:30)"
else
    ok "60-backup: configured; unit files written (no systemd here to enable the timer)"
fi

exit 0
