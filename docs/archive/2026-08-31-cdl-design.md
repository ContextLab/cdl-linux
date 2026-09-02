# CDL Linux — Product and Architecture Overview

**Status:** **Frozen for implementation** · **Revision:** 2.3 · **Date:** 2026-08-31 · **Repo:** `ContextLab/cdl-linux`

A focused coordination appliance for supervising concurrent LLM agent work, delivered as an
installable Linux distribution.

> **This document is frozen.** It has converged, and it should stop being the project's centre of
> gravity. Amend it only when a spike, a hardware capture, or a component spec produces genuinely new
> evidence — not to refine wording. The next real progress comes from M0's hardware facts,
> `cdl-agent-lifecycle`, and spikes 1 and 2.
>
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
>
> **Revision 2.1 changes** (a focused correction pass, not a rewrite): split the release into three
> tiers so subsystems stop being launch-blocking all at once (§2.2, D32); made local and ssh+nohup
> the only required job backends, with cloud and HF Jobs as optional adapters gated on a named
> provider and confirmed funding (D30, §16.4); gave spend controls an owner (D33, DR12); corrected
> spike 1, where option C could not satisfy its own pass condition (§9, D34); corrected the threat
> model's overstated T1 residual and its treatment of worktrees as a security boundary, and added
> six agent-specific threats (§5); named the sshd startup design as a sub-problem (§7); fixed the M0
> committed-versus-gitignored contradiction (§6); added M3's restore boundary (§6); and tightened
> eight acceptance tests that did not fully test their requirements (§10).
>
> **Revision 2.3** (amended under the freeze rule, on M0 evidence and one new requirement): recorded
> R18/D35/P8 — docking station and external monitor, which independently reinforce D34; noted that
> M0 retired the **mixed-media striping concern only** — both drives are NVMe and identical, while
> every other RAID0 risk stands, including drive health, which is still unmeasured — confirmed 64 GB
> RAM, and found hibernation unavailable, which is a live §3.2 question. See `notes/hardware/tensorbook-profile.md`.
>
> **Revision 2.2 changes** (final consistency patch): made compositor language consistent with D34
> and rewrote §12 around required session *properties* rather than a chosen implementation, with cage
> as the documented rejected baseline; made the hardware-capture ignore rule fail-closed so the
> committed profile is possible and raw captures are not; removed hibernation from R8's M2 test and
> split it into R8b at M3; gave D29 an explicit failure branch (§3.2); resolved cloud and HF Jobs to
> "optional extension, never blocks a release"; gave thermal policy its real owner (§16.5); stated
> that the registry is local and authoritative rather than distributed (§8); added M1's architecture
> requirement (§6); and corrected the `/etc` credentials rationale plus five acceptance tests (§5,
> §10).

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

### 2.2 Release tiers (D32)

Revision 2 narrowed the implementation *sequence* but not the release *scope*, which left every
subsystem able to become launch-blocking simultaneously. Three named targets fix that:

- **Usable alpha** (M1–M2) — the smallest thing that answers whether the product thesis survives
  contact with implementation. This is what the next several weeks are for.
- **Release candidate** (M3–M4) — adds the custom storage stack, hibernation, and the ISO.
- **Product v1** — the release candidate, accepted by the fresh-wipe gate (D31) and published.

**A capability may only block the milestone its tier assigns it to.** Anything marked optional must
not gate a milestone, and any subsystem that starts behaving as though it were alpha-blocking when
the table says otherwise is scope creep to be pushed back.

| Capability | Alpha (M1–M2) | RC (M3–M4) |
|-|-|-|
| Ubuntu 26.04 LTS base, pinned | ✓ stock install | ✓ custom install |
| Terminal session: compositor + kitty + zellij | ✓ | ✓ |
| macOS/Cmd keybinding layer | ✓ | ✓ |
| Session security / lock path (T2) | ✓ **alpha-blocking** | ✓ |
| Worktree seeding and agent supervision | ✓ | ✓ |
| Job layer, all seven verbs | ✓ | ✓ |
| Job backends: **local + ssh+nohup** | ✓ **required** | ✓ |
| Job backends: cloud, HF Jobs | — | — **optional extension; never blocks M4 or product v1** (§16.4) |
| Job backend: Slurm | — | designed, ships disabled (§16.1) |
| Spend controls, best-effort (D33) | ✓ | ✓ |
| Provider configuration + `cdl doctor` | ✓ | ✓ |
| Local inference + GPU admission | ✓ | ✓ |
| Remote access over the tailnet | ✓ | ✓ |
| Backup + **tested restore** | ✓ | ✓ |
| NVIDIA driver + CUDA + PyTorch | ✓ | ✓ |
| Emacs, croft, LaTeX, text browser, VPN, wifi | ✓ | ✓ |
| Encrypted striped storage + snapshot rollback | — | ✓ |
| Hibernation validated on hardware (D29) | — | ✓ |
| Reproducible remix ISO + apt repository | — | ✓ |
| Documentation | on-disk only | ✓ published |

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
| **D30** | **Full job layer** — the complete verb set (submit / list / status / logs / cancel / artifacts / reconcile). **Required backends are local and ssh+nohup**; those two alone gate the alpha. Cloud and HF Jobs are **optional extensions**: they never block M4 or product v1, and neither may be written until its provider is named and its funding confirmed (§16.4). Local plus ssh already satisfy the remote-coordination thesis; a cloud adapter must not hold up an installable operating system. Slurm is designed and specified but ships disabled until its auth is testable (§16.1). |
| **D31** | **Acceptance is a fresh install onto a fully wiped machine.** Nothing hand-configured on the working machine counts as done until it exists as a package or declarative artifact in the repo. |
| **D32** | **Three release tiers** — usable alpha (M1–M2), release candidate (M3–M4), product v1. A capability blocks only the milestone its tier assigns it (§2.2). |
| **D33** | **Spend controls are owned by `cdl-agent-lifecycle`**, best-effort but not unowned. Minimum: per-job declared budget, per-provider concurrency ceiling, global daily warning and hard-stop where the API permits, runtime and token accounting, cost visible in `cdl status`, and defined behaviour when a provider exposes no reliable cost data. |
| **D34** | **A compositor with a real session-lock protocol is the default answer to T2.** Minimal sway (no panel, launcher, decorations or desktop services) is preferred over cage unless spike 1 finds a cheaper path that actually passes. A proven security protocol outranks "technically not a window manager". **Independently reinforced by R18/P8:** sway handles multi-output and hotplug natively; a single-output kiosk does not. |
| **D35** | **Docking station and external monitor are supported (R18).** The session must survive dock and undock without restarting. A stated operator requirement, not an inference. |

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

### 3.2 D29's failure branch

**Status as of 2026-09-01: this branch is live.** M0 confirmed by direct observation that kernel
lockdown is active (`none [integrity] confidentiality`) and is what hides `disk` from
`/sys/power/state`. Secure Boot and hibernation are mutually exclusive on a stock Ubuntu kernel here.
The choice below is now required before M3, not hypothetical.

D29 makes hibernation a launch requirement on a chassis with documented, severe suspend and
hibernate defects. A launch requirement with no failure branch is how a project accumulates
increasingly desperate kernel workarounds: each one is individually justified because failing is not
permitted. **"A failed spike may change the architecture" applies here too.**

If ten consecutive hardware hibernate/resume cycles cannot be made to pass in M3, the project takes
one of these branches — explicitly, as a recorded decision, not by drift:

1. **Block the release** pending a kernel or firmware fix, and say so publicly rather than shipping a
   feature that works intermittently.
2. **Change the target hardware.** The design is meant to be hardware-profile-driven (D1); a machine
   that cannot hibernate reliably may simply be the wrong first target.
3. **Reconsider D29.** The user downgrades hibernation to an experiment, **R8's orderly-shutdown
   behaviour becomes the shipped behaviour and R8b is dropped**, and the swap sizing stays as-is so
   the decision can be revisited without a reinstall.

**Branch 3 is the only one that does not require restarting work**, which is why R8 is written so
that its M2 behaviour is independently shippable. What is *not* permitted is a fourth branch where
hibernation is nominally required, never actually passes, and the workarounds accumulate.

---

## 4. Hard constraints

Requirements that **cannot be satisfied as originally stated**. Each is stated with its resolution.

| Requirement | Why impossible | Resolution |
|-|-|-|
| Create USB images "via web" | WebUSB classes Mass Storage as a protected interface and rejects `claimInterface()`; the only bypass requires Isolated Web Apps on enterprise-managed ChromeOS. The OS kernel driver already claims the interface. No product does this. | Ventoy stick prepared once natively; thereafter each release is a browser drag-and-drop onto its data partition. Plus documented `dd`/Rufus paths. |
| Fira Code ligatures on the bare Linux console | The kernel console has no TrueType rasterizer (PSF 1-bit bitmaps only), no text-shaping engine, and a 512-glyph ceiling. A ligature is a HarfBuzz GSUB substitution. This is a different rendering model, not a missing feature. | Single fullscreen kitty under a Wayland compositor. See §12. |
| Cmd keybindings + system clipboard on the bare console | `keymaps(5)` documents nine console modifiers, none of which is Super. `console_codes(4)` supports two OSC sequences; OSC 52 is not among them. | Real terminal emulator. See §8. |
| Ship LM Studio or Claude Code on the ISO | LM Studio's terms forbid sublicensing, distributing or transferring the software. Claude Code's license grants no sublicense. | Fetch-on-demand helpers running each vendor's own installer, so the user accepts the license directly and we redistribute nothing. |
| Bake the CUDA **toolkit** into the ISO | The CUDA EULA permits redistribution only for applications with "material additional functionality"; an OS does not qualify. Ubuntu places it in multiverse. | Ship the NVIDIA **driver** (explicitly redistributable for OSI-licensed kernels); pull CUDA at first boot. PyTorch wheels bundle their own CUDA runtime anyway. |
| Redistribute Rhino branding | `rhino-linux/branding`, `/wallpapers`, `/plymouth`, `/lightdm` have **no LICENSE file**; default copyright applies. | Use ContextLab's own MIT-licensed assets. See §13. |
| ~2 TB with any redundancy | Arithmetic: two 1 TB drives give 2 TB with none, or 1 TB mirrored. | Accepted deliberately (D15). Off-machine backup is therefore mandatory, not optional. |
| Fully unattended install | Wifi credentials, LUKS passphrase, API keys and remote-host key enrollment are all irreducibly interactive. | The install is interactive by design. This spec does not claim otherwise. |
| OAuth/SAML login from a text browser | Terminal browsers have no JavaScript engine; modern IdP consent screens are JS SPAs. | Never authenticate on the machine. Pre-generate tokens elsewhere; complete browser flows on another device. |
| **Lock the screen under cage with swaylock** | Cage implements neither `ext-session-lock-v1` nor layer-shell. **Verified:** no `session_lock.c` in the source tree; `cage.c` (716 lines) contains no `session_lock`/`layer_shell` references; upstream issue **#264 "Add support for ext-session-lock-v1" is open**. | **Cage rejected.** Minimal sway plus swaylock is the selected hypothesis (D34), pending spike 1. Autologin remains **not** committed until that spike passes. |

---

## 5. Threat model

The FDE and secrets discussion in revision 1 mixed several threat models. They are separated here.
Full controls and their failure behaviour live in `cdl-security-and-recovery`.

| # | Threat | In v1 scope | Control | Residual risk |
|-|-|-|-|-|
| T1 | Opportunistic theft, machine powered off | Yes | LUKS2 FDE, passphrase at every boot (D7). Swap inside the container, so RAM contents including API keys never hit plaintext disk. | **Low, conditional on a strong passphrase.** Residual: passphrase strength and reuse; offline guessing against the LUKS header; metadata exposed through the unencrypted ESP and `/boot`; boot tampering if the machine is later recovered and reused; and any credential copied *outside* the encrypted volume — backups, paper notes, the user's Mac. Revision 2 said "none material", which was wrong. |
| T2 | Opportunistic access, machine powered on and unattended | Yes | **Currently unresolved.** Autologin plus plaintext keys means opening the lid yields a shell with live credentials; FDE protects only a powered-off machine. | **The live gap in the design.** See §12; blocks the autologin decision. |
| T3 | Malicious local process reading provider keys | Yes | Keys in `~/.config/cdl/providers.env`, mode `0600`, owned by the user. | Any process running *as the user* can still read them. Accepted: this is a single-user machine. |
| T4 | Compromised or misbehaving agent destroying local work | Yes | Bubblewrap process sandbox with an AppArmor profile; `Restart=no`; append-only backup so history cannot be rewritten. **Worktrees are *not* part of this control** — see below. | Sandbox escape; anything the agent is legitimately allowed to reach. |
| T4a | Agent exfiltrates secrets over permitted network egress | Yes | **No control in v1 as designed.** The sandbox's network policy is the only possible boundary and is currently unspecified. | **Open.** `cdl-agent-lifecycle` must define an egress policy, or this is accepted explicitly rather than by omission. |
| T4b | Untrusted repository content as instructions (prompt injection) | Yes | None mechanical. An agent reads the repo it works on, and that content reaches the model. | **Open.** Mitigation is procedural: treat any repo an agent touches as trusted input, and say so. |
| T4c | Destructive push to a git remote | Yes | Append-only backup preserves local history; the remote is not protected by anything on this machine. | **Open.** Candidate: deny-by-default push credentials, or branch protection server-side. |
| T4d | Prompt and source content leaked to model providers | Partial | Provider choice is the only lever. Local models keep content on the machine. | Accepted for API-backed agents; this is what using a provider means. Worth stating so it is a choice, not a surprise. |
| T4e | Agent reads other worktrees, `$HOME`, or other agents' state | Yes | Bubblewrap filesystem policy — **currently unspecified**. | **Open, and the reason worktrees must not be miscounted as isolation.** |
| T4f | One credential set shared by every agent | Yes | Provider keys live in one user-scoped file readable by every agent process. | **Open.** Per-agent credential scoping is not designed. Decide whether it is worth the complexity. |
| T5 | Stolen backup credential | Yes | `rest-server --append-only`: verbatim, it "allows creation of new backups but prevents deletion and modification of existing backups" and "prevents an attacker from wiping your server backups when access is gained to the server being backed up." | An attacker with the laptop can still *read* and decrypt backup history, and can append garbage. Retention pruning must therefore run from the NAS side, not the laptop. |
| T6 | Supply-chain compromise | Partial | Pinned archive snapshot, per-ISO package manifest, checksummed vendored binaries, pinned pacscript commits. | Pacstall source builds and `cargo install` pull unaudited upstream code. Reduced, not eliminated. |
| T7 | Evil maid — physical access to unencrypted `/boot`/ESP | **No — explicitly out of scope** | Secure Boot raises the bar. `/boot` is unencrypted and unmeasured; an attacker with physical access can modify the initramfs to capture the passphrase. | Accepted and stated. Against a targeted adversary with physical access, nothing in an unencrypted initramfs is trustworthy. |
| T8 | Network attacker | Yes | No public ports, ever. OpenSSH bound to the tailnet interface; firewall default deny except `tailscale0`. Key-only auth. | Compromise of the tailnet identity. |

**Worktrees are collision isolation, not a security boundary.** They stop concurrent agents
corrupting each other's git index — which is exactly what the 24/100-commit finding measured — and
they do nothing else. An agent in a worktree can read every other worktree, `$HOME`, and the
provider key file. The security boundary is bubblewrap plus a network policy, both of which
`cdl-agent-lifecycle` must specify. Revision 2 listed worktrees as a T4 control; that was a category
error and is corrected above.

**The T4a–T4f rows are mostly open.** That is deliberate: an agent threat model with honest gaps is more
useful than one that lists a control for every row. Each open row is an input to
`cdl-agent-lifecycle` and `cdl-security-and-recovery`, and none may be closed by assertion.

**On why credentials are user-scoped rather than in `/etc`.** Revision 1 claimed `/etc` would let
"the `ollama` system user and every service on the box" read the keys. That is wrong: a `0600`
root-owned file in `/etc` is no more readable than one in `$HOME`. The real reasons are that
user-scoped credentials match the single-user threat model, keep the keys inside the backup and
restore path that already covers `$HOME`, and avoid the accident that system-wide configuration
invites — services picking up credentials nobody intended to hand them.

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
- **Deliverable:** raw capture stored locally in the **gitignored** `notes/hardware/`, plus a
  **redacted profile committed as `notes/hardware/tensorbook-profile.md`**. The raw output carries
  serial numbers, MAC addresses, UUIDs and hostnames and must not be committed (§15); the profile
  carries the facts the design needs, with identifiers removed.
- **Retain the raw capture off-machine too** — the Tensorbook is wiped three times across M2–M4, and
  a capture that lives only on it is a capture you lose.
- **Exit:** every fact in §15 recorded, including the firmware settings that require a reboot to
  read, and an explicit go/no-go recorded for each of: Intel VMD/RST, dual-NVMe striping viability,
  GPU and display topology, supported sleep states, and RAM-derived swap sizing.
- **Why first:** one-way. Every fact becomes unobtainable after installation, and at least six
  design decisions currently rest on assumptions rather than measurements (§15).

### M1 · Environment prototype — *does the day-to-day feel good?*

- **Entry:** M0 complete (for the wifi/GPU package choices only; otherwise independent).
- **Where:** an Ubuntu 26.04 VM, or any existing Linux box. **Not** the Tensorbook.
- **Architecture matters.** The target and the vendored binaries (zellij, croft) are **amd64**; a VM
  on Apple Silicon is ARM. Either run an amd64 VM, or run ARM for interaction testing *and* validate
  package closure and vendored binaries on amd64 in CI. Interaction work on ARM is fine; concluding
  anything about packages or binaries from it is not.
- **The compositor spike needs a real seat.** Spike 1 tests a Wayland seat and a session-lock
  protocol, which nested windows inside someone else's desktop session cannot exercise. It needs a
  virtual GPU/DRM environment or bare metal.
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

**The restore boundary, stated explicitly.** A full `$HOME` restore would silently undo D31 by
reinstating configuration the repository never learned to reproduce. So M3's restore is partial by
design:

| Category | M3 treatment | Why |
|-|-|-|
| Work: repositories, worktrees, documents | **Restored** | This is the thing backup exists for |
| Job and agent registry state | **Restored** | Durable supervision across a reinstall is a product claim; if it cannot survive this, say so |
| Application state and build artifacts (venvs, caches, `node_modules`) | **Not restored** — regenerated | They are derived. Regenerating proves the seeding hook works |
| Model weights | **Not restored** — re-downloaded from the excluded-weights manifest | They are excluded from backup by design |
| System and user *configuration* | **Not restored — reproduced from the repo** | This is the D31 gate. Anything that only comes back by restore is missing declarative configuration, and that is the defect M3 is designed to expose |
| Secrets: provider keys, restic repo password, SSH identity | **Re-enrolled, not restored** | Re-running enrollment proves the first-boot path works and rotates credentials that existed on a machine now wiped |

**Before M3 starts, record which machine holds the only copy of the hardware knowledge** (the M0
capture) and confirm it exists off-machine.

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
| **`cdl-security-and-recovery`** | Threat model in full, including every open T4a–T4f row; secrets at rest and leakage during install; remote access; snapshot and rollback design; backup schedule, retention, encryption, failure notification, consistency, restore verification, bare-machine recovery, RPO/RTO | Review findings #2, #4, #5. Also the D26 recovery posture, the T2 session-lock gap, and the **sshd startup design** below |
| **`cdl-agent-lifecycle`** | Agent **and job** state machines; PTY ownership and attachment protocol; blocked/waiting/complete detection; exit status; prompt and launch-command recording; cancellation; worktree ownership and reconciliation after crashes; resume without replay; **sandbox filesystem and network policy** (closing T4a and T4e); port allocation registry; SQLite schema and migrations; GPU admission; **spend controls per D33**; provider and global concurrency limits; `cdl status` output contract; local and ssh backend contracts | Review findings #6, #7. Also D28's three-location model, D30's backend split, and the Slurm extension plan. **Write this one first** — it holds the differentiating functionality and drives M1. Limit its first executable slice to one local interactive agent, then prove spike 2 |
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

**The sshd startup design is a named sub-problem, not a one-line setting.** "OpenSSH bound to the
tailnet interface" is right in intent and fragile in practice: the tailnet address may not exist when
sshd starts, and a `tailscaled` restart can change interface readiness — while remote access is the
only way back into a machine whose display has broken. The spec must compare four approaches and
pick one with stated failure behaviour:

1. Listen on all interfaces, enforce the boundary purely in firewall rules
2. Bind explicitly, with systemd ordering and a restart policy that survives `tailscaled` restarts
3. A socket unit tied to tailnet readiness
4. Tailscale SSH — noting that restarting the daemon terminates existing Tailscale SSH sessions

The acceptance test must probe **each non-tailnet interface by name** — physical LAN and any
public-facing address — not an unspecified "from outside".

### 7.1 Where revision 1's content went

Restructuring is the easiest way to lose content silently. This table exists so the loss can be
checked rather than trusted. Every revision 1 section is accounted for; where mechanism left this
document without a written destination, the source material is in `notes/` and the receiving spec
must reconcile against it before it is called complete.

| Revision 1 section | Destination |
|-|-|
| §1 Purpose and design philosophy | §1, sharpened thesis added |
| §2 Decision record | §3, extended with D26–D31 |
| §3 Hard constraints | §4, plus one new row (the compositor locking constraint) |
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
| §15 Open items | §16. Item 15.1 (backup target) closed by D27; 15.4 (reproducible builds) → `cdl-install-and-packaging` and DR11; 15.5 (spend controls) **closed by D33** — owned by `cdl-agent-lifecycle`, tested as DR12 |
| §16 Evidence standards | §17, with qualifications moved inline to the claims themselves |

---

## 8. Architecture at a glance

```
                       ┌───────────────────────────────────────────┐
   attention surface   │  compositor → kitty → zellij → cdl status │   one visible thing
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
   durable state       │  job + agent registry (SQLite, WAL)       │   local authoritative registry,
                       │  port allocation registry (locked)        │   tracking execution across
                       │                                           │   three locations
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

**Why the registry is SQLite, not per-worktree JSON.** D28 puts agents in three *locations* and D30
requires reconciliation across them. Per-worktree JSON with multiple concurrent writers on one
machine would require inventing transactional file handling; SQLite in WAL mode provides it. This
reverses revision 1's implied design.

**The registry is local and authoritative — it is not a distributed database.** It runs on the
Tensorbook and records work executing elsewhere; remote hosts hold no replica and are never written
to directly. `cdl-agent-lifecycle` must therefore state explicitly that **the WAL database must never
live on NFS or SMB** (where WAL locking is unreliable), and must define its backup treatment, schema
migration, corruption recovery, and — the case restore actually creates — **reconciliation of
restored-but-stale records whose remote process no longer exists.**

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
the Wayland session uses XKB — or the rescue console behaves differently from the session.

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

**Start from minimal sway** (D34's default hypothesis) — authenticated tty login → sway → kitty →
zellij → swaylock — with croft and literal Super keybindings in place, and cage compared only as the
rejected baseline.

The swaylock-under-cage sub-question is **already answered and needs no spike**: cage implements
neither `ext-session-lock-v1` nor layer-shell (§4). What the spike must decide is which of three
designs to adopt:

| Option | Mechanism | Verdict |
|-|-|-|
| **A. Different compositor** — *the default (D34)* | Replace cage with one implementing `ext-session-lock-v1`: minimal sway or labwc with no panel, launcher, decorations or desktop services | **Can satisfy the pass condition.** Costs a config file and more surface area than a 77 kB kiosk. A proven security protocol outranks kiosk purity |
| **B. Hibernate as the lock** | Lid close and idle trigger **hibernation**, not suspend; resume requires the LUKS passphrase, a genuine credential barrier | **Cannot gate the alpha.** Hibernation is not validated until M3 (D29), so making session security depend on it couples the alpha to the highest-risk hardware feature. Viable as a *second* layer later |
| **C. No autologin** | Conventional authenticated getty login; the compositor starts from the user's profile; no in-session locker | **Insufficient alone.** It protects the boot path, not an already-open session, so by itself it cannot meet the pass condition below. It is a necessary component, not a solution |

**Option C needs a partner mechanism** to close T2 — one of: terminate the session on lid close or
idle; switch to a locked login VT while killing the credentialed session; or a compositor with real
session-lock support, which is option A. Revision 2 listed C as a standalone option; that was wrong,
because the pass condition below is about an open session and C does not touch one.

**Pass condition:** an unattended lid-open does not yield a shell with live credentials, demonstrated
end to end — including what happens when the lock component itself crashes, and how tty2 recovery
still works. **Until this passes, autologin is not committed** and threat T2 stays open.

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
| R1 | Provider APIs built in; keys collected at setup | first-boot-and-environment §providers | M1 | `cdl doctor` makes **one minimal, bounded-cost** live call per configured provider — smallest model, fewest tokens, documented worst-case spend — and reports which keys work. **Keys must be redacted in all output and logs**, including on failure paths, where they most often leak |
| R2 | Two drives as one ~2 TB volume | install-and-packaging §storage | M3 | `lsblk` shows the four-layer stack; `df` shows a single ~1.85 TiB filesystem |
| R3 ⚠ | emacs + croft preinstalled | first-boot-and-environment §editors | M1 | Both launch; croft renders Nerd Font glyphs not `[?]`; **Emacs LLM integration (gptel/ellama) configured and answering** |
| R4 | macOS-native keybindings | agent-lifecycle §keybindings (generation); overview §8 | M1 | Generated configs diffed against the source table in CI; Cmd-S/Z/C verified not to emit XOFF/SIGTSTP/SIGINT |
| R5 | Everything a TUI; no GUI | overview §12; install §manifest | M1 | No display manager, no notification daemon, and no **browser application** — defined as an installed executable capable of rendering and navigating the web with a JavaScript engine. Asserted over the **installed package closure**, not just the manifest, since dependencies pull in what the manifest excludes. A rendering *library* (WebKit as someone's dependency) does not violate this; a launchable browser does. State the rule this way or the test is unfalsifiable |
| R6 | Native CUDA/NVIDIA | first-boot-and-environment §cuda | M2 | `nvidia-smi` and a PyTorch CUDA tensor op on the real GPU |
| R7 ⚠ | ollama + LM Studio; models chosen at install; easy to add later | first-boot-and-environment §models | M2 | Model picker gated on measured VRAM; disk quota and GC policy enforced — a pull that would exceed the ceiling is refused; **and the LM Studio fetch-on-demand helper runs the vendor installer so the user accepts the license directly, verified end to end (§4)** |
| R8 ⚠ | Wifi drivers + modern conveniences | first-boot-and-environment §network, §power | M2 | Wifi connects via nmtui; lid-close during a running agent does not suspend; **critical battery warns early, refuses to start new long jobs below a threshold, and performs an orderly shutdown**. Hibernation is deliberately *not* part of this test — see R8b |
| R8b | Critical battery hibernates rather than shutting down | first-boot-and-environment §power | **M3** | Critical battery hibernates and resumes with work intact. Replaces R8's orderly shutdown once D29 is validated; if D29 fails (§3.2), the M2 behaviour stands as the shipped behaviour |
| R9 | LAN backup | security-and-recovery §backup | M2 | A restore drill onto a clean machine **re-establishes** work, system configuration, repository keys, SSH identity, restic credentials and registry state — not merely `$HOME`. Secrets are deliberately **re-enrolled rather than restored** (§6, M3 restore boundary), so the drill exercises enrollment. It must also **reconcile restored job records whose remote process no longer exists** — the state a restore reliably produces |
| R10 ⚠ | Full apt support | install-and-packaging §apt-policy | M2 | Ownership policy documented per package class; third-party pins in `/etc/apt/preferences.d`; `unattended-upgrades` posture decided and tested |
| R11 | python + PyTorch + HF for CUDA | first-boot-and-environment §python | M2 | CUDA tensor op; HF cache location and ceiling configured |
| R12 ⚠ | LaTeX distribution | first-boot-and-environment §latex | M2 | A document builds; **profile and installed size explicitly chosen against the ISO budget** |
| R13 ⚠ | Full docs with screenshots | install-and-packaging §documentation | M4 | VHS PNG diffs pass in CI; docs present on-disk offline; **boot/installer/GRUB captures produced by QEMU framebuffer, not VHS** |
| R14 ⚠ | Text-based browser | first-boot-and-environment §browser | M1 | w3m or lynx installed. **Must be non-JS by capability — Browsh and Carbonyl are excluded; Carbonyl is Chromium in a terminal, with WebGL and video** |
| R15 ⚠ | VPN support | first-boot-and-environment §vpn | M2 | GlobalProtect connects headlessly and survives a multi-hour unattended run, **or** an off-VPN bastion path is documented instead |
| R16 | Easy installable-USB creation | install-and-packaging §distribution | M4 | **A physical machine boots the ISO from a Ventoy stick, with Secure Boot in the same state intended for the Tensorbook** — a boot test under a different posture proves nothing about the real one. Compatibility assumed until demonstrated. Plus `dd` and Rufus paths documented and tested |
| R17 | Fira Code with ligatures | overview §12 | M1 | Ligatures render in kitty; icon glyphs come from the fallback, not a patched font |
| R18 | **Docking station + external monitor** (D35) | overview §12 P8; first-boot-and-environment §display | M2 | Dock and undock with a session running and agents attached: outputs appear and disappear, the session survives, no restart needed, and the terminal is usable on the external display. Output layout is remembered across dock cycles |
| DR1 | Several agents concurrently (D8/D28) | agent-lifecycle | M2 | The full D28 working shape runs overnight unattended |
| DR2 | Long-lived unattended sessions (D9) | agent-lifecycle §supervision | M2 | Agent survives logout, **termination and restart of kitty/zellij** (not a machine reboot — D26 means a reboot needs the passphrase), and network loss |
| DR3 | Remote job launching (D10/D30) | agent-lifecycle §jobs | M2 | All seven verbs against the GPU host; reconcile recovers a job whose launcher died |
| DR4 | Remote access (D11) | security-and-recovery §remote-access | M2 | SSH from the Mac over the tailnet succeeds; **every non-tailnet interface enumerated by name and probed** — physical LAN and any public address — shows no listening service. Plus the sshd startup behaviour survives a `tailscaled` restart (§7) |
| DR5 | Snapshot + rollback (D5) | security-and-recovery §snapshots | M3 | A deliberate bad update is rolled back from the boot menu |
| DR6 | FDE (D7) | install-and-packaging §storage | M3 | Passphrase required at boot; swap inside the container verified |
| DR7 ⚠ | Hibernation (D25/D29) | install-and-packaging §storage; environment §power | M3 | **Ten consecutive hibernate/resume cycles on hardware, plus documented recovery from a failed resume** |
| DR8 ⚠ | Screen lock / session security (T2) | security-and-recovery §session | M1 | Spike 1 option demonstrated; unattended lid-open does not yield a live-credential shell |
| DR9 ⚠ | First-run experience | first-boot-and-environment §first-run | M2 | First boot on a fresh install is resumable and idempotent; an interrupted provisioning run recovers |
| DR10 ⚠ | Offline behaviour | first-boot-and-environment §offline | M2 | Machine boots, opens a session and reports provider unavailability clearly with no network |
| DR11 | Reproducible build | install-and-packaging §reproducibility | M4 | **Target:** two builds of one commit produce byte-identical ISOs. **Fallback standard, if signing or bootstrap artifacts make that infeasible:** identical package manifests and normalised filesystem contents, with every remaining difference enumerated and explained |
| DR12 | Spend controls (D33) | agent-lifecycle §budget | M2 | A job exceeding its declared budget stops; the per-provider concurrency ceiling is enforced; a daily threshold warns and a hard stop halts new work where the API permits; `cdl status` shows cost; behaviour is defined and tested for a provider exposing no reliable cost data |

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

**Stated as required properties, not as a chosen implementation.** D34 names minimal sway as the
default hypothesis, but spike 1 has not run. Until it does, this section says what the session must
do; §9 says how the candidate is chosen.

### 12.1 Required session properties

| # | Property | Why |
|-|-|-|
| P1 | One visible full-screen terminal; no panel, launcher, decorations, desktop services or mouse-driven applications | Principle 1: singularity in attention. The session is a boundary, not a desktop |
| P2 | GPU-accelerated terminal with truecolor and Nerd Font glyphs | croft's own README requires "A Nerd Font as your terminal font — without one they render as `[?]` boxes" and "A 256 color or truecolor terminal." The bare console satisfies neither, so the flagship editor would be visibly broken on the purist option. This is evidence, not aesthetics |
| P3 | Programming ligatures | R17, and unachievable on the kernel console (§4) |
| P4 | **A working lock path that leaves no credentialed shell exposed** | Threat T2. This is the property that eliminated the previous candidate |
| P5 | Literal Super/Cmd keybindings delivered to applications | R4, and the reason zellij replaces tmux (§8) |
| P6 | A rescue path independent of the compositor | A broken GPU driver must never leave the machine unreachable — a getty on tty2 |
| P7 | Defined behaviour when the locker or compositor crashes | An unattended machine must fail closed, not into a live shell |
| P8 | **Multiple outputs, with hotplug** — dock and undock while the session runs, without restarting it | **New requirement (R18), stated during M0.** The operator uses a docking station and an external monitor. A session that must be restarted to gain or lose a display is not usable on a laptop that docks |

### 12.2 Session path

Boot → **authenticated login on tty1** → candidate compositor → one fullscreen **kitty** → **zellij**
for multiplexing. Rescue getty on tty2.

> **Autologin is not committed.** Revision 1 specified it. Combined with plaintext API keys, opening
> the lid would yield a shell with live credentials (T2). Autologin is adopted only if spike 1
> produces a lock path that passes, and per §9 option C ("no autologin") is a component of the answer
> rather than the whole of it.

### 12.3 Why cage is the rejected baseline

Revision 1 selected cage and proposed swaylock under it. **Cage implements neither
`ext-session-lock-v1` nor layer-shell** — verified against the source tree (no `session_lock.c`; no
matches for `session_lock`/`layer_shell` in the 716-line `cage.c`) and confirmed by open upstream
issue **#264, "Add support for ext-session-lock-v1."** It therefore fails P4, which is disqualifying.

**It very likely fails P8 as well.** Cage is a single-output kiosk, and research flagged early that
"whether cage (a single-output kiosk) handles hotplug at all is unknown and unresearched." The
docking requirement arrived after cage had already been ruled out on P4, so two independent
disqualifications stand — not worth a spike to confirm.

`physlock` is not an equivalent substitute: it draws its prompt on the VT, which the compositor
occupies as DRM master, so the prompt would not be visible. *That step is reasoning from the display
model rather than a test — confirm it in spike 1 rather than treating it as established.*

Two cage facts are worth keeping on record because revision 1 stated them wrongly: its man page says
*"Cage runs a single, maximized application. Cage can run multiple applications, but only a single
one is visible at any point in time"* — the constraint is one **visible** client, not one client; and
upstream describes it as not fitting "into a regular desktop-style workflow", which is a virtue for
P1 and irrelevant to P4.

### 12.4 Independent of the compositor choice

**Fonts.** `fonts-firacode` **unpatched** plus `fonts-nerd-symbols` as a fontconfig fallback — not a
Nerd-patched Fira Code. Patching frequently damages GSUB ligature tables; fallback preserves Fira
Code's ligatures *and* supplies the icon glyphs croft needs (P2, P3).

**Console legibility.** On a 2560×1440 15" panel the default VT font is unreadable. An explicit large
PSF (`setfont`) and a chosen kitty `font_size` are required, not optional (P6 — the rescue console
has to be usable).

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
| **2 · QEMU + OVMF, two emulated NVMe controllers** | Storage layout, boot, installer, LUKS+RAID0+LVM+btrfs, **the hibernation storage plumbing and initramfs configuration**, systemd units, candidate compositor + kitty session | No |
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

> **`scripts/capture-hardware.sh` is authoritative for the command list.** Revision 2 duplicated the
> commands here, which immediately drifted from the script. This section now states the *facts
> required* and the decisions each one gates; the script states how they are obtained, and the two
> cannot disagree because only one of them lists commands.

**Handling.** Raw output goes to `notes/hardware/`, **which is gitignored** — it contains serial
numbers, MAC addresses, filesystem UUIDs and hostnames, and D1 commits to keeping personal data out
of a publishable artifact. The committed artifact is `notes/hardware/tensorbook-profile.md`: redacted
*facts* ("two 1 TB NVMe drives, 512-byte logical and reported physical sectors"), never raw
command output. Describe sector geometry only as the device reports it — "512e" specifically means
512-byte logical over 4096-byte physical, and claiming it without a 4096 physical reading is a claim
about the hardware that the capture does not support. Keep a copy of the raw
capture off-machine; the Tensorbook is wiped three times across M2–M4.

### 15.1 Facts required, and what each one decides

| Fact | Decides | Go/no-go |
|-|-|-|
| Exact model and BIOS version **and release date** | Which documented chassis quirks apply; whether a firmware update exists | |
| Secure Boot state, and whether it can be disabled | Signed-module requirement; whether MOK enrollment joins the interactive install steps | |
| TPM presence — device nodes **and** `systemd-cryptenroll --tpm2-device=list` | Gates every TPM option. D7 rejected TPM auto-unlock, so this is recorded for completeness while it is knowable | |
| **Both drives NVMe, or one SATA?** | The entire striping design. At least one documented Tensorbook shipped 1 TB NVMe + 1 TB M.2 SATA, which would make striping actively harmful | ✅ **go/no-go** |
| Physical and logical sector sizes | The LUKS `--sector-size 4096` tuning | |
| SMART wear and error history | Whether either drive is already suspect — decisive under RAID0, where either failure loses everything | ✅ **go/no-go** |
| **Measured RAM** | Swap size, and therefore the whole LVM layout. Currently assumes 64 GB from a vendor launch post rather than measurement; under D29 this is a launch-requirement input | ✅ **go/no-go** |
| GPU model, VRAM, driver, power and thermal limits | Local-model picker ceiling; the sustained-load thermal question (§16.5) | |
| DRM connector and provider topology; which driver is *bound* | Whether the console comes from `i915`/`simpledrm` or `nvidia-drm` — the session and rescue-console design | ✅ **go/no-go** |
| Supported sleep states (`mem_sleep`, `state`) | Whether hibernation is offered at all, and s2idle vs deep S3 — the root of the known Razer suspend quirks | ✅ **go/no-go** |
| Battery design capacity and critical-power behaviour | Critical-battery policy; UPower's default chain ends in PowerOff, which on an FDE machine means total session loss | |
| Wifi chipset and bound driver | The firmware package that must ship on the ISO | |
| Existing kernel command line | Workarounds already applied to this machine | |

### 15.2 Firmware settings — requires a reboot into setup

Not obtainable from a running system, and not optional.

- **Intel VMD/RST mode.** ✅ **go/no-go, and the highest-consequence fact here.** If storage is in
  VMD/RST mode and it cannot be disabled, a stock installer sees no disks at all and the project
  stops.
- **Chipset graphics: Dedicated GPU Only vs Dynamic Display Switch.** Decides the console path with
  the DRM topology above.
- **Secure Boot: enabled, and can it be disabled?**
- **Any BIOS password set?**

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

### 16.3 NAS make and model

D27 selects the design shape but the capability probe (SSH → container → SFTP → SMB) must run before
`cdl-security-and-recovery` can be finalised.

### 16.4 Cloud provider identity, and whether HF Jobs is funded

**"Cloud" is not a backend.** AWS Batch, RunPod, Lambda Cloud, Modal and a raw cloud VM have
materially different lifecycle, artifact and billing semantics. D30 requires **exactly one named
provider** before the cloud adapter is written.

**HF Jobs is entitled but was measured unfunded.** Revision 1 cited the org's `academia` plan and the
token's `jobs` scope as evidence HF Jobs was "a genuinely available remote compute target." That
conflates entitlement with availability. Research separately recorded, and this correction rests on
it: *"HF Jobs 401 in scheduled CI (expired HF_TOKEN) and 402 in manual runs (unfunded account)."* A
402 is Payment Required — the account is authorised but cannot run jobs.

Before either adapter is written, decide and record:

- The one cloud provider for v1
- Whether HF Jobs will be funded, or whether the backend is dropped
- What "artifacts" means for each backend concretely — a path, an object URL, a retention window
- Which job states are common to all backends and which are backend-specific
- Cost limits and what cancellation actually guarantees per backend
**Resolved, so it stops being ambiguous:** an unavailable backend **never** blocks a release. Cloud
and HF Jobs are optional extensions that ship when they are ready, before or after v1. The tier table
(§2.2) and D30 both now say this in the same words.

The check that settles the HF half is a single minimal job submission, which costs money and
therefore needs the user's consent rather than being run speculatively.

### 16.5 Sustained thermal load

A verified first-hand report on this chassis says "I have not been able to do any fan control at
all." D28 puts 1–2 local agents on the laptop GPU, so multi-hour local load is a real use case and
thermals are a first-class risk.

**This is an open question, not an unowned one.** Revision 2.1 said unowned, which contradicted §7 —
`cdl-first-boot-and-environment` already owns power, lid, battery and thermal policy. The work splits:

- **M0** ✅ **done.** Measured 2026-09-01: **no fan speed inputs and no writable PWM controls
  exist**, so the reported "no fan control at all" is confirmed on this unit rather than being
  hearsay. An `acpi_fan` device is present but exposes neither. 29 cooling devices exist — those are
  `intel_pstate` and the thermal zones, i.e. throttling, not fans. Idle `x86_pkg_temp` 52 °C.
- **M2** runs a controlled sustained-load test and records the steady-state thermal behaviour.
- **`cdl-first-boot-and-environment`** owns the resulting policy. Given the M0 result, that policy
  **cannot rest on fan control** — it has to be throttling, temperature thresholds, whether sustained
  local inference requires AC power, and **refusal to launch local jobs when conditions are
  unsafe**, which makes it an input to GPU admission control in `cdl-agent-lifecycle`.

What remains open is the M2 sustained-load measurement: what steady state this chassis actually
reaches under a multi-hour local inference run, given that nothing can spin the fans faster.

### 16.6 Which GPU drives the docked external monitor

**Deliberately deferred, not forgotten.** R18/D35 are recorded and the compositor decision (D34) does
not depend on the answer — sway is chosen on P4 and P8 regardless of which GPU owns the dock's
output. What the answer changes is narrow: one line of recovery planning, and the connector names in
the output-layout configuration.

The measured topology says `HDMI-A-1` and `DP-5`…`DP-8` are on the NVIDIA GPU while `DP-1`…`DP-4` are
on the Intel iGPU, so both outcomes are live:

- **Dock on an NVIDIA connector** → a docked external monitor depends on the NVIDIA driver, and
  recovery planning must assume a broken driver costs the external display even though the internal
  panel survives.
- **Dock on an Intel connector** → it does not, and the "milder failure mode" conclusion holds
  docked as well as undocked.

**Why it is deferred:** the operator shares one docking station between the Tensorbook and their Mac,
so the test costs a physical swap rather than a command. It is not worth that until the Tensorbook is
docked anyway.

**Resolution:** run `sudo scripts/capture-followup.sh` during M2, when the machine is docked in normal
use. It walks both observations and names the connector. Until then this is an open parameter in
`cdl-first-boot-and-environment` §display — an unknown with a known resolution step, not a placeholder.

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
  the Marotta & Acquisti finding (§1.3); the **HF Jobs 401/402 results** (§16.4) — load-bearing for
  dropping HF Jobs from the required backends, and settled by one minimal job submission whenever the
  user chooses to spend that money.

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

**Corrections made in revision 2.1**

| # | Revision 2 said | Correction |
|-|-|-|
| 7 | T1 residual risk is "none material" (r2 §5) | Overstated. Low *conditional on a strong passphrase*, with five named residuals. §5 |
| 8 | Worktree isolation is a control against a malicious agent (r2 §5) | Category error. Worktrees are collision isolation; the security boundary is bubblewrap plus network policy. §5 |
| 9 | Spike 1 option C ("no autologin") is a standalone option (r2 §9) | It cannot satisfy its own pass condition, which concerns an already-open session. It is a component, not a solution. §9 |
| 10 | "v1" as a single scope (r2 §2.2) | Every subsystem became launch-blocking at once. Split into alpha / RC / product v1. §2.2, D32 |
| 11 | Job backends "local, ssh+nohup, cloud, HF Jobs" as one commitment (r2 D30) | "Cloud" is not a backend. Only local and ssh+nohup are required; the others need a named provider first. D30, §16.4 |
| 12 | HF Jobs is "a genuinely available remote compute target" (r1 §9) | Conflates entitlement with funding. The token carries the `jobs` scope, and research measured **402 Payment Required** on manual runs. §16.4 |
| 13 | Spend controls unowned (r2 §16.3) | Owned by `cdl-agent-lifecycle`, tested as DR12. D33 |
| 14 | M0 output "committed to `notes/hardware/`" (r2 §6) | Contradicted §15, which gitignores it. Raw stays local; a redacted profile is committed. §6, §15 |
| 15 | §15 duplicated the script's command list (r2 §15) | The two drifted immediately. §15 now states facts required; the script is authoritative for commands |

**Corrections made in revision 2.2**

| # | Revision 2.1 said | Correction |
|-|-|-|
| 16 | D34 prefers sway, while five normative sections still prescribed cage | The clearest internal contradiction in the document. §12 now states required session properties; cage is the documented rejected baseline. §4, §8, §9, §12, §14 |
| 17 | M0 commits `notes/hardware/tensorbook-profile.md` | `.gitignore` made that impossible. Now fail-closed with explicit allows |
| 18 | R8's M2 test required critical battery to hibernate | That made hibernation alpha-blocking, contradicting the tier table. Split into R8 (orderly shutdown, M2) and R8b (hibernation, M3) |
| 19 | D29 is a launch requirement, with no failure branch | A requirement that may not fail accumulates workarounds. Three explicit branches recorded. §3.2 |
| 20 | Cloud and HF Jobs "optional… before M4", with §16.4 still asking if they block the release | Ambiguous. Resolved: optional extensions that never block M4 or product v1 |
| 21 | Thermals have "no current owner" (r2.1 §16.5) | Contradicted §7. `cdl-first-boot-and-environment` owns the policy; M0 and M2 supply the measurement |
| 22 | The registry "spans three machines" | Implies distributed SQLite. It is a local authoritative registry tracking execution across three locations. §8 |
| 23 | `/etc` "would let the `ollama` system user and every service read" the keys | False — mode and ownership apply in `/etc` too. The real rationale is the single-user threat model and the backup path. §5 |
| 24 | M1 runs in "a VM on the Mac" | On Apple Silicon that is ARM, while the target and vendored binaries are amd64. Architecture requirement stated. §6 |
