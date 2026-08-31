# CDL Linux — Design Specification

**Status:** Draft for review · **Date:** 2026-08-31 · **Repo:** `ContextLab/cdl-linux`

An LLM-first, TUI-only Linux distribution for terminal-based agent coordination.

---

## 1. Purpose and design philosophy

### 1.1 What this is

A fully installable Linux distribution, delivered as a remix ISO, whose purpose is **coordinating LLM
agents from a terminal**. The first target is a Lambda Tensorbook that will be fully wiped on install.

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

**"Focused by construction" is unachievable and the spec does not claim it.** The system provides
full `apt` and a text browser; between them, anything can be installed and the whole web is
reachable. A machine its owner administers cannot prevent its owner from being distracted.

What is achievable is **focus by default, with friction rather than prohibition**: distractions are
absent, unadvertised, and not one keystroke away. The focused path is the path of least resistance.
Every design decision below serves that formulation, not the stronger one.

### 1.4 Governing principles

1. **Parallelism in execution, singularity in attention.** The machine runs N agents concurrently;
   the human-facing surface presents one thing at a time, with the rest reduced to a status line and
   a queue. You go to the work; the work does not come to you.
2. **The terminal is the substrate, not the fallback.** Every capability is reachable as text, every
   configuration is declarative, no capability is interactive-only.
3. **Supervision is solved; isolation is not.** Use systemd for what systemd does. Build only the
   glue that does not exist.
4. **Human ergonomics win.** The primary operator is a person, agent-assisted — not the reverse.
5. **Opinions are packages.** Every default ships as an independently removable unit.

### 1.5 What the target machine actually is

Measured during design: the lab's remote GPU host has **4× RTX A6000 (~192 GB VRAM), 64 cores, 503 GB
RAM**. The Tensorbook has a single laptop GPU. Serious training and large-model inference belong on
the remote host.

**The Tensorbook is therefore a coordination surface, not a compute box.** This strengthens rather
than weakens the thesis, and it is why the remote-job layer is core rather than peripheral.

---

## 2. Decision record

Decisions are numbered as recorded during design. All were confirmed by the user.

| # | Decision |
|-|-|
| D1 | Audience: **personal-first, publishable**. Hardware config behind a profile layer; no personal data in the image; real docs. |
| D2 | "No GUI" means capability-over-purity; the display-stack call was delegated. |
| D3 | Primary operator: **the user, agent-assisted**. Human ergonomics win conflicts. |
| D4/D15 | Storage: **one flat 2 TB striped volume**. Total loss on single-drive failure accepted, reaffirmed after being shown the risk math. |
| D5 | **Snapshot + rollback** before every update. |
| D6 | Secrets: **plaintext config under full-disk encryption**. 1Password explicitly rejected (no paid-subscription dependency). |
| D7 | **LUKS full-disk encryption, passphrase at every boot.** Not TPM auto-unlock. |
| D8 | **Several agents concurrently on one repo.** |
| D9 | **Long-lived unattended sessions** are common and important. |
| D10 | Local GPU for local models; remote job launching also required. |
| D11 | **Remote access from other machines** required. |
| D12 | True motivation is **attention**, not performance. |
| D16 | Build path: **Docker prototype → working machine → full ISO**. |
| D17 | A second working computer (the user's Mac) is available. |
| D19 | Base: **Ubuntu 26.04 LTS, pinned.** Not a rolling `devel` base. |
| D22 | Artifact: **true remix ISO**, not a package-set overlay. |
| D23 | Orchestration: **minimal glue over systemd** (delegated to implementer). |
| D24 | Name: **`cdl`** / repo `cdl-linux`. |
| D25 | **Hibernation enabled**; swap ≥ RAM. |

### 2.1 Rejected alternatives and why

- **Rolling `devel` base (Rhino's actual base).** Rhino's own documentation calls it "unstable" and
  "strongly advised against using this in a production setting." It forces NVIDIA onto DKMS on a
  machine with no GUI fallback. Comparison of archive indexes showed 26.04 LTS ships *identical*
  libc6, gcc, python3, rustc, golang, git, llvm and neovim, and is currently **ahead on the kernel**
  (7.0.0-30.30 vs 7.0.0-14.14). Rolling was buying newer systemd and a much worse NVIDIA story.
- **1Password for secrets.** Works headlessly, but on a GUI-less machine it relocates the plaintext
  secret rather than eliminating it — either 30-minute re-authentication or a service-account token
  on disk.
- **Bare kernel VT.** See §5.
- **tmux.** See §6.

---

## 3. Hard constraints

Requirements that **cannot be satisfied as originally stated**. Each is stated with its resolution.

| Requirement | Why impossible | Resolution |
|-|-|-|
| Create USB images "via web" | WebUSB classes Mass Storage as a protected interface and rejects `claimInterface()`; the only bypass requires Isolated Web Apps on enterprise-managed ChromeOS. The OS kernel driver already claims the interface. No product does this. | Ventoy stick prepared once natively; thereafter each release is a browser drag-and-drop onto its data partition. Plus documented `dd`/Rufus paths. |
| Fira Code ligatures on the bare Linux console | The kernel console has no TrueType rasterizer (PSF 1-bit bitmaps only), no text-shaping engine, and a 512-glyph ceiling. A ligature is a HarfBuzz GSUB substitution. This is a different rendering model, not a missing feature. | Single fullscreen kitty under `cage`. See §5. |
| Cmd keybindings + system clipboard on the bare console | `keymaps(5)` documents nine console modifiers, none of which is Super. `console_codes(4)` supports two OSC sequences; OSC 52 is not among them. | Real terminal emulator. See §6. |
| Ship LM Studio or Claude Code on the ISO | LM Studio's terms forbid sublicensing, distributing or transferring the software. Claude Code's license grants no sublicense. | Fetch-on-demand helpers running each vendor's own installer, so the user accepts the license directly and we redistribute nothing. |
| Bake the CUDA **toolkit** into the ISO | The CUDA EULA permits redistribution only for applications with "material additional functionality"; an OS does not qualify. Ubuntu places it in multiverse. | Ship the NVIDIA **driver** (explicitly redistributable for OSI-licensed kernels); pull CUDA at first boot. PyTorch wheels bundle their own CUDA runtime anyway. |
| Redistribute Rhino branding | `rhino-linux/branding`, `/wallpapers`, `/plymouth`, `/lightdm` have **no LICENSE file**; default copyright applies. | Use ContextLab's own MIT-licensed assets. See §9. |
| ~2 TB with any redundancy | Arithmetic: two 1 TB drives give 2 TB with none, or 1 TB mirrored. | Accepted deliberately (D15). Off-machine backup is therefore mandatory, not optional. See §8. |
| Fully unattended install | Wifi credentials, LUKS passphrase, API keys and remote-host key enrollment are all irreducibly interactive. | The install is interactive by design. This spec does not claim otherwise. |
| OAuth/SAML login from a text browser | Terminal browsers have no JavaScript engine; modern IdP consent screens are JS SPAs. | Never authenticate on the machine. Pre-generate tokens elsewhere; complete browser flows on another device. |

---

## 4. §1 — Storage and boot

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

**Tuning.** `--sector-size 4096` on the LUKS container (measured ~1994 MB/s vs ~1130 MB/s at the
512-byte default — this recovers most of what striping was meant to buy), `--allow-discards
--persistent`, and `fstrim.timer` enabled.

**Risks accepted.**
1. Hibernation on a Razer Blade chassis is known-fragile: spurious wake from XHC,
   an infinite suspend loop needing `button.lid_init_state=open`, `acpi_sleep=nonvs`, and Xid 79
   "GPU has fallen off the bus" under runtime PM.
2. NVIDIA writes ~16 GB of VRAM to `NVreg_TemporaryFilePath` on each hibernate. That path must be on
   the big volume, never tmpfs, and it is real write amplification.
3. Resume traverses four layers. **Must be proven in QEMU before touching hardware** (§10).

**Contingent on hardware capture:** swap size follows measured RAM; the whole striping design assumes
both drives are NVMe. See §11.

---

## 5. §2 — Session and display

Boot → autologin on tty1 → `cage` (single-client kiosk compositor, ~77 kB, no config file, cannot
display two windows) → one fullscreen **kitty**. **zellij** inside it for multiplexing. A rescue
getty on tty2, so a broken GPU driver never leaves the machine unreachable.

**This is not a desktop.** No window manager, no panel, no file manager, no mouse-driven
applications. Upstream cage states it "will not fit into a regular desktop-style workflow" — that is
precisely why it is used.

**Justification** is evidentiary rather than aesthetic: croft, a required component, states in its own
README that it needs "A Nerd Font as your terminal font — without one they render as `[?]` boxes" and
"A 256 color or truecolor terminal." The bare console satisfies neither. The distro's flagship editor
would be visibly broken on the purist option.

**Fonts.** `fonts-firacode` **unpatched** plus `fonts-nerd-symbols` as a fontconfig fallback — not a
Nerd-patched Fira Code. Patching frequently damages GSUB ligature tables; fallback preserves Fira
Code's ligatures *and* supplies the icon glyphs croft needs.

**Screen lock — required, not optional.** Autologin plus plaintext API keys means opening the lid
yields a shell with live credentials; FDE protects only a powered-off machine. Ship a locker
(`physlock` on the TTY, or `swaylock` under cage), engaged automatically on lid close and idle.

---

## 6. §3 — Keybindings

A single machine-readable Cmd table is the source of truth; every downstream config is generated from
it: `keyd`, kitty, `~/.inputrc`, zsh bindkeys, helix, neovim, zellij, yazi, and Emacs via the `kkp`
package.

**Rule written into the spec: the Cmd layer must never inherit Control.** The obvious implementation —
aliasing Cmd onto Ctrl — is destructive in a terminal: Cmd-S becomes XOFF (looks like a hang), Cmd-Z
becomes SIGTSTP, Cmd-C becomes SIGINT. On macOS these never collide because Cmd and Ctrl are separate
keys.

**zellij, not tmux.** tmux's manual contains zero occurrences of "super", and tmux strips the kitty
keyboard protocol, so Cmd bindings break in every application running inside it. zellij adopted that
protocol specifically for Super and passes it through. Cost: not in Ubuntu or Pacstall, so vendor a
pinned static musl binary.

Both keymap systems must be configured — the console uses `loadkeys`/PSF, cage/Wayland uses XKB — or
the rescue console behaves differently from the session.

---

## 7. §4 — LLM layer

**Engines.** `llama.cpp` (its `llama-server` uniquely serves OpenAI chat-completions, OpenAI Responses
*and* Anthropic Messages from one binary), Ollama via Pacstall, and `llama-swap` to hot-swap models
behind one port under limited VRAM.

**Flagship agent:** opencode (MIT). goose (Apache-2.0) also available. Claude Code and LM Studio via
fetch-on-demand helpers only (§3).

**Provider configuration.** `~/.config/cdl/providers.env`, mode `0600` — **not** `/etc`. Placing keys
in `/etc` would let the `ollama` system user and every service on the box read them. Ship both
spellings of the env vars that diverge across tools (`TOGETHER_API_KEY`/`TOGETHERAI_API_KEY`,
`FIREWORKS_API_KEY`/`FIREWORKS_AI_API_KEY`, `OPENROUTER_API_KEY`/`OR_API_KEY`).

`cdl doctor` probes each configured provider and reports which keys actually work.

**Model management.** A first-boot picker gated on measured Hugging Face blob sizes against detected
VRAM — the current headline "Flash" models are 111–150 GB MoEs and an ungated picker would offer
models that cannot load. Disk-quota and GC policy required: nothing may silently fill the volume.

---

## 8. §5 — Agent orchestration

**Worktree per agent, enforced.** A shared checkout is not merely untidy: measured, agents sharing one
checkout landed 24 of 100 commits with 75 `index.lock` failures, staging each other's half-finished
work. One worktree per agent landed 100/100. One branch cannot be checked out twice, so each agent
owns its own branch by construction.

**`cdl worktree new <branch>` — the seeding hook.** `git worktree add` carries no untracked or
gitignored files, so a fresh agent workspace has no venv, no `node_modules`, no `.env`. The hook:
1. creates the venv with `uv` so packages hardlink from one shared cache;
2. reflink-copies large gitignored directories (`cp --reflink=auto`, free on btrfs);
3. assigns a deterministic, non-colliding port block derived from the branch name.

No existing tool in this category allocates ports. **This hook is the highest-value component in the
project** and it is dozens of lines, not a product.

**`cdl-agent@.service`** — one templated unit per agent, in its own slice: journald capture with
cross-reboot history, `MemoryHigh` to throttle rather than kill, `MemoryMax` as a backstop,
`OnFailure=` notification, and **`Restart=no`** (restarting an LLM agent replays its opening prompt
against a repo it already half-modified). `loginctl enable-linger` so agents run with nobody logged
in. Interactive panes start under `systemd-run --scope --user` so they outlive the login session.

**Ubuntu's `systemd-oomd` default must be overridden.** Ubuntu ships
`ManagedOOMMemoryPressure=kill` at a 50 % limit with a 20 s pressure duration, so an arbitrary
descendant cgroup is killed under pressure and the victim is not chosen — potentially the multiplexer,
taking every agent with it. Ship per-agent slices plus `ManagedOOMPreference=avoid` on the supervisor
and notifier. *(Verify these values on the target before relying on them — §12.)*

**GPU arbitration.** One inference server as a system service behind a `flock` semaphore. MIG does not
exist on laptop GPUs, and MPS attributes all activity to the MPS server in `nvidia-smi`, destroying
per-agent attribution exactly when supervising several agents. Admission control, not isolation.

**`cdl status`** is the single supervisory surface — the concrete expression of principle 1.

---

## 9. §6 — Remote compute

**Interface:** two functions — `submit → job id`, `poll → status` — over a **durable on-disk job
registry**, so a job survives the process that launched it and can be re-attached from any later
session. That registry is the piece no existing tool provides and is the reason this is a thin adapter
rather than a dependency.

**Backends (v1):** `ssh + nohup` (the bare GPU host, no scheduler) and `ssh + sbatch` (the Slurm
cluster). Additional targets available: cloud GPUs and Hugging Face Jobs (verified: the user's org
holds an `academia` plan and the token carries the `jobs` scope).

**Every job ships its own environment** via `uv` or a container. The remote GPU host runs
RHEL 8.10 with python 3.6.8 and no `nvcc`; nothing there is usable as a base.

**Enrollment is a first-boot step.** After the wipe the machine has no SSH keys on any remote host.
Setup must generate a key and run `ssh-copy-id` against each target, each requiring an interactive
password. This joins the irreducibly-interactive list in §3.

**clustrix** (`ContextLab/clustrix`) is a **later optional backend, never a dependency**. Verified:
only `v0.1.1` is tagged, with **596 commits** on master above it — the library is unreleased rather
than broken. It nonetheless blocks the calling process for a whole job, persists no job IDs, and has
no TUI, all disqualifying for unattended use. Publishing v0.2.0 is a worthwhile parallel task on its
own merits and must not gate this project.

---

## 10. §7 — Backup and recovery

**Backup is load-bearing, not a convenience.** D15 accepted total loss on single-drive failure, and
snapshots live on the same volume they protect. An off-machine backup is the only thing between one
NVMe failure and losing the work.

`restic` over SFTP. `--exclude-caches` drops the entire Hugging Face cache for free, because
`huggingface_hub` writes `CACHEDIR.TAG`. **Keep a plain-text manifest of the excluded weights inside
the backup** so restore is a scripted re-download rather than a loss.

**Recovery.** `GRUB_TIMEOUT_STYLE=menu` with a non-zero timeout — Ubuntu hides the menu by default on
single-OS installs, and a menu you cannot see is a recovery path you do not have. Two kernels always
retained, `grub-btrfs` snapshot entries, and a `nvidia-drm.modeset=0 nomodeset` recovery entry.
A known-good Ubuntu live USB is retained permanently.

---

## 11. §8 — Documentation

MkDocs, themed from the tokens in §9 for continuity with the lab's existing sites.

**Screenshots are regression tests.** `vhs` tapes rendered to **PNG** and diffed in CI: PNG output is
byte-identical across runs, GIF output is not. The CI runner must have `fonts-firacode` installed or
every image silently renders in a different typeface, and VHS must be configured with the shipped
theme or published screenshots depict a system that does not exist.

**VHS cannot capture everything.** It renders inside its own pty and physically cannot photograph
GRUB, the installer, the bare VT, or the boot sequence. Those need QEMU framebuffer capture — a
different tool, and a documented gap rather than an oversight.

**Docs ship on-disk.** A documentation site is useless exactly when it is most needed: no wifi, no
boot.

---

## 12. §9 — Branding and theme

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
| 0 black | `#022919` | 1.24 | `#227754` | 3.58 | green tint |
| 1 red | `#E7556F` | 5.53 | `#EF90A1` | 8.56 | bonfire-red · rare accent |
| 2 green | `#00A863` | 6.32 | `#29E095` | 11.37 | Dartmouth tint · **workhorse** |
| 3 yellow | `#A5D75F` | 11.64 | `#F5DC69` | 14.29 | rich-spring / summer-yellow |
| 4 blue | `#308ED5` | 5.55 | `#72B2E2` | 8.56 | river-blue · rare accent |
| 5 magenta | `#9A7EA5` | 5.50 | `#B8A5C0` | 8.56 | violet · rare accent |
| 6 cyan | `#12A08C` | 6.00 | `#37C7B0` | 9.29 | green-adjacent teal |
| 7 white | `#BBD3C9` | 12.38 | `#E8EEEB` | 16.66 | green-tinted neutral |

Every normal colour clears 4.5:1 and every bright is lighter than its normal. Five of eight hues sit
in or beside the green family, so ordinary output reads as monochrome Dartmouth green; red, blue and
violet appear only where a terminal must genuinely distinguish something, which is what makes them
read as highlights.

**Structural, never text:** `#00693E` Dartmouth green (2.88:1) and `#003C73` river navy (1.77:1) —
splash, borders, inactive chrome. Their darkness is the point.

---

## 13. §10 — Validation ladder

| Stage | Validates | Needs target hardware |
|-|-|-|
| **1 · Docker** | Package availability and versions, LLM tooling, python/uv/torch paths, provider config, `cdl doctor`, docs build | No |
| **2 · QEMU + OVMF, two emulated NVMe controllers** | **Storage layout, boot, installer, LUKS+RAID0+LVM+btrfs, hibernation resume, systemd units, cage+kitty session** | No |
| **3 · Tensorbook** | CUDA on real silicon, display on the real panel, wifi, suspend, thermals | Yes |

Docker validates the *least* risky part of the system: it cannot test a kernel, GPU, console,
bootloader or disk layout, and systemd-in-a-container cannot properly exercise the orchestration
layer. The two highest-risk components — the four-layer storage stack and the installer — are
precisely what stage 2 covers without hardware. Nested virtualisation is confirmed working on GitHub
Linux x86 runners; GPU testing is not possible in hosted CI and requires the Tensorbook enrolled as a
self-hosted runner.

---

## 14. §11 — Pre-wipe hardware capture

One-way. Every fact becomes unobtainable after installation, and at least six decisions currently rest
on assumptions. Required **before stage 3**, not before stage 1.

```bash
sudo dmidecode -s system-product-name; sudo dmidecode -s system-version
sudo nvme list; lsblk -d -o NAME,MODEL,TRAN,ROTA,PHY-SEC,LOG-SEC,SIZE
lspci -nn | grep -Ei 'vga|3d|network|audio'
lsusb | grep -i 1532; free -g
```

Plus, from firmware: whether storage is in **Intel VMD/RST mode** (if so and it cannot be disabled, a
stock installer sees no disks at all and the project stops), and the Chipset setting (Dedicated GPU
Only vs Dynamic Display Switch, which decides whether the console comes from `i915`/`simpledrm` or
from `nvidia-drm`).

**Decisions blocked on this:** swap size (assumes 64 GB RAM, from a vendor launch post rather than
measurement); the entire striping design (**at least one documented Tensorbook shipped 1 TB NVMe +
1 TB M.2 SATA**, which would make striping actively harmful); the console/display path; the wifi
firmware package.

---

## 15. Open items

1. **Backup target.** Make, model, and whether it offers SSH/SFTP, can run a container, or is
   SMB-only. `restic` has no native SMB or NFS backend and the design differs completely by answer.
2. **Slurm host key enrollment.** Public-key auth is advertised by the server and the key is offered
   and rejected; cause not yet determined (candidates: `StrictModes` with a group-writable home,
   a failed `ssh-copy-id`, or site policy requiring portal registration).
3. **Linux Foundation sublicense.** The name `cdl-linux` contains the adjacent letters "Linux", which
   requires a free, perpetual sublicense for a software mark. Trivially satisfiable; must be filed
   before public release.
4. **Reproducible builds.** Not yet designed. Requires `snapshot.ubuntu.com` pinning, a per-ISO
   package manifest, and `SOURCE_DATE_EPOCH`.
5. **Spend controls.** An LLM-first distro that collects API keys and ships no budget or usage
   visibility is a genuine product gap.

---

## 16. Evidence standards

This spec distinguishes **measured** from **reported** claims, and implementation must preserve that
distinction. Figures verified by direct command execution during design include the clustrix tag and
commit counts, the remote host specifications, the Ubuntu package and archive queries, the name
collision checks, and every contrast ratio in §12.

Figures **reported by research subagents but not independently reproduced** include the
worktree commit experiment, the dm-crypt throughput numbers, the drive-failure probability math, and
the `systemd-oomd` default values. These are plausible and well-sourced but must be confirmed on the
target before anything depends on them. `notes/` carries the full ledger.
