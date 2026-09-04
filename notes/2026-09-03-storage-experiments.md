# Storage layout: the experiments behind §2.1 (2026-09-03)

Moved out of the specification. This is the evidence; the spec carries the contract. Every
row was measured in the VM harness, none on the Tensorbook.

## What the stock installer will and will not do

| Attempt | Result |
|-|-|
| Build md/LUKS/btrfs + all three subvolumes in `early-commands`, hand curtin `preserve: true` | curtin crashes: `'NoneType' object has no attribute 'size'` |
| Let curtin build the stack from a normal storage config | Installs cleanly, **creates no subvolumes**; root lands in the top level (`subvolid=5`) |
| Set `storage:config:mount:options` to `subvol=/@` | Documented by Canonical to be silently dropped by subiquity, so this cannot work and fails without an error |

Verified over SSH on the installed VM: `md0` raid0 with two members, LUKS on `md0`, btrfs
root, `/boot` outside the encryption, `crypttab` referencing `md0`, initramfs carrying
cryptsetup and md, and a console unlock at boot -- **all pass**. Only the subvolumes fail.

## Why the migration cannot run on a live system

| Approach | Result |
|-|-|
| `btrfs subvolume snapshot` of the running root into `@` | `Could not create subvolume: Text file busy` |
| Rename the top level's contents into `@` | `cannot move '.../boot': Device or resource busy` -- a directory with a filesystem mounted on it cannot be renamed, and `/boot`, `/proc`, `/sys`, `/dev`, `/run` all qualify |

## The inline-in-YAML attempt, and how it failed

The first migration was written directly into `late-commands`. It failed with exit 2 and
left the installer at `Press enter to start a shell` for six hours.

The cause was ordinary and the diagnosis was expensive. The script set
`fstab=/tmp/top/@/etc/fstab`, unmounted `/tmp/top`, and then ran `awk` against `$fstab`.
`awk` cannot open a path under a directory that is no longer mounted, exits 2, and `set -e`
takes the installation down with it. `/boot` was never remounted and `update-grub` never
ran.

**What made it expensive was not the bug.** The failure message named the entire script
rather than a line, nothing had been written to the target, and the `set -x` trace went to
the guest's journal, which the harness cannot read. Six hours of VM time produced one bit of
information: it did not work.

An earlier draft attributed a previous exit 2 to `curtin in-target` having stale mount
bookkeeping after a manual remount. **That was asserted rather than measured.** This run
used an explicit chroot instead and still exited 2, but from `awk`, before reaching the
chroot -- so it neither confirms nor refutes the curtin explanation, which remains untested.

## Options considered for the subvolume problem

| Option | Cost |
|-|-|
| Root not in a subvolume, `@home` and `@models` created afterwards | Loses §11.4's rollback, which needs a snapshot of root -- the reason `@` exists |
| Migrate to `@` from `install.sh`, on the running system | **Impossible**, per the table above |
| Migrate to `@` in the installer | **Chosen.** Everything else already works; the VM can run it destructively at no cost |
| Drop btrfs for root, ext4 instead | Simplest, and loses snapshots on the thing snapshots were for |
| Abandon the stock installer for storage | Contradicts §1.2 and is most of what a custom ISO was going to cost |

## A considered alternative, rejected for a practical reason

Two LUKS devices with btrfs spanning both (`-d raid0 -m raid1`) would stripe data while
mirroring metadata, so a single-device failure would leave a mountable filesystem that can
at least enumerate what was lost. The Ubuntu installer cannot produce that layout, and
building it by hand contradicts §3's stock-installer premise. Revisit if the storage layout
is ever rebuilt outside the installer.
