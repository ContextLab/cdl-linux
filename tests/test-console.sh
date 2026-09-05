#!/usr/bin/env bash
# The console module's checkable claims, on a machine that is not the target.
#
# What can be checked here: the generators are deterministic and produce the formats the
# consumers actually parse, the contrast gate rejects a bad palette as well as accepting
# the shipped one, the launcher refuses to draw a menu into a pipe, the session-name rule
# is what §9.3 says, the pinned checksums still match what upstream serves, and nothing in
# the module writes to .profile.
#
# What cannot, and is therefore absent rather than faked: whether kmscon starts against
# i915 on the Tensorbook's panel and whether pango shapes `=>` into a ligature there.
# That is spike S4 (§12) and it needs the machine and a photograph.
#
# The checksum assertions download real release assets, so they are gated behind
# CDL_NET_TESTS the same way the other suites are; tests/run-net.sh sets it and runs them
# on purpose. A pinned checksum that nobody re-checks is a pinned name rather than a
# pinned artefact, so they are not optional -- they are just not in the fast path.

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo" || exit 1

pass=0; fail=0
ok()  { printf '  \033[32mOK\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
# `A && ok ... || bad ...` is not if-then-else. These take the command, so the reported
# result is the command's alone.
try()  { local m="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$m"; else bad "$m"; fi; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

CONSOLE=install/files/console
PALETTE="$CONSOLE/palette.conf"

printf '\033[1m-- lint --\033[0m\n'
# run-all.sh lints the modules; these are the installed payloads, which have no .sh
# suffix and would otherwise be linted by nothing.
if command -v shellcheck >/dev/null 2>&1; then
    for f in "$CONSOLE/cdl" "$CONSOLE/cdl-palette-apply" "$CONSOLE/cdl-palette-check" \
             "$CONSOLE/motd-10-cdl" install/modules/50-console.sh install/modules/52-branding.sh; do
        if shellcheck -x "$f" >/dev/null 2>&1; then ok "shellcheck $f"; else bad "shellcheck $f"; shellcheck -x "$f" | head -20; fi
    done
else
    printf '  shellcheck not installed; syntax only\n'
    for f in "$CONSOLE"/* install/modules/5*.sh; do
        try "bash -n $f" bash -n "$f"
    done
fi
# The zshrc is zsh, not bash, and shellcheck cannot read it. zsh can.
if command -v zsh >/dev/null 2>&1; then
    if zsh -n "$CONSOLE/zshrc" 2>/dev/null; then ok "zsh -n $CONSOLE/zshrc"; else bad "zsh -n $CONSOLE/zshrc"; fi
fi

printf '\n\033[1m-- contrast gate (§9.7) --\033[0m\n'
if bash "$CONSOLE/cdl-palette-check" "$PALETTE" >"$work/check.out" 2>&1; then
    ok "the shipped cdl-default palette passes its contrast thresholds"
else
    bad "the shipped palette FAILS contrast"; cat "$work/check.out"
fi

# The archived design's actual failure (§9.7): colours that are nearly the background.
# A checker that only ever passes has not been shown to check anything.
cat > "$work/grey.conf" <<'GREY'
background=#3a3a3a
foreground=#454545
GREY
for i in $(seq 0 15); do printf 'color%d=#404040\n' "$i" >> "$work/grey.conf"; done
if bash "$CONSOLE/cdl-palette-check" "$work/grey.conf" >/dev/null 2>&1; then
    bad "grey-on-grey palette PASSED; the checker does not check"
else
    ok "a grey-on-grey palette is rejected (exit nonzero)"
fi
# ...and it must fail for the stated reason, not because the file was unreadable.
bash "$CONSOLE/cdl-palette-check" "$work/grey.conf" >"$work/grey.out" 2>&1
rc=$?
check "grey-on-grey exits 1 (below threshold), not 2 (unusable file)" "$rc" "1"
if grep -q 'FAIL' "$work/grey.out"; then ok "the rejection names the failing colours"; else bad "no per-colour FAIL lines"; fi

# A malformed palette is a different failure and must not be reported as bad contrast.
printf 'background=not-a-colour\nforeground=#ffffff\n' > "$work/bad.conf"
bash "$CONSOLE/cdl-palette-check" "$work/bad.conf" >/dev/null 2>&1
check "a malformed palette exits 2, not 1" "$?" "2"

printf '\n\033[1m-- generated formats (§9.7) --\033[0m\n'
out="$work/gen"
bash "$CONSOLE/cdl-palette-apply" --palette "$PALETTE" --out-dir "$out" --quiet \
    || bad "cdl-palette-apply failed"

# setvtrgb's format is exactly three lines of sixteen comma-separated decimals. Getting
# this wrong produces a VT with a scrambled palette and no error message, so it is
# asserted field by field rather than by eyeballing the file.
if [ -f "$out/vtrgb" ]; then
    check "vtrgb has exactly 3 lines" "$(wc -l < "$out/vtrgb" | tr -d ' ')" "3"
    vt_ok=1
    while IFS= read -r line; do
        n="$(awk -F, '{print NF}' <<<"$line")"
        [ "$n" -eq 16 ] || { vt_ok=0; bad "vtrgb line has $n fields, want 16"; }
        # Every field a decimal in 0..255. A hex value here would be silently accepted
        # by setvtrgb as something else entirely.
        awk -F, '{for(i=1;i<=NF;i++){if($i !~ /^[0-9]+$/ || $i<0 || $i>255) exit 1}}' <<<"$line" \
            || { vt_ok=0; bad "vtrgb line has a field outside 0..255: $line"; }
    done < "$out/vtrgb"
    [ "$vt_ok" -eq 1 ] && ok "vtrgb: 3 lines x 16 decimals, all in 0..255"
else
    bad "no vtrgb generated"
fi

# The dashboard (§8) reads these. Eighteen are required: sixteen ANSI slots plus
# foreground and background.
if [ -f "$out/palette.css" ]; then
    missing=""
    for i in $(seq 0 15); do grep -q -- "--cdl-color$i:" "$out/palette.css" || missing="$missing color$i"; done
    grep -q -- '--cdl-foreground:' "$out/palette.css" || missing="$missing foreground"
    grep -q -- '--cdl-background:' "$out/palette.css" || missing="$missing background"
    if [ -z "$missing" ]; then ok "palette.css defines all 18 required custom properties"
    else bad "palette.css is missing:$missing"; fi
    # The accent is a documented nineteenth, not one of the required eighteen.
    try "palette.css also carries --cdl-accent (the brand green)" \
        grep -q -- '--cdl-accent:' "$out/palette.css"
    # Every value must be a full hex colour: a truncated one is valid CSS and silently wrong.
    if grep -oE -- '--cdl-[a-z0-9]+: *[^;]+' "$out/palette.css" | grep -qvE '#[0-9a-f]{6}$'; then
        bad "palette.css has a value that is not #rrggbb"
    else
        ok "every palette.css value is a full #rrggbb"
    fi
else
    bad "no palette.css generated"
fi

# kmscon's option names are its own (light-grey, dark-grey, light-red...), not color8..15.
# Getting the mapping wrong yields a console whose bright colours are in the wrong slots.
if [ -f "$out/kmscon-palette.conf" ]; then
    kok=1
    grep -q '^palette=custom$' "$out/kmscon-palette.conf" || { kok=0; bad "kmscon fragment does not select palette=custom"; }
    for n in black red green yellow blue magenta cyan light-grey dark-grey \
             light-red light-green light-yellow light-blue light-magenta light-cyan white \
             foreground background; do
        grep -qE "^palette-$n=[0-9]+,[0-9]+,[0-9]+$" "$out/kmscon-palette.conf" \
            || { kok=0; bad "kmscon fragment missing or malformed: palette-$n"; }
    done
    [ "$kok" -eq 1 ] && ok "kmscon fragment: palette=custom plus all 18 named entries as r,g,b"
else
    bad "no kmscon-palette.conf generated"
fi

# Regenerating must change nothing. A generator that rewrites identical files makes every
# "did anything change?" check downstream useless.
bash "$CONSOLE/cdl-palette-apply" --palette "$PALETTE" --out-dir "$out" >"$work/second.out" 2>&1
if grep -q 'already current' "$work/second.out"; then ok "a second cdl-palette-apply changes nothing"; else bad "not idempotent: $(cat "$work/second.out")"; fi

printf '\n\033[1m-- the launcher (§9.1, §9.3) --\033[0m\n'
# §9.1's whole argument: this must never draw a menu into something that is not a
# terminal. In the test harness stdin and stdout are both pipes, which is the case.
out_txt="$(bash "$CONSOLE/cdl" </dev/null 2>&1)"; rc=$?
check "cdl with no tty exits 1" "$rc" "1"
if grep -q 'cdl status' <<<"$out_txt"; then ok "cdl with no tty prints the help"; else bad "no help text: $out_txt"; fi
if grep -qi 'not a terminal' <<<"$out_txt"; then ok "cdl says why it refused"; else bad "refusal does not explain itself"; fi

# The rule §9.3 rests on. Sourcing the launcher defines its functions and runs nothing,
# which is what makes this testable rather than re-implemented here.
# Sourcing the launcher defines its functions and runs nothing, which is what makes the
# rule testable rather than re-implemented here. The path is computed, so shellcheck
# cannot follow it -- that is the point, not a defect.
# shellcheck disable=SC1090
sess() { ( set +u; unset SSH_CONNECTION; [ -n "${1:-}" ] && export SSH_CONNECTION="$1"; \
           source "$repo/$CONSOLE/cdl"; cdl_session_name ); }
check "no SSH_CONNECTION -> cdl-local"          "$(sess)"                      "cdl-local"
check "SSH_CONNECTION set -> cdl-remote"        "$(sess '10.0.0.1 1 10.0.0.2 22')" "cdl-remote"
check "an empty SSH_CONNECTION is still local"  "$(sess '')"                   "cdl-local"

# `cdl help` must work without a tty too: `ssh host cdl help` is a stated use.
bash "$CONSOLE/cdl" help </dev/null >/dev/null 2>&1
check "cdl help exits 0 without a tty" "$?" "0"
bash "$CONSOLE/cdl" nonsense </dev/null >/dev/null 2>&1
check "an unknown subcommand exits 1" "$?" "1"

printf '\n\033[1m-- nothing runs from a profile (§9.1) --\033[0m\n'
# The single most important negative claim in §9: a launcher in .profile would capture
# scp, rsync and git-over-SSH. This greps the whole module set, not just the obvious file.
if grep -rn --include='*' -E '(^|[^-[:alnum:]_])\.?profile' install/modules/50-console.sh install/modules/52-branding.sh "$CONSOLE" install/files 2>/dev/null \
   | grep -vE '^\S+: *#' | grep -v 'never from .profile' | grep -v 'a launcher in .profile' \
   | grep -v 'lacks' | grep -v '/etc/profile' > "$work/profile.hits"; then
    if [ -s "$work/profile.hits" ]; then
        bad "something references a profile file:"; cat "$work/profile.hits"
    else
        ok "nothing writes to .profile or .bash_profile"
    fi
else
    ok "nothing writes to .profile or .bash_profile"
fi
# And positively: the launcher is installed as an executable, not sourced from an rc.
# shellcheck disable=SC2016  # a literal line to find in the module, not an expansion
if grep -q 'install_tool "$FILES/console/cdl" /usr/local/bin/cdl' install/modules/50-console.sh; then
    ok "cdl is installed as an executable in /usr/local/bin (§9.1)"
else
    bad "cdl is not installed to /usr/local/bin"
fi
# The zshrc must not launch anything either.
# shellcheck disable=SC2016  # a literal pattern to grep for, not an expansion
if grep -qE '^\s*(exec\s+)?cdl\b' "$CONSOLE/zshrc"; then
    bad "the system zshrc launches cdl"
else
    ok "the system zshrc defines and exports, but launches nothing"
fi

printf '\n\033[1m-- tty2 stays a plain getty (§9.2) --\033[0m\n'
# kmsconvt@.service ships Alias=autovt@.service; enabling the bare template would put
# kmscon on every VT including tty2. The module must enable the tty1 INSTANCE.
if grep -q 'systemctl enable -q kmsconvt@tty1.service' install/modules/50-console.sh; then
    ok "kmscon is enabled per-instance (kmsconvt@tty1), not as the autovt template"
else
    bad "kmscon enablement does not name the tty1 instance"
fi
if grep -qE 'enable -q getty@tty2.service' install/modules/50-console.sh; then
    ok "getty@tty2 is enabled explicitly"
else
    bad "tty2 is left to assumption"
fi
if grep -qE 'systemctl mask.*getty@tty1' install/modules/50-console.sh; then
    bad "getty@tty1 is masked; that deletes kmscon's OnFailure fallback (§9.6)"
else
    ok "getty@tty1 is not masked, so kmscon's OnFailure fallback survives"
fi

printf '\n\033[1m-- the Plymouth theme (§9.8) --\033[0m\n'
PLY=install/files/plymouth/cdl.script
if grep -q 'Image("logo.png")' "$PLY"; then ok "the theme loads a logo image"; else bad "no logo image load"; fi
if grep -qE 'screen_width */ *2 *- *logo\.width */ *2' "$PLY"; then
    ok "the logo is centred by computation, not by a magic offset"
else
    bad "no horizontal centre computation"
fi
if grep -q 'SetDisplayPasswordFunction' "$PLY"; then ok "a LUKS passphrase prompt is wired up"; else bad "no password callback"; fi
if grep -qE 'entry\.sprite\.SetY\(below_logo\)' "$PLY"; then
    ok "the passphrase prompt sits beneath the logo (§9.8)"
else
    bad "the prompt is not positioned below the logo"
fi
# §9.8's constraint: a theme that defines the message callbacks as empty hides the failure
# you needed to read. Both must actually draw.
for fn in message_callback status_callback; do
    if awk "/^fun $fn/,/^}/" "$PLY" | grep -q 'SetImage'; then
        ok "$fn draws what it is given (does not swallow boot messages)"
    else
        bad "$fn is empty; Escape would reveal nothing"
    fi
done
# The parameter-shadowing trap: Plymouth script has one namespace, so a global named
# `prompt` would be shadowed by display_password_callback's own `prompt` parameter.
if grep -qE '^\s*(prompt|bullets)\.sprite' "$PLY"; then
    bad "a sprite is named prompt/bullets and will be shadowed by the callback parameter"
else
    ok "sprite globals avoid the callback parameter names"
fi
# The template must be fully substitutable: a leftover token is a broken theme.
if grep -q '@@' "$PLY"; then ok "the theme is a template (colour tokens present)"; else bad "no colour tokens; the theme cannot follow the palette"; fi
if grep -q "grep -qE '@@\[A-Z_\]+@@'" install/modules/52-branding.sh; then
    ok "the module refuses to install a theme with unsubstituted tokens"
else
    bad "nothing checks for leftover tokens"
fi
# cdl_fetch_verified calls die(), and die() exits. Guarding it with a bare `if` makes the
# placeholder fallback unreachable: the module would exit on a failed download instead of
# falling back. The subshell is what makes the fallback real.
# shellcheck disable=SC2016  # a literal pattern to find in the module, not an expansion
if grep -qE 'if \( *cdl_fetch_verified "\$LOGO_URL"' install/modules/52-branding.sh; then
    ok "the logo fetch runs in a subshell, so its fallback is reachable"
else
    bad "cdl_fetch_verified is guarded by a bare if; die() would exit and the fallback is dead code"
fi

printf '\n\033[1m-- GRUB keeps its escapes (§9.8) --\033[0m\n'
if grep -q 'GRUB_DISABLE_RECOVERY=false' install/modules/52-branding.sh; then
    ok "recovery entries stay visible"
else
    bad "recovery entries are not kept visible"
fi
if grep -q 'GRUB_DISTRIBUTOR="CDL Linux"' install/modules/52-branding.sh; then ok "the menu is branded"; else bad "no GRUB_DISTRIBUTOR"; fi
if grep -q 'grub.d/cdl.cfg' install/modules/52-branding.sh; then
    ok "GRUB is configured by a drop-in, not by editing /etc/default/grub"
else
    bad "GRUB config is not a drop-in"
fi

printf '\n\033[1m-- the fallback logo --\033[0m\n'
if python3 -c "import xml.dom.minidom; xml.dom.minidom.parse('install/assets/cdl-logo.svg')" 2>/dev/null; then
    ok "install/assets/cdl-logo.svg is well-formed XML"
else
    bad "the placeholder SVG does not parse"
fi
if grep -qi 'placeholder' install/assets/cdl-logo.svg; then
    ok "the placeholder says it is a placeholder"
else
    bad "the placeholder does not identify itself"
fi
# The real logo is fetched, not committed: a public repo should not redistribute the mark.
if ls install/assets/*.png install/assets/*.webp >/dev/null 2>&1; then
    bad "a raster logo is committed to the repo; it is meant to be fetched at install time"
else
    ok "no logo raster is committed (fetched at install time with a pinned checksum)"
fi

printf '\n\033[1m-- pinned artefacts, against the real thing --\033[0m\n'
if [ -z "${CDL_NET_TESTS:-}" ]; then
    printf '  skip  pinned checksums vs fresh downloads (set CDL_NET_TESTS=1, or run tests/run-net.sh)\n'
else
    sha_of() { curl -fsSL --retry 2 "$1" -o "$work/dl" 2>/dev/null && shasum -a 256 "$work/dl" | cut -d' ' -f1; }
    pinned() { grep -E "^$1=" install/modules/*.sh | head -1 | sed -E 's/.*="([0-9a-f]{64})".*/\1/'; }

    ZV="$(grep -E '^ZELLIJ_VERSION=' install/modules/50-console.sh | cut -d'"' -f2)"
    NV="$(grep -E '^NERD_VERSION=' install/modules/50-console.sh | cut -d'"' -f2)"

    check_dl() {
        local what="$1" url="$2" want="$3" got
        got="$(sha_of "$url")"
        if [ -z "$got" ]; then bad "$what: could not download $url"; return; fi
        if [ "$got" = "$want" ]; then ok "$what sha256 matches a fresh download"
        else bad "$what sha256 MISMATCH: pinned $want, downloaded $got"; fi
    }

    zb="https://github.com/zellij-org/zellij/releases/download/v${ZV}"
    check_dl "zellij ${ZV} x86_64 tarball"  "$zb/zellij-no-web-x86_64-unknown-linux-musl.tar.gz"  "$(pinned ZELLIJ_SHA_X86_TGZ)"
    check_dl "zellij ${ZV} aarch64 tarball" "$zb/zellij-no-web-aarch64-unknown-linux-musl.tar.gz" "$(pinned ZELLIJ_SHA_ARM_TGZ)"
    check_dl "Nerd Fonts Symbols ${NV}" \
        "https://github.com/ryanoasis/nerd-fonts/releases/download/v${NV}/NerdFontsSymbolsOnly.zip" "$(pinned NERD_SHA)"
    check_dl "the CDL logo" "https://context-lab.com/images/CDL_Avatar.png" "$(pinned LOGO_SHA)"

    # Upstream publishes the checksum of the BINARY inside the tarball, not of the
    # tarball. Both are pinned, and this is the one upstream actually attests to.
    if curl -fsSL --retry 2 "$zb/zellij-no-web-x86_64-unknown-linux-musl.tar.gz" -o "$work/z.tgz" 2>/dev/null; then
        tar xzf "$work/z.tgz" -C "$work" 2>/dev/null
        got="$(shasum -a 256 "$work/zellij" | cut -d' ' -f1)"
        if [ "$got" = "$(pinned ZELLIJ_SHA_X86_BIN)" ]; then
            ok "the zellij binary inside the tarball matches upstream's published sha256"
        else
            bad "zellij inner binary MISMATCH: pinned $(pinned ZELLIJ_SHA_X86_BIN), got $got"
        fi
    fi
fi

printf '\n\033[1m-- summary --\033[0m\n'
printf '  passed: %d\n  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
