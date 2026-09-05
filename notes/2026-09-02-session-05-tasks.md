# Session 05 task tracker (2026-09-02)

`TodoWrite` is not available in this session, so this file is the task list. **Keep it
updated as work happens**, not at the end: it is what survives a context loss.

Status key: `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked · `[-]` dropped

## Now

Working from the design review recaptured at `de5407f0-a720-4a23-940f-c20047cad9fc:62`
(2026-09-04, 12,508 chars). Its six blockers and the milestone restructure are done; V4
itself is the remaining open item.

- [x] **Blocker 1. Migration correctness.** Traversal is find-based (no shell glob), and
  `/srv/models` contents move rather than being shadowed. **The review's named symptom does
  not occur** -- `.ssh/authorized_keys` and `.profile` sit inside `/home/<user>`, which the
  old `/home/*` glob did match. The real gaps were a hidden entry *directly* in `/home` and
  `..`-prefixed names. **The bigger defect was the primitive:** `mv` across a btrfs
  subvolume hits EXDEV and degrades to copy+unlink, breaking hardlinks. `@` is now a
  `btrfs subvolume snapshot`; the two splits use `cp -a --reflink=auto`.
- [x] **Blocker 2. Interruption safety.** `install/installer/migrate-btrfs-root.sh`: stages
  recorded to `.cdl-migration-state` on the top-level subvolume, EXIT trap, refuses on a
  live system, exits 0 if already migrated, distinguishes empty leftovers from a populated
  `@`, validates everything **before** touching the bootloader.
- [x] **Blocker 3. curtin ambiguity.** Everything uses `chroot /target`.
- [x] **Blocker 4. Autoinstall hygiene.** Duplicate `shutdown` removed; strict duplicate-key
  validation added and proven against the commit that shipped the dupe; production profile
  split to `install/autoinstall/tensorbook.yaml` with placeholders only, matched by disk
  identity with a count guard.
- [x] **Blocker 5. Install framework.** `install.sh` + `install/lib.sh` +
  `00-preflight.sh` + `10-base.sh`, 19 assertions.
- [x] **Blocker 6. Normative text.** §2.1 condensed to one contract; experiments moved to
  `notes/2026-09-03-storage-experiments.md`; subsections reordered; §12 restructured.
- [x] **Test suite split.** `run-all.sh` (fast, 24 files linted, 5 suites), `run-vm.sh`,
  `run-destructive.sh`. Full failing-suite output preserved to a named file.
- [x] **V4. The migration works, and is verified on three consecutive installs.**
  Runs 7, 8 and 9 each: migration exit 0 through all eight stages, disks boot, LUKS unlocks
  at the console, SSH comes up, `verify.sh` **21 passed / 0 failed**, fixture
  **30 passed / 0 failed**. Every hidden file, the hidden entry directly in `/home`, the
  `..`-prefixed name, the hardlink pair, all three symlinks, the awkward filename, both
  owners and the model weights survived with content, mode, uid, gid and link count intact.
  - Guards exercised on a live machine, not reasoned about: re-run against an
    already-migrated target exits 0; a non-mountpoint is refused; a target on the same
    device but not on `@` is refused by the partial-migration guard with two recovery
    routes, leaving all three subvolumes untouched.
- [x] **B2. Second backup copy: DONE 2026-09-04.** `scripts/backup/pull-second-copy.sh`,
  15 assertions against the real bucket. Survives a wipe, an empty re-pull, visible
  corruption, a same-size/same-mtime look-alike, and silent local rot. Three measured
  findings: `--checksum` is *worse* on this gateway (no hash reads as "same"), `--immutable`
  is beaten by an attacker who preserves mtime, and restic names every file by the SHA-256
  of its content so the puller verifies cryptographically with no password.
- [!] **B0. Back up the Tensorbook that exists today.** Blocked: the machine is not
  reachable from here. Remaining: first real backup, restore on another machine, one
  restore from the second copy, and the owner's name in `notes/`.

## Open: subiquity cannot copy its own logs into the target

Every install ends with subiquity's `cp -a /var/log/cloud-init.log /var/log/installer`
failing (exit 1), which makes the run report "An error occurred" after everything has
actually worked. `/var/log/installer/` on the installed machine holds only
`casper-md5check.json` and `media-info`; the subiquity and cloud-init logs are absent.

**Not established whether this is caused by our changes.** It surfaced only after the
`umount --recursive /target` failure was fixed, so it may have been there all along, masked
by the earlier error. The plausible link is that the migration remounts `/target`, which is
exactly the stale-bookkeeping condition earlier drafts *asserted* breaks `curtin in-target`
-- so this may be the first real evidence for a claim that was previously written down
without any.

**Impact is bounded and does not block V4:** what is lost is installer diagnostics on the
installed machine. Our own evidence is written independently and is present --
`/var/log/cdl/` holds 12 files including `migration-run.log` with the full command trace,
`migration.txt`, the fixture manifest, and the recorded `lsblk`/`fstab`/`crypttab`/`mdstat`.

### What the VM runs have cost, and bought

| Run | Outcome |
|-|-|
| 1 | Inline migration, exit 2. Cause found by reading, not from the log: `awk` read an fstab path under a directory the script had just unmounted. Installer sat at `Press enter to start a shell` for six hours |
| 2 | `write_files` **does not reach subiquity's late-commands environment**. Every `test -x` guard fired and the run stopped *before* the fixture or the migration. The guards are why this was a finding and not a half-migrated filesystem |
| 3 | `/run` is mounted **noexec** in the installer, so a decoded, chmod'd script exits 126. Scripts are handed to `bash` instead |
| 4 | Migration ran, exited 1, and its log was unreachable -- copied to `/target`, which the script unmounts, and `cat` went to a journal the harness cannot read. Log now goes to `/dev/console`, plus xtrace with line numbers |
| 5 | The log paid for itself: `mount '#' /target/boot`. curtin writes fstab comments like `# /boot was on /dev/vda2`, where `$1` is `#` and `$2` is `/boot`, so an awk rule keyed on `$2` alone matched a comment |
| 6 | Migration **succeeded**; disks boot and verify 21/21. Three harness defects found: verifier's `sudo` had no password so `btrfs subvolume list` returned empty and read as "absent"; `boot.py` reported SSH up after its own qemu failed to take the image lock, probing another VM through the same port; the fixture had overwritten the real `authorized_keys` |
| 7, 8 | Clean installs, 21/21 and 30/30. Ended with subiquity's `umount --recursive /target` failing: late-commands left `/target/sys` mounted **inside itself**, because one teardown ran a single `umount -R ... \|\| true` and the next block rbind'd over what was left |
| 9 | Mounts clean. A different, probably pre-existing subiquity failure surfaced behind it (see above) |

**A correction that stands:** the spec claimed `curtin in-target` fails after a manual
remount because of stale mount bookkeeping. That was asserted, not measured. Run 1 replaced
curtin with an explicit chroot and still exited 2 -- but from `awk`, before reaching the
chroot. The curtin explanation remains untested and is now recorded as open.

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
- [x] **A12. Branding**, §9.6. Six stages with their mechanisms and failure modes. Hard rule:
  artwork and config only, never a signed executable, since replacing shim/GRUB/kernel means
  disabling Secure Boot or enrolling our own key. Every branded stage keeps an unbranded
  escape (GRUB recovery entry, Plymouth Escape, tty2 plain getty), because branding that
  removes a diagnostic is a cost paid at the worst moment.
- [x] **Fonts, palette, logo** (user request, 2026-09-03). Turned out to be D3/T1 from the
  original brainstorming, dropped silently by the console-first decision. §9.6 restores it
  with `kmscon` (in the Ubuntu archive; freetype/pango so it can shape, which the kernel VT
  cannot); tty2 stays a kernel VT so recovery does not depend on it. §9.7 defines one palette
  in one file feeding kmscon, `setvtrgb`, shell/tool themes and the dashboard CSS, with
  contrast checked in the suite. Logo centred in Plymouth. Font is `fonts-firacode` plus
  Symbols Nerd Font fallback, since the patched Nerd build is not packaged.
- [~] **A13. Whitepaper rewritten** for console-first, the install-script model, kmscon and
  the measured findings. PDF still to render.
- [ ] **A13b. Render the PDF** from the corrected spec. Its central argument
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

## CLOSED: the intermittent suite failure, cause found

**Reproduced on 2026-09-03 and fixed.** It was a race in
`tests/test-capture-safety.sh`, not in any product code.

The test built a collision path from `date`, wrote a file there, and then ran
`capture-hardware.sh`, which computes *its own* timestamp. If the clock ticked between the
two, the script picked a different filename, wrote successfully and exited 0. The exit-code
assertion then failed.

**The worse half:** the preceding assertion -- that the existing file was not clobbered --
**passed vacuously** in exactly that case, because nothing had tried to touch the file it
was checking. A green line was reported for a case the run never exercised.

**Measured rate:** 1 in 300 attempts with only a `date` call between the two timestamps
(`/tmp/racetest`, 2026-09-03). The real test launches a script there, so the window is
wider. That is consistent with two failures in many hundreds of suite runs.

**The fix** starts each attempt just after a second boundary, then confirms the collision
actually occurred by checking that no new capture file appeared, and retries up to five
times if the clock won. If it never collides, the suite now **fails loudly as untested**
rather than asserting anything. 12 consecutive runs clean.

**What made this findable at last** was `run-all.sh` preserving the full output of a
failing suite to a named file. Both previous occurrences were lost because the caller had
piped the runner to `tail -3`, so only the count survived. The fix that mattered was to
the evidence, not to the test.

## Decisions taken this session

| # | Decision |
|-|-|
| Public repo, personal scope | Shareable, contributions welcome, **no maintenance or testing promise beyond one person's use**. This is why the distribution apparatus is not built. |
| Install model | One script on vanilla Ubuntu Server 26.04, modelled on Lambda Stack. No custom ISO, no signed APT repo, no SBOM, no trademark review. |
| Console-first | Not headless. No graphical stack, but a usable authenticated text console; local inference at the console is a use case. |
| GPU | Exclusive workload. Training stops inference, runs, restarts it. Serving need not continue through training. |
| Storage | Striped (user's call, against recommendation). md0 RAID0 → LUKS → btrfs with `@`, `@home`, `@models`. |
| Unlock | Passphrase only, typed at the machine. No remote unlock, no TPM. |
