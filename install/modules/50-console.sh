#!/usr/bin/env bash
# The console people actually use: palette, font with ligatures, shell, multiplexer,
# login surfaces and the `cdl` launcher.  Spec §9.1 and §9.5-§9.7.
#
# WHAT THIS MODULE WILL NOT DO, and why it matters more than what it does:
#
#   * tty2 stays a plain getty.  §9.2: "a broken home screen, a broken shell
#     configuration or a broken zellij is an inconvenience rather than an incident."
#     Every change below is made to tty1 alone, and tty2 is enabled explicitly rather
#     than left to whatever the last change implied.
#
#   * Nothing is written to .profile, and nothing launches `cdl`.  §9.1 is explicit: a
#     launcher in a shell rc "runs for every non-interactive session too, so it would
#     capture scp, rsync, git over SSH, and any automation."  This module installs an
#     executable and two banners that *mention* it.  tests/test-console.sh greps for
#     exactly this and fails if it ever stops being true.
#
# Ordering: 50 is after the base packages (10) and before anything GPU-shaped, because
# nothing here needs a GPU and a person locked out of a pleasant console cannot
# conveniently debug one.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

cdl_need_root "50-console"

HERE="$(cd "$(dirname "$0")" && pwd)"
FILES="$HERE/../files"

# --- pinned artefacts ---------------------------------------------------------------------
# Every checksum below was computed by downloading the artefact, not copied from a page.
# Both zellij values are recorded because upstream and this script measure different
# things -- see the note at the zellij section.
ZELLIJ_VERSION="0.45.1"
ZELLIJ_BASE="https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}"
# sha256 of the release TARBALL (what cdl_fetch_verified downloads)
ZELLIJ_SHA_X86_TGZ="d7bda1e18c30a688833ae7627f1d6a253bbba5349a4bc48e4f0ec008aaf75ed1"
ZELLIJ_SHA_ARM_TGZ="7c0725cd433299eaf171d673df3b8e7ceceae1b06f8265ba552ff3b9c3c82ea0"
# sha256 of the BINARY INSIDE it, which is what upstream publishes and signs off on
ZELLIJ_SHA_X86_BIN="0ec6ef07b63c6355c02ce18343d40ef5ef5af19e25313ea9009c8fceda29e94f"
ZELLIJ_SHA_ARM_BIN="2f3965f5b4d7fbb25dfc543e91f9680c9ee7b4eb07d8a3e6392fa276fc65c509"

NERD_VERSION="3.5.1"
NERD_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v${NERD_VERSION}/NerdFontsSymbolsOnly.zip"
NERD_SHA="fdca3682534f6f65e1ccb2345b0362ccf67d9b8eca7c8025330946e93e2473bc"

CDL_BIN=/opt/cdl/bin
CDL_CACHE=/var/cache/cdl

changed=0
touched() { changed=$((changed+1)); }

# =========================================================================================
# (a) THE PALETTE
# =========================================================================================
# §9.7: one file, and every other themed surface generated from it.

install_tool() {
    local src="$1" dest="$2"
    if cdl_write_if_changed "$dest" < "$src"; then
        chmod 0755 "$dest"
        touched
        dim "    installed $dest"
    fi
}

mkdir -p "$CDL_ETC"

# The palette itself is configuration a person may legitimately want to edit, so it is
# NOT overwritten once it exists.  cdl_write_if_changed would replace an edited palette
# on every run, which would make "edit /etc/cdl/palette.conf" a lie.
if [ ! -f "$CDL_ETC/palette.conf" ]; then
    install -m 0644 "$FILES/console/palette.conf" "$CDL_ETC/palette.conf"
    touched
    ok "installed the cdl-default palette at $CDL_ETC/palette.conf"
else
    dim "    $CDL_ETC/palette.conf exists; left alone (it is yours to edit)"
fi

install_tool "$FILES/console/cdl-palette-apply" /usr/local/bin/cdl-palette-apply
install_tool "$FILES/console/cdl-palette-check" /usr/local/bin/cdl-palette-check

# Check BEFORE generating.  A palette that fails contrast should not reach the VT, the
# shell and the dashboard first and be reported afterwards.
if ! /usr/local/bin/cdl-palette-check "$CDL_ETC/palette.conf" >/dev/null 2>&1; then
    /usr/local/bin/cdl-palette-check "$CDL_ETC/palette.conf" >&2 || true
    die "the palette at $CDL_ETC/palette.conf fails its contrast thresholds (§9.7). Nothing was generated from it."
fi

/usr/local/bin/cdl-palette-apply --palette "$CDL_ETC/palette.conf" --out-dir "$CDL_ETC" --quiet \
    || die "cdl-palette-apply failed"
ok "palette generated (kmscon, vtrgb, zsh, zellij, css) and contrast-checked"

# --- the kernel VT gets the palette at boot ------------------------------------------------
# §9.7's table: "The kernel VT fallback -- setvtrgb, from the same source file."  This is
# what makes tty2 -- and tty1 if kmscon fails to start -- wear the same colours.
#
# After systemd-vconsole-setup, which sets the font and keymap and would otherwise race
# with this; before getty.target, so the first login already has the palette.
if cdl_write_unit cdl-vtrgb.service <<UNIT
$CDL_MANAGED
[Unit]
Description=Apply the CDL palette to the kernel virtual terminals
Documentation=https://github.com/ContextLab/cdl-linux
After=systemd-vconsole-setup.service
Before=getty.target
ConditionPathExists=$CDL_ETC/vtrgb
ConditionPathExists=/dev/tty0

[Service]
Type=oneshot
RemainAfterExit=yes
# setvtrgb ships in kbd at /usr/sbin (verified against the 26.04 Contents index).
ExecStart=/usr/sbin/setvtrgb $CDL_ETC/vtrgb

[Install]
WantedBy=multi-user.target
UNIT
then touched; fi

# =========================================================================================
# (b) THE FONT, AND LIGATURES ON tty1
# =========================================================================================
# §9.6.  kmscon renders through pango rather than the kernel's 512-glyph bitmap table,
# and pango shapes -- which is what a ligature is.

cdl_apt_install kmscon fonts-firacode fontconfig kbd unzip

# S4 (§12) asks whether kmscon shapes ligatures on the real panel.  The package existing
# and the pango module being present are the parts that can be established here; the
# photograph of `=>` on the Tensorbook's own screen is the part that cannot.
if ls /usr/lib/*/kmscon/mod-pango.so >/dev/null 2>&1; then
    ok "kmscon with the pango font engine (shaping, therefore ligatures) is installed"
else
    warn "kmscon is installed but mod-pango.so is missing; ligatures will NOT work"
    warn "    kmscon would fall back to a non-shaping engine. S4 cannot pass in this state."
fi

# --- Symbols Nerd Font -------------------------------------------------------------------
# §9.6: "the patched Fira Code Nerd Font build is not in the Ubuntu archive, so rather
# than vendor a patched font we use the packaged original and let fontconfig fall back to
# the symbols-only font for the glyph ranges it lacks."
FONT_DIR=/usr/local/share/fonts/cdl
mkdir -p "$FONT_DIR" "$CDL_CACHE"

if [ ! -f "$FONT_DIR/SymbolsNerdFontMono-Regular.ttf" ]; then
    cdl_fetch_verified "$NERD_URL" "$CDL_CACHE/NerdFontsSymbolsOnly-${NERD_VERSION}.zip" "$NERD_SHA"
    tmp="$(mktemp -d)"
    unzip -o -q "$CDL_CACHE/NerdFontsSymbolsOnly-${NERD_VERSION}.zip" \
        'SymbolsNerdFontMono-Regular.ttf' 'LICENSE' -d "$tmp" \
        || die "cannot unpack the Nerd Fonts symbols archive"
    install -m 0644 "$tmp/SymbolsNerdFontMono-Regular.ttf" "$FONT_DIR/"
    # The font is SIL OFL and the licence travels with it.
    [ -f "$tmp/LICENSE" ] && install -m 0644 "$tmp/LICENSE" "$FONT_DIR/LICENSE.SymbolsNerdFont"
    rm -rf "$tmp"
    touched
    ok "installed Symbols Nerd Font Mono ${NERD_VERSION} to $FONT_DIR"
else
    dim "    Symbols Nerd Font Mono already installed"
fi

# --- fontconfig fallback --------------------------------------------------------------------
# "Fira Code" gains "Symbols Nerd Font Mono" as a weak appended family, so any glyph Fira
# Code does not carry -- croft's file and activity-bar icons, per §9.6 -- is drawn from
# the symbols font instead of appearing as a box.
#
# binding="weak" matters: a weak edit appends below anything the caller asked for, so a
# request for Fira Code still gets Fira Code for every glyph Fira Code has.
if cdl_write_if_changed /etc/fonts/conf.d/62-cdl-firacode-symbols.conf <<'FCFG'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- managed by cdl-linux; edits here are overwritten by ./install.sh -->
<fontconfig>
  <!-- Fira Code carries no Nerd Font symbol ranges. Rather than vendor a patched build
       (spec 9.6), fall back to the symbols-only font for exactly those glyphs. -->
  <match target="pattern">
    <test name="family"><string>Fira Code</string></test>
    <edit name="family" mode="append" binding="weak">
      <string>Symbols Nerd Font Mono</string>
    </edit>
  </match>
  <!-- The same for the generic monospace alias, so a program that asks for "monospace"
       on this machine gets the same two-font pairing. -->
  <match target="pattern">
    <test name="family"><string>monospace</string></test>
    <edit name="family" mode="prepend" binding="weak">
      <string>Fira Code</string>
    </edit>
    <edit name="family" mode="append" binding="weak">
      <string>Symbols Nerd Font Mono</string>
    </edit>
  </match>
</fontconfig>
FCFG
then
    touched
    fc-cache -f >/dev/null 2>&1 || warn "fc-cache failed; fonts may not be visible until the next boot"
    ok "fontconfig: Fira Code falls back to Symbols Nerd Font Mono"
fi

# --- kmscon configuration -------------------------------------------------------------------
# kmscon.conf has no include directive (checked in kmscon.conf(5)), so the file is
# composed here from a static head plus the palette fragment cdl-palette-apply generated.
# That keeps §9.7's single source without pretending kmscon supports something it does not.
#
# /etc/kmscon/kmscon.conf is a dpkg conffile.  cdl_write_if_changed backs up what it
# replaces (§3.2), so the packaged original is recoverable.
{
    printf '%s\n' "$CDL_MANAGED"
    cat <<'KHEAD'
# Composed by install/modules/50-console.sh from this file's head and the palette
# fragment generated by cdl-palette-apply. Edit /etc/cdl/palette.conf for colours; edit
# the module for anything else.

### Fonts (spec 9.6) ###
# pango is the whole point. It is the only one of kmscon's engines that shapes text, and
# a ligature is a HarfBuzz GSUB substitution -- so with font-engine=8x16 or unifont you
# get Fira Code's letterforms and none of its ligatures.
font-engine=pango
font-name=Fira Code
font-size=14
font-dpi=96

### Terminal ###
term=xterm-256color
sb-size=20000

### Video ###
# The panel is on the Intel iGPU (measured, spec 9.5), so the console works without the
# NVIDIA driver loaded. gpus=primary keeps kmscon on that one rather than having it pick
# among two.
drm
gpus=primary

### Input ###
xkb-repeat-delay=250
xkb-repeat-rate=40

KHEAD
    printf '### Palette (spec 9.7): generated from /etc/cdl/palette.conf ###\n'
    # Drop the fragment's own generated-by header; this file has its own.
    grep -v '^#' "$CDL_ETC/kmscon-palette.conf"
} > /tmp/cdl-kmscon.conf.$$

if cdl_write_if_changed /etc/kmscon/kmscon.conf < /tmp/cdl-kmscon.conf.$$; then
    touched
    ok "kmscon configured: Fira Code 14 via pango, CDL palette"
fi
rm -f /tmp/cdl-kmscon.conf.$$

# --- tty1 is kmscon; tty2 is a plain getty ----------------------------------------------------
# §9.2 and §9.6.  Two things are deliberately NOT done here:
#
#   * `systemctl enable kmsconvt@.service` (the bare template) is NOT used.  Its
#     [Install] section carries Alias=autovt@.service, which makes systemd-logind spawn
#     kmscon on EVERY newly allocated VT -- including tty2, which §9.2 requires to stay
#     an ordinary getty.  Enabling the tty1 instance keeps the alias scoped to tty1.
#
#   * getty@tty1 is not masked.  kmsconvt@.service already declares
#     `Conflicts=getty@tty1.service` and `OnFailure=getty@tty1.service`, which is exactly
#     §9.6's "if kmscon does not start, tty1 falls back to the kernel VT".  Masking
#     getty@tty1 would delete that fallback and turn a cosmetic failure into no console.
if cdl_have_systemd; then
    systemctl disable --quiet getty@tty1.service 2>/dev/null || true
    if ! systemctl is-enabled -q kmsconvt@tty1.service 2>/dev/null; then
        systemctl enable -q kmsconvt@tty1.service 2>/dev/null \
            || warn "could not enable kmsconvt@tty1; tty1 stays a kernel VT (ligatures lost, machine fine)"
        touched
    fi
    # tty2, explicitly, rather than by assumption.
    systemctl is-enabled -q getty@tty2.service 2>/dev/null || { systemctl enable -q getty@tty2.service 2>/dev/null || true; touched; }
    systemctl is-enabled -q cdl-vtrgb.service 2>/dev/null || { systemctl enable -q cdl-vtrgb.service 2>/dev/null || true; touched; }
    ok "tty1 = kmscon (fallback to getty on failure); tty2 = plain getty (§9.2)"
else
    warn "no systemd here (container): units written but not enabled"
fi

# =========================================================================================
# (c) THE SHELL
# =========================================================================================
# §9.5.  Each tool was checked against the 26.04 package index before being listed; the
# loop below still verifies, because a package can be removed from a release.

SHELL_PKGS=(zsh git gh ripgrep fd-find jq htop bat eza git-delta emacs-nox)

# The probe below asks apt-cache whether each package exists, and apt-cache can only
# answer from a populated /var/lib/apt/lists. On a fresh machine -- or when this module is
# re-run alone with `--module 50-console` -- those lists may be empty, and every package
# would then be reported "not in this release's archive" and silently skipped. Refresh
# first, so an absent package means absent rather than unasked.
cdl_apt_update_once || die "apt-get update failed; cannot tell which of §9.5's tools this release has"

available=(); unavailable=()
for p in "${SHELL_PKGS[@]}"; do
    if cdl_pkg_present "$p" || apt-cache show "$p" >/dev/null 2>&1; then
        available+=("$p")
    else
        unavailable+=("$p")
    fi
done
[ "${#available[@]}" -gt 0 ] && cdl_apt_install "${available[@]}"
if [ "${#unavailable[@]}" -gt 0 ]; then
    warn "not in this release's archive, skipped: ${unavailable[*]}"
fi

# nvtop only where there is a GPU to watch.  §9.5 lists it, but on a machine without an
# NVIDIA GPU it is a package that reports nothing.
if cdl_has_nvidia_gpu && apt-cache show nvtop >/dev/null 2>&1; then
    cdl_apt_install nvtop
    ok "nvtop installed (NVIDIA GPU present)"
else
    dim "    nvtop skipped: no NVIDIA GPU on this machine"
fi

# --- delta as git's pager --------------------------------------------------------------------
# §9.5 wants one palette across delta too.  delta is configured through git, not an
# alias, so this goes in /etc/gitconfig where it applies to every user without editing
# anyone's ~/.gitconfig.
if cdl_have delta; then
    if cdl_write_if_changed /etc/gitconfig.d-cdl <<'GITCFG'
# managed by cdl-linux; included from /etc/gitconfig
[core]
    pager = delta
[interactive]
    diffFilter = delta --color-only
[delta]
    navigate = true
    line-numbers = true
    syntax-theme = ansi
[merge]
    conflictstyle = zdiff3
GITCFG
    then touched; fi
    # An include rather than an overwrite: /etc/gitconfig may hold a site setting, and
    # this must add to it rather than replace it.
    if ! git config --system --get-all include.path 2>/dev/null | grep -qx /etc/gitconfig.d-cdl; then
        git config --system --add include.path /etc/gitconfig.d-cdl
        touched
    fi
    # syntax-theme=ansi makes delta use the terminal's sixteen colours -- which are the
    # CDL palette -- instead of carrying its own copy of a colour scheme.
    ok "git-delta wired into /etc/gitconfig, themed from the terminal palette"
fi

# --- the system zshrc -----------------------------------------------------------------------
install -d -m 0755 "$CDL_ETC"
if cdl_write_if_changed "$CDL_ETC/zshrc" < "$FILES/console/zshrc"; then
    chmod 0644 "$CDL_ETC/zshrc"
    touched
    ok "installed $CDL_ETC/zshrc"
fi

# One guarded line appended to /etc/zsh/zshrc, backed up first.  Appending rather than
# replacing: /etc/zsh/zshrc is Debian's and carries things (compinit paths, /etc/zsh/zshenv
# interaction) that are not ours to drop.
ZSHRC=/etc/zsh/zshrc
GUARD='[ -r /etc/cdl/zshrc ] && . /etc/cdl/zshrc   # cdl-linux'
if [ -d /etc/zsh ]; then
    if [ ! -f "$ZSHRC" ] || ! grep -qF '/etc/cdl/zshrc' "$ZSHRC"; then
        cdl_backup_file "$ZSHRC"
        printf '\n# cdl-linux: the system-wide CDL shell configuration (spec 9.5).\n%s\n' "$GUARD" >> "$ZSHRC"
        touched
        ok "hooked $CDL_ETC/zshrc into $ZSHRC (one guarded line)"
    else
        dim "    $ZSHRC already sources $CDL_ETC/zshrc"
    fi
else
    warn "/etc/zsh does not exist; zsh may not be installed. The shell config was not hooked up."
fi

# --- the primary user's shell -----------------------------------------------------------------
# §9.5 makes zsh the shell.  Changed only if it is not already zsh: chsh on every run
# would overwrite a deliberate change by the person who uses this machine.
primary_user="${SUDO_USER:-}"
if [ -z "$primary_user" ] || [ "$primary_user" = root ]; then
    primary_user="$(getent passwd 1000 | cut -d: -f1)"
fi
if [ -n "$primary_user" ] && cdl_have zsh; then
    current_shell="$(getent passwd "$primary_user" | cut -d: -f7)"
    zsh_path="$(command -v zsh)"
    if [ "$current_shell" != "$zsh_path" ]; then
        if chsh -s "$zsh_path" "$primary_user" 2>/dev/null; then
            touched
            ok "$primary_user's login shell is now zsh (was ${current_shell:-unset})"
        else
            warn "could not change $primary_user's shell to zsh; run: chsh -s $zsh_path $primary_user"
        fi
    else
        dim "    $primary_user already uses zsh"
    fi
else
    [ -n "$primary_user" ] || warn "no uid-1000 user found; no login shell was changed"
fi

# =========================================================================================
# (d) ZELLIJ
# =========================================================================================
# Not in the Ubuntu archive (checked), so a pinned release binary.  §11.3 covers the
# refresh of pinned CLIs.

case "$(cdl_arch)" in
    x86_64)          z_url="$ZELLIJ_BASE/zellij-no-web-x86_64-unknown-linux-musl.tar.gz"
                     z_tgz="$ZELLIJ_SHA_X86_TGZ"; z_bin="$ZELLIJ_SHA_X86_BIN" ;;
    aarch64|arm64)   z_url="$ZELLIJ_BASE/zellij-no-web-aarch64-unknown-linux-musl.tar.gz"
                     z_tgz="$ZELLIJ_SHA_ARM_TGZ"; z_bin="$ZELLIJ_SHA_ARM_BIN" ;;
    *)               z_url=""; warn "no zellij build for $(cdl_arch); skipping the multiplexer" ;;
esac

# The "no-web" build, deliberately.  The default build embeds a web server; §7.2 is that
# being on the tailnet is not authorisation, and the cheapest way to honour that is not
# to install a second listener nobody asked for.

if [ -n "$z_url" ]; then
    mkdir -p "$CDL_BIN" "$CDL_CACHE"
    need_install=1
    if [ -x "$CDL_BIN/zellij" ] && [ "$(sha256sum "$CDL_BIN/zellij" | cut -d' ' -f1)" = "$z_bin" ]; then
        need_install=0
        dim "    zellij $ZELLIJ_VERSION already installed and verified"
    fi
    if [ "$need_install" -eq 1 ]; then
        tgz="$CDL_CACHE/zellij-${ZELLIJ_VERSION}-$(cdl_arch).tar.gz"
        cdl_fetch_verified "$z_url" "$tgz" "$z_tgz"
        tmp="$(mktemp -d)"
        tar xzf "$tgz" -C "$tmp" || { rm -rf "$tmp"; die "cannot unpack $tgz"; }
        # Upstream publishes the checksum of the BINARY, not of the tarball.  Verifying
        # both means a tampered archive is caught by cdl_fetch_verified and a tampered
        # binary is caught against the value upstream actually attests to.
        got="$(sha256sum "$tmp/zellij" | cut -d' ' -f1)"
        [ "$got" = "$z_bin" ] || { rm -rf "$tmp"; die "zellij binary checksum mismatch: got $got, want $z_bin"; }
        install -m 0755 "$tmp/zellij" "$CDL_BIN/zellij"
        rm -rf "$tmp"
        touched
        ok "installed zellij $ZELLIJ_VERSION (no-web build) to $CDL_BIN/zellij"
    fi
    if [ "$(readlink -f /usr/local/bin/zellij 2>/dev/null)" != "$CDL_BIN/zellij" ]; then
        ln -sf "$CDL_BIN/zellij" /usr/local/bin/zellij
        touched
    fi

    # Config and layout.  The theme file itself is generated by cdl-palette-apply, so it
    # is not copied here.
    install -d -m 0755 "$CDL_ETC/zellij" "$CDL_ETC/zellij/layouts" "$CDL_ETC/zellij/themes"
    if cdl_write_if_changed "$CDL_ETC/zellij/config.kdl" < "$FILES/zellij/config.kdl"; then touched; fi
    if cdl_write_if_changed "$CDL_ETC/zellij/layouts/agents.kdl" < "$FILES/zellij/layouts/agents.kdl"; then touched; fi
    chmod 0644 "$CDL_ETC/zellij/config.kdl" "$CDL_ETC/zellij/layouts/agents.kdl"
    ok "zellij configured (theme from the palette, agents layout, resurrection off per §9.4)"
fi

# =========================================================================================
# (e) LOGIN SURFACES
# =========================================================================================
# §9.1's table.  Both of these are DISPLAYED, never executed as a login action.

# --- /etc/issue ---------------------------------------------------------------------------
# Plain text, the first thing a person at the machine reads.  \n and \l are agetty
# escapes, expanded at display time, so the hostname stays correct if it changes.  The
# tailnet address is written literally because there is no getty escape for it; re-running
# this module refreshes it.
ts_ip="$(cdl_tailscale_ip)"
{
    printf '\n'
    printf '  CDL Linux  \\n  (\\l)\n'
    [ -n "$ts_ip" ] && printf '  tailnet %s\n' "$ts_ip"
    printf '\n'
    printf '  log in, then type  cdl  to begin.\n'
    printf '\n'
} > /tmp/cdl-issue.$$
if cdl_write_if_changed /etc/issue < /tmp/cdl-issue.$$; then
    touched
    ok "/etc/issue: hostname, ${ts_ip:+tailnet address, }and how to begin"
fi
rm -f /tmp/cdl-issue.$$

# --- the motd ------------------------------------------------------------------------------
# 26.04 runs /etc/update-motd.d/* from pam_motd; /etc/motd.d carries no packaged entries on
# this release (checked against the 26.04 Contents index).
MOTD_DIR=/etc/update-motd.d
if [ -d "$MOTD_DIR" ]; then
    if cdl_write_if_changed "$MOTD_DIR/10-cdl" < "$FILES/console/motd-10-cdl"; then
        chmod 0755 "$MOTD_DIR/10-cdl"
        touched
        ok "installed $MOTD_DIR/10-cdl (two-line status, names \`cdl\`)"
    fi

    # Quieten the stock noise.  §9 wants two lines and a hint, not a screen of
    # advertising.  chmod -x rather than delete: dpkg owns these files, a deleted
    # conffile comes back on upgrade as a prompt, and an un-executable one is
    # trivially reversible with chmod +x.
    #
    # 90-updates-available is KEPT ON PURPOSE: "there are 14 security updates" is
    # operational information on a machine used every few weeks (§11.2).
    for noisy in 10-help-text 50-motd-news 60-ubuntu-server-tip 91-contract-ua-esm-status; do
        f="$MOTD_DIR/$noisy"
        if [ -f "$f" ] && [ -x "$f" ]; then
            chmod -x "$f"
            touched
            dim "    silenced $noisy (chmod -x; reversible)"
        fi
    done
else
    warn "$MOTD_DIR does not exist; the post-login status line was not installed"
fi

# =========================================================================================
# (f) THE LAUNCHER
# =========================================================================================
# §9.1: a real executable on PATH, so `ssh host cdl status`, scp and rsync all behave.
# Nothing invokes it.
install_tool "$FILES/console/cdl" /usr/local/bin/cdl

# The claim in §9.1 that nothing enters the launcher non-interactively is worth checking
# at install time rather than only in the test suite: this is the file that would break it.
if grep -rqE '(^|[^#])\bcdl\b' /etc/profile /etc/profile.d/*.sh 2>/dev/null; then
    warn "something in /etc/profile* mentions cdl; §9.1 requires the launcher never run from a profile"
fi

# =========================================================================================
if [ "$changed" -eq 0 ]; then
    ok "console already configured; nothing changed"
else
    ok "console configured ($changed change(s))"
fi
exit 0
