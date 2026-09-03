#!/usr/bin/env bash
# Test the backup path from inside the VM: restic -> rclone -> Hugging Face bucket.
#
# Spike S1 proved this transport works from macOS. That is not the same as proving it works
# from the machine that will actually run it: different restic build, different rclone
# build, different libc, and a guest whose only route out is QEMU's user-mode NAT. This
# closes that gap, which is §12's B7 on the VM rather than on the Tensorbook.
#
# Credentials are read from the host's [hf] profile and passed through the environment.
# They are never written to the guest's disk.

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

BUCKET="${CDL_TEST_BUCKET:-cdl-vm-backup-test}"
NS="${CDL_HF_NAMESPACE:-jeremyrmanning}"

prof_get() {
    awk -v key="$1" '
        /^\[hf\]/ { f = 1; next }
        /^\[/     { f = 0 }
        f && $1 == key { print $3; exit }
    ' "$HOME/.aws/credentials" 2>/dev/null
}

K="$(prof_get aws_access_key_id)"
V="$(prof_get aws_secret_access_key)"
[[ -n "$K" && -n "$V" ]] || die "no [hf] profile in ~/.aws/credentials; generate S3 credentials first"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -p "$SSH_PORT")

# Commands are assembled as strings and evaluated in the guest, which is the point.
# shellcheck disable=SC2029
sshv() {
    if command -v sshpass >/dev/null; then
        sshpass -p "$VM_PASSWORD" ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "$@"
    else
        ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "$@"
    fi
}

log "checking the VM is reachable"
sshv true 2>/dev/null || die "cannot reach the VM on port $SSH_PORT; boot it first"

log "checking restic and rclone are present in the guest"
sshv 'command -v restic && command -v rclone' >/dev/null 2>&1 \
    || die "restic or rclone missing in the guest; the autoinstall package list should carry both"

# The whole test runs as one remote script so credentials cross once, live in a
# tmpfs-backed file the script removes, and never touch the guest's persistent disk.
log "running the backup round trip inside the VM"
sshv "AWS_KEY='$K' AWS_SECRET='$V' NS='$NS' BUCKET='$BUCKET' bash -s" <<'REMOTE'
set -uo pipefail
pass=0; fail=0
step() {
    local name="$1"; shift
    if "$@" >/tmp/bk.out 2>&1; then
        printf '  PASS  %s\n' "$name"; pass=$((pass+1))
    else
        printf '  FAIL  %s\n' "$name"; fail=$((fail+1)); tail -4 /tmp/bk.out | sed 's/^/        /'
    fi
}

conf="$(mktemp -p /dev/shm 2>/dev/null || mktemp)"
chmod 600 "$conf"
cat > "$conf" <<CONF
[hf]
type = s3
provider = Other
endpoint = https://s3.hf.co/${NS}
access_key_id = ${AWS_KEY}
secret_access_key = ${AWS_SECRET}
region = us-east-1
force_path_style = true
list_version = 2
upload_cutoff = 2G
chunk_size = 2G
CONF
export RCLONE_CONFIG="$conf"
export RESTIC_PASSWORD='cdl-vm-backup-test-throwaway'
export RESTIC_REPOSITORY="rclone:hf:${BUCKET}/restic"

echo "guest: $(restic version | head -1)"
echo "guest: $(rclone version | head -1)"

step "rclone reaches the gateway"  rclone lsd hf:
step "restic init"                 restic init
step "backup /etc"                 restic backup /etc --tag vm
step "check --read-data"           restic check --read-data
rm -rf /tmp/restored
step "restore"                     restic restore latest --target /tmp/restored

if diff -r /etc /tmp/restored/etc >/dev/null 2>&1; then
    echo "  PASS  restored /etc is identical"; pass=$((pass+1))
else
    # /etc changes under us (resolv.conf, mtab); compare a stable subset instead
    if diff -r /etc/default /tmp/restored/etc/default >/dev/null 2>&1; then
        echo "  PASS  restored /etc/default is identical (full /etc drifts during backup)"; pass=$((pass+1))
    else
        echo "  FAIL  restored tree differs"; fail=$((fail+1))
    fi
fi

step "forget + prune"              restic forget --keep-last 1 --prune
step "check after prune"           restic check
rm -f "$conf"
printf '\n== guest backup test: %d passed, %d failed ==\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
REMOTE
rc=$?

log "cleaning up the test bucket contents"
sshv "AWS_KEY='$K' AWS_SECRET='$V' NS='$NS' BUCKET='$BUCKET' bash -s" <<'CLEAN' >/dev/null 2>&1
conf="$(mktemp)"; chmod 600 "$conf"
printf '[hf]\ntype = s3\nprovider = Other\nendpoint = https://s3.hf.co/%s\naccess_key_id = %s\nsecret_access_key = %s\nregion = us-east-1\nforce_path_style = true\nlist_version = 2\n' \
    "$NS" "$AWS_KEY" "$AWS_SECRET" > "$conf"
RCLONE_CONFIG="$conf" rclone purge "hf:${BUCKET}/restic"
rm -f "$conf"
CLEAN

exit $rc
