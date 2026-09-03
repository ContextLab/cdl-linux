# Session 05 task tracker (2026-09-02)

`TodoWrite` is not available in this session, so this file is the task list. **Keep it
updated as work happens**, not at the end: it is what survives a context loss.

Status key: `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked · `[-]` dropped

## Now

- [~] **V1. Run the VM install end to end** (`scripts/vm/install.sh`). Settles whether the
  autoinstall's `early-commands` path works: md → LUKS → btrfs with three subvolumes, handed
  to curtin as `preserve: true`. Curtin's handling of a pre-built stack is the risky part.
  - Attempt 1 failed at `hdiutil attach`: macOS cannot mount an Ubuntu hybrid ISO at all
    ("no mountable file systems"). Fixed by extracting `casper/vmlinuz` and `casper/initrd`
    with `bsdtar`, which reads ISO9660 directly.
  - Attempt 2 stopped at subiquity's serial-mode prompt: the autoinstall never took effect.
    Cause was the kernel cmdline `ds=nocloud-net;s=/cdrom/`, which points cloud-init at the
    *install ISO* (no `user-data` on it) and so stopped it discovering the CIDATA-labelled
    seed volume that has one. Fixed by passing `autoinstall` alone and letting NoCloud find
    the seed by label.
  - Attempt 3: `early-commands` ran the whole storage stack -- `mdadm --create`,
    `cryptsetup luksFormat`, `cryptsetup open`, `mkfs.btrfs`, and all three subvolumes
    (`@`, `@home`, `@models`), and subiquity applied the config through every stage --
    then **curtin crashed**: `'NoneType' object has no attribute 'size'`. Handing curtin a
    pre-built stack via `preserve: true` does not work.
  - **Second obstacle, from Canonical's own docs**: subiquity silently drops
    `storage:config:mount:options`, which is the field a `subvol=/@` mount needs. So even a
    working `preserve` path would have mounted the top level, silently.
  - Attempt 4 (running): let curtin build the stack the way it supports, and ask whether it
    creates subvolumes on its own. Ubuntu's guided btrfs installs use `@`/`@home`, so the
    capability exists; whether autoinstall reaches it is the question.
  - **Recorded in the spec as §2.1.2** with four options and none chosen, because the
    measurement is not finished. This is the spike doing its job: the layout cannot be
    assumed, and draft 2 wrote it down as though declaring it made it so.
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

- [x] **A1. Console interface section (§9).** Boot chain, no autologin, an explicit `cdl`
  launcher never invoked from `.profile` (it would capture `scp`, `rsync`, git-over-SSH and
  recovery sessions), tty2 as an ordinary recovery getty, and local inference as a
  first-class action on the home screen.
- [x] **A2. Rewrite §3** to the one-script install model. Adds the properties that matter
  (idempotent, vanilla Ubuntu only, refuses rather than guesses, per-module runnable, does
  not touch storage) and states that uninstall is unsupported rather than half-working.
- [x] **A3. Local vs SSH workspaces** separate by default, `--shared` lists connected
  clients first. In §9.3.
- [x] **A4. Auth split.** §7: explicit sshd directives, `AllowGroups cdl`, and B1a asserts
  the *effective* config via `sshd -T` rather than the file, since Include/Match can differ.
- [x] **A5. Session logging sensitivity.** §9.4: mode 0600, excluded from backup by default,
  rotated on §11.1's schedule, zellij resurrection disabled.
- [x] **A6. GPU thermal policy** added alongside the CPU one: power cap via `nvidia-smi -pl`,
  admission refusal at 87 °C, and never killing a running job on temperature.
- [x] **A7. Backup second copy operations** in §10.2: where, daily, 30 pulls retained,
  capacity checked, already encrypted (it is a restic repo), alerting, one named owner, and
  a quarterly restore **from the second copy** since that is the one nobody exercises.
- [x] **A8. Rollback consistency.** §11.4: `/boot` is a separate ext4 partition and is in no
  btrfs snapshot, so rolling `@` back past a kernel upgrade restores old `/lib/modules`
  against a new `/boot` -- no md, no dm-crypt, no root. `/boot` is now archived into each
  snapshot and restored with it. New test B7a exercises it across a kernel change.
- [x] **A9. Network states** in §7.1: before enrolment (sshd also on LAN, console does the
  enrolment), during failure (LAN works, tailnet does not, and `logged out` looks identical
  to `down` from elsewhere), key expiry disabled for this node. §7.2 states that tailnet
  reachability is not authorisation: the dashboard checks `tailscale whois`, the model
  endpoint cannot, so sharing the tailnet shares the endpoint.
- [x] **A10. Verified-boot claim narrowed.** New §2.1.1: signed kernel and modules, *not*
  verified boot, because the initrd is unvalidated and `/boot` is unencrypted by necessity.
- [x] **A11. Model capacity** given as a table of workloads against 16 GB, marked as
  estimates from parameter counts rather than measurements, with B4 to replace them.
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
