#!/usr/bin/env bash
# Checks for install/modules/55-dashboard.sh and install/dashboard/ that run on a plain
# macOS checkout: no root, no apt, no systemd. Everything that needs those (the module
# actually applying, the units actually enabling) belongs to tests/vm/verify-dashboard.sh
# instead, run against the guest.
#
# This starts the real app.py under a real venv with the real pinned fastapi/uvicorn (no
# mocks), and exercises the real auth refusal path: on this machine tailscale is not
# installed, so a non-loopback request must hit `tailscale whois`, watch it fail because the
# binary is absent, and get refused. That is the production failure mode for an
# unenrolled or misconfigured box, not a stand-in for it.
#
# Usage: tests/test-dashboard.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$repo_root/install/modules/55-dashboard.sh"
DASH_SRC="$repo_root/install/dashboard"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

tmp="$(mktemp -d)"
server_pid=""
cleanup() {
    [ -n "$server_pid" ] && kill "$server_pid" >/dev/null 2>&1
    rm -rf "$tmp"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------
echo "== shellcheck =="
# ---------------------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    if (cd "$(dirname "$MODULE")" && shellcheck -x "$(basename "$MODULE")"); then
        ok "shellcheck clean: install/modules/55-dashboard.sh"
    else
        bad "shellcheck: install/modules/55-dashboard.sh"
    fi
    for f in gpu-telemetry.sh resolve-bind.sh; do
        if (cd "$DASH_SRC" && shellcheck -x "$f"); then
            ok "shellcheck clean: install/dashboard/$f"
        else
            bad "shellcheck: install/dashboard/$f"
        fi
    done
else
    echo "  shellcheck not installed — skipping"
fi

if bash -n "$MODULE"; then ok "bash -n: 55-dashboard.sh"; else bad "bash -n: 55-dashboard.sh"; fi

# ---------------------------------------------------------------------------------------
echo "== gpu-telemetry.sh: nvidia-smi's [N/A] must become JSON null, not invalid JSON =="
# ---------------------------------------------------------------------------------------
# nvidia-smi prints the literal "[N/A]" for a field it cannot read (common for power.draw
# and utilization on some mobile GPUs, and for every field during driver init). A fixture
# nvidia-smi on PATH stands in for the real one so this is real bash + real python3 json
# parsing, not a description of what the code is supposed to do.
NA_BIN="$tmp/na-bin"
mkdir -p "$NA_BIN"
cat > "$NA_BIN/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
echo "0, [N/A], 1024, 24576, 45, [N/A]"
EOF
chmod +x "$NA_BIN/nvidia-smi"

NA_RUN="$tmp/na-run"
if PATH="$NA_BIN:$PATH" CDL_RUN_DIR="$NA_RUN" bash "$DASH_SRC/gpu-telemetry.sh"; then
    ok "gpu-telemetry.sh ran against a fixture nvidia-smi returning [N/A] fields"
else
    bad "gpu-telemetry.sh exited nonzero against a fixture [N/A] nvidia-smi"
fi

if python3 -c "
import json
d = json.load(open('$NA_RUN/gpu.json'))
assert isinstance(d, list) and len(d) == 1, d
g = d[0]
assert g['utilization_pct'] is None, g
assert g['power_draw_w'] is None, g
assert g['temperature_c'] == 45, g
assert g['memory_used_mib'] == 1024, g
"; then
    ok "/run/cdl/gpu.json is valid JSON with null for every [N/A] field"
else
    bad "gpu.json was not valid JSON, or [N/A] did not become null: $(cat "$NA_RUN/gpu.json" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------------------
echo "== venv + real pinned fastapi/uvicorn =="
# ---------------------------------------------------------------------------------------
VENV="$tmp/venv"
if ! python3 -m venv "$VENV" >/dev/null 2>&1; then
    bad "could not create a venv with the system python3 — cannot continue"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi
ok "venv created at $VENV"

if "$VENV/bin/pip" install --quiet --no-input -r "$DASH_SRC/requirements.txt"; then
    ok "pip install of pinned requirements.txt (real PyPI, real packages)"
else
    bad "pip install of pinned requirements.txt failed"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi

installed="$("$VENV/bin/python" -c 'import fastapi, uvicorn; print(fastapi.__version__, uvicorn.__version__)')"
want="$(awk -F== '/^fastapi/{f=$2} /^uvicorn/{u=$2} END{print f, u}' "$DASH_SRC/requirements.txt")"
if [ "$installed" = "$want" ]; then
    ok "installed versions match the pin ($installed)"
else
    bad "version mismatch: installed [$installed] want [$want]"
fi

# ---------------------------------------------------------------------------------------
echo "== starting app.py (fixture data, real subprocess calls for everything else) =="
# ---------------------------------------------------------------------------------------
FIXTURE_DIR="$tmp/fixtures"
mkdir -p "$FIXTURE_DIR"
cat > "$FIXTURE_DIR/gpu.json" <<'JSON'
[{"index":0,"utilization_pct":12,"memory_used_mib":1024,"memory_total_mib":24576,"temperature_c":45,"power_draw_w":80.5}]
JSON
cat > "$FIXTURE_DIR/backup-runs.jsonl" <<'JSON'
{"started":"2026-09-01T02:30:00Z","result":"ok","detail":"snapshot abc123","seconds":42}
JSON

# Machine panel (sec 8.1) fixtures: a fake /proc/meminfo, a fake sysfs thermal zone, and a
# fake intel_pstate max_perf_pct -- this Mac has none of these in the real Linux shape.
MEMINFO="$tmp/meminfo"
cat > "$MEMINFO" <<'EOF'
MemTotal:       16384000 kB
MemFree:         2048000 kB
MemAvailable:    9000000 kB
EOF

THERMAL_ROOT="$tmp/thermal"
mkdir -p "$THERMAL_ROOT/thermal_zone0"
echo "x86_pkg_temp" > "$THERMAL_ROOT/thermal_zone0/type"
echo "52300" > "$THERMAL_ROOT/thermal_zone0/temp"

MAX_PERF_PCT="$tmp/max_perf_pct"
echo "83" > "$MAX_PERF_PCT"

# Largest-models fixture: two "models" of different sizes under a fake ollama store.
MODELS_DIR="$tmp/models/ollama"
mkdir -p "$MODELS_DIR"
head -c 2048 /dev/zero > "$MODELS_DIR/small.bin"
head -c 8192 /dev/zero > "$MODELS_DIR/big.bin"

# A free port: ask the OS for one, then release it immediately. A fixed port would collide
# with a leftover process from a previous failed run.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("0.0.0.0",0)); print(s.getsockname()[1]); s.close()')"

# Bound to 0.0.0.0 deliberately: the client-perceived source address (127.0.0.1 for a
# loopback curl, the LAN address for a curl from this Mac's own LAN IP) depends on where the
# request comes from, not on what the server bound to, so one instance covers both the
# "loopback is always allowed" and "a real non-loopback caller is refused" cases below.
CDL_DASH_FIXTURE_DIR="$FIXTURE_DIR" \
CDL_PROC_MEMINFO="$MEMINFO" \
CDL_SYS_THERMAL_ROOT="$THERMAL_ROOT" \
CDL_SYS_MAX_PERF_PCT="$MAX_PERF_PCT" \
CDL_MODELS_OLLAMA_DIR="$MODELS_DIR" \
CDL_MODELS_GGUF_DIR="$tmp/no-such-gguf-dir" \
BIND_HOST=0.0.0.0 \
CDL_DASH_PORT="$PORT" \
CDL_ZELLIJ_SOCKET_DIR="$tmp/no-such-zellij-dir" \
"$VENV/bin/python" "$DASH_SRC/app.py" >"$tmp/server.log" 2>&1 &
server_pid=$!

base="http://127.0.0.1:$PORT"
up=0
for _ in $(seq 1 50); do
    curl -fsS -o /dev/null "$base/api/status" 2>/dev/null && { up=1; break; }
    sleep 0.2
done
if [ "$up" -eq 1 ]; then
    ok "server came up on port $PORT"
else
    bad "server never answered on port $PORT — log follows"
    cat "$tmp/server.log"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi

# ---------------------------------------------------------------------------------------
echo "== routes (loopback, always allowed) =="
# ---------------------------------------------------------------------------------------
code="$(curl -s -o "$tmp/index.html" -w '%{http_code}' "$base/")"
if [ "$code" = "200" ] && grep -qi '<html' "$tmp/index.html"; then
    ok "GET / is 200 HTML"
else
    bad "GET / -> $code (expected 200 HTML)"
fi

status_json="$tmp/status.json"
code="$(curl -s -o "$status_json" -w '%{http_code}' "$base/api/status")"
if [ "$code" = "200" ]; then
    ok "GET /api/status is 200"
else
    bad "GET /api/status -> $code"
fi

if python3 -c "
import json, sys
d = json.load(open('$status_json'))
want = {'generated_at','gpu','smart','ollama','llama_swap','sessions','storage','machine','backup','tailscale'}
missing = want - d.keys()
assert not missing, f'missing keys: {missing}'
assert d['gpu'][0]['temperature_c'] == 45, d['gpu']
assert d['backup']['result'] == 'ok', d['backup']
assert d['sessions'] == [], d['sessions']
assert isinstance(d['storage']['root'], dict), d['storage']
" ; then
    ok "/api/status has the expected keys and reflects fixture data"
else
    bad "/api/status JSON shape or fixture values wrong"
fi

if python3 -c "
import json
d = json.load(open('$status_json'))
m = d['machine']
assert m['cpu_temperature_c']['value'] == 52.3, m
assert m['cpu_temperature_c']['reason'] is None, m
assert m['max_perf_pct']['value'] == 83, m
assert m['load'] is not None and 'load1' in m['load'], m
assert m['memory']['total_kib'] == 16384000, m
assert m['memory']['available_kib'] == 9000000, m
assert m['memory']['used_kib'] == 16384000 - 9000000, m
lm = d['storage']['largest_models']
names = [x['path'].split('/')[-1] for x in lm['models']]
assert names[0] == 'big.bin', lm
assert names[1] == 'small.bin', lm
assert lm['models'][0]['size_bytes'] == 8192, lm
assert d['ollama']['requests_served']['value'] is None, d['ollama']
assert d['ollama']['requests_served']['reason'], d['ollama']
assert d['llama_swap']['requests_served']['value'] is None, d['llama_swap']
"; then
    ok "machine panel (CPU temp, max_perf_pct, load, memory) and largest_models reflect fixtures"
    ok "requests_served is null-with-reason for ollama and llama-swap (genuinely unavailable)"
else
    bad "machine panel / largest_models / requests_served shape or values wrong"
fi

code="$(curl -s -o /dev/null -w '%{http_code}' "$base/palette.css")"
if [ "$code" = "200" ]; then ok "GET /palette.css is 200"; else bad "GET /palette.css -> $code"; fi

palette_body="$(curl -s "$base/palette.css")"
if echo "$palette_body" | grep -q -- '--cdl-bg'; then
    ok "palette.css falls back to the built-in palette (no /etc/cdl/palette.css here)"
else
    bad "palette.css fallback content missing --cdl-bg"
fi

# ---------------------------------------------------------------------------------------
echo "== read-only: no write route exists (§8.2) =="
# ---------------------------------------------------------------------------------------
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/api/status")"
if [ "$code" = "405" ]; then ok "POST /api/status is 405"; else bad "POST /api/status -> $code (want 405)"; fi

openapi="$tmp/openapi.json"
curl -s -o "$openapi" "$base/openapi.json"
if python3 -c "
import json
d = json.load(open('$openapi'))
bad_methods = []
for path, methods in d.get('paths', {}).items():
    for m in methods:
        if m.lower() not in ('get',):
            bad_methods.append((path, m))
assert not bad_methods, bad_methods
"; then
    ok "OpenAPI route list contains only GET"
else
    bad "OpenAPI schema advertises a non-GET route"
fi

# ---------------------------------------------------------------------------------------
echo "== auth: non-loopback refused when tailscale cannot vouch for it (§8.3, §7.2) =="
# ---------------------------------------------------------------------------------------
if command -v tailscale >/dev/null 2>&1; then
    echo "  tailscale IS installed on this Mac — this test needs it absent to exercise the"
    echo "  real refusal path; skipping rather than giving a false pass or fail."
else
    lan_ip="$(python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(('8.8.8.8', 80))
    print(s.getsockname()[0])
finally:
    s.close()
" 2>/dev/null)"
    if [ -z "$lan_ip" ]; then
        bad "could not determine this Mac's LAN IP — cannot exercise the non-loopback path"
    else
        code="$(curl -s -o "$tmp/forbidden.json" -w '%{http_code}' "http://$lan_ip:$PORT/api/status" --max-time 3)"
        if [ "$code" = "403" ]; then
            ok "a request from $lan_ip (non-loopback) is 403 with tailscale absent"
        else
            bad "request from $lan_ip -> $code (want 403); body: $(cat "$tmp/forbidden.json" 2>/dev/null)"
        fi
    fi
fi

# ---------------------------------------------------------------------------------------
echo "== auth: the DI seam used only by tests, not by the refusal path above =="
# ---------------------------------------------------------------------------------------
kill "$server_pid" >/dev/null 2>&1
wait "$server_pid" 2>/dev/null
server_pid=""

WHOIS_FIXTURE="$tmp/whois-allow.json"
cat > "$WHOIS_FIXTURE" <<'JSON'
{"UserProfile": {"LoginName": "operator"}}
JSON
PORT2="$(python3 -c 'import socket; s=socket.socket(); s.bind(("0.0.0.0",0)); print(s.getsockname()[1]); s.close()')"
CDL_DASH_FIXTURE_DIR="$FIXTURE_DIR" \
CDL_DASH_FIXTURE_WHOIS="$WHOIS_FIXTURE" \
BIND_HOST=0.0.0.0 \
CDL_DASH_PORT="$PORT2" \
CDL_ZELLIJ_SOCKET_DIR="$tmp/no-such-zellij-dir" \
"$VENV/bin/python" "$DASH_SRC/app.py" >"$tmp/server2.log" 2>&1 &
server_pid=$!

up=0
for _ in $(seq 1 50); do
    curl -fsS -o /dev/null "http://127.0.0.1:$PORT2/api/status" 2>/dev/null && { up=1; break; }
    sleep 0.2
done
if [ "$up" -eq 1 ]; then
    lan_ip2="$(python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(('8.8.8.8', 80))
    print(s.getsockname()[0])
finally:
    s.close()
" 2>/dev/null)"
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://$lan_ip2:$PORT2/api/status" --max-time 3)"
    if [ "$code" = "200" ]; then
        ok "a non-loopback caller IS allowed once whois vouches for it (fixture-injected)"
    else
        bad "fixture-vouched caller -> $code (want 200)"
    fi
else
    bad "second server (fixture whois) never came up"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
