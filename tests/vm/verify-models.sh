#!/usr/bin/env bash
# Runs INSIDE the installed guest, as root. Checks what only a booted machine can show:
# that the model servers are actually serving, on the addresses spec §5.1 promises, and that
# the GPU lock in §6.1 really restarts what it stopped -- including after a SIGKILL, which is
# the case the spec singles out because a shell trap would miss it.
#
#   ssh cdl-vm 'sudo bash /repo/tests/vm/verify-models.sh'
#
# The VM is arm64 and has no GPU. Nothing here needs one: the lock contract is about
# serving-versus-training, and every branch of it is exercisable on a machine with no CUDA.
# What this cannot check is GPU behaviour itself -- that is §12's M1/G1 on the Tensorbook.

set -uo pipefail

pass=0; fail=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "must run as root inside the guest" >&2; exit 1; }

# A service state, as one word. Used everywhere below.
state() { systemctl is-active "$1" 2>/dev/null || true; }

# Wait up to $2 seconds for $1 to reach state $3. Returns 0 if it did.
wait_state() {
    local unit="$1" secs="$2" want="$3" i
    for ((i = 0; i < secs * 10; i++)); do
        [ "$(state "$unit")" = "$want" ] && return 0
        sleep 0.1
    done
    return 1
}

head_ "binaries"
for b in /opt/cdl/ollama/bin/ollama /opt/cdl/llama/llama-server /opt/cdl/llama-swap/llama-swap; do
    if [ -x "$b" ]; then ok "$b is present and executable"; else bad "$b missing"; fi
done
for b in ollama llama-server llama-swap cdl-models cdl-gpu; do
    if command -v "$b" >/dev/null 2>&1; then ok "$b is on PATH"; else bad "$b not on PATH"; fi
done
# Assert on what --version prints, not on its exit status: ollama's client returns non-zero
# when it cannot reach a server, which says nothing about whether the binary loaded. What is
# under test here is that the unpacked tree runs at all -- shared libraries resolved,
# architecture right.
version_says() {  # $1 label, $2 expected substring, $3.. command
    local label="$1" want="$2"; shift 2
    local out; out="$("$@" --version 2>&1 | head -3 | tr '\n' ' ')"
    if grep -qi -- "$want" <<<"$out"; then
        ok "$label --version runs: $out"
    else
        bad "$label --version printed nothing usable: $out"
    fi
}
version_says ollama       version /opt/cdl/ollama/bin/ollama
version_says llama-server version /opt/cdl/llama/llama-server
version_says llama-swap   version /opt/cdl/llama-swap/llama-swap

head_ "the model tree (spec §3.4)"
# owner, group, mode -- exactly what 30-models.sh sets, checked on the real filesystem.
for spec in "/srv/models:root:models:750" \
            "/srv/models/ollama:ollama:models:2750" \
            "/srv/models/gguf:root:models:2750"; do
    IFS=: read -r path owner group mode <<<"$spec"
    got="$(stat -c '%U:%G:%a' "$path" 2>/dev/null || echo missing)"
    check "$path is $owner:$group $mode" "$got" "$owner:$group:$mode"
done
for u in ollama llama; do
    if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx models; then
        ok "$u is in the models group"
    else
        bad "$u is not in the models group"
    fi
done
# The read-only half of §3.4: llama must not be able to write the tree it serves from.
if runuser -u llama -- test -w /srv/models/gguf 2>/dev/null; then
    bad "the llama user can write /srv/models/gguf; §3.4 says read-only"
else
    ok "the llama user cannot write /srv/models/gguf"
fi
if runuser -u llama -- test -w /srv/models/ollama 2>/dev/null; then
    bad "the llama user can write ollama's tree"
else
    ok "the llama user cannot write ollama's tree"
fi

head_ "ollama on 11434 (spec §5.1)"
check "ollama.service is active" "$(state ollama.service)" "active"
check "cdl-model-firewall.service is active" "$(state cdl-model-firewall.service)" "active"
tags="$(curl -fsS --max-time 10 http://127.0.0.1:11434/api/tags 2>&1)"
if printf '%s' "$tags" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "models" in d' 2>/dev/null; then
    ok "GET 127.0.0.1:11434/api/tags returns JSON with a models list"
else
    bad "127.0.0.1:11434/api/tags did not return the expected JSON: $(printf '%s' "$tags" | head -c 200)"
fi
if ss -ltnH 'sport = :11434' | grep -qE '(0\.0\.0\.0|\*):11434'; then
    ok "11434 listens on all interfaces (the fence, not the bind, keeps it off the LAN)"
else
    bad "11434 is not listening where the unit says: $(ss -ltnH 'sport = :11434')"
fi
# The fence itself. Without this rule the 0.0.0.0 bind is a LAN-exposed model endpoint.
if nft list table inet cdl_models >/dev/null 2>&1; then
    ok "the nftables table cdl_models is loaded"
    rules="$(nft list table inet cdl_models)"
    if grep -q 'tcp dport 11434' <<<"$rules" && grep -q 'drop' <<<"$rules"; then
        ok "11434 has an accept-then-drop rule"
    else
        bad "cdl_models has no 11434 drop rule: $rules"
    fi
    if grep -q 'lo' <<<"$rules" && grep -q 'tailscale0' <<<"$rules"; then
        ok "lo and tailscale0 are the accepted inputs"
    else
        bad "the accepted interfaces are not lo + tailscale0: $rules"
    fi
else
    bad "the nftables table cdl_models is not loaded; 11434 is open to the LAN"
fi

head_ "llama-swap on 127.0.0.1:8081 (spec §5.1)"
check "llama-swap.service is active" "$(state llama-swap.service)" "active"
if curl -fsS --max-time 10 http://127.0.0.1:8081/health >/dev/null 2>&1; then
    ok "GET 127.0.0.1:8081/health answers"
else
    bad "127.0.0.1:8081/health did not answer: $(curl -sS --max-time 10 http://127.0.0.1:8081/health 2>&1 | head -c 200)"
fi
listen8081="$(ss -ltnH 'sport = :8081' | awk '{print $4}')"
if [ -n "$listen8081" ] && ! grep -qE '(^|[^0-9.])(0\.0\.0\.0|\*):8081' <<<"$listen8081"; then
    ok "8081 is bound to loopback only ($listen8081)"
else
    bad "8081 is not loopback-only: '$listen8081'"
fi

head_ "the GPU lock: status and dry run (spec §6.1)"
check "the lock file exists" "$([ -e /run/cdl/gpu.lock ] && echo yes || echo no)" "yes"
check "the lock file is 0664 root:cdl" "$(stat -c '%a %U %G' /run/cdl/gpu.lock)" "664 root cdl"
if cdl-gpu status | grep -q 'gpu lock:  free'; then
    ok "cdl-gpu status reports the lock free before anything runs"
else
    bad "cdl-gpu status does not report a free lock: $(cdl-gpu status | head -3)"
fi
dry="$(cdl-gpu train --dry-run -- echo hello 2>&1)"
if grep -q 'would stop:' <<<"$dry" && grep -q 'ollama.service' <<<"$dry" && grep -q 'dry run' <<<"$dry"; then
    ok "--dry-run names what it would stop and changes nothing"
else
    bad "--dry-run output is wrong: $dry"
fi
check "--dry-run left ollama running" "$(state ollama.service)" "active"

head_ "the GPU lock: a job that exits normally"
before_ollama="$(state ollama.service)"
before_swap="$(state llama-swap.service)"
check "ollama is up before the job" "$before_ollama" "active"
check "llama-swap is up before the job" "$before_swap" "active"

# --force throughout: §6.1 says `cdl-gpu train` asks before stopping a live endpoint, and a
# script has no terminal to answer with. The refusal that happens without it is checked at
# the end, so the flag is not hiding an untested path.
cdl-gpu train --force -- sleep 5 > /tmp/cdl-gpu-normal.log 2>&1 &
job=$!
if wait_state ollama.service 15 inactive; then
    ok "ollama is stopped while the job holds the GPU"
else
    bad "ollama was still '$(state ollama.service)' during the job"
fi
check "llama-swap is stopped during the job" "$(state llama-swap.service)" "inactive"
if cdl-gpu status | grep -q 'gpu lock:  HELD'; then
    ok "cdl-gpu status reports the lock HELD during the job"
else
    bad "status does not report the lock held: $(cdl-gpu status | head -3)"
fi
if cdl-gpu status | grep -q 'ollama.service llama-swap.service'; then
    ok "cdl-gpu status names the services it stopped"
else
    bad "status does not name the stopped services: $(cdl-gpu status)"
fi

# A second run while the first holds the lock must be refused, not queued.
second="$(cdl-gpu train --force -- true 2>&1)"; second_rc=$?
check "a second training run is refused" "$second_rc" "1"
if grep -qi 'already held' <<<"$second"; then
    ok "the refusal says the GPU is already held"
else
    bad "the refusal message is unclear: $second"
fi
check "the refused run did not stop anything else" "$(state ollama.service)" "inactive"

wait "$job"; job_rc=$?
check "the job's exit status reaches the caller" "$job_rc" "0"
if wait_state ollama.service 30 active; then ok "ollama is back after a normal exit"; else bad "ollama did not come back: $(state ollama.service)"; fi
if wait_state llama-swap.service 30 active; then ok "llama-swap is back after a normal exit"; else bad "llama-swap did not come back: $(state llama-swap.service)"; fi
check "the lock is free again" "$(cdl-gpu status | grep -c 'gpu lock:  free')" "1"

head_ "the GPU lock: a job that exits non-zero"
cdl-gpu train --force -- sh -c 'exit 3' > /tmp/cdl-gpu-nonzero.log 2>&1; rc=$?
check "a non-zero exit is propagated" "$rc" "3"
if wait_state ollama.service 30 active; then ok "ollama is back after a non-zero exit"; else bad "ollama did not come back after a failure"; fi
if wait_state llama-swap.service 30 active; then ok "llama-swap is back after a non-zero exit"; else bad "llama-swap did not come back after a failure"; fi

head_ "the GPU lock: SIGKILL, the case a shell trap misses"
cdl-gpu train --force -- sh -c 'kill -9 $$' > /tmp/cdl-gpu-sigkill.log 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then
    ok "a SIGKILLed job reports failure (exit $rc)"
else
    bad "a SIGKILLed job reported success"
fi
if wait_state ollama.service 30 active; then
    ok "ollama is back after SIGKILL (systemd's ExecStopPost ran)"
else
    bad "ollama did not come back after SIGKILL: $(state ollama.service)"
fi
if wait_state llama-swap.service 30 active; then
    ok "llama-swap is back after SIGKILL"
else
    bad "llama-swap did not come back after SIGKILL"
fi
if journalctl -t cdl-gpu --since '-5 min' 2>/dev/null | grep -q 'restarted ollama.service'; then
    ok "the restore is logged with the job it belongs to"
else
    bad "no restore log line from the restore script"
fi

head_ "the GPU lock: state is not left behind"
leftover="$(find /run/cdl/gpu -maxdepth 1 -name 'stopped-*' 2>/dev/null | wc -l | tr -d ' ')"
check "no stopped-* state files survive a finished job" "$leftover" "0"
check "no holder record survives a finished job" "$([ -e /run/cdl/gpu/holder ] && echo yes || echo no)" "no"

head_ "refusing to stop a live endpoint unasked"
noforce="$(cdl-gpu train -- true < /dev/null 2>&1)"; noforce_rc=$?
if [ "$noforce_rc" -ne 0 ] && grep -q -- '--force' <<<"$noforce"; then
    ok "without a terminal and without --force, the run is refused and names --force"
else
    bad "a non-interactive run without --force was not refused cleanly (rc=$noforce_rc): $noforce"
fi
check "the refused run left ollama running" "$(state ollama.service)" "active"

head_ "cdl-models"
if cdl-models status >/dev/null 2>&1; then ok "cdl-models status runs"; else bad "cdl-models status failed: $(cdl-models status 2>&1 | head -5)"; fi
if cdl-models status 2>&1 | grep -q 'ollama.service'; then ok "cdl-models status names the services"; else bad "cdl-models status does not list services"; fi
if cdl-models chat < /dev/null 2>&1 | grep -q 'terminal'; then
    ok "cdl-models chat refuses cleanly without a terminal"
else
    bad "cdl-models chat did not explain itself without a terminal"
fi

printf '\n\033[1m== %d passed, %d failed ==\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
