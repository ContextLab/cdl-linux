# CDL Linux — Product and Architecture Overview

**Status:** Draft for detailed review · **Revision:** 2 · **Date:** 2026-08-31 · **Repo:** `ContextLab/cdl-linux`

A focused coordination appliance for supervising concurrent LLM agent work, delivered as an
installable Linux distribution.

> **What this document is.** The product thesis, scope boundary, decision record, threat model,
> milestone plan, and requirement traceability matrix.
>
> **What it is not.** It contains no implementation mechanism. State machines, interfaces, failure
> behaviour and acceptance tests live in the four component specifications listed in §7. If you are
> looking for *how* something works, this is the wrong document — §7 says which one to open.
>
> **Revision 2 changes:** narrowed v1 and made milestones explicit (§2, §6); split mechanism into
> four component specs (§7); added a threat model (§5), a traceability matrix (§10), and risk spikes
> (§9); recorded six new decisions (§3, D26–D31); corrected four claims that were wrong or
> overstated (§17.3).

---

## 1. Product thesis

### 1.1 What this is

A fully installable Linux distribution whose purpose is **coordinating LLM agents from a terminal**.
The first target is a Lambda Tensorbook that will be fully wiped on install.

The sharper statement of the same idea, and the one that should drive design conflicts:

> **This is not "Ubuntu without a desktop." It is a focused coordination appliance for supervising
> concurrent agent work.**

That framing is what makes the project differentiated rather than subtractive. Attention-first
design, worktree isolation, durable supervision, off-machine backup and terminal-as-primary-interface
all reinforce it. Anything that does not reinforce it is a candidate for deferral.

### 1.2 The motivating claim

The original brief argued the GUI is a *resource* cost — "wastes no additional resources on GUI
features." Clarification during design revealed the real driver is **attention**:

> "nothing specifically 'annoys' me about doing this on macOS, but macos comes with many other
> distractions and bloat: email, browser, other apps. i want a system that is specifically focused on
> llm tasks/features."

This reframing is load-bearing. A resource-first distro is defined by its package list. An
attention-first distro is defined by its **boundary** — what it refuses to do. The lean package list
is a consequence, not the goal.

### 1.3 Honest limit on the boundary

**"Focused by construction" is unachievable and this spec does not claim it.** The system provides
full `apt` and a text browser; between them, anything can be installed and the whole web is
reachable. A machine its owner administers cannot prevent its owner from being distracted.

What is achievable is **focus by default, with friction rather than prohibition**: distractions are
absent, unadvertised, and not one keystroke away. The focused path is the path of least resistance.

Research supports the weaker claim and undercuts the stronger one: the strongest available evidence
(Marotta & Acquisti, n=455, *reported by research subagent — not independently reviewed*) is that
endogenous self-commitment produced no productivity change while exogenous defaults produced ~8 more
tasks/hr. Every kiosk precedent that works exempts the administrator by design. The design
consequence is that **there is no focus subsystem** — no blocklists, no time gates, no dashboards.
The attention design *is* the build manifest plus the display stack: build-time facts, not running
services. The one cheap ratchet worth keeping is the image manifest in git, so anything installed at
11pm is a visible diff.

### 1.4 Governing principles

1. **Parallelism in execution, singularity in attention.** The machine runs N agents concurrently;
   the human-facing surface presents one thing at a time, with the rest reduced to a status line and
   a queue. You go to the work; the work does not come to you.
2. **The terminal is the substrate, not the fallback.** Every capability is reachable as text, every
   configuration is declarative, no capability is interactive-only.
3. **Supervision is solved; isolation is not.** Use systemd for what systemd does. Build only the
   glue that does not exist.
4. **Human ergonomics win.** The primary operator is a person, agent-assisted — not the reverse.
5. **Opinions are packages.** Every default ships as an independently removable unit. *This principle
   is inert until a package delivery channel exists; see §7 and D31.*
6. **Invariants are structural, not procedural.** Where a rule can be enforced by construction,
   enforce it there. `Restart=no` makes prompt replay impossible rather than discouraged; the
   fresh-wipe acceptance gate (D31) makes undocumented hand-edits fail rather than merely frowned
   upon.

### 1.5 What the target machine actually is

Measured during design: the lab's remote GPU host has **4× RTX A6000 (~192 GB VRAM), 64 cores,
503 GB RAM**. The Tensorbook has a single laptop GPU.

**The Tensorbook is therefore a coordination surface, not a compute box.** This strengthens the
thesis rather than weakening it, and it is why the remote-job layer is core rather than peripheral.

---

## 2. Scope

### 2.1 The working shape v1 must support (D28)

Stated by the user during review, and the sizing input for every concurrency decision:

- **5–10 API-backed agents** (provider APIs — the common case)
- **1–2 local-model agents** on the Tensorbook GPU
- **2–4 agents running on the lab GPU host**

So up to ~16 concurrent supervised units across **three execution locations**. This is the single
most consequential requirement in the document. It promotes from "precautionary" to "load-bearing":
the port allocation registry, per-agent systemd slices, the `systemd-oomd` override, GPU admission
control, and `cdl status` as a real supervisory surface rather than a convenience.

### 2.2 In scope for v1

| Capability | Notes |
|-|-|
| Ubuntu 26.04 LTS base, pinned | D19 |
| Encrypted striped storage with snapshots | RAID0 → LUKS2 → LVM → btrfs (D4/D15, D7) |
| **Hibernation, validated on hardware** | Launch requirement (D29), not an experiment |
| Single fullscreen terminal session | cage + kitty + zellij, **autologin not committed** (§12) |
| macOS/Cmd keybinding layer | Generated from one source table (§8) |
| Agent orchestration | Worktree seeding, `cdl-agent@.service`, `cdl status` |
| **Full job layer** | submit / list / status / logs / cancel / artifacts / reconcile (D30) |
| Job backends | local, ssh+nohup (GPU host), cloud, HF Jobs |
| Provider configuration | User-scoped, validated, with `cdl doctor` |
| Local inference | llama.cpp / Ollama / llama-swap, GPU admission control |
| Remote access | OpenSSH bound to the tailnet; no public ports |
| Backup | restic → append-only REST server, **with a tested restore** |
| NVIDIA driver + CUDA + PyTorch | Driver on ISO, CUDA at first boot |
| Emacs, croft, LaTeX, text browser, VPN, wifi | Original requirements R3, R12, R14, R15, R8 |
| Docs, on-disk and published | MkDocs + VHS screenshot regression |
| Remix ISO | D22, accepted by fresh-wipe install (D31) |

### 2.3 Explicit non-goals for v1

Each of these was considered and deliberately deferred or rejected. Listing them prevents
re-litigation and prevents scope from creeping back in through implementation.

| Non-goal | Why |
|-|-|
| **Remote LUKS unlock** | D26. Cost is paid at every kernel update; benefit only materialises on rare unattended reboots. A reboot means physical presence. |
| **Slurm job backend enabled** | D30. Pubkey auth unresolved (§16.1) so it cannot be tested. Designed and specified; ships disabled. |
| **clustrix as a dependency** | Blocks the calling process for a whole job, persists no job IDs, has no TUI. Optional backend later, never on the critical path. |
| **SkyPilot** | v2 evaluation. Its own docs say "Slurm support is under active development." |
| **MIG / MPS GPU isolation** | MIG does not exist on laptop GPUs; MPS destroys per-agent attribution in `nvidia-smi` exactly when supervising N agents. Admission control instead. |
| **A notification bus** | A general notification bus is a general interruption bus. No libnotify, no dunst, no mako. Outbound-only completion receipts to a phone; passive local status line. |
| **Any GUI application path** | `apt install firefox` will succeed and install a useless binary. Documented as acceptable, not supported. |
| **Fully unattended install** | Irreducibly interactive (§4). |
| **A focus-enforcement subsystem** | §1.3. |

---

## 3. Decision record

Decisions D1–D25 were recorded during the original design session. D26–D31 were resolved during
review on 2026-08-31. All were confirmed by the user.

| # | Decision |
|-|-|
| D1 | Audience: **personal-first, publishable**. Hardware config behind a profile layer; no personal data in the image; real docs. |
| D2 | "No GUI" means capability-over-purity; the display-stack call was delegated. |
| D3 | Primary operator: **the user, agent-assisted**. Human ergonomics win conflicts. |
| D4/D15 | Storage: **one flat 2 TB striped volume**. Total loss on single-drive failure accepted, reaffirmed after being shown the risk math. |
| D5 | **Snapshot + rollback** before every update. |
| D6 | Secrets: **plaintext config under full-disk encryption**. 1Password explicitly rejected (no paid-subscription dependency). |
| D7 | **LUKS full-disk encryption, passphrase at every boot.** Not TPM auto-unlock. |
| D8 | **Several agents concurrently on one repo.** Quantified by D28. |
| D9 | **Long-lived unattended sessions** are common and important. |
| D10 | Local GPU for local models; remote job launching also required. |
| D11 | **Remote access from other machines** required. |
| D12 | True motivation is **attention**, not performance. |
| D16 | Build path: **Docker prototype → working machine → full ISO**. Superseded in detail by the milestone plan (§6). |
| D17 | A second working computer (the user's Mac) is available. |
| D19 | Base: **Ubuntu 26.04 LTS, pinned.** Not a rolling `devel` base. |
| D22 | Artifact: **true remix ISO**, not a package-set overlay. |
| D23 | Orchestration: **minimal glue over systemd**. |
| D24 | Name: **`cdl`** / repo `cdl-linux`. |
| D25 | **Hibernation enabled**; swap ≥ RAM. Strengthened by D29. |
| **D26** | **No remote LUKS unlock.** An unattended reboot parks the machine at the passphrase prompt and it stays there. No dropbear-initramfs, no tailscale-initramfs, nothing sensitive on unencrypted `/boot`. |
| **D27** | **Backup target is the user's QNAP/TrueNAS**, which exposes SSH and can run containers. Primary design: `restic` → `rest-server --append-only` in a container on the NAS. Fallbacks in priority order: restic over SFTP; restic via an rclone SMB remote. A capability probe resolves which, before any code. |
| **D28** | **Working shape: 5–10 API agents + 1–2 local agents + 2–4 GPU-host agents.** See §2.1. |
| **D29** | **Hibernation is a launch requirement**, not an experiment. It must be validated on the real machine, including recovery from a failed resume, before M3 is complete. |
| **D30** | **Full job layer in v1** — the complete verb set across local, ssh, cloud and HF Jobs backends. The Slurm backend is designed and specified but ships disabled until its auth is testable (§16.1). |
| **D31** | **Acceptance is a fresh install onto a fully wiped machine.** Nothing hand-configured on the working machine counts as done until it exists as a package or declarative artifact in the repo. |

### 3.1 Rejected alternatives and why

- **Rolling `devel` base (Rhino's actual base).** Rhino's own documentation calls it "unstable" and
  "strongly advised against using this in a production setting." It forces NVIDIA onto DKMS on a
  machine with no GUI fallback. Comparison of archive indexes showed 26.04 LTS ships *identical*
  libc6, gcc, python3, rustc, golang, git, llvm and neovim, and is currently **ahead on the kernel**
  (7.0.0-30.30 vs 7.0.0-14.14). Rolling was buying newer systemd and a much worse NVIDIA story.
- **1Password for secrets.** Works headlessly, but on a GUI-less machine it relocates the plaintext
  secret rather than eliminating it — either 30-minute re-authentication or a service-account token
  on disk.
- **Bare kernel VT.** See §12.
- **tmux.** See §8.
- **swaylock under cage.** Ruled out on primary-source evidence; see §12.

---

## 4. Hard constraints

Requirements that **cannot be satisfied as originally stated**. Each is stated with its resolution.

| Requirement | Why impossible | Resolution |
|-|-|-|
| Create USB images "via web" | WebUSB classes Mass Storage as a protected interface and rejects `claimInterface()`; the only bypass requires Isolated Web Apps on enterprise-managed ChromeOS. The OS kernel driver already claims the interface. No product does this. | Ventoy stick prepared once natively; thereafter each release is a browser drag-and-drop onto its data partition. Plus documented `dd`/Rufus paths. |
| Fira Code ligatures on the bare Linux console | The kernel console has no TrueType rasterizer (PSF 1-bit bitmaps only), no text-shaping engine, and a 512-glyph ceiling. A ligature is a HarfBuzz GSUB substitution. This is a different rendering model, not a missing feature. | Single fullscreen kitty under `cage`. See §12. |
| Cmd keybindings + system clipboard on the bare console | `keymaps(5)` documents nine console modifiers, none of which is Super. `console_codes(4)` supports two OSC sequences; OSC 52 is not among them. | Real terminal emulator. See §8. |
| Ship LM Studio or Claude Code on the ISO | LM Studio's terms forbid sublicensing, distributing or transferring the software. Claude Code's license grants no sublicense. | Fetch-on-demand helpers running each vendor's own installer, so the user accepts the license directly and we redistribute nothing. |
| Bake the CUDA **toolkit** into the ISO | The CUDA EULA permits redistribution only for applications with "material additional functionality"; an OS does not qualify. Ubuntu places it in multiverse. | Ship the NVIDIA **driver** (explicitly redistributable for OSI-licensed kernels); pull CUDA at first boot. PyTorch wheels bundle their own CUDA runtime anyway. |
| Redistribute Rhino branding | `rhino-linux/branding`, `/wallpapers`, `/plymouth`, `/lightdm` have **no LICENSE file**; default copyright applies. | Use ContextLab's own MIT-licensed assets. See §13. |
| ~2 TB with any redundancy | Arithmetic: two 1 TB drives give 2 TB with none, or 1 TB mirrored. | Accepted deliberately (D15). Off-machine backup is therefore mandatory, not optional. |
| Fully unattended install | Wifi credentials, LUKS passphrase, API keys and remote-host key enrollment are all irreducibly interactive. | The install is interactive by design. This spec does not claim otherwise. |
| OAuth/SAML login from a text browser | Terminal browsers have no JavaScript engine; modern IdP consent screens are JS SPAs. | Never authenticate on the machine. Pre-generate tokens elsewhere; complete browser flows on another device. |
| **Lock the screen under cage with swaylock** | Cage implements neither `ext-session-lock-v1` nor layer-shell. **Verified:** no `session_lock.c` in the source tree; `cage.c` (716 lines) contains no `session_lock`/`layer_shell` references; upstream issue **#264 "Add support for ext-session-lock-v1" is open**. | Unresolved — three candidate designs in §12. Autologin is **not** committed until one is chosen and demonstrated. |

---

## 5. Threat model

The FDE and secrets discussion in revision 1 mixed several threat models. They are separated here.
Full controls and their failure behaviour live in `cdl-security-and-recovery`.

| # | Threat | In v1 scope | Control | Residual risk |
|-|-|-|-|-|
| T1 | Opportunistic theft, machine powered off | Yes | LUKS2 FDE, passphrase at every boot (D7). Swap inside the container, so RAM contents including API keys never hit plaintext disk. | None material. `/boot` and ESP are unencrypted but hold no secrets (D26 removes the tailnet key that would have lived there). |
| T2 | Opportunistic access, machine powered on and unattended | Yes | **Currently unresolved.** Autologin plus plaintext keys means opening the lid yields a shell with live credentials; FDE protects only a powered-off machine. | **The live gap in the design.** See §12; blocks the autologin decision. |
| T3 | Malicious local process reading provider keys | Yes | Keys in `~/.config/cdl/providers.env`, mode `0600` — **not** `/etc`, which the `ollama` system user and every service unit could read. | Any process running *as the user* can still read them. Accepted: this is a single-user machine. |
| T4 | Compromised or misbehaving agent destroying work | Yes | Worktree isolation per agent; bubblewrap process sandbox with an AppArmor profile; `Restart=no`; append-only backup so history cannot be rewritten. | An agent can still push to remotes and spend provider credit. Spend controls remain an open product gap (§16.3). |
| T5 | Stolen backup credential | Yes | `rest-server --append-only`: verbatim, it "allows creation of new backups but prevents deletion and modification of existing backups" and "prevents an attacker from wiping your server backups when access is gained to the server being backed up." | An attacker with the laptop can still *read* and decrypt backup history, and can append garbage. Retention pruning must therefore run from the NAS side, not the laptop. |
| T6 | Supply-chain compromise | Partial | Pinned archive snapshot, per-ISO package manifest, checksummed vendored binaries, pinned pacscript commits. | Pacstall source builds and `cargo install` pull unaudited upstream code. Reduced, not eliminated. |
| T7 | Evil maid — physical access to unencrypted `/boot`/ESP | **No — explicitly out of scope** | Secure Boot raises the bar. `/boot` is unencrypted and unmeasured; an attacker with physical access can modify the initramfs to capture the passphrase. | Accepted and stated. Against a targeted adversary with physical access, nothing in an unencrypted initramfs is trustworthy. |
| T8 | Network attacker | Yes | No public ports, ever. OpenSSH bound to the tailnet interface; firewall default deny except `tailscale0`. Key-only auth. | Compromise of the tailnet identity. |

**Note on T2 and D26 together.** Declining remote unlock removes an attack surface (no tailnet
credential on unencrypted `/boot`) at the cost of availability after an unattended reboot. That
trade is deliberate and is the reason §11 requires the machine's recovery posture to assume physical
presence.

---

## 6. Milestones

Each milestone has an entry condition, a deliverable, and an exit criterion that is a test, not a
judgement. **No milestone's work may be blocked on a later milestone's riskiest component** — that
principle is why ISO work is last, not first.

### M0 · Hardware capture — *do this now*

- **Entry:** none. Independent of every other decision.
- **Deliverable:** `scripts/capture-hardware.sh` output committed to `notes/hardware/`.
- **Exit:** every fact in §15 recorded, including firmware settings that require a reboot to read.
- **Why first:** one-way. Every fact becomes unobtainable after installation, and at least six
  design decisions currently rest on assumptions rather than measurements (§15).

### M1 · Environment prototype — *does the day-to-day feel good?*

- **Entry:** M0 complete (for the wifi/GPU package choices only; otherwise independent).
- **Where:** an Ubuntu 26.04 VM on the Mac, or any existing Linux box. **Not** the Tensorbook.
- **Deliverable:** package manifest, kitty session, generated keybindings, provider configuration,
  worktree creation and seeding, one supervised agent under systemd, `cdl status`.
- **Exit:** the user works inside it for a full session and reports whether it is pleasant. Spikes 1
  and 2 (§9) pass or the architecture changes.
- **Why:** this milestone tests the actual product thesis. It must not be gated on storage, boot,
  installer or ISO work, none of which make the environment better.

### M2 · Operational appliance — *the real machine, conventional install*

- **Entry:** M1 exit; M0 complete.
- **Where:** the Tensorbook, wiped, using a **stock Ubuntu Server 26.04 installation**.
- **Deliverable:** NVIDIA driver and CUDA, PyTorch, networking and wifi, VPN, remote access, backup
  with a **tested restore**, the full agent orchestration and job layer, power/lid/thermal policy.
- **Exit:** the user runs the D28 working shape — 5–10 API agents, 1–2 local, 2–4 on the GPU host —
  unattended overnight, and the machine is in the expected state the next morning.
- **Binding constraint from D31:** every customisation must exist in the repo as a package or a
  declarative artifact. A hand-edited config file on this machine is a **defect**, because M4's
  acceptance test replays this milestone's work onto bare metal. Nothing hand-edited will survive.

### M3 · Recoverable custom storage installation

- **Entry:** M2 exit; spike 3 (§9) passes in QEMU.
- **Deliverable:** the RAID0 → LUKS2 → LVM → btrfs layout, snapshot and rollback, **hibernation
  working on real hardware including recovery from a failed resume** (D29), restore drill from the
  M2 backup onto the new layout.
- **Exit:** (a) a deliberate bad update is rolled back from the boot menu and the machine returns to
  service; (b) ten consecutive hibernate/resume cycles succeed on hardware; (c) a full restore from
  backup reproduces the working environment.
- **Note:** this milestone destroys the M2 installation. The M2 backup and restore must be proven
  *before* it starts — that is the whole point of testing restore in M2.

### M4 · Remix ISO

- **Entry:** M3 exit.
- **Deliverable:** reproducible build, subiquity integration with the custom storage recipe, the
  `cdl` apt repository, signing, generic hardware profile, published documentation.
- **Exit (D31):** a **fresh install onto a completely wiped machine, from the ISO**, produces a
  working system with no manual steps beyond the documented interactive ones (wifi, LUKS passphrase,
  API keys, remote host enrollment). Two builds of the same commit produce identical ISOs.

---

## 7. Component specification map

This document is the overview. Mechanism lives in four specs, each of which must contain state
transitions, failure behaviour, and acceptance tests. None is written yet; this table is the
commissioning brief for each.

| Spec | Owns | Must resolve |
|-|-|-|
| **`cdl-install-and-packaging`** | Live ISO build toolchain; subiquity integration and the custom storage recipe; package manifests, sources and pinning; vendored binaries (zellij, croft); Secure Boot; first-boot provisioning; installed-system updates; the project's own apt repository; reproducibility; ISO size budget; **the documentation pipeline** | Review finding #1. Also the apt-ownership/conflict policy (apt vs Pacstall vs cargo vs vendored), `unattended-upgrades` on or off, and third-party repo pinning in `/etc/apt/preferences.d` |
| **`cdl-security-and-recovery`** | Threat model in full; secrets at rest and leakage during install; remote access (bind addresses, firewall, key enrollment and rotation, mosh); snapshot and rollback design; backup schedule, retention, encryption, failure notification, consistency, restore verification, bare-machine recovery, RPO/RTO | Review findings #2, #4, #5. Also the D26 recovery posture and the T2 session-lock gap |
| **`cdl-agent-lifecycle`** | Agent state machine; PTY allocation, attach/detach, input injection; blocked/waiting/complete detection; exit status; prompt and launch-command recording; cancellation; worktree and service reconciliation; resume without replay; bubblewrap sandbox; port allocation registry; GPU admission; `cdl status` contract; the full job layer and its registry schema | Review findings #6, #7. Also the three-location model from D28 and the Slurm extension plan (D30) |
| **`cdl-first-boot-and-environment`** | First-run experience; provider key entry, validation and leakage avoidance; model installation, quota and GC; offline behaviour; CUDA at first boot; Emacs configuration and LLM integration; croft packaging and pinning; python/PyTorch/HF; LaTeX profile; text browser; VPN; wifi; power, lid, battery and thermal policy; keybinding generation | Review finding #8 |

**Documentation, carried forward from revision 1 so the restructure does not lose it.** MkDocs,
themed from the tokens in §13. **Screenshots are regression tests:** `vhs` tapes rendered to PNG and
diffed in CI, because PNG output is byte-identical across runs and GIF output is not. The CI runner
must have `fonts-firacode` installed or every image silently renders in a different typeface, and
VHS must be configured with the shipped theme or published screenshots depict a system that does not
exist. **VHS cannot capture everything** — it renders inside its own pty and physically cannot
photograph GRUB, the installer, the bare VT, or the boot sequence. Those need QEMU framebuffer
capture: a different tool, and a documented gap rather than an oversight. **Docs ship on-disk**, because
a documentation site is useless exactly when it is most needed: no wifi, no boot.

### 7.1 Where revision 1's content went

Restructuring is the easiest way to lose content silently. This table exists so the loss can be
checked rather than trusted. Every revision 1 section is accounted for; where mechanism left this
document without a written destination, the source material is in `notes/` and the receiving spec
must reconcile against it before it is called complete.

| Revision 1 section | Destination |
|-|-|
| §1 Purpose and design philosophy | §1, sharpened thesis added |
| §2 Decision record | §3, extended with D26–D31 |
| §3 Hard constraints | §4, plus one new row (the cage locking constraint) |
| §4 Storage and boot | §11 keeps the layout and rationale; the install recipe → `cdl-install-and-packaging` |
| §5 Session and display | §12, with three corrections |
| §6 Keybindings | §8 keeps the rule and the tmux/zellij verdict; config generation → `cdl-agent-lifecycle` |
| §7 LLM layer | → `cdl-first-boot-and-environment`. **Not yet rewritten anywhere:** the divergent provider env-var spellings, the llama.cpp/llama-swap rationale, and the VRAM-gated model picker. Source in `notes/research/`. |
| §8 Agent orchestration | §8 keeps the architecture; state machine, registry and sandbox → `cdl-agent-lifecycle` |
| §9 Remote compute | → `cdl-agent-lifecycle` §jobs. **Not yet rewritten:** the clustrix verdict, HF Jobs entitlement, and the ship-your-own-environment constraint (the GPU host runs python 3.6.8 with no `nvcc`). |
| §10 Backup and recovery | → `cdl-security-and-recovery`. **Not yet rewritten:** `--exclude-caches` dropping the HF cache via `CACHEDIR.TAG`, the excluded-weights manifest, `GRUB_TIMEOUT_STYLE=menu`, `grub-btrfs`, the retained live USB. |
| §11 Documentation | §7, carried forward in full above |
| §12 Branding and theme | §13, with the contrast claim corrected |
| §13 Validation ladder | §14, with the hibernation claim corrected |
| §14 Pre-wipe hardware capture | §15, expanded from 4 commands to 27 plus firmware items |
| §15 Open items | §16. Item 15.1 (backup target) closed by D27; 15.4 (reproducible builds) → `cdl-install-and-packaging` and DR11; 15.5 (spend controls) survives as §16.3, still unowned |
| §16 Evidence standards | §17, with qualifications moved inline to the claims themselves |

---

## 8. Architecture at a glance

```
                       ┌───────────────────────────────────────────┐
   attention surface   │  cage → kitty → zellij → cdl status       │   one visible thing
                       └───────────────────────────────────────────┘
                                        │
                       ┌───────────────────────────────────────────┐
   supervision         │  systemd --user + linger                  │   durable, survives logout
                       │  cdl-agent@.service, per-agent slices     │   Restart=no
                       └───────────────────────────────────────────┘
                          │                │                 │
   execution locations    │ local          │ GPU host        │ cloud / HF Jobs
                          │ (1–2 local     │ (2–4 agents,    │ (batch)
                          │  models)       │  ssh+nohup)     │
                          └────────────────┴─────────────────┘
                                        │
                       ┌───────────────────────────────────────────┐
   durable state       │  job + agent registry (SQLite, WAL)       │   spans three machines
                       │  port allocation registry (locked)        │
                       └───────────────────────────────────────────┘
                                        │
                       ┌───────────────────────────────────────────┐
   isolation           │  git worktree per agent + bubblewrap      │
                       └───────────────────────────────────────────┘
                                        │
                       ┌───────────────────────────────────────────┐
   storage             │  btrfs @ @home @snapshots                 │
                       │  LVM (lv_root, lv_swap ≥ RAM)             │
                       │  LUKS2 (one container, one passphrase)    │
                       │  md0 RAID0 across two NVMe                │
                       └───────────────────────────────────────────┘
```

**Why the registry is SQLite, not per-worktree JSON.** D28 puts agents on three machines and D30
requires reconciliation across them. Per-worktree JSON with multiple concurrent writers would
require inventing transactional file handling; SQLite in WAL mode provides it. This reverses
revision 1's implied design.

**Worktree per agent, enforced.** *Reported by research subagent, not independently reproduced:*
agents sharing one checkout landed 24 of 100 commits with 75 `index.lock` failures, staging each
other's half-finished work; one worktree per agent landed 100/100. One branch cannot be checked out
twice, so each agent owns its own branch by construction.

**`cdl worktree new <branch>` — the seeding hook.** `git worktree add` carries no untracked or
gitignored files, so a fresh agent workspace has no venv, no `node_modules`, no `.env`. The hook
creates the venv with `uv` so packages hardlink from one shared cache, reflink-copies large
gitignored directories (`cp --reflink=auto`, free on btrfs), and **allocates a port block**.

> **Correction to revision 1.** Revision 1 described "a deterministic, non-colliding port block
> derived from the branch name." A hash is deterministic but **not** non-colliding. The design is a
> hash for the *preferred* block, plus collision detection against a persistent allocation registry,
> plus an advisory lock around allocate-and-record, plus a documented fallback when the preferred
> block is taken. Specified in `cdl-agent-lifecycle`.

**Keybindings.** A single machine-readable Cmd table is the source of truth; every downstream config
is generated from it: `keyd`, kitty, `~/.inputrc`, zsh bindkeys, helix, neovim, zellij, yazi, and
Emacs via the `kkp` package. **The Cmd layer must never inherit Control** — aliasing Cmd onto Ctrl
is destructive in a terminal: Cmd-S becomes XOFF (looks like a hang), Cmd-Z becomes SIGTSTP, Cmd-C
becomes SIGINT. Both keymap systems must be configured — the console uses `loadkeys`/PSF,
cage/Wayland uses XKB — or the rescue console behaves differently from the session.

**zellij, not tmux.** tmux's manual contains zero occurrences of "super", and tmux strips the kitty
keyboard protocol, so Cmd bindings break in every application running inside it. zellij adopted that
protocol specifically for Super and passes it through. Cost: not in Ubuntu or Pacstall, so vendor a
pinned static musl binary.

**Ubuntu's `systemd-oomd` default must be overridden.** *Reported, not reproduced:* Ubuntu ships
`ManagedOOMMemoryPressure=kill` at a 50 % limit with a 20 s pressure duration, so an arbitrary
descendant cgroup is killed under pressure and the victim is not chosen — potentially the
multiplexer, taking every agent with it. Ship per-agent slices with `MemoryHigh` (throttles rather
than kills) plus `MemoryMax` as a backstop, and `ManagedOOMPreference=avoid` on the supervisor and
notifier. **Confirm these values on the target before relying on them.**

**Process sandbox.** *Reported, not reproduced:* on Ubuntu 24.04 and later the default AppArmor
policy prevents bubblewrap from creating the user namespaces it needs, and Claude Code's default on
sandbox failure is to warn and then run **unsandboxed**. The image must therefore ship
`/etc/apparmor.d/bwrap`, preinstall bubblewrap, set the agent's fail-closed sandbox option, and check
`kernel.apparmor_restrict_unprivileged_userns` at first boot. Revision 1 dropped this finding
entirely despite the research identifying the process boundary as required for unattended agents.

**GPU arbitration.** One inference server as a system service behind a `flock` semaphore. Admission
control, not isolation (see §2.3 for why MIG and MPS are excluded).

---

## 9. Risk spikes

Build these before broad scaffolding. **A failed spike is allowed to change the architecture** —
that is what they are for. Each has a stated pass condition.

### Spike 1 · Session and lock path

Assemble cage + kitty + literal Super keybindings + zellij + croft, and determine the lock path.

The swaylock sub-question is **already answered and needs no spike**: cage implements neither
`ext-session-lock-v1` nor layer-shell (§4). What the spike must decide is which of three designs to
adopt:

| Option | Mechanism | Cost |
|-|-|-|
| **A. Different compositor** | Replace cage with one that implements `ext-session-lock-v1` (sway or labwc configured with no bars or decorations) | A real window manager with a config file; more surface area than a 77 kB kiosk |
| **B. Hibernate as the lock** | Lid close and idle trigger **hibernation**, not suspend. Resume requires the LUKS passphrase, so it is a genuine credential barrier | Slow (writes ≥ RAM plus ~16 GB of preserved VRAM). Depends entirely on D29 succeeding. Elegant coupling if it does |
| **C. No autologin** | Conventional authenticated getty login; cage started from the user's profile; no in-session locker | Less elegant, much safer failure mode. Does not protect a session already open |

**Pass condition:** one option demonstrated end to end, including what happens when it fails.
**Until then, autologin is not committed** and threat T2 stays open.

### Spike 2 · Durable interactive agent

A systemd-managed interactive agent that: gets a PTY, can be attached and detached, survives logout,
reports completion, preserves exit status, and **never replays its opening prompt**.

**Pass condition:** attach → detach → log out → log back in → attach again, with the agent still
running and its scrollback intact; then kill the terminal and confirm the agent neither dies nor
restarts.

### Spike 3 · Storage, installer, and hibernation in QEMU

Subiquity (or an alternative) producing the exact two-disk encrypted layout under QEMU + OVMF with
two emulated NVMe controllers, followed by snapshot → update → rollback → hibernate → resume.

**Pass condition:** an unattended-installed VM survives a deliberate bad update via boot-menu
rollback, and resumes from hibernation across all four storage layers.
**Explicitly does not establish** that hibernation works on the Tensorbook (§14).

---

## 10. Requirement traceability

Every original requirement, mapped to the component that implements it, the milestone that delivers
it, and the test that proves it. Rows marked ⚠ are those revision 1 dropped or under-specified.

| # | Requirement | Design component | Milestone | Acceptance test |
|-|-|-|-|-|
| R1 | Provider APIs built in; keys collected at setup | first-boot-and-environment §providers | M1 | `cdl doctor` makes one live call per configured provider and reports which keys work |
| R2 | Two drives as one ~2 TB volume | install-and-packaging §storage | M3 | `lsblk` shows the four-layer stack; `df` shows a single ~1.85 TiB filesystem |
| R3 ⚠ | emacs + croft preinstalled | first-boot-and-environment §editors | M1 | Both launch; croft renders Nerd Font glyphs not `[?]`; **Emacs LLM integration (gptel/ellama) configured and answering** |
| R4 | macOS-native keybindings | agent-lifecycle §keybindings (generation); overview §8 | M1 | Generated configs diffed against the source table in CI; Cmd-S/Z/C verified not to emit XOFF/SIGTSTP/SIGINT |
| R5 | Everything a TUI; no GUI | overview §12; install §manifest | M1 | Manifest contains no display manager, no browser engine, no notification daemon |
| R6 | Native CUDA/NVIDIA | first-boot-and-environment §cuda | M2 | `nvidia-smi` and a PyTorch CUDA tensor op on the real GPU |
| R7 ⚠ | ollama + LM Studio; models chosen at install; easy to add later | first-boot-and-environment §models | M2 | Model picker gated on measured VRAM; **disk quota and GC policy enforced — a pull that would exceed the ceiling is refused** |
| R8 ⚠ | Wifi drivers + modern conveniences | first-boot-and-environment §network, §power | M2 | Wifi connects via nmtui; **lid-close during a running agent does not suspend; critical battery hibernates rather than powering off** |
| R9 | LAN backup | security-and-recovery §backup | M2 | A restore drill reproduces `$HOME` onto a clean machine |
| R10 ⚠ | Full apt support | install-and-packaging §apt-policy | M2 | Ownership policy documented per package class; third-party pins in `/etc/apt/preferences.d`; `unattended-upgrades` posture decided and tested |
| R11 | python + PyTorch + HF for CUDA | first-boot-and-environment §python | M2 | CUDA tensor op; HF cache location and ceiling configured |
| R12 ⚠ | LaTeX distribution | first-boot-and-environment §latex | M2 | A document builds; **profile and installed size explicitly chosen against the ISO budget** |
| R13 ⚠ | Full docs with screenshots | install-and-packaging §documentation | M4 | VHS PNG diffs pass in CI; docs present on-disk offline; **boot/installer/GRUB captures produced by QEMU framebuffer, not VHS** |
| R14 ⚠ | Text-based browser | first-boot-and-environment §browser | M1 | w3m or lynx installed. **Must be non-JS by capability — Browsh and Carbonyl are excluded; Carbonyl is Chromium in a terminal, with WebGL and video** |
| R15 ⚠ | VPN support | first-boot-and-environment §vpn | M2 | GlobalProtect connects headlessly and survives a multi-hour unattended run, **or** an off-VPN bastion path is documented instead |
| R16 | Easy installable-USB creation | install-and-packaging §distribution | M4 | Ventoy drag-and-drop; `dd` and Rufus paths documented and tested |
| R17 | Fira Code with ligatures | overview §12 | M1 | Ligatures render in kitty; icon glyphs come from the fallback, not a patched font |
| DR1 | Several agents concurrently (D8/D28) | agent-lifecycle | M2 | The full D28 working shape runs overnight unattended |
| DR2 | Long-lived unattended sessions (D9) | agent-lifecycle §supervision | M2 | Agent survives logout, reboot of the terminal, and network loss |
| DR3 | Remote job launching (D10/D30) | agent-lifecycle §jobs | M2 | All seven verbs against the GPU host; reconcile recovers a job whose launcher died |
| DR4 | Remote access (D11) | security-and-recovery §remote-access | M2 | SSH from the Mac over the tailnet; `nmap` from outside shows no open port |
| DR5 | Snapshot + rollback (D5) | security-and-recovery §snapshots | M3 | A deliberate bad update is rolled back from the boot menu |
| DR6 | FDE (D7) | install-and-packaging §storage | M3 | Passphrase required at boot; swap inside the container verified |
| DR7 ⚠ | Hibernation (D25/D29) | install-and-packaging §storage; environment §power | M3 | **Ten consecutive hibernate/resume cycles on hardware, plus documented recovery from a failed resume** |
| DR8 ⚠ | Screen lock / session security (T2) | security-and-recovery §session | M1 | Spike 1 option demonstrated; unattended lid-open does not yield a live-credential shell |
| DR9 ⚠ | First-run experience | first-boot-and-environment §first-run | M2 | First boot on a fresh install is resumable and idempotent; an interrupted provisioning run recovers |
| DR10 ⚠ | Offline behaviour | first-boot-and-environment §offline | M2 | Machine boots, opens a session and reports provider unavailability clearly with no network |
| DR11 | Reproducible build | install-and-packaging §reproducibility | M4 | Two builds of one commit produce identical ISOs |
| DR12 ⚠ | Spend controls | *unowned — see §16.3* | — | — |

---

## 11. Storage and boot

```
nvme0n1p1   ESP      FAT32   1 GiB        unencrypted (UEFI reads only plain FAT32)
nvme0n1p2   /boot    ext4    2 GiB        unencrypted (GRUB2 LUKS2 = PBKDF2, not Argon2id)
nvme0n1p3  ┐
nvme1n1p1  ┴── md0 (RAID0) ── LUKS2 ── LVM VG "cdl"
                                        ├── lv_swap  ≥ RAM      hibernation target
                                        └── lv_root  remainder  btrfs: @ @home @snapshots
```

**Why each layer exists.** LUKS sits *above* the stripe so there is exactly one container and
therefore **one passphrase**; per-drive LUKS would need two unlocks or a `decrypt_keyctl` keyscript,
doubling the fragility of the one thing that must never fail. LVM exists *only* to provide a swap
block device and btrfs inside that single container — a btrfs swapfile would require NOCOW, forbid
compression, need exclusion from every snapshot, and make hibernation's `resume_offset` awkward.
Swap **must** be inside LUKS; swap outside it writes RAM contents, including API keys, in plaintext.

**Tuning.** `--sector-size 4096` on the LUKS container (*reported, not reproduced:* ~1994 MB/s vs
~1130 MB/s at the 512-byte default, which would recover most of what striping was meant to buy),
`--allow-discards --persistent`, and `fstrim.timer` enabled.

**Risks accepted.**
1. Hibernation on a Razer Blade chassis is known-fragile: spurious wake from XHC, an infinite suspend
   loop needing `button.lid_init_state=open`, `acpi_sleep=nonvs`, and Xid 79 "GPU has fallen off the
   bus" under runtime PM. **D29 makes this a launch requirement, so these are risks to be retired in
   M3, not accepted.**
2. NVIDIA writes ~16 GB of VRAM to `NVreg_TemporaryFilePath` on each hibernate. That path must be on
   the big volume, never tmpfs, and it is real write amplification.
3. Resume traverses four layers. Must be proven in QEMU before touching hardware (spike 3) — and
   then proven *again* on hardware (§14).
4. **D26 consequence:** an unattended reboot leaves the machine at the passphrase prompt,
   unreachable, until someone is physically present. Every recovery procedure must assume this.

**Contingent on hardware capture:** swap size follows measured RAM; the whole striping design assumes
both drives are NVMe. See §15.

---

## 12. Session and display

Boot → **login on tty1** → `cage` → one fullscreen **kitty** → **zellij** for multiplexing. A rescue
getty on tty2, so a broken GPU driver never leaves the machine unreachable.

> **Autologin is not committed.** Revision 1 specified autologin. Combined with plaintext API keys
> that means opening the lid yields a shell with live credentials (threat T2), and the locker
> revision 1 proposed does not work (below). Autologin is adopted only if spike 1 produces a working
> lock path; otherwise the session begins with a conventional authenticated login.

**This is not a desktop.** No window manager, no panel, no file manager, no mouse-driven
applications. Upstream cage states it "will not fit into a regular desktop-style workflow" — that is
precisely why it is used.

> **Correction to revision 1.** Revision 1 said cage "cannot display two windows." Its man page says
> the opposite, verbatim: *"Cage runs a single, maximized application. Cage can run multiple
> applications, but only a single one is visible at any point in time."* The constraint is one
> **visible** client, not one client. The distinction matters for any future in-session overlay.

**The locking problem.** Revision 1 proposed swaylock under cage. **Cage implements neither
`ext-session-lock-v1` nor layer-shell** — verified against the source tree (no `session_lock.c`; no
matches for `session_lock`/`layer_shell` in the 716-line `cage.c`) and confirmed by open upstream
issue **#264, "Add support for ext-session-lock-v1."** `physlock` is not an equivalent substitute:
it draws its prompt on the VT, which cage occupies as DRM master, so the prompt would not be
visible. *That last step is reasoning from the display model, not a test — confirm it in spike 1
rather than treating it as established.* Three candidate
designs are in spike 1 (§9).

**Justification for a compositor at all** is evidentiary rather than aesthetic: croft, a required
component, states in its own README that it needs "A Nerd Font as your terminal font — without one
they render as `[?]` boxes" and "A 256 color or truecolor terminal." The bare console satisfies
neither. The distro's flagship editor would be visibly broken on the purist option.

**Fonts.** `fonts-firacode` **unpatched** plus `fonts-nerd-symbols` as a fontconfig fallback — not a
Nerd-patched Fira Code. Patching frequently damages GSUB ligature tables; fallback preserves Fira
Code's ligatures *and* supplies the icon glyphs croft needs.

**Console legibility.** On a 2560×1440 15" panel the default VT font is unreadable. An explicit large
PSF (`setfont`) and a chosen kitty `font_size` are required, not optional.

---

## 13. Branding and theme

All assets are ContextLab's own, from the **MIT-licensed** `ContextLab/contextlab.github.io` and
`llm-course` repositories. This sidesteps entirely the finding that Rhino's branding repositories
carry no license.

**Brand icon:** `CDL_Avatar.png` (533×533, transparent alpha confirmed) — Plymouth splash, GRUB mark,
docs favicon.

**Palette derivation.** Dartmouth green `#00693E` is HSL hue **155.4°**, L 0.206, S 1.000. All green
tints lock that hue and vary lightness. The critical finding: **Dartmouth green is unreadable as text
on a dark background** (2.63:1 against the lab's own dark theme; 2.88:1 against the base below). The
palette is therefore split by *role* — the dark half is structural, the light half is text.

**CDL Dark.** Base `#000F09` · surface `#011B10` · foreground `#E8EEEB` (16.66:1) · cursor `#29E095`

| slot | normal | ratio | bright | ratio | family |
|-|-|-|-|-|-|
| 0 black | `#022919` | **1.24** | `#227754` | **3.58** | green tint — **structural only** |
| 1 red | `#E7556F` | 5.53 | `#EF90A1` | 8.56 | bonfire-red · rare accent |
| 2 green | `#00A863` | 6.32 | `#29E095` | 11.37 | Dartmouth tint · **workhorse** |
| 3 yellow | `#A5D75F` | 11.64 | `#F5DC69` | 14.29 | rich-spring / summer-yellow |
| 4 blue | `#308ED5` | 5.55 | `#72B2E2` | 8.56 | river-blue · rare accent |
| 5 magenta | `#9A7EA5` | 5.50 | `#B8A5C0` | 8.56 | violet · rare accent |
| 6 cyan | `#12A08C` | 6.00 | `#37C7B0` | 9.29 | green-adjacent teal |
| 7 white | `#BBD3C9` | 12.38 | `#E8EEEB` | 16.66 | green-tinted neutral |

> **Correction to revision 1.** Revision 1 claimed "every normal colour clears 4.5:1." That is false:
> ANSI slot 0 normal is **1.24:1** and its bright is **3.58:1**. The accurate claim is **seven of
> eight normal colours clear 4.5:1; slot 0 does not and never will, because it is a near-black.**
>
> This is not merely a wording fix. Slot 0 **can** be emitted as foreground text — `ls` dircolors,
> diff tools, and any program using `\e[30m` do it — so it cannot be treated as purely structural by
> assertion. Two things follow, and belong in `cdl-first-boot-and-environment`: ship a `LS_COLORS`
> and tool-theme set that never selects colour 0 as a foreground, and document the residual risk for
> third-party programs that do it anyway.

Five of eight hues sit in or beside the green family, so ordinary output reads as monochrome
Dartmouth green; red, blue and violet appear only where a terminal must genuinely distinguish
something, which is what makes them read as highlights.

**Structural, never text:** `#00693E` Dartmouth green (2.88:1) and `#003C73` river navy (1.77:1) —
splash, borders, inactive chrome. Their darkness is the point.

---

## 14. Validation ladder

| Stage | Validates | Needs target hardware |
|-|-|-|
| **1 · Docker** | Package availability and versions, LLM tooling, python/uv/torch paths, provider config, `cdl doctor`, docs build | No |
| **2 · QEMU + OVMF, two emulated NVMe controllers** | Storage layout, boot, installer, LUKS+RAID0+LVM+btrfs, **the hibernation storage plumbing and initramfs configuration**, systemd units, cage+kitty session | No |
| **3 · Tensorbook** | CUDA on real silicon, display on the real panel, wifi, suspend, thermals, **hibernation in fact** | Yes |

Docker validates the *least* risky part of the system: it cannot test a kernel, GPU, console,
bootloader or disk layout, and systemd-in-a-container cannot properly exercise the orchestration
layer. **This is why M1 uses a VM rather than a container** — the stages are CI validation
mechanisms, not the milestone environments. Stage 1 is where package availability is checked on
every commit; M1 is where a human finds out whether the system is pleasant to use. Nested virtualisation is confirmed working on GitHub Linux x86 runners; GPU testing is not
possible in hosted CI and requires the Tensorbook enrolled as a self-hosted runner.

> **Correction to revision 1.** Revision 1's table claimed stage 2 validates "hibernation resume."
> QEMU validates the *storage plumbing and initramfs configuration* for hibernation — genuinely
> useful, and worth doing first. It cannot validate what actually dominates the risk here: the
> Tensorbook's firmware, the panel and GPU topology, NVIDIA's VRAM preservation behaviour, lid
> events, or resume reliability across power states. Under D29, hibernation is a **stage 3**
> acceptance item requiring repeated real-hardware cycles including failure recovery.

---

## 15. Pre-wipe hardware capture

One-way, and the reason M0 comes first. Every fact becomes unobtainable after installation.
Runnable script: `scripts/capture-hardware.sh`. Output belongs in `notes/hardware/`, **which is
gitignored** — captures contain serial numbers, MAC addresses, filesystem UUIDs and hostnames, and
D1 commits to keeping personal data out of a publishable artifact. Quote redacted *facts* into
specs ("two 1 TB NVMe drives, both 512e/4Kn"), never raw command output.

Revision 1's list was too narrow for the number of decisions that depend on it. Full list:

```bash
# identity and firmware
sudo dmidecode -s system-product-name; sudo dmidecode -s system-version
sudo dmidecode -s bios-version; sudo dmidecode -s bios-release-date
mokutil --sb-state                       # Secure Boot state
ls -l /dev/tpm* 2>/dev/null; sudo systemd-cryptenroll --tpm2-device=list

# storage — decides whether striping is even coherent
sudo nvme list
lsblk -e7 -o NAME,MODEL,TRAN,ROTA,PHY-SEC,LOG-SEC,SIZE,FSTYPE,MOUNTPOINT
sudo smartctl -a /dev/nvme0n1; sudo smartctl -a /dev/nvme1n1
sudo fdisk -l; sudo blkid

# GPU, display topology and driver state
nvidia-smi -q                            # GPU, VRAM, driver, power, thermal
lspci -nnk                               # every device WITH bound driver
ls /sys/class/drm/                       # connector and provider topology
xrandr --listproviders 2>/dev/null || true

# memory — decides swap size and therefore the whole LVM layout
free -g; sudo dmidecode -t memory | grep -E 'Size|Speed|Locator'

# power and sleep
cat /sys/power/mem_sleep; cat /sys/power/state
cat /sys/class/power_supply/BAT*/energy_full_design 2>/dev/null
upower -i "$(upower -e | grep BAT)" 2>/dev/null || true

# network
lspci -nn | grep -Ei 'network|wireless'; lsusb
iw dev 2>/dev/null; nmcli device status

# current boot configuration
cat /proc/cmdline; uname -a
```

**Plus, from firmware (requires a reboot into setup):** whether storage is in **Intel VMD/RST mode**
(if so and it cannot be disabled, a stock installer sees no disks at all and the project stops), and
the Chipset setting (Dedicated GPU Only vs Dynamic Display Switch, which decides whether the console
comes from `i915`/`simpledrm` or from `nvidia-drm`).

**Decisions blocked on this:** swap size (currently assumes 64 GB RAM, from a vendor launch post
rather than measurement) — and under D29 this is now a launch-requirement input, not a nicety; the
entire striping design (**at least one documented Tensorbook shipped 1 TB NVMe + 1 TB M.2 SATA**,
which would make striping actively harmful); the console/display path; the wifi firmware package;
the thermal envelope for sustained CUDA load.

---

## 16. Open items

### 16.1 Slurm host key enrollment

Public-key auth is advertised by the server, the key is offered,
and the server rejects it — measured: verbose SSH shows `Offering public key: ... SHA256:qngAAcL/…`
followed by another `Authentications that can continue:`, so this is **server-side rejection, not
a client failure to present the key**. Candidate causes, untested: `StrictModes` with a
group-writable home; a quietly failed `ssh-copy-id`; site policy requiring portal registration.
Diagnosing it requires an interactive password login the user must perform. **Not
design-blocking** — D30 ships the Slurm backend disabled with an extension plan. Do not retry
auth repeatedly; lockout risk on a university host.
*(What was resolved earlier is that the user authenticates by password, which removed Kerberos and
GSSAPI from v1. The note heading "AUTH RESOLVED" in the session log refers to that narrower fact
and is superseded by the later diagnosis.)*

### 16.2 Linux Foundation sublicense

The name `cdl-linux` contains the adjacent letters "Linux", which
requires a free, perpetual sublicense for a software mark. Trivially satisfiable; must be filed
before public release.

### 16.3 Spend controls — unowned

An LLM-first distro that collects API keys and ships no budget or
usage visibility is a genuine product gap, made larger by D28 (up to ~16 concurrent agents). It
appears in the traceability matrix as DR12 with no owning component. **Decide: v1 feature,
documented gap, or explicit non-goal.**

### 16.4 NAS make and model

D27 selects the design shape but the capability probe (SSH → container →
SFTP → SMB) must run before `cdl-security-and-recovery` can be finalised.

### 16.5 Sustained thermal load

A verified first-hand report on this chassis says "I have not been
able to do any fan control at all." If multi-hour local GPU load is a real use case — D28 says
1–2 local agents, so it is — thermals are a first-class risk with no current owner.

---

## 17. Evidence standards

### 17.1 The rule

This spec distinguishes **measured** from **reported** claims, and implementation must preserve that
distinction. Revision 1 stated the rule in this section but violated it in the body; revision 2
carries the qualification inline at each claim instead.

### 17.2 Classification

**Measured** — verified by direct command execution:

- clustrix tag and commit counts; the remote GPU host's specifications; Ubuntu package and archive
  queries; the name collision checks; every contrast ratio in §13.
- Added in revision 2: cage's lack of session-lock support (source tree, `cage.c`, upstream issue
  #264); cage's man-page description of multiple clients; `rest-server --append-only` semantics;
  the existence of an rclone SMB backend.

**Reported by research subagents, not independently reproduced** — treat as testimony, confirm before
depending on it:

- the worktree commit experiment (§8); the dm-crypt throughput numbers (§11); the drive-failure
  probability math; the `systemd-oomd` default values (§8); the bubblewrap/AppArmor interaction (§8);
  the Marotta & Acquisti finding (§1.3).

`notes/` carries the full ledger.

### 17.3 Corrections made in revision 2

| # | Revision 1 said | Correction |
|-|-|-|
| 1 | "Every normal colour clears 4.5:1" (r1 §12) | False. ANSI slot 0 is 1.24:1. Seven of eight clear it. §13 |
| 2 | cage "cannot display two windows" (r1 §5) | Cage runs multiple clients; only one is *visible*. §12 |
| 3 | swaylock as the locker under cage (r1 §5) | Cage implements no session-lock protocol; upstream issue open. §4, §12 |
| 4 | Stage 2 validates "hibernation resume" (r1 §13) | QEMU validates the plumbing, not hibernation in fact. §14 |
| 5 | "deterministic, non-colliding port block" (r1 §8) | A hash is not non-colliding. Needs detection, a registry, and a lock. §8 |
| 6 | Worktree and dm-crypt figures narrated as "measured" | Qualified inline as reported. §8, §11, §17.2 |
