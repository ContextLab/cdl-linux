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

opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
if [[ "$opts" == *"subvol=/@"* ]]; then
    printf '\033[32m ok:\033[0m root is already on @; nothing to do.\n'
    exit 0
fi

cat >&2 <<'MSG'
fatal: this machine's root is not on the @ subvolume, and that cannot be fixed from here.

  The migration only works during installation, when nothing is running from the
  filesystem. Attempting it live fails two different ways (see the comments at the top of
  this file, and spec §2.1.3).

  To get the subvolume layout, reinstall using install/autoinstall.yaml, which performs the
  migration in its late-commands.

  The machine is otherwise fine without it. What is lost is §11.4's rollback, which needs a
  snapshot of root, and a top-level root cannot be snapshotted.
MSG
exit 1
