#!/usr/bin/env bash
# Verify, on the booted system, that install/modules/55-dashboard.sh did what spec §8 asks.
#
# Runs INSIDE the guest as root (tests/run-vm.sh drives it there via
# scripts/vm/run-in-guest.sh, which already carries sudo). The guest is arm64 (§12), so
# nvidia-smi and smartctl are both absent here; that is exactly the "null GPU" case §8.1
# describes for a machine with no NVIDIA card, and this asserts /run/cdl/gpu.json says so
# rather than not existing.

set -uo pipefail
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$*"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$*"; }

state="$(systemctl is-active cdl-dashboard 2>&1)"
if [ "$state" = "active" ]; then
    ok "cdl-dashboard.service is active"
else
    bad "cdl-dashboard.service is not active (got '$state')"
fi

user="$(systemctl show -p User --value cdl-dashboard 2>/dev/null)"
if [ "$user" = "cdl-dash" ]; then
    ok "cdl-dashboard.service runs as cdl-dash"
else
    bad "cdl-dashboard.service runs as '$user', want cdl-dash"
fi

timer_state="$(systemctl is-active cdl-gpu-telemetry.timer 2>&1)"
if [ "$timer_state" = "active" ]; then
    ok "cdl-gpu-telemetry.timer is active"
else
    bad "cdl-gpu-telemetry.timer is not active (got '$timer_state')"
fi

# The timer fires every 2s; give it a moment even on a machine that just booted.
for _ in $(seq 1 10); do
    [ -f /run/cdl/gpu.json ] && break
    sleep 1
done
if [ -f /run/cdl/gpu.json ]; then
    ok "/run/cdl/gpu.json exists"
    contents="$(cat /run/cdl/gpu.json)"
    # arm64: no nvidia-smi, so this must read null rather than being absent or malformed.
    if [ "$contents" = "null" ]; then
        ok "/run/cdl/gpu.json is null on this arm64, no-NVIDIA guest"
    elif python3 -c "import json,sys; json.loads(sys.argv[1])" "$contents" 2>/dev/null; then
        ok "/run/cdl/gpu.json is valid JSON (got GPU data: $contents)"
    else
        bad "/run/cdl/gpu.json is neither null nor valid JSON: $contents"
    fi
else
    bad "/run/cdl/gpu.json does not exist"
fi

port="$(awk -F= '/^CDL_DASH_PORT=/{print $2}' /etc/cdl/dashboard.env 2>/dev/null)"
port="${port:-8080}"

status_out="$(curl -fsS "http://127.0.0.1:$port/api/status" 2>&1)"
if [ -n "$status_out" ] && printf '%s' "$status_out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "GET 127.0.0.1:$port/api/status from the loopback is valid JSON"
else
    bad "GET 127.0.0.1:$port/api/status failed or was not JSON: $status_out"
fi

post_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/api/status")"
if [ "$post_code" = "405" ]; then
    ok "POST /api/status is 405 (no write routes, §8.2)"
else
    bad "POST /api/status -> $post_code, want 405"
fi

openapi_paths="$(curl -fsS "http://127.0.0.1:$port/openapi.json" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
bad_methods = [(p, m) for p, methods in d.get("paths", {}).items() for m in methods if m.lower() != "get"]
print("OK" if not bad_methods else f"BAD:{bad_methods}")
' 2>/dev/null)"
if [ "$openapi_paths" = "OK" ]; then
    ok "OpenAPI route list contains only GET"
else
    bad "OpenAPI schema advertises a non-GET route ($openapi_paths)"
fi

printf '\n== dashboard verification: %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
