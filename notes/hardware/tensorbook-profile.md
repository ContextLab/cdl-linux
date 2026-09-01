# Tensorbook hardware profile

**Source:** `scripts/capture-hardware.sh`, run as root on 2026-09-01T02:19:32Z.
**Raw capture:** `notes/hardware/tensorbook-<date>-raw.md` — gitignored, retained off-machine.

Redacted: serial numbers, MAC addresses, filesystem UUIDs and hostname are deliberately absent.
This file records the *facts the design depends on*, per §15 of the design overview.

---

## Identity

| Fact | Value |
|-|-|
| Product | **TensorBook (late 2021)**, system version 7.04 |
| BIOS | **1.02, dated 2022-02-12** — 4.5 years old |
| Kernel at capture | 7.0.0-28-generic x86_64 |
| Secure Boot | **Enabled** |
| TPM | **Present and usable** — TPM 2.0, `MSFT0101:00`, driver `tpm_crb`; `systemd-cryptenroll --tpm2-device=list` resolves `/dev/tpmrm0` |

## Storage — ✅ GO

| Fact | Value |
|-|-|
| Drive 0 | Samsung `MZVL21T0HCLR-00B00`, **NVMe**, 953.9 G |
| Drive 1 | Samsung `MZVL21T0HCLR-00B00`, **NVMe**, 953.9 G — *identical model* |
| Sector sizes | PHY-SEC **512**, LOG-SEC **512** on both |
| Current layout | Drive 1 holds the live system: 1 G vfat ESP at `/boot/efi`, 952.8 G ext4 at `/`. Drive 0 is **whole-disk ext4, no partition table, unmounted** |
| Encryption | None. The current install is unencrypted |

**The striping risk is retired.** Both drives are NVMe and identical, so the documented
"1 TB NVMe + 1 TB M.2 SATA" Tensorbook variant — which would have made RAID0 actively harmful — does
not apply to this unit. D4/D15 proceed as designed.

**One correction to carry into the install spec:** both drives report 512-byte physical *and*
logical sectors, so the `--sector-size 4096` LUKS tuning is a dm-crypt-layer choice on a 512e device,
not a match to a native 4K device. It remains permitted, and the throughput claim behind it is
subagent-reported and still unverified (§17.2) — measure it on this hardware before relying on it.

## Memory — ✅ GO, with a sizing decision

| Fact | Value |
|-|-|
| Installed | **2 × 32 GB DDR4-3200 = 64 GB** (`free -g` reports 61 usable) |
| Slots | 4 total, **2 populated, 2 empty** (`Controller0/1-ChannelA-DIMM1` both "No Module Installed") |

The 64 GB assumption in the design was **correct**. But the two empty slots mean the machine can
reach 128 GB, and hibernation swap must be ≥ RAM and **cannot be resized comfortably after install**.
See "Decisions this capture forces" below.

## Sleep and hibernation — 🛑 NO-GO as configured

| Fact | Value |
|-|-|
| `/sys/power/mem_sleep` | `s2idle [deep]` — **deep S3 available and selected** |
| `/sys/power/state` | **`freeze mem`** — **`disk` is absent. Hibernation is unavailable.** |
| `resume=` on cmdline | Absent |
| Current swap | 7 GB — far below RAM in any case |

**This directly blocks D29, and the indicated cause is Secure Boot.** The kernel exposes `disk` only
when `hibernation_available()` is true, which requires both that `nohibernate` is unset — it is unset
here — and that `LOCKDOWN_HIBERNATION` is not blocked. Ubuntu puts the kernel in lockdown *integrity*
mode when Secure Boot is enabled, and that mode blocks hibernation because the resume image cannot be
verified.

*This is inference from the kernel's documented behaviour plus two measured facts (Secure Boot
enabled, no `nohibernate`), not a direct observation of the lockdown state.* The decisive test is one
command; see below.

## GPU and display — ✅ GO, and better than assumed

| Fact | Value |
|-|-|
| GPU | **NVIDIA GeForce RTX 3080 Laptop GPU, 16 GB VRAM** |
| Driver / CUDA at capture | 580.173.02 / CUDA 13.0 |
| Power | 80 W default and current limit, **105 W max**, 1 W min |
| Idle temp | 47 °C |
| Internal panel | **`eDP-1` on card1 = the Intel iGPU** (`0000:00:02.0`) |
| NVIDIA outputs | card0 (`0000:01:00.0`) carries `HDMI-A-1` and `DP-5`…`DP-8` |

**The console comes from `i915`, not `nvidia-drm`.** The machine is in hybrid/Dynamic Display Switch
mode, not "Dedicated GPU Only". This is materially good news: the internal panel is driven by the
Intel iGPU, so a broken NVIDIA driver does not by itself black out the display. The tty2 rescue getty
stays, but the failure mode it guards against is milder than the design assumed.

16 GB VRAM also sets the local-model picker ceiling concretely (D28's 1–2 local agents).

## Network — ✅ GO

| Fact | Value |
|-|-|
| Wi-Fi | **Intel Wi-Fi 6E AX210/AX1675 (Typhoon Peak)** `[8086:2725]`, driver **`iwlwifi`** |

In-kernel driver, firmware ships in `linux-firmware`. **No special wifi firmware package is needed** —
one of the open questions in §15 closes with no work required.

## Power

| Fact | Value |
|-|-|
| Battery design capacity | 5,209,000 µWh ≈ **52.1 Wh** |

## Existing kernel command line

`ro quiet splash crashkernel=2G-4G:320M,4G-32G:512M,32G-64G:1024M,64G-128G:2048M,128G-:4096M`

No NVIDIA or ACPI workarounds are currently applied, and **no `resume=`**. The `crashkernel`
reservation (2 GB at this RAM size) is Ubuntu's default and is worth revisiting — it is memory
permanently unavailable to agents.

## Capture gaps

| Gap | Consequence |
|-|-|
| `nvme-cli` not installed | No NVMe-native controller detail. Non-blocking — `lsblk` answered the drive-type question |
| `smartmontools` not installed | **No SMART wear or error history.** This was a stated go/no-go input: under RAID0 either drive's failure loses everything, so their health matters. Install `smartmontools` and re-run before M3 |
| Battery `charge_full_design` absent | Expected — this battery reports in energy units, and `energy_full_design` was captured |

## Firmware settings — still outstanding

Requires a reboot into setup; not obtainable from a running system.

- [ ] **Intel VMD/RST vs AHCI** — the highest-consequence unknown. Both drives are visible to a
      running Linux kernel with a standard NVMe driver, which is *suggestive* that VMD is off, but it
      is not proof and the installer's behaviour is what matters.
- [ ] **Chipset graphics mode** — the DRM topology already shows hybrid with the panel on the iGPU,
      so this is now confirmation rather than discovery.
- [ ] **Can Secure Boot be disabled?** — newly load-bearing; see below.
- [ ] **Is a BIOS password set?**

---

## Decisions this capture forces

### 1. Secure Boot vs hibernation — they appear to be mutually exclusive

D19 chose Ubuntu 26.04 LTS substantially *because* it ships signed precompiled NVIDIA modules that
work under Secure Boot. D29 makes hibernation a launch requirement. On a stock Ubuntu kernel, this
capture indicates you cannot have both.

**Confirm first — one command, no reboot:**

```bash
cat /sys/kernel/security/lockdown     # expect: none [integrity] confidential
```

If `integrity` is bracketed, lockdown is active and Secure Boot is the cause. The decisive test is
then to disable Secure Boot in firmware and re-check `/sys/power/state` for `disk`.

If confirmed, this is a §3.2 decision, and the branches are real:

- **Disable Secure Boot** → hibernation becomes available. Signed NVIDIA modules still load (they are
  simply no longer *required*), so D19's package choice keeps its practical benefit. Cost: the boot
  chain is unverified, which worsens T7 (evil maid) — already out of scope — and weakens T1's
  "boot tampering if the machine is recovered" residual.
- **Keep Secure Boot** → D29 fails, and §3.2 branch 3 applies: hibernation becomes an experiment,
  R8's orderly-shutdown behaviour ships as designed, and swap stays sized so the decision can be
  revisited without reinstalling.
- **Signed hibernation images** — the only way to have both. Not shipped by Ubuntu; treat as research,
  not a plan.

### 2. Swap sizing against two empty DIMM slots

Swap must be ≥ RAM for hibernation and cannot be comfortably resized later.

- Size for **today's 64 GB** (~72 GiB swap): loses ~3.5 % of the 2 TB volume.
- Size for a **possible 128 GB upgrade** (~136 GiB swap): loses ~7 %, and hibernation keeps working
  after a RAM upgrade rather than silently breaking.

The second option costs about 64 GiB of disk to avoid a reinstall later. Worth deciding now, because
it is baked in at install time.
