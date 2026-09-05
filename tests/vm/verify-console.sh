#!/usr/bin/env bash
# Acceptance checks for the console and branding modules. RUNS INSIDE THE GUEST, AS ROOT.
#
#   scripts/vm/run-in-guest.sh bash /repo/tests/vm/verify-console.sh
#
# Everything here asserts something the spec claims about the installed machine, and each
# check names the section it is checking, so a failure says which claim is wrong rather
# than only that something is. This is the counterpart to tests/test-console.sh, which
# checks what can be checked without the machine.
#
# THE ONE THING THIS CANNOT DO is spike S4 (§12): whether kmscon shapes `=>` into a
# ligature on the Tensorbook's own panel, against i915, with the NVIDIA driver loaded.
# That needs the hardware and a photograph. What is checked here is everything that makes
# S4 possible -- the package, the pango module, the font, the unit -- so that a failed S4
# is a rendering finding rather than a missing dependency.

set -uo pipefail

pass=0; fail=0; warned=0
ok()   { printf '  \033[32mPASS\033[0m  %-52s (%s)\n' "$1" "$2"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %-52s (%s)\n' "$1" "$2"; fail=$((fail+1)); }
note() { printf '  \033[33mWARN\033[0m  %-52s (%s)\n' "$1" "$2"; warned=$((warned+1)); }

# `A && ok ... || bad ...` is not if-then-else: if `ok` ever returned nonzero the `bad`
# branch would also run. These take the command instead, so the reported result is the
# command's and nothing else's.
try()  { local m="$1" s="$2"; shift 2; if "$@" >/dev/null 2>&1; then ok "$m" "$s"; else bad "$m" "$s"; fi; }
tryw() { local m="$1" s="$2"; shift 2; if "$@" >/dev/null 2>&1; then ok "$m" "$s"; else note "$m" "$s"; fi; }
# The inverse: passes when the command FAILS. Used for the negative claims (§9.1's "no
# profile launches cdl", §9.7's "no leftover tokens").
tryn() { local m="$1" s="$2"; shift 2; if "$@" >/dev/null 2>&1; then bad "$m" "$s"; else ok "$m" "$s"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" -eq 0 ] || { echo "this must run as root inside the guest" >&2; exit 2; }

# The primary user. §9.5 makes zsh their shell; the VM's is `cdl`.
USER_NAME="${CDL_TEST_USER:-$(getent passwd 1000 | cut -d: -f1)}"
[ -n "$USER_NAME" ] || { echo "no uid-1000 user in this guest" >&2; exit 2; }

printf '\n\033[1m-- the font and the terminal that can shape it (§9.6) --\033[0m\n'

if dpkg-query -W -f='${Status}' kmscon 2>/dev/null | grep -q 'ok installed'; then
    ok "kmscon is installed" "§9.6"
    # Ligatures need shaping, and only the pango engine shapes. Without this module
    # kmscon still runs and still shows Fira Code -- and silently has no ligatures,
    # which is exactly the failure that would be mistaken for an S4 result.
    if ls /usr/lib/*/kmscon/mod-pango.so >/dev/null 2>&1; then
        ok "kmscon's pango font engine is present (shaping possible)" "§9.6"
    else
        bad "mod-pango.so missing: kmscon cannot shape, so no ligatures" "§9.6"
    fi
    try "kmscon.conf selects font-engine=pango" "§9.6" grep -q '^font-engine=pango' /etc/kmscon/kmscon.conf
    try "kmscon.conf selects Fira Code"          "§9.6" grep -q '^font-name=Fira Code' /etc/kmscon/kmscon.conf
else
    # §9.6 plans for this: "If it fails, the console keeps the kernel VT and loses
    # ligatures, which is a cosmetic loss rather than a design change."
    note "kmscon is NOT installed; the console falls back to the kernel VT" "§9.6, S4 blocked"
    if [ -f /etc/cdl/vtrgb ]; then
        ok "the kernel-VT fallback palette is in place" "§9.7"
    else
        bad "no kmscon AND no vtrgb: the console is unstyled" "§9.7"
    fi
fi

if fc-list 2>/dev/null | grep -qi 'fira code'; then
    ok "Fira Code is installed and visible to fontconfig" "§9.6"
else
    bad "fc-list does not report Fira Code" "§9.6"
fi
if fc-list 2>/dev/null | grep -qi 'symbols nerd font'; then
    ok "Symbols Nerd Font is installed and visible to fontconfig" "§9.6"
else
    bad "fc-list does not report Symbols Nerd Font" "§9.6"
fi
# The fallback is the point of shipping two fonts: fontconfig must actually resolve a
# request for Fira Code into the symbols font for glyphs Fira Code lacks.
if have fc-match; then
    if fc-match 'Fira Code' 2>/dev/null | grep -qi 'firacode\|fira code'; then
        ok "fc-match 'Fira Code' resolves to Fira Code itself" "§9.6"
    else
        bad "fc-match 'Fira Code' does not resolve to Fira Code" "§9.6"
    fi
    try "the Fira Code -> Symbols fallback rule is installed" "§9.6" \
        test -f /etc/fonts/conf.d/62-cdl-firacode-symbols.conf
fi

printf '\n\033[1m-- tty1 is kmscon, tty2 is an ordinary getty (§9.2) --\033[0m\n'
if systemctl is-enabled -q kmsconvt@tty1.service 2>/dev/null; then
    ok "kmsconvt@tty1 is enabled" "§9.6"
else
    note "kmsconvt@tty1 is not enabled; tty1 stays a kernel VT" "§9.6"
fi
if systemctl is-enabled -q getty@tty2.service 2>/dev/null; then
    ok "getty@tty2 is enabled: the recovery terminal exists" "§9.2"
else
    bad "getty@tty2 is NOT enabled; there is no plain recovery terminal" "§9.2"
fi
# The trap this module exists to avoid: enabling the bare template aliases autovt@ and
# puts kmscon on every VT, including the one that must stay boring.
if [ -e /etc/systemd/system/autovt@.service ]; then
    bad "autovt@.service is aliased to kmscon: tty2 is NOT a plain getty" "§9.2"
else
    ok "autovt@ is not globally aliased to kmscon" "§9.2"
fi
# kmscon's own fallback must survive: masking getty@tty1 would delete it.
if systemctl is-enabled getty@tty1.service 2>/dev/null | grep -q masked; then
    bad "getty@tty1 is masked; kmscon's OnFailure fallback is gone" "§9.6"
else
    ok "getty@tty1 is not masked, so kmscon can fall back to it" "§9.6"
fi

printf '\n\033[1m-- the palette, applied (§9.7) --\033[0m\n'
try "/etc/cdl/palette.conf exists" "§9.7" test -f /etc/cdl/palette.conf
if /usr/local/bin/cdl-palette-check /etc/cdl/palette.conf >/dev/null 2>&1; then
    ok "the installed palette passes its contrast thresholds" "§9.7"
else
    bad "the installed palette FAILS contrast" "§9.7"
fi
for f in vtrgb palette.css zsh-colors.zsh kmscon-palette.conf zellij/themes/cdl.kdl; do
    try "generated: /etc/cdl/$f" "§9.7" test -f "/etc/cdl/$f"
done
# The unit that puts the palette on the kernel VTs. RemainAfterExit means a completed
# oneshot reads as active, so is-active is the right question.
if systemctl is-active -q cdl-vtrgb.service 2>/dev/null; then
    ok "cdl-vtrgb.service is active (kernel VTs carry the palette)" "§9.7"
elif systemctl is-enabled -q cdl-vtrgb.service 2>/dev/null; then
    note "cdl-vtrgb is enabled but not active; check journalctl -u cdl-vtrgb" "§9.7"
else
    bad "cdl-vtrgb.service is neither active nor enabled" "§9.7"
fi
# Regenerating on the installed machine must change nothing.
if /usr/local/bin/cdl-palette-apply 2>&1 | grep -q 'already current'; then
    ok "cdl-palette-apply is idempotent on the installed machine" "§3.1"
else
    bad "cdl-palette-apply rewrites files on a second run" "§3.1"
fi

printf '\n\033[1m-- the shell (§9.5) --\033[0m\n'
user_shell="$(getent passwd "$USER_NAME" | cut -d: -f7)"
if [ "$user_shell" = "$(command -v zsh)" ]; then
    ok "$USER_NAME's login shell is zsh" "§9.5"
else
    bad "$USER_NAME's shell is $user_shell, not zsh" "§9.5"
fi
try "/etc/cdl/zshrc is installed"               "§9.5" test -f /etc/cdl/zshrc
try "/etc/zsh/zshrc sources it (one guarded line)" "§9.5" grep -qF '/etc/cdl/zshrc' /etc/zsh/zshrc
# The prompt must actually build in a real zsh, not merely parse.
if su - "$USER_NAME" -s /bin/zsh -c 'source /etc/cdl/zshrc 2>&1; print -r -- OKPROMPT' 2>/dev/null | grep -q OKPROMPT; then
    ok "the zshrc sources cleanly in a real zsh" "§9.5"
else
    bad "the zshrc errors when sourced" "§9.5"
fi
for t in git gh rg fdfind jq htop batcat eza delta emacs; do
    tryw "tool present: $t" "§9.5" have "$t"
done

printf '\n\033[1m-- zellij (§9.5, §9.4) --\033[0m\n'
if have zellij; then
    v="$(zellij --version 2>/dev/null)"
    if [ -n "$v" ]; then ok "zellij runs: $v" "§9.5"; else bad "zellij is on PATH but does not run" "§9.5"; fi
else
    bad "zellij is not installed" "§9.5"
fi
try "zellij config installed"          "§9.5" test -f /etc/cdl/zellij/config.kdl
try "the agents layout is installed"   "§9.5" test -f /etc/cdl/zellij/layouts/agents.kdl
try "session resurrection is disabled" "§9.4" grep -q 'session_serialization false' /etc/cdl/zellij/config.kdl

printf '\n\033[1m-- login surfaces (§9.1) --\033[0m\n'
if grep -qi 'cdl' /etc/issue 2>/dev/null; then
    ok "/etc/issue names cdl" "§9.1"
else
    bad "/etc/issue does not mention cdl" "§9.1"
fi
if [ -x /etc/update-motd.d/10-cdl ]; then
    ok "the motd status script is installed and executable" "§9.1"
    if /etc/update-motd.d/10-cdl 2>/dev/null | grep -qi 'cdl'; then
        ok "the motd runs and names cdl" "§9.1"
    else
        bad "the motd script produces nothing useful" "§9.1"
    fi
else
    bad "no /etc/update-motd.d/10-cdl" "§9.1"
fi
for noisy in 10-help-text 50-motd-news; do
    if [ -f "/etc/update-motd.d/$noisy" ] && [ -x "/etc/update-motd.d/$noisy" ]; then
        bad "the noisy motd script $noisy is still enabled" "§9.1"
    else
        ok "$noisy is silenced or absent" "§9.1"
    fi
done
# §11.2: update notices are operational information and are deliberately kept.
if [ -f /etc/update-motd.d/90-updates-available ] && [ ! -x /etc/update-motd.d/90-updates-available ]; then
    bad "90-updates-available was disabled; update notices are wanted" "§11.2"
else
    ok "90-updates-available is left enabled" "§11.2"
fi

printf '\n\033[1m-- the launcher (§9.1, §9.3) --\033[0m\n'
try "/usr/local/bin/cdl is a real executable" "§9.1" test -x /usr/local/bin/cdl
# The stated use: `ssh host cdl status` must work, which means it must work with no tty.
if su - "$USER_NAME" -c '/usr/local/bin/cdl status' </dev/null >/dev/null 2>&1; then
    ok "cdl status runs as $USER_NAME with no tty" "§9.1"
else
    bad "cdl status fails as $USER_NAME" "§9.1"
fi
# ...and the home screen must refuse, rather than writing a menu into a pipe.
if su - "$USER_NAME" -c '/usr/local/bin/cdl' </dev/null >/dev/null 2>&1; then
    bad "cdl drew a home screen with no tty" "§9.1"
else
    ok "cdl with no tty refuses and exits nonzero" "§9.1"
fi
# §9.1's hard negative: no profile file may launch it.
if grep -rlE '^[^#]*\bcdl\b' /etc/profile /etc/profile.d /home/*/.profile /home/*/.bash_profile /home/*/.zprofile 2>/dev/null | grep -q .; then
    bad "a profile file references cdl; non-interactive sessions would enter it" "§9.1"
else
    ok "no profile file launches cdl" "§9.1"
fi

printf '\n\033[1m-- boot branding (§9.8) --\033[0m\n'
if have plymouth-set-default-theme; then
    theme="$(plymouth-set-default-theme 2>/dev/null)"
    if [ "$theme" = cdl ]; then
        ok "the default Plymouth theme is cdl" "§9.8"
    else
        bad "the default Plymouth theme is '$theme', not cdl" "§9.8"
    fi
else
    bad "plymouth-set-default-theme is not installed" "§9.8"
fi
try "the boot logo image exists" "§9.8" test -f /usr/share/plymouth/themes/cdl/logo.png
if [ -f /usr/share/plymouth/themes/cdl/cdl.script ]; then
    ok "the theme script is installed" "§9.8"
    tryn "the theme's colours were substituted from the palette" "§9.7" \
        grep -q '@@' /usr/share/plymouth/themes/cdl/cdl.script
else
    bad "no cdl.script" "§9.8"
fi
# The theme has to be IN the initramfs, or none of it is drawn before the LUKS prompt --
# which is the one moment §9.8 cares about most.
initrd="/boot/initrd.img-$(uname -r)"
if [ -f "$initrd" ] && have lsinitramfs; then
    if lsinitramfs "$initrd" 2>/dev/null | grep -q 'plymouth/themes/cdl'; then
        ok "the cdl theme is inside the initramfs" "§9.8"
        if lsinitramfs "$initrd" 2>/dev/null | grep -q 'plymouth/themes/cdl/logo.png'; then
            ok "the logo image is inside the initramfs" "§9.8"
        else
            bad "the theme is in the initramfs but the logo is not" "§9.8"
        fi
    else
        bad "the cdl theme is NOT in the initramfs; the LUKS prompt will be unbranded" "§9.8"
    fi
else
    note "no lsinitramfs or no initrd for $(uname -r); cannot check the initramfs" "§9.8"
fi
# GRUB: the menu must be regenerated AND must still offer the recovery entry.
try "the GRUB drop-in is installed" "§9.8" test -f /etc/default/grub.d/cdl.cfg
if [ -f /boot/grub/grub.cfg ]; then
    try "grub.cfg carries the CDL menu title (update-grub ran)" "§9.8" grep -q 'CDL Linux' /boot/grub/grub.cfg
    try "a recovery entry is present in the menu"              "§9.8" grep -qi 'recovery mode' /boot/grub/grub.cfg
else
    note "no /boot/grub/grub.cfg (not a GRUB machine?)" "§9.8"
fi

printf '\n\033[1m-- summary --\033[0m\n'
printf '  passed: %d   warned: %d   failed: %d\n' "$pass" "$warned" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
