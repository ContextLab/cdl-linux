#!/usr/bin/env bash
# Runs INSIDE an installed guest, as root, after ./install.sh has run there.
#
# Checks that 40-agents.sh actually installed something that runs, for the guest's own
# architecture (arm64 -- see scripts/vm/lib.sh's UBUNTU_ARCH), and that cdl-agent behaves
# correctly for an ordinary, unprivileged user rather than only for root.
#
# Invoked by tests/run-vm.sh.

set -uo pipefail

pass=0; fail=0
ok()  { printf '  \033[32mOK\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

[ "$(id -u)" -eq 0 ] || { printf 'verify-agents: must run as root inside the guest\n' >&2; exit 1; }

MODULE=/home/cdl/cdl-linux/install/modules/40-agents.sh

# --- what the run record says happened -------------------------------------------------------
RECORD=/var/log/cdl/install-runs.jsonl
if [ -f "$RECORD" ]; then
    result="$(python3 - "$RECORD" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
# The module's most recent record, whatever run it belongs to: requiring it in the LAST run
# fails under per-module iteration, where the last run is whichever module ran most recently.
mine = [r for r in rows if r["module"] == "40-agents"]
print(mine[-1]["result"] if mine else "did-not-run")
PY
)"
    if [ "$result" = ok ]; then ok "40-agents recorded 'ok'"; else bad "40-agents recorded '$result'"; fi
else
    bad "no run record at $RECORD"
fi

# --- the three redistributable CLIs run, for this guest's real architecture -------------------
# The guest is arm64 (scripts/vm/lib.sh), which is exactly the arch codex and opencode's
# pinned aarch64 assets are for, and the arch gemini-cli's npm package has no native
# component to get wrong for either. A binary that merely exists proves nothing; --version
# has to actually execute it.
for bin in codex opencode gemini; do
    if command -v "$bin" >/dev/null 2>&1; then
        ok "$bin is on PATH"
        if out="$("$bin" --version 2>&1)"; then
            ok "$bin --version runs ($out)"
        else
            bad "$bin --version failed: $out"
        fi
    else
        bad "$bin is not on PATH"
    fi
done

# Both are meant to land at /opt/cdl/bin, symlinked into /usr/local/bin -- not wherever npm
# or tar happened to put them, so the two are interchangeable from cdl-agent's point of view.
for bin in codex opencode gemini; do
    link="/usr/local/bin/$bin"
    if [ -L "$link" ]; then
        target="$(readlink "$link")"
        if [[ "$target" == /opt/cdl/bin/* ]]; then
            ok "$link is a symlink into /opt/cdl/bin ($target)"
        else
            bad "$link points at $target, not /opt/cdl/bin"
        fi
    else
        bad "$link is not a symlink"
    fi
done

# --- gemini-cli's dependency: Node from NodeSource, not Ubuntu's own package ------------------
if command -v node >/dev/null 2>&1; then
    ok "node is installed ($(node --version 2>&1))"
    if dpkg-query -W -f='${Version}' nodejs 2>/dev/null | grep -q .; then
        origin="$(apt-cache policy nodejs 2>/dev/null | grep -o 'deb.nodesource.com' | head -1)"
        if [ "$origin" = "deb.nodesource.com" ]; then
            ok "nodejs came from the NodeSource repository"
        else
            bad "nodejs did not come from NodeSource: $(apt-cache policy nodejs 2>&1)"
        fi
    fi
else
    bad "node is not installed"
fi

# --- cdl-agent, as user cdl (not root) ---------------------------------------------------------
# The credential launcher is meant for an ordinary interactive user; running it as root would
# not exercise the "invoking user" ownership check at all (root can read anything).
if id cdl >/dev/null 2>&1; then
    ok "user cdl exists"
else
    bad "user cdl does not exist in this guest"
fi

if [ -x /usr/local/bin/cdl-agent ]; then
    ok "/usr/local/bin/cdl-agent is installed and executable"
else
    bad "/usr/local/bin/cdl-agent is not installed"
fi

if list_out="$(su - cdl -c 'cdl-agent list' 2>&1)"; then
    ok "cdl-agent list runs as user cdl"
    if grep -q 'codex' <<<"$list_out" && grep -q 'opencode' <<<"$list_out" && grep -q 'gemini' <<<"$list_out"; then
        ok "cdl-agent list names all installed agents"
    else
        bad "cdl-agent list output missing an agent: $list_out"
    fi
    if grep -qE 'codex[[:space:]]+yes' <<<"$list_out"; then
        ok "cdl-agent list reports codex as installed"
    else
        bad "cdl-agent list does not report codex as installed: $list_out"
    fi
else
    bad "cdl-agent list failed as user cdl: $list_out"
fi

# /etc/cdl/keys.example exists, world-readable, and names every variable the launcher uses.
if [ -f /etc/cdl/keys.example ]; then
    ok "/etc/cdl/keys.example exists"
    mode="$(stat -c%a /etc/cdl/keys.example)"
    if [ "$mode" = "644" ]; then ok "/etc/cdl/keys.example is mode 0644"; else bad "/etc/cdl/keys.example is mode $mode, want 0644"; fi
    for v in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY TOGETHER_API_KEY FIREWORKS_API_KEY; do
        if grep -q "^${v}=" /etc/cdl/keys.example; then ok "keys.example names $v"; else bad "keys.example is missing $v"; fi
    done
else
    bad "/etc/cdl/keys.example does not exist"
fi

# --- cdl-agent refuses a bad keys file for the real user, not just in a fixture ----------------
su - cdl -c 'mkdir -p ~/.config/cdl && printf "OPENAI_API_KEY=x\n" > ~/.config/cdl/keys && chmod 644 ~/.config/cdl/keys'
out="$(su - cdl -c 'cdl-agent --print-env codex' 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "cdl-agent (as cdl) refuses its own mode-0644 keys file"; else bad "cdl-agent (as cdl) accepted a mode-0644 keys file"; fi
su - cdl -c 'chmod 600 ~/.config/cdl/keys'
out="$(su - cdl -c 'cdl-agent --print-env codex' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qx OPENAI_API_KEY <<<"$out"; then
    ok "cdl-agent (as cdl) accepts a correct keys file and exports OPENAI_API_KEY for codex"
else
    bad "cdl-agent (as cdl) with a correct keys file: rc=$rc out=$out"
fi
su - cdl -c 'rm -f ~/.config/cdl/keys'

# --- idempotence, for this module specifically -------------------------------------------------
second="$(bash "$MODULE" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then ok "a second 40-agents run exits 0"; else bad "a second 40-agents run exited $rc: $second"; fi
if grep -qE '^\s+(installing:|fetched |linked )' <<<"$second"; then
    bad "a second 40-agents run changed something: $second"
else
    ok "a second 40-agents run changed nothing"
fi
if grep -q 'already installed' <<<"$second"; then
    ok "a second 40-agents run reports everything already installed"
else
    bad "a second 40-agents run did not confirm nothing to do: $second"
fi

printf '\n  verify-agents: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
