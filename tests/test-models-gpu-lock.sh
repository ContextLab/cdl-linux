#!/usr/bin/env bash
# 30-models and 35-gpu-lock: everything about them that can be checked without installing
# them. Runs on macOS.
#
# Three of these checks talk to the network on purpose:
#
#   * every pinned sha256 in 30-models.sh is compared against a fresh download of the asset
#     it names, for BOTH architectures. That is about 3 GB per run, and it is the point: a
#     pin nobody re-verifies is a pin that silently rots when a release is re-cut. The bytes
#     are streamed through shasum and never written to disk.
#   * the same checksums are cross-checked against the publishers' own manifests where they
#     publish one, which catches a pin that is self-consistent but wrong.
#
# What is NOT here, because only a booted machine can show it: that the units start, that
# 11434 answers, that the nftables rule takes effect, and that the restart really survives a
# SIGKILL. Those are tests/vm/verify-models.sh, and they are absent here rather than faked.

# The single-quoted strings passed to `has`/`hasnt`/`grep` below are literal text to look
# for in the shipped files. They are not meant to expand, which is the whole point.
# shellcheck disable=SC2016

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has()  { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1 -- not found in $(basename "$3"): $2"; fi; }
hasnt(){ if grep -qF -- "$2" "$3"; then bad "$1 -- unexpectedly present in $(basename "$3"): $2"; else ok "$1"; fi; }
head_(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mod30="$repo/install/modules/30-models.sh"
mod35="$repo/install/modules/35-gpu-lock.sh"
vmtest="$repo/tests/vm/verify-models.sh"

for f in "$mod30" "$mod35" "$vmtest"; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

# The modules ship scripts and units inside heredocs. Everything below reads them out by
# delimiter, so the thing under test is the text that will land on the machine rather than a
# copy of it that can drift.
extract_block() {
    local file="$1" delim="$2"
    awk -v d="$delim" '
        BEGIN { start = "<<'"'"'?" d "'"'"'?" }
        !inb && $0 ~ start { inb = 1; next }
        inb && $0 == d { exit }
        inb { print }
    ' "$file"
}

extract_block "$mod30" CDL_MODELS_SH        > "$work/cdl-models"
extract_block "$mod30" OLLAMA_UNIT          > "$work/ollama.service"
extract_block "$mod30" SWAP_UNIT            > "$work/llama-swap.service"
extract_block "$mod30" FIREWALL_UNIT        > "$work/cdl-model-firewall.service"
extract_block "$mod30" MODELS_NFT           > "$work/models-firewall.nft"
extract_block "$mod30" SWAP_YAML            > "$work/llama-swap.yaml"
extract_block "$mod35" CDL_GPU_SH           > "$work/cdl-gpu"
extract_block "$mod35" CDL_GPU_RESTORE_SH   > "$work/gpu-restore"
chmod +x "$work/cdl-models" "$work/cdl-gpu" "$work/gpu-restore"

head_ "the shipped files were actually extracted"
for f in cdl-models cdl-gpu gpu-restore ollama.service llama-swap.service \
         cdl-model-firewall.service models-firewall.nft llama-swap.yaml; do
    if [ -s "$work/$f" ]; then ok "$f extracted ($(wc -l < "$work/$f" | tr -d ' ') lines)"
    else bad "$f is empty: the heredoc delimiter changed and this suite is testing nothing"; fi
done

head_ "shellcheck and syntax"
for f in "$mod30" "$mod35" "$vmtest"; do
    n="$(basename "$f")"
    if ! bash -n "$f"; then bad "$n does not parse"; continue; fi
    if command -v shellcheck >/dev/null 2>&1; then
        if (cd "$(dirname "$f")" && shellcheck -x "$n"); then ok "shellcheck -x $n"; else bad "shellcheck -x $n"; fi
    else
        ok "$n parses (shellcheck not installed)"
    fi
done
for f in cdl-models cdl-gpu gpu-restore; do
    if ! bash -n "$work/$f"; then bad "the shipped $f does not parse"; continue; fi
    if command -v shellcheck >/dev/null 2>&1; then
        if shellcheck "$work/$f"; then ok "shellcheck (shipped) $f"; else bad "shellcheck (shipped) $f"; fi
    else
        ok "shipped $f parses (shellcheck not installed)"
    fi
done

head_ "the module contract"
for f in "$mod30" "$mod35"; do
    n="$(basename "$f")"
    has "$n sets -uo pipefail"        'set -uo pipefail' "$f"
    has "$n carries the source-path directive" '# shellcheck source-path=SCRIPTDIR source=../lib.sh' "$f"
    has "$n sources lib.sh"           'source "$(dirname "$0")/../lib.sh"' "$f"
    has "$n calls cdl_need_root"      "cdl_need_root \"${n%.sh}\"" "$f"
    has "$n reports an unchanged run" 'nothing changed' "$f"
done
has "30-models writes owned files under /etc/cdl" '$CDL_ETC/llama-swap.yaml' "$mod30"
has "the shipped cdl-models carries the managed header" 'managed by cdl-linux' "$work/cdl-models"
has "the shipped cdl-gpu carries the managed header"    'managed by cdl-linux' "$work/cdl-gpu"
has "the shipped gpu-restore carries the managed header" 'managed by cdl-linux' "$work/gpu-restore"
has "the nftables ruleset carries the managed header"   'managed by cdl-linux' "$work/models-firewall.nft"

head_ "§3.4 users, groups and the model tree"
has "the models group is created"          'groupadd --system models' "$mod30"
has "the ollama system user is created"    'cdl_system_user ollama /srv/models/ollama' "$mod30"
has "the llama system user is created"     'cdl_system_user llama  /srv/models/gguf' "$mod30"
has "/srv/models is root:models 0750"      'ensure_dir /srv/models       root   models 0750' "$mod30"
has "/srv/models/ollama is ollama:models 2750" 'ensure_dir /srv/models/ollama ollama models 2750' "$mod30"
has "/srv/models/gguf is root:models 2750" 'ensure_dir /srv/models/gguf  root   models 2750' "$mod30"
# Group write anywhere in the tree would undo §3.4's "shared without any service being able
# to modify another's", so assert the absence rather than trusting the modes above.
if grep -qE 'ensure_dir /srv/models[^ ]* +[a-z]+ +models +[0-9]*[2367][0-9]?[0-9]?$' "$mod30"; then
    bad "a /srv/models directory is group-writable"
else
    ok "no /srv/models directory is group-writable"
fi

head_ "§3.4 hardening block, in every model-server unit"
# The block, line for line, from spec §3.4.
hardening=(
    'NoNewPrivileges=true'
    'PrivateTmp=true'
    'ProtectSystem=strict'
    'ProtectHome=true'
    'ProtectKernelTunables=true'
    'ProtectKernelModules=true'
    'ProtectControlGroups=true'
    'RestrictSUIDSGID=true'
    'RestrictNamespaces=true'
    'LockPersonality=true'
    'MemoryDenyWriteExecute=false'
)
for unit in ollama.service llama-swap.service; do
    for line in "${hardening[@]}"; do
        has "$unit: $line" "$line" "$work/$unit"
    done
    # §3.4 lists MemoryDenyWriteExecute=false *with its reason*, so that nobody adds it back
    # thinking it was an oversight. The comment is part of the requirement.
    if grep -q 'MemoryDenyWriteExecute=false.*deliberately' "$work/$unit"; then
        ok "$unit: MemoryDenyWriteExecute=false says why it is false"
    else
        bad "$unit: MemoryDenyWriteExecute=false has lost the comment explaining it"
    fi
    hasnt "$unit: PrivateDevices is not set (the GPU is /dev/nvidia*)" 'PrivateDevices' "$work/$unit"
    has "$unit: joins the models group" 'SupplementaryGroups=models' "$work/$unit"
done
has "ollama.service writes exactly its own tree" 'ReadWritePaths=/srv/models/ollama' "$work/ollama.service"
has "llama-swap.service gets /srv/models/gguf read-only" 'ReadOnlyPaths=/srv/models/gguf' "$work/llama-swap.service"
# The absence of a ReadWritePaths *directive* is the enforcement behind §3.4's "read-only"
# for this service. Matched at the start of a line, because ProtectSystem's own comment
# mentions ReadWritePaths and a substring match would pass on that.
if grep -qE '^ReadWritePaths=' "$work/llama-swap.service"; then
    bad "llama-swap.service has a writable path; §3.4 says its tree is read-only"
else
    ok "llama-swap.service has no ReadWritePaths= directive at all"
fi
check "ollama runs as the ollama user" "$(grep -c '^User=ollama$' "$work/ollama.service")" "1"
check "llama-swap runs as the llama user" "$(grep -c '^User=llama$' "$work/llama-swap.service")" "1"

# The firewall unit is the deliberate exception, and the reason has to be written down where
# the next person will look for it.
head_ "the firewall unit's exemption is deliberate and explained"
hasnt "cdl-model-firewall does not set ProtectKernelModules" 'ProtectKernelModules' "$work/cdl-model-firewall.service"
if grep -q 'ProtectKernelModules' "$mod30" && grep -q 'nf_tables' "$mod30"; then
    ok "30-models explains why nft cannot have ProtectKernelModules"
else
    bad "the firewall unit skips a hardening line with no explanation in the module"
fi

head_ "§5.1 addresses"
has "llama-swap binds 127.0.0.1:8081" '--listen 127.0.0.1:8081' "$work/llama-swap.service"
hasnt "llama-swap never binds a wildcard address" '--listen 0.0.0.0' "$work/llama-swap.service"
if grep -q 'llama-swap.yaml' "$work/llama-swap.service"; then ok "llama-swap reads /etc/cdl/llama-swap.yaml"; else bad "llama-swap has no config path"; fi

# The design decision under test: 0.0.0.0 is only acceptable with the kernel-side fence, so
# if the bind is a wildcard, the rule and the hard dependency on it must both be there.
if grep -q 'OLLAMA_HOST=0.0.0.0' "$work/ollama.service"; then
    ok "ollama binds 0.0.0.0 (localhost + tailnet, per the module header)"
    has "there is an nftables rule for 11434"      'tcp dport 11434' "$work/models-firewall.nft"
    has "the rule accepts loopback and tailscale0" 'iifname { "lo", "tailscale0" } accept' "$work/models-firewall.nft"
    has "the rule drops everything else on 11434"  'tcp dport 11434 drop' "$work/models-firewall.nft"
    has "the ruleset is reloadable (delete before define)" 'delete table inet cdl_models' "$work/models-firewall.nft"
    has "ollama.service will not start without the fence" 'Requires=cdl-model-firewall.service' "$work/ollama.service"
    has "ollama.service is ordered after the fence" 'After=network-online.target cdl-model-firewall.service' "$work/ollama.service"
    has "the fence unit loads the ruleset" 'nft -f' "$work/cdl-model-firewall.service"
    # iif would be resolved to a device index at load time and fail when tailscale0 does not
    # exist yet -- the §7.1 state the machine has to survive.
    if grep -qE '^\s*tcp dport 11434 iif ' "$work/models-firewall.nft"; then
        bad "the rule uses iif, which cannot load before tailscale0 exists (§7.1)"
    else
        ok "the rule uses iifname, so it loads with Tailscale down (§7.1)"
    fi
else
    ok "ollama does not bind a wildcard address; no firewall rule required"
fi
has "the ollama model tree is where §5.2 says" 'Environment=OLLAMA_MODELS=/srv/models/ollama' "$work/ollama.service"

head_ "cdl-models covers §9.1's console actions"
for sub in status pull chat; do
    if grep -qE "^\s+$sub\)" "$work/cdl-models"; then ok "cdl-models has a '$sub' subcommand"; else bad "cdl-models has no '$sub' subcommand"; fi
done
has "pull runs as the ollama user" 'runuser -u ollama' "$work/cdl-models"
has "chat is local inference at the console" 'as_ollama run' "$work/cdl-models"

head_ "§6.1 the lock contract"
has "the lock file is the one §6.1 names"     '/run/cdl/gpu.lock' "$mod35"
has "the holder is recorded separately"       '/run/cdl/gpu' "$mod35"
has "a tmpfiles.d rule creates it 0664 group cdl" 'f /run/cdl/gpu.lock 0664 root cdl -' "$mod35"
has "the cdl group is created"                'groupadd --system cdl' "$mod35"
has "the lock is exclusive and non-blocking"  'flock -n 9' "$work/cdl-gpu"
has "a held lock is refused, not queued"      'the GPU is already held' "$work/cdl-gpu"
has "train names what it will stop"           'This will stop, for the duration of the job' "$work/cdl-gpu"
has "--force skips the question"              '--force' "$work/cdl-gpu"
has "there is a --dry-run"                    '--dry-run' "$work/cdl-gpu"
has "status reports the holder"               'gpu_holder_report' "$work/cdl-gpu"
has "status reports which services were stopped" 'stopped for the running job' "$work/cdl-gpu"
# 35-gpu-lock must not skip itself on a machine with no GPU: the VM has no GPU and is where
# the contract is proven.
hasnt "35-gpu-lock does not require a GPU" 'cdl_require_gpu_or_skip' "$mod35"

head_ "§6.1 the restart survives SIGKILL, by systemd rather than by a trap"
has "the job runs as a transient systemd unit" 'systemd-run --collect --wait --unit' "$work/cdl-gpu"
has "the restore is the unit's ExecStopPost"   '-p "ExecStopPost=$CDL_GPU_RESTORE $job_id"' "$work/cdl-gpu"
has "the restore is a separate executable"     '/usr/local/lib/cdl/gpu-restore' "$mod35"
has "the restore starts the recorded services" 'systemctl start "$unit"' "$work/gpu-restore"
has "the restore reads the recorded list"      'stopped-$id' "$work/gpu-restore"
# The wrapper may not be the restart path for a running job. Its only `systemctl start` must
# be none at all: everything goes through the restore script, which systemd invokes.
check "cdl-gpu itself never restarts a service" "$(grep -c 'systemctl start' "$work/cdl-gpu")" "0"
has "the wrapper's trap is only a pre-launch safety net" 'launched' "$work/cdl-gpu"
if grep -q '\[ "\$launched" -eq 1 \] && return 0' "$work/cdl-gpu"; then
    ok "the trap disarms once systemd owns the job"
else
    bad "the trap does not disarm; two restore paths could race"
fi
if grep -qE "trap .* (SIGKILL|KILL|9)\b" "$work/cdl-gpu"; then
    bad "the wrapper pretends to trap SIGKILL, which is not trappable"
else
    ok "the wrapper does not pretend to trap SIGKILL"
fi

head_ "cdl-gpu's service list, against fixture systemctl output"
mkdir -p "$work/fakebin"
cat > "$work/fakebin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
# Fixture. `systemctl is-active <unit>` answers from FAKE_STATES="unit=state unit=state".
[ "$1" = is-active ] || { echo "fixture systemctl: unexpected '$*'" >&2; exit 64; }
for kv in ${FAKE_STATES:-}; do
    case "$kv" in
        "$2="*) printf '%s\n' "${kv#*=}"; [ "${kv#*=}" = active ] && exit 0; exit 3 ;;
    esac
done
printf 'inactive\n'; exit 3
FAKE_SYSTEMCTL
chmod +x "$work/fakebin/systemctl"

active_for() {  # $1 = FAKE_STATES, $2 = optional CDL_GPU_SERVICES override
    FAKE_STATES="$1" CDL_GPU_SERVICES="${2:-}" CDL_GPU_LIB_ONLY=1 PATH="$work/fakebin:$PATH" \
        bash -c 'source "$1"; gpu_active_services' _ "$work/cdl-gpu" | tr '\n' ' ' | sed 's/ $//'
}

check "both running -> both listed, in order" \
    "$(active_for 'ollama.service=active llama-swap.service=active')" \
    "ollama.service llama-swap.service"
check "only ollama running -> only ollama" \
    "$(active_for 'ollama.service=active llama-swap.service=inactive')" \
    "ollama.service"
check "only llama-swap running -> only llama-swap" \
    "$(active_for 'ollama.service=inactive llama-swap.service=active')" \
    "llama-swap.service"
check "neither running -> nothing to restart" \
    "$(active_for 'ollama.service=inactive llama-swap.service=inactive')" \
    ""
check "a failed service is not restarted afterwards" \
    "$(active_for 'ollama.service=failed llama-swap.service=active')" \
    "llama-swap.service"
# A unit mid-start is still stopped by `systemctl stop`, so it has to be on the list or the
# endpoint stays down after the job.
check "an activating service counts as running" \
    "$(active_for 'ollama.service=activating llama-swap.service=inactive')" \
    "ollama.service"
check "a reloading service counts as running" \
    "$(active_for 'ollama.service=reloading llama-swap.service=inactive')" \
    "ollama.service"
check "an unknown unit is not invented" \
    "$(active_for 'nothing.service=active')" \
    ""
check "the service list is overridable for tests" \
    "$(active_for 'a.service=active b.service=active' 'b.service a.service')" \
    "b.service a.service"

head_ "pinned versions and real checksums"
sed -n '/^# --- pinned versions/,/^esac$/p' "$mod30" > "$work/pins.sh"
check "the pin block was extracted" "$(grep -c '^OLLAMA_VERSION=' "$work/pins.sh")" "1"
cat > "$work/pins-driver.sh" <<'PINS_DRIVER'
cdl_arch() { printf '%s' "$CDL_ARCH"; }
skip() { printf 'SKIP %s\n' "$*" >&2; exit 2; }
# shellcheck disable=SC1090
source "$PINS"
printf '%s %s ollama\n'     "$OLLAMA_URL" "$OLLAMA_SHA"
printf '%s %s llama.cpp\n'  "$LLAMA_URL"  "$LLAMA_SHA"
printf '%s %s llama-swap\n' "$SWAP_URL"   "$SWAP_SHA"
PINS_DRIVER

assets="$work/assets.txt"
: > "$assets"
for arch in x86_64 aarch64; do
    if CDL_ARCH="$arch" PINS="$work/pins.sh" bash "$work/pins-driver.sh" >> "$assets" 2>/dev/null; then
        ok "the module pins all three components for $arch"
    else
        bad "the module has no pins for $arch"
    fi
done
check "six assets are pinned (three components, two architectures)" "$(wc -l < "$assets" | tr -d ' ')" "6"

# Cross-check against the publishers' own manifests first: cheap, and it catches a pin that
# is internally consistent but does not match what upstream says it shipped.
ollama_manifest="$(curl -fsSL --max-time 60 https://github.com/ollama/ollama/releases/download/v0.33.3/sha256sum.txt 2>/dev/null)"
swap_manifest="$(curl -fsSL --max-time 60 https://github.com/mostlygeek/llama-swap/releases/download/v253/llama-swap_253_checksums.txt 2>/dev/null)"
if [ -n "$ollama_manifest" ]; then ok "fetched ollama's published sha256sum.txt"; else bad "could not fetch ollama's sha256sum.txt"; fi
if [ -n "$swap_manifest" ]; then ok "fetched llama-swap's published checksums"; else bad "could not fetch llama-swap's checksums"; fi

while read -r url want component; do
    [ -n "$url" ] || continue
    base="$(basename "$url")"
    case "$component" in
        ollama)     line="$(grep -F " ./$base" <<<"$ollama_manifest" | awk '{print $1}')" ;;
        llama-swap) line="$(grep -F " $base"   <<<"$swap_manifest"   | awk '{print $1}')" ;;
        *)          line="" ;;
    esac
    if [ -n "$line" ]; then
        check "$base matches the publisher's own manifest" "$line" "$want"
    fi
done < "$assets"

# And now the real thing: download each asset and hash the bytes. Streamed, so ~3 GB moves
# through memory and nothing is written to disk. Gated: that much network does not belong
# in the fast suite; tests/run-net.sh sets CDL_NET_TESTS=1 and runs it on purpose.
if [ -n "${CDL_NET_TESTS:-}" ]; then
    while read -r url want component; do
        [ -n "$url" ] || continue
        base="$(basename "$url")"
        got="$(curl -fsSL --retry 2 --max-time 900 "$url" | shasum -a 256 | awk '{print $1}')"
        rc=${PIPESTATUS[0]}
        if [ "$rc" -ne 0 ]; then
            bad "$component: could not download $base (curl exit $rc)"
            continue
        fi
        check "$component: $base sha256 matches a fresh download" "$got" "$want"
    done < "$assets"
else
    printf '  skip  asset checksums vs fresh downloads, ~3 GB (set CDL_NET_TESTS=1, or run tests/run-net.sh)\n'
fi

printf '\n\033[1m== %d passed, %d failed ==\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
