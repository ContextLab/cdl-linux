#!/usr/bin/env bash
# install/modules/40-agents.sh and install/bin/cdl-agent: what can be checked without root,
# apt or an Ubuntu machine to install onto.
#
# Runs on macOS. It covers: lint, the honesty of the pinned checksums (each is compared
# against a tarball downloaded here and now, so a checksum that was never fetched fails),
# and cdl-agent's credential handling -- the refusal on a bad keys file, and the exact set
# of environment variables each agent gets (spec §4.1).
#
# What it cannot cover -- actually installing the binaries, apt, npm, systemd -- belongs to
# tests/vm/verify-agents.sh, which runs inside the installed guest, and is absent here
# rather than faked.

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  \033[32mOK\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has(){ if grep -q "$2" "$3"; then ok "$1"; else bad "$1"; fi; }

MODULE="$repo/install/modules/40-agents.sh"
AGENT="$repo/install/bin/cdl-agent"
VERIFY="$repo/tests/vm/verify-agents.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------------------
printf '\n-- lint --\n'
# ---------------------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    for f in "$MODULE" "$AGENT" "$VERIFY"; do
        if (cd "$(dirname "$f")" && shellcheck -x "$(basename "$f")"); then
            ok "shellcheck -x $(basename "$f")"
        else
            bad "shellcheck -x $(basename "$f")"
        fi
    done
else
    bad "shellcheck is not installed; the lint assertions could not run"
fi
for f in "$MODULE" "$AGENT" "$VERIFY"; do
    if bash -n "$f"; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done

# ---------------------------------------------------------------------------------------
printf '\n-- module contract --\n'
# ---------------------------------------------------------------------------------------
has "40-agents sets -uo pipefail"                 'set -uo pipefail' "$MODULE"
# shellcheck disable=SC2016  # a literal grep pattern; expansion is exactly what must not happen
has "40-agents sources lib.sh"                    'source "$(dirname "$0")/../lib.sh"' "$MODULE"
has "40-agents carries the source-path directive" '# shellcheck source-path=SCRIPTDIR source=../lib.sh' "$MODULE"
has "40-agents calls cdl_need_root"               'cdl_need_root "40-agents"' "$MODULE"
has "40-agents uses cdl_fetch_verified"           'cdl_fetch_verified' "$MODULE"

managed="$(sed -n 's/^CDL_MANAGED="\(.*\)"$/\1/p' "$repo/install/lib.sh")"
if [ -n "$managed" ]; then ok "lib.sh defines CDL_MANAGED"; else bad "cannot read CDL_MANAGED from lib.sh"; fi
if grep -Fxq "$managed" "$AGENT"; then ok "cdl-agent carries the CDL_MANAGED line"
else bad "cdl-agent does not carry lib.sh's CDL_MANAGED line verbatim"; fi

# ---------------------------------------------------------------------------------------
printf '\n-- pins are real (network, live downloads kept) --\n'
# ---------------------------------------------------------------------------------------
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

codex_version="$(sed -n 's/^CODEX_VERSION=\(.*\)$/\1/p' "$MODULE")"
codex_tag="rust-v${codex_version}"
opencode_version="$(sed -n 's/^OPENCODE_VERSION=\(.*\)$/\1/p' "$MODULE")"
gemini_version="$(sed -n 's/^GEMINI_VERSION=\(.*\)$/\1/p' "$MODULE")"

if [ -n "$codex_version" ]; then ok "40-agents pins a codex version ($codex_version)"; else bad "no CODEX_VERSION"; fi
if [ -n "$opencode_version" ]; then ok "40-agents pins an opencode version ($opencode_version)"; else bad "no OPENCODE_VERSION"; fi
if [ -n "$gemini_version" ]; then ok "40-agents pins a gemini-cli version ($gemini_version)"; else bad "no GEMINI_VERSION"; fi

# codex: two arches, two pinned checksums
for spec in "x86_64:CODEX_SHA256_X86_64:codex-x86_64-unknown-linux-musl.tar.gz" \
            "aarch64:CODEX_SHA256_AARCH64:codex-aarch64-unknown-linux-musl.tar.gz"; do
    IFS=: read -r arch var asset <<<"$spec"
    want="$(sed -n "s/^${var}=\\(.*\\)\$/\\1/p" "$MODULE")"
    if [[ "$want" =~ ^[0-9a-f]{64}$ ]]; then ok "40-agents has a codex $arch sha256"; else bad "$var is not a sha256: '$want'"; fi
    url="https://github.com/openai/codex/releases/download/${codex_tag}/${asset}"
    dest="$work/$asset"
    if curl -fsSL --retry 2 -o "$dest" "$url"; then
        got="$(sha256_of "$dest")"
        check "codex $codex_version $arch sha256 matches a fresh download" "$got" "$want"
        if tar tzf "$dest" | grep -qx "codex-${arch}-unknown-linux-musl"; then
            ok "codex $arch tarball contains the single binary 40-agents expects"
        else
            bad "codex $arch tarball layout is not what 40-agents expects"
        fi
    else
        bad "could not download $url (the checksum assertion did not run)"
    fi
done

# opencode: two arches, two pinned checksums, different asset-name arch spelling
for spec in "x86_64:OPENCODE_SHA256_X86_64:opencode-linux-x64.tar.gz" \
            "aarch64:OPENCODE_SHA256_AARCH64:opencode-linux-arm64.tar.gz"; do
    IFS=: read -r arch var asset <<<"$spec"
    want="$(sed -n "s/^${var}=\\(.*\\)\$/\\1/p" "$MODULE")"
    if [[ "$want" =~ ^[0-9a-f]{64}$ ]]; then ok "40-agents has an opencode $arch sha256"; else bad "$var is not a sha256: '$want'"; fi
    url="https://github.com/sst/opencode/releases/download/v${opencode_version}/${asset}"
    dest="$work/$asset"
    if curl -fsSL --retry 2 -o "$dest" "$url"; then
        got="$(sha256_of "$dest")"
        check "opencode $opencode_version $arch sha256 matches a fresh download" "$got" "$want"
        if tar tzf "$dest" | grep -qx "opencode"; then
            ok "opencode $arch tarball contains the single binary 40-agents expects"
        else
            bad "opencode $arch tarball layout is not what 40-agents expects"
        fi
    else
        bad "could not download $url (the checksum assertion did not run)"
    fi
done

x86="$(sed -n 's/^CODEX_SHA256_X86_64=\(.*\)$/\1/p' "$MODULE")"
arm="$(sed -n 's/^CODEX_SHA256_AARCH64=\(.*\)$/\1/p' "$MODULE")"
if [ "$x86" = "$arm" ]; then bad "codex's two architectures carry the same sha256; one is wrong"; else ok "codex's two architectures have different checksums"; fi

# gemini-cli: no standalone Linux binary to pin a checksum for (npm-only; documented in the
# module's own header). Confirm the decision against the live release, so a future gemini-cli
# release that *does* ship one is noticed rather than silently left on the npm path forever.
if release_json="$(curl -fsSL "https://api.github.com/repos/google-gemini/gemini-cli/releases/tags/v${gemini_version}" 2>/dev/null)"; then
    if grep -o '"name": *"[^"]*"' <<<"$release_json" | grep -qiE 'linux.*\.(tar\.gz|zip|AppImage)"$|linux-(x64|x86_64|arm64|aarch64)'; then
        bad "gemini-cli v${gemini_version} now ships a Linux release asset; 40-agents should use it instead of npm"
    else
        ok "gemini-cli v${gemini_version} still ships no standalone Linux binary (npm route is correct)"
    fi
else
    bad "could not reach the GitHub API to verify gemini-cli's release assets"
fi

# ---------------------------------------------------------------------------------------
printf '\n-- cdl-agent: the keys file is refused unless it is exactly right --\n'
# ---------------------------------------------------------------------------------------
keysdir="$work/home/.config/cdl"
mkdir -p "$keysdir"
KEYS="$keysdir/keys"
cat > "$KEYS" <<'EOF'
ANTHROPIC_API_KEY=fixture-anthropic
OPENAI_API_KEY=fixture-openai
GEMINI_API_KEY=fixture-gemini
OPENROUTER_API_KEY=fixture-openrouter
TOGETHER_API_KEY=fixture-together
FIREWORKS_API_KEY=fixture-fireworks
EOF

run_agent() { CDL_KEYS_FILE="$KEYS" CDL_SESSION_DIR="$work/sessions" bash "$AGENT" "$@"; }

chmod 600 "$KEYS"
if out="$(run_agent --print-env claude 2>&1)"; then ok "a 0600, self-owned keys file is accepted"
else bad "a correct keys file was refused: $out"; fi

chmod 644 "$KEYS"
out="$(run_agent --print-env claude 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "cdl-agent refuses a mode-0644 keys file"; else bad "cdl-agent accepted a mode-0644 keys file"; fi
if grep -qi '0600' <<<"$out"; then ok "the refusal names the required mode"; else bad "refusal message: $out"; fi
chmod 600 "$KEYS"

# A keys file owned by another uid cannot be constructed without root (chown needs
# privilege this suite does not run with). Assert the check exists in the code instead:
# cdl-agent must compare the file's owner against the invoking user before trusting it.
has "cdl-agent compares the keys file's owner to the invoking user" 'id -un' "$AGENT"
if grep -q 'owned by' "$AGENT"; then ok "cdl-agent's refusal names the owner mismatch"; else bad "no owner-mismatch message found"; fi

# A missing keys file is not an error -- every key is simply absent.
out="$(CDL_KEYS_FILE="$work/does-not-exist" CDL_SESSION_DIR="$work/sessions" bash "$AGENT" --print-env claude 2>&1)"; rc=$?
check "a missing keys file is not refused" "$rc" "0"
if [ -z "$out" ]; then ok "a missing keys file exports nothing"; else bad "expected no output, got: $out"; fi

# ---------------------------------------------------------------------------------------
printf '\n-- cdl-agent: exactly the right variables, per agent (spec §4.1) --\n'
# ---------------------------------------------------------------------------------------
FORBIDDEN="ANTHROPIC_BASE_URL DISABLE_TELEMETRY DO_NOT_TRACK CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC DISABLE_GROWTHBOOK"

claude_env="$(run_agent --print-env claude)"
any_forbidden=0
for v in $FORBIDDEN; do
    if grep -qx "$v" <<<"$claude_env"; then any_forbidden=1; bad "claude's env includes forbidden variable $v"; fi
done
[ "$any_forbidden" -eq 0 ] && ok "claude never gets any of the five forbidden variables"
if grep -qx 'ANTHROPIC_API_KEY' <<<"$claude_env"; then ok "claude gets ANTHROPIC_API_KEY"; else bad "claude did not get ANTHROPIC_API_KEY: $claude_env"; fi

codex_env="$(run_agent --print-env codex)"
if grep -qx 'OPENAI_API_KEY' <<<"$codex_env"; then ok "codex gets OPENAI_API_KEY"; else bad "codex env: $codex_env"; fi
if grep -qx 'ANTHROPIC_API_KEY' <<<"$codex_env"; then bad "codex must not get ANTHROPIC_API_KEY: $codex_env"; else ok "codex does not get ANTHROPIC_API_KEY"; fi

gemini_env="$(run_agent --print-env gemini)"
if grep -qx 'GEMINI_API_KEY' <<<"$gemini_env"; then ok "gemini gets GEMINI_API_KEY"; else bad "gemini env: $gemini_env"; fi
if grep -qx 'OPENAI_API_KEY' <<<"$gemini_env"; then bad "gemini must not get OPENAI_API_KEY: $gemini_env"; else ok "gemini does not get OPENAI_API_KEY"; fi

opencode_env="$(run_agent --print-env opencode)"
for v in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY \
         OPENROUTER_API_KEY OR_API_KEY TOGETHER_API_KEY TOGETHERAI_API_KEY FIREWORKS_API_KEY FIREWORKS_AI_API_KEY; do
    if grep -qx "$v" <<<"$opencode_env"; then ok "opencode gets $v"; else bad "opencode did not get $v: $opencode_env"; fi
done

# --- an agent that does not exist is refused, not silently passed through ---------------
out="$(run_agent --print-env nonesuch 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "an unknown agent name is refused"; else bad "unknown agent 'nonesuch' was accepted"; fi

# ---------------------------------------------------------------------------------------
printf '\n-- cdl-agent list: never a value --\n'
# ---------------------------------------------------------------------------------------
list_out="$(run_agent list)"
if [ -n "$list_out" ]; then ok "cdl-agent list produced output"; else bad "cdl-agent list produced no output"; fi
leaked=0
for val in fixture-anthropic fixture-openai fixture-gemini fixture-openrouter fixture-together fixture-fireworks; do
    if grep -q "$val" <<<"$list_out"; then leaked=1; bad "cdl-agent list printed a key value ($val)"; fi
done
[ "$leaked" -eq 0 ] && ok "cdl-agent list never prints a key value"
if grep -q 'ANTHROPIC_API_KEY' <<<"$list_out"; then ok "cdl-agent list names which keys are present"; else bad "list output: $list_out"; fi

printf '\n  test-agents: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
