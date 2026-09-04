# Appliance-mode autoinstall

`tensorbook.yaml` builds the storage layout in spec §2.1: two NVMe drives striped into one
`md` RAID0 device, LUKS on top, btrfs with `@`, `@home` and `@models`, and `/boot` outside
the encryption.

**You do not need this file.** Portable mode — `./install.sh` on an existing Ubuntu Server
26.04 install — configures everything except storage and is the mode that works on any
machine. This profile exists for one specific two-drive laptop, and it is where all of the
destructive risk in this project lives.

## Before you use it

**This erases both drives, and RAID0 has no redundancy.** Spec §10 requires a restore-tested
backup *and* a second copy the machine holds no credential for, before this runs on hardware
with anything on it.

## It is a template, and will not install as committed

Three placeholders must be substituted when the install medium is built:

| Placeholder | What it is |
|-|-|
| `@@CDL_LUKS_PASSPHRASE@@` | The disk encryption passphrase, typed at every boot |
| `@@CDL_PASSWORD_HASH@@` | The local account's password hash, from `openssl passwd -6` |
| `@@CDL_SSH_PUBKEY@@` | The public key allowed to log in — SSH is key-only |

**None of these belong in this repository, which is public.** A committed passphrase is a
published one, and rotating a LUKS passphrase afterwards does not un-publish the passphrase
the disk was created with.

Substitute them onto the medium, not into a file you might commit:

```bash
mkdir -p /Volumes/CIDATA
sed -e "s|@@CDL_LUKS_PASSPHRASE@@|$(read -rsp 'LUKS passphrase: ' p; echo "$p")|" \
    -e "s|@@CDL_PASSWORD_HASH@@|$(openssl passwd -6)|" \
    -e "s|@@CDL_SSH_PUBKEY@@|$(cat ~/.ssh/id_ed25519.pub)|" \
    install/autoinstall/tensorbook.yaml > /Volumes/CIDATA/user-data
printf 'instance-id: cdl-box\nlocal-hostname: cdl-box\n' > /Volumes/CIDATA/meta-data
base64 -i install/installer/migrate-btrfs-root.sh | tr -d '\n' > /Volumes/CIDATA/migrate.b64
```

The volume must be labelled `CIDATA` for cloud-init's NoCloud datasource to find it.

## Disks are matched by identity, not by enumeration

`/dev/nvme0n1` is whatever the kernel probed first this boot, and on a two-drive machine
the names can swap between boots. Installing over the wrong drive is not recoverable.

`early-commands` therefore refuses unless exactly two NVMe disks of roughly the expected
size are present, and prints the serials it found. For a stronger check, set
`CDL_EXPECTED_SERIALS` on the medium to a space-separated list; the guard then refuses any
disk whose serial is not in it. Serials are not committed here because they are hardware
identifiers and this repository is public — `notes/hardware/` is gitignored for the same
reason.

## Why this is separate from `scripts/vm/autoinstall/user-data`

That one is a test fixture: 20 GB partitions, virtio disks, and a passphrase in plain text
because it protects nothing. Sharing one file between the test rig and a machine holding
real work is how a test credential ends up on the real machine.

The two files share the thing worth sharing — `install/installer/migrate-btrfs-root.sh` —
and nothing else.
