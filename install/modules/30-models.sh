#!/usr/bin/env bash
# Local model serving: Ollama on 11434, llama-swap -> llama-server on 8081 (spec §5).
#
# Everything here is a pinned release tarball verified by sha256. No vendor install script
# runs, because `curl | sh` cannot be pinned, cannot be checksummed and rewrites units this
# module owns. The checksums below were computed from the actual assets on 2026-09-05 and
# cross-checked against the publishers' own manifests where they publish one (ollama's
# `sha256sum.txt`, llama-swap's `_checksums.txt`); tests/test-models-gpu-lock.sh downloads
# every asset again and compares, so a silently re-cut release is a test failure.
#
# WHY OLLAMA BINDS 0.0.0.0 AND IS FENCED BY nftables.
# §5.1 wants 11434 answering on localhost and the tailnet but not the LAN, and §7.1 says the
# service must still start when Tailscale is not up. Ollama's OLLAMA_HOST takes exactly one
# host:port, so binding "the tailnet address" means:
#   - localhost stops working (one address, not two), and
#   - the unit cannot start before `tailscale ip -4` answers, which is precisely the state
#     §7.1 says the machine has to survive.
# A drop-in generated at ExecStartPre has both problems and adds a third: the address is
# fixed at start, so a node that joins the tailnet later serves nothing until someone
# restarts it. So the bind is 0.0.0.0 and the restriction lives in the kernel:
# /etc/cdl/models-firewall.nft accepts 11434 from `lo` and `tailscale0` and drops the rest.
# That is also exactly what §12's H1a tests ("from off-tailnet: the model port refused").
# The rule matches on `iifname`, not `iif`, because iifname is resolved per packet: the
# ruleset loads and is correct before tailscale0 exists, and starts matching when it does.
# ollama.service carries Requires= on the firewall unit, so the port cannot open on a
# machine where the rule failed to load.
#
# 8081 needs no rule: llama-swap binds 127.0.0.1 and is therefore unreachable off-box by
# construction rather than by policy.
#
# WHAT UPSTREAM DOES NOT SHIP. ggml-org/llama.cpp publishes no Linux CUDA binary -- the
# release carries ubuntu-x64 and ubuntu-arm64 (CPU), plus vulkan/rocm/sycl variants, and
# CUDA only for Windows. This module therefore installs the CPU build on both
# architectures. GPU serving on this box is Ollama's job (its tarball bundles its own CUDA
# runtime, see lib/ollama/cuda_v12 and cuda_v13). If the escape hatch on 8081 ever needs the
# GPU, the two honest routes are the `ubuntu-vulkan-x64` asset or a local build with
# -DGGML_CUDA=ON; both are a change to this file, not a runtime surprise.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

cdl_need_root "30-models"

# --- pinned versions ----------------------------------------------------------------------
OLLAMA_VERSION="v0.33.3"          # released 2026-09-02
LLAMA_BUILD="b10809"              # the build behind llama.cpp v0.4.0 (its nightly-tag.txt)
SWAP_VERSION="253"                # mostlygeek/llama-swap v253, released 2026-09-04

OLLAMA_BASE="https://github.com/ollama/ollama/releases/download/${OLLAMA_VERSION}"
LLAMA_BASE="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_BUILD}"
SWAP_BASE="https://github.com/mostlygeek/llama-swap/releases/download/v${SWAP_VERSION}"

case "$(cdl_arch)" in
    x86_64)
        OLLAMA_URL="$OLLAMA_BASE/ollama-linux-amd64.tar.zst"
        OLLAMA_SHA="c13cea8f3389db4145f8a6cb88d1747242a48639d7c13e3bda7c1ebdc6eebb2f"
        LLAMA_URL="$LLAMA_BASE/llama-${LLAMA_BUILD}-bin-ubuntu-x64.tar.gz"
        LLAMA_SHA="5e34434ddc6d03cd1584f403201aff0d4bd1a5793a72ff7e286532dfd1e4b941"
        SWAP_URL="$SWAP_BASE/llama-swap_${SWAP_VERSION}_linux_amd64.tar.gz"
        SWAP_SHA="91f4d0af56cd5471d0133d6f89db7a7db118a9cd6f8ecd2bbdffd50aa29e5eb6"
        ;;
    aarch64|arm64)
        OLLAMA_URL="$OLLAMA_BASE/ollama-linux-arm64.tar.zst"
        OLLAMA_SHA="4425a112af999ae6572c1ce211fbabeaca7bab23ed5860972acdfc0cc2358420"
        LLAMA_URL="$LLAMA_BASE/llama-${LLAMA_BUILD}-bin-ubuntu-arm64.tar.gz"
        LLAMA_SHA="f2b7333971e1b7b42e9268bfdbfa30f5f56e2897156084d2251385df94aec358"
        SWAP_URL="$SWAP_BASE/llama-swap_${SWAP_VERSION}_linux_arm64.tar.gz"
        SWAP_SHA="7ccf4e1920cf36c041e2cabe2388676a4755c9763c396cfb2f9fd46649788a90"
        ;;
    *)
        skip "30-models: no pinned model-server binaries for $(cdl_arch)"
        ;;
esac

OPT=/opt/cdl
DIST="$OPT/dist"        # the verified archives stay here: a re-run re-verifies instead of
                        # re-downloading, which is what makes idempotence cheap offline.
changed=0

# --- helpers --------------------------------------------------------------------------------
# A directory with an exact owner, group and mode. Returns 0 if it changed anything, 1 if it
# was already right, so the module can report "nothing changed" truthfully.
ensure_dir() {
    local p="$1" o="$2" g="$3" m="$4" cur
    if [ -d "$p" ]; then
        cur="$(stat -c '%U %G %a' "$p" 2>/dev/null)"
        [ "$cur" = "$o $g $m" ] && return 1
    fi
    mkdir -p "$p"      || die "cannot create $p"
    chown "$o:$g" "$p" || die "cannot set $o:$g on $p"
    chmod "$m" "$p"    || die "cannot set mode $m on $p"
    dim "    $p -> $o:$g $m"
    return 0
}

# A pinned tarball unpacked into a directory of our own, with the expected checksum recorded
# beside it. A second run compares the stamp and does nothing.
# $1 label  $2 url  $3 sha256  $4 dest under /opt/cdl  $5 --strip-components  $6.. extra tar args
install_pinned_tarball() {
    local label="$1" url="$2" sha="$3" dest="$4" strip="$5"; shift 5
    case "$dest" in "$OPT"/?*) : ;; *) die "refusing to unpack $label outside $OPT: $dest" ;; esac
    local archive
    archive="$DIST/$(basename "$url")"
    if [ -f "$dest/.cdl-stamp" ] && [ "$(cat "$dest/.cdl-stamp")" = "$sha" ]; then
        return 1
    fi
    mkdir -p "$DIST"
    cdl_fetch_verified "$url" "$archive" "$sha"
    rm -rf "$dest"; mkdir -p "$dest"
    tar -xf "$archive" -C "$dest" --strip-components="$strip" "$@" \
        || die "cannot unpack $label from $archive"
    printf '%s\n' "$sha" > "$dest/.cdl-stamp"
    ok "$label $(basename "$url") unpacked into $dest"
    return 0
}

# /usr/local/bin/<name> -> target, only rewritten when it points somewhere else.
link_bin() {
    local name="$1" target="$2"
    [ "$(readlink "/usr/local/bin/$name" 2>/dev/null)" = "$target" ] && return 1
    ln -sfn "$target" "/usr/local/bin/$name" || die "cannot link /usr/local/bin/$name"
    return 0
}

# --- packages -------------------------------------------------------------------------------
# zstd: ollama ships .tar.zst. nftables: the 11434 fence. curl/jq: cdl-models uses both.
cdl_apt_install ca-certificates curl jq zstd nftables

# --- users, groups and the model tree (§3.4) -------------------------------------------------
if ! getent group models >/dev/null; then
    groupadd --system models || die "cannot create group models"
    dim "    created group models"
    changed=1
fi

cdl_system_user ollama /srv/models/ollama
cdl_system_user llama  /srv/models/gguf

for u in ollama llama; do
    if ! id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx models; then
        usermod -aG models "$u" || die "cannot add $u to group models"
        dim "    added $u to group models"
        changed=1
    fi
done

# §3.4: "group-readable by a models group that all three join, so weights are shared without
# any service being able to modify another's". Group write is therefore absent everywhere:
# ollama writes its own tree as its owner, and nothing but root writes the GGUF tree. setgid
# keeps new blobs in the models group so the sharing survives whatever umask is in force.
ensure_dir /srv/models       root   models 0750 && changed=1
ensure_dir /srv/models/ollama ollama models 2750 && changed=1
ensure_dir /srv/models/gguf  root   models 2750 && changed=1

# --- binaries ---------------------------------------------------------------------------------
install_pinned_tarball ollama     "$OLLAMA_URL" "$OLLAMA_SHA" "$OPT/ollama"     0 --zstd && changed=1
install_pinned_tarball llama.cpp  "$LLAMA_URL"  "$LLAMA_SHA"  "$OPT/llama"      1 && changed=1
install_pinned_tarball llama-swap "$SWAP_URL"   "$SWAP_SHA"   "$OPT/llama-swap" 0 llama-swap && changed=1

for f in "$OPT/ollama/bin/ollama" "$OPT/llama/llama-server" "$OPT/llama-swap/llama-swap"; do
    [ -x "$f" ] || die "unpacked tree is missing $f"
done

link_bin ollama      "$OPT/ollama/bin/ollama"     && changed=1
link_bin llama-server "$OPT/llama/llama-server"   && changed=1
link_bin llama-swap  "$OPT/llama-swap/llama-swap" && changed=1

# --- llama-swap configuration -------------------------------------------------------------------
# Deliberately empty of models. §12's M2 says llama-swap exists only when a concrete Responses
# or Anthropic requirement appears, and a config naming models nobody has downloaded would
# make the service fail its health checks on every boot for a capability nobody asked for.
# The commented example is the whole documentation anyone needs to add the first one.
if cdl_write_if_changed "$CDL_ETC/llama-swap.yaml" <<SWAP_YAML; then changed=1; fi
$CDL_MANAGED
#
# llama-swap: the escape hatch on 127.0.0.1:8081 (spec §5.1). Ollama on 11434 is the
# endpoint; this exists for the OpenAI Responses and Anthropic Messages APIs that
# llama-server serves and Ollama does not.
#
# Add a model by dropping a .gguf into /srv/models/gguf (as root -- the service reads that
# tree and must never be able to write it) and uncommenting a block like this one:
#
# models:
#   "qwen3-4b":
#     cmd: >
#       /opt/cdl/llama/llama-server
#       --port \${PORT}
#       --model /srv/models/gguf/qwen3-4b-q4_k_m.gguf
#       --ctx-size 8192
#     ttl: 300
#
# \${PORT} is filled in by llama-swap. \`ttl\` unloads an idle model, which is how 16 GB of
# VRAM (§5.3) serves more than one.

healthCheckTimeout: 300
logLevel: info
models: {}
SWAP_YAML

# --- the 11434 fence ------------------------------------------------------------------------------
# `table` then `delete table` then the real definition: that idiom makes the file reloadable,
# because deleting a table that does not exist is an error and not deleting it makes a second
# load append duplicate rules. policy accept, so this table only ever decides 11434.
if cdl_write_if_changed "$CDL_ETC/models-firewall.nft" <<'MODELS_NFT'; then changed=1; fi
#!/usr/sbin/nft -f
# managed by cdl-linux; edits here are overwritten by ./install.sh
#
# 11434 is reachable from this machine and from the tailnet, and from nowhere else (§5.1,
# §12 H1a). iifname is matched by name per packet, so this loads correctly before
# tailscale0 exists and starts matching the moment it does -- which is what lets
# ollama.service start when Tailscale is down (§7.1).
table inet cdl_models
delete table inet cdl_models
table inet cdl_models {
    chain input {
        type filter hook input priority filter; policy accept;
        tcp dport 11434 iifname { "lo", "tailscale0" } accept
        tcp dport 11434 drop
    }
}
MODELS_NFT

# The hardening block from §3.4 is deliberately NOT copied onto this unit. nft loads
# nf_tables and its chain modules on first use, so ProtectKernelModules=true would make it
# fail on a fresh boot with an error that does not mention systemd -- the same trap §3.4
# documents for MemoryDenyWriteExecute. It runs one command as root and exits.
if cdl_write_unit cdl-model-firewall.service <<FIREWALL_UNIT; then changed=1; fi
$CDL_MANAGED
[Unit]
Description=cdl-linux model endpoint firewall (11434: loopback and tailnet only)
Documentation=file://$CDL_ETC/models-firewall.nft
After=network-pre.target
Before=ollama.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $CDL_ETC/models-firewall.nft
ExecStop=-/usr/sbin/nft delete table inet cdl_models
NoNewPrivileges=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
FIREWALL_UNIT

# --- units ------------------------------------------------------------------------------------------
# The hardening block is §3.4's, line for line, including the comments that say why each line
# is there. PrivateDevices is absent on both: the GPU is /dev/nvidia*, and §3.4 names that
# exception explicitly.
if cdl_write_unit ollama.service <<OLLAMA_UNIT; then changed=1; fi
$CDL_MANAGED
[Unit]
Description=Ollama model server (cdl-linux)
Documentation=https://github.com/ollama/ollama
Wants=network-online.target
After=network-online.target cdl-model-firewall.service
# Not Wants=: if the fence did not load, 11434 must not open. See the header of
# install/modules/30-models.sh for why the bind is 0.0.0.0 in the first place.
Requires=cdl-model-firewall.service

[Service]
Type=exec
User=ollama
Group=ollama
SupplementaryGroups=models
Environment=HOME=/srv/models/ollama
Environment=OLLAMA_MODELS=/srv/models/ollama
Environment=OLLAMA_HOST=0.0.0.0:11434
ExecStart=$OPT/ollama/bin/ollama serve
Restart=on-failure
RestartSec=3

NoNewPrivileges=true          # no setuid escalation from a compromised model server
PrivateTmp=true               # a scratch file cannot be read by another service
ProtectSystem=strict          # / is read-only; only ReadWritePaths are not
ProtectHome=true              # /home is invisible: no service has business there
ReadWritePaths=/srv/models/ollama  # exactly one directory, named per service
ProtectKernelTunables=true
ProtectKernelModules=true     # nothing here loads a module
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=false  # false, deliberately: JIT and CUDA need W+X and would break

[Install]
WantedBy=multi-user.target
OLLAMA_UNIT

# llama has no ReadWritePaths, and that absence is the enforcement behind §3.4's "read-only"
# for this service: ProtectSystem=strict leaves nothing writable, ReadOnlyPaths names the one
# tree it may read, and PrivateTmp gives it the scratch space llama-server actually uses.
if cdl_write_unit llama-swap.service <<SWAP_UNIT; then changed=1; fi
$CDL_MANAGED
[Unit]
Description=llama-swap -> llama-server (cdl-linux escape hatch on 127.0.0.1:8081)
Documentation=https://github.com/mostlygeek/llama-swap
Wants=network-online.target
After=network-online.target

[Service]
Type=exec
User=llama
Group=llama
SupplementaryGroups=models
Environment=HOME=/srv/models/gguf
ExecStart=$OPT/llama-swap/llama-swap --config $CDL_ETC/llama-swap.yaml --listen 127.0.0.1:8081
Restart=on-failure
RestartSec=3

NoNewPrivileges=true          # no setuid escalation from a compromised model server
PrivateTmp=true               # a scratch file cannot be read by another service
ProtectSystem=strict          # / is read-only; only ReadWritePaths are not
ProtectHome=true              # /home is invisible: no service has business there
ReadOnlyPaths=/srv/models/gguf     # exactly one directory, named per service, read-only
ProtectKernelTunables=true
ProtectKernelModules=true     # nothing here loads a module
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=false  # false, deliberately: JIT and CUDA need W+X and would break

[Install]
WantedBy=multi-user.target
SWAP_UNIT

# --- cdl-models -----------------------------------------------------------------------------------------
# §9.1 lists `chat` as a console action, so local inference has to be one command from the
# home screen and not a recipe. The delimiter below is a contract with
# tests/test-models-gpu-lock.sh, which extracts this heredoc and lints it.
if cdl_write_if_changed /usr/local/bin/cdl-models <<'CDL_MODELS_SH'; then changed=1; fi
#!/usr/bin/env bash
# managed by cdl-linux; edits here are overwritten by ./install.sh
#
# The model servers, from the console: what is running, what is downloaded, and a chat.
#
#   cdl-models status        which servers are up, which models exist, GPU lock state
#   cdl-models pull <name>   download an Ollama model, as the ollama user
#   cdl-models chat [name]   talk to a local model right here (spec §9.1)
#   cdl-models list          the same inventory as `status`, without the service checks

set -uo pipefail

OLLAMA_BIN=/opt/cdl/ollama/bin/ollama
OLLAMA_ADDR="${OLLAMA_HOST:-127.0.0.1:11434}"
GGUF=/srv/models/gguf

c_ok=; c_bad=; c_dim=; c_off=
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_ok=$'\033[32m'; c_bad=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
fi
die() { printf '%s\n' "$*" >&2; exit 1; }

# Ollama's own client, run as the ollama user so anything it writes lands in the tree that
# user owns. Root is required for that; without it, fall back to talking to the server over
# the API as whoever we are, which is enough for read-only commands.
as_ollama() {
    if [ "$(id -u)" -eq 0 ]; then
        runuser -u ollama -- env HOME=/srv/models/ollama OLLAMA_MODELS=/srv/models/ollama \
            OLLAMA_HOST="$OLLAMA_ADDR" "$OLLAMA_BIN" "$@"
    else
        OLLAMA_HOST="$OLLAMA_ADDR" "$OLLAMA_BIN" "$@"
    fi
}

svc_line() {
    local unit="$1" state
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    if [ "$state" = active ]; then
        printf '  %sup%s    %s\n' "$c_ok" "$c_off" "$unit"
    else
        printf '  %sdown%s  %s (%s)\n' "$c_bad" "$c_off" "$unit" "${state:-unknown}"
    fi
}

cmd_status() {
    printf 'services\n'
    svc_line ollama.service
    svc_line llama-swap.service
    svc_line cdl-model-firewall.service

    printf '\nendpoints\n'
    if curl -fsS --max-time 5 "http://$OLLAMA_ADDR/api/tags" >/dev/null 2>&1; then
        printf '  %sok%s    http://%s  (Ollama, OpenAI chat-completions)\n' "$c_ok" "$c_off" "$OLLAMA_ADDR"
    else
        printf '  %sno%s    http://%s  (Ollama not answering)\n' "$c_bad" "$c_off" "$OLLAMA_ADDR"
    fi
    if curl -fsS --max-time 5 http://127.0.0.1:8081/health >/dev/null 2>&1; then
        printf '  %sok%s    http://127.0.0.1:8081  (llama-swap, Responses + Anthropic)\n' "$c_ok" "$c_off"
    else
        printf '  %sno%s    http://127.0.0.1:8081  (llama-swap not answering)\n' "$c_bad" "$c_off"
    fi

    printf '\n'
    cmd_list

    if command -v cdl-gpu >/dev/null 2>&1; then
        printf '\nGPU\n'
        cdl-gpu status | sed 's/^/  /'
    fi
}

cmd_list() {
    printf 'ollama models (/srv/models/ollama)\n'
    local tags
    tags="$(curl -fsS --max-time 5 "http://$OLLAMA_ADDR/api/tags" 2>/dev/null)"
    if [ -n "$tags" ]; then
        local names
        names="$(printf '%s' "$tags" | jq -r '.models[]?.name' 2>/dev/null)"
        if [ -n "$names" ]; then
            printf '%s\n' "$names" | sed 's/^/  /'
        else
            printf '  %s(none downloaded: cdl-models pull llama3.2)%s\n' "$c_dim" "$c_off"
        fi
    else
        printf '  %s(server not answering; cannot list)%s\n' "$c_dim" "$c_off"
    fi

    printf 'gguf models (%s)\n' "$GGUF"
    local ggufs
    ggufs="$(find "$GGUF" -maxdepth 1 -name '*.gguf' -printf '%f\t%s\n' 2>/dev/null | sort)"
    if [ -n "$ggufs" ]; then
        printf '%s\n' "$ggufs" | sed 's/^/  /'
    else
        printf '  %s(none: drop a .gguf in as root, then add it to /etc/cdl/llama-swap.yaml)%s\n' \
            "$c_dim" "$c_off"
    fi
}

cmd_pull() {
    [ $# -ge 1 ] || die "usage: cdl-models pull <model>   (for example: cdl-models pull llama3.2)"
    [ "$(systemctl is-active ollama.service 2>/dev/null)" = active ] \
        || die "ollama.service is not running; start it with: systemctl start ollama"
    as_ollama pull "$1"
}

cmd_chat() {
    local model="${1:-}"
    [ -t 0 ] || die "cdl-models chat needs a terminal. For scripted use, POST to http://$OLLAMA_ADDR/v1/chat/completions"
    [ "$(systemctl is-active ollama.service 2>/dev/null)" = active ] \
        || die "ollama.service is not running; start it with: systemctl start ollama"
    if [ -z "$model" ]; then
        model="$(curl -fsS --max-time 5 "http://$OLLAMA_ADDR/api/tags" 2>/dev/null \
                 | jq -r '.models[0].name // empty' 2>/dev/null)"
    fi
    [ -n "$model" ] || die "no model downloaded yet. Try: cdl-models pull llama3.2"
    printf '%stalking to %s on %s -- /bye to leave%s\n' "$c_dim" "$model" "$OLLAMA_ADDR" "$c_off"
    as_ollama run "$model"
}

case "${1:-status}" in
    status)      cmd_status ;;
    list)        cmd_list ;;
    pull)        shift; cmd_pull "$@" ;;
    chat)        shift; cmd_chat "$@" ;;
    -h|--help)   sed -n '4,10p' "$0" | sed -E 's/^#[[:space:]]?//' ;;
    *)           die "unknown command '$1' (try: status, list, pull, chat)" ;;
esac
CDL_MODELS_SH
chmod 0755 /usr/local/bin/cdl-models

# --- start ----------------------------------------------------------------------------------------------
if cdl_have_systemd; then
    cdl_enable_now cdl-model-firewall.service
    cdl_enable_now ollama.service
    cdl_enable_now llama-swap.service
    # Restart only what this run rewrote: an unchanged run must not interrupt a model
    # someone is talking to.
    if [ "$changed" -eq 1 ]; then
        systemctl try-restart ollama.service llama-swap.service
    fi
    ok "ollama on 11434 (lo + tailnet), llama-swap on 127.0.0.1:8081"
else
    warn "no systemd here: units written but not started"
fi

if [ "$changed" -eq 0 ]; then
    ok "30-models: already installed and configured; nothing changed"
else
    ok "30-models: Ollama $OLLAMA_VERSION, llama.cpp $LLAMA_BUILD, llama-swap v$SWAP_VERSION"
fi
exit 0
