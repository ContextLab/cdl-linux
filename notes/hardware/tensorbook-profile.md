# Tensorbook hardware profile

**Source:** `scripts/capture-hardware.sh`, run as root on 2026-09-01T02:19:32Z.
**Follow-up:** `scripts/capture-followup.sh`, run 2026-09-01T12:49Z (kernel 7.0.0-30-generic —
note the machine has taken a kernel update since the first capture). Published as
`notes/hardware/tensorbook-20260901T124921Z-diagnosis.md`.

**Status: M0 is complete except the firmware gate.** Every command-capturable item is now
recorded. Outstanding: the four firmware observations, which need a reboot into setup, and the
dock connector question, deliberately deferred to M2 (§16.6).
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

**The drive-compatibility gate passes — and that is all it does.** Both drives are NVMe and
identical, so the documented "1 TB NVMe + 1 TB M.2 SATA" Tensorbook variant, which would have made
RAID0 actively harmful, does not apply to this unit. **The mixed-media striping concern is retired.**

Calling this "the striping risk is retired" would be wrong, and an earlier draft of this file did.
Every central RAID0 risk is still live:

- Either drive failing destroys the entire volume (D4/D15, accepted deliberately).
- **SMART health is still unknown** — `smartmontools` was not installed at capture time, so nothing
  here says whether these two drives are actually healthy enough to stripe.
- Off-machine backup remains load-bearing rather than a convenience.
- The 4 KiB dm-crypt tuning that motivated the layout is **unmeasured on this hardware** and is
  subagent-reported testimony.

D4/D15 proceed as designed, on the same accepted terms as before — not on better ones.

**One correction to carry into the install spec:** both drives report **512-byte logical and
512-byte physical** sectors — i.e. 512n *as reported*. (Not "512e", which specifically means 512-byte
logical over 4096-byte physical; nothing in the capture reports a 4096 physical sector, and NVMe
devices commonly under-report their internal geometry, so the honest statement is what the device
exposes.) The `--sector-size 4096` LUKS tuning is therefore a dm-crypt-layer choice made *on top of*
a device reporting 512-byte sectors, not a match to a native 4K device. It remains permitted, and the throughput claim behind it is
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

**This directly blocks D29, and the cause is now CONFIRMED rather than inferred.** The follow-up
read the lockdown state directly:

```
lockdown        : none [integrity] confidentiality
```

The bracketed `[integrity]` is the active mode. Kernel lockdown is on, which is what hides `disk`
from `/sys/power/state`; `nohibernate` is unset, ruling out the other cause. Secure Boot →
lockdown → hibernation blocked.

*Revision 2.3 recorded this as inference from documented kernel behaviour. It is now a direct
observation.* On a stock Ubuntu kernel, Secure Boot and hibernation are mutually exclusive here.

## Drive health — ✅ GO, with two anomalies worth noting

Measured 2026-09-01. Both drives pass every threshold the follow-up checks.

| | `/dev/nvme0n1` | `/dev/nvme1n1` |
|-|-|-|
| SMART health | **PASSED** | **PASSED** |
| Critical warning | `0x00` | `0x00` |
| Endurance used | **2 %** | **0 %** |
| Available spare | 100 % | 100 % |
| Media/data-integrity errors | **0** | **0** |
| Power-on hours | 255 | 206 |
| Unsafe shutdowns | **65** | **66** |
| Data written | **48.0 TB** | 5.5 TB |

**The drive-health go/no-go passes.** Zero media errors, full spare, minimal endurance consumed.
Nothing here argues against striping this pair.

**Anomaly 1 — unsafe shutdowns.** 65 and 66 unclean shutdowns against 255 and 206 power-on hours is
roughly **one unclean shutdown every 3–4 hours of uptime**. That is a stability signal, and it
interacts with two design decisions: RAID0 has no redundancy to absorb a torn write, and btrfs is
being asked to survive them. It may be benign — a machine habitually powered off by holding the
button, or counters carried over from a prior life — but it should be explained before M3 commits to
the striped layout, not after. *Derived from the captured counters, not itself a measurement of
cause.*

**Anomaly 2 — write volume.** `nvme0n1` shows 48.0 TB written in 255 power-on hours: ~52 MB/s
sustained across the drive's entire recorded life, and ~47 full drive-writes on a ~1 TB device. The
*system* drive (`nvme1n1`) shows only 5.5 TB. The heavily-written drive is the one currently holding
an unmounted whole-disk ext4 filesystem. Consistent with it having served as ML scratch or dataset
staging. Endurance is still only 2 %, so this is context rather than a problem — but it means the
two drives are not equally worn, which is worth knowing before striping them together.

## Sector geometry — settled

```
LBA Format  0 : Metadata Size: 0 bytes - Data Size: 512 bytes - Relative Performance: 0 Best (in use)
```

**Exactly one LBA format exists on both drives, 512 bytes, in use.** There is no 4096-byte format to
switch to, so these drives are 512-byte natively and cannot be reformatted to 4K. This closes the
question the profile previously got wrong: not "512e", and not a native-4K device presenting 512.

Consequence for the install spec: `--sector-size 4096` on the LUKS container remains available as a
**dm-crypt-layer** choice over 512-byte devices, and the throughput claim behind it is still
subagent-reported and unmeasured on this hardware.

## Thermal and fan control — measured, and it confirms the risk

| Fact | Value |
|-|-|
| hwmon chips | `AC0`, `acpi_fan`, `acpitz`, `BAT0`, `coretemp`, `iwlwifi_1`, `nvme` |
| Fan speed inputs | **0** |
| Writable PWM controls | **0** |
| Cooling devices | **29** |
| Idle temps | `x86_pkg_temp` 52 °C, `TCPU` 49 °C, `acpitz` 27.8 °C, `iwlwifi` 32 °C |
| CPU scaling driver | `intel_pstate` |

**The reported "no fan control at all" on this chassis is now confirmed on this unit rather than
being hearsay.** An `acpi_fan` device exists, but it exposes neither a readable speed nor a writable
control. What the system *can* do is throttle: 29 cooling devices are present, which is
`intel_pstate` and the thermal zones, not fans.

So the sustained-load policy §16.5 assigns to `cdl-first-boot-and-environment` has to be built on
**throttling and refusal-to-launch**, not on spinning fans faster. `SEN1`–`SEN4` report 50 m°C, which
is 0.05 °C and clearly an unpopulated sensor rather than a reading — do not build policy on those.

## GPU and display — ✅ GO, and better than assumed

| Fact | Value |
|-|-|
| GPU | **NVIDIA GeForce RTX 3080 Laptop GPU, 16 GB VRAM** |
| Driver / CUDA at capture | 580.173.02 / CUDA 13.0 |
| Power | 80 W default and current limit, **105 W max**, 1 W min |
| Idle temp | 47 °C |
| Internal panel | **`eDP-1` on card1 = the Intel iGPU** (`0000:00:02.0`) |
| NVIDIA outputs | card0 (`0000:01:00.0`) carries `HDMI-A-1` and `DP-5`…`DP-8` |

> **Caveat added with R18 (docking).** The milder failure mode below holds for the *internal* panel.
> The external outputs — `HDMI-A-1` and `DP-5`…`DP-8` — are on the **NVIDIA** GPU, while `DP-1`…`DP-4`
> are on the Intel side. So whether a docked external monitor depends on the NVIDIA driver comes down
> to which connector the dock actually drives, and that is unknown until the machine is captured while
> docked. `scripts/capture-followup.sh` prints the connector table for exactly that comparison —
> run it once undocked and once docked, and diff.

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

| Gap | Status |
|-|-|
| `nvme-cli` not installed | ✅ **Closed** — installed; namespace format captured and the sector question settled |
| `smartmontools` not installed | ✅ **Closed** — both drives read, both PASSED |
| Kernel lockdown state not read | ✅ **Closed** — `[integrity]` confirmed active; D29's cause is now observation, not inference |
| Fan, hwmon and thermal-zone inventory absent | ✅ **Closed** — no fan telemetry or control exists; 29 cooling devices; policy must rest on throttling |
| Battery `charge_full_design` absent | Expected — this battery reports in energy units, and `energy_full_design` was captured |
| Which GPU drives a docked external monitor | ⬜ **Deferred to M2** (§16.6). The follow-up did identify the dock itself: a **USB4 dock, "T4801" (Shenzhen Lianfaxun)**, already authorized with `iommu` policy, showing `disconnected` at capture time |
| NVIDIA connectors absent from this run | ⬜ Only `card1` (i915) connectors were enumerated this time, though the first capture saw `card0-DP-5`…`DP-8` and `HDMI-A-1`. Most likely the dGPU was runtime-suspended or unbound. **Re-check while docked** — it bears directly on §16.6 |

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
