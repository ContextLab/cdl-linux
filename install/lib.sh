#!/usr/bin/env bash
# Shared helpers for install.sh and its modules. Sourced, never executed.
#
# Every module runs as its own process with this sourced, so a module cannot leak shell
# state into the next one, and a module that calls `exit` ends itself rather than the run.

# --- output ------------------------------------------------------------------------------
# Colour only when stdout is a terminal: a piped or logged run must stay greppable.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_OK=; C_WARN=; C_ERR=; C_DIM=; C_OFF=
fi

log()  { printf '%s\n' "$*" >&2; }
ok()   { printf '%s  ok  %s%s\n'   "$C_OK"   "$C_OFF" "$*" >&2; }
warn() { printf '%swarn%s %s\n'    "$C_WARN" "$C_OFF" "$*" >&2; }
err()  { printf '%sFAIL%s %s\n'    "$C_ERR"  "$C_OFF" "$*" >&2; }
dim()  { printf '%s%s%s\n'         "$C_DIM"  "$*"     "$C_OFF" >&2; }
die()  { err "$*"; exit 1; }

# die() EXITS. So do the helpers below that call it: cdl_need_root, cdl_apt_install,
# cdl_apt_source, cdl_fetch_verified, cdl_system_user and cdl_enable_now. That is the
# intended behaviour -- a module that cannot install what it needs must stop -- but it
# means none of them can be tested with a plain `if`:
#
#     if cdl_fetch_verified "$url" "$dest" "$sha"; then ... else <FALLBACK> fi
#
# The else branch there is unreachable. On failure the module exits and the fallback never
# runs, which is worse than no fallback because the code says one is there. When a module
# genuinely has something to fall back to, run the call in a subshell so the exit becomes
# a status the `if` can read (the fetched file still lands on disk):
#
#     if ( cdl_fetch_verified "$url" "$dest" "$sha" ); then ... else <FALLBACK> fi
#
# 52-branding.sh does this for the boot logo, and tests/test-console.sh asserts it.

# --- module exit contract ----------------------------------------------------------------
# 0  the module's work is done (whether it acted or found nothing to do)
# 2  the module does not apply to this machine, and that is not an error
# *  failure: the run stops, and later modules do not run
CDL_SKIP=2
skip() { warn "$*"; exit "$CDL_SKIP"; }

# --- environment -------------------------------------------------------------------------
# CDL_OS_RELEASE exists so the preflight can be exercised against a fixture without
# pretending to be a different machine. It is never set in normal use.
cdl_os_release() { printf '%s' "${CDL_OS_RELEASE:-/etc/os-release}"; }

cdl_os_id()      { awk -F= '$1=="ID"{gsub(/"/,"",$2);print $2}'         "$(cdl_os_release)" 2>/dev/null; }
cdl_os_version() { awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2);print $2}' "$(cdl_os_release)" 2>/dev/null; }
cdl_arch()       { printf '%s' "${CDL_ARCH:-$(uname -m)}"; }

cdl_is_root()        { [ "$(id -u)" -eq 0 ]; }
cdl_need_root()      { cdl_is_root || die "$1 needs root; re-run with sudo"; }
cdl_is_interactive() { [ -t 0 ] && [ -t 1 ]; }

# --- idempotence helpers -----------------------------------------------------------------
# Back up before modifying, once per run, keeping the original mode and owner. A module
# that edits a file the user may have written must call this first.
cdl_backup_file() {
    local f="$1" stamp="${CDL_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
    [ -e "$f" ] || return 0
    local b="${f}.cdl-backup-${stamp}"
    [ -e "$b" ] && return 0
    cp -a "$f" "$b" && dim "    backed up $f -> $b"
}

# Write content to a file only if it differs, so a second run reports no change.
# Returns 0 if it wrote, 1 if the file was already correct.
cdl_write_if_changed() {
    local f="$1"; shift
    local new; new="$(cat)"
    if [ -f "$f" ] && [ "$(cat "$f")" = "$new" ]; then
        return 1
    fi
    cdl_backup_file "$f"
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$new" > "$f"
    return 0
}

cdl_have()        { command -v "$1" >/dev/null 2>&1; }
cdl_pkg_present() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }

# --- hardware and platform ---------------------------------------------------------------
cdl_is_x86_64()     { [ "$(cdl_arch)" = x86_64 ]; }
# NVIDIA present on the PCI bus. Not "driver loaded": that is what 20-nvidia establishes.
# Read from sysfs, which needs no package: the earlier `lspci | grep` treated a MISSING
# lspci (pciutils is not installed by anything here) as "no GPU", which would have sent the
# Tensorbook silently down the CPU-torch path. Vendor 0x10de is NVIDIA.
cdl_has_nvidia_gpu() {
    [ -n "${CDL_FAKE_NVIDIA:-}" ] && return 0
    local v
    for v in /sys/bus/pci/devices/*/vendor; do
        [ -r "$v" ] && [ "$(cat "$v" 2>/dev/null)" = "0x10de" ] && return 0
    done
    return 1
}
# GPU-dependent modules call this first and skip cleanly elsewhere. Every other machine --
# the arm64 VM, a laptop without a discrete GPU -- gets everything else.
cdl_require_gpu_or_skip() {
    if cdl_is_x86_64 && cdl_has_nvidia_gpu; then return 0; fi
    skip "$1: no x86_64 NVIDIA GPU here; skipping"
}

# --- apt ---------------------------------------------------------------------------------
cdl_apt_update_once() {
    [ -n "${_CDL_APT_UPDATED:-}" ] && return 0
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || return 1
    _CDL_APT_UPDATED=1
}
# Install only what is missing; a second run installs nothing and reports nothing.
cdl_apt_install() {
    local missing=() p
    for p in "$@"; do cdl_pkg_present "$p" || missing+=("$p"); done
    [ "${#missing[@]}" -eq 0 ] && return 0
    cdl_apt_update_once || die "apt-get update failed"
    dim "    installing: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 \
        || die "apt-get install failed for: ${missing[*]}"
    for p in "${missing[@]}"; do cdl_pkg_present "$p" || die "apt reported success but $p is not installed"; done
    _CDL_APT_UPDATED=   # new source lists may follow; force a refresh next time
}
# A vendor APT source: keyring under /etc/apt/keyrings, one .sources file, both idempotent.
# $1 name  $2 key URL  $3 the deb822 body (Types/URIs/Suites/Components), Signed-By added.
cdl_apt_source() {
    local name="$1" key_url="$2" body="$3" changed=0
    local keyring="/etc/apt/keyrings/$name.gpg"
    mkdir -p /etc/apt/keyrings
    if [ ! -s "$keyring" ]; then
        curl -fsSL "$key_url" | gpg --dearmor -o "$keyring" 2>/dev/null || die "cannot fetch signing key for $name"
        chmod 0644 "$keyring"; changed=1
    fi
    if cdl_write_if_changed "/etc/apt/sources.list.d/$name.sources" <<<"$body
Signed-By: $keyring"; then changed=1; fi
    [ "$changed" -eq 1 ] && _CDL_APT_UPDATED=
    return 0
}

# --- users, units, files -----------------------------------------------------------------
# A system account with no shell and no password, for a service. $1 user  $2 home (or "")
cdl_system_user() {
    local u="$1" home="${2:-/nonexistent}"
    id -u "$u" >/dev/null 2>&1 && return 0
    useradd --system --user-group --shell /usr/sbin/nologin --home-dir "$home" --no-create-home "$u" \
        || die "cannot create system user $u"
    dim "    created system user $u"
}
# Every file this script owns carries this line, so a later run can tell its files from a
# person's. cdl_write_if_changed backs up anything it replaces, per spec §3.2.
# shellcheck disable=SC2034  # used by modules that source this file
CDL_MANAGED="# managed by cdl-linux; edits here are overwritten by ./install.sh"
# A systemd unit from stdin; reloads only when it changed. Returns 0 changed, 1 unchanged.
cdl_write_unit() {
    local name="$1"
    if cdl_write_if_changed "/etc/systemd/system/$name"; then
        systemctl daemon-reload; return 0
    fi
    return 1
}
cdl_enable_now() {
    local u="$1"
    systemctl is-enabled -q "$u" 2>/dev/null || systemctl enable -q "$u" || die "cannot enable $u"
    systemctl is-active  -q "$u" 2>/dev/null || systemctl start "$u"     || die "cannot start $u"
}
# In a container there is no systemd; modules that write units still succeed, and say so.
cdl_have_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }

# --- pinned downloads --------------------------------------------------------------------
# $1 URL  $2 destination  $3 expected sha256. Downloads only if absent or wrong, verifies
# always. A pinned release with no checksum is a pinned name, not a pinned artefact.
cdl_fetch_verified() {
    local url="$1" dest="$2" want="$3" have tmp
    have="$( [ -f "$dest" ] && sha256sum "$dest" | cut -d' ' -f1 )"
    [ "$have" = "$want" ] && return 0
    tmp="$(mktemp)"
    curl -fsSL --retry 3 -o "$tmp" "$url" || { rm -f "$tmp"; die "download failed: $url"; }
    have="$(sha256sum "$tmp" | cut -d' ' -f1)"
    [ "$have" = "$want" ] || { rm -f "$tmp"; die "checksum mismatch for $url: got $have, want $want"; }
    mkdir -p "$(dirname "$dest")"; mv "$tmp" "$dest"; chmod 0755 "$dest"
    dim "    fetched $(basename "$dest")"
}

# --- cdl configuration -------------------------------------------------------------------
CDL_ETC=/etc/cdl
# $1 key from /etc/cdl/palette.conf (color0..color15, foreground, background), as #rrggbb
cdl_palette() { awk -F= -v k="$1" '$1==k {gsub(/[ \t]/,"",$2); print $2}' "$CDL_ETC/palette.conf" 2>/dev/null; }
cdl_tailscale_ip() { command -v tailscale >/dev/null && tailscale ip -4 2>/dev/null | head -1; }
