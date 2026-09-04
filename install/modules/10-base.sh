#!/usr/bin/env bash
# The packages every later module assumes, and nothing else.
#
# Deliberately small. This module exists to prove the framework -- ordering, idempotence,
# failure propagation, run records -- against something real but harmless, before anything
# touches drivers, storage or services.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

cdl_need_root "10-base"

PACKAGES=(ca-certificates curl git jq rsync)

missing=()
for p in "${PACKAGES[@]}"; do
    cdl_pkg_present "$p" || missing+=("$p")
done

if [ "${#missing[@]}" -eq 0 ]; then
    ok "all ${#PACKAGES[@]} base packages already installed"
    exit 0
fi

log "    installing: ${missing[*]}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq                    || die "apt-get update failed"
apt-get install -y -qq "${missing[@]}" || die "apt-get install failed for: ${missing[*]}"

still=()
for p in "${missing[@]}"; do
    cdl_pkg_present "$p" || still+=("$p")
done
[ "${#still[@]}" -eq 0 ] || die "apt reported success but these are not installed: ${still[*]}"

ok "installed ${#missing[@]} package(s)"
exit 0
