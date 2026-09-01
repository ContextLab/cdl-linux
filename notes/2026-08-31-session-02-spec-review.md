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

- ✅ Design spec at **revision 2.2, frozen**
- ✅ `scripts/capture-hardware.sh` — lints clean, tested on macOS (degradation path), **not yet run
  on the Tensorbook**. This is milestone M0 and it is one-way; it should happen before more
  architecture work.
- ⬜ Four component specs, commissioned in §7 but **not written**:
  `cdl-install-and-packaging`, `cdl-security-and-recovery`, `cdl-agent-lifecycle`,
  `cdl-first-boot-and-environment`
- ⬜ Three risk spikes (§9), none started

## Resume here

1. Wait for the user's review of revision 2 before writing component specs — the four briefs in §7
   are the commissioning input and may change.
2. Run `scripts/capture-hardware.sh` on the Tensorbook (needs sudo; output is gitignored).
3. §7.1 lists content that left revision 1 with **no written destination yet** — provider env-var
   spellings, llama-swap rationale, clustrix verdict, restic `--exclude-caches`/`CACHEDIR.TAG`,
   GRUB recovery menu. Source is in `notes/research/`. Each receiving spec must reconcile against it.
4. §16.3 spend controls is still **unowned** (DR12 in the traceability matrix, no component). Needs a
   product decision: v1 feature, documented gap, or explicit non-goal.
