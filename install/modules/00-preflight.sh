#!/usr/bin/env bash
# Refuse, early and specifically, rather than guessing.
#
# Everything here runs before any module has changed anything. A machine this script does
# not support should be left exactly as it was found, and told why.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

SUPPORTED_VERSION="26.04"
SUPPORTED_ARCH="x86_64"

fail=0

id="$(cdl_os_id)"; version="$(cdl_os_version)"; arch="$(cdl_arch)"

if [ "$id" != "ubuntu" ]; then
    err "this is '${id:-unknown}', not Ubuntu."
    log "    cdl-linux configures Ubuntu Server ${SUPPORTED_VERSION}. It is not a distribution"
    log "    and does not attempt to work anywhere else. Nothing has been changed."
    fail=1
elif [ "$version" != "$SUPPORTED_VERSION" ]; then
    err "this is Ubuntu ${version:-unknown}, not ${SUPPORTED_VERSION}."
    log "    Package names, kernel track and driver availability all differ between"
    log "    releases. Guessing produces a half-configured machine. Nothing has been changed."
    fail=1
else
    ok "Ubuntu ${version}"
fi

if [ "$arch" != "$SUPPORTED_ARCH" ]; then
    err "architecture is ${arch}, not ${SUPPORTED_ARCH}."
    log "    The GPU and ML stack this configures exists for ${SUPPORTED_ARCH} only."
    fail=1
else
    ok "architecture ${arch}"
fi

if cdl_is_root; then ok "running as root"
else err "not running as root; re-run with sudo"; fail=1; fi

if cdl_is_interactive; then ok "interactive session"
else dim "    non-interactive session: modules must not prompt"; fi

[ "$fail" -eq 0 ] || exit 1
exit 0
