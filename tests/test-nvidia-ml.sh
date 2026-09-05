#!/usr/bin/env bash
# 20-nvidia and 25-ml: the parts that can be checked without a GPU, a root shell or Ubuntu.
#
# Runs on macOS. What it covers is the module contract (lint, the skip path, the shipped
# helper scripts) and the honesty of the pins: the uv checksums in 25-ml.sh are compared
# against tarballs downloaded here and now, so a checksum that was never fetched fails.
#
# What it cannot cover -- installing a driver, resolving apt, importing torch -- belongs to
# tests/vm/verify-nvidia-ml.sh, which runs inside the installed guest, and is absent here
# rather than faked.

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  \033[32mOK\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
# $1 description  $2 grep pattern  $3 file. A helper rather than `grep && ok || bad`, which
# reads as if-then-else and is not (ShellCheck SC2015 is right about it).
has(){ if grep -q "$2" "$3"; then ok "$1"; else bad "$1"; fi; }
hasi(){ if grep -qi "$2" "$3"; then ok "$1"; else bad "$1"; fi; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

NVIDIA="$repo/install/modules/20-nvidia.sh"
ML="$repo/install/modules/25-ml.sh"
BIN="$repo/install/bin"

# --- lint ---------------------------------------------------------------------------------
printf '\n-- lint --\n'
if command -v shellcheck >/dev/null 2>&1; then
    for f in "$NVIDIA" "$ML" "$BIN/cdl-gpu-check" "$BIN/cdl-ml-check" "$BIN/cdl-gpu-powercap" \
             "$repo/tests/vm/verify-nvidia-ml.sh"; do
        if (cd "$(dirname "$f")" && shellcheck -x "$(basename "$f")"); then
            ok "shellcheck -x $(basename "$f")"
        else
            bad "shellcheck -x $(basename "$f")"
        fi
    done
else
    bad "shellcheck is not installed; the lint assertions could not run"
fi

for f in "$NVIDIA" "$ML" "$BIN/cdl-gpu-check" "$BIN/cdl-ml-check" "$BIN/cdl-gpu-powercap" \
         "$repo/tests/vm/verify-nvidia-ml.sh"; do
    if bash -n "$f"; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done

# --- the module contract --------------------------------------------------------------------
printf '\n-- module contract --\n'
for f in "$NVIDIA" "$ML"; do
    b="$(basename "$f")"
    has "$b sets -uo pipefail"                  'set -uo pipefail' "$f"
    # shellcheck disable=SC2016  # a literal grep pattern; expansion is exactly what must not happen
    has "$b sources lib.sh"                     'source "$(dirname "$0")/../lib.sh"' "$f"
    has "$b carries the source-path directive"  '# shellcheck source-path=SCRIPTDIR source=../lib.sh' "$f"
    has "$b calls cdl_need_root"                "cdl_need_root \"${b%.sh}\"" "$f"
done

# Files outside /etc/cdl and /opt/cdl carry the managed header, and it is the same string
# lib.sh defines rather than one that merely looks like it.
managed="$(sed -n 's/^CDL_MANAGED="\(.*\)"$/\1/p' "$repo/install/lib.sh")"
if [ -n "$managed" ]; then ok "lib.sh defines CDL_MANAGED"; else bad "cannot read CDL_MANAGED from lib.sh"; fi
for f in "$BIN/cdl-gpu-check" "$BIN/cdl-ml-check" "$BIN/cdl-gpu-powercap"; do
    if grep -Fxq "$managed" "$f"; then ok "$(basename "$f") carries the CDL_MANAGED line"
    else bad "$(basename "$f") does not carry lib.sh's CDL_MANAGED line verbatim"; fi
done

# --- 20-nvidia skips rather than failing, and does it before asking for root ------------------
printf '\n-- 20-nvidia skip path --\n'
osr="$work/os-release"
printf 'ID=ubuntu\nVERSION_ID="26.04"\n' > "$osr"

# This test runs unprivileged on purpose: the skip has to happen before cdl_need_root, or an
# arm64 VM cannot even establish that the module does not apply to it.
if [ "$(id -u)" -eq 0 ]; then
    bad "this suite must not run as root; the skip-before-root assertion would be vacuous"
else
    ok "running unprivileged, so 'skip before root' is a real assertion"
fi

out="$(CDL_OS_RELEASE="$osr" CDL_ARCH=aarch64 bash "$NVIDIA" 2>&1)"; rc=$?
check "20-nvidia exits 2 on aarch64" "$rc" "2"
if grep -q 'no x86_64 NVIDIA GPU' <<<"$out"; then ok "the aarch64 skip says why"; else bad "aarch64 skip message: $out"; fi
if grep -qi 'needs root' <<<"$out"; then bad "20-nvidia demanded root before skipping"; else ok "20-nvidia skips without needing root"; fi

# x86_64 with no NVIDIA device on the bus: there is no lspci on macOS, which is exactly the
# 'x86_64 machine with no discrete GPU' case, and it must skip rather than fail.
out="$(CDL_OS_RELEASE="$osr" CDL_ARCH=x86_64 bash "$NVIDIA" 2>&1)"; rc=$?
check "20-nvidia exits 2 on x86_64 with no NVIDIA GPU" "$rc" "2"
if grep -qi 'needs root' <<<"$out"; then bad "20-nvidia demanded root before skipping (x86_64)"; else ok "x86_64 skip happens before the root check"; fi
if [ "$rc" -eq 1 ]; then bad "20-nvidia failed instead of skipping"; fi

# The GPU gate has to be the very first thing the module does.
first_gate="$(grep -vE '^[[:space:]]*#' "$NVIDIA" | grep -oE 'cdl_require_gpu_or_skip|cdl_need_root' | head -1)"
check "20-nvidia's first gate is the GPU check, not the root check" "$first_gate" "cdl_require_gpu_or_skip"

# --- 25-ml is NOT gated on a GPU --------------------------------------------------------------
printf '\n-- 25-ml runs everywhere --\n'
if grep -q 'cdl_require_gpu_or_skip' "$ML"; then
    bad "25-ml skips on non-GPU machines; it must install the CPU build instead"
else
    ok "25-ml does not gate itself on a GPU"
fi
# Reaching the root check proves nothing skipped ahead of it.
out="$(CDL_OS_RELEASE="$osr" CDL_ARCH=aarch64 bash "$ML" 2>&1)"; rc=$?
check "25-ml on aarch64 without root exits 1 (not 2)" "$rc" "1"
if grep -qi 'needs root' <<<"$out"; then ok "25-ml reached cdl_need_root on a non-GPU machine"; else bad "25-ml output: $out"; fi

# The GPU/CPU choice must be visible in the output, not inferred.
if grep -q 'so the CPU build' "$ML" && grep -q 'so the CUDA build' "$ML"; then
    ok "25-ml states which torch build it is installing"
else
    bad "25-ml does not name the build it chose"
fi

# --- the pins are real ---------------------------------------------------------------------
printf '\n-- pins (real downloads) --\n'
uv_version="$(sed -n 's/^UV_VERSION=\(.*\)$/\1/p' "$ML")"
sha_x86="$(sed -n 's/^UV_SHA256_X86_64=\(.*\)$/\1/p' "$ML")"
sha_arm="$(sed -n 's/^UV_SHA256_AARCH64=\(.*\)$/\1/p' "$ML")"

if [ -n "$uv_version" ]; then ok "25-ml pins a uv version ($uv_version)"; else bad "25-ml has no UV_VERSION"; fi
if [[ "$sha_x86" =~ ^[0-9a-f]{64}$ ]]; then ok "25-ml has an x86_64 uv sha256"; else bad "UV_SHA256_X86_64 is not a sha256: '$sha_x86'"; fi
if [[ "$sha_arm" =~ ^[0-9a-f]{64}$ ]]; then ok "25-ml has an aarch64 uv sha256"; else bad "UV_SHA256_AARCH64 is not a sha256: '$sha_arm'"; fi
if [ "$sha_x86" = "$sha_arm" ]; then bad "both architectures carry the same sha256; one of them is wrong"; else ok "the two architectures have different checksums"; fi

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# A real download, because the point of a checksum is that somebody fetched the bytes it
# describes. Offline, this fails and says so; it does not pass quietly.
for spec in "x86_64-unknown-linux-gnu:$sha_x86" "aarch64-unknown-linux-gnu:$sha_arm"; do
    triple="${spec%%:*}"; want="${spec##*:}"
    url="https://github.com/astral-sh/uv/releases/download/${uv_version}/uv-${triple}.tar.gz"
    dest="$work/uv-$triple.tar.gz"
    if curl -fsSL --retry 2 -o "$dest" "$url"; then
        got="$(sha256_of "$dest")"
        check "uv $uv_version $triple sha256 matches a fresh download" "$got" "$want"
        if tar tzf "$dest" | grep -qx "uv-${triple}/uv"; then
            ok "$triple tarball contains uv-${triple}/uv, which is what 25-ml extracts"
        else
            bad "$triple tarball layout is not what 25-ml expects"
        fi
    else
        bad "could not download $url (the checksum assertion did not run)"
    fi
done

# The torch pins name a wheel that has to exist for the interpreter on the target machine.
# Ubuntu 26.04's default python3 is 3.14 (python3 3.14.3-0ubuntu2 in resolute), so cp314 is
# the tag that matters; a pin whose only wheels are cp313 is a pin to a source build.
torch_version="$(sed -n 's/^TORCH_VERSION=\(.*\)$/\1/p' "$ML")"
torch_cuda_tag="$(sed -n 's/^TORCH_CUDA_TAG=\(.*\)$/\1/p' "$ML")"
if [ -n "$torch_version" ]; then ok "25-ml pins a torch version ($torch_version)"; else bad "25-ml has no TORCH_VERSION"; fi

# The index page is saved before it is searched: `curl | grep -q` makes grep close the pipe
# on the first match, curl exits 23, and pipefail turns a successful check into a failure.
wheel_on_index() { # $1 index dir  $2 variant  $3 arch
    local page="$work/whl-$1.html"
    [ -s "$page" ] || curl -fsSL -o "$page" "https://download.pytorch.org/whl/$1/torch/" || return 1
    grep -qF "torch-${torch_version}%2B${2}-cp314-cp314-manylinux_2_28_${3}.whl" "$page"
}
for want in "cpu:cpu:x86_64" "cpu:cpu:aarch64" "${torch_cuda_tag}:${torch_cuda_tag}:x86_64"; do
    IFS=: read -r idx variant arch <<<"$want"
    if wheel_on_index "$idx" "$variant" "$arch"; then
        ok "torch ${torch_version}+${variant} has a cp314 ${arch} wheel on the ${idx} index"
    else
        bad "no torch-${torch_version}+${variant} cp314 ${arch} wheel on https://download.pytorch.org/whl/${idx}/torch/"
    fi
done

# 20-nvidia's whole decision rests on NVIDIA publishing a 26.04 repository with a 26.04 key.
# Both are checked live, because "we looked it up once" is not a property a test can assert.
nv_repo="$(sed -n 's|^NVIDIA_REPO="\(.*\)"$|\1|p' "$NVIDIA")"
nv_key="${nv_repo}60DF8A40.pub"
if [ -n "$nv_repo" ]; then ok "20-nvidia names a CUDA repository ($nv_repo)"; else bad "20-nvidia has no NVIDIA_REPO"; fi
case "$nv_repo" in
    *ubuntu2604*) ok "the CUDA repository is the 26.04 one, not a 24.04 stand-in" ;;
    *)            bad "the CUDA repository is not ubuntu2604: $nv_repo" ;;
esac
code="$(curl -s -o /dev/null -w '%{http_code}' "$nv_repo")"
check "NVIDIA's ubuntu2604 CUDA repository answers" "$code" "200"
if key="$(curl -fsSL "$nv_key")"; then
    if grep -q 'BEGIN PGP PUBLIC KEY BLOCK' <<<"$key"; then
        ok "its signing key is a real armoured public key"
    else
        bad "$nv_key did not return a PGP public key"
    fi
else
    bad "could not fetch the signing key $nv_key"
fi
has "20-nvidia fetches that key by name" '60DF8A40.pub' "$NVIDIA"

# The driver must come from Ubuntu's archive, and NVIDIA's origin must be pinned below it, or
# a routine upgrade replaces the signed module with an unsigned DKMS build (spec §2.1.1).
has "20-nvidia pins NVIDIA's origin below the archive" 'Pin-Priority: 100' "$NVIDIA"
has "20-nvidia installs an nvidia-driver metapackage" 'nvidia-driver-' "$NVIDIA"
has "the driver branch is pinned to a number"        'DRIVER_BRANCH=595' "$NVIDIA"
if grep -qE 'cdl_apt_install[^\n]*cuda-drivers|cdl_apt_install[^\n]*nvidia-open' "$NVIDIA"; then
    bad "20-nvidia installs NVIDIA's own driver packages, which are unsigned DKMS builds"
else
    ok "20-nvidia does not install cuda-drivers or nvidia-open"
fi

# --- the shipped helper scripts ----------------------------------------------------------------
printf '\n-- helper scripts --\n'
# cdl-ml-check embeds python. Extract it exactly as bash would and compile it, so a syntax
# error there is caught here instead of on the machine.
awk '/<<'"'"'PY'"'"'$/{f=1;next} f&&/^PY$/{f=0} f' "$BIN/cdl-ml-check" > "$work/ml-check.py"
if [ -s "$work/ml-check.py" ]; then ok "cdl-ml-check's python block extracted"; else bad "no python heredoc found in cdl-ml-check"; fi
if python3 -m py_compile "$work/ml-check.py" 2>"$work/pyerr"; then
    ok "cdl-ml-check's python compiles"
else
    bad "cdl-ml-check's python does not compile: $(cat "$work/pyerr")"
fi
if grep -q 'torch.cuda.is_available()' "$work/ml-check.py"; then ok "cdl-ml-check reports torch.cuda.is_available()"; else bad "cdl-ml-check does not report torch.cuda.is_available()"; fi
if grep -q 'torch.__version__' "$work/ml-check.py"; then ok "cdl-ml-check prints the torch version"; else bad "cdl-ml-check does not print the torch version"; fi
if grep -q 'gpu_present and not cuda_ok' "$work/ml-check.py"; then ok "cdl-ml-check fails when a GPU is present but CUDA is not"; else bad "cdl-ml-check has no GPU-without-CUDA failure"; fi

# Both checks must be able to fail. A checker that cannot exit nonzero is decoration.
for f in "$BIN/cdl-gpu-check" "$BIN/cdl-ml-check"; do
    if grep -q 'exit 1' "$f"; then ok "$(basename "$f") can exit nonzero"; else bad "$(basename "$f") never exits nonzero"; fi
done
if grep -q 'nvidia-smi' "$BIN/cdl-gpu-check"; then ok "cdl-gpu-check runs nvidia-smi"; else bad "cdl-gpu-check does not run nvidia-smi"; fi

# Both modules install their checker, and 20-nvidia says a reboot is needed.
has  "20-nvidia installs cdl-gpu-check"     'cdl-gpu-check'        "$NVIDIA"
has  "20-nvidia writes into /usr/local/bin" '/usr/local/bin/'      "$NVIDIA"
has  "25-ml installs cdl-ml-check"          '/usr/local/bin/cdl-ml-check' "$ML"
hasi "20-nvidia says a reboot is required"  'REBOOT IS REQUIRED'   "$NVIDIA"
has  "20-nvidia names the G1 milestone"     'G1'                   "$NVIDIA"

# --- §2.3's power cap -----------------------------------------------------------------------
printf '\n-- the §2.3 power cap --\n'
has  "cdl-gpu-powercap applies the cap with nvidia-smi -pl" 'nvidia-smi -pl'    "$BIN/cdl-gpu-powercap"
has  "the power cap runs from a oneshot unit"               'Type=oneshot'      "$NVIDIA"
has  "20-nvidia writes gpu.conf"                            'gpu.conf'          "$NVIDIA"
has  "gpu.conf carries the 80 W floor from the spec"        'CDL_GPU_POWER_FLOOR_W=80' "$NVIDIA"
hasi "gpu.conf says the numbers are estimates"              'ESTIMATE'          "$NVIDIA"
has  "20-nvidia enables nvidia-persistenced"                'nvidia-persistenced' "$NVIDIA"
has  "20-nvidia records versions in nvidia.txt"             'nvidia.txt'        "$NVIDIA"

# --- the checkers actually behave, rather than merely containing the right words ------------
printf '\n-- the checkers, run here --\n'
# There is no nvidia-smi on this machine, which is the "driver not installed" case both
# scripts exist to catch. A checker that cannot detect that is a checker nobody can trust.
out="$(bash "$BIN/cdl-gpu-check" 2>&1)"; rc=$?
check "cdl-gpu-check exits nonzero where nvidia-smi is absent" "$rc" "1"
if grep -q 'nvidia-smi is not installed' <<<"$out"; then ok "cdl-gpu-check names the missing nvidia-smi"; else bad "cdl-gpu-check said: $out"; fi

out="$(bash "$BIN/cdl-ml-check" 2>&1)"; rc=$?
check "cdl-ml-check exits nonzero where the venv is absent" "$rc" "1"
if grep -q '/opt/cdl/ml/bin/python does not exist' <<<"$out"; then ok "cdl-ml-check names the missing venv"; else bad "cdl-ml-check said: $out"; fi

# cdl-gpu-powercap runs from a boot unit, so a missing card must be a clean no-op rather than
# a unit that fails at every boot on a machine whose driver has not come up yet.
out="$(bash "$BIN/cdl-gpu-powercap" 2>&1)"; rc=$?
check "cdl-gpu-powercap exits 0 when nvidia-smi is absent" "$rc" "0"
if grep -q 'nvidia-smi absent' <<<"$out"; then ok "cdl-gpu-powercap says why it did nothing"; else bad "cdl-gpu-powercap said: $out"; fi

printf '\n  test-nvidia-ml: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
