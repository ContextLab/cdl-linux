# Session 05 task tracker (2026-09-02)

`TodoWrite` is not available in this session, so this file is the task list. **Keep it
updated as work happens**, not at the end: it is what survives a context loss.

Status key: `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked · `[-]` dropped

## Now

- [~] **V1. Run the VM install end to end.** `scripts/vm/install.sh`. The autoinstall's
  `early-commands` path (md → LUKS → btrfs + three subvolumes, handed to curtin as
  `preserve: true`) is **UNVERIFIED** and this is what settles it. Expect failure on the
  first attempt; curtin's `preserve: true` handling for a pre-built stack is the risky part.
- [ ] **V2. Boot it and answer the LUKS prompt.** `scripts/vm/boot.py`. Tests the unlock
  path the real machine will use.
- [ ] **V3. Run the verifier.** `scripts/vm/verify.sh`. It now asserts `@`, `@home`,
  `@models` and will FAIL until the layout is right, which is the point.
- [ ] **B1. Test the backup path on the VM.** `restic` → `rclone` → HF bucket, from inside
  the guest rather than from the Mac. Then restore and diff. S1 proved the transport from
  macOS; this proves it from the machine that will actually run it.
- [ ] **B2. Test the second copy.** §10.2's `rclone copy` pull from a different machine,
  since that is the only thing standing between a compromised token and total loss.

## Then: remaining audit items

Source: `notes/reviews/2026-09-02-cdl-box-deep-audit.md`

- [ ] **A1. Console interface section (§9).** Authenticated `cdl` home screen on tty1,
  recovery VT, plain-shell escape. **Do not launch zellij from `.profile`** — it would
  capture `scp`, `rsync`, git-over-SSH and recovery sessions. Local inference at the console
  is a stated use case and should be a first-class action.
- [ ] **A2. Rewrite §3** from "provisioning modules" to the one-script install model.
- [ ] **A3. Local vs SSH workspaces separate by default**, with an explicit "attach shared"
  that shows connected clients.
- [ ] **A4. Auth split**: strong Unix password for console and sudo; SSH key-only, no root
  login, an allow-group, and `sshd -T` tests of the effective config.
- [ ] **A5. Session logging sensitivity.** Transcripts can capture code, prompts and tokens.
  Define mode, retention, and whether they are backed up.
- [ ] **A6. Thermal: a separate GPU policy.** §2.3 sets CPU package thresholds only.
- [ ] **A7. Backup second copy operational detail**: retention, capacity, encryption,
  alerting, ownership, restore-test cadence.
- [ ] **A8. Rollback**: `/boot` and root-subvolume consistency across kernel changes.
- [ ] **A9. Network behaviour** before Tailscale enrolment, and during failure or
  reauthentication. Tailnet reachability is not authorisation to read prompts or dashboard
  data.
- [ ] **A10. Do not claim full verified boot.** Ubuntu's chain validates shim, GRUB, kernel
  and modules; the initrd is not validated, so the claim has to be narrower.
- [ ] **A11. Model capacity stated testably** rather than "7B-class".
- [ ] **A12. Branding stages**, if wanted: GRUB menu, Plymouth, `/etc/issue`, console login,
  shell. Artwork and config only, never replacing signed executables.
- [ ] **A13. Regenerate the whitepaper + PDF** from the corrected spec. Its central argument
  (headless, not a distribution, SSH-primary) is now partly obsolete.

## Done this session

- [x] GPU lock protocol replaced. Draft 2's shared-lock-for-lifetime plus exclusive-for-
  training could never let training start under `flock`. Now exclusive workload: training
  stops the servers, takes the GPU, restarts them via `ExecStopPost`. User confirmed serving
  need not continue through training.
- [x] Verifier now checks the three subvolumes. It previously checked only that `/` was
  btrfs, so it would have passed the flat layout the autoinstall actually produced.
- [x] Autoinstall rebuilt to create the subvolumes in `early-commands`. **Unverified.**
- [x] Product definition rewritten around the Lambda Stack model (one script, vanilla
  Ubuntu), public repo, no maintenance promise, explicitly not a distribution.
- [x] Console-first replaces headless.
- [x] Cross-reference defects from the audit: S3 and B0/B7 pointed at §11 (are in §12); S1
  still listed open after being answered; §8.3 described write actions after §8.2 declared
  the dashboard read-only; CLI refresh pointed at B4 when acceptance is B6; stale NAS prose.

## Decisions taken this session

| # | Decision |
|-|-|
| Public repo, personal scope | Shareable, contributions welcome, **no maintenance or testing promise beyond one person's use**. This is why the distribution apparatus is not built. |
| Install model | One script on vanilla Ubuntu Server 26.04, modelled on Lambda Stack. No custom ISO, no signed APT repo, no SBOM, no trademark review. |
| Console-first | Not headless. No graphical stack, but a usable authenticated text console; local inference at the console is a use case. |
| GPU | Exclusive workload. Training stops inference, runs, restarts it. Serving need not continue through training. |
| Storage | Striped (user's call, against recommendation). md0 RAID0 → LUKS → btrfs with `@`, `@home`, `@models`. |
| Unlock | Passphrase only, typed at the machine. No remote unlock, no TPM. |
