#!/usr/bin/env bash
# The agent CLIs: three pinned, redistributable release binaries, plus Claude Code, which
# is neither (spec §4). And the credential launcher that fronts all four (spec §4.1, §4.2).
#
# codex and opencode ship real Linux release binaries for both supported architectures.
# gemini-cli does not: its GitHub releases carry only a cross-platform npm bundle and
# unsigned darwin zips, no standalone Linux binary (checked against the v0.58.0 release
# assets on 2026-09-05). It is npm-only, so it needs Node.js, which is not part of 10-base
# because nothing else here does. Node comes from the NodeSource apt repo (current Active
# LTS, Node 24) rather than Ubuntu's own package, which lags upstream by a major version.
#
# Claude Code carries no licence field in its repository (verified via `gh api
# repos/anthropics/claude-code`), so it cannot be redistributed. cdl-agent runs the vendor
# installer itself, on first use, as the invoking user -- never here at install time.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

cdl_need_root "40-agents"

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR=/opt/cdl/bin
CACHE_DIR=/opt/cdl/lib/agents

# --- pinned versions and checksums ----------------------------------------------------
# Refreshed deliberately and together (spec §11.3), never automatically. Re-pin by editing
# these four lines (plus GEMINI_VERSION below) and re-running this module.
CODEX_VERSION=0.153.4
CODEX_TAG="rust-v${CODEX_VERSION}"
CODEX_SHA256_X86_64=f479424eca092484dc40d87ae28c44f4cc40234a60045d6131e493800d814a30
CODEX_SHA256_AARCH64=5cda6182bd94c3a30f2eb63a495489ebf7f691fddb14d70f48c6c1a5071b6cde

OPENCODE_VERSION=1.18.29
OPENCODE_SHA256_X86_64=ea800b7ff56226b70952126c9fc1e2517ca4c4b5682fd9d3f9e87449697a1194
OPENCODE_SHA256_AARCH64=70baf769395ca4e7a68924026530c390eace194f3b7e4919d4efcb2aa2eed3c0

# gemini-cli: npm only (see header). Version is pinned by the explicit @version in the
# `npm install -g` call below; npm itself verifies the package's integrity hash against
# the registry, which is what a checksum would do here for a binary.
GEMINI_VERSION=0.58.0
NODE_MAJOR=24

case "$(cdl_arch)" in
    x86_64)  DPKG_ARCH=amd64; CODEX_ASSET_ARCH=x86_64; CODEX_SHA256="$CODEX_SHA256_X86_64"
             OPENCODE_ASSET_ARCH=x64;   OPENCODE_SHA256="$OPENCODE_SHA256_X86_64" ;;
    aarch64) DPKG_ARCH=arm64; CODEX_ASSET_ARCH=aarch64; CODEX_SHA256="$CODEX_SHA256_AARCH64"
             OPENCODE_ASSET_ARCH=arm64; OPENCODE_SHA256="$OPENCODE_SHA256_AARCH64" ;;
    *) die "40-agents: unsupported architecture $(cdl_arch) (codex and opencode ship only x86_64 and aarch64)" ;;
esac

mkdir -p "$BIN_DIR" "$CACHE_DIR"

# $1 name  $2 version  $3 url  $4 sha256  $5 member (the single file inside the tarball)
# Idempotent via a version stamp: a binary already at the pinned version is left alone,
# with no network access and no re-extraction, so a second run is silent and fast.
cdl_install_release_cli() {
    local name="$1" version="$2" url="$3" sha256="$4" member="$5"
    local target="$BIN_DIR/$name" stamp="$CACHE_DIR/${name}.version"
    local archive
    archive="$CACHE_DIR/${name}-${version}-$(cdl_arch).tar.gz"

    # The stamp records version AND checksum. A stamp keyed on version alone let a repinned
    # artefact of the same version -- opencode's musl build swapped for the glibc one --
    # report "already installed" while the old binary stayed on disk; measured on the VM.
    if [ -x "$target" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$version $sha256" ]; then
        ok "$name $version already installed"
        return 0
    fi

    cdl_fetch_verified "$url" "$archive" "$sha256"

    local extract_dir
    extract_dir="$(mktemp -d)"
    tar -xzf "$archive" -C "$extract_dir" || die "cannot extract $archive"
    [ -f "$extract_dir/$member" ] || die "$name $version archive did not contain expected file '$member'"

    install -m 0755 "$extract_dir/$member" "$target.new"
    mv -f "$target.new" "$target"
    rm -rf "$extract_dir"
    printf '%s %s' "$version" "$sha256" > "$stamp"
    ok "installed $name $version"
}

# $1 name  $2 target under BIN_DIR
cdl_symlink_agent_bin() {
    local name="$1"
    local link="/usr/local/bin/$name" target="$BIN_DIR/$name"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
        return 0
    fi
    ln -sf "$target" "$link"
    dim "    linked $link -> $target"
}

# --- codex (Apache-2.0, pinned release binary) -----------------------------------------
cdl_install_release_cli codex "$CODEX_VERSION" \
    "https://github.com/openai/codex/releases/download/${CODEX_TAG}/codex-${CODEX_ASSET_ARCH}-unknown-linux-musl.tar.gz" \
    "$CODEX_SHA256" \
    "codex-${CODEX_ASSET_ARCH}-unknown-linux-musl"
cdl_symlink_agent_bin codex

# --- opencode (MIT, pinned release binary) ---------------------------------------------
# The glibc build, NOT the -musl one. The musl tarball needs /lib/ld-musl-<arch>.so.1, which
# Ubuntu does not ship, and exec fails with "required file not found" -- measured on the VM.
cdl_install_release_cli opencode "$OPENCODE_VERSION" \
    "https://github.com/sst/opencode/releases/download/v${OPENCODE_VERSION}/opencode-linux-${OPENCODE_ASSET_ARCH}.tar.gz" \
    "$OPENCODE_SHA256" \
    "opencode"
cdl_symlink_agent_bin opencode

# --- gemini-cli (Apache-2.0, npm-only -- see header) -----------------------------------
GEMINI_STAMP="$CACHE_DIR/gemini.version"
if [ -f "$GEMINI_STAMP" ] && [ "$(cat "$GEMINI_STAMP")" = "$GEMINI_VERSION" ] && command -v gemini >/dev/null 2>&1; then
    ok "gemini-cli $GEMINI_VERSION already installed"
else
    cdl_apt_source nodesource "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
"Types: deb
URIs: https://deb.nodesource.com/node_${NODE_MAJOR}.x
Suites: nodistro
Components: main
Architectures: $DPKG_ARCH"
    cdl_apt_install nodejs

    npm install -g --silent "@google/gemini-cli@${GEMINI_VERSION}" \
        || die "npm install -g @google/gemini-cli@${GEMINI_VERSION} failed"
    gemini_bin="$(command -v gemini)" || die "npm reported success but 'gemini' is not on PATH"

    # npm puts the binary wherever its prefix says (Node from NodeSource defaults to
    # /usr, so this is normally /usr/bin/gemini). Fronting it with the same /opt/cdl/bin
    # symlink as the other three keeps `cdl-agent list` and PATH expectations uniform,
    # regardless of where npm decided to put the real thing.
    ln -sf "$gemini_bin" "$BIN_DIR/gemini"
    printf '%s' "$GEMINI_VERSION" > "$GEMINI_STAMP"
    ok "installed gemini-cli $GEMINI_VERSION (npm, Node ${NODE_MAJOR}.x)"
fi
cdl_symlink_agent_bin gemini

# --- cdl-agent: the per-process credential launcher (spec §4.1, §4.2) ------------------
# A standalone file at install/bin/cdl-agent, not a heredoc here, so it can be shellchecked
# and unit-tested directly (see tests/test-agents.sh), the same pattern 20-nvidia.sh uses
# for cdl-gpu-check.
CDL_AGENT_SCRIPT=/usr/local/bin/cdl-agent
note_changed=0
if cdl_write_if_changed "$CDL_AGENT_SCRIPT" < "$HERE/../bin/cdl-agent"; then note_changed=1; fi
chmod 0755 "$CDL_AGENT_SCRIPT"

# --- /etc/cdl/keys.example --------------------------------------------------------------
KEYS_EXAMPLE="$CDL_ETC/keys.example"
if cdl_write_if_changed "$KEYS_EXAMPLE" <<'KEYS_EOF'
# managed by cdl-linux; edits here are overwritten by ./install.sh
#
# Template for ~/.config/cdl/keys, read by cdl-agent (spec §4.1). Copy it there, fill in
# what you use, and lock it down -- cdl-agent refuses a keys file that is not mode 0600
# and owned by you:
#
#   install -m 0600 /etc/cdl/keys.example ~/.config/cdl/keys
#
# One KEY=value per line. A key you don't use can stay blank or be left out entirely;
# cdl-agent only exports what a given agent needs, and only into that agent's process.

# claude (Claude Code): optional. cdl-agent never sets ANTHROPIC_BASE_URL or any of the
# telemetry/tracking variables for claude -- see spec §4.1 for why.
ANTHROPIC_API_KEY=

# codex
OPENAI_API_KEY=

# gemini (gemini-cli)
GEMINI_API_KEY=

# opencode: resolves providers via models.dev, so any of the above plus these. Both
# spellings of each divergent variable are exported together when the value below is set.
OPENROUTER_API_KEY=
TOGETHER_API_KEY=
FIREWORKS_API_KEY=
KEYS_EOF
then note_changed=1; fi
chmod 0644 "$KEYS_EXAMPLE"

# Printed once, on the run that actually installed or updated something -- not on every
# idempotent re-run.
if [ "$note_changed" -eq 1 ]; then
    log ""
    log "    To use the agent CLIs, create your credentials file once:"
    log ""
    log "        install -m 0600 /etc/cdl/keys.example ~/.config/cdl/keys"
    log ""
    log "    then edit it and run e.g. 'cdl-agent codex'. 'cdl-agent list' shows what's"
    log "    installed and which keys are present (never their values)."
fi

ok "agent CLIs installed: codex $CODEX_VERSION, opencode $OPENCODE_VERSION, gemini-cli $GEMINI_VERSION"
exit 0
