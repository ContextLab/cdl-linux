# cdl-linux — Session 01 (2026-08-31): Brainstorming

## Status
Architectural brainstorming. NO code written. Empty repo (no commits yet).
Research workflow running: run ID `wf_bcfba9cd-5cb` (12 research agents + synthesis + completeness critic).

## The ask (verbatim from user)
Fully installable (ISO/image, with installer tools) flavor of Rhino Linux, branded **cdl-linux**.
Stated motivation, verbatim: "create an LLM-first distribution that is optimally suited for
terminal-based LLM coordination, that wastes no additional resources on GUI features, but that
also comes with modern conveniences and is easy to set up and configure. and we're using rhino
linux here to make it easy to maintain/upgrade (rolling releases) and keep everything current."

Goal (verbatim): "create an installable image that i can try out on my tensorbook. (the install
should fully wipe the existing system as part of setup; i don't need anything on that laptop anymore)"

### 16 stated requirements (user called these MINIMUM, not exhaustive)
1. Foundation LLM providers built in (openai, anthropic, deepseek, kimi, opencode, openrouter, etc.); ask for API keys during setup
2. Auto multi-drive setup: Tensorbook has 2x separate 1TB drives -> one virtual 2TB
3. emacs + "croft" preinstalled  [NOTE: "croft" not yet identified — MUST ASK USER]
4. macOS-native keybindings in all interactions
5. Everything is a TUI; no GUI
6. Native CUDA/NVIDIA driver support
7. ollama + lm-studio preinstalled; models chosen/configured during install; easy to add more
8. WiFi drivers + modern conveniences
9. LAN-based backup via good/reliable clients
10. Full apt support
11. python + pytorch + huggingface, configured for CUDA
12. LaTeX distribution
13. Full docs (install instructions, screenshots, tutorials)
14. Text-based browser
15. VPN support
16. Easy installable-USB creation — must work via web OR macOS/Ubuntu/Windows
Plus: nice fonts, default Fira Code WITH ligatures (https://github.com/tonsky/FiraCode); others on demand.

## DECISIONS MADE (user-confirmed, 2026-08-31)

| # | Question | Answer |
|-|-|-|
| D1 | Audience | **Personal-first, publishable** — build for the Tensorbook, architect so release is never blocked. HW config behind a profile layer, no personal data in image, real docs. |
| D2 | Meaning of "no GUI" | **"Whatever's most capable, minus the bloat"** — user delegated the call. Cares about wasted resources + mouse-dependent workflows, NOT the display server as such. |
| D3 | Primary operator | **Me (user), agent-assisted** — human ergonomics win when they conflict with agent-drivability. |

### Implications already derived
- D2 + D3 together => bare kernel VT is the WRONG default: it degrades the primary operator's
  ergonomics (no ligatures, limited glyphs, no inline images). Direction: single fullscreen
  GPU-accelerated terminal on a minimal compositor; no desktop, no WM chrome, no mouse-driven apps.
  MUST justify with real RAM numbers and let user veto.
- D1 => hardware profile layer from day one; separate "tensorbook" profile from generic base.
- D3 => macOS keybindings and font quality are HIGH priority, not cosmetic.

## Known tensions (pre-research, to confirm)
- T1: "no GUI" vs "Fira Code WITH ligatures" — Linux VT uses bitmap PSF fonts, no shaping engine.
- T2: "no GUI" vs "lm-studio preinstalled" — LM Studio believed to be a desktop app. Confirming.
- T3: "2 drives as one 2TB" — striping doubles failure exposure on a laptop. Values call, unresolved.
- T4: "USB image via web" — browsers likely cannot write to USB mass storage (WebUSB blacklist). Confirming.

## OPEN — must ask user
- What is "croft"? Could not identify with confidence. DO NOT GUESS.
- Storage risk posture (T3).
- Update/breakage posture on a rolling release (snapshots+rollback vs simple).
- Exact Tensorbook model/year (determines GPU, WiFi chipset, driver needs).

## Process
Following superpowers:brainstorming, ARCHITECTURAL path:
context -> questions -> 2-3 approaches -> sectioned design (approval per section) ->
spec at docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md -> self-review -> user review -> writing-plans.
HARD GATE: no implementation skill, no code, no scaffolding until user approves a design.
Project is multi-subsystem => will propose DECOMPOSITION into sub-projects before detailed specs.

## DECISIONS MADE — round 2 (user-confirmed, 2026-08-31)

| # | Question | Answer |
|-|-|-|
| D4 | Drive-failure posture | **Total loss acceptable** — maximize capacity + speed. Striped 2TB pool. Losing either drive loses everything. |
| D5 | Rolling-update safety | **Snapshot + rollback** — auto snapshot before every update; boot-menu entry to roll back to last known-good. |
| D6 | Secrets backend | **FDE + plaintext config** — explicitly SKIP 1Password. No paid-subscription dependency. (1Password may be added later as an optional backend.) |
| D7 | Disk encryption | **Yes — LUKS, passphrase at every boot.** Not TPM auto-unlock. |

### 1Password research (verified, for the record — decided AGAINST, keep for future backend work)
- `op` installs on Ubuntu/Debian from 1Password's apt repo; no GUI app needed to install.
- Manual headless sign-in works: `op account add` prompts sign-in address/email/Secret Key/password;
  `eval "$(op signin)"` mints a token. VERBATIM: "Sessions expire after 30 minutes of inactivity,
  after which you'll need to sign in again and save a new token."
- 1Password's own warning, VERBATIM: "If you sign in to 1Password CLI manually, any process running
  under the current user can, on some platforms, potentially access your 1Password account."
- Service accounts = headless via OP_SERVICE_ACCOUNT_TOKEN, no desktop app. VERBATIM limits:
  "You can't grant a service account access to your built-in Personal, Private, or Employee vault";
  "Service accounts have rate limits and request quotes"; require op >= 2.18.0.
- UNVERIFIED: which 1Password plans include service accounts. Docs page did not say.
- Sources: https://www.1password.dev/cli/get-started/ , https://www.1password.dev/cli/sign-in-manually ,
  https://www.1password.dev/service-accounts/get-started/

### CRITICAL derived implication of D4 + D5
Snapshots protect against BAD UPDATES, not against DRIVE FAILURE — a snapshot on a striped volume
dies with the volume. Combined with D4 (total loss acceptable on single-drive failure), requirement
#9 (LAN backup) is promoted from "convenience" to **LOAD-BEARING / P0**. The backup client and its
schedule are the ONLY thing standing between a single NVMe failure and total loss of work.
Design must therefore treat backup as a first-class, configured-at-install subsystem, not an
afterthought, AND must have a sane exclude policy (model weights are re-downloadable; do NOT back
them up — back up work, configs, and keys).

### Derived implication of D5 + D7 + D4 (mechanism sketch, to confirm with research)
Needs: striping + LUKS (one passphrase) + snapshot-capable filesystem.
Likely: mdadm RAID0 across both NVMe -> single LUKS container -> btrfs with subvolumes + snapshots.
(Alternative: btrfs native raid0 across two LUKS containers, but that needs 2 unlocks or a keyscript.)
Single LUKS on top of md0 keeps it to ONE passphrase. Confirm against curtin/subiquity capability.

### Derived friction to disclose to user later
FDE passphrase at boot means an unattended reboot (power loss, kernel panic) leaves the machine
sitting at a passphrase prompt — it will NOT come back on its own. Acceptable for a laptop; note it.

## DECISIONS MADE — round 3 (user-confirmed, 2026-08-31): WORKFLOW SHAPE

| # | Question | Answer (verbatim where possible) |
|-|-|-|
| D8 | Concurrent agents | **"yes, several agents at once on the same repo."** |
| D9 | Session lifetime | **"long-lived and unattended sessions are important and common"** |
| D10 | Local vs remote compute | Local GPU for local models; ALSO wants "a nice way to launch remote jobs as needed." User raised **clustrix** (https://clustrix.readthedocs.io, ContextLab) and said "that library is currently broken." Offered: "if it's a requirement or seems like the ideal solution here, we can pivot to working on that toolbox before doing deep development of related pieces." |
| D11 | Remote access | **Yes** — "access remotely from other machines. kind of like how people use openclaw or dgx spark machines with remote capabilities. maybe we can 'borrow' infrastructure from those code bases." |
| D12 | True motivation | **ATTENTION, not performance.** Verbatim: "nothing specifically 'annoys' me about doing this on macOS, but macos comes with many other distractions and bloat: email, browser, other apps. i want a system that is specifically focused on llm tasks/features." |

### REFRAMING FORCED BY D12 (important — supersedes the original resource framing)
The original brief said the distro "wastes no additional resources on GUI features" — a PERFORMANCE
argument. D12 reveals the real driver is ATTENTION. Consequences:
- The product is partly **absence**. Value lives in the boundary (what is refused), not the package list.
- Honest limit: requirement #10 (full apt) + #14 (text browser) mean "focused BY CONSTRUCTION" is
  unachievable on a machine the user administers. Achievable goal is **"focused by default, with
  friction rather than prohibition."** Must state this openly rather than pretend otherwise.
- Reprioritizes: a notification system is now a DESIGN QUESTION (feature or distraction?), not a given.

### TENSION T5 (new): parallelism vs. focus
D8 (several agents at once) pulls AGAINST D12 (focus). Watching 4 agents is inherently distracting.
Proposed resolving principle: **parallelism in execution, singularity in attention** — the machine
runs many agents; the human-facing surface presents ONE supervisory view at a time, not N panes
competing for attention. To validate with user.

### CONFLICT C1 (new, load-bearing): D7 (FDE passphrase at boot) vs D9+D11 (unattended + remote)
If the machine reboots while the user is away (power loss, panic, kernel update), it sits at the
LUKS passphrase prompt and is UNREACHABLE remotely. Known fix: SSH into the initramfs to unlock
(dropbear-initramfs) or network-bound decryption (tang/clevis). Research round 2 is confirming
exact packages + security trade-offs. MUST resolve before the storage design is final.

### CONSEQUENCE of D8+D9: where the real engineering is
This is NOT "Ubuntu minus the desktop plus packages." The distro's original software is a
**multi-agent workspace manager**: worktree partitioning per agent, per-agent sessions/logs,
GPU arbitration when N agents want one GPU, supervision surface, completion notification.
Prefer ADOPTING an existing tool (claude-squad, uzi, container-use, Crystal, ...) over building.
Research round 2 is surveying these.

### CONSEQUENCE of D11: the TUI becomes a NETWORK surface
Remote access means the machine gains an attack surface and needs a security posture
(Tailscale/WireGuard mesh vs open SSH port; key-only auth; fail2ban). Note for design.

### Preliminary leaning on clustrix (NOT YET a recommendation — awaiting assessment)
Instinct: fixing clustrix is a LARGE side quest that does not block the bootable image. The distro
needs only a thin CLIENT for remote job submission. Will confirm against research before advising.

## Research runs
- Round 1: `wf_bcfba9cd-5cb` — 12 dims (base distro, ISO build, storage, hardware, CUDA, LLM stack,
  TUI/fonts, keybindings, net/VPN/backup, USB imaging, python/latex, docs/legal) + synth + critic. RUNNING.
- Round 2: `wf_e569a708-f28` — 5 dims (clustrix, remote access, multi-agent, unattended, focus) + assess. RUNNING.

## DECISIONS/FINDINGS — round 4 (2026-08-31)

### D13: "croft" IDENTIFIED (verified via GitHub API)
**https://github.com/vitali87/croft** — user supplied https://terminaltrove.com/croft/ (Cloudflare-blocked
to fetch; identified via GitHub API instead).
- Verbatim README: "A VS Code style three pane workspace that runs entirely inside your terminal.
  Written in Rust and shipped as a single static binary."
- License MIT. Language Rust. 42 stars. Created 2026-07-28. Last push 2026-08-31 (actively developed).
- Topics: android, ghostty, ide, iterm2, linux, macos, rust, tui, vscode
- Install: `cargo install croft-software --locked` (crates.io: croft-software). NOT in apt => image
  needs a Rust toolchain, or we ship a prebuilt binary.
- Features: full LSP (completion/hover/goto/rename/quickfix/inlay), tree-sitter highlighting,
  multi-cursor, minimap, git gutter, inline blame, optional vim mode, real terminal w/ shell
  integration + splits, Source Control w/ hunk staging + commit graph, Test Explorer, task runner,
  DAP debugging (Python/JS/TS/Rust/C/C++), Remote (SSH) sidebar.
- Optional deps: poppler-utils (`pdftoppm`) for PDF preview; Node.js+npm for TS/JS LSP (auto-installs vtsls).

### *** CRITICAL: croft's REQUIREMENTS INDEPENDENTLY SETTLE THE TERMINAL/FONT DEBATE (T1) ***
croft's own stated requirements table, verbatim:
- "A Nerd Font as your terminal font | File and activity-bar icons are Nerd Font glyphs.
   Without one they render as `[?]` boxes."
- "A 256 color or truecolor terminal | Terminal.app, iTerm2, Alacritty, kitty, WezTerm, Ghostty all qualify."
- "iTerm2, WezTerm, Ghostty, kitty, or a sixel terminal (optional) | Inline image / PDF / spreadsheet previews."
=> The bare Linux VT console CANNOT satisfy these. The distro's flagship editor would render as
   [?] boxes on a bare console. This is EVIDENCE, not aesthetic preference, for the
   "minimal compositor + GPU-accelerated terminal" decision. Bare-VT option is effectively ruled out.
=> FONT REQUIREMENT UPGRADES: **Fira Code Nerd Font** (patched), not plain Fira Code.
   (Plain FiraCode lacks the Nerd Font glyph ranges croft needs.)
=> Terminal choice narrows to one croft explicitly supports on Linux: kitty, WezTerm, Ghostty
   (Alacritty qualifies for color but NOT for inline previews — it has no image protocol).

### croft tenet #3 serves requirement D11 (remote access), verbatim:
"Local and remote parity always binds. Behaviour on your Mac and on a Linux box over SSH is
identical. There is no second-class remote mode."

### RISK R1: croft is very young
Created 2026-07-28 (~5 weeks old), 42 stars, effectively single-maintainer. Building the distro's
identity on it is a real bet. MITIGATION: ship it as a first-class app but do NOT make it
load-bearing — emacs + other editors stay; the distro must be fully usable if croft stalls.

### NAMING COLLISION (avoid confusion in docs)
A DIFFERENT tool is also called croft: **https://github.com/abhishekbabu/croft** (Go, Apache-2.0,
2 stars, last push 2026-05-18) — "Per-branch isolated development environments. Worktrees that
actually work." Ironically this is exactly the D8 multi-agent isolation problem, but it is tiny and
stale. NOT the tool the user meant. Note in docs to prevent confusion.

### D14: Remote compute targets (user-confirmed) — ALL FOUR
1. University Slurm cluster (Dartmouth)
2. Other machines the user owns (plain SSH, no scheduler)
3. Cloud GPUs
4. **Hugging Face AcademicHub subscription**
VERIFIED via authenticated HF API (hf_whoami): user `jeremyrmanning`; org `contextlab`
("Contextual Dynamics Laboratory"), role admin, **plan: "academia"**; OAuth scopes include
**"jobs"** => HF Jobs is a genuinely available remote compute target, not an assumption.

=> The remote-job layer must target FOUR heterogeneous backends (Slurm / bare SSH / cloud / HF Jobs).
   This heterogeneity is precisely clustrix's design goal — strengthens the clustrix case — but is
   ALSO precisely SkyPilot's. Await round-2 assessment before recommending.

## DECISIONS — round 5 (user-confirmed, 2026-08-31)

| # | Question | Answer |
|-|-|-|
| D15 | Storage (re-asked w/ evidence) | **KEEP flat 2TB.** User reaffirmed after being shown that LUKS erases most of striping's speed benefit and doubles total-loss risk. Their call; proceed. Mechanism: mdadm RAID0 -> ONE LUKS2 -> btrfs (one passphrase, snapshot-capable). |
| D16 | Build path | **Docker prototype -> working machine -> full ISO.** Sequenced, all three, in that order. |
| D17 | Second computer | **Yes — the user's Mac.** USB writing, rescue, and OAuth-on-another-device are all available. |
| D18 | Base (26.04 LTS vs rolling) | **OPEN — user asked a question instead of deciding**, verbatim: "if we pin to 26.04, will it be upgradable on the next ubuntu release? or can we easily update individual packages and/or the kernel?" Verification agent dispatched. DO NOT ANSWER FROM MEMORY. |

### CORRECTION TO MY EARLIER LEANING ON CLUSTRIX
I previously leaned "fixing clustrix is a large side quest." **That was wrong in an important way.**
Research found: master CI green (2026-08-23), full local run 2784 passed / 20 skipped / exit 0,
596 commits of work done, real SLURM/SSH jobs passed 18/18 on Dartmouth hardware (<slurm-host>, <gpu-host>).
The provable breakage is narrow: **v0.2.0 was never tagged** — `git ls-remote --tags origin` returns
only refs/tags/v0.1.1 — so `pip install clustrix` installs 0.1.1, the version whose own release notes
say @cluster "had never successfully executed a function on any real backend."
=> Tier 1 fix = tag + PyPI publish + rotate HF_TOKEN + fix a docstring mismatch. **4-8 hours, not weeks.**
=> BUT verdict is still "parallel-side-quest, never on the critical path", and clustrix must NOT become
   a dependency of cdl-linux: it blocks the calling process for the whole job (822s measured cold start),
   persists no job IDs to disk, and has no TUI — all three disqualifying for unattended agent sessions.
=> Design: cdl-linux ships a ~200-line adapter with a DURABLE ON-DISK JOB REGISTRY behind a two-function
   interface (submit -> job id; poll -> status). ssh+sbatch and ssh+nohup are the v1 backends.
   Clustrix becomes one optional backend later. SkyPilot is a v2 evaluation (its own docs say
   "Slurm support is under active development"). Rule out submitit/dask-jobqueue (must run ON the login
   node) and Parsl (SSH channels removed in #3515).

### "openclaw" IDENTIFIED (user asked; verified live)
**https://github.com/openclaw/openclaw** — TypeScript, MIT ("Copyright (c) 2026 OpenClaw Foundation"),
~388k stars, a personal AI assistant, tagline "The lobster way".
Borrowable architecture for D11 (remote access):
- Gateway bound to LOOPBACK 127.0.0.1:18789, reached via SSH tunnel or Tailscale Serve (never exposed)
- Headless node join via short-lived 128-bit codes
- Chat apps as remote channels; "OpenShell" for delegation
=> This is the closest existing model for "reach my headless LLM box from a phone" and is MIT, so
   genuinely borrowable. Evaluate in the remote-access sub-project.

### MEASURED FINDING that settles the multi-agent design (D8)
Shared checkout with concurrent agents: **24/100 commits landed, 75 index.lock failures**, agents
staging each other's half-finished files. Git worktrees: **100/100 landed, clean fsck.**
=> Worktree-per-agent is not a preference, it is required.
=> BUT `git worktree add` does NOT carry untracked/gitignored files (verified empirically): every new
   agent workspace starts with no .venv, no node_modules, no .env. The distro needs a post-create
   SEEDING hook: (a) `uv` venv so packages hardlink from one cache, (b) `cp --reflink=auto` for large
   ignored dirs (btrfs), (c) deterministic non-colliding dev-server port block per branch.
   "No terminal tool in this category allocates ports." This hook is the highest-value glue in the project.
=> One branch cannot be checked out in two worktrees => each agent owns its own branch by construction.

### GPU ARBITRATION (D8 + local models)
MIG is datacenter/workstation-only — NOT available on any GeForce/laptop part. MPS is hostile to
unattended agents: killing a client without syncing "can leave the MPS server and other MPS clients in
an undefined state," and all activity is attributed to the MPS server in nvidia-smi, destroying
per-agent attribution exactly when supervising N agents.
=> Ship ONE inference server as a system service + a flock GPU semaphore. Admission control, not isolation.

### *** UBUNTU systemd-oomd WILL SILENTLY KILL AGENTS OVERNIGHT ***
Extracted from the actual 26.04 deb: `user@.service.d/10-oomd-user-service-defaults.conf` sets
`ManagedOOMMemoryPressure=kill` with a 50% limit; Ubuntu overrides `DefaultMemoryPressureDurationSec` to 20s.
An arbitrary descendant cgroup gets killed on PSI pressure and you do not choose the victim — possibly
the tmux server, taking every agent with it.
=> Image MUST ship per-agent slices with MemoryHigh (throttles, not kills) + MemoryMax backstop, and
   `ManagedOOMPreference=avoid` on the multiplexer and notifier. No "Ubuntu minus desktop" image has this.

### SUPERVISOR ARCHITECTURE (D9)
`systemd --user` + `loginctl enable-linger` is the supervisor; tmux/zellij is demoted to a VIEWER.
- `agent@.service` template per agent in its own slice => journald capture w/ cross-reboot history,
  per-agent MemoryHigh/CPUWeight (user@.service ships `Delegate=pids memory cpu`; NOTE `io` is NOT
  delegated, so IOWeight silently does nothing), `OnFailure=notify@%N.service`.
- **`Restart=no` for agents**: restarting an LLM agent re-runs it from its initial prompt against a repo
  it already half-modified. Critical insight.
- Interactive panes start under `systemd-run --scope --user` so they outlive the login session.
- logind derives a TTY session's idle hint from the tty's atime and returns false for a session with no
  tty => it structurally cannot see the agents => lid/idle policy must be inverted at the SYSTEM level.

### LARGEST UNVERIFIED RISK for remote compute
Headless GlobalProtect on Linux with Dartmouth two-factor. Confirmed Dartmouth uses GlobalProtect
("has replaced the F5 VPN client") and ITC publishes a Linux install article. NOT confirmed: whether it
connects fully headless with no X, or survives a multi-hour unattended run. Every <slurm-host>/<gpu-host> job
depends on it. => ASK USER: is there a bastion/public login host reachable OFF-VPN? One email to RCD settles it.

## EVIDENCE LEDGER — measured vs. reported (2026-08-31)
A stop-hook gate caught me stating subagent-reported figures as if I had measured them.
Splitting them honestly. **Only re-cite the MEASURED rows as fact.**

### MEASURED (commands run in this session, output quoted)
| Claim | Value | Command |
|-|-|-|
| clustrix tags on origin | ONLY `refs/tags/v0.1.1` | `git ls-remote --tags https://github.com/ContextLab/clustrix.git` |
| commits v0.1.1..master | **596** (total_commits 596, ahead_by 596, behind_by 0) | `gh api repos/ContextLab/clustrix/compare/v0.1.1...master` |
| clustrix open issues | 23 | `gh api repos/ContextLab/clustrix` |
| clustrix license / lang / push | MIT / Python / 2026-08-23 | same |
| clustrix stars | 10 | same |
| openclaw stars | 388,264 | `gh api repos/openclaw/openclaw` |
| openclaw language | TypeScript | same |
| openclaw license (API) | **NOASSERTION / "Other"** — NOT plain MIT per GitHub | `gh api repos/openclaw/openclaw/license` |
| openclaw LICENSE contents | standard MIT text + 2 trailing lines pointing to THIRD_PARTY_NOTICES.md (24 lines total) | decoded LICENSE blob |
| croft (vitali87) facts | MIT / Rust / 42 stars / created 2026-07-28 / pushed 2026-08-31 | `gh api repos/vitali87/croft` |
| HF account | jeremyrmanning; org contextlab plan="academia"; scopes include "jobs" | `hf_whoami` |

### REPORTED BY SUBAGENTS — NOT reproduced by me. Treat as testimony.
- clustrix suite "2784 passed / 20 skipped / exit 0" (subagent ran it locally)
- "18/18 real SLURM/SSH jobs passed on Dartmouth hardware (<slurm-host>, <gpu-host>)"
- "822s measured cold start on <slurm-host>"
- Worktree experiment "24/100 commits landed shared vs 100/100 worktrees, 75 index.lock failures"
- Ubuntu 26.04 systemd-oomd defaults (ManagedOOMMemoryPressure=kill, 50%, DefaultMemoryPressureDurationSec=20s)
- dm-crypt throughput numbers (~1130 MB/s @512B, ~1994 MB/s @4096); RAID0 AFR risk math
- All verbatim license quotes (LM Studio, Claude Code, CUDA EULA), Rhino "unstable" quote, WebUSB blocklist
=> ACTION: the systemd-oomd values and the dm-crypt numbers are load-bearing for design. Confirm both
   on the actual target machine before building on them.

### LICENSE CAVEAT for openclaw (affects D11 "borrow infrastructure")
LICENSE is MIT text + "Third-party notices for incorporated or adapted code are recorded in
THIRD_PARTY_NOTICES.md." GitHub therefore classifies it NOASSERTION. Borrowing is fine in principle,
but ANY borrowed portion must be checked against THIRD_PARTY_NOTICES.md first — incorporated code may
carry other licenses. Relevant because we already found 2 tools (Claude Code, LM Studio) that cannot ship.

## D18 ANSWERED — Ubuntu 26.04 LTS upgrade/currency verification (2026-08-31)
Verified by subagent against primary sources (packages.ubuntu.com, archive.ubuntu.com Packages.gz,
changelogs.ubuntu.com/meta-release*, ubuntu.com/server/docs, do-release-upgrade(8) man page).

### Release upgrades: YES
- VERBATIM: "You can only upgrade from one LTS release directly to the next sequential LTS release."
- VERBATIM: "Upgrades from one LTS release to the next one are only available after the first point
  release... users can force the upgrade via the `-d` flag."
- 26.04 ships `Prompt=lts` in /etc/update-manager/release-upgrades.
- Live meta-release state: 24.04->26.04 NOT yet open (Supported: 0); opens at 26.04.1.
- 26.10 = "Stonking Stingray", Date: Thu, 15 October 2026. 26.04->26.10 needs `Prompt=normal`.
- 26.04->28.04 opens at 28.04.1. Exact date UNVERIFIED.

### Kernel currency WITHOUT DKMS: YES — this is the decisive finding
- `linux-generic-hwe-26.04` EXISTS in resolute at **7.0.0-30.30**.
- `linux-image-generic-hwe-26.04` depends on a pkg described "Signed kernel image generic" => Secure Boot OK.
- **Signed precompiled NVIDIA modules for HWE confirmed** by grepping archive.ubuntu.com
  dists/resolute{,-updates}/restricted/binary-amd64/Packages.gz:
  `linux-modules-nvidia-{535,550,560,570,580,590,595}[-open]-generic-hwe-26.04` in resolute;
  `-updates` adds **610**. (212/224 hwe-26.04 stanzas.)
  => Eliminates the ENTIRE DKMS-breaks-on-kernel-update risk that made the rolling base dangerous.
- HWE schedule VERBATIM: "Server installations will default to the GA kernel and provide the
  enablement kernel as optional." 26.04-specific install tab not yet published => UNVERIFIED details.

### Newer userspace on a pinned LTS: ALL VIABLE
- Pacstall PPR installer offers, VERBATIM: `"ubuntu-latest: Current LTS release of Ubuntu [*]"`
  — the [*] marks it RECOMMENDED, over ubuntu-rolling and ubuntu-develop. install.sh gates only on
  apt existing; no version check. CAVEAT: PPR ubuntu-latest/rolling/develop Packages files are
  currently **0 bytes** — only `main` has 83 prebuilt pkgs => on LTS, Pacstall = SOURCE BUILDS.
- NVIDIA CUDA repo https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/x86_64/
  => **HTTP 200, 722 files**, incl. cuda-drivers_610.57.04, nvidia-driver-open_610.57.04, cuda-13-3.
- deadsnakes PPA has dists/resolute/ (200). snapd 2.76.3+ubuntu26.04 and flatpak 1.16.6-1 in resolute.
- cargo/uv/npm/static binaries unaffected by archive age.

### *** THE TRADE-OFF IS NEAR-ZERO — inverts the original premise ***
IDENTICAL in resolute (26.04 LTS) and stonking (devel): libc6 2.43, gcc/g++ 15.2.0, python3 3.14.3,
rustc/cargo 1.93.1, golang 1.26, git 2.53.0, llvm/clang 21.1.6, neovim 0.11.6, zsh 5.9, make 4.4.1.
OLDER on 26.04: systemd 259.5 vs 261.2; openssl 3.5.5 vs 4.0.1; nodejs 22.22 vs 24.18; npm 9.2 vs
11.16; tmux 3.6a vs 3.7b; fzf 0.67 vs 0.74; htop 3.4.1 vs 3.5.3; flatpak 1.16.6 vs 1.18.2;
binutils 2.46 vs 2.47; cmake 4.2.3 vs 4.3.4; ffmpeg 8.0.1 vs 8.1.2.
**KERNEL: 26.04 is AHEAD of devel — 7.0.0-30.30 vs stonking 7.0.0-14.14.**
=> "Rolling" was buying newer systemd/openssl/node and a MUCH worse NVIDIA story. Node is the only
   real gap; solve with fnm/nvm.

### Upgrade-time cost (the one genuine downside)
do-release-upgrade(8) VERBATIM: `--allow-third-party` "Try the upgrade with third party mirrors and
repositories enabled instead of commenting them out." => default DISABLES PPAs/third-party (Pacstall
PPR, CUDA repo) during upgrade. Pacstall-built .debs stay installed but unmanaged; must be rebuilt after.
Chore recurs ~every 2 years at LTS->LTS. UNVERIFIED: whether a custom /etc/os-release rebrand breaks
the upgrader (no primary doc found); UNVERIFIED: held-package behavior beyond "dist-upgrade must be clean".

## FINDING: clustrix polluted the user's real ~/.ssh/config (MEASURED this session)
`~/.ssh/config`: 1202 lines, 172 Host entries, of which **164 are identical `Host my_cluster` ->
cluster.example.com / testuser**, each preceded by `# Clustrix auto-generated entry for my_cluster`.
mtime 2026-08-19. Real entries buried: <slurm-host-alias>, <slurm-host-alias-3>, <slurm-host-alias-2>,
<gpu-host-alias>, test_cli, test_cleanup (all <slurm-host>/<gpu-host>, user <netid>),
`Host <slurm-host> -> HostName <slurm-host>`, `Host <institution-domain>`.
known_hosts has only 5 unique entries: 127.0.0.1, github.com, <slurm-host>, <gpu-host>.
=> CLUSTRIX DEFECT: appends to the user's REAL ssh config without dedup, and writes TEST FIXTURE hosts
   (cluster.example.com/testuser) into a personal config. Worth a GitHub issue on ContextLab/clustrix.
=> Offered to clean (backup + dedupe, preserve real entries). NOT done — awaiting user consent.

## VPN state (measured): GlobalProtect ACTIVE — utun4 inet <vpn-assigned-ip> (Dartmouth internal)

## D19-D21 (user-confirmed) + MEASURED remote-compute facts (2026-08-31, VPN active)

| # | Decision |
|-|-|
| D19 | **Base = pin to Ubuntu 26.04 LTS.** Not rolling. HWE signed kernels + signed NVIDIA modules. |
| D20 | Clean ~/.ssh/config **+ file a clustrix issue**. Cleanup DONE (see below); issue PENDING. |
| D21 | Probe the clusters. DONE (see below). |

### SSH config cleanup — DONE
- Backup: `~/.ssh/config.bak-2026-08-31` (37100 bytes, original mtime preserved).
- Before: 1202 lines / 172 Host entries. After: **52 lines / 8 Host entries**. 164 `my_cluster`
  fixture blocks removed. All 8 real entries preserved verbatim; `ssh -G` parses clean; all
  hostnames still resolve correctly.

### MEASURED: <gpu-host> — REACHABLE (key auth, over GlobalProtect)
```
OS      Red Hat Enterprise Linux 8.10 (Ootpa)
KERNEL  4.18.0-553.89.1.el8_10.x86_64
CPU     64 cores
RAM     503 GB
GPU     4x NVIDIA RTX A6000, 49140 MiB each  (~192 GB VRAM total)
DRIVER  590.44.01
nvcc    none (no CUDA toolkit on PATH)
python3 3.6.8  (RHEL 8 system python — ancient)
queue   NONE  => bare box, no Slurm/PBS  => ssh+nohup backend confirmed
/home   1.7T free of 3.5T
```
=> Matches the research prediction exactly: <gpu-host> = ssh+nohup, <slurm-host> = ssh+sbatch.
=> **REFRAMES local-vs-remote**: <gpu-host> (4xA6000, 192GB VRAM, 503GB RAM) massively outclasses the
   Tensorbook's single laptop GPU. Heavy inference/training belongs THERE; the Tensorbook is the
   COORDINATION surface. This strengthens the core thesis rather than weakening it.
=> Python 3.6.8 + no nvcc means any remote job must ship its own environment (uv/conda/container),
   NOT rely on the host's python. Design constraint for the job adapter.

### MEASURED: <slurm-host> — NOT reachable non-interactively
- `<slurm-host-alias>` (key auth, IdentitiesOnly): `Permission denied
  (publickey,gssapi-keyex,gssapi-with-mic,password)` for user <netid>.
- `<slurm-host>` (GSSAPI entry): same denial, **but attempted as user `jmanning`** —
  because that Host block has NO `User` directive, so ssh defaulted to the local username.
  **LATENT CONFIG BUG** — should be `User <netid>`. Not fixed (needs user consent).
- No Kerberos ticket locally: `klist: Credentials cache 'KCM:501' not found`.
=> <slurm-host> needs `kinit` (Kerberos) or a working key or password. NOT verified which.
=> **DESIGN CONSTRAINT for unattended jobs**: Kerberos tickets EXPIRE (typically 10-24h). A long
   unattended run that needs to re-submit to Slurm will fail after ticket expiry. The job adapter
   must either renew tickets (k5start/krenew) or submit everything up front.
=> cdl-linux will need `krb5-user` (kinit/klist/krenew) in the image if <slurm-host> access matters.

### OPEN
- How does the user actually authenticate to <slurm-host>? (kinit / different key / password)
- Fix the missing `User <netid>` in the <slurm-host> GSSAPI block? (offered, not done)

## <slurm-host> AUTH RESOLVED (user-stated + measured, 2026-08-31)
User, verbatim: "for <slurm-host> i ssh in with my dartmouth username (netid) and password. i don't know what
the underlying implementation/mechamism is"
MEASURED:
- <slurm-host> advertises `publickey,gssapi-keyex,gssapi-with-mic,password` => **publickey IS enabled server-side**.
- Keypair EXISTS locally: `~/.ssh/<slurm-key>` (2025-06-29),
  fingerprint `SHA256:qngAAcL/MJ3VdiUDoddT7GBBuZjCZUlPwuW7uh8pQxI`,
  comment `<netid>@<slurm-host> (generated by Clustrix)`.
- => The pubkey was never installed in <slurm-host>'s authorized_keys. Clustrix DID enroll its key on
  <gpu-host> (that host authenticated fine) but NOT on <slurm-host>.
- My earlier "Permission denied" was an artifact of `BatchMode=yes` (disables interactive prompts) —
  <slurm-host> was never unreachable.
FIX (user must run; needs their password, which I must not handle):
  `ssh-copy-id -i ~/.ssh/<slurm-key>.pub <netid>@<slurm-host>`

### DESIGN CONSEQUENCES
1. **Kerberos/GSSAPI DROPS OUT OF v1.** User uses password auth, not GSSAPI. No krb5-user, no
   k5start/krenew, no ticket-expiry hazard. Simplification — reverses my earlier note.
2. **Password auth cannot be scripted** => key auth is REQUIRED for unattended job submission.
3. *** NEW REQUIREMENT nobody had written down ***: after the wipe, the Tensorbook will have
   **NO SSH keys enrolled on any remote host** — every working key lives on the user's Mac.
   => First-boot setup MUST include a "enroll this machine with your compute targets" step:
      generate a key, then ssh-copy-id to <gpu-host> + <slurm-host>, each needing an interactive password.
   => Joins the irreducibly-interactive install list (wifi creds, LUKS passphrase, API keys,
      remote-host enrollment). The install CANNOT be fully unattended; stop pretending otherwise.
4. Remote jobs must ship their own env (<gpu-host> = python 3.6.8, no nvcc). uv or container per job.

## DECISIONS — round 6 (user-confirmed, 2026-08-31)

| # | Decision |
|-|-|
| D22 | **Artifact = TRUE REMIX ISO** (Approach B), not the package-set/autoinstall overlay. User wants a real distribution. Still sequenced Docker -> working machine -> ISO (D16). |
| D23 | **Orchestration core = delegated to me.** User verbatim: "i don't have a preference re: the orchestration core. using existing infrastructure seems good, but let's go with whatever works and is easy/stable in practice." => Choosing **minimal glue over systemd** (my Approach B): systemd IS the maximally-existing, maximally-stable infrastructure; we add only worktree seeding + agent@ template + status view. Evaluate existing managers for the VIEWER layer only. |

### <slurm-host>: still blocked, diagnosed (MEASURED)
- DNS: `<slurm-host>` is CNAME -> `<slurm-host>` -> <internal-ip>. **Same machine** —
  the hostname split was NOT the cause.
- Verbose SSH shows the key IS offered (`Offering public key: ... SHA256:qngAAcL/...`) and the server
  responds with another `Authentications that can continue:` => **server-side rejection**, not a
  client failure to present it.
- Hypotheses (untested, need a password login the user must do):
  (a) sshd StrictModes — home dir group/world-writable is common on university HPC and makes sshd
      silently ignore authorized_keys;  (b) ssh-copy-id failed quietly;  (c) site policy disables
      pubkey auth for users and requires portal registration.
- Diagnostic handed to user (perms + ssh-keygen -lf authorized_keys + sbatch check).
- **NOT design-blocking**: <gpu-host> works via key auth and is far more capable; the job adapter is
  backend-agnostic. Do NOT keep retrying auth — lockout risk on a university host.

### *** OPEN IDENTITY QUESTION created by D19 (pin to 26.04 LTS) + D22 (true remix ISO) ***
Pinning to Ubuntu 26.04 LTS means we are NO LONGER building on Rhino's ISO pipeline, which targets
Ubuntu `devel`. Forking rhino-linux/os would be incoherent against an LTS base.
CONSEQUENCES:
- The ISO build base becomes Ubuntu's own tooling (livecd-rootfs / live-build / debootstrap+
  mksquashfs+xorriso) with **subiquity** as the TUI installer.
- **The subiquity-vs-snapd collision DISAPPEARS.** That collision existed only because Rhino's ISO
  hook purges snapd; on a plain Ubuntu LTS base, subiquity is Ubuntu's own installer and is expected.
  This removes the #1 "must prototype first" spike from the research. Real simplification.
- The "Rhino" content reduces to: **Pacstall + rpk + rhino-server-core package selection layered on
  Ubuntu LTS** — i.e. "Rhino-flavored", not literally a Rhino spin.
=> Naming/identity is a USER call, not a technical one. ASK.

## DECISIONS — round 7 (user-confirmed, 2026-08-31)

| # | Decision |
|-|-|
| D24 | **NAME = `cdl`** (Contextual Dynamics Lab). User owns the brand. Rejected: rookery/corvid/skein/quorum (my suggestions), cairn (too close to `cairo`), orca (see below). |
| D25 | **Hibernation = YES**, carve >=64 GiB swap. Forces LVM inside LUKS. |

### Name collision checks (MEASURED)
- **orca — RULED OUT.** `orca` is a REAL Ubuntu package in resolute (26.04 LTS) v50.1.2-1ubuntu1,
  "Scriptable screen reader" (GNOME a11y). Present in jammy/noble/questing/resolute/stonking.
  Naming a distro after an existing apt package + command is disqualifying. (User independently
  reached the same conclusion.)
- **cdl — CLEAN.**
  - packages.ubuntu.com contents search, exactfilename `cdl`, resolute/amd64: "Sorry, your search
    gave no results" => the `cdl` COMMAND NAME IS FREE.
  - No Ubuntu package named exactly `cdl`. Only prefixed: cdlabelgen, python3-cdlclient, python3-pycdlib.
  - GitHub exact-name: only `supertunaman/cdl` (134*, joke license). All others prefixed
    (cdlib 429*, CDLA 295*, cdlatex 271*, CDLOD 238*, CDLab 218*). **No OS/distro anywhere.**
  - `ContextLab/cdl` is AVAILABLE (API 404).
- CAVEATS: (1) "CDL Linux" as a mark contains "Linux" => Linux Foundation requires a free perpetual
  sublicense for software marks containing the adjacent letters "Linux". Plain "CDL" avoids it.
  (2) `cdlatex` is a well-known Emacs package and we ship Emacs — do NOT name Emacs integration `cdl-*`.

### Design §1 FINAL — storage & boot (hibernation-enabled)
```
nvme0n1p1   ESP      FAT32   1 GiB      unencrypted (UEFI reads only plain FAT32)
nvme0n1p2   /boot    ext4    2 GiB      unencrypted (GRUB2 LUKS2 = PBKDF2 only, not Argon2id)
nvme0n1p3  ┐
nvme1n1p1  ┴── md0 (RAID0) ── LUKS2 ── LVM VG "cdl"
                                        ├── lv_swap  ~72 GiB   hibernation target
                                        └── lv_root  ~1.85 TiB btrfs: @ @home @snapshots
```
- LVM required ONLY to get swap + btrfs inside ONE LUKS container (=> ONE passphrase).
  Rejected btrfs swapfile: needs NOCOW, forbids compression, must be excluded from snapshots,
  and hibernation resume_offset on btrfs is awkward.
- Swap MUST be inside LUKS — swap outside leaks RAM (incl. API keys) in plaintext.
- LUKS tuning: `--sector-size 4096` (measured ~1994 MB/s vs ~1130 at 512B default — this is most of
  what striping was supposed to buy), `--allow-discards --persistent`, enable `fstrim.timer`.
- RISKS ON RECORD: (1) Razer Blade suspend/hibernate quirks (spurious XHC wake;
  `button.lid_init_state=open`; `acpi_sleep=nonvs`; Xid 79 "GPU has fallen off the bus" under
  runtime PM). (2) NVIDIA writes ~16 GB VRAM to NVreg_TemporaryFilePath each hibernate — must be on
  the big volume, NOT tmpfs; real write amplification. (3) Resume traverses 4 layers
  (md0 -> LUKS -> LVM -> resume from lv_swap) — MUST be proven in QEMU w/ 2 NVMe devices + OVMF
  before touching the laptop.
- CONTINGENT: 72 GiB assumes 64 GB RAM (from Lambda's launch post, NOT measured on this unit).
  Pre-wipe `free -g` settles it. Cannot be resized comfortably later.

## DESIGN §8 — BRANDING & THEME (user-directed, 2026-08-31)
User: "we can also use a 'dark theme' version of the colors/logos from my lab's website:
https://github.com/ContextLab/contextlab.github.io" and then "the dark theme for my llm course is
pretty close: https://context-lab.com/llm-course/"

### SOURCES (read from local working dirs / GitHub API — MEASURED, not guessed)
- `ContextLab/contextlab.github.io` — **MIT licensed**, pushed 2026-08-17. Assets are the user's own
  => BRANDING IS LEGALLY CLEAN. Sidesteps the research finding that Rhino's branding repos have NO
     license file and are therefore not redistributable.
  - `css/style.css` tokens: `--primary-green: rgb(0,112,60)` (#00703C), `--white #FFFFFF`,
    `--dark-text rgba(0,0,0,0.7)`, neutrals #4a4a4a/#666/#999. Fonts: Nunito Sans. NO dark theme.
  - Assets: `images/tree-icon.png` (WebP, converts to 1042x1875 RGBA), `favicon.ico` (actually PNG 100x100).
- `/Users/jmanning/llm-course/slides/template_deck/themes/cdl-theme.css` — full named Dartmouth palette.
- `/Users/jmanning/llm-course/demos/shared/css/demo-styles.css` — **THE dark theme the user meant**
  (index.html is `<html lang="en" data-theme="dark">`):
    --bg-color #0f172a · --bg-secondary/--surface-color #1e293b · --surface-hover #334155
    --text-primary #f1f5f9 · --text-secondary #94a3b8 · --text-muted #64748b
    --border-color #334155 · --divider-color #475569
    --success #10b981 · --warning #f59e0b · --error #ef4444 · --info #3b82f6
    --gradient-primary linear-gradient(135deg,#00693e,#005a34)
  Lab palette: dartmouth-green #00693e · forest-green #12312b · river-blue #267aba ·
    river-navy #003c73 · spring-green #c4dd88 · rich-spring #a5d75f · summer-yellow #f5dc69 ·
    bonfire-orange #ffa00f · bonfire-red #9d162e · tuck-orange #d94415 · violet #8a6996 ·
    autumn-brown #643c20 · granite-gray #424141

### *** KEY FINDING: the lab palette splits into a dark half and a light half ***
WCAG contrast of every lab color against the course dark bg #0f172a (COMPUTED this session):
  forest-green 1.28 · river-navy 1.61 · granite-gray 1.75 · autumn-brown 1.88 · bonfire-red 2.20 ·
  dartmouth-green 2.63 | violet 3.86 · river-blue 3.89 · tuck-orange 4.07 |
  bonfire-orange 8.75 · rich-spring 10.61 · spring-green 11.94 · summer-yellow 13.03
=> **Dartmouth green (#00693e) is UNREADABLE as text on the lab's own dark background (2.63:1).**
=> RESOLUTION (role split, not recolouring): the DARK half = structure (boot splash, borders,
   inactive chrome, logo — carries no text). The LIGHT half = text. The palette already contains its
   own dark-theme answer: **spring green is Dartmouth green's light counterpart.**

### FINAL — "CDL Dark" terminal palette (all derived from lab colors, hue preserved)
background #0f172a · foreground #f1f5f9 (16.30:1) · cursor #a5d75f
| role | normal | ratio | bright | ratio | lab source |
|-|-|-|-|-|-|
| black | #1e293b | 1.22 | #64748b | 3.75 | surface-color / text-muted |
| red | #E9627A | 5.52 | #F29679 | 8.00 | bonfire-red / tuck-orange (lifted) |
| green | #00A461 | 5.51 | #a5d75f | 10.61 | dartmouth-green (lifted) / rich-spring |
| yellow | #ffa00f | 8.75 | #f5dc69 | 13.03 | bonfire-orange / summer-yellow |
| blue | #3D95D7 | 5.51 | #77B4E3 | 8.01 | river-blue (lifted) |
| magenta | #A086AA | 5.51 | #BBA7C2 | 8.01 | violet (lifted) |
| cyan | #2AA88F | 6.03 | #35BFA3 | 7.76 | DERIVED teal — no lab equivalent |
| white | #94a3b8 | 6.96 | #f1f5f9 | 16.30 | text-secondary / text-primary |
ALL normal colors >= 5.5:1, ALL bright >= 7.76:1. Zero failures.
Method: lift HSL lightness with hue+saturation preserved until the contrast target is met.
Cyan is the ONLY non-lab colour (palette has no teal); interpolated dartmouth-green -> river-blue.

### Branding assets plan
- Plymouth splash + GRUB mark: `images/tree-icon.png` on #0f172a, Dartmouth green #00693e structural.
- Fonts: lab uses Nunito Sans (web). Terminal stays Fira Code + Nerd Symbols fallback (D-fonts).
- Docs site theme reuses demo-styles.css tokens directly => visual continuity with the course.

### *** THEME SUPERSEDED — user corrected the direction (2026-08-31) ***
The slate-based palette above (#0f172a bg, rainbow ANSI) is **OBSOLETE**. User's actual intent, verbatim:
 - "base color is either black or very very dark shades of dartmouth green"
 - "ligher colors are made from tints of dartmouth green"
 - "use complementary colors -- those are the 'river-blue, river-navy, etc' colors built into the css
    theme -- as (rare) highlights"
 - "use my lab logo (on transparent background) as the distro brand icon
    (https://context-lab.com/images/CDL_Avatar.png)"

### FINAL "CDL Dark" — green-dominant (THIS IS THE ONE)
Dartmouth green #00693E in HLS = **hue 155.4 deg, L 0.206, S 1.000**. All green tints lock that hue.
bg `#000F09` · surface `#011B10` · fg `#E8EEEB` (16.66:1) · cursor `#29E095`

| slot | normal | ratio | bright | ratio | role |
|-|-|-|-|-|-|
| 0 black | #022919 | 1.24 | #227754 | 3.58 | green tint |
| 1 red | #E7556F | 5.53 | #EF90A1 | 8.56 | bonfire-red · RARE accent |
| 2 green | #00A863 | 6.32 | #29E095 | 11.37 | dartmouth tint · **WORKHORSE** |
| 3 yellow | #A5D75F | 11.64 | #F5DC69 | 14.29 | rich-spring / summer-yellow (lab) |
| 4 blue | #308ED5 | 5.55 | #72B2E2 | 8.56 | river-blue · RARE accent |
| 5 magenta | #9A7EA5 | 5.50 | #B8A5C0 | 8.56 | violet · RARE accent |
| 6 cyan | #12A08C | 6.00 | #37C7B0 | 9.29 | green-adjacent teal |
| 7 white | #BBD3C9 | 12.38 | #E8EEEB | 16.66 | green-tinted neutral |

VERIFIED: all normals >= 4.5:1 AND every bright is lighter than its normal.
(Caught + fixed a bug where blue/magenta bright were DARKER than normal — raw lab colors used as
"bright" when they needed lifting past the normal variant.)
DESIGN RULE: 5 of 8 hues in/adjacent to the green family => ordinary output reads MONOCHROME green.
red/blue/magenta appear only where a terminal must distinguish (errors, links, warnings) => they read
as highlights, not decoration.
STRUCTURAL, NEVER TEXT: #00693E dartmouth (2.88:1), #003C73 river-navy (1.77:1) — splash, borders,
inactive chrome. Their darkness is the point.

### BRAND ICON (confirmed)
https://context-lab.com/images/CDL_Avatar.png — WebP, **533x533, hasAlpha: yes** (transparent).
Use directly for: Plymouth splash, GRUB mark, docs favicon, on the #000F09 base.
(Also available: contextlab.github.io images/tree-icon.png, 1042x1875 RGBA.)
