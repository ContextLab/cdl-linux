# Tensorbook hardware profile

**Source:** `scripts/capture-hardware.sh`, run as root on 2026-09-01T02:19:32Z.
**Follow-up:** `scripts/capture-followup.sh`, run 2026-09-01T12:49Z (kernel 7.0.0-30-generic —
note the machine has taken a kernel update since the first capture). Published as
`notes/hardware/tensorbook-20260901T124921Z-diagnosis.md`.

**Status: M0 is COMPLETE.** The firmware gate closed 2026-09-02. Every command-capturable item was recorded by the
captures; the firmware observations were made by walking AMI Aptio V setup on 2026-09-01 and are
recorded in `notes/hardware/firmware-gate-checklist.md`. Post-reboot verification ran 2026-09-02
(`scripts/verify-firmware.sh`). Only the dock connector question remains, deliberately deferred
to M2 (§16.6).
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
| Four firmware observations not made | ✅ **Closed** — AMI Aptio V walked 2026-09-01; all four answered. See `notes/hardware/firmware-gate-checklist.md` |
| VT-d state not directly read | ✅ **Closed** — measured 2026-09-02: 4 DMAR units, TB DMA protection `1`. VT-d is active |
| Battery `charge_full_design` absent | Expected — this battery reports in energy units, and `energy_full_design` was captured |
| Which GPU drives a docked external monitor | ⬜ **Deferred to M2** (§16.6). The follow-up did identify the dock itself: a **USB4 dock, "T4801" (Shenzhen Lianfaxun)**, already authorized with `iommu` policy, showing `disconnected` at capture time |
| NVIDIA connectors absent from this run | ⬜ Only `card1` (i915) connectors were enumerated this time, though the first capture saw `card0-DP-5`…`DP-8` and `HDMI-A-1`. Most likely the dGPU was runtime-suspended or unbound. **Re-check while docked** — it bears directly on §16.6 |

## Firmware settings — the M0 gate: OBSERVED, and mostly not what was expected

**Walked 2026-09-01.** Firmware is **AMI Aptio V**, core 2.21.1278. Tabs: Main / Advanced /
Chipset / Security / Boot / Save & Exit. Full item-by-item record, including menu maps and the
reasoning for each decision, is in `notes/hardware/firmware-gate-checklist.md`.

**The headline: this firmware is heavily stripped.** Of the six settings this section previously
recommended changing, **four do not exist**. Every absence pushes work onto the OS spec rather
than resolving it, so the absences are load-bearing findings, not trivia.

### The four M0 gate observations — all answered

| Question | Answer, as read from firmware 2026-09-01 |
|-|-|
| Intel VMD/RST vs AHCI | **`Intel VMD Technology [Disabled]`.** Native NVMe. `Advanced → NVMe Configuration` lists both drives individually, and no RST menu exists. A stock installer will see both disks |
| Chipset graphics mode | **`GPU Mode [NVIDIA(R) Optimus(TM)]`** — Optimus *is* hybrid. Confirms the DRM topology from the firmware side |
| Can Secure Boot be disabled? | **Yes.** The field offers `Enabled`/`Disabled`. `System Mode [Deployed]`, `Vendor Keys [Active]` |
| Is a BIOS password set? | **No.** `Administrator Password` and `User Password` both `Not Installed` |

*Previously this section recorded VMD as "suggestive" from the `nvme` driver binding. It is now a
direct firmware read, corroborated by PCI addressing in domain `0000` and the absence of any
VMD/RAID-class controller in `lspci`.*

### What was actually changed: one setting

| Setting | Change | Why |
|-|-|-|
| **Fast Boot** | `Enabled` → **`Disabled`** | Fast Boot commonly skips USB initialisation. §11 requires installing from USB *and* permanently retaining a live-USB rescue path; a rescue stick that will not boot is not a rescue path |

### What does not exist — four recommendations this section can no longer make

| Previously recommended | Reality | Consequence |
|-|-|-|
| "Set the most aggressive cooling profile available" | **No fan, thermal or cooling-profile setting exists anywhere in this firmware** (Advanced, Chipset, and Power and Performance all searched) | Combined with the measured 0 fan inputs and 0 writable PWM, there is **nowhere in this system, firmware or OS, to influence fans**. §16.5's sustained-load policy must rest *entirely* on throttling and refusal-to-launch. This is no longer a fallback; it is the only mechanism |
| "Lower the Thunderbolt/USB4 security level" | **No security level is exposed.** `Advanced → Thunderbolt Configuration` contains one line, `Integrated Thunderbolt Support [Enabled]` | Authorisation lives wholly in `boltd`. **`bolt`/`boltctl` is now a HARD dependency for M3**: if it is absent after the reinstall, or its database does not carry across, the dock cannot be authorised and **no firmware setting can rescue it**. Measured 2026-09-02: `boltctl` present, **1 device stored** — satisfied today; the risk is carrying it across the reinstall |
| "Disable Wake on USB / XHC wake if exposed" | **Not exposed.** `Advanced → USB Configuration` contains one line, `Legacy USB Support [Enabled]`. No wake-from-Thunderbolt either | The spurious-wake hypothesis for the 65–66 unsafe shutdowns is testable and fixable **only** via `/proc/acpi/wakeup`, and any fix must be made persistent by cdl-linux, because that file resets every boot |
| "Keep S3 — verify it stays selected" | **No S3 / Modern Standby selector exists** | Benign absence: `mem_sleep` already reads `s2idle [deep]`, the outcome we wanted, and nothing can now flip it by accident |

### Wake sources — MEASURED, and the unsafe-shutdown suspect is armed

Measured 2026-09-02 from `/proc/acpi/wakeup`. Firmware exposes no wake control (see above), so
this is the only place the machine's wake configuration is visible or changeable.

**13 wake sources are enabled.** Twelve are armed at **S4**: `PEG0`, `PEG1`, `PEG2` (PCIe
graphics), `RP17`, `RP19`, `RP20` (root ports), `TXHC`, `TDM0`, `TDM1`, `TRP0`, `TRP2`
(Thunderbolt), and `AWAC`.

**One is armed at S3, and it is the suspect:**

```
XHCI	  S3	*enabled   pci:0000:00:14.0
```

`XHCI` is the main USB controller, and **S3 is the state this machine actually suspends to** —
`mem_sleep` reads `s2idle [deep]`, deep selected. So any USB event can wake this laptop out of
suspend. That is precisely the mechanism behind the profile's candidate explanation for the
**65–66 unsafe shutdowns**: a machine that wakes in a bag, overheats or drains, and gets
power-cycled by hand. The hypothesis was previously research-flagged and untested on this unit.
**It is now confirmed that the mechanism is armed**, which is not the same as confirming it
fired — that needs a suspend/resume log, not a settings read.

**Test, one command, reversible, no reboot:**

```bash
echo XHCI | sudo tee /proc/acpi/wakeup    # toggles; re-run to restore
grep XHCI /proc/acpi/wakeup               # confirm it now reads *disabled
```

**Cost of disabling:** USB devices can no longer wake the machine from suspend. The lid switch
and power button still can, so on a laptop this is close to free.

**Persistence is owed by cdl-linux.** `/proc/acpi/wakeup` resets on every boot, so a fix must be
reapplied by a systemd unit or udev rule. Carry into `cdl-first-boot-and-environment` alongside
the `boltd` dependency. Do **not** disable the Thunderbolt entries (`TXHC`, `TDM0`, `TDM1`,
`TRP0`, `TRP2`) as part of this — they are armed at S4, not S3, and docking is a requirement.

### Thermal policy — the lever exists, confirmed

Item 5 established there is no fan control anywhere, leaving §16.5's policy resting entirely on
throttling. That policy is now confirmed **implementable** (measured 2026-09-02):

```
intel_pstate no_turbo             : 0      (turbo currently on)
intel_pstate max_perf_pct         : 100    (no cap applied)
scaling driver (cpu0)             : intel_pstate
fan inputs                        : 0      (as before)
writable PWM                      : 0      (as before)
```

Both `no_turbo` and `max_perf_pct` are present and writable, so cdl-linux can drop turbo and cap
sustained frequency under agent load and restore them afterwards. This is why Turbo Mode and
Hyper-Threading stay enabled in firmware: the ceiling belongs there, the duty cycle belongs to
the OS.

### Secure Boot — unchanged, and the decision is reversible

**Left `Enabled`. Nothing was changed**, per the instruction that this is decided at §3.2 before
M3 rather than flipped to close M0.

Newly established, and it changes how §3.2 should be approached: **the decision is reversible and
testable.** `Vendor Keys [Active]`, and this firmware exposes no key-management menu at all — no
`Key Management`, no `Restore Factory Keys`, no `Erase All Secure Boot Settings`. There is
therefore no way to erase or corrupt the enrolled keys. Toggling Secure Boot off disables
*enforcement* while leaving the key store intact, so toggling it back on restores the verified
boot chain with no re-enrolment. `System Mode [Deployed]` restricts key management, not
enforcement toggling — separate axes in the UEFI spec.

So §3.2 can be **measured** rather than reasoned about: disable, boot, check `/sys/power/state`
for `disk` and `/sys/kernel/security/lockdown` for `none`, confirm the signed NVIDIA modules
still load, then keep it off or re-enable. One reboot each way, fully reversible.

### Left alone, with reasons

- **TPM** — present and usable (`MSFT0101:00`, `tpm_crb`), but D7 rejected TPM auto-unlock. No
  reason to change it; no reason to disable it either. Firmware entry is `Advanced → Trusted
  Computing`.
- **SpeedStep and Turbo Mode** — `Advanced → Power and Performance → CPU - Power Management
  Control` exposes exactly these two, both `[Enabled]`. Correct: `intel_pstate` is the active
  scaling driver and wants them. **Do not disable Turbo to compensate for the missing fan
  control** — that would cap the machine permanently, whereas `intel_pstate` can drop turbo
  dynamically under load and restore it. Firmware keeps the ceiling; the OS chooses when to duck
  under it.
- **Hyper-Threading** — `[Enabled]`, `Advanced → CPU Configuration`. Keep: D28 puts 1–2 local
  agents here and HT doubles logical cores. Same reasoning as Turbo.
- **VMX (Intel Virtualization Technology)** — `[Enabled]`. This is *CPU* virtualisation (VT-x),
  needed for any future VM work. It is **not** VT-d, and does not resolve the item below.
- **`Bootup NumLock State [Off]`** — correct, and not cosmetic. D26 has every unattended reboot
  parking at the LUKS passphrase prompt; on a keyboard with an embedded numeric keypad, NumLock
  On can turn passphrase letters into digits.
- **`Enable USB Charge Function [Disable]`** — USB power while the machine is off or asleep.
  Already disabled; good for in-bag battery drain.
- **TCG Storage Security (Opal SED)** — `Security → TCG Storage Security Configuration`, one
  submenu per drive. Each offers only `Set Admin Password` and `Set User Password`, and **both
  are unset on both drives**. Opal is supported but has never been enabled or locked, so nothing
  here will ambush the M3 install. **Leave unset**: the design is committed to LUKS (D26), and
  an Opal password is a second unlock secret outside it. Hazard, recorded so nobody tries it:
  a lost Opal password requires a **PSID revert, which erases the drive**.
- **UEFI Network Stack** — found **already `Disabled`**, which is the desired state. The design
  never network-boots, and it is pre-boot attack surface running at full firmware privilege.
  Recorded so that a firmware update re-enabling it is detectable.

### VT-d / IOMMU — MEASURED ACTIVE. Claim was true; its stated evidence was not

*This section previously asserted "VT-d — leave enabled. The Thunderbolt `iommu` policy depends
on it." That assertion is withdrawn as stated.*

**There is no VT-d toggle anywhere in this firmware.** `Advanced → CPU Configuration` contains
only `VMX` and `Hyper-Threading`; the Chipset tab has no System Agent submenu.

The evidence previously cited is `policy: iommu` at line 50 of
`tensorbook-20260901T124921Z-diagnosis.md` — that is **boltd's stored policy**, not a read of
VT-d state. bolt selects that policy when the system reports IOMMU DMA protection, so it is
strong evidence, but it is one inference removed and a stored policy persists from whenever it
was set. The first raw capture contains **zero** `iommu` mentions; the string appears only in the
follow-up.

**Settled by direct measurement 2026-09-02** (`scripts/verify-firmware.sh`, recorded in
`notes/hardware/tensorbook-20260902T030111Z-firmware-verify.md`):

```
/sys/class/iommu entries          : dmar0 dmar1 dmar2 dmar3
TB domain0 DMA protection         : 1
ACPI: DMAR 0x000000005B91F000 0000B8 (v02 INTEL  EDK2 ...)
DMAR: Host address width 39
DMAR: dmar0: reg_base_addr fed90000 ver 4:0 ...
```

**VT-d is ACTIVE**, with four DMAR units and Thunderbolt pre-boot DMA protection reporting `1`.
The original recommendation ("leave VT-d enabled") was therefore **correct**; what was wrong was
the evidence it cited. The distinction matters because a claim that happens to be true while
resting on the wrong derivation will survive until the day the derivation changes and nobody
notices. This one is now a direct read with a date, not an inference from a stored policy.

Nothing to change: VT-d cannot be switched off from this firmware in any case.

### The graphics-mode trade-off, now that docking is a requirement (R18)

Firmware confirms the current setting is `NVIDIA(R) Optimus(TM)` — hybrid. The trade-off stands
and should be decided, not defaulted:

- **Keep hybrid** (current): the internal panel is on the Intel iGPU, so a broken NVIDIA driver
  does not black out the laptop screen — measured, and the reason §12 calls the rescue story
  milder than assumed. Better battery life. Cost: external outputs on the NVIDIA connectors under
  a Wayland compositor are the fiddlier path.
- **Dedicated-GPU-only**: every output lands on one driver, which is usually simpler for external
  monitors. Cost: the internal panel then depends on the NVIDIA driver too, which **removes the
  rescue advantage M0 discovered**, and costs battery.

**Provisional recommendation: keep hybrid**, and it was left unchanged. Revisit only if the M2
dock test (§16.6) shows the dock landing on an NVIDIA connector.

### BIOS password — a §3.2 companion decision, not a separate one

Both fields exist and both are unset; left unset. The decisive reason not to set one now is
sequencing: **§3.2 requires returning to this menu** before M3 to toggle Secure Boot and measure
hibernation, and a firmware password adds lockout risk to the very next planned firmware task.
The security gain is also marginal — LUKS protects the data regardless, so a BIOS password
defends against boot-order and setup tampering, i.e. the T7 evil-maid class this profile records
as out of scope.

**But decide it together with §3.2.** If Secure Boot is disabled for hibernation, the boot chain
becomes unverified and the T1 residual ("boot tampering if the machine is recovered") worsens; a
firmware password is then cheap partial compensation. If one is ever set: Clevo-class boards
commonly store it outside CMOS, so a forgotten password may not be clearable by removing the
battery.

### Firmware age

BIOS **1.02, dated 2022-02-12** — 4.5 years old; confirmed on the Main tab, so the machine has
taken no unrecorded firmware update. Also recorded there: EC FW 1.00, MCU FW 1.00.02.00,
iGFX GOP 17.0.1064, Memory RC 2.0.2.0, product version 7.04.

Worth checking for an update, with three cautions now rather than two: research found LVFS
coverage for this class of chassis is poor, so `fwupdmgr` may not offer one; vendor updaters are
often Windows-only, which is awkward now that this machine no longer has Windows; and **a
firmware update would likely reset every setting recorded above**, which is precisely why they
are recorded. Check `fwupdmgr get-devices` before assuming either way. An update remains a
plausible fix for the suspend quirks behind the unsafe-shutdown count, but it is a risk in
itself, and nothing in the design currently depends on it.

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
