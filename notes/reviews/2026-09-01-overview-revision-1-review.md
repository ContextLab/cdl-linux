# Overview spec — revision 1 review (verbatim)

**Recovered 2026-09-02 from the prompt history** via `surfer search "architectural thesis"`.
**Original delivery:** 2026-09-01T00:12:56Z, prompt id `24ecf0ca-db66-45dc-80e2-661093b8ef64:1`, cwd `/Users/jmanning/cdl-linux`.

This is the review that `docs/superpowers/specs/2026-08-31-cdl-design.md` §7 refers to when it
requires the `cdl-agent-lifecycle` spec to resolve **findings #6 and #7**. It existed nowhere in
the repository until now — only references to it — which is why those two were carried as an open
item through two drafts. Stored verbatim so that cannot recur.

**Do not edit below this line.** It is the user's text, quoted, and is the source every claim
about "what the review said" must be re-derived from.

---

I've reviewed the spec; it needs some substantial edits.

The concept is strong and unusually well researched, but the current specification is not implementation-ready. It is closer to an architectural thesis than a buildable system specification: the rationale is excellent, while several critical workflows, interfaces, and acceptance criteria remain undefined or
  internally inconsistent.

  I reviewed the design spec, the full brainstorming/decision log, both research digests, and the structure of the raw research captures. The repository currently contains no implementation scaffold beyond those documents.

  ## Overall assessment

  The strongest idea is not “Ubuntu without a desktop.” It is:

  > A focused coordination appliance for supervising concurrent agent work.

  That is differentiated and coherent. The attention-first framing, worktree isolation, durable supervision, off-machine backup, and terminal-as-primary-interface all reinforce it.

  The project becomes much weaker when it tries to solve everything simultaneously: custom ISO, unusual encrypted RAID layout, hibernation, NVIDIA laptop quirks, local inference, remote compute abstraction, provider onboarding, multi-agent orchestration, macOS keybindings, and a novel display session. Those are
  individually plausible, but collectively create too many unproven dependencies for v1.

  My recommendation is to preserve the product thesis while drastically narrowing the first milestone.

  ## Critical findings

  ### 1. The spec does not yet specify how the distribution is built

  D22 commits to a true remix ISO, but there is no corresponding architecture for:

  - The live ISO build toolchain
  - Subiquity integration
  - The custom storage recipe
  - Package manifests and package sources
  - Package pinning and vendored binaries
  - Secure Boot
  - First-boot provisioning
  - Installed-system updates
  - The project’s own apt repository

  The validation ladder refers to “the installer” as though its design already exists (docs/superpowers/specs/2026-08-31-cdl-design.md:358), but no section defines it.

  This is the largest structural omission. “Opinions are packages” also cannot work until an update and package-delivery channel exists (docs/superpowers/specs/2026-08-31-cdl-design.md:49).

  ### 2. Remote access—the explicit D11 requirement—is largely missing

  The research identified the central conflict:

  FDE boot passphrase
          ↓
  unattended reboot
          ↓
  machine cannot reach normal SSH/Tailscale

  It explored dropbear-initramfs, Tailscale in initramfs, plaintext bootstrap credentials, ACLs, and the threat-model tradeoff. None of that made it into the spec.

  Remote compute is specified, but remote access to the laptop is not. Those are different capabilities. The design still needs decisions on:

  - OpenSSH and/or Tailscale
  - Bind addresses and firewall policy
  - Remote LUKS unlock, or explicit rejection of it
  - Recovery after unattended reboot
  - SSH key enrollment and rotation
  - Whether remote interactive sessions use mosh
  - What happens when networking or Tailscale is updated

  This should be a first-class section, not an implementation detail.

  ### 3. Cage, kitty, autologin, and screen locking may be incompatible as written

  The design says cage can display only one client and that this client is kitty (docs/superpowers/specs/2026-08-31-cdl-design.md:158). It then proposes swaylock as another Wayland client (docs/superpowers/specs/2026-08-31-cdl-design.md:175).

  That needs a concrete proof-of-concept. A single-client kiosk compositor cannot simply be assumed to support a separately launched locker. physlock is not an equivalent solution inside an active Wayland session.

  Until this is demonstrated, autologin should not be committed. A conventional authenticated TTY login followed by automatic cage startup is less elegant but has a much safer failure mode.

  ### 4. Snapshot and rollback are promised but not designed

  D5 promises a snapshot before every update. The recovery section only names grub-btrfs (docs/superpowers/specs/2026-08-31-cdl-design.md:296).

  Missing details include:

  - What initiates snapshots: apt hook, wrapper command, systemd unit, or all three
  - Whether direct apt usage can bypass snapshots
  - Snapshot naming and retention
  - Root rollback semantics
  - Treatment of @home
  - /boot and kernel/package database consistency
  - What happens when a package update succeeds but boot files and root snapshot diverge
  - How the operator confirms and finalizes a rollback
  - Disk-pressure behavior

  Bootable snapshot entries are not themselves a rollback mechanism.

  ### 5. Backup is correctly called load-bearing, but only a backend was selected

  The spec chooses restic over SFTP, but does not define:

  - Schedule
  - Retention
  - Repository encryption and password handling
  - Failure notification
  - Network and AC-power requirements
  - Backup consistency during active agent writes
  - Restore verification
  - A complete bare-machine recovery procedure
  - Recovery-point and recovery-time targets

  Until the backup target is known, RAID0 should remain a conditional design rather than an implementation commitment. The first destructive install should be blocked on a successful backup and restore drill.

  ### 6. The proposed orchestrator is underspecified

  The systemd direction is sensible, but it does not yet describe a usable agent lifecycle:

  - How an interactive agent gets a PTY
  - How the user attaches and detaches
  - How input is injected
  - How blocked/waiting/completed state is detected
  - How exit status is preserved
  - How prompts and launch commands are recorded
  - How agents are cancelled
  - How stale worktrees and services are reconciled
  - How a user resumes work without replaying the initial prompt

  There is also no process sandbox in the final spec, despite the research identifying it as important for unattended agents.

  The proposed “deterministic, non-colliding port block derived from the branch name” is not guaranteed to be non-colliding (docs/superpowers/specs/2026-08-31-cdl-design.md:231). A hash needs collision detection and an allocation registry protected by a lock.

  ### 7. The remote-job interface is too small

  submit → job id and poll → status is a useful conceptual core, but it cannot support the claimed durable workflow by itself. At minimum it needs:

  - submit
  - list
  - status
  - logs
  - cancel
  - artifacts or result location
  - reconcile
  - Idempotency semantics
  - Backend-native and CDL job identifiers
  - Atomic registry writes and locking

  Per-worktree JSON is especially risky if multiple processes can update it. SQLite would likely be simpler and more robust than inventing transactional JSON handling.

  ### 8. Many original minimum requirements disappeared from the final spec

  These are absent or insufficiently specified:

  - Emacs configuration and LLM integration
  - Croft packaging and version pinning
  - Python/PyTorch/Hugging Face environment
  - LaTeX distribution size/profile
  - Text-browser choice
  - VPN support
  - Wi-Fi/network setup
  - Full apt ownership/conflict policy
  - First-run experience
  - Provider-key entry UX
  - Model installation after first boot
  - Offline behavior
  - CUDA first-boot installation
  - Package list and ISO size budget

  A requirement-to-design-to-test traceability matrix would make these omissions immediately visible.

  ### 9. Hibernation should not be accepted merely because QEMU resumes

  QEMU can validate the storage plumbing and initramfs configuration. It cannot validate the real risks that dominate here: the Tensorbook firmware, panel/GPU topology, NVIDIA preservation behavior, lid events, or resume reliability.

  The validation table currently overstates what stage 2 establishes (docs/superpowers/specs/2026-08-31-cdl-design.md:362). Hardware hibernation needs repeated real-machine testing, including failure recovery, before becoming the default.

  ### 10. Some claims contradict their own evidence

  The palette says every normal color clears 4.5:1 (docs/superpowers/specs/2026-08-31-cdl-design.md:348), but ANSI black is listed as 1.24:1 (docs/superpowers/specs/2026-08-31-cdl-design.md:339). ANSI slot 0 can be emitted as foreground text, so it cannot safely be treated as purely structural.

  The spec also calls the worktree experiment and dm-crypt figures “measured” in the main narrative, while §16 correctly classifies them as subagent-reported and not independently reproduced. The main text should use the same qualification.

  Finally, the brainstorming notes say Slurm authentication was later resolved, while open item 15.2 still says public-key authentication is unresolved (docs/superpowers/specs/2026-08-31-cdl-design.md:403). The spec has gone stale relative to its own decision log.

  ## What is especially good

  Several decisions should survive the narrowing:

  - Ubuntu LTS rather than a rolling development archive
  - Plain CDL branding rather than trying to remain a literal Rhino spin
  - Focus by default rather than pretending focus can be enforced
  - Worktrees as the unit of concurrent agent work
  - systemd as the durable process supervisor
  - Restart=no for agents
  - Provider secrets scoped to the user rather than /etc
  - Backup treated as essential
  - A visible recovery menu and retained live USB
  - Hardware capture before wiping
  - Remote environments treated as disposable and self-contained
  - Proprietary applications installed only through vendor-controlled flows
  - A staged Docker → VM → hardware validation strategy

  ## Recommended next steps

  ### 1. Rewrite the spec around explicit milestones

  I would use:

  1. CDL environment prototype
     Ubuntu 26.04 VM or existing Linux installation; package manifest, kitty session, keybindings, provider configuration, worktrees, one supervised agent.

  2. Operational appliance
     Real Tensorbook using a conventional Ubuntu Server installation; NVIDIA, networking, backup, remote access, orchestration, power behavior.

  3. Recoverable custom storage installation
     RAID0/LUKS/LVM/btrfs, snapshots, restore drill, hibernation experiments.

  4. Remix ISO
     Reproducible build, installer integration, package repository, signing, documentation, and generic hardware profile.

  Do not make ISO work the prerequisite for discovering whether the day-to-day environment is actually pleasant.

  ### 2. Perform the hardware capture now

  This should happen before more architecture work, even if destructive installation is months away. Add:

  - nvidia-smi GPU, VRAM, driver, power and thermal data
  - lspci -nnk
  - lsblk -e7 -o ...
  - SMART/NVMe health
  - current partition tables
  - Secure Boot status
  - TPM presence
  - Wi-Fi chipset and active driver
  - firmware/BIOS version
  - suspend modes from /sys/power/mem_sleep
  - current boot parameters
  - display connector/provider topology

  The existing capture list is too narrow for the number of decisions that depend on it.

  ### 3. Resolve five blocking product decisions

  Before implementation, decide:

  - Remote unlock after reboot: yes or no
  - Exact backup target and restore expectations
  - Normal agent concurrency and whether agents are local-model or API-backed
  - Whether hibernation is a launch requirement or an experiment
  - Which capabilities are actually v1: local inference, remote-job adapter, both, or neither

  ### 4. Add four missing design documents

  Keep the current document as a product/architecture overview, then create focused specs for:

  - ISO, installer, packaging, and updates
  - Security, secrets, remote access, and recovery
  - Agent lifecycle and orchestration
  - First boot, provider/model setup, and offline behavior

  Each should include state transitions, failure behavior, and acceptance tests.

  ### 5. Build three risk spikes before broad scaffolding

  The highest-value proofs are:

  1. Cage + kitty + literal Super keybindings + zellij + croft + a working lock path.
  2. A systemd-managed interactive agent that can be attached, survives logout, reports completion, and never replays itself.
  3. Subiquity or another installer producing the exact two-disk encrypted layout in QEMU, followed by snapshot, update, rollback, and resume tests.

  A failed spike should be allowed to change the architecture.

  ### 6. Create traceability and threat-model tables

  For every original requirement, record:

  requirement → design component → milestone → acceptance test

  Separately identify threats such as opportunistic theft, malicious local processes, compromised agents, stolen backup credentials, supply-chain compromise, and physical “evil maid” access. The current FDE/secrets discussion mixes several threat models.

  ### 7. Define a minimal v1

  My preferred v1 would include:

  - Ubuntu Server 26.04 base
  - Cage/kitty only if the lock spike succeeds
  - OpenSSH over Tailscale after normal boot
  - Worktree creation and seeding
  - One systemd-managed agent lifecycle
  - cdl status
  - User-scoped provider configuration
  - Emacs, croft, and one flagship agent
  - Restic backup with tested restore
  - NVIDIA driver and PyTorch
  - Plain SSH/sbatch recipes, not a custom remote-job abstraction yet
  - No hibernation guarantee
  - No custom RAID installer or remix ISO until the environment proves useful

  That version tests the product’s actual thesis—focused agent coordination—without making success depend on the riskiest storage, boot, and hardware work.

  In short: keep the vision and most of the architectural principles, but turn the current document into an overview, narrow v1, and make security, lifecycle, installation, updating, and recovery precise before writing the distro itself.
