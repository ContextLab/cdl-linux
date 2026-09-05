#!/usr/bin/env bash
# NVIDIA driver, CUDA toolkit, persistence mode and the §2.3 power cap.
#
# ============================================================================================
# THE DECISION: Ubuntu's archive driver, NVIDIA's CUDA toolkit. Both halves were checked
# against the live repositories on 2026-09-05 rather than assumed.
# ============================================================================================
#
# NVIDIA *does* publish a 26.04 CUDA repository. This was the open question and it has an
# answer:
#
#   https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/x86_64/  -> HTTP 200
#   .../ubuntu2504/...                                                           -> HTTP 404
#   .../ubuntu2404/...                                                           -> HTTP 200
#
# It is a flat repository (`Release` has no `Suites`/`Components`; `Origin: NVIDIA`,
# `Label: NVIDIA CUDA`), and its signing key is 60DF8A40.pub, not ubuntu2404's 3bf863cc.pub:
#
#   pub   rsa4096 2025-11-24 [SCEA] 14BAFBC7562AD710CA04E69905FBB6DA60DF8A40
#   uid                             Kitmaker (Ubuntu 26.04) <kitmaker@nvidia.com>
#
# So both sources exist and the choice is real. It is split, and here is why.
#
# DRIVER: Ubuntu archive. Spec §6 asks for the "NVIDIA driver from the Ubuntu archive
# (signed, loads under Secure Boot)", and §2.1.1 narrows the claim this machine makes to
# "signed kernel and modules". Canonical signs the `restricted`-component modules with the
# key Ubuntu's shim already trusts; NVIDIA's own `cuda-drivers`/`nvidia-open` packages build
# through DKMS on the machine, and a locally built module is unsigned, so Secure Boot refuses
# to load it until somebody enrols a MOK by hand at the console. That is the opposite of a
# reproducible install. Ubuntu 26.04 (resolute) carries, in `restricted` with security
# support:
#
#   nvidia-driver-595        595.84-0ubuntu0.26.04.1   NVIDIA driver metapackage
#   nvidia-utils-595         595.84-0ubuntu0.26.04.1   nvidia-smi and friends
#   nvidia-compute-utils-595 595.84-0ubuntu0.26.04.1   provides nvidia-persistenced
#   linux-modules-nvidia-595-generic{,-hwe-26.04}      prebuilt SIGNED modules
#
# CUDA TOOLKIT: NVIDIA's repository, which §3.2 permits ("the script adds third-party APT
# sources it needs (NVIDIA's, ...)"). Ubuntu's own `nvidia-cuda-toolkit` trails NVIDIA's by
# releases, and the ubuntu2604 repository ships exactly one toolkit series: `cuda-toolkit-13-3`
# at 13.3.1-1. That series pairs with the r595 driver branch, which is checkable rather than
# hopeful -- the same repository's `cuda-drivers` 595.58.03 declares
# `Depends: nvidia-driver (>= 595.58.03)`, and Ubuntu's nvidia-driver-595 is 595.84.
#
# THE PIN THAT MAKES THE SPLIT HOLD. NVIDIA's repository also contains `nvidia-driver`,
# `nvidia-open` and `cuda-drivers`, all of which would happily replace the signed Ubuntu
# driver during a routine upgrade. /etc/apt/preferences.d pins that origin below the archive
# (priority 100), so packages that exist only there -- the CUDA toolkit -- still install,
# while anything Ubuntu also ships keeps coming from Ubuntu. This is also what §11.2 means by
# the driver being "pinned, and never in the unattended set".
#
# REBOOT. The kernel module is not loaded by installing it. `cdl-gpu-check` and
# `cdl-ml-check` therefore fail until the machine has been rebooted once, and §12's G1 is
# explicit that its exit test is `nvidia-smi` and `torch.cuda.is_available()` "**after a
# reboot**, not only after install". This module says so at the end of a run that installed
# anything, and does not attempt to load the module itself.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

# Before the root check, deliberately: an arm64 VM or a laptop with no discrete GPU must be
# able to establish that this module does not apply without being root to find out.
cdl_require_gpu_or_skip "20-nvidia"

cdl_need_root "20-nvidia"

HERE="$(cd "$(dirname "$0")" && pwd)"

DRIVER_BRANCH=595
CUDA_SERIES=13-3
NVIDIA_REPO="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/x86_64/"
NVIDIA_KEY="${NVIDIA_REPO}60DF8A40.pub"

changed=0

# --- 1. the signed kernel module, matched to the kernel that is actually installed ---------
# `nvidia-driver-595` depends on `nvidia-dkms-595`, and every `linux-modules-nvidia-595-*`
# package *provides* it. Installing the prebuilt one first satisfies that dependency with
# Canonical-signed modules, so DKMS never builds anything. Which flavour depends on which
# kernel metapackage this machine tracks, so it is read rather than guessed.
kernel_flavour=""
if cdl_pkg_present "linux-image-generic-hwe-26.04"; then
    kernel_flavour="generic-hwe-26.04"
elif cdl_pkg_present "linux-image-generic"; then
    kernel_flavour="generic"
else
    # e.g. 7.0.0-31-generic -> generic
    kernel_flavour="$(uname -r | cut -d- -f3-)"
fi

cdl_apt_update_once || die "apt-get update failed"

modules_pkg="linux-modules-nvidia-${DRIVER_BRANCH}-${kernel_flavour}"
if apt-cache show "$modules_pkg" >/dev/null 2>&1; then
    if ! cdl_pkg_present "$modules_pkg"; then changed=1; fi
    cdl_apt_install "$modules_pkg"
    dim "    signed prebuilt modules: $modules_pkg"
else
    # Not fatal, but it is the difference between a machine that boots into the driver and
    # one that stops at a blue MOK-enrolment screen, so it is said plainly rather than logged.
    warn "no prebuilt signed module package for kernel flavour '$kernel_flavour'"
    warn "    falling back to DKMS. Under Secure Boot the module will not load until a MOK"
    warn "    is enrolled at the console (see spec §2.1.1)."
fi

# --- 2. driver and userspace, from the Ubuntu archive -------------------------------------
DRIVER_PKGS=(
    "nvidia-driver-${DRIVER_BRANCH}"
    "nvidia-utils-${DRIVER_BRANCH}"
    "nvidia-compute-utils-${DRIVER_BRANCH}"   # provides nvidia-persistenced
)
for p in "${DRIVER_PKGS[@]}"; do cdl_pkg_present "$p" || changed=1; done
cdl_apt_install "${DRIVER_PKGS[@]}"

# --- 3. NVIDIA's repository, pinned below the archive --------------------------------------
cdl_apt_source "cdl-nvidia-cuda" "$NVIDIA_KEY" "Types: deb
URIs: $NVIDIA_REPO
Suites: /"

# Priority 100: install what only this origin has (the CUDA toolkit), never prefer it over a
# package Ubuntu also ships (the driver).
if cdl_write_if_changed /etc/apt/preferences.d/cdl-nvidia-cuda.pref <<EOF
$CDL_MANAGED
# Keep the signed Ubuntu driver: NVIDIA's repository also carries nvidia-driver,
# nvidia-open and cuda-drivers, and an upgrade from there would replace it with an
# unsigned DKMS build (spec §2.1.1, §11.2).
Package: *
Pin: origin developer.download.nvidia.com
Pin-Priority: 100
EOF
then
    changed=1
    _CDL_APT_UPDATED=
fi

# --- 4. the CUDA toolkit -------------------------------------------------------------------
cuda_pkg="cuda-toolkit-${CUDA_SERIES}"
cdl_pkg_present "$cuda_pkg" || changed=1
cdl_apt_install "$cuda_pkg"

# --- 5. persistence mode --------------------------------------------------------------------
# Without it the driver unloads whenever the last client exits, and the next `nvidia-smi`
# or CUDA context pays a multi-second re-initialisation. On a box that serves models and
# runs training, that cost is paid constantly.
if cdl_have_systemd; then
    cdl_enable_now nvidia-persistenced.service
    ok "nvidia-persistenced enabled"
else
    warn "no systemd here: nvidia-persistenced not enabled (unit files are still written)"
fi

# --- 6. §2.3's GPU power cap ------------------------------------------------------------------
# The numbers are §2.3's own and §2.3 calls them provisional, so they are configuration
# rather than constants. cdl-gpu-powercap reads this file; the future cdl-thermal daemon
# reads the same one.
if cdl_write_if_changed "$CDL_ETC/gpu.conf" <<EOF
$CDL_MANAGED
#
# Spec §2.3's GPU thermal and power policy.
#
# EVERY NUMBER HERE IS AN ESTIMATE. §2.3 states them as starting values and says they are
# "equally provisional and equally due for measurement under B4"; §12's G1 requires that
# "§2.3's temperature and VRAM thresholds are replaced with recorded numbers". Until that
# happens these are a starting point, not a measurement.
#
# Boot-time power cap, in watts, or 'default' for the card's own default limit. §2.3 gives a
# range rather than a boot value -- a floor of 80 W and a ceiling of the card's default -- so
# the ceiling is what the machine boots into, and stepping down is the thermal daemon's job.
CDL_GPU_POWER_CAP_W=default

# §2.3: "Soft limit >= 80 C: reduce the power cap by 15 W, floor 80 W"
CDL_GPU_POWER_FLOOR_W=80
CDL_GPU_POWER_STEP_W=15
CDL_GPU_TEMP_SOFT_C=80

# §2.3: "Recover <= 70 C for 60 s: raise by 15 W, ceiling the card's default"
CDL_GPU_TEMP_RECOVER_C=70
CDL_GPU_RECOVER_DWELL_S=60

# §2.3: "Admission >= 87 C: refuse to load a new model or start a training run, and say why".
# §2.3 is equally clear about what this never does: it does not kill a running job.
CDL_GPU_TEMP_ADMISSION_C=87

# §2.3: sampled on the same 5 s interval as the CPU policy.
CDL_GPU_SAMPLE_INTERVAL_S=5
EOF
then changed=1; fi

for script in cdl-gpu-powercap cdl-gpu-check; do
    if cdl_write_if_changed "/usr/local/bin/$script" < "$HERE/../bin/$script"; then changed=1; fi
    chmod 0755 "/usr/local/bin/$script"
done

# Oneshot at boot. RemainAfterExit so a re-run of the unit is a deliberate act rather than
# something systemd repeats; it must run after the driver is up, which is what
# nvidia-persistenced.service being started implies.
if cdl_write_unit cdl-gpu-powercap.service <<EOF
$CDL_MANAGED
[Unit]
Description=cdl-linux: apply the spec §2.3 GPU power cap
Documentation=file:///etc/cdl/gpu.conf
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service
ConditionPathExists=/dev/nvidiactl

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/cdl-gpu-powercap

[Install]
WantedBy=multi-user.target
EOF
then changed=1; fi

if cdl_have_systemd; then
    # Not cdl_enable_now: ConditionPathExists=/dev/nvidiactl is false until the module has
    # loaded, so before the first reboot `start` would report a condition failure and
    # cdl_enable_now would treat that as fatal. Enable it; boot runs it.
    systemctl is-enabled -q cdl-gpu-powercap.service 2>/dev/null \
        || systemctl enable -q cdl-gpu-powercap.service \
        || die "cannot enable cdl-gpu-powercap.service"
    if [ -e /dev/nvidiactl ]; then
        systemctl start cdl-gpu-powercap.service \
            || warn "cdl-gpu-powercap.service did not start; see: journalctl -u cdl-gpu-powercap"
    fi
else
    warn "no systemd here: cdl-gpu-powercap.service written but not enabled"
fi

# --- 7. record what was installed ------------------------------------------------------------
# PACKAGED versions only, and no timestamp: this file has to be byte-identical on a second
# run, or the run is not idempotent. The *loaded* driver version deliberately does not go in
# here -- it is empty before the first reboot and a version string after it, so recording it
# would rewrite the file on the first idle post-reboot run and re-print "A REBOOT IS
# REQUIRED" on a machine that had already been rebooted. It is reported on stdout below
# instead, where saying it twice costs nothing. What installed this is already in
# /var/log/cdl/install-runs.jsonl.
driver_ver="$(dpkg-query -W -f='${Version}' "nvidia-driver-${DRIVER_BRANCH}" 2>/dev/null)"
utils_ver="$(dpkg-query -W -f='${Version}'  "nvidia-utils-${DRIVER_BRANCH}"  2>/dev/null)"
cuda_ver="$(dpkg-query -W -f='${Version}'   "$cuda_pkg"                      2>/dev/null)"
modules_ver="$(dpkg-query -W -f='${Version}' "$modules_pkg" 2>/dev/null || true)"

if cdl_write_if_changed "$CDL_ETC/nvidia.txt" <<EOF
$CDL_MANAGED
#
# What install/modules/20-nvidia.sh put on this machine. Driver from Ubuntu's archive
# (signed, Secure Boot); CUDA toolkit from NVIDIA's ubuntu2604 repository. See the comments
# at the top of that module for why the two come from different places.

driver_package        nvidia-driver-${DRIVER_BRANCH}
driver_version        ${driver_ver:-not-installed}
driver_source         ubuntu-archive (restricted)
utils_version         ${utils_ver:-not-installed}
kernel_modules        ${modules_pkg}
kernel_modules_version ${modules_ver:-none (DKMS fallback)}
cuda_package          ${cuda_pkg}
cuda_version          ${cuda_ver:-not-installed}
cuda_source           ${NVIDIA_REPO}
EOF
then changed=1; fi

# Reported, never recorded. Reading it must not influence `changed`.
runtime_ver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
if [ -n "$runtime_ver" ]; then
    dim "    loaded driver: $runtime_ver"
else
    dim "    loaded driver: none yet (the module loads at boot)"
fi

if [ "$changed" -eq 1 ]; then
    ok "driver ${driver_ver:-?}, CUDA ${cuda_ver:-?}; recorded in $CDL_ETC/nvidia.txt"
    log ""
    log "    A REBOOT IS REQUIRED. The kernel module is installed but not loaded, so"
    log "    cdl-gpu-check and cdl-ml-check fail until this machine has been rebooted."
    log "    §12's G1 is checked after that reboot, not now:"
    log ""
    log "        sudo reboot"
    log "        cdl-gpu-check && cdl-ml-check"
    log ""
else
    ok "driver ${driver_ver:-?} and CUDA ${cuda_ver:-?} already installed; nothing to do"
fi

exit 0
