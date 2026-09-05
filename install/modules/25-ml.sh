#!/usr/bin/env bash
# uv, and the shared PyTorch environment every training and evaluation run starts from.
#
# ============================================================================================
# PINS. Every version and checksum below was fetched on 2026-09-05, not remembered.
# ============================================================================================
#
# uv 0.12.10, the current release (`gh release list -R astral-sh/uv` -> 0.12.10, published
# 2026-09-04T23:15:57Z). Spec §6 makes uv the environment tool for the whole machine ("**uv
# for every environment**, so packages hardlink from one shared cache instead of being copied
# per project"), which makes it infrastructure rather than a convenience, and infrastructure
# gets a checksum. Both Linux tarballs are pinned by sha256 so the arm64 test VM installs the
# same way the x86_64 machine does; the checksums were computed from the downloaded files and
# agree with the .sha256 files the release publishes beside them.
#
# torch 2.14.0, which is current on PyPI. Two builds, and the module picks between them at
# run time rather than skipping on a machine with no GPU -- a module that only ever runs on
# the one machine that has a 3080 is a module nobody can test:
#
#   GPU present -> torch==2.14.0+cu130 from https://download.pytorch.org/whl/cu130
#   otherwise   -> torch==2.14.0+cpu   from https://download.pytorch.org/whl/cpu
#
# cu130 matches the CUDA 13.3 toolkit 20-nvidia installs (CUDA minor versions are compatible
# within a major release). Ubuntu 26.04's default python3 is 3.14, and both indexes carry
# cp314 manylinux_2_28 wheels for x86_64 and aarch64 -- checked, because a pin to a version
# with no wheel for the interpreter on the box is a pin to a source build.
#
# WHAT THIS MODULE IS NOT. Spec §6 also lists transformers, datasets, peft, accelerate,
# bitsandbytes, rclone and hf-mount. They belong to the model and training modules; this one
# establishes the interpreter, the tool and the framework they all sit on, and stops there.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

cdl_need_root "25-ml"

HERE="$(cd "$(dirname "$0")" && pwd)"

UV_VERSION=0.12.10
UV_SHA256_X86_64=173d95a0c32d18c896c46ba6fafbf3cf9c14ab74b033f81b76c883ef492a976b
UV_SHA256_AARCH64=9ff6b9d4665edcdd3a88dcc73cd1eb641754deb927f14e8c62ebfde6bf4f5f5e

TORCH_VERSION=2.14.0
# NumPy rides on the same index. Without it every `import torch` warns "Failed to initialize
# NumPy", and tensor<->ndarray conversion, which every training script does, raises.
NUMPY_VERSION=2.5.2
TORCH_CUDA_TAG=cu130

CDL_OPT=/opt/cdl
VENV="$CDL_OPT/ml"
DIST="$CDL_OPT/dist"
# One cache, on the same filesystem as the venv, so §6's hardlinking actually happens: uv
# cannot hardlink a wheel across a filesystem boundary and silently copies instead.
UV_CACHE="$CDL_OPT/uv-cache"

changed=0

# --- 1. the interpreter --------------------------------------------------------------------
cdl_apt_install python3 python3-venv ca-certificates curl

# --- 2. uv, pinned by checksum ---------------------------------------------------------------
case "$(cdl_arch)" in
    x86_64)          uv_triple=x86_64-unknown-linux-gnu;  uv_sha="$UV_SHA256_X86_64" ;;
    aarch64|arm64)   uv_triple=aarch64-unknown-linux-gnu; uv_sha="$UV_SHA256_AARCH64" ;;
    *)               die "no pinned uv build for architecture $(cdl_arch); add its sha256 to this module" ;;
esac

uv_url="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uv_triple}.tar.gz"
uv_tarball="$DIST/uv-${UV_VERSION}-${uv_triple}.tar.gz"

installed_uv=""
[ -x /usr/local/bin/uv ] && installed_uv="$(/usr/local/bin/uv --version 2>/dev/null | awk '{print $2}')"

if [ "$installed_uv" = "$UV_VERSION" ]; then
    ok "uv $UV_VERSION already installed"
else
    cdl_fetch_verified "$uv_url" "$uv_tarball" "$uv_sha"
    tmp="$(mktemp -d)"
    tar -xzf "$uv_tarball" -C "$tmp" || { rm -rf "$tmp"; die "cannot unpack $uv_tarball"; }
    for b in uv uvx; do
        [ -f "$tmp/uv-${uv_triple}/$b" ] || { rm -rf "$tmp"; die "$b missing from $uv_tarball"; }
        install -m 0755 "$tmp/uv-${uv_triple}/$b" "/usr/local/bin/$b"
    done
    rm -rf "$tmp"
    got="$(/usr/local/bin/uv --version 2>/dev/null | awk '{print $2}')"
    [ "$got" = "$UV_VERSION" ] || die "installed uv reports '$got', expected $UV_VERSION"
    ok "uv $UV_VERSION installed (${uv_triple})"
    changed=1
fi

# --- 3. the shared environment ----------------------------------------------------------------
mkdir -p "$UV_CACHE" "$DIST"
if [ ! -x "$VENV/bin/python" ]; then
    dim "    creating the shared venv at $VENV"
    python3 -m venv "$VENV" || die "python3 -m venv $VENV failed (is python3-venv installed?)"
    changed=1
fi
py_version="$("$VENV/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"

# --- 4. torch: CUDA build on a GPU machine, CPU build everywhere else -------------------------
# Stated rather than inferred from the output, because "torch is installed" means two very
# different things on the two machines and the difference is what G1 checks.
if cdl_is_x86_64 && cdl_has_nvidia_gpu; then
    torch_variant="$TORCH_CUDA_TAG"
    torch_index="https://download.pytorch.org/whl/${TORCH_CUDA_TAG}"
    torch_why="x86_64 with an NVIDIA GPU, so the CUDA build"
else
    torch_variant="cpu"
    torch_index="https://download.pytorch.org/whl/cpu"
    torch_why="no x86_64 NVIDIA GPU here, so the CPU build -- the correct answer on this machine, not a degraded one"
fi
torch_want="${TORCH_VERSION}+${torch_variant}"
# Which build was chosen is reported on every run, including one that installs nothing. What
# was *done* is reported below, and only when it was done.
dim "    torch build: $torch_why (${torch_want})"

torch_have="$("$VENV/bin/python" -c 'import torch; print(torch.__version__)' 2>/dev/null || true)"
numpy_have="$("$VENV/bin/python" -c 'import numpy; print(numpy.__version__)' 2>/dev/null || true)"

if [ "$torch_have" = "$torch_want" ] && [ "$numpy_have" = "$NUMPY_VERSION" ]; then
    ok "torch $torch_want and numpy $NUMPY_VERSION already installed in $VENV (python $py_version)"
else
    if [ -n "$torch_have" ]; then dim "    replacing torch $torch_have with $torch_want"; fi
    log "    installing torch ${torch_want} from ${torch_index}"
    UV_CACHE_DIR="$UV_CACHE" /usr/local/bin/uv pip install \
        --python "$VENV/bin/python" \
        --index-url "$torch_index" \
        "torch==${torch_want}" "numpy==${NUMPY_VERSION}" \
        || die "uv pip install torch==${torch_want} numpy==${NUMPY_VERSION} failed (index: $torch_index)"

    got="$("$VENV/bin/python" -c 'import torch; print(torch.__version__)' 2>/dev/null || true)"
    [ "$got" = "$torch_want" ] || die "installed torch reports '${got:-nothing}', expected $torch_want"
    got_np="$("$VENV/bin/python" -c 'import numpy; print(numpy.__version__)' 2>/dev/null || true)"
    [ "$got_np" = "$NUMPY_VERSION" ] || die "installed numpy reports '${got_np:-nothing}', expected $NUMPY_VERSION"
    ok "torch $torch_want and numpy $NUMPY_VERSION installed in $VENV (python $py_version)"
    changed=1
fi

# --- 5. the acceptance check --------------------------------------------------------------------
if cdl_write_if_changed /usr/local/bin/cdl-ml-check < "$HERE/../bin/cdl-ml-check"; then changed=1; fi
chmod 0755 /usr/local/bin/cdl-ml-check

if [ "$changed" -eq 0 ]; then
    ok "25-ml: nothing to do"
else
    log ""
    log "    Check it with:  cdl-ml-check"
    if [ "$torch_variant" = "$TORCH_CUDA_TAG" ]; then
        log "    On this machine that needs the driver loaded, so reboot first if 20-nvidia"
        log "    has just run (spec §12, G1)."
    fi
    log ""
fi

exit 0
