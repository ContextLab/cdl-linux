#!/usr/bin/env bash
# The boot, branded: GRUB's menu and Plymouth's centred logo.  Spec §9.8.
#
# THE HARD RULE (§9.8): "artwork and configuration only, never a signed executable."
# Ubuntu's Secure Boot chain validates shim, GRUB, the kernel and its modules.  Nothing
# here replaces any of them -- this module writes a GRUB drop-in, a Plymouth theme
# directory and a PNG.
#
# EVERY BRANDED STAGE KEEPS AN UNBRANDED ESCAPE, also §9.8, and each one is a line of
# configuration that is easy to get backwards:
#
#   * GRUB keeps its recovery entry (GRUB_DISABLE_RECOVERY=false) and its edit key.
#   * Plymouth keeps Escape, which reveals the boot log.  That is plymouthd's own
#     handling, and the theme's part of the bargain is to draw the messages it is sent
#     rather than swallow them -- see the comments in cdl.script.
#   * tty2 keeps a plain getty, which is 50-console's business, not this module's.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

cdl_need_root "52-branding"

HERE="$(cd "$(dirname "$0")" && pwd)"
FILES="$HERE/../files"
ASSETS="$HERE/../assets"

THEME_DIR=/usr/share/plymouth/themes/cdl
CDL_CACHE=/var/cache/cdl

# --- the real logo ---------------------------------------------------------------------
# The lab's actual avatar, fetched at install time with a pinned checksum rather than
# committed to this repository.  The source repository (ContextLab/contextlab.github.io)
# is MIT with no separate asset grant, and a public repo should not redistribute a lab's
# mark on the strength of an inference about licensing.  Fetching it puts the file on the
# machine that is entitled to it without republishing it here.
#
# Despite the .png name the file is WebP (533x533, RGBA) -- verified, not assumed.
LOGO_URL="https://context-lab.com/images/CDL_Avatar.png"
LOGO_SHA="3d75ca7e3181175d900f55a1c031bb1c526f1f8fbb99ebb09debb6bf43311e6c"

changed=0
touched() { changed=$((changed+1)); }

# =========================================================================================
# GRUB
# =========================================================================================
# A drop-in under /etc/default/grub.d rather than an edit to /etc/default/grub.  Ubuntu
# sources every *.cfg there after the main file, so this adds settings without owning a
# file the person who uses this machine may also want to edit -- and removing the branding
# is deleting one file rather than reconstructing an edited one.
grub_changed=0
if [ -d /etc/default/grub.d ] || mkdir -p /etc/default/grub.d 2>/dev/null; then
    if cdl_write_if_changed /etc/default/grub.d/cdl.cfg <<GRUBCFG
$CDL_MANAGED
# Spec §9.8: "Menu title, colours, background, and a visible Recovery entry."

# The name in the menu and in the boot entries.
GRUB_DISTRIBUTOR="CDL Linux"

# Long enough to read and act on, short enough not to be a delay on every boot. The
# machine is at a desk and is rebooted rarely (§7.3), so the menu is worth seeing.
GRUB_TIMEOUT=3
GRUB_TIMEOUT_STYLE=menu

# THE ESCAPE, and the reason this file exists at all. Ubuntu's default hides the recovery
# entries; §9.8 requires them visible, because "branding that removes a diagnostic is a
# cost paid at the worst moment".
GRUB_DISABLE_RECOVERY=false

# Keep the boot messages available. quiet+splash is Plymouth's normal mode and Escape
# still reveals the log, but nothing here adds "loglevel=0" or similar: a splash that
# suppresses the log is the failure mode §9.8 names.
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"

# GRUB's own documentation warns that early graphical modes fail on some hardware. "auto"
# degrades to a plain text menu rather than to a blank screen, which is the documented
# behaviour §9.8 asks for.
GRUB_GFXMODE=auto
GRUB_TERMINAL_OUTPUT=gfxterm
GRUBCFG
    then
        grub_changed=1; touched
        ok "GRUB drop-in written (CDL Linux, timeout 3, recovery entries VISIBLE)"
    else
        dim "    GRUB drop-in already current"
    fi
else
    warn "/etc/default/grub.d is not available; GRUB branding skipped"
fi

# =========================================================================================
# PLYMOUTH
# =========================================================================================
cdl_apt_install plymouth plymouth-themes plymouth-label

# The converters.  librsvg2-bin renders the fallback SVG; webp decodes the real logo.
# Both were confirmed present in 26.04 before being listed here.
cdl_apt_install librsvg2-bin webp

mkdir -p "$THEME_DIR" "$CDL_CACHE"

# --- the logo image ------------------------------------------------------------------------
# Real logo first.  If the download fails its checksum -- a changed asset, a captive
# portal, no network during a re-run -- the shipped placeholder is rendered instead,
# because Plymouth with no image at all is a black screen, which is indistinguishable
# from a hang.  Which one was used is printed, so a boot screen that looks wrong is
# traceable to a line of install output rather than to a guess.
logo_source=""
logo_png="$THEME_DIR/logo.png"

if [ ! -f "$logo_png" ]; then
    raw="$CDL_CACHE/cdl-avatar.webp"
    # THE SUBSHELL IS LOAD-BEARING. cdl_fetch_verified calls die() on a failed download or
    # a checksum mismatch, and die() calls exit -- so `if cdl_fetch_verified ...; then`
    # does NOT fall through to an else branch, it ends the module. Everything below about
    # falling back to the placeholder would have been unreachable code. Running it in a
    # subshell turns that exit into a status this `if` can actually read; the file it
    # fetches lands on disk either way, so nothing is lost by the subshell.
    if ( cdl_fetch_verified "$LOGO_URL" "$raw" "$LOGO_SHA" ); then
        # WebP with an alpha channel. Plymouth composites onto the framebuffer, and an
        # RGBA PNG over an unpainted framebuffer shows whatever the firmware left behind,
        # so the logo is flattened onto the palette's background colour here.
        bg="$(cdl_palette background)"; bg="${bg:-#0b1210}"
        if cdl_have dwebp && cdl_have convert; then
            dwebp -quiet "$raw" -o "$CDL_CACHE/cdl-avatar.png" \
                && convert "$CDL_CACHE/cdl-avatar.png" -background "$bg" -flatten -resize 256x256 "$logo_png" \
                && logo_source="the lab's avatar (fetched, checksum verified)"
        elif cdl_have dwebp; then
            # Without ImageMagick the alpha stays, which Plymouth handles by compositing
            # onto the background this theme paints itself -- so the result is correct,
            # just produced by plymouthd rather than here.
            dwebp -quiet "$raw" -o "$logo_png" \
                && logo_source="the lab's avatar (fetched, checksum verified, alpha kept)"
        fi
    else
        warn "could not fetch the lab's logo with its pinned checksum; using the placeholder"
    fi

    if [ ! -f "$logo_png" ]; then
        if cdl_have rsvg-convert; then
            rsvg-convert -w 256 -h 256 "$ASSETS/cdl-logo.svg" -o "$logo_png" \
                && logo_source="the PLACEHOLDER wordmark (install/assets/cdl-logo.svg)"
        elif cdl_have convert; then
            convert -background none -resize 256x256 "$ASSETS/cdl-logo.svg" "$logo_png" \
                && logo_source="the PLACEHOLDER wordmark (install/assets/cdl-logo.svg)"
        fi
    fi

    if [ -f "$logo_png" ]; then
        chmod 0644 "$logo_png"; touched
        ok "boot logo: $logo_source"
    else
        die "could not produce $logo_png with either the real logo or the placeholder; Plymouth would show a black screen"
    fi
else
    dim "    boot logo already present at $logo_png"
fi

# --- the theme ---------------------------------------------------------------------------------
# cdl.script is a template; its @@..@@ colour tokens come from the palette (§9.7), because
# plymouthd reads the theme out of the initramfs where /etc/cdl does not exist.
hex_to_float() {
    # "#rrggbb" and a component index (1,3,5) -> "0.xyz"
    local h="${1#\#}" off="$2"
    awk -v v="$((16#${h:$off:2}))" 'BEGIN{printf "%.3f", v/255}'
}

pal_bg="$(cdl_palette background)"; pal_bg="${pal_bg:-#0b1210}"
pal_fg="$(cdl_palette foreground)"; pal_fg="${pal_fg:-#d7e3dc}"
# The bullets wear the bright green rather than the darker brand accent: they are small
# and they are the thing being typed into, so they get the more legible of the two.
pal_ac="$(cdl_palette color10)";    pal_ac="${pal_ac:-#4fc98a}"

theme_changed=0
if sed -e "s/@@BG_R@@/$(hex_to_float "$pal_bg" 0)/g" \
       -e "s/@@BG_G@@/$(hex_to_float "$pal_bg" 2)/g" \
       -e "s/@@BG_B@@/$(hex_to_float "$pal_bg" 4)/g" \
       -e "s/@@FG_R@@/$(hex_to_float "$pal_fg" 0)/g" \
       -e "s/@@FG_G@@/$(hex_to_float "$pal_fg" 2)/g" \
       -e "s/@@FG_B@@/$(hex_to_float "$pal_fg" 4)/g" \
       -e "s/@@AC_R@@/$(hex_to_float "$pal_ac" 0)/g" \
       -e "s/@@AC_G@@/$(hex_to_float "$pal_ac" 2)/g" \
       -e "s/@@AC_B@@/$(hex_to_float "$pal_ac" 4)/g" \
       "$FILES/plymouth/cdl.script" > "$CDL_CACHE/cdl.script.gen"
then
    # The token SHAPE, not a bare '@@': prose in the template legitimately discusses the
    # tokens, and a guard that fires on the word for a thing rather than the thing is a
    # guard that fails the install for no reason. (It did, once, before this was tightened.)
    if grep -qE '@@[A-Z_]+@@' "$CDL_CACHE/cdl.script.gen"; then
        die "the Plymouth theme still contains unsubstituted colour tokens; refusing to install it: $(grep -oE '@@[A-Z_]+@@' "$CDL_CACHE/cdl.script.gen" | sort -u | tr '\n' ' ')"
    fi
    if cdl_write_if_changed "$THEME_DIR/cdl.script" < "$CDL_CACHE/cdl.script.gen"; then
        theme_changed=1; touched
    fi
    chmod 0644 "$THEME_DIR/cdl.script"
else
    die "could not generate the Plymouth theme script from the palette"
fi

if cdl_write_if_changed "$THEME_DIR/cdl.plymouth" < "$FILES/plymouth/cdl.plymouth"; then
    theme_changed=1; touched
fi
chmod 0644 "$THEME_DIR/cdl.plymouth"

# --- make it the default ---------------------------------------------------------------------
# -R rebuilds the initramfs, which is slow and writes to /boot, so it runs only when the
# theme actually changed or is not yet the default.
if cdl_have plymouth-set-default-theme; then
    current="$(plymouth-set-default-theme 2>/dev/null || true)"
    if [ "$current" != cdl ] || [ "$theme_changed" -eq 1 ]; then
        if plymouth-set-default-theme -R cdl >/dev/null 2>&1; then
            touched
            ok "Plymouth theme 'cdl' is the default; initramfs rebuilt"
        else
            warn "plymouth-set-default-theme -R cdl failed; the boot splash stays as it was"
        fi
    else
        dim "    Plymouth theme 'cdl' is already the default"
    fi
else
    warn "plymouth-set-default-theme not found; the theme is installed but not selected"
fi

# --- update-grub, last ---------------------------------------------------------------------
# After Plymouth, because the initramfs rebuild changes what GRUB will list, and only if
# the drop-in changed: update-grub rewrites /boot/grub/grub.cfg and is not free.
if [ "$grub_changed" -eq 1 ]; then
    if cdl_have update-grub; then
        if update-grub >/dev/null 2>&1; then
            ok "update-grub regenerated the boot menu"
        else
            die "update-grub failed after writing /etc/default/grub.d/cdl.cfg; the menu may be stale"
        fi
    else
        warn "update-grub not found (no GRUB on this machine?); the drop-in is written but unapplied"
    fi
fi

if [ "$changed" -eq 0 ]; then
    ok "boot branding already in place; nothing changed"
else
    ok "boot branding configured ($changed change(s))"
fi
exit 0
