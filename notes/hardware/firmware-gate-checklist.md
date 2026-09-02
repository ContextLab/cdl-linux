# Firmware gate — working checklist

Closes item 1 of "Resume here" (`notes/2026-08-31-session-02-spec-review.md`).
Settings described by **function**, not menu name — names differ between firmware revisions.
**An absence is a finding:** if a setting is not exposed, record that.

Started: 2026-09-01. Machine: TensorBook (late 2021), BIOS 1.02 dated 2022-02-12.

| # | Item | Action | Status | Observed value |
|-|-|-|-|-|
| 0 | Enter firmware setup | — | ✅ | Reached setup directly (no `--firmware-setup` needed) |
| 1 | Intel VMD / RST vs AHCI | Record; **turn off if on** | ✅ | **`Intel VMD Technology [Disabled]`** — stated by firmware. No change needed |
| 2 | Secure Boot — can it be disabled? | **Record only, do NOT change** | ✅ | **YES — toggle offers Enabled/Disabled.** Left `Enabled` |
| 3 | BIOS password state | Record | ✅ | Admin + User fields exist, **both unset**. Left unset — see note |
| 4 | Graphics mode (hybrid vs dGPU-only) | Record; keep hybrid | ✅ | **`GPU Mode [NVIDIA(R) Optimus(TM)]`** = hybrid. **Left unchanged** |
| 5 | Fan / cooling profile | **Change** → most aggressive | ➖ | **ABSENT — no fan/thermal setting exists in this firmware** |
| 6 | Fast Boot | **Change** → disable | ⬜ | |
| 7 | Wake on USB / XHC wake | **Change** → disable if exposed | ➖ | **ABSENT.** Only `Legacy USB Support [Enabled]` exists — kept |
| 8 | Thunderbolt / USB4 security level | **Change** → lower, or pre-authorise dock | ➖ | **No security level exposed.** Master toggle only, `[Enabled]` — kept |
| 9 | Sleep mode S3 vs Modern Standby | Verify S3 stays selected | ✅ | No selector exposed; `deep` already selected & cannot be flipped |
| 10 | VT-d / IOMMU | Verify **enabled**, leave alone | ➖ | **Not exposed anywhere.** Resolve by measurement (item 11) |
| 12 | UEFI Network Stack *(added mid-walk)* | **Change** → disable | ✅ | **Already `Disabled`.** Desired state; no change made |
| 11 | Save & exit, post-reboot verification | Run verification block | ⬜ | |

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked · ➖ not exposed (a finding)

## Log

**Firmware identified:** AMI **Aptio V**, core version 2.21.1278 (c) 2022.
Tabs: Main / Advanced / Chipset / Security / Boot / Save & Exit.

**Versions read from Main tab (2026-09-01):**
- BIOS **1.02** — matches the DMI value captured from Linux. No unrecorded update.
- **EC FW 1.00** — new, not previously captured.
- **MCU FW 1.00.02.00** — new, not previously captured.
- **iGFX GOP 17.0.1064** — new. Intel Graphics Output Protocol driver.
- **Memory RC 2.0.2.0** — new. Intel memory reference code.

**Menu map — `Advanced` tab (verbatim, top to bottom):**
CPU Configuration · Power and Performance · Thunderbolt Configuration · Trusted Computing ·
USB Configuration · Network Stack Configuration · NVMe Configuration

Notable **absences** on Advanced (each is a finding per the M0 rule):
- No `SATA Configuration` / `SATA And RST Configuration` / `VMD Configuration` — consistent with
  VMD being off. A board in RST mode normally exposes an RST menu here. Still to check: Chipset.
- No `ACPI Settings` — usual home of the S3 vs S0ix selector (item 9). Check Chipset.
- **No fan or thermal entry.** If none exists under Chipset either, item 5's recommendation is
  *unavailable*, and §16.5's thermal policy must rest entirely on throttling and
  refusal-to-launch. Not yet concluded.

Also: `Product version 7.04` on Main matches the DMI value already in the profile.

**Item 1 — VMD evidence from `tensorbook-2026-08-31-raw.md`:**
- Both NVMe controllers enumerate at `02:00.0` and `03:00.0` in PCI domain `0000` —
  ordinary root-port addressing.
- **No** Intel Volume Management Device / RAID-class controller anywhere in lspci.
- No PCI domain other than `0000` exists in the capture.
With VMD enabled, Intel's VMD controller appears as a RAID-class device and the NVMe
endpoints move to a synthetic domain (`10000:…`). Neither is present ⇒ VMD is **off**.

**Confirmed in firmware 2026-09-01:** no RST/VMD menu exists on the Advanced tab, and
`Advanced → NVMe Configuration` lists **both drives individually** — the direct-attach
signature. Under VMD the endpoints are masked behind the VMD controller instead.

**Direct firmware confirmation:** `Chipset → Intel VMD Technology [Disabled]`. The firmware
states it outright — four independent signals now agree.

**Item 1 RESOLVED: native NVMe, VMD off. No firmware change made.** A stock Ubuntu
installer will see both disks. This retires the highest-consequence unknown in M0 and
upgrades the profile's "suggestive" wording to a direct observation.


### Menu map — `Chipset` tab (flat, no submenus)

```
GPU Mode                   [NVIDIA(R) Optimus(TM)]
Intel VMD Technology       [Disabled]
Enable USB Charge Function [Disable]
```

**Item 4 RESOLVED — graphics mode.** `NVIDIA(R) Optimus(TM)` *is* hybrid mode: the iGPU drives
the internal panel, the dGPU renders on demand. This confirms the DRM topology captured from
Linux (panel on `card1`/i915) from the firmware side. **Left unchanged**, per the profile's
provisional recommendation: hybrid preserves the rescue advantage — a broken NVIDIA driver
cannot black out the internal panel. Revisit only if the M2 dock test (§16.6) lands the
external display on an NVIDIA connector.

**Incidental:** `Enable USB Charge Function [Disable]` — USB power delivery while the machine is
off/asleep. Already disabled; good for in-bag battery drain. No change.

**Absences on Chipset (findings):**
- No VT-d / IOMMU setting here. Captured Thunderbolt `iommu` policy proves VT-d is *active*,
  so the toggle must live elsewhere — check `Advanced → CPU Configuration`.
- No fan or thermal profile. Two tabs down, none found. Last candidate: `Power and Performance`.
- No S3 / Modern Standby selector. Last candidate: `Power and Performance`.

### Menu map — `Advanced → Power and Performance`

Single submenu, `CPU - Power Management Control`, containing exactly two settings:

```
Intel(R) SpeedStep(tm)  [Enabled]
Turbo Mode              [Enabled]
```

Both already match the profile's "leave alone" recommendation — `intel_pstate` is the active
scaling driver and wants both enabled. **No change.**

### Item 5 RESOLVED — and it is the bad branch: NO FAN CONTROL EXISTS

Searched Advanced, Chipset, and Power and Performance. **This firmware exposes no fan curve, no
cooling profile, and no thermal-policy setting of any kind.**

Combined with the measured `0 fan inputs, 0 writable PWM` from the OS side, the conclusion is
now complete and symmetric: **there is nowhere in this system — firmware or OS — to influence
fan behaviour.** The profile's recommendation ("set the most aggressive cooling profile
available") is void; no such setting is available.

**Design consequence.** §16.5's sustained-load policy for `cdl-first-boot-and-environment` must
rest *entirely* on throttling and refusal-to-launch, exactly as the profile's fallback
anticipated. This is no longer a precaution — it is the only available mechanism.

**But the policy does have a lever.** Fans are uncontrollable; CPU frequency is not.
`intel_pstate` is the active driver, and it exposes runtime throttling
(`no_turbo`, `max_perf_pct`). So Turbo Mode should stay **Enabled in firmware** — surrendering
it permanently here would cap the machine forever, whereas the OS can drop turbo dynamically
under sustained agent load and restore it after. Firmware keeps the ceiling; the OS chooses
when to duck under it. *To be verified post-reboot — see item 11.*

### Item 9 RESOLVED — sleep mode

No S3 / Modern Standby selector is exposed anywhere. This is the **benign** absence: the OS
already measured `mem_sleep = s2idle [deep]` with deep S3 selected, which is the outcome the
profile wanted. Nothing to change, and nothing that can accidentally flip it.

### Menu map — `Advanced -> CPU Configuration` (partial)

```
Intel (VMX) Virtualization Technology  [Enabled]
Hyper-Threading                        [Enabled]
```

Both correct as found; **no change**.
- `VMX` (= VT-x) is *CPU* virtualisation - needed for any future VM/hypervisor work. It is **not**
  VT-d, so it does not resolve item 10.
- `Hyper-Threading` enabled: keep. D28 puts 1-2 local agents here and HT doubles logical cores.
  Same logic as Turbo Mode - do not trade permanent capacity for a marginal thermal gain when
  the OS holds a dynamic throttle.

**Three Intel "V" features, all distinct, all now recorded:**
VMX = CPU virtualisation (Enabled) - VT-d = IOMMU (not exposed, see item 10) -
VMD = storage presentation (Disabled).

### Item 10 - correction to the profile's evidence

The profile (line 259) asserts VT-d is enabled "because the Thunderbolt `iommu` policy depends
on it". Re-checked against source: the actual evidence is `policy: iommu` at line 50 of the
follow-up diagnosis, which is **boltd's stored policy**, not a direct read of VT-d state. bolt
selects that policy when the system reports IOMMU DMA protection, so it is strong evidence -
but it is one inference removed, and a stored policy persists from whenever it was set. The
first raw capture contains **zero** `iommu` mentions; the string appears only in the follow-up.

No VT-d toggle found on Chipset or (so far) CPU Configuration. **Resolve by direct measurement
post-reboot rather than by menu archaeology** - see item 11.

### Item 12 - UEFI Network Stack (added during the walk, not in the original plan)

`Advanced -> Network Stack Configuration`. **Recommendation: disable.**

- The design never network-boots: SS11 installs from USB and permanently retains a live-USB
  rescue path. PXE / HTTP boot is unused now and at M3.
- It is pre-boot attack surface running at full firmware privilege, so disabling marginally
  improves the T1 residual (boot tampering if the machine is recovered).
- **No effect on Linux networking** - this governs UEFI's own stack, not the OS's. Linux drives
  the NIC via `iwlwifi` / the dock's ethernet driver regardless.
- Cheap partial compensation if the D29 branch later disables Secure Boot and weakens the boot
  chain deliberately.

Cost: loses network-boot recovery, which this design does not use.

**Observed 2026-09-01: already `Disabled`.** No change was needed - the desired state was the
factory default. Recorded so a future firmware update that re-enables it is detectable.

### Item 8 RESOLVED - Thunderbolt security is not a firmware setting on this board

`Advanced -> Thunderbolt Configuration` contains **exactly one entry**:

```
Integrated Thunderbolt Support  [Enabled]
```

Kept enabled - docking is a hard requirement (R18/D35/P8) and this is the dock's only path.

**No `Security Level`, no `Native OS Security`, no `Thunderbolt Boot Support`, no
`Wake From Thunderbolt Devices`.** The firmware exposes no Thunderbolt security policy at all,
which means authorisation is delegated wholly to the OS (`boltd`). Consistent with the
follow-up capture seeing a bolt-managed device with `policy: iommu`.

**The profile's item-8 recommendation therefore splits:**
- *"Lower the security level"* - **impossible.** No such setting exists. Nothing to weaken.
- *"Or pre-authorise the dock"* - **already done.** The `T4801` is stored with `iommu` policy,
  so it should auto-connect without interaction.

**Correction to the profile's reasoning.** It argued the security level should be lowered
because "on a TUI-only machine there is no GUI to approve a new Thunderbolt device - an
authorisation prompt has nowhere to appear." That is true only of *GUI* approval flows.
`boltd` ships a CLI (`boltctl list`, `boltctl enroll <uuid>`) that is entirely TUI-native.
The no-GUI problem was never a reason to weaken the port.

**Design consequence for M3, carried forward:** since firmware provides no fallback, Thunderbolt
security lives entirely in the OS. `bolt`/`boltctl` **must** be in the cdl-linux base install,
and dock enrolment must be written into the docking runbook. If `boltd` is absent or its
database is not carried across the reinstall, the dock will not authorise and **there is no
firmware setting to rescue it**. This is now a hard dependency, not a convenience.

### Item 7 RESOLVED - no USB wake setting exists; the investigation moves to the OS

`Advanced -> USB Configuration` contains **exactly one entry**:

```
Legacy USB Support  [Enabled]
```

**No `USB Wake Support`, no `Wake on USB`, no XHC wake control anywhere in this firmware.**
Combined with item 8 (no `Wake From Thunderbolt Devices` either), there is no firmware-side
control over wake sources at all.

**Design consequence - the unsafe-shutdown investigation is now OS-only.** The profile named
spurious XHC wake as a candidate explanation for the **65-66 unsafe shutdowns** and proposed
disabling it in firmware. That option does not exist. The hypothesis is still live, but it can
only be tested and fixed from Linux via `/proc/acpi/wakeup`, and any fix must be made persistent
by cdl-linux (systemd unit or udev rule) because `/proc/acpi/wakeup` resets every boot.
Carry into `cdl-first-boot-and-environment` alongside the `boltd` dependency from item 8.

**`Legacy USB Support` - keep Enabled. Do not disable.**
It provides USB HID support in pre-boot environments. Disabling it buys a marginal reduction in
SMI-trap latency and pre-boot attack surface, but risks a **non-functional USB keyboard in GRUB
or a firmware rescue shell**. SS11 makes the live-USB rescue path load-bearing, and SS7.1 lists a
GRUB recovery menu as pending content. Trading a working rescue keyboard for marginal latency
is the wrong side of that bet. (Distinct from item 6: Fast Boot skipping USB *initialisation*
is a separate mechanism, still to check on the Boot tab.)

### Item 2 - Secure Boot state as found (RECORDED, NOTHING CHANGED)

`Security -> Secure Boot`:

```
System Mode   [Deployed]
Vendor Keys   [Active]
Secure Boot   [Enabled]
```

Confirms from the firmware side what the OS measured: Secure Boot enforcing, which is what
drives kernel lockdown `[integrity]`, which is what hides `disk` from `/sys/power/state` and
blocks D29.

**What each line means:**
- `System Mode [Deployed]` - the most restrictive of the four UEFI Secure Boot states
  (Setup / Audit / User / Deployed). PK is enrolled and key updates are restricted. Some
  firmware will not transition out of Deployed without an explicit physical-presence action.
- `Vendor Keys [Active]` - factory/Microsoft KEK and db are in place and unmodified. Nobody has
  enrolled custom keys, so a Machine Owner Key path is untouched and available later.
- `Secure Boot [Enabled]` - enforcing.

**Absences on this screen:** no `Secure Boot Mode` (Standard/Custom) selector, no `Key
Management` submenu, no `Restore Factory Keys`, no `Erase All Secure Boot Settings`. In Deployed
Mode this firmware appears to hide key management entirely.

**ANSWERED 2026-09-01: YES.** The `Secure Boot` field is selectable and offers both `Enabled`
and `Disabled`. Deployed Mode restricts *key management*, not enforcement toggling.
**Left at `Enabled`. Nothing changed**, per the profile's instruction that this is decided at
SS3.2 before M3, not flipped to close M0.

**Item 2 RESOLVED - and SS3.2 is a genuine decision, not a foregone conclusion.**

**Newly established: the decision is REVERSIBLE and TESTABLE.** Because `Vendor Keys [Active]`
and this firmware exposes no key-management menu at all, there is no way to erase or corrupt the
enrolled keys by accident. Toggling Secure Boot off disables enforcement while leaving the key
store intact, so toggling it back on restores the verified boot chain with no re-enrolment.

That changes how SS3.2 should be approached. The profile framed it as a decision to be reasoned
about; it can instead be **measured**:

1. Disable Secure Boot in firmware.
2. Boot and check `/sys/power/state` for `disk`, and `/sys/kernel/security/lockdown` for `none`.
3. Confirm the signed NVIDIA modules still load (they should - they become optional, not invalid).
4. Either keep it off and accept the D29 hibernation branch, or re-enable and take branch 3.

Cost of the experiment is one reboot each way, and it is fully reversible. **Do this at SS3.2
before M3 - not now.**


### TCG Storage Security (Opal SED) - recorded, unchanged. Not in the original plan.

`Security -> TCG Storage Security Configuration`, one submenu per drive (2 total). Each offers
exactly two options - `Set Admin Password` and `Set User Password` - and **both are unset on
both drives**.

**Reading: Opal is supported by the PM9A1 drives but has never been enabled or locked.** No
drive is in a locked or password-protected state, so nothing here will ambush the M3 install.

**Leave unset.** The design is committed to LUKS software encryption (D26: unattended reboot
parks at the passphrase prompt; the profile tunes `--sector-size 4096` on the *LUKS container*).
Opal is a separate, firmware-managed hardware-encryption mechanism the design does not use, and
setting an Opal password creates a second independent unlock secret outside the design.

**Hazard, recorded so nobody tries it later:** if an Opal password is set and then lost, recovery
requires a **PSID revert, which erases the drive**. There is no passphrase-recovery path.

### Item 3 RESOLVED - BIOS password: fields exist, both unset, LEFT UNSET

`Security` tab carries both `Administrator Password` and `User Password` (the firmware's own,
distinct from the per-drive Opal passwords). Both `Not Installed`.

**Recommendation: do not set one today.** Two reasons, one of them decisive:

1. **Decisive: we have a planned return trip to this menu.** SS3.2 requires coming back before M3
   to toggle Secure Boot and measure hibernation. Setting a firmware password now adds a
   lockout risk to the very next planned firmware task, for no benefit in the interim.
2. **Marginal security gain.** The data is protected by LUKS regardless (D26), so a BIOS password
   does not defend confidentiality. What it defends is boot-order and setup tampering - i.e. the
   T7 evil-maid class, which the profile records as **already out of scope**.

**But flag it as a SS3.2 companion decision.** If SS3.2 disables Secure Boot for hibernation, the
boot chain becomes unverified and the T1 residual ("boot tampering if the machine is recovered")
worsens. A firmware password is then cheap partial compensation - it stops casual boot-order
changes and re-entry to setup. Decide the two together, not separately.

**If one is ever set:** Clevo-class boards commonly store it outside CMOS, so a forgotten
password may not be clearable by removing the battery. Record it wherever the LUKS passphrase
is recorded, or do not set it.

### Item 10 RESOLVED - VT-d is not exposed in this firmware at all

`Advanced -> CPU Configuration` is confirmed complete: `Intel (VMX) Virtualization Technology`
and `Hyper-Threading`, nothing else. Combined with the stripped Chipset tab (no System Agent
submenu), **there is no VT-d / IOMMU toggle anywhere in this firmware.**

Benign absence, on the item-9 pattern: VT-d cannot be switched off by accident. But its actual
state is now genuinely unknown from the firmware side, and the profile's claim that it is
enabled rests on boltd's stored `policy: iommu` - strong but indirect. **Settle it by direct
measurement post-reboot (item 11).** If `/sys/class/iommu/` turns out empty, the profile's
Thunderbolt DMA-protection reasoning needs revisiting.

### Menu map - `Boot` tab

```
Bootup NumLock State   [Off]
Boot Option Priorities
  Boot Option #1       [ubuntu (SAMSUNG MZV...)]
Fast Boot              [Enabled]     <- THE ONE CHANGE
```

- `Bootup NumLock State [Off]` - **correct, leave it.** Not cosmetic on this machine: D26 has
  every unattended reboot parking at the LUKS passphrase prompt. On a laptop with an embedded
  numeric keypad, NumLock On can turn passphrase letters into digits. Off is the safe state.
- Only one boot entry exists, and no CSM/Legacy selector is present - the machine is UEFI-only,
  consistent with Secure Boot enforcing.

---

## Tooling added for item 11

`scripts/verify-firmware.sh` — captures the post-firmware state on the Tensorbook itself,
redaction-checks it, and pushes it, because the operator drives firmware from the laptop and
cannot paste output into a session running on another machine. Follows the same
`as_user` / `diagnosis_leaks` / hard-redaction-gate pattern as `capture-followup.sh`.

### OPEN — unexplained single test failure, not yet root-caused

On the FIRST `tests/run-all.sh` after adding `verify-firmware.sh`, the summary reported
`failures: 1`, attributed to `test-capture-safety.sh`. The same suite has since run **four
consecutive times clean** (`failures: 0`), and `test-capture-safety.sh` passes in isolation.
The specific failing check name was lost to output truncation on that first run.

Ruled out so far:
- **Not the timestamp race.** `tests/test-capture-safety.sh:56` already sleeps 1s between the
  two capture runs, so "two runs produce two distinct captures" cannot collide.
- **Not a lint failure.** All 6 shell files were shellcheck-clean *before* that run.

**Not diagnosed. Do not treat as fixed.** A test that fails once and then passes is either
order-dependent, state-dependent, or genuinely racy, and all three matter for a suite that
gates a push. Reproduce by running `tests/run-all.sh` from a clean checkout and capturing the
FULL output, not a tail.

This does not block the firmware work — nothing in it touches the captures.
