# VM harness

A disposable machine that stands in for the Tensorbook, so the risky parts of
`docs/superpowers/specs/2026-09-02-cdl-box-design.md` can be tested before anything
touches real hardware.

```bash
scripts/vm/install.sh     # unattended install from autoinstall/user-data (~20 min)
scripts/vm/boot.py        # boot, answer the LUKS prompt, wait for ssh
scripts/vm/verify.sh      # acceptance checks against the running VM
```

Large artifacts live under `$TMPDIR/cdl-vm`, never in the repository: the ISO alone is 3 GB.

## What this reproduces

The parts of the design that are hard to get right and expensive to get wrong on a machine
you have to physically visit:

- **The storage layout** (spec §2.1): `md0` RAID0 across two disks, LUKS on top, btrfs on
  top of that, `/boot` deliberately outside the encryption because GRUB has to read a kernel
  before anything can be unlocked.
- **Boot and unlock** (§12 B1): whether `mdadm` assembles and `cryptsetup` unlocks from the
  initramfs, and whether the machine comes all the way back to SSH afterwards. `boot.py`
  answers the passphrase prompt on the serial console rather than using a keyfile, because a
  keyfile would test something the real machine does not do.
- **Reproducibility** (§12 S2, B9): `autoinstall/user-data` *is* the install procedure.
  Running `install.sh` twice from clean is the "two installs from the written procedure"
  that milestone asks for, with no step a human can perform differently the second time.
- **The headless posture** (§1.1): that no display stack got pulled in.
- **The backup path** (§10): `restic` and `rclone` present and working.

## What this does NOT reproduce, and it is not a short list

Read this before treating a green run as evidence about the real machine.

| Not tested | Why |
|-|-|
| **NVIDIA, CUDA, PyTorch** (§6, B2) | No GPU passthrough on an Apple Silicon host. Milestone B2 can only be run on the Tensorbook |
| **Thermal behaviour** (§2.3) | The thresholds are guesses until measured on real silicon under sustained load. A VM tells you nothing about them |
| **Thunderbolt and the dock** (§2.2) | No hardware to enrol |
| **Secure Boot, and the firmware itself** | The VM uses edk2 with its own defaults. The Tensorbook's AMI firmware is what the M0 walk characterised, and it is stripped in ways a VM is not |
| **XHCI wake and the unsafe shutdowns** (§2.2) | No real ACPI wake sources |
| **Real drive behaviour** | Two qcow2 files on one SSD. This says nothing about the unequal wear on the actual NVMe pair, and a striped pair's failure mode cannot be rehearsed here |

## The architecture gap, stated plainly

**The host is arm64 and the Tensorbook is amd64.** The harness installs Ubuntu `arm64`
because emulating x86-64 on Apple Silicon runs under TCG at roughly an order of magnitude
slower, which makes an install impractical to iterate on.

What that costs, in decreasing order of how likely it is to matter:

- **The bootloader differs.** `grub-efi-arm64` against `grub-efi-amd64`. The storage stack
  underneath is identical, but the EFI plumbing is not the same package.
- **`intel_pstate` does not exist here**, so §2.3's thermal levers cannot even be inspected.
- Some packages differ in availability or version between the two ports.

The storage layout itself, which is what this harness exists to test, is
architecture-independent: `mdadm`, `cryptsetup` and `btrfs` behave the same on both. Treat
a green run as evidence about **the layout**, and not as evidence about the machine.

One amd64 run under emulation before the real install would close most of the gap, at the
cost of a slow afternoon. That is worth doing once, and not worth doing on every change.

## Credentials

Everything in `lib.sh` and `autoinstall/user-data` is a **test credential** and is meant to
be public: the LUKS passphrase, the user password, the hostname. Nothing here is used on the
real machine, and the real machine's passphrase is typed by a human and stored nowhere.
