#!/usr/bin/env bash
# managed by cdl-linux; edits here are overwritten by ./install.sh
#
# Installed to /opt/cdl/dashboard/resolve-bind.sh by install/modules/55-dashboard.sh.
# ExecStartPre for cdl-dashboard.service. Resolves the tailnet IPv4 to bind to, with a
# short retry, and writes it to systemd's RuntimeDirectory for this unit as an
# EnvironmentFile. Runs every time the service starts (so on every boot), not just at
# install time: sec 7.3 says a reboot leaves the box unreachable until someone unlocks it
# and Tailscale reconnects, so re-resolving here means the dashboard picks up the tailnet
# address as soon as it exists rather than only after the next `install.sh` run.
#
# If Tailscale is not enrolled yet (sec 8.3's "local-only until enrolled" case), this falls
# back to 127.0.0.1 and says so in the unit's journal -- it does not fail the unit, because a
# fresh box legitimately has no tailnet address yet and that is not an install error.

set -uo pipefail

RUNTIME_DIR="${RUNTIME_DIRECTORY:-/run/cdl-dash}"
OUT="$RUNTIME_DIR/bind.env"
mkdir -p "$RUNTIME_DIR"

resolve_ip() {
    command -v tailscale >/dev/null 2>&1 || return 1
    tailscale ip -4 2>/dev/null | head -1
}

ip=""
for _ in 1 2 3 4 5; do
    ip="$(resolve_ip || true)"
    [ -n "$ip" ] && break
    sleep 2
done

if [ -n "$ip" ]; then
    printf 'BIND_HOST=%s\nCDL_DASH_TAILNET=1\n' "$ip" > "$OUT"
    echo "cdl-dashboard: binding to tailnet address $ip"
else
    printf 'BIND_HOST=127.0.0.1\nCDL_DASH_TAILNET=0\n' > "$OUT"
    echo "cdl-dashboard: no tailnet address yet; binding to 127.0.0.1 (local-only until enrolled)"
fi
