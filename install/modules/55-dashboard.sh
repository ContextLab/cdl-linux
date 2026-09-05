#!/usr/bin/env bash
# cdl-dash: the read-only web dashboard (spec §8).
#
# One FastAPI app under systemd (§8.3), serving one page that polls /api/status. It has no
# write route at all -- §8.2 is the authority on that, and tests/test-dashboard.sh asserts
# it by probing a route and by walking the generated OpenAPI schema.
#
# --- PrivateDevices, resolved (§3.4) --------------------------------------------------------
# §3.4's hardening table sets PrivateDevices=true on the dashboard row but the dashboard also
# needs nvidia-smi and smartctl output for §8.1's GPU and SMART panels, both of which read
# real devices (/dev/nvidia*, /dev/nvme*). Those are contradictory for one process. Dropping
# PrivateDevices would be the smaller diff, but it would give a process that only ever needs
# to read two small JSON blobs standing device access it does not need for anything else it
# does. Instead: a second, separate unit, `cdl-gpu-telemetry`, runs as root on a 2s timer,
# queries nvidia-smi and smartctl itself, and writes /run/cdl/gpu.json and
# /run/cdl/smart.json, world-readable. cdl-dash keeps PrivateDevices=true and never touches a
# device; it only reads those two files. See install/dashboard/gpu-telemetry.sh.
#
# --- SupplementaryGroups, resolved -----------------------------------------------------------
# The telemetry files are plain data (utilisation percentages, temperatures, a pass/fail
# bit) with nothing sensitive in them, so they are written world-readable (0644) rather than
# gated behind a shared group. That means cdl-dash needs no SupplementaryGroups= at all --
# which keeps PrivateDevices=true meaningful with zero exceptions carved into it.
#
# --- zellij sessions, resolved ---------------------------------------------------------------
# §8.1 wants the zellij sessions panel, but `zellij list-sessions` authenticates as the
# invoking UID, and cdl-dash is a separate unprivileged system account -- it has no business
# becoming the console user (uid 1000) to run it. app.py instead lists the session socket
# directory itself (session name = socket file name, start time = the socket's mtime); see
# its module docstring for the one thing that loses (which agent CLI is attached).
#
# --- bind address, resolved (§8.3, §7.3) ------------------------------------------------------
# The service binds to the tailnet IPv4 only, or 127.0.0.1 if none exists yet. That is
# re-resolved by an ExecStartPre (install/dashboard/resolve-bind.sh) on every unit start,
# with a short retry, rather than baked in once at install time: §7.3 already established
# that a reboot leaves the box waiting on Tailscale to reconnect, and re-resolving at every
# start means the dashboard picks up the tailnet address as soon as it exists instead of
# only after the next `install.sh` run.
#
# --- port -------------------------------------------------------------------------------------
# The spec does not name one for the dashboard (only Ollama's 11434 and llama-swap's 8081
# are pinned, in §5.1). 8080 is used here and is overridable via CDL_DASH_PORT in
# /etc/cdl/dashboard.env for a box where something else already holds it.
#
# --- tailscale whois as a non-root, non-operator user: what must be true --------------------
# app.py's auth middleware (§8.3) runs `tailscale whois` as cdl-dash, an unprivileged system
# account with no interactive login. tailscaled's LocalAPI socket
# (/run/tailscale/tailscaled.sock) is root-only by default; a non-root caller gets it only
# once a human runs `sudo tailscale set --operator=cdl-dash` on this box, which this module
# does NOT do for you, on purpose: Tailscale allows exactly one operator system-wide
# (tailscale/tailscale#17817), so setting it here would silently take that grant away from
# a human who set `tailscale set --operator=<their own login>` for their own convenience.
# That is a worse failure than the one it would fix.
#
# Until that `set --operator` command has been run: every whois call fails, so every
# non-loopback request is refused (fail closed -- a safe default, just not a working
# dashboard). app.py's real_tailscale_whois() now runs the CLI as its own account (never
# root, never given operator here) and logs the process's stderr verbatim on failure --
# "cdl-dash whois failed for <ip>: <stderr>" -- so this exact permission gap names itself in
# `journalctl -u cdl-dashboard` on the real machine instead of presenting as a mute 403.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

cdl_need_root "55-dashboard"

SRC_DIR="$(cd "$(dirname "$0")/../dashboard" && pwd)"
APP_DIR=/opt/cdl/dashboard
VENV_DIR="$APP_DIR/venv"
DASH_PORT_DEFAULT=8080

# --- packages: python3 + venv + pip, nothing else ------------------------------------------
cdl_apt_install python3 python3-venv python3-pip

# --- the application, copied in (not symlinked: /opt/cdl must survive the repo moving) -----
changed=0
for f in app.py gpu-telemetry.sh resolve-bind.sh requirements.txt; do
    if cdl_write_if_changed "$APP_DIR/$f" < "$SRC_DIR/$f"; then changed=1; fi
done
chmod 0755 "$APP_DIR/app.py" "$APP_DIR/gpu-telemetry.sh" "$APP_DIR/resolve-bind.sh"
chmod 0644 "$APP_DIR/requirements.txt"

# --- /etc/cdl/dashboard.env: seeded once, then left alone --------------------------------
# dashboard.env.default is fully managed (rewritten every run, like everything else this
# module owns) and carries only the shipped defaults. dashboard.env is what the unit
# actually reads, and it is copied from the default ONLY if it does not already exist: an
# operator who has changed CDL_DASH_PORT by hand must not have that reverted on the next
# `./install.sh`, which cdl_write_if_changed would otherwise do to this file every run.
DEFAULT_ENV="$CDL_ETC/dashboard.env.default"
ENV_FILE="$CDL_ETC/dashboard.env"

cdl_write_if_changed "$DEFAULT_ENV" <<CONF
$CDL_MANAGED
# The shipped defaults for cdl-dashboard.service. Rewritten every run -- do not edit this
# file. It is copied to $ENV_FILE once, the first time this module runs on a machine; that
# copy is never touched again, so edit $ENV_FILE by hand instead.
CDL_DASH_PORT=$DASH_PORT_DEFAULT
CONF
chmod 0644 "$DEFAULT_ENV"

if [ ! -f "$ENV_FILE" ]; then
    cp "$DEFAULT_ENV" "$ENV_FILE"
    dim "    seeded $ENV_FILE from $DEFAULT_ENV; edit it by hand from here on"
fi
chmod 0644 "$ENV_FILE"

# --- venv: created once, packages pinned and verified rather than "latest" ------------------
if [ ! -x "$VENV_DIR/bin/python" ]; then
    python3 -m venv "$VENV_DIR" || die "cannot create venv at $VENV_DIR"
    dim "    created venv at $VENV_DIR"
fi

want_versions="$(awk -F== '/^[a-zA-Z]/{printf "%s ", $2}' "$APP_DIR/requirements.txt")"
have_versions="$("$VENV_DIR/bin/python" -c '
try:
    import fastapi, uvicorn
    print(fastapi.__version__, uvicorn.__version__, end=" ")
except Exception:
    pass
' 2>/dev/null)"

if [ "$(echo "$have_versions" | xargs)" != "$(echo "$want_versions" | xargs)" ]; then
    "$VENV_DIR/bin/pip" install --quiet --no-input --upgrade pip \
        || die "cannot upgrade pip in $VENV_DIR"
    "$VENV_DIR/bin/pip" install --quiet --no-input -r "$APP_DIR/requirements.txt" \
        || die "pip install failed for $APP_DIR/requirements.txt"
    dim "    installed pinned fastapi/uvicorn into $VENV_DIR"
fi

# --- the service user: owns nothing (§3.4's dashboard row) ----------------------------------
cdl_system_user cdl-dash

if ! cdl_have_systemd; then
    warn "55-dashboard: no systemd here; files installed but no unit was started"
    ok "55-dashboard: application and venv in place"
    exit 0
fi

unit_changed=0

# --- cdl-gpu-telemetry: root, every 2s, feeds the two files cdl-dash is allowed to read -----
if cdl_write_unit cdl-gpu-telemetry.service <<UNIT
$CDL_MANAGED
[Unit]
Description=cdl-linux GPU/NVMe telemetry snapshot for cdl-dash (spec §8.3, §3.4)

[Service]
Type=oneshot
Environment=CDL_RUN_DIR=/run/cdl
ExecStart=$APP_DIR/gpu-telemetry.sh
RuntimeDirectory=cdl
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
ReadWritePaths=/run/cdl
UNIT
then unit_changed=1; fi

if cdl_write_unit cdl-gpu-telemetry.timer <<'UNIT'
# managed by cdl-linux; edits here are overwritten by ./install.sh
[Unit]
Description=Run cdl-gpu-telemetry every 2s (spec §8.1: GPU and SMART panels)

[Timer]
OnBootSec=2s
OnUnitActiveSec=2s
AccuracySec=250ms
Unit=cdl-gpu-telemetry.service

[Install]
WantedBy=timers.target
UNIT
then unit_changed=1; fi

# --- cdl-dashboard: the §3.4 hardening block verbatim, plus PrivateDevices=true -------------
# ReadWritePaths is omitted: §3.4's table says the dashboard owns nothing, and giving it one
# anyway just to match the block's shape would contradict its own row.
# The dash in `EnvironmentFile=-/run/cdl-dash/bind.env` below is load-bearing. systemd reads
# every EnvironmentFile= before spawning EACH command, including ExecStartPre -- and
# ExecStartPre is what writes that file. Without the dash the first start fails with
# "Failed to load environment files" before resolve-bind.sh ever runs, which is what
# happened on the VM. With it the missing file is ignored for the pre-step and is present
# by the time ExecStart is spawned.
if cdl_write_unit cdl-dashboard.service <<UNIT
$CDL_MANAGED
[Unit]
Description=cdl-dash: read-only status dashboard (spec §8)
After=network-online.target cdl-gpu-telemetry.timer
Wants=network-online.target cdl-gpu-telemetry.timer

[Service]
Type=simple
User=cdl-dash
Group=cdl-dash
RuntimeDirectory=cdl-dash
RuntimeDirectoryMode=0750
EnvironmentFile=$CDL_ETC/dashboard.env
ExecStartPre=$APP_DIR/resolve-bind.sh
EnvironmentFile=-/run/cdl-dash/bind.env
Environment=PYTHONUNBUFFERED=1
ExecStart=$VENV_DIR/bin/python $APP_DIR/app.py
Restart=on-failure
RestartSec=2

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=false
PrivateDevices=true

[Install]
WantedBy=multi-user.target
UNIT
then unit_changed=1; fi

cdl_enable_now cdl-gpu-telemetry.timer
cdl_enable_now cdl-dashboard.service

# cdl_enable_now only starts a unit that was not already active; an update to app.py or to
# either unit file needs an explicit restart to actually take effect.
if [ "$changed" -eq 1 ] || [ "$unit_changed" -eq 1 ]; then
    systemctl restart cdl-dashboard.service || die "cdl-dashboard failed to restart after an update"
    systemctl restart cdl-gpu-telemetry.timer || die "cdl-gpu-telemetry.timer failed to restart after an update"
fi

ip="$(cdl_tailscale_ip)"
if [ -n "$ip" ]; then
    ok "55-dashboard: cdl-dash running, will bind to tailnet address $ip"
else
    warn "55-dashboard: no tailnet address yet; cdl-dash is local-only (127.0.0.1) until enrolled"
fi

exit 0
