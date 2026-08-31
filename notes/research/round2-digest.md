# cdl-linux research round 2 — digest (2026-08-31)

Run `wf_e569a708-f28`. 6 agents, 0 errors, 841835 tokens. Raw: round2-raw.json


## CLUSTRIX VERDICT: **PARALLEL-SIDE-QUEST**

**Reasoning:** The distro needs ZERO lines of clustrix to boot, encrypt, run agents, or reach a cluster. Everything cdl-linux actually requires from remote compute is `ssh` plus `sbatch` — both already installed, both already proven against <slurm-host> and <gpu-host> in clustrix's own committed evidence. So fixing clustrix must NOT precede distro work; making it a prerequisite converts 23 open issues, an undecided API semantics question (#170), 847 mock occurrences, and a bus factor of 1 into blockers on a bootable image. That is exactly the distraction the distro exists to eliminate. BUT there is a bounded, high-value slice worth doing in parallel, in its own session/worktree, never on the image's critical path: Tier 1 release mechanics. v0.2.0 is unreleased — I confirmed this session that `git ls-remote --tags origin` returns only refs/tags/v0.1.1 — so `pip install clustrix` today installs 0.1.1, the version whose own release notes say `@cluster` 'had never successfully executed a function on any real backend.' Meanwhile master is green (2784 passed locally, exit 0), 596 commits of work are done, and real SLURM/SSH jobs passed 18/18 on Dartmouth hardware. The only thing between that and a usable library is a git tag, a PyPI token, and a rotated HF_TOKEN. Hours, not weeks, and its value is independent of the distro. Two hard boundaries: (1) Tier 2/3 work — durable job handles, a real CLI, #170, mock removal, restoring the 7 removed backends — is out of scope until the laptop boots; (2) clustrix must never become a dependency of cdl-linux. It blocks the calling process for the whole job (822s measured cold start on <slurm-host>), persists no job IDs to disk, and has no TUI — all three disqualifying for unattended agent sessions, so the distro would have to build the durable job registry and the TUI anyway. Build those in cdl-linux behind a two-function interface (submit -> job id; poll -> status), and let clustrix be one optional backend among ssh+sbatch and ssh+nohup.

**Alternative:** Plain `ssh` + `sbatch` (<slurm-host>) and `ssh` + `nohup` (<gpu-host>/<gpu-host-2>), wrapped in a ~200-line adapter whose only real content is a durable on-disk job registry: submit, record {job_id, backend, host, submitted_at, remote_dir} to a per-worktree JSON file, walk away, re-attach from any later process. Detached by construction (sbatch returns a job ID immediately), zero dependencies, works today against every target the user has, and it is the one piece clustrix does not and cannot provide. It is also the right abstraction regardless: if clustrix ships it becomes a backend module; if it never ships nothing is lost. SkyPilot is the only credible later upgrade — the sole maintained tool that submits from a laptop to a Slurm login node over plain SSH with no daemon and no root, with re-attachable jobs — but its own docs say 'Slurm support is under active development' and its SSH-machine mode needs Debian + root + k3s on port 6443, so it cannot reach <gpu-host> and is a v2 evaluation, not a v1 dependency. Rule out submitit and dask-jobqueue (must run ON the login node, no SSH backend) and Parsl (SSH channels removed in #3515; its FAQ names 'laptop on wifi with no public IP' as a documented failure mode — i.e. a machine behind the Dartmouth VPN).

**Effort:** Clustrix Tier 1 (tag v0.2.0, publish to PyPI, rotate HF_TOKEN, gate or fund the HF Jobs smoke test, fix the `clustrix status` docstring/behavior mismatch): 4-8 hours, one session, separate worktree. The cdl-linux side of remote compute for v1: ~200 lines of adapter plus an ssh_config in the image — half a day, and honestly deferrable out of v1 entirely. Clustrix Tier 2 (durable handles, submit/list/logs/cancel CLI, #170 semantics): 1-3 weeks — do NOT start before the laptop boots. Tier 3 (mock removal, 90% coverage, restoring removed backends): months — permanently out of scope for this project.


## ARCHITECTURAL CONSEQUENCES (12)

### The unit of workspace is a git worktree, not the repo — and the image must ship worktree SEEDING, not just worktree tooling.
_Driven by: Several LLM agents at once on one repo_

A shared checkout empirically loses 76% of commits (24/100 landed, 75 index.lock failures, agents staging each other's half-finished files); worktrees land 100/100 with a clean fsck. But `git worktree add` does NOT carry untracked/gitignored files, so every new agent workspace starts with no .venv, no node_modules, no .env — verified empirically. The distro therefore needs a post-create hook that (a) creates the venv with `uv` so packages hardlink from one cache, (b) reflink-copies large ignored dirs with `cp --reflink=auto` on btrfs, and (c) derives a deterministic non-colliding dev-server port block per branch. No terminal tool in this category allocates ports. This hook is the highest-value glue in the project and it is dozens of lines, not a new product. Also: one branch cannot be checked out in two worktrees, so each agent must own its own branch by construction.

### The image ships ONE inference server as a system service plus a flock GPU semaphore — never per-agent GPU partitioning.
_Driven by: Several agents + one laptop GPU_

MIG is unavailable on every GeForce/laptop part (NVIDIA's supported list is datacenter/workstation only), and MPS is actively hostile to unattended agents: killing a client without syncing 'can leave the MPS server and other MPS clients in an undefined state,' and all client activity is attributed to the MPS server in nvidia-smi, destroying per-agent attribution exactly when supervising four agents. The right frame is admission control, not isolation: load weights once, let the server batch, budget for the KV-cache multiplier ('a 2K context with 4 parallel requests will result in an 8K context'). This is a systemd unit and two env vars in the image, not a subsystem.

### systemd --user with lingering is the supervisor; tmux/zellij is demoted to a viewer. A naive distro gets this backwards.
_Driven by: Long-lived unattended sessions_

`loginctl enable-linger` so agents run with nobody logged in; an `agent@.service` template per agent in its own slice, which buys journald capture with cross-reboot history, per-agent MemoryHigh/CPUWeight (user@.service ships `Delegate=pids memory cpu`, so these work unprivileged — note `io` is NOT delegated, so IOWeight silently does nothing), and `OnFailure=notify@%N.service` using the template pattern in systemd.unit(5) Example 3. Use Restart=no for the agents themselves: restarting an LLM agent re-runs it from its initial prompt against a repo it already half-modified. Interactive panes must start under `systemd-run --scope --user` (the documented pattern) so they outlive the login session.

### Ubuntu's shipped systemd-oomd config will silently SIGKILL your agents overnight unless the image overrides it.
_Driven by: Unattended sessions on an Ubuntu-derived base_

Extracted from the actual 26.04 deb: user@.service.d/10-oomd-user-service-defaults.conf sets ManagedOOMMemoryPressure=kill with a 50% limit, and Ubuntu overrides DefaultMemoryPressureDurationSec to 20s. So an arbitrary descendant cgroup of the user session — a random agent, or the tmux server taking every agent with it — gets killed on PSI pressure and you do not choose the victim. The image must ship per-agent slices with MemoryHigh (which throttles rather than kills) plus MemoryMax as a backstop, and ManagedOOMPreference=avoid on the multiplexer and notifier. No 'Ubuntu minus desktop' image contains this file.

### Lid and idle policy must be inverted at the system level, because logind structurally cannot see the agents.
_Driven by: Unattended sessions on a laptop_

logind derives a TTY session's idle hint from the tty's atime and returns false outright for a session with no tty — so a detached tmux session with four agents at 100% CPU counts as idle, and with zero login sessions the whole system counts as idle. Meanwhile LidSwitchIgnoreInhibited defaults to 'yes', so a sleep inhibitor does not stop a lid-close suspend, and polkit ships inhibit-handle-lid-switch with allow_any=no while treating seatless SSH sessions as non-local — the lock you want cannot be taken from SSH. The image therefore ships a logind.conf.d drop-in (HandleLidSwitch=ignore, HandleLidSwitchExternalPower=ignore, IdleAction=suspend) and every job runs under `systemd-inhibit --what=idle:sleep`, the one lock polkit grants unauthenticated. Separately, UPower's default critical-power chain ends in PowerOff at 2% with no hibernation swap — on an FDE machine that means the passphrase prompt and total loss of the session.

### The image has TWO operating systems to build, and the disk layout is decided by the remote-unlock path, not by btrfs preference.
_Driven by: Remote access + full-disk encryption_

Every remote-access mechanism — sshd, tailscaled, Claude Code Remote Control — lives in userspace after root is mounted, so an unattended reboot parks the machine at the initramfs prompt, unreachable from anywhere. Making it reachable means dropbear-initramfs (Ubuntu universe, present through the current devel series) plus tailscale-initramfs so the box joins the tailnet before root unlocks. Two consequences a naive image never faces: (1) stripe BELOW the crypt layer — mdadm/LVM RAID0, one LUKS2 container, btrfs single-profile inside — because btrfs-native RAID0 over two LUKS containers means two passphrase prompts and two cryptroot-unlocks; (2) 'does pre-boot SSH still work?' becomes a mandatory post-kernel-update check on a rolling base that regenerates the initramfs constantly. The config path is /etc/dropbear/initramfs/dropbear.conf — most blog posts still cite the pre-2022 path and will silently do nothing.

### Zero public ports, ever — a tailnet is the transport substrate and the firewall default is deny-all-except-tailscale0.
_Driven by: Remote access from other machines_

This is the same choice NVIDIA shipped for headless DGX Spark access (NVIDIA Sync wraps Tailscale rather than a bespoke relay), and Tailscale's own hardening guide endorses deleting every ufw rule except 'Anywhere on tailscale0'. Consequence for session design: prefer plain OpenSSH bound to tailscale0 over Tailscale SSH, because 'Restarting the Tailscale daemon will stop any existing Tailscale SSH session' and a rolling base restarts tailscaled on upgrade. Never let an agent's lifetime depend on the connection — always inside a multiplexer or a systemd unit.

### There is no focus subsystem. The entire attention design is the build manifest plus the display stack — build-time facts, not running services.
_Driven by: Attention as the core motivation_

Because the user is root, every runtime enforcement mechanism is endogenous, and the strongest available evidence (Marotta & Acquisti, n=455) is that endogenous self-commitment produced no productivity change while exogenous defaults produced ~8 more tasks/hr. Every kiosk precedent that works exempts the administrator by design. So: no display manager, no desktop, no JS-capable browser engine, no notification daemon, no blocklists, no time gates, no dashboards. The honest restatement is 'focused by default via absence,' and the correct scope is a package list plus a shell that opens onto the repos. The one cheap ratchet worth keeping is the image manifest in git, so anything installed at 11pm is a visible diff. Two traps this closes: 'text-based browser' must mean w3m/lynx (non-JS by capability), NOT Browsh or Carbonyl — Carbonyl is literally 'Chromium running inside your terminal' with WebGL and video; and 'present but unadvertised' is theater here, since Rhino's empty-.desktop trick hides things from a GUI menu this system will not have.

### Notifications are outbound-only and leave the machine entirely; the split is by who initiated the event.
_Driven by: Attention + unattended sessions both_

Completion receipts for things the user started (agent finished, GPU job OOMed, remote job returned) go out via a curl one-liner to ntfy on the phone, and appear locally only as a passive status line — never a bell, popup, or color flash. Things the world started (mail, chat, news) get no delivery path at all, not a muted one. Concretely: do not install libnotify/dunst/mako. A general notification bus is a general interruption bus, and Rhino's own ISO builder already treats update-notifier as clutter to purge.

### The image must ship an AppArmor profile for bwrap, or the entire unattended-safety story is silently absent while appearing to work.
_Driven by: Ubuntu 24.04+ lineage + unattended agents_

'On Ubuntu 24.04 and later, the default AppArmor policy prevents bubblewrap from creating the user namespaces it needs for isolation,' and Claude Code's default on sandbox failure is a warning followed by running UNSANDBOXED. So the build must include /etc/apparmor.d/bwrap, preinstall bubblewrap + socat, set sandbox.failIfUnavailable: true, and run a first-boot check on `sysctl kernel.apparmor_restrict_unprivileged_userns`. On a rolling base this needs to be a recurring check. Anthropic's own guidance is that worktrees plus the Bash sandbox are 'not sufficient for fully unattended runs' — the process boundary is required, and bubblewrap (not Docker) is the right one for a laptop needing native GPU access.

### ANTHROPIC_BASE_URL and the privacy env vars must never be set in the system profile.
_Driven by: Local models + Claude Code Remote Control both wanted_

Remote Control refuses to run when ANTHROPIC_BASE_URL points anywhere but api.anthropic.com, and DISABLE_TELEMETRY / DO_NOT_TRACK / CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC / DISABLE_GROWTHBOOK each disable it outright. The natural distro design — one local gateway for everything, privacy vars on by default — would silently kill the best phone-steering path, including `--spawn worktree` with `--capacity 32`, which is the cleanest answer to concurrent agents on one repo. Scope local-model routing per-project or per-shell and drive local models through ollama/vLLM directly rather than rewriting Claude Code's base URL machine-wide.

### The build is a maintained divergence from a desktop distro, and the submission-side Python must be pinned independently of the system Python.
_Driven by: Rhino Linux base + a rolling Ubuntu-devel lineage_

Rhino's identity is maximal installability and a GUI: rhino-pkg wraps 'apt + snap + flatpak + Pacstall', and it ships lightdm, plymouth, Unicorn/XFCE, themes and hello-rhino. The good news is Rhino's own ISO hook (etc/config/hooks/live/000-remove-blacklisted-packages.chroot) already does `apt-get autoremove --purge` on ubuntu-desktop, snapd, apport and update-notifier — extend that file rather than inventing a mechanism, but keep Pacstall since that is how Rhino ships kernels. Separately, any environment-replicating remote submission mirrors the caller's Python minor version; a rolling system Python bump silently invalidates every cached remote conda env, turning 62-second reruns back into 14-minute cold starts. Pin the agent/submission Python with uv or pyenv and make that pin an explicit, visible distro setting.


## UNIDENTIFIED / UNVERIFIED (honesty ledger)

### openclaw
NOT unidentified — I verified this live rather than trusting the corpus. github.com/openclaw/openclaw returns HTTP 200 with aria-label="388261 users starred"; TypeScript, MIT (LICENSE reads 'MIT License / Copyright (c) 2026 OpenClaw Foundation'), a personal AI assistant, 'The lobster way'. Architecture: a loopback-bound Gateway on 127.0.0.1:18789 reached over SSH tunnel or Tailscale Serve, headless node join via short-lived 128-bit codes, chat apps as remote channels, and OpenShell for delegating long-running work to remote sandboxes over SSH. Recommendation: borrow the Gateway/loopback/pairing pattern, do not ship the product — its primary operator surface is `openclaw dashboard`, a web Control UI, and its surface area (browser automation, email, smart home) contradicts the attention goal.

### GlobalProtect on Linux, headless, with Dartmouth two-factor
Confirmed Dartmouth uses GlobalProtect (it 'has replaced the F5 VPN client') and that ITC publishes a 'GlobalProtect Linux VPN Client Installation' article. NOT confirmed: whether the Linux client connects fully headless with no X, and whether a session survives a multi-hour unattended run. Palo Alto doc URLs returned 404 and the web-search budget was exhausted. This is the single largest unverified risk for remote compute on a TUI-only machine — every <slurm-host>/<gpu-host> job depends on it. Resolve empirically on a test box before designing any remote-job path.

### TPM 2.0 presence on the Lambda Tensorbook
Undetermined. Gates every TPM option (systemd-cryptenroll --tpm2-with-pin, clevis-tpm2). Resolve on the hardware with `ls /dev/tpm*`, `systemd-cryptenroll --tpm2-device=list`, and a firmware check for Intel PTT. Note that TPM auto-unlock would silently repeal the FDE decision already made, so this may not matter at all.

### The user's exact Tensorbook GPU and VRAM
Partially identified and internally inconsistent across the corpus. The surviving Lambda/Razer launch post specifies i7-11800H, RTX 3080 Max-Q 16GB VRAM, 64GB DDR4, 2TB SSD, Razer Blade 15 chassis, shipped with Ubuntu 20.04 — and 64GB matches the brief. But Lambda's spec page now 301-redirects away (on-prem hardware business ended 2025-08-29), so the configuration of THIS unit is unverified. One command settles it: `nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv`. Certain regardless: it is a GeForce mobile part, so MIG is off the table.

### Sustained lid-closed thermal behavior of this chassis
No primary source. NotebookCheck (the usual source for Blade 15 Advanced stress data) blocked automated fetches with 403/404 and Lambda's pages are gone. What is certain is that the GPU self-protects via hardware slowdown/shutdown temperatures visible in nvidia-smi, so the realistic risks are the panel, battery and chassis surface — not silicon damage. Treat as an empirical question for the actual machine, not a spec-sheet answer. Linux fan control for Razer chassis is also in poor shape (the popular no-dkms fork was archived 2025-03-31), so do not plan a thermal safety mechanism around it.

### What specifically broke when the user says 'clustrix is currently broken'
Cannot be inferred, and the evidence points the other way: master CI green (2026-08-23) and a full local run gave 2784 passed / 20 skipped / exit 0. The three provable breakages are (a) v0.2.0 unreleased so `pip install clustrix` gives 0.1.1 where remote execution never worked — I re-confirmed only refs/tags/v0.1.1 exists on origin; (b) HF Jobs 401 in scheduled CI (expired HF_TOKEN) and 402 in manual runs (unfunded account); (c) issue #170, parallel=True returning a cores-dependent value and type. If the user hit something else it is worth capturing before it is lost.

### NVIDIA Sync's license / source availability
Undetermined — the docs page only says 'Download and install NVIDIA Sync' with no license or repo link. Treat as proprietary. Immaterial to the build: the borrowable insight (NVIDIA's own off-network answer is Tailscale) is already established, and NVIDIA/dgx-spark-playbooks is Apache-2.0 but contains instructions only, not dashboard source.

### Zellij's runtime memory footprint versus tmux
No credible current measurement. The three zellij memory issues on GitHub are all closed and date from 2021-2023. Architecture (Rust + WASM plugin runtime + optional web server vs a small C daemon) suggests a higher baseline but I have no number. Measure with `ps -o rss=` if it matters; on 64GB it probably does not.

### Whether any Linux distribution already targets attention as its primary design goal
Negative finding, and honestly search-limited (WebSearch budget exhausted at 200/200). Everything surfacing under 'distraction-free Linux' is one of three other things: minimalism/low resource use, visual tidiness (Pop!_OS), or third-party lockdown (Porteus Kiosk, ChromeOS kiosk — both of which exempt the administrator by design). Webconverger, the other commonly cited kiosk distro, declares 'End of life 2023'. So cdl-linux appears to have no direct precedent, but treat this as 'not found' rather than 'does not exist'.

### Peer-reviewed status of Marotta & Acquisti (2017)
The retrieved PDF is labelled 'PRELIMINARY DRAFT' (WEIS 2017, June 2017) and itself says 'additional analysis is needed to understand and confirm the mechanism.' I could not check for a published version. Treat the direction of the finding (exogenous blocking works, endogenous self-commitment does not) as well-supported and the effect sizes (~8 tasks/hr, ~$0.80/hr) as provisional.


## NEW USER QUESTIONS (12)

### Q1. Is Rhino Linux actually the right base, or would plain Ubuntu Server (or Debian) get you there faster? Rhino's entire identity is a rolling desktop plus four package surfaces, and the build plan is largely 'delete Rhino's identity.'
**Matters:** This is the biggest scope decision left and nobody has asked it. Rhino means maintaining a divergence upstream will never test, on a rolling base whose kernel churn threatens the initramfs remote-unlock path on every update. Ubuntu Server means the desktop was never there to remove, the initramfs is stable, and you keep apt and NVIDIA packaging. The one real argument for Rhino is Pacstall for fresher packages — worth knowing whether that is load-bearing for you or incidental.

**Options:** (a) Rhino, extending their own 000-remove-blacklisted-packages.chroot hook — most work, freshest packages; (b) Ubuntu Server 26.04 LTS minimal + NVIDIA drivers — least work, most stable initramfs, no desktop to delete; (c) Ubuntu Server with Pacstall added for the two or three packages that actually need it.

### Q2. Does v1 ship remote job submission at all, or is that explicitly a later milestone?
**Matters:** Your stated motivation is attention rather than capability, and there is a defensible v1 that ships nothing but ssh configured plus a documented sbatch workflow. Deferring it removes the clustrix question, the SkyPilot evaluation, and the VPN unknown from the critical path to a bootable image.

**Options:** (a) v1 ships ssh config + a documented sbatch recipe, nothing else; (b) v1 ships the ~200-line adapter with the durable job registry and one ssh+sbatch backend; (c) v1 ships nothing — remote compute is v2.

### Q3. Are the coding agents API-backed (Claude/Codex) or do they run on the local GPU — and separately, is the local GPU doing your research work during those unattended windows?
**Matters:** If the agents are API-backed and the GPU sits idle overnight, an entire layer disappears from v1: no inference server, no GPU semaphore, no MPS/MIG question, and no NVIDIA suspend/resume work (NVreg_PreserveVideoMemoryAllocations plus a ~17GB temp path that must not be tmpfs). That is the largest single scope reduction available.

**Options:** (a) API-backed agents, GPU idle overnight — drop the whole GPU layer from v1; (b) API-backed agents, GPU running your own jobs — keep only a flock semaphore; (c) local models drive the agents — the shared inference server is v1-critical.

### Q4. How are the two NVMe drives laid out, and is RAID0's doubled failure rate acceptable? One LUKS container over an mdadm/LVM stripe, or btrfs-native RAID0 over two LUKS containers?
**Matters:** This blocks the installer and cannot be changed later without a reinstall. Striping below the crypt layer gives one passphrase, one unlock, one cryptroot-unlock. btrfs-native RAID0 means two LUKS containers, two prompts, and the decrypt_keyctl keyscript — doubling the fragility of the remote-unlock path you most need to be reliable. Also: RAID0 across two drives doubles the whole-volume failure rate, so the backup plan is not optional.

**Options:** (a) mdadm RAID0 -> one LUKS2 -> btrfs single profile (recommended); (b) two LUKS + btrfs RAID0 + decrypt_keyctl; (c) no striping — two separate volumes, simplest of all.

### Q5. Is remote LUKS unlock a v1 requirement, and are you comfortable with a Tailscale auth key sitting in plaintext in the initramfs on the unencrypted boot partition? Related and prior: is the FDE threat model an opportunistic thief, or a targeted adversary with physical access?
**Matters:** Remote unlock is the only way to recover an unattended reboot from anywhere, and it has a cost stated verbatim by the tool's author: a stolen powered-off laptop yields a tailnet credential (ACL-scopable, expiring within 90 days, needing an initramfs rebuild before expiry). Against a targeted adversary nothing in an unencrypted initramfs is trustworthy at all — an evil-maid can modify it to capture the passphrase — and the honest answer becomes that unattended reboot cannot be solved securely.

**Options:** (a) dropbear + tailscale-initramfs in v1, accept the key exposure with a tight ACL; (b) dropbear LAN-only in v1, full remote unlock in v2; (c) no remote unlock — a reboot means walking to the machine.

### Q6. Which Claude subscription tier, and is it acceptable that Remote Control stores session transcripts on Anthropic servers while connected?
**Matters:** Remote Control requires a Pro/Max/Team/Enterprise claude.ai login and explicitly does not support API keys. If you are API-key-based, the phone-steering story must come from Channels or a terminal client instead — and `--spawn worktree` with `--capacity 32`, the cleanest built-in answer to concurrent agents on one repo, goes away with it. The transcript question matters given this is Dartmouth/ContextLab work that may involve unpublished or IRB-scoped material.

**Options:** (a) Max/Pro login — Remote Control is the phone path; (b) API key — plan on Channels (Telegram) or mosh + tmux from Blink; (c) no remote steering in v1.

### Q7. Will this machine live permanently on AC, and are you willing to disable suspend, hibernate and automatic reboots on it?
**Matters:** With a boot passphrase, any reboot ends every running agent until you physically type it. UPower's shipped critical-power chain ends in a hard PowerOff at 2% battery when there is no hibernation swap. If the answer is 'always plugged in, no auto-reboot,' a whole category of battery, thermal and suspend work drops out of v1 and the remaining risk is just kernel updates.

**Options:** (a) Always AC, suspend and auto-reboot disabled — simplest; (b) sometimes on battery — needs a low-battery push alert and an AC-required guard on long jobs.

### Q8. Will you accept a browser that literally cannot execute JavaScript (w3m/lynx), knowing it will occasionally fail on a real docs site or cloud console?
**Matters:** This is the one attention decision that must be made explicitly at build time, because 'text-based browser' does not constrain anything by itself — Carbonyl is Chromium in a terminal with WebGL and video playback, and Browsh claims it renders 'anything that a modern browser can.' A non-JS engine is capability-limited rather than willpower-limited, which is the only kind of limit that survives you being root. Both JS-capable terminal browsers are also poorly maintained, which is an independent reason for the same choice.

**Options:** (a) w3m only, and JS-gated pages become an agent fetch-and-summarize task; (b) w3m plus a headless non-interactive renderer the agent drives; (c) install a JS terminal browser and accept the distraction surface that comes with it.

### Q9. Do you want this machine to ever tell you to stop?
**Matters:** The best available evidence (Mark et al., CHI 2018) is that people with high control over their own work — you — responded to having distractions blocked by working 'longer stretches without physical breaks, with consequently higher stress,' and about a third of that sample reported net costs. You are building a machine that makes this more likely, not less. If yes, the cheap honest version is elapsed-session time in the same passive status line as agent state — never a nagging timer, which is the 'often annoying' pattern the same literature warns about.

**Options:** (a) Nothing — the machine never comments on your time; (b) passive elapsed-session time in the status line; (c) an explicit session end that gets recorded.

### Q10. Can you reach <slurm-host> by SSH from OFF the Dartmouth VPN, via a bastion or public login host?
**Matters:** If yes, the entire VPN constraint disappears for Slurm work and the biggest unverified risk in remote compute evaporates. If no, headless GlobalProtect on Linux with two-factor must be verified on a test box before any remote-job design is committed to — I could not verify it from documentation, and every unattended remote job depends on it.

**Options:** (a) Yes, there is a bastion — ask RCD to confirm; (b) No, VPN required — verify headless GlobalProtect first; (c) Unknown — one email to RCD settles it.

### Q11. Are you willing to publish clustrix v0.2.0 to PyPI (it needs a token only you control), and do you want the HuggingFace Jobs backend at all?
**Matters:** These are the only two decisions in the Tier-1 clustrix slice that require you rather than me. Without the PyPI publish, any future integration installs from a git checkout — a meaningfully worse story for a distro you might share. And HF Jobs is failing two ways (401 expired token in scheduled CI, 402 unfunded account in manual runs); if you do not intend to fund it, gating that smoke test off the weekly schedule stops CI going permanently red for a non-bug.

**Options:** (a) Publish and fund HF; (b) Publish and gate HF Jobs out of scheduled CI; (c) Do neither for now — clustrix stays paused entirely until the laptop boots.

### Q12. How many agents concurrently in the normal case, and roughly what peak RSS does one of yours use? A `systemd-cgtop -m` capture during a typical session would settle it.
**Matters:** I can give you the slice and MemoryHigh scaffolding, but the per-agent budgets are a measurement, not a guess. It also decides whether the concurrency is small enough (2-3) that a plain tmux + worktree setup with no manager is defensible, or large enough (6+) that workmux's dashboard is the difference between supervision and chaos.

**Options:** (a) 2-3 agents — skip the manager, use Claude Code's native --worktree plus tmux; (b) 4-8 agents — workmux earns its place; (c) unknown — measure first on the current machine.


## VENDOR LIST (18)

| name | url | role | license |
|-|-|-|-|
| workmux | https://github.com/raine/workmux | Primary multi-agent orchestrator: git worktree + tmux window per agent, cross-session TUI dashboard with per-agent working/blocked/done status in the tmux status line, input injection without attaching, one-command merge+teardown, and — critically — files.copy/symlink plus post_create hooks that fix the empirically-confirmed 'new worktree has no .venv/.env/node_modules' problem. Most actively maintained tool in the category by a wide margin (release 2026-08-30, 100+ commits/90d). Rust binary not in Ubuntu repos, so the image vendors the linux-amd64 tarball and owns the update cadence. | MIT |
| claude-squad | https://github.com/smtg-ai/claude-squad | Documented fallback if workmux's single-maintainer risk materializes. Same architecture (tmux + worktrees + TUI), far better known (8.4k stars), still shipping — but slowing (6 commits/90d) and lacking the worktree file seeding. The AGPL is a deliberate decision to make, not an oversight. | AGPL-3.0 |
| @anthropic-ai/sandbox-runtime | https://github.com/anthropic-experimental/sandbox-runtime | The process boundary for unattended agents without Docker — wraps the whole Claude Code process (file tools, MCP servers, hooks) in bubblewrap, so the GPU stays natively accessible. Anthropic's own docs say worktrees plus the Bash sandbox are 'not sufficient for fully unattended runs.' Pin the version: explicitly a beta research preview with an unstable config format, and it starts anyway (blocking network, confining writes) if settings fail to load — so a clean start is not proof the config applied. | Apache-2.0 |
| bubblewrap | https://github.com/containers/bubblewrap | Underlying unprivileged sandbox. Must be preinstalled AND unblocked with an /etc/apparmor.d/bwrap profile on any Ubuntu 24.04+ lineage, plus sandbox.failIfUnavailable: true, or isolation silently does not happen while appearing to work. | LGPL-2.1 |
| tailscale-initramfs | https://github.com/darkrain42/tailscale-initramfs | The load-bearing piece for remote LUKS unlock: runs the Tailscale client inside the Debian/Ubuntu initramfs so the machine joins the tailnet before root is mounted, behind NAT with no port forwarding. Small project (86 stars) — read its verbatim warning about the plaintext auth key on unencrypted /boot before adopting, and calendar the ~90-day key rotation. | GPL-2.0 |
| dropbear-initramfs (Ubuntu universe) | https://packages.ubuntu.com/search?keywords=dropbear-initramfs&searchon=names&suite=all&section=all | Pre-boot SSH server for cryptroot-unlock, present through the current Ubuntu devel series. Config lives at /etc/dropbear/initramfs/dropbear.conf — verify against the package filelist, not blog posts still citing the pre-2022 /etc/dropbear-initramfs/config path, which will silently do nothing. | MIT-style (Dropbear) |
| Debian cryptsetup README.initramfs | https://salsa.debian.org/cryptsetup-team/cryptsetup/-/raw/debian/latest/debian/README.initramfs | Authoritative source on unlocking multiple LUKS devices with one passphrase (decrypt_keyctl vs decrypt_derived), including the warning that decrypt_derived loses your data permanently if the source LUKS header is damaged. Read before finalizing the two-NVMe layout. | documentation |
| tmux | https://github.com/tmux/tmux | The persistence and scriptability layer. Four primitives an orchestrator needs and zellij lacks: pipe-pane (continuous output tee with no rate limiter), set-hook pane-exited/pane-died (fires the completion notification with no polling), wait-for, and control mode. In the Ubuntu archive; upstream very active. | ISC |
| tmuxp | https://github.com/tmux-python/tmuxp | Declarative session layout in a git-tracked YAML, loaded detached with `tmuxp load -d`. The safe post-reboot story: rebuild geometry, shells and CWDs, never replay agent commands. Use instead of tmux-resurrect, which is two years stale and has open Aug-2026 bugs titled 'Saved pane command line cannot be replayed faithfully.' | MIT |
| zellij | https://github.com/zellij-org/zellij | Alternative multiplexer and a supported workmux backend — better out-of-box ergonomics and built-in per-second session serialization with a safe 'Press ENTER to run' banner. Two caveats: not in the Ubuntu archive, and it has no pipe-pane, no pane-exit hooks and no exit-status query, so completion detection must wrap the command rather than observe the pane. Prefer the `zellij-no-web` build if you take it. | MIT |
| ntfy | https://github.com/binwiederhier/ntfy | Outbound-only completion receipts to the phone, so the interrupting surface lives off the machine and no notification daemon is installed. One curl line from any systemd unit or hook. Client is in the Ubuntu archive; self-host if notification bodies will carry journal tails or repo paths. | Apache-2.0 |
| earlyoom | https://github.com/rfjakob/earlyoom | Second OOM net under systemd-oomd, catching the fast-ballooning single process that PSI misses over 20s. SIGTERM before SIGKILL, with --avoid/--prefer to protect sshd and the multiplexer. In the Ubuntu archive. Read earlyoom.default first: a quoted or space-containing --avoid regex silently matches nothing because systemd word-splits the args without shell quote removal. | MIT |
| rhino-linux/os (ISO builder hook) | https://github.com/rhino-linux/os | Template rather than dependency — etc/config/hooks/live/000-remove-blacklisted-packages.chroot already implements purge-by-construction on ubuntu-desktop, ubuntu-session, snapd, apport, update-manager and update-notifier, plus the empty-.desktop hiding trick. If Rhino stays as the base, extend this file instead of inventing a mechanism, and keep Pacstall since that is how Rhino ships kernels. | see repo |
| Cage | https://github.com/cage-kiosk/cage | Escape hatch, not a v1 component: a single-application Wayland kiosk compositor that runs on KMS+DRM straight from a TTY, so the one GUI thing you eventually need does not require a desktop underneath it. Actively maintained (v0.3.1, 2026-06-30). | MIT |
| SkyPilot | https://github.com/skypilot-org/skypilot | v2 candidate for laptop-to-Slurm submission — the only maintained tool that submits over plain SSH to a login node with no daemon and no root, with re-attachable managed jobs. Not v1: its own docs say 'Slurm support is under active development,' and its SSH-machine mode needs Debian + root + k3s on port 6443, which rules out <gpu-host>. | Apache-2.0 |
| ContextLab/clustrix | https://github.com/ContextLab/clustrix | Optional backend only, never a dependency. After Tier-1 release mechanics it becomes a legitimate `pip install` for function-shipping to <slurm-host>/<gpu-host> with environment replication — genuinely unmatched by anything else surveyed for that specific ergonomic. It cannot be the distro's remote-compute layer: blocking calls, no durable job handles, no TUI, 822s measured cold start. Headless-friendly though: `import clustrix` loads no ipywidgets/IPython and the core dependency closure is 29 packages / 66MB. | MIT |
| OpenClaw | https://github.com/openclaw/openclaw | Architecture reference, do not ship. Borrow three patterns: the loopback-only Gateway reached via SSH tunnel or Tailscale Serve (copy this for any local service on the box), short-lived pairing codes exchanged for durable device tokens, and OpenShell's remote-workspace mode for long-running agents. Adopting the product reintroduces a web Control UI and a large non-coding surface area (browser automation, email, smart home). | MIT |
| awesome-agent-orchestrators | https://github.com/andyrewlee/awesome-agent-orchestrators | Re-check here before committing to any tool in this category. Three major projects died between June 2025 and April 2026 (uzi dead since 2025-06, Crystal deprecated Feb 2026 in favor of the GUI-only Nimbalyst, Vibe Kanban sunsetting Apr 2026) — mortality is high enough that a periodic recheck is warranted. | index |
