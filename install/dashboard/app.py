#!/usr/bin/env python3
# managed by cdl-linux; edits here are overwritten by ./install.sh
#
# Installed to /opt/cdl/dashboard/app.py by install/modules/55-dashboard.sh, and run there
# by the venv it creates alongside it (/opt/cdl/dashboard/venv).
"""cdl-dash: a read-mostly status page for a cdl-linux box (spec sec 8).

One FastAPI process, one page, one JSON endpoint. No build step, no CDN -- the box is
tailnet-only (sec 8.3) so nothing here fetches anything off-box at request time.

Design notes that matter for anyone changing this file:

* READ-ONLY (sec 8.2). There are no POST/PUT/PATCH/DELETE routes, and tests/test-dashboard.sh
  asserts that both by probing a route and by walking the generated OpenAPI schema.

* GPU and SMART data do NOT come from running nvidia-smi/smartctl in this process. This
  service is hardened with PrivateDevices=true (sec 3.4's dashboard row), so it has no
  /dev/nvidia* and no raw block device access at all. A separate root timer unit,
  cdl-gpu-telemetry, queries both every 2s and writes /run/cdl/gpu.json and
  /run/cdl/smart.json world-readable; this process only ever reads those two files. See
  install/modules/55-dashboard.sh for why that split exists instead of dropping
  PrivateDevices.

* Sessions (zellij) are read by listing the socket directory zellij creates for the console
  user, not by shelling out to `zellij list-sessions`: that command authenticates as the
  invoking UID, and cdl-dash is a separate unprivileged system account with no business
  becoming uid 1000. A socket file's existence is treated as a live session; its name is the
  session name; its mtime approximates when it started. Which agent CLI is attached to a
  session is not recoverable this way and is reported as null -- stated rather than guessed,
  per this repo's accuracy rule.

* Auth is Tailscale's (sec 8.3, sec 7.2): every request's source IP is resolved with
  `tailscale whois --json <ip>`; no UserProfile means 403. 127.0.0.1 is always allowed (the
  console can curl itself). The whois call is a plain function on app.state so a test can
  replace it -- but only via the CDL_DASH_FIXTURE_WHOIS env var, never by default, so the
  real refusal path (tailscale absent or the IP unknown to it) is what actually gets
  exercised by default.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable, Optional

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse
from starlette.middleware.base import BaseHTTPMiddleware

# --- configuration -----------------------------------------------------------------------
# CDL_DASH_FIXTURE_DIR redirects the two root-written telemetry files and the backup log to
# a test fixture directory, so tests/test-dashboard.sh can exercise every branch of
# /api/status without root, a GPU, or a real backup run. It is unset in production.
FIXTURE_DIR = os.environ.get("CDL_DASH_FIXTURE_DIR")

CDL_ETC = Path(os.environ.get("CDL_ETC", "/etc/cdl"))
OLLAMA_BASE = os.environ.get("CDL_OLLAMA_BASE", "http://127.0.0.1:11434")
LLAMA_SWAP_BASE = os.environ.get("CDL_LLAMA_SWAP_BASE", "http://127.0.0.1:8081")

# The console user's zellij session sockets. zellij defaults to $XDG_RUNTIME_DIR/zellij and
# falls back to /tmp/zellij-<uid> when there is no runtime dir (e.g. a non-systemd login).
# There is one supported human operator (sec 3.4) and Ubuntu assigns uid 1000 to the first
# created account, so that is what is checked; CDL_ZELLIJ_SOCKET_DIR overrides it for tests.
_ZELLIJ_CANDIDATES = [
    d
    for d in (
        os.environ.get("CDL_ZELLIJ_SOCKET_DIR"),
        "/run/user/1000/zellij",
        "/tmp/zellij-1000",
    )
    if d
]

HTTP_TIMEOUT = float(os.environ.get("CDL_DASH_HTTP_TIMEOUT", "1.5"))
CACHE_SECONDS = float(os.environ.get("CDL_DASH_CACHE_SECONDS", "1"))
LOOPBACK_IPS = {"127.0.0.1", "::1"}

BUILTIN_PALETTE_CSS = """/* built-in fallback palette: /etc/cdl/palette.css was absent */
:root {
  --cdl-bg: #101014;
  --cdl-fg: #e6e6e6;
  --cdl-panel: #1a1a20;
  --cdl-border: #2c2c34;
  --cdl-accent: #4fb3ff;
  --cdl-ok: #55c98a;
  --cdl-warn: #e0b84c;
  --cdl-err: #e35d5d;
  --cdl-dim: #8a8a94;
}
"""


def _fixture_path(name: str, real: str) -> Path:
    """Resolve a data file's path: under CDL_DASH_FIXTURE_DIR in tests, real on the box."""
    if FIXTURE_DIR:
        return Path(FIXTURE_DIR) / name
    return Path(real)


def _read_json_file(path: Path) -> Optional[Any]:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def _read_last_jsonl_line(path: Path) -> Optional[Any]:
    try:
        lines = [l for l in path.read_text().splitlines() if l.strip()]
    except OSError:
        return None
    if not lines:
        return None
    try:
        return json.loads(lines[-1])
    except ValueError:
        return None


def _http_get_json(url: str) -> Optional[Any]:
    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as resp:  # noqa: S310
            return json.loads(resp.read())
    except (urllib.error.URLError, OSError, ValueError, TimeoutError):
        return None


# --- data sources --------------------------------------------------------------------------


def get_gpu() -> Optional[Any]:
    """GPU utilisation/memory/temperature/power, written by cdl-gpu-telemetry as root."""
    return _read_json_file(_fixture_path("gpu.json", "/run/cdl/gpu.json"))


def get_smart() -> list:
    """SMART health per NVMe, written by cdl-gpu-telemetry as root (sec 2.1)."""
    data = _read_json_file(_fixture_path("smart.json", "/run/cdl/smart.json"))
    return data if isinstance(data, list) else []


def get_ollama() -> Optional[dict]:
    tags = _http_get_json(f"{OLLAMA_BASE}/api/tags")
    if tags is None:
        return None
    ps = _http_get_json(f"{OLLAMA_BASE}/api/ps")
    return {"tags": tags, "ps": ps}


def get_llama_swap() -> Optional[Any]:
    return _http_get_json(f"{LLAMA_SWAP_BASE}/running")


def get_sessions() -> list:
    """zellij session names, from the socket directory rather than `zellij list-sessions`
    (see the module docstring for why: cdl-dash is not the console user)."""
    for d in _ZELLIJ_CANDIDATES:
        p = Path(d)
        try:
            entries = sorted(p.iterdir())
        except (OSError, FileNotFoundError):
            continue
        sessions = []
        for e in entries:
            try:
                started = time.strftime(
                    "%Y-%m-%dT%H:%M:%SZ", time.gmtime(e.stat().st_mtime)
                )
            except OSError:
                started = None
            sessions.append({"name": e.name, "started": started, "agent": None})
        return sessions
    return []


def _disk_usage(path: str) -> Optional[dict]:
    try:
        import shutil

        u = shutil.disk_usage(path)
        return {"total": u.total, "used": u.used, "free": u.free}
    except OSError:
        return None


def get_storage() -> dict:
    # Sec 8.1: @, @home and @models share one btrfs pool, so these three usually read as the
    # same free figure. All three are still returned so the frontend can show one number
    # (the panel does) while a debugger can see the raw per-path reads that produced it.
    return {
        "root": _disk_usage("/"),
        "home": _disk_usage("/home"),
        "models": _disk_usage("/srv/models"),
    }


def get_backup() -> Optional[Any]:
    return _read_last_jsonl_line(
        _fixture_path("backup-runs.jsonl", "/var/log/cdl/backup-runs.jsonl")
    )


def get_tailscale_self() -> Optional[dict]:
    try:
        out = subprocess.run(
            ["tailscale", "status", "--json"],
            capture_output=True,
            timeout=HTTP_TIMEOUT,
            check=True,
        )
        data = json.loads(out.stdout)
    except (
        OSError,
        subprocess.SubprocessError,
        ValueError,
    ):
        return None
    self_node = data.get("Self") if isinstance(data, dict) else None
    if not isinstance(self_node, dict):
        return None
    return {
        "name": self_node.get("HostName") or self_node.get("DNSName"),
        "online": self_node.get("Online"),
        "tailscale_ips": self_node.get("TailscaleIPs"),
    }


_status_cache: dict = {"at": 0.0, "body": None}


def build_status() -> dict:
    now = time.time()
    if _status_cache["body"] is not None and now - _status_cache["at"] < CACHE_SECONDS:
        return _status_cache["body"]
    body = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "gpu": get_gpu(),
        "smart": get_smart(),
        "ollama": get_ollama(),
        "llama_swap": get_llama_swap(),
        "sessions": get_sessions(),
        "storage": get_storage(),
        "backup": get_backup(),
        "tailscale": get_tailscale_self(),
    }
    _status_cache["at"] = now
    _status_cache["body"] = body
    return body


# --- auth (sec 8.3, sec 7.2) ---------------------------------------------------------------


def real_tailscale_whois(ip: str) -> Optional[dict]:
    try:
        out = subprocess.run(
            ["tailscale", "whois", "--json", ip],
            capture_output=True,
            timeout=HTTP_TIMEOUT,
            check=True,
        )
        return json.loads(out.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        # Binary absent, tailscaled not running, timeout, unparseable output, or a nonzero
        # exit (tailscale whois exits nonzero for an IP it does not recognise) -- every one
        # of these means "cannot vouch for this caller", so every one of them refuses.
        return None


def _whois_fn() -> Callable[[str], Optional[dict]]:
    fixture = os.environ.get("CDL_DASH_FIXTURE_WHOIS")
    if not fixture:
        return real_tailscale_whois

    def fixture_whois(_ip: str) -> Optional[dict]:
        try:
            return json.loads(Path(fixture).read_text())
        except (OSError, ValueError):
            return None

    return fixture_whois


class TailscaleAuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        client_ip = request.client.host if request.client else None
        if client_ip in LOOPBACK_IPS:
            return await call_next(request)
        whois = request.app.state.whois
        identity = whois(client_ip) if client_ip else None
        if not isinstance(identity, dict) or not identity.get("UserProfile"):
            return JSONResponse(
                {"detail": "forbidden: no tailnet identity for this caller"},
                status_code=403,
            )
        return await call_next(request)


# --- app -------------------------------------------------------------------------------------

app = FastAPI(title="cdl-dash", description="cdl-linux status dashboard (read-only)")
app.state.whois = _whois_fn()
app.add_middleware(TailscaleAuthMiddleware)


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return _PAGE_HTML


@app.get("/palette.css", response_class=PlainTextResponse)
def palette_css() -> str:
    path = CDL_ETC / "palette.css"
    try:
        return path.read_text()
    except OSError:
        return BUILTIN_PALETTE_CSS


@app.get("/api/status")
def api_status() -> dict:
    return build_status()


_PAGE_HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>cdl-dash</title>
<link rel="stylesheet" href="/palette.css">
<style>
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 1rem; font-family: ui-monospace, "Fira Code", monospace;
    background: var(--cdl-bg, #101014); color: var(--cdl-fg, #e6e6e6);
  }
  h1 { font-size: 1rem; font-weight: 600; margin: 0 0 1rem; color: var(--cdl-accent, #4fb3ff); }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 0.75rem; }
  .panel {
    background: var(--cdl-panel, #1a1a20); border: 1px solid var(--cdl-border, #2c2c34);
    border-radius: 6px; padding: 0.75rem;
  }
  .panel h2 { font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.05em;
    margin: 0 0 0.5rem; color: var(--cdl-dim, #8a8a94); }
  .panel pre { margin: 0; white-space: pre-wrap; word-break: break-word; font-size: 0.8rem; }
  .stamp { margin-top: 1rem; font-size: 0.7rem; color: var(--cdl-dim, #8a8a94); }
  .ok { color: var(--cdl-ok, #55c98a); }
  .err { color: var(--cdl-err, #e35d5d); }
</style>
</head>
<body>
<h1>cdl-dash</h1>
<div class="grid" id="grid">
  <div class="panel"><h2>GPU</h2><pre id="p-gpu">loading...</pre></div>
  <div class="panel"><h2>Model servers</h2><pre id="p-models">loading...</pre></div>
  <div class="panel"><h2>Sessions</h2><pre id="p-sessions">loading...</pre></div>
  <div class="panel"><h2>Storage</h2><pre id="p-storage">loading...</pre></div>
  <div class="panel"><h2>SMART</h2><pre id="p-smart">loading...</pre></div>
  <div class="panel"><h2>Backup</h2><pre id="p-backup">loading...</pre></div>
</div>
<div class="stamp" id="stamp"></div>
<script>
function fmtBytes(n) {
  if (n === null || n === undefined) return "?";
  const u = ["B","KB","MB","GB","TB"]; let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return n.toFixed(1) + " " + u[i];
}
async function poll() {
  let s;
  try {
    const r = await fetch("/api/status", {cache: "no-store"});
    if (!r.ok) throw new Error("status " + r.status);
    s = await r.json();
  } catch (e) {
    document.getElementById("stamp").textContent = "fetch failed: " + e;
    return;
  }
  document.getElementById("p-gpu").textContent = s.gpu ? JSON.stringify(s.gpu, null, 2) : "no GPU / telemetry not yet written";
  const models = {ollama: s.ollama, llama_swap: s.llama_swap};
  document.getElementById("p-models").textContent = JSON.stringify(models, null, 2);
  document.getElementById("p-sessions").textContent = s.sessions.length
    ? s.sessions.map(x => x.name + " (started " + x.started + ")").join("\\n")
    : "no sessions";
  const st = s.storage;
  document.getElementById("p-storage").textContent = "free: " +
    (st.root ? fmtBytes(st.root.free) + " / " + fmtBytes(st.root.total) : "?");
  document.getElementById("p-smart").textContent = s.smart.length
    ? JSON.stringify(s.smart, null, 2) : "no NVMe telemetry";
  document.getElementById("p-backup").textContent = s.backup ? JSON.stringify(s.backup, null, 2) : "no backup recorded yet";
  document.getElementById("stamp").textContent = "updated " + s.generated_at;
}
poll();
setInterval(poll, 2000);
</script>
</body>
</html>
"""


if __name__ == "__main__":
    import uvicorn

    bind_host = os.environ.get("BIND_HOST", "127.0.0.1")
    port = int(os.environ.get("CDL_DASH_PORT", "8080"))
    uvicorn.run(app, host=bind_host, port=port, log_level="info")
