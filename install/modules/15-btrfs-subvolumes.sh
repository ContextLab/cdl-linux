#!/usr/bin/env bash
# Guard. The btrfs subvolume migration does NOT run from a live system, and this script
# exists to say so rather than to attempt it.
#
# Both ways were measured, and both fail:
#
#   snapshot the running root into @
#     -> Could not create subvolume: Text file busy
#        btrfs will not snapshot the top-level subvolume while it is mounted as root.
#
#   rename the top level's contents into @
#     -> cannot move '.../boot' -> '.../@/boot': Device or resource busy
#        a directory with a filesystem mounted on it cannot be renamed, and /boot, /proc,
#        /sys, /dev and /run all qualify.
#
# The migration therefore happens in the installer's late-commands, where the filesystem is
# mounted at /target and nothing is executing from it. See spec §2.1.3 and
# scripts/vm/autoinstall/user-data.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
if [[ "$opts" == *"subvol=/@"* ]]; then
    ok "root is already on @; nothing to do"
    exit 0
fi

# SKIP, not fail. A machine without the layout is fully supported in portable mode (§1.2),
# and exit 1 here stopped every later module on exactly the machine portable mode names as
# its only prerequisite -- a stock ext4 Ubuntu Server. Caught in cold review, not by the VM,
# whose root is on @.
cat >&2 <<'MSG'
note: this machine's root is not on the @ subvolume, and that cannot be added from here.

  The migration only works during installation, when nothing is running from the
  filesystem. Attempting it live fails two different ways (see the comments at the top of
  this file, and spec §2.1.3).

  To get the subvolume layout, reinstall using install/autoinstall.yaml, which performs the
  migration in its late-commands.

  The machine is otherwise fine without it. What is lost is §11.4's rollback, which needs a
  snapshot of root, and a top-level root cannot be snapshotted.
MSG
skip "15-btrfs-subvolumes: no subvolume layout on this machine (portable mode); later modules continue"
