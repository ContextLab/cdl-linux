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

**M0 is PARTIALLY COMPLETE.** The capture ran as root on the Tensorbook 2026-09-01, was transferred
by email, and was decoded locally and verified byte-identical (sha256) against the user's own copy.

- ✅ Design spec at **revision 2.3, frozen**
- ✅ **Initial capture run on the Tensorbook**; redacted profile committed as
  `notes/hardware/tensorbook-profile.md`. Raw capture is gitignored.
- ✅ **R18/D35/P8 recorded** — docking station and external monitor. Independently reinforces D34.
  The dock follow-up is deferred to M2 as §16.6, because one docking station is shared with the Mac.
- 🛑 **D29 is blocked** under the current Secure Boot posture: `/sys/power/state` reads `freeze mem`
  with no `disk`. Indicated cause is kernel lockdown; not yet directly confirmed. §3.2 branch.
- ⬜ **M0 still open on:** SMART health and endurance, direct lockdown-state confirmation,
  NVMe-native controller detail, firmware answers (VMD/RST, graphics mode, whether Secure Boot can
  be disabled, BIOS password), and the fan-control interface inventory.
  **Do not mark M0 complete until those are recorded.**
- ⬜ Four component specs, commissioned in §7 but **not written**
- ⬜ Three risk spikes (§9), none started

### What M0 has already settled

| Question | Answer |
|-|-|
| Both drives NVMe? | **Yes** — two identical Samsung `MZVL21T0HCLR-00B00`. Mixed-media concern retired; the other RAID0 risks are not |
| RAM | **64 GB** (2×32 DDR4-3200), two slots free → 128 GB possible, which is a swap-sizing decision |
| Console/display path | Internal panel `eDP-1` on the **Intel iGPU** → better rescue behaviour. External outputs split across both GPUs |
| Wifi | Intel AX210 on in-kernel `iwlwifi` → **no firmware package needed** |
| GPU | RTX 3080 Laptop, **16 GB VRAM** → sets the local-model ceiling |
| Hibernation | **Unavailable** as configured. Blocks D29, not M1 or M2 |

## Resume here

1. **Finish M0.** On the Tensorbook, two commands: `git pull` then
   `sudo ./scripts/capture-followup.sh`. Needs no dock (the dock test is off by default per
   §16.6), installs `smartmontools` and `nvme-cli`, answers drive health and the lockdown
   question, and commits+pushes the redaction-checked diagnosis file automatically — so
   nothing has to be copied between machines. The push is blocked if the redaction scan
   finds any identifier.
   Then reboot into firmware and record VMD/RST vs AHCI, graphics mode, whether Secure Boot can be
   disabled, and BIOS password state. Update the profile with all of it plus a final go/no-go table.
2. **Write `cdl-agent-lifecycle`** — the correct first component spec; needs no hardware facts.
   First vertical slice only: one local interactive agent → PTY allocated → registry entry → attach/
   detach → terminal destroyed → reattach → exit status and logs retained → no prompt replay.
   Settle the state machine, SQLite ownership, service/PTY relationship, crash reconciliation, and
   the minimum sandbox boundary before any implementation.
3. **Write the M1 slice** of `cdl-first-boot-and-environment`: authenticated tty login, minimal sway,
   swaylock, kitty, zellij, croft, fonts, keybindings, Emacs plus one LLM integration, provider
   enrollment and bounded `cdl doctor`, offline startup, non-JS browser, tty2 recovery. Docking is
   M2 and must not expand spike 1 beyond confirming sway's multi-output support exists.
4. **Run spikes 1 and 2.** Spike 1 starts from tty login → sway → kitty → zellij → swaylock; test
   lock crash, compositor crash, idle, lid, tty2 recovery. Spike 2 follows the lifecycle slice.
5. **Probe the NAS** before writing the backup spec: container support → rest-server → SSH/SFTP →
   SMB fallback, in that order. That decides whether the append-only design is real (§16.3).
6. **Secure Boot decision has a deadline, not urgency.** M1 does not need it. Before M3: confirm
   lockdown state; test whether disabling Secure Boot exposes `disk`; confirm NVIDIA modules still
   load; judge the security trade-off; then record the §3.2 branch. Swap sizing is due at the same
   point — 136 GiB is defensible only if a 128 GB RAM upgrade is genuinely plausible, otherwise
   72 GiB suffices for the measured hardware.
7. §7.1 lists content that left revision 1 with **no written destination yet** — provider env-var
   spellings, llama-swap rationale, clustrix verdict, restic `--exclude-caches`/`CACHEDIR.TAG`,
   GRUB recovery menu. Source is in `notes/research/`. Each receiving spec must reconcile against it.
