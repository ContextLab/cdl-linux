# cdl-linux — Session 02 (2026-08-31): spec review response

## What happened

User delivered a detailed review of revision 1 of the design spec. Verdict: strong concept, well
researched, **not implementation-ready** — "closer to an architectural thesis than a buildable system
specification." Ten critical findings, seven recommended next steps.

Diagnosis after reading the spec, the 653-line decision log, and both research digests: **most of
what the review calls "missing" was researched in round 1/2 and never promoted into the spec.** The
round-2 digest already contained the entire remote-access design; the round-1 completeness critic
already named, by name, nearly every requirement the review's finding #8 lists. So the fix was
promotion and precision, not new research.

Output: revision 2 of the design spec (commit `dcc7462`), restructured as a product/architecture
overview, plus `scripts/capture-hardware.sh`.

## Decisions made this session (D26–D31, user-confirmed)

| # | Decision |
|-|-|
| D26 | **No remote LUKS unlock.** Unattended reboot parks at the passphrase prompt. No dropbear, no tailscale-initramfs, nothing sensitive on unencrypted `/boot`. |
| D27 | **Backup = QNAP/TrueNAS**, which has SSH + containers. restic → `rest-server --append-only`. Fallbacks: SFTP, then rclone SMB remote. Capability probe first. |
| D28 | **Working shape: 5–10 API agents + 1–2 local + 2–4 on the GPU host** (~16 units, three locations). Promotes port registry, per-agent slices, oomd override and `cdl status` to load-bearing. |
| D29 | **Hibernation is a launch requirement**, hardware-validated including failed-resume recovery. |
| D30 | **Full job layer in v1** (submit/list/status/logs/cancel/artifacts/reconcile). Slurm backend designed but ships disabled until its auth is testable. |
| D31 | **Acceptance = fresh install onto a fully wiped machine.** Makes hand-edited config a defect in M2, because M4 replays onto bare metal. |

## Verified this session (MEASURED — commands run, output quoted)

| Claim | Result | How |
|-|-|-|
| cage session-lock support | **None.** No `session_lock.c`; no `session_lock`/`layer_shell` matches in 716-line `cage.c`; upstream issue **#264 open** | `gh api` on repo tree, contents, issue search |
| cage client model | "Cage can run multiple applications, but only a single one is visible at any point in time" | `cage.1.scd` verbatim |
| `rest-server --append-only` | Real. "allows creation of new backups but prevents deletion and modification of existing backups" | rest-server README verbatim |
| rclone SMB backend | Exists (`backend/smb/smb.go`) | `gh api` contents |

**Consequence:** swaylock under cage is ruled out on evidence, not suspicion. Autologin is no longer
committed. Threat T2 (powered-on unattended machine with live credentials) is the open gap.

## Where the review was slightly wrong

The review said the spec had "gone stale" on Slurm because the notes say auth was resolved. Actually
the **notes heading** is stale, not the spec. Line 453 says "AUTH RESOLVED"; line ~487, later in the
same file, says "still blocked, diagnosed" — server-side rejection of an offered key. What was
resolved is password auth removing Kerberos/GSSAPI from v1. Added a supersession marker at line 455.

## Review rounds 2 and 3 (same session)

Two further review rounds produced revision 2.1 (`3952312`) and revision 2.2 (`15b24ca`).
**The overview is now frozen** — amend only on new evidence from a spike, a hardware capture, or a
component spec, not to refine wording.

Decisions added: D32 release tiers (alpha M1–M2 / RC M3–M4 / product v1), D33 spend controls owned by
`cdl-agent-lifecycle`, D34 a compositor with a real session-lock protocol (minimal sway) as the T2
default. §3.2 records D29's failure branch, which matters: a launch requirement with no permitted
failure is how kernel workarounds accumulate.

Corrections worth remembering because they were inherited errors, not typos:
- **HF Jobs entitlement ≠ funding.** The `academia` plan and `jobs` scope were cited as proof of
  availability; research separately measured **402 Payment Required** on manual runs.
- **Worktrees are collision isolation, not a security boundary.** They were listed as a control
  against a malicious agent. The boundary is bubblewrap plus network policy.
- **`/etc` does not make a file world-readable.** Mode and ownership apply there too. The real
  rationale for user-scoped credentials is the single-user threat model and the backup path.
- **The hardware ignore rule was fail-open**, and M0's required committed profile was impossible.
  Now default-deny with explicit allows.

## State of the work

**M0 is complete except the firmware gate.** The initial capture ran 2026-08-31 and the follow-up
ran 2026-09-01, publishing itself to the repo automatically (commit `1b7fb86`).

- ✅ Design spec at **revision 2.3, frozen**
- ✅ **Capture + follow-up both run on the Tensorbook.** Redacted profile committed as
  `notes/hardware/tensorbook-profile.md`; the diagnosis as
  `notes/hardware/tensorbook-20260901T124921Z-diagnosis.md`. Raw captures stay gitignored.
- ✅ **R18/D35/P8 recorded** — docking station and external monitor. Dock identified as a **USB4
  "T4801"**, already authorized with `iommu` policy. Which GPU drives it is deferred to M2 (§16.6).
- 🛑 **D29 is blocked, and the cause is now CONFIRMED** rather than inferred: lockdown reads
  `none [integrity] confidentiality`, with `nohibernate` unset. Secure Boot → lockdown →
  hibernation blocked. §3.2 is a live decision due before M3.
- ⬜ **Firmware gate still open** — four observations needing a reboot into setup.
- ⬜ Four component specs, commissioned in §7 but **not written**
- ⬜ Three risk spikes (§9), none started

### What M0 settled

| Question | Answer |
|-|-|
| Both drives NVMe? | **Yes** — two identical Samsung `MZVL21T0HCLR-00B00`. Mixed-media concern retired; other RAID0 risks stand |
| Drive health | **Both PASSED.** 0 media errors, 100% spare, 2% and 0% endurance used. Striping this pair is defensible |
| Sector geometry | **One LBA format, 512 B, in use.** No 4K format exists. Not 512e, not native-4K-presenting-512 |
| RAM | **64 GB** (2×32 DDR4-3200), two slots free → swap-sizing decision |
| Console/display | Internal panel `eDP-1` on the **Intel iGPU** → better rescue behaviour |
| Wifi | Intel AX210 on in-kernel `iwlwifi` → **no firmware package needed** |
| GPU | RTX 3080 Laptop, **16 GB VRAM** |
| Hibernation | **Unavailable**, cause confirmed as Secure Boot lockdown |
| Fan control | **None exists** — 0 fan inputs, 0 writable PWM. 29 cooling devices = throttling only |

### Anomalies recorded, not yet explained

- **Unsafe shutdowns: 65 and 66** against 255 and 206 power-on hours — about one unclean shutdown
  per 3–4 hours of uptime. Matters because RAID0 has no redundancy for a torn write and btrfs must
  survive them. Explain before M3 commits to the layout.
- **`nvme0n1`: 48.0 TB written in 255 hours** (~52 MB/s sustained, ~47 drive-writes) versus 5.5 TB
  on the system drive. The two drives are not equally worn. Endurance still 2%, so context rather
  than a fault.
- **NVIDIA connectors absent** from the follow-up run though the first capture saw them — dGPU
  likely runtime-suspended. Re-check while docked; bears on §16.6.

## Resume here

1. **Close the firmware gate.** Reboot into setup and record: Intel VMD/RST vs AHCI; graphics mode;
   **whether Secure Boot can be disabled** (now load-bearing for D29); BIOS password state.
2. **Write `cdl-agent-lifecycle`** — the correct first component spec; needs no hardware facts.
   First vertical slice only: one local interactive agent → PTY allocated → registry entry →
   attach/detach → terminal destroyed → reattach → exit status and logs retained → no prompt replay.
   Settle the state machine, SQLite ownership, service/PTY relationship, crash reconciliation, and
   the minimum sandbox boundary before any implementation.
3. **Write the M1 slice** of `cdl-first-boot-and-environment`: authenticated tty login, minimal sway,
   swaylock, kitty, zellij, croft, fonts, keybindings, Emacs plus one LLM integration, provider
   enrollment and bounded `cdl doctor`, offline startup, non-JS browser, tty2 recovery. Docking is
   M2 and must not expand spike 1 beyond confirming sway's multi-output support exists.
4. **Run spikes 1 and 2.** Spike 1 starts from tty login → sway → kitty → zellij → swaylock; test
   lock crash, compositor crash, idle, lid, tty2 recovery. Spike 2 follows the lifecycle slice.
5. **Probe the NAS** before writing the backup spec: container support → rest-server → SSH/SFTP →
   SMB fallback, in that order (§16.3).
6. **Two decisions due before M3, not now.** The §3.2 Secure Boot ↔ hibernation branch, and swap
   sizing — 136 GiB only if a 128 GB RAM upgrade is genuinely plausible, else 72 GiB.
7. §7.1 lists content that left revision 1 with **no written destination yet** — provider env-var
   spellings, llama-swap rationale, clustrix verdict, restic `--exclude-caches`/`CACHEDIR.TAG`,
   GRUB recovery menu. Source is in `notes/research/`. Each receiving spec must reconcile against it.

## Tooling built this session

- `scripts/capture-hardware.sh` — 42 read-only captures; timestamped, no-clobber output.
- `scripts/capture-followup.sh` — installs tools, re-captures, diagnoses, redaction-checks, and
  auto-commits/pushes the safe diagnosis. Git runs as `$SUDO_USER`, not root.
- `tests/run-all.sh`, `tests/test-dock-diff.sh`, `tests/test-capture-safety.sh` — 37 checks.
