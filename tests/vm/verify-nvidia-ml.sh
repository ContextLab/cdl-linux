#!/usr/bin/env bash
# Runs INSIDE an installed guest, as root, after ./install.sh has run there.
#
# The guest is arm64 and has no NVIDIA GPU, which is the point: it is where the "no GPU"
# branch of both modules gets exercised for real. 20-nvidia must have *skipped* (exit 2,
# recorded as such), and 25-ml must have built a working CPU environment anyway. A module
# that only works on the one machine with a 3080 is a module nobody can test.
#
# Invoked by tests/run-vm.sh.

set -uo pipefail

pass=0; fail=0
ok()  { printf '  \033[32mOK\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

[ "$(id -u)" -eq 0 ] || { printf 'verify-nvidia-ml: must run as root inside the guest\n' >&2; exit 1; }

RECORD=/var/log/cdl/install-runs.jsonl
VENV=/opt/cdl/ml

# --- what the run record says happened ------------------------------------------------------
if [ -f "$RECORD" ]; then
    ok "a run record exists at $RECORD"
    result="$(python3 - "$RECORD" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
if not rows:
    print("no-rows"); raise SystemExit(0)
# The module\'s most recent record, whatever run it belongs to. Requiring it to sit in
# the LAST run made every verifier fail under per-module iteration, where the last run is
# whichever module ran most recently.
mine = [r for r in rows if r["module"] == "20-nvidia"]
print(mine[-1]["result"] if mine else "did-not-run")
PY
)"
    if [ "$result" = skipped ]; then
        ok "20-nvidia recorded 'skipped' on this GPU-less machine"
    else
        bad "20-nvidia recorded '$result'; on a machine with no NVIDIA GPU it must skip"
    fi

    ml_result="$(python3 - "$RECORD" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
# The module\'s most recent record, whatever run it belongs to. Requiring it to sit in
# the LAST run made every verifier fail under per-module iteration, where the last run is
# whichever module ran most recently.
mine = [r for r in rows if r["module"] == "25-ml"]
print(mine[-1]["result"] if mine else "did-not-run")
PY
)"
    if [ "$ml_result" = ok ]; then
        ok "25-ml recorded 'ok' (it must not skip on a machine with no GPU)"
    else
        bad "25-ml recorded '$ml_result'; it should have installed the CPU build"
    fi
else
    bad "no run record at $RECORD"
fi

# --- 20-nvidia left nothing behind on a machine it does not apply to ---------------------------
if [ -e /etc/cdl/nvidia.txt ]; then
    bad "/etc/cdl/nvidia.txt exists, but 20-nvidia skipped here"
else
    ok "20-nvidia wrote nothing (no /etc/cdl/nvidia.txt on a skipped machine)"
fi

# Re-running it directly must still skip, with exit 2 and not a failure.
bash /home/cdl/cdl-linux/install/modules/20-nvidia.sh >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then ok "re-running 20-nvidia here exits 2 (skip)"; else bad "re-running 20-nvidia exits $rc, want 2"; fi

# --- uv ----------------------------------------------------------------------------------------
want_uv="$(sed -n 's/^UV_VERSION=\(.*\)$/\1/p' /home/cdl/cdl-linux/install/modules/25-ml.sh)"
if [ -x /usr/local/bin/uv ]; then
    got_uv="$(/usr/local/bin/uv --version 2>/dev/null | awk '{print $2}')"
    if [ "$got_uv" = "$want_uv" ]; then ok "uv $got_uv installed, matching the pin"
    else bad "uv reports '$got_uv', pin says '$want_uv'"; fi
else
    bad "/usr/local/bin/uv is not installed"
fi
if [ -x /usr/local/bin/uvx ]; then ok "uvx installed alongside uv"; else bad "/usr/local/bin/uvx is missing"; fi

# --- the shared environment ----------------------------------------------------------------------
if [ -x "$VENV/bin/python" ]; then
    ok "$VENV/bin/python exists"
    if out="$("$VENV/bin/python" -c 'import torch; print(torch.__version__)' 2>&1)"; then
        ok "the venv imports torch ($out)"
        case "$out" in
            *+cpu) ok "torch is the CPU build, which is correct on a machine with no GPU" ;;
            *)     bad "torch is '$out'; a GPU-less machine must get the +cpu build" ;;
        esac
    else
        bad "the venv cannot import torch: $out"
    fi

    # stdout only: a warning on stderr (the NumPy one, before numpy was pinned) turned
    # "False" into "…UserWarning…False" and failed a correct machine.
    if cuda="$("$VENV/bin/python" -c 'import torch; print(torch.cuda.is_available())' 2>/dev/null)"; then
        if [ "$cuda" = "False" ]; then ok "torch.cuda.is_available() is False here, as it must be"
        else bad "torch.cuda.is_available() returned '$cuda' on a machine with no GPU"; fi
    else
        bad "torch.cuda.is_available() raised: $cuda"
    fi
else
    bad "$VENV/bin/python does not exist"
fi

# --- the acceptance check itself -----------------------------------------------------------------
if [ -x /usr/local/bin/cdl-ml-check ]; then
    ok "cdl-ml-check is installed and executable"
if warn_out="$("$VENV/bin/python" -c 'import torch, numpy' 2>&1 >/dev/null)" && [ -z "$warn_out" ]; then
    ok "torch and numpy import with nothing on stderr"
else bad "importing torch+numpy wrote to stderr: ${warn_out:0:120}"; fi
    if out="$(/usr/local/bin/cdl-ml-check 2>&1)"; then
        ok "cdl-ml-check exits 0 on this GPU-less machine (CPU torch)"
        if grep -q 'no NVIDIA GPU here' <<<"$out"; then
            ok "cdl-ml-check says why it is satisfied with a CPU build"
        else
            bad "cdl-ml-check said nothing about the absent GPU: $out"
        fi
    else
        bad "cdl-ml-check exited nonzero: $out"
    fi
else
    bad "/usr/local/bin/cdl-ml-check is not installed"
fi

# cdl-gpu-check belongs to 20-nvidia, which skipped, so it must be absent rather than
# installed-and-failing.
if [ -e /usr/local/bin/cdl-gpu-check ]; then
    bad "cdl-gpu-check is installed, but 20-nvidia skipped on this machine"
else
    ok "cdl-gpu-check is absent, as it should be where 20-nvidia skipped"
fi

# --- idempotence, for this module specifically ------------------------------------------------------
second="$(bash /home/cdl/cdl-linux/install/modules/25-ml.sh 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then ok "a second 25-ml run exits 0"; else bad "a second 25-ml run exited $rc: $second"; fi
if grep -q 'nothing to do' <<<"$second"; then
    ok "a second 25-ml run reports nothing to do"
else
    bad "a second 25-ml run did not report 'nothing to do': $second"
fi
if grep -qE '^\s+(installing:|fetched |creating the shared venv)' <<<"$second"; then
    bad "a second 25-ml run changed something: $second"
else
    ok "a second 25-ml run changed nothing"
fi

printf '\n  verify-nvidia-ml: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
