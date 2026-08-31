# cdl-linux research round 1 — digest (2026-08-31)

Run `wf_bcfba9cd-5cb`. 14 agents, 0 errors, 2423246 subagent tokens, 1100 tool calls.
530 verified facts, 75 conflicts. Raw: round1-raw.json


## HARD BLOCKERS (14) — requirements that CANNOT be met as written

### "Creating installable USB images from an ISO ... via web"
**Why:** Impossible in every shipping browser, for two independent reasons. The WebUSB spec classes Mass Storage (0x08) as a protected interface class and specifies claimInterface() to reject it with a SecurityError; the only bypass is the 'usb-unrestricted' permissions-policy token, which 'MUST only be enabled for Isolated Web Apps', and Isolated Web Apps install only on enterprise-managed ChromeOS via an admin panel. Even if that filter vanished, the OS kernel driver (usb-storage/UAS, USBSTOR, IOUSBMassStorageDriver) already claims the interface and WebUSB has no way to detach it. The File System Access API is not a side door either: Chromium explicitly blocks /dev with kBlockAllChildren on Linux, and on macOS Chrome runs unprivileged and writes via temp-file-then-rename, which cannot target a device node. Both APIs are Chromium-only. No product on the market does this.

**Nearest achievable:** A web page CAN copy an ISO onto an already-Ventoy-prepared stick's data partition via showSaveFilePicker() — ordinary file I/O on a mounted filesystem, fully permitted in Chrome/Edge/Opera 86+. So: user prepares a Ventoy stick once with a native tool, and thereafter every new release is a browser drag-and-drop. Otherwise the web page serves the ISO, displays the verified checksum, and hands over the exact per-OS command.

### Programming ligatures (Fira Code) on the bare Linux virtual console
**Why:** The kernel console has no TrueType rasterizer at all — setfont(8): 'The standard Linux font format is the PSF font', 1-bit bitmaps. It has no text-shaping engine, no GSUB table parser, a 512-glyph ceiling (with color dropping from 16 to 8 above 256), no way to represent a glyph spanning multiple cells, and no subpixel or negative bearings. A programming ligature is a HarfBuzz GSUB substitution over a run of characters producing overlapping glyphs with negative offsets — foot's maintainer names Fira Code specifically on this point when closing the request WONTFIX. This is not a missing feature; it is a different rendering model.

**Nearest achievable:** Run one fullscreen kitty (HarfBuzz shaping, no GTK/Qt dependency, 32 MB installed) under cage, a 77 kB single-client kiosk compositor with no config file that physically cannot show two windows. If that is unacceptable, kmscon gives real antialiased Fira Code and 24-bit color with no compositor — but its render API is single-codepoint, so no ligatures, ever. Third option: a PSF bitmap font converted from Fira Code (letterforms only, no ligatures).

### Cmd (Super) keybindings and a system clipboard on the bare Linux virtual console
**Why:** keymaps(5) documents exactly nine console modifiers — Shift, AltGr, Control, Alt, ShiftL, ShiftR, CtrlL, CtrlR, CapsShift — and none is Super/Meta/Command. Separately, console_codes(4) lists exactly two supported OSC sequences for the Linux console (ESC ] R and ESC ] P), so OSC 52 clipboard does nothing. The kitty keyboard protocol, which is the only mechanism that transmits super (bit 8) to an application, is implemented by terminal emulators, all of which need X11 or Wayland. Ctrl+Shift+C is also byte-identical to Ctrl+C in legacy encoding — the distinction exists only inside a terminal emulator that consumes it before the pty.

**Nearest achievable:** At most ~8 Cmd chords translated by keyd into the kernel's unused F13-F20 function-key strings (\E[25~ through \E[34~, verified in defkeymap.c and in `infocmp -1 linux`), bindable in readline/zle/Emacs. Up to 256 arbitrary escape strings are definable via loadkeys if needed. No clipboard beyond gpm's console selection (left-drag select, middle-click paste), which is not scriptable. Full Cmd and a real clipboard require a terminal emulator.

### Lambda Stack on a Rhino Linux / Ubuntu-devel base
**Why:** Three independent hard gates, each read from the artifacts themselves. (1) install-lambda-stack.sh contains `case "$DISTRIB_RELEASE" in 20.04|22.04|24.04)` and otherwise calls `fatal "Lambda Stack only supports Ubuntu 20.04, 22.04, and 24.04 LTS"`. (2) It aborts unless $DISTRIB_ID is exactly 'Ubuntu'. (3) lambda-stack-repo.deb's postinst builds its apt line from `lsb_release -cs`, and Lambda's archive has no suite past noble — I probed focal/jammy/noble as 200 and oracular/plucky/questing/resolute as 404. Rhino's ISO builder sets CODENAME="devel" and VERSION=$(date +%Y).$RELEASE, so no value it can produce satisfies any gate. Lambda has also exited its on-premise hardware business as of 2025-08-29.

**Nearest achievable:** Reproduce what Lambda Stack provides from first-party sources: nvidia-driver-580-open (or -595/-610) from Ubuntu restricted, NVIDIA's own CUDA apt repo at developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/x86_64/ (verified live), and uv/pip for PyTorch. Alternatively run a jammy/noble Lambda Stack container under Podman with nvidia-container-toolkit, with the host supplying only the driver.

### Shipping Claude Code or LM Studio preinstalled on a distributable ISO
**Why:** Claude Code's LICENSE.md reads in full: '© Anthropic PBC. All rights reserved. Use is subject to Anthropic's Commercial Terms of Service.' Those terms grant no sublicense and forbid using the Services to 'resell the Services except as expressly approved by Anthropic'. LM Studio's terms are equally explicit: 'You will not...sublicense, distribute, sell, use for service bureau use, as an application service provider, or a software-as-a-service, lease, rent, loan, or otherwise transfer the Software', and separately forbid combining it with open source 'in a manner that imposes...a requirement or condition that the Software or any part thereof...be redistributable at no charge' — which is what a free ISO is. The headless llmster daemon is covered by the same terms; MIT on the `lms` CLI does not help, because lms is only a client for the proprietary engine.

**Nearest achievable:** Post-install fetch helpers that run each vendor's own installer at the user's request (`curl -fsSL https://claude.ai/install.sh | bash`, `curl -fsSL https://lmstudio.ai/install.sh | bash`), so the end user accepts the license directly and you redistribute nothing. Make a redistributable agent the preinstalled flagship: opencode (MIT), goose (Apache-2.0), or Codex CLI (Apache-2.0, static musl binary). llama-server covers every protocol LM Studio serves, plus Anthropic Messages.

### Baking the CUDA Toolkit into the ISO
**Why:** The CUDA EULA (v13.3, updated 2026-01-26) permits redistribution only of the Attachment A libraries, and only under conditions written for applications: 'Your application must have material additional functionality, beyond the included portions of the SDK' and 'The distributable portions of the SDK shall only be accessed by your application.' An operating system satisfies neither. Canonical's own placement agrees — cuda-toolkit, cuda-toolkit-13-1 and nvidia-cuda-toolkit are all in multiverse, which Ubuntu defines as 'Software restricted by copyright or legal issues'.

**Nearest achievable:** Ship the NVIDIA *driver*, which IS redistributable — its license §1.1(d) explicitly permits distribution 'for use with operating system kernels distributed under the terms of an OSI-approved open source license', unmodified, with the Agreement included. Pull CUDA at first boot from NVIDIA's live ubuntu2604 repo, or from Ubuntu multiverse, so the end user accepts the terms. For most workloads you can skip the system toolkit entirely: PyPI torch wheels bundle their own CUDA runtime and only need driver >= 580.

### Redistributing Rhino Linux branding, wallpapers, Plymouth or LightDM themes
**Why:** rhino-linux/branding has no LICENSE file and its GitHub license field is null; it contains only bashrc, logo.png and logo.svg. The same is true of rhino-linux/wallpapers, /plymouth, /lightdm, /dotfiles, /calamares-settings and /AdwRhino. With no license grant, default copyright applies — these assets are not redistributable. Rhino also publishes no trademark or brand-usage policy: their linked 'branding guidelines' page shows palettes and logos but states no usage terms, and their homepage carries no copyright or trademark notice.

**Nearest achievable:** Commission original logo, wallpaper, Plymouth and GRUB assets; rename via etc/terraform.conf (DISTRO_NAME, NAME, FNAME); describe the lineage only in prose, which is nominative use and not trademark use. Or ask on their Discord / open an issue on rhino-linux/tracker for an explicit license on the branding repo — that would benefit every downstream, not just you.

### A fully unattended install that also enables Secure Boot AND loads an NVIDIA DKMS driver on first boot
**Why:** MOK enrollment is interactive by design — that interactivity is the security property. dkms 3.2.2's prepare_mok() runs `update-secureboot-policy --enroll-key`, which sets a one-time password; the actual enrollment happens in shim's MokManager on the next boot, a firmware-level screen requiring a physical keypress and the password. No installer can automate that away. Compounding it, ArchWiki reports that Razer's BIOS does not allow changing signing keys, so you cannot enroll your own key in firmware db on this chassis: 'We tested appending or changing keys using efitools KeyTool.efi or the efi-updatevars tool; neither work.'

**Nearest achievable:** Use Ubuntu's signed kernel plus the precompiled, Canonical-signed linux-modules-nvidia-*-generic packages — Ubuntu Server docs recommend `ubuntu-drivers` for exactly this reason, since it 'will, by default, only install the pre-built, signed drivers' and needs no enrollment at all. This requires giving up Rhino's unsigned mainline kernel. Otherwise: accept one interactive MOK reboot as the single human touchpoint, or document 'disable Secure Boot in the BIOS' as an install prerequisite and have the installer detect and refuse if it is on.

### ~2TB of usable capacity from two 1TB drives with any redundancy
**Why:** Arithmetic. Two 1TB drives give 2TB with zero redundancy or ~1TB mirrored. Any scheme presenting ~2TB as one volume roughly doubles the probability of total loss (computed: at 1% per-drive AFR, 7.73% over four years vs 3.94% for a single drive; at 2%, 14.92% vs 7.76%). Separately, no arrangement of two internal NVMe drives is a backup — theft, liquid, board failure, an errant wipefs, and a bad rolling kernel update are 100% correlated across both.

**Nearest achievable:** Pick per-dataset rather than for the whole volume. LVM with root and /home pinned to PV1 and a striped LV only for re-downloadable model weights gives you throughput where it helps and keeps a single-drive death from costing both a bootable system and your data. Or do not combine at all: / on nvme0, models on nvme1. Or 1TB btrfs/ZFS mirror plus an external 2TB NVMe in a Thunderbolt 4 enclosure. In every case an external backup is mandatory, not optional.

### Installing cdl-linux from a TUI-only ISO using Rhino's own installer
**Why:** Rhino's only installer is Calamares, which is a Qt/QML GUI framework with no text-mode frontend — its src/ tree has calamares, libcalamares, libcalamaresui, modules, qml and branding, a GitHub code search for 'ncurses' in the repo returns 0 results, and its entire CLI option set is -d/-D/-c/-X/-T. Rhino launches it from a desktop icon with `Exec=sudo -E calamares -D6` and `Terminal=false`, and the live package list pulls calamares plus qml6 modules. There is no ubiquity and no subiquity anywhere in Rhino's tree. Additionally its partition.conf offers only single-disk ext4/btrfs/xfs with optional LUKS — no LVM, no RAID — so it could not create the 2TB volume even if it were a TUI.

**Nearest achievable:** Adopt subiquity (already a curses TUI, autoinstall supports multi-disk via a raw curtin `storage: config:` passthrough, multiple ESPs supported), or write a scripted installer, or skip the ISO for now: install Ubuntu Server 26.04 with its stock TUI installer and convert with Rhino's own `ub2r.sh`, which offers 'rhino-server-core: TUI tool suite w/ basic development tools' as an explicit, officially supported option.

### tmux plus Cmd/Super bindings anywhere in the stack
**Why:** tmux.1 states 'Ctrl keys may be prefixed with `C-` or `^`, Shift keys with `S-` and Alt (meta) with `M-`', and a case-insensitive grep for 'super' across the entire 226 KB manual returns zero matches. Worse, tmux is a terminal to its panes and does not implement the kitty keyboard protocol (its CHANGES mentions only extended-keys, modifyOtherKeys and the libtickit CSI u sequence), so it strips KKP — helix's `Cmd-`, neovim's `<D-`, yazi's `<D-`, fish's `super-` and Emacs kkp all stop working the moment they run inside tmux. Three open issues (#3335, #4158, #4196) and no maintainer commitment.

**Nearest achievable:** Use zellij, which adopted the kitty keyboard protocol in 0.41.0 specifically for 'special previously unavailable modifiers (eg. Super a)', supports `bind "Super c"`, and passes KKP through to panes. Cost: not in Ubuntu or Pacstall, so vendor a pinned static musl binary. Or keep tmux and have the terminal emulator translate every Cmd chord into a legacy chord before tmux sees it. Or skip the multiplexer and use kitty's native tabs/splits bound to cmd+t/cmd+d/cmd+w, which is closer to macOS anyway.

### Testing the CUDA / GPU stack in GitHub-hosted CI
**Why:** GitHub-hosted runners expose no NVIDIA GPU. Nested virtualization is confirmed working on Linux x86 runners (GitHub staff, 2024-04-05: 'All Linux runners are now on a SKU that supports nested virtualization'), but that gives a CPU-only VM. GPU passthrough via VFIO requires bare-metal control over IOMMU groups, which hosted runners do not provide. I found no documented GitHub-hosted GPU runner SKU. KVM is also unavailable on hosted ARM64 runners (actions/runner-images #14062, closed).

**Nearest achievable:** Split the test matrix honestly. In hosted CI, prove the ISO boots UEFI, partitions two NVMe controllers into the target layout, and installs unattended — QEMU with two `-device nvme,serial=...` controllers plus OVMF does this well, and disk serials make autoinstall `match:` rules deterministic. Test CUDA *packaging* rather than function: apt policy/pin correctness, --dry-run resolution, DKMS source build against shipped headers, initramfs module inclusion. For real GPU validation, bring up the Tensorbook manually once and enroll it as a self-hosted runner with a `gpu` label.

### Installing aider on the system Python
**Why:** aider-chat declares requires_python '<3.13,>=3.10'. Ubuntu 26.04 and 26.10 both ship Python 3.14 as the default python3 (python3-defaults 3.14.3-0ubuntu2), and python3.15.0~rc1 is already staged in the same archive. Resolution simply fails. Independently, aider's last GitHub release is v0.86.0 from 2025-08-09 and its last commit is 2026-05-22 — over three months stale.

**Nearest achievable:** Drop aider in favour of gptme (MIT, requires_python <3.15, last push 2026-08-31), opencode, or goose. If aider is genuinely required, provision it on demand into its own pinned Python 3.12 venv via `uv tool install --python 3.12 aider-chat`, and accept maintaining a second interpreter for one stale tool.

### Completing a 2026 OAuth / SAML login (Tailscale, Anthropic console, GlobalProtect, a JS captive portal) from a terminal-only machine
**Why:** Links' own feature page states 'HTML 4.0 support (without CSS)' with no JavaScript; w3m's MANUAL and lynx's help never mention JavaScript at all. A modern identity-provider consent screen is a JavaScript SPA. The two terminal browsers with real engines are both stale and unpackaged: browsh's last release is 2024-01-29 (and it drags in a full Firefox, i.e. the GUI stack the distro exists to avoid), and carbonyl's last release is 2023-02-18 with last push 2024-07-01.

**Nearest achievable:** Never do OAuth on the machine. Pre-generate a Tailscale auth key before the wipe and enroll with `tailscale up --auth-key=...`; the login URL `tailscale up` prints is device-agnostic, so open it on a phone, or use `--qr`. Create API keys on another device and deliver them via /etc/environment or a systemd credential. Ship chawan (already packaged in the stonking suite, opt-in QuickJS) as best-effort for simple portals. As a last resort, a scripted headless-Firefox+Playwright OAuth helper invoked on demand — never an interactive browser.


## PHILOSOPHY TENSIONS (9)

### What "TUI-only, no GUI" actually forbids: no desktop environment, or no graphics stack at all?
**Why it matters:** This single answer determines roughly half the project. On the bare kernel VT there is no TrueType rasterizer (PSF bitmaps only), no text-shaping engine, a 512-glyph ceiling (and 8 colors if you exceed 256), truecolor is downgraded to 16fg/8bg, there is no OSC 52 so no system clipboard, and keymaps(5) has nine modifiers of which none is Super. That means: no Fira Code ligatures (architecturally, not as a missing feature), no Nerd Font icons, no Cmd key, no clipboard, no inline images, and croft — which you asked for by name — runs in a broken state because its own README requires a Nerd Font, 256/truecolor, and a kitty-graphics-or-sixel terminal. Every other requirement you stated collides here.

- **A:** Redefine "no GUI" as "no desktop environment": boot to TTY, systemd launches `cage` (77 kB, four deps, six flags, no config file, physically cannot show two windows) running one fullscreen kitty. tmux/zellij provides multiplexing. You get ligatures, truecolor, clipboard, real Cmd via the kitty keyboard protocol, and kitty graphics. Total cost ~33 MB installed. Upstream cage itself says it "will not fit into a regular desktop-style workflow" — the spirit of your constraint survives intact.
- **B:** kmscon (1.8 MB, in the Ubuntu archive, revived 2025, about to become Fedora 45's default console): real antialiased TrueType Fira Code and 24-bit color on bare KMS with no compositor. But its render API is single-codepoint (`render(font, uint32_t ch)`), so ligatures are impossible by construction, and there is no image protocol (issue #138 open since 2020). You drop ligatures and images; you keep purity.
- **C:** Bare VT with a PSF font converted from Fira Code. You get Fira Code's letterforms as bitmaps and nothing else — no ligatures, no icons, no clipboard, no Cmd, no images, and croft degrades badly. Maximum purity, minimum function.

**Recommendation:** Option A. You have already asked for ligatures, Fira Code, croft, and macOS keybindings — that is a request for a real terminal emulator, whether or not it was phrased that way. Take cage+kitty and additionally enable kmscon or a plain getty on tty2 as a rescue console so a broken GPU driver never bricks a machine with no graphical fallback. If you genuinely mean Option C, say so now and I will delete the ligature, croft, clipboard, and Cmd requirements from the spec rather than pretending they can be partially met.

### Is cdl-linux one machine that works, or a distro other people install?
**Why it matters:** Almost every expensive constraint in this project exists only because of redistribution. Trademark debranding, the Canonical "recompile the source code" clause, NVIDIA CUDA EULA conditions that no OS can satisfy, LM Studio's and Claude Code's redistribution bans, ISO hosting above GitHub's 2 GiB asset cap, signed installers, checksum signing, USB-writer tooling for three operating systems — all of it evaporates if the audience is you and a handful of colleagues. Conversely, if it is public, none of it is optional and the project is perhaps 5x larger.

- **A:** Personal build. Skip the ISO entirely at first: install Ubuntu Server 26.04 (TUI installer, handles multi-disk LVM natively), run Rhino's own `ub2r.sh` and pick `rhino-server-core`, then layer your tooling with a config-management repo. You have a working Tensorbook in an afternoon. Produce an ISO later, from a known-good system, if you still want one.
- **B:** Public flavor. Fork rhino-linux/os (GPL-3.0), build a TUI environment overlay, debrand fully, replace all unlicensed Rhino art, add an installer, set up CI + ISO hosting + signing, and accept ongoing maintenance against a moving Ubuntu devel archive.
- **C:** Personal build first, with the provisioning expressed as an idempotent, re-runnable repo, so that turning it into a public ISO later is a packaging exercise rather than an archaeology exercise.

**Recommendation:** Option C. Build the machine you actually want, but express every configuration decision as a scripted, versioned artifact from day one. This defers the entire legal/branding/distribution workstream without paying for it twice. Note that Rhino already ships a headless Docker image (`ghcr.io/rhino-linux/docker`) whose whole userland is one `pacstall -PI nala-deb rhino-server-core` line — use it as the prototyping loop before touching the laptop.

### Rolling and current vs. boots reliably every morning
**Why it matters:** Rhino tracks Ubuntu's `devel` archive, whose Release file today has a 14-day Valid-Until — it is a live pre-release, and it rolls over to 27.04 development weeks after 26.10 ships on 2026-10-15. Rhino's own converter documentation says the state "is unstable" and is "strongly advised against using this in a production setting." This is not theoretical: on 2026-02-14 an upstream uutils coreutils change left Pacstall unable to run any command, and `rpk update` could leave it unable to repair itself. Layer on top that Rhino replaces Ubuntu's signed kernel with an unsigned mainline build, which forces NVIDIA onto DKMS, which has a confirmed 610.57.04 build failure on kernel 7.1.8 while Pacstall's `linux-kernel` already tracks 7.2. A machine with no GUI and a broken NVIDIA module after an update is a machine you recover from a USB stick.

- **A:** Full rolling. Track devel, take mainline kernels, accept periodic breakage. Mitigate with btrfs/Timeshift snapshots, two kernels always installed, /etc/dkms/no-autoinstall-errors so a DKMS failure does not abort the kernel install, and a boot-time `nvidia-smi -L` health check.
- **B:** Pin to Ubuntu 26.04 LTS ('resolute'), keep Canonical's signed `linux-image-generic`, use the precompiled signed `linux-modules-nvidia-*` packages (which never compile and work under Secure Boot), and adopt only the Rhino parts you actually want — Pacstall, rhino-pkg/rpk, rhino-server-core. You lose "rolling" and gain a base that Tailscale, NVIDIA's CUDA repo, and every third-party apt source actually publish for.
- **C:** Snapshot-rolling: mirror the devel archive at a chosen date, build against the frozen snapshot, and advance the snapshot deliberately after testing. Rolling for users, pinned for you.

**Recommendation:** Option B for the machine, and be honest that this makes cdl-linux "Rhino-flavored" rather than literally Rhino. The rolling model is the single largest source of avoidable risk here, and its concrete benefits on this hardware (an Ampere laptop GPU from 2022) are close to zero. If "rolling" is itself a core value rather than a means, take Option C, not Option A.

### ~2TB of capacity vs. surviving a drive failure on a laptop with no redundancy
**Why it matters:** Two 1TB drives give you 2TB with no redundancy or 1TB with mirroring; there is no third answer. Striping roughly doubles the probability of total volume loss (at 1% AFR: 7.73% over four years vs 3.94%; at 2%: 14.92% vs 7.76%), and it does so across the whole 2TB rather than half of it. Meanwhile, if you also want full-disk encryption, striping buys you almost nothing: measured dm-crypt on NVMe caps at ~1130 MB/s with the default 512-byte LUKS sector and ~1994 MB/s at 4096, and an independent 2x-NVMe test found LUKS-on-RAID0 "hardly any better than a single LUKS-encrypted NVMe." And with 64 GB RAM, a model that fits in page cache is re-read at RAM speed after its first load, so striping mostly accelerates the first read of each model. Separately: theft, spill, board failure, an errant `wipefs`, and a bad rolling kernel update are 100% correlated across both internal drives regardless of layout — no arrangement of two internal NVMe drives is a backup.

- **A:** LVM VG spanning both PVs, linear allocation, with `/` and `/home` pinned to PV1 and a striped LV only for `/var/lib/models`. Declarative in curtin except the striped LV, which needs an `lvcreate -i 2` late-command. Best repair story of any option (`pvmove` is online and restartable).
- **B:** Do not combine them at all. `/` on nvme0, models and datasets on nvme1 at a fixed mount point. Zero exotic failure modes, trivially installable by any installer, and a dead drive costs you either a re-downloadable model cache or a reinstallable system, never both.
- **C:** mdadm RAID0 or btrfs multi-device for one flat ~2TB namespace and peak sequential throughput, accepting doubled total-loss probability. Note btrfs multi-device root has an open initramfs assembly race (Debian #964906) that md and LVM do not.

**Recommendation:** Option B unless you can name a single file or working set that exceeds ~900 GB. "Combine into one 2TB volume" is a shape, not a requirement; the underlying need is usually "enough room for model weights," which a second mount point satisfies with none of the risk. If you do combine, take Option A over Option C. And whichever you pick, an external backup is not optional — that decision is upstream of all of this.

### Batteries-included ISO vs. an ISO anyone will actually download
**Why it matters:** I measured this: GGUF weights are effectively incompressible. A 125 MB slice of Qwen3-8B Q4_K_M compressed to 96.28% with xz -6, 96.00% with zstd -19, 96.39% with gzip -9. So squashfs saves ~4% and every gigabyte of model is a gigabyte of ISO. Rhino's baseline generic ISO is already 2.70 GiB. The torch+CUDA wheel stack is 2.82 GiB compressed (~6-8 GB unpacked). texlive-full is 4.88 GiB of debs / 8.71 GiB installed. Preloading all three yields an 8-12 GB image, which also blows past GitHub Releases' 2 GiB per-asset cap and makes FAT32 USB instructions silently fail. Meanwhile a first-boot download of a 12 GB model measured ~4.1 min from Ollama's registry and ~7.7 min from Hugging Face on a fast line — but ~32 min on a 50 Mbit/s home connection.

- **A:** Lean ISO (~3.5 GB): NVIDIA driver + curated TeX subset (0.33 GiB download / 0.89 GiB installed) + the ~330 MiB TUI toolset + static binaries (uv 18.5 MB, tectonic 9.7 MB, zellij 14.3 MB). A first-boot systemd unit fetches torch/CUDA/models when the network appears.
- **B:** One small model baked in as an offline floor (gemma-4-E4B-it Q4_K_M at 4.98 GB or Qwen3-8B Q4_K_M at 5.03 GB, ~+4.8 GB), everything larger downloaded. The machine has a working local assistant with no network, and the ISO stays under ~10 GB.
- **C:** Two published images: a lean netinstall and a fat "offline" edition that preloads the wheel cache under /var/cache and installs from it locally.

**Recommendation:** Option B if the ISO must be self-sufficient, Option A if not. Whichever you choose, do not offer a model *picker* at install time — that would mean shipping every candidate. Move selection to first boot, and gate the picker on measured file size from the Hugging Face blob API against detected VRAM. That guard is not optional: the 2026 headline "Flash" models are giant MoEs (Qwen3.8-Flash-Next UD-Q4_K_XL is ~111 GB across 4 shards; GLM-5.3-Flash ~150 GB across 6), so a picker built from a trending list will offer users models that cannot load.

### How opinionated should cdl-linux be — a configured environment, or a stocked toolbox?
**Why it matters:** You have asked for macOS keybindings, a default font, a default editor stack, preinstalled models, and "CUDA out of the box." Each of those is a decision made on the user's behalf. But every opinion is a maintenance surface and a surprise: a canonical Cmd table has to be regenerated into eight config dialects (keyd, ghostty/foot, ~/.inputrc, zsh bindkeys, helix TOML, nvim Lua, zellij KDL, Emacs); a globally-set ANTHROPIC_BASE_URL silently disables Claude Code's Remote Control and voice dictation; a blessed shared venv means users step on each other's dependency changes; installing TLP without masking power-profiles-daemon leaves two daemons fighting over the same kernel tunables with a warning nobody will ever see on a headless box.

- **A:** Heavily opinionated: one canonical config generated from a single machine-readable table, a blessed /opt venv, a chosen agent, a chosen multiplexer, a chosen editor. Everything works together on day one; deviating means fighting the distro.
- **B:** Lightly opinionated: ship the tools and a documented, opt-in `cdl-linux-config apply` that installs the opinions. Stock underneath, curated on top.
- **C:** Opinionated defaults, but every opinion is a separate, individually-removable package (cdl-linux-keybindings, cdl-linux-fonts, cdl-linux-llm-defaults) rather than a monolith.

**Recommendation:** Option C. It gets you the day-one experience of A with the escape hatches of B, and it forces you to write down each opinion as a discrete artifact rather than as accumulated dotfile sediment. Two opinions I would make non-negotiable regardless: never alias Cmd onto Ctrl (that turns Cmd-S into XOFF, Cmd-Z into SIGTSTP, Cmd-D into logout), and never set gateway env vars globally when a per-invocation wrapper will do.

### A redistributable free-software ISO vs. the proprietary AI tools that are the point of the distro
**Why it matters:** The two flagship tools you would most want preinstalled cannot be shipped. LM Studio's terms forbid distributing the Software and forbid combining it with open source "in a manner that imposes... a requirement or condition that the Software... be redistributable at no charge" — which is exactly what a free ISO is; this covers the headless `llmster` daemon too. Claude Code's entire LICENSE.md is "© Anthropic PBC. All rights reserved. Use is subject to Anthropic's Commercial Terms of Service," which grant no sublicense. The CUDA Toolkit EULA's redistribution conditions ("Your application must have material additional functionality... The distributable portions of the SDK shall only be accessed by your application") are written for applications and cannot be satisfied by an OS — Canonical's own signal agrees, placing cuda-toolkit in multiverse. Separately, KoboldCpp and TabbyAPI are AGPL-3.0 and Crush is FSL-1.1-MIT (source-available, not OSI-approved).

- **A:** Free-software ISO with clean components only (llama.cpp MIT, Ollama MIT, opencode MIT, goose Apache-2.0, Codex CLI Apache-2.0, gptme MIT, LiteLLM MIT), plus first-run `cdl-linux install claude-code|lmstudio` helpers that run the vendors' own installers so the user holds the license directly. The NVIDIA *driver* is fine to ship (its license explicitly permits redistribution with OSI-licensed kernels, unmodified, with the Agreement included); CUDA comes from NVIDIA's live ubuntu2604 repo at first boot.
- **B:** Ubuntu-style components: main/universe for permissive, restricted/multiverse for AGPL and FSL, third-party for EULA-gated fetch-only tools. Pacstall pacscripts already carry a `license=()` field — populate it and let rpk filter on it.
- **C:** Ignore all of it because the ISO is private. Legitimate if and only if you answered "personal machine" to the scope tension above.

**Recommendation:** Option A implemented via Option B's component structure. Make opencode or goose the preinstalled flagship agent — both are redistributable, both are already Pacstall packages, both have real headless modes — and reach Claude Code through a fetch helper. This is not a compromise on capability; it is a compromise on which logo appears first.

### "macOS-native keybindings" — literal Cmd everywhere, or macOS ergonomics translated into terminal idiom?
**Why it matters:** The obvious implementation is the one keyd's own examples/macos.conf does: make the Cmd layer inherit Control (`[meta_mac:C]`). In a terminal that is destructive, because Ctrl+letter is not a shortcut namespace, it is the control-character namespace and the tty line discipline. Cmd-S becomes XOFF (terminal appears frozen), Cmd-Z becomes SIGTSTP, Cmd-D becomes EOF/logout, Cmd-W becomes kill-word, Cmd-C becomes SIGINT. On real macOS these never collide because Cmd and Ctrl are genuinely separate — merging them destroys the exact property you are asking to preserve. Meanwhile the window-management half of macOS (Cmd-Tab, Cmd-Space, Cmd-M, Cmd-H, Cmd-Q) has no referent at all on a system with no window manager, and tmux cannot express Super in any form (its 226 KB manual contains zero occurrences of "super") and strips the kitty protocol from everything inside it.

- **A:** Literal Cmd, delivered as a genuine `super` modifier by the terminal emulator via the kitty keyboard protocol. keyd only swaps the physical key so Cmd sits beside the spacebar. Ghostty/foot/kitty consume Cmd-C/V themselves for clipboard; helix (`Cmd-s`), neovim (`<D-s>`), yazi (`<D-`), fish (`super-c`), zellij (`Super c`) and Emacs-with-kkp (`s-c`) all bind super natively. bash/zsh/less get Cmd chords translated into specific byte sequences by the terminal (`ghostty keybind = cmd+left=text:\x01`). Ctrl keeps its Unix meaning untouched. Requires Option A of the no-GUI tension, and zellij instead of tmux.
- **B:** CUA-style: a Ctrl-based scheme (micro's defaults), honestly documented as "macOS-ish, not macOS." Works everywhere including the bare VT, but Ctrl-S/Z/D/C collisions still have to be individually neutralized, and Emacs pays a permanent tax via cua-mode.
- **C:** Bare-VT fallback only: route ~8 Cmd chords through the kernel's unused F13-F20 function-key strings (\E[25~ through \E[34~, confirmed present in defkeymap.c and in terminfo). No clipboard, no Super-aware apps, but conflict-free.

**Recommendation:** Option A, with one hard rule written into the spec: the Cmd layer must never inherit Control. Re-target the window-management chords onto the multiplexer (Cmd-T new tab, Cmd-W close pane, Cmd-D split, Cmd-Tab next pane, Cmd-Space fzf launcher) and explicitly declare Cmd-Q/M/H unmapped rather than letting them fall through to XON/Enter/Backspace. Define the canonical table once in a machine-readable file and generate all eight config dialects from it. Before any of this, run `sudo keyd monitor` on the actual machine — I could not verify the Blade 15's bottom-row key order or whether Fn is firmware-handled and therefore invisible to evdev.

### How much of the installer and distribution stack do you want to own?
**Why it matters:** Rhino's only installer is Calamares, which is a Qt/QML GUI with no text frontend (zero ncurses hits in its tree, and its CLI options are only -d/-D/-c/-X/-T), is launched from a desktop icon with `Terminal=false`, and whose Rhino partition.conf offers a single-disk ext4/btrfs/xfs layout with no LVM and no RAID. So a TUI-only Rhino inherits exactly none of Rhino's installer work — and the installer is precisely the component that would have to do the two-NVMe storage layout. Whatever you choose, this is the largest single piece of work in the project. Note also that curtin was dropped from the Ubuntu archive after 22.04, so any curtin-based path means vendoring it.

- **A:** Adopt subiquity. It is already a curses TUI, its autoinstall schema already supports multi-disk LVM/RAID via a raw curtin `storage: config:` passthrough, multiple ESPs are supported (LP#1817066 Fix Released), and autoinstall makes the whole install declaratively testable in QEMU. Cost: AGPL-3.0 on the subiquity/ tree, a classic-confinement snap dependency, and real work to make it install a non-Ubuntu-Server rootfs.
- **B:** Write a thin scripted installer (sgdisk + mdadm/LVM + unsquashfs + grub-install) driven by a small TUI. Total control over the exact 2-NVMe layout, easily driven by expect over a serial console for CI. You own every edge case: LUKS, Secure Boot, recovery, network config, users.
- **C:** Skip the installer entirely for now: install Ubuntu Server with its stock TUI installer, then convert with `ub2r.sh` selecting `rhino-server-core`. Zero installer code written, and Ubuntu Server's installer already handles multi-disk LVM.

**Recommendation:** Option C to get the machine running this week, Option A if and when you commit to a distributable ISO. Do not write Option B — a bespoke installer is the highest-effort, highest-risk, lowest-differentiation component in the entire project, and the only thing it buys over subiquity is branding.


## DECOMPOSITION (14 sub-projects, in build order)

### 1. Hardware inventory and pre-wipe capture  _(risk: low)_
**Purpose:** Resolve the facts nobody could verify from public sources, BEFORE the disks are destroyed. Capture: `sudo dmidecode -s system-product-name/-version/baseboard-product-name` (which Razer chassis Lambda actually shipped — public sources disagree between i7-11800H/RTX 3080 Max-Q and i7-12800H/RTX 3080 Ti); `lspci -nn | grep -Ei 'vga|3d|network|audio'` (GPU PCI ID and whether WiFi is AX210 or the AX411/Killer AX1690 at subdev 0x1691/0x1692); `lsusb | grep -i 1532` (OpenRazer PID); `sudo nvme list; lsblk -d -o NAME,MODEL,TRAN,ROTA,PHY-SEC,LOG-SEC,SIZE` (whether BOTH drives are NVMe — at least one documented Tensorbook shipped 1TB NVMe + 1TB M.2 SATA, which would make striping actively harmful); the BIOS storage mode (Intel VMD/RST would hide the namespaces from a stock installer entirely); the BIOS Chipset setting (Dedicated GPU Only vs NVIDIA Dynamic Display Switch, which decides whether the console comes from i915/simpledrm or from nvidia-drm); the panel variant; `sudo keyd monitor` bottom-row key order and whether Fn produces any evdev event; and `grep MD_LINEAR /boot/config-$(uname -r)`. Also: full backup of anything on the machine.

**Depends on:** none

**Risk:** Cheap and fast, but strictly one-way — every fact here becomes unobtainable after the wipe, and at least six downstream decisions are currently blocked on guesses. The only real risk is skipping it.

### 2. Scope and philosophy decisions  _(risk: low)_
**Purpose:** Get written answers to the nine philosophy tensions, especially: what 'no GUI' forbids; personal machine vs public distro; rolling vs pinned base; combined 2TB vs split mounts; ISO fatness; and whether the product name keeps 'Rhino'. Produce a one-page decision record that every later sub-project cites.

**Depends on:** Hardware inventory and pre-wipe capture

**Risk:** No technical risk; enormous rework risk if skipped. Roughly half the remaining sub-projects have two mutually exclusive shapes depending on these answers.

### 3. Headless base rootfs prototype (in Docker)  _(risk: low)_
**Purpose:** Validate the entire non-hardware userland before touching the laptop, using Rhino's own published recipe: `FROM ubuntu:devel` (or `ubuntu:26.04` if pinned) -> rewrite sources -> install Pacstall -> `pacstall -PI nala-deb rhino-server-core`. Prove the TUI toolset, LLM CLIs, Python/uv layer, and package availability all resolve. `ghcr.io/rhino-linux/docker:latest` already exists as a starting point.

**Depends on:** Scope and philosophy decisions

**Risk:** Fastest possible feedback loop and no hardware needed. Caveat: it cannot validate kernel, GPU, console, or storage — do not mistake a green container for a working system.

### 4. Kernel, NVIDIA and Secure Boot policy  _(risk: high)_
**Purpose:** Pick and prove one coherent triple: (a) Ubuntu signed linux-image-generic + precompiled signed linux-modules-nvidia-595-open-generic + Secure Boot ON + no DKMS ever; or (b) Rhino mainline unsigned kernel + nvidia-headless-610-open DKMS + Secure Boot OFF. Use nvidia-headless-*-open, NOT nvidia-driver-* (which pulls xserver-xorg-video-nvidia and libnvidia-gl onto a machine with no X). Set /etc/dkms/no-autoinstall-errors if DKMS is in play, keep two kernels installed, add a boot-time `nvidia-smi -L` health check, and decide the nvidia-drm.modeset/fbdev policy from the BIOS MUX answer.

**Depends on:** Hardware inventory and pre-wipe capture

**Risk:** The highest-consequence failure mode in the project: on a machine with no X and no Wayland fallback, a driver or console regression is recoverable only from a live USB. NVIDIA 610.57.04 has a confirmed build failure on kernel 7.1.8 while Pacstall's linux-kernel already tracks 7.2, and nvidia-drm's fbdev console is known-broken on the 6.11+/7.0 generation (NV-Kernels #176). Always ship a `nvidia-drm.modeset=0 nomodeset` recovery GRUB entry.

### 5. Console and terminal session stack  _(risk: medium)_
**Purpose:** Build and prove the session: TTY autologin -> cage@tty1.service (upstream ships a complete unit template, PAM stack, and the WLR_LIBINPUT_NO_DEVICES=1 workaround) -> fullscreen kitty. Install fonts-firacode (unpatched, ligature tables intact) plus fonts-nerd-symbols as a fontconfig icon fallback rather than a patched font. Ship kmscon or a plain getty on tty2 as a rescue console. Verify with `notcurses-info` what the resulting terminal actually supports.

**Depends on:** Kernel, NVIDIA and Secure Boot policy

**Risk:** wlroots on NVIDIA has historically been painful; improved substantially with explicit sync in driver 555+. If the panel is wired to the Intel iGPU (normal for a hybrid Blade 15) cage runs on Intel and this is a non-issue — but that is exactly what the hardware inventory has to confirm. Also add /etc/libinput/local-overrides.quirks with MatchName=keyd*keyboard or the trackpad will misbehave while typing.

### 6. Storage layout and installer  _(risk: high)_
**Purpose:** Implement the chosen disk layout end to end. Whatever is chosen, the ESP and /boot must sit outside it (UEFI reads only plain FAT32; GRUB2's LUKS2 support covers PBKDF2 but not Argon2id, which is cryptsetup's LUKS2 default). If LUKS is wanted, put it UNDER the combining layer (one container per drive) with `--sector-size 4096 --perf-no_read_workqueue --perf-no_write_workqueue --allow-discards --persistent`, and use keyutils/decrypt_keyctl with the crypttab `initramfs` flag for a single passphrase. Register two ESPs via curtin `grub: install_devices: [...]` / debconf `grub-efi/install_devices`. Then either drive subiquity with an autoinstall file or use Ubuntu Server's stock installer plus ub2r.sh.

**Depends on:** Scope and philosophy decisions

**Risk:** Rhino's Calamares cannot express any multi-disk layout and is not a TUI, so this cannot be inherited. curtin cannot declare a striped LV (no stripes/stripesize key) — that needs an lvcreate late-command. Do not ship `raidlevel: linear` without checking CONFIG_MD_LINEAR on the target kernel: it validates in curtin's schema but was removed from mainline in 6.8, reinstated in 6.14 as deprecated, and is off in Debian trixie.

### 7. macOS keybinding layer  _(risk: medium)_
**Purpose:** Define the canonical Cmd table once, in a machine-readable file, and generate every downstream config from it: keyd default.conf (physical Super/Alt swap only), kitty/ghostty keybinds, ~/.inputrc, zsh bindkeys, helix config.toml, nvim Lua keymaps, zellij config.kdl, yazi keymap.toml, and Emacs init using the kkp MELPA package for a real `super` modifier. Mine Toshy's config for WHICH chords matter (do not ship Toshy — it hard-requires X11/Wayland window-class context).

**Depends on:** Console and terminal session stack

**Risk:** The failure mode is subtle and severe: any binding that reaches the pty as a control character breaks the shell rather than erroring. Zellij is required over tmux (tmux has no Super and strips the kitty protocol), and zellij is in neither Ubuntu nor Pacstall, so it must be vendored as a pinned static musl binary.

### 8. Python, CUDA and scientific layer  _(risk: medium)_
**Purpose:** Own the interpreter rather than fighting PEP 668 and a moving system Python: `uv python install` a python-build-standalone build into /opt/cdl-linux, create the ML venv there, install torch from the cu130 index (matches PyPI's default and vllm's pin; sm_86 is in the shipped SASS arch list; driver 580+ satisfies it). Set HF_HOME to the big volume. Ship a curated TeX subset (texlive-latex-recommended + -extra + -fonts-recommended + -science + -bibtex-extra + latexmk + biber = 0.33 GiB download / 0.89 GiB installed) plus apt-file with a pre-built index, not texlive-full. Vendor uv, tectonic and euporie as pinned binaries.

**Depends on:** Headless base rootfs prototype (in Docker)

**Risk:** Ubuntu already carries python3.15.0~rc1 alongside 3.14, so any venv tied to the system python3 will be orphaned by a default-interpreter bump. Do not use cu128 (its index is frozen at torch 2.11.0). aider cannot be installed at all (requires_python <3.13) and should be dropped, not worked around.

### 9. LLM tooling layer  _(risk: medium)_
**Purpose:** Install the redistributable engines and clients: llama.cpp (whose llama-server uniquely serves OpenAI chat-completions, OpenAI Responses AND Anthropic Messages from one binary), Ollama via the existing Pacstall ollama-bin package (bundles its own CUDA runtime, so it needs only the driver), llama-swap for hot-swapping models behind one port on 16 GB of VRAM, and one flagship agent (opencode or goose, both Pacstall-packaged). Optionally LiteLLM as a single local gateway. Ship /etc/cdl-linux/providers.env setting BOTH spellings of the divergent env vars (TOGETHER_API_KEY and TOGETHERAI_API_KEY; FIREWORKS_API_KEY and FIREWORKS_AI_API_KEY; OPENROUTER_API_KEY and OR_API_KEY) plus an `cdl-linux doctor` that probes each endpoint. Proprietary tools (Claude Code, LM Studio) get fetch-on-demand helpers only.

**Depends on:** Python, CUDA and scientific layer

**Risk:** Ubuntu's llama.cpp is CPU-only in practice — libggml0-backend-cuda exists only at 0.20.2-2, in multiverse, in stonking-proposed, and version-lagged behind libggml0 0.22.0-1. Either build with -DGGML_CUDA=ON in your pipeline or make Ollama the default GPU engine. Codex CLI, if included, forces a Responses-API endpoint into the design.

### 10. Networking, power and backup  _(risk: medium)_
**Purpose:** NetworkManager + nmtui (which does support WPA2/WPA3-Enterprise 802.1X, WPA3 Personal, OWE and WireGuard editing, contrary to common belief — but cannot CREATE VPN connections, only activate them). Pin Tailscale's apt suite to `resolute` literally or use its install.sh, never $VERSION_CODENAME. Pick exactly one of TLP or power-profiles-daemon and mask the other. Backup via restic over SFTP or restic-rest-server (--append-only), NOT restic's local backend over a CIFS mount; `--exclude-caches` drops the whole HF cache for free because huggingface_hub writes CACHEDIR.TAG. Keep a plain-text manifest of excluded weights inside the backup so restore is a scripted re-download.

**Depends on:** Headless base rootfs prototype (in Docker)

**Risk:** The unsolvable piece is browser-required OAuth (Tailscale login, Anthropic console, SAML VPNs, JS captive portals) — no terminal browser can complete a 2026 identity-provider flow. Design around it with pre-generated auth keys and second-device logins; do not plan on browsh (last release 2024-01) or carbonyl (last release 2023).

### 11. ISO build pipeline and CI  _(risk: high)_
**Purpose:** Fork rhino-linux/os (GPL-3.0) — the v2 branch's overlay design is the intended seam — and create platform/iso-generic/environment/<name>/ with a TUI package list and install hook. Note `server` will assemble without error for amd64 but silently produce an unusable ISO with no environment layer at all; name your environment something else. Add jlumbroso/free-disk-space as step 1 (GitHub guarantees only 14 GB). Test the resulting ISO in QEMU with two independent NVMe controllers and OVMF — nested virt is confirmed working on GitHub Linux x86 runners (but not arm64), and you must install qemu-system-x86 + ovmf at job time plus a /dev/kvm udev rule.

**Depends on:** Storage layout and installer

**Risk:** There is no third-party flavor SDK, SDK docs, or supported process — grepping Rhino's wiki and repos for spin/flavour/remix returns only unrelated hits. The v2 branch is unmerged. ISOs are built only by manual workflow_dispatch upstream. CUDA/GPU behavior cannot be tested in hosted CI at all; that requires the Tensorbook enrolled as a self-hosted runner.

### 12. Branding, licensing and legal debrand  _(risk: medium)_
**Purpose:** Replace every Rhino asset with original work — rhino-linux/branding, wallpapers, plymouth, lightdm and dotfiles all have NO license file, so default copyright applies and they are not redistributable. Rename via etc/terraform.conf (DISTRO_NAME, NAME, FNAME). Add a non-affiliation disclaimer modeled on Rhino's own ('Ubuntu and Canonical are registered trademarks of Canonical Ltd... Linux is the registered trademark of Linus Torvalds'), plus a third line disclaiming Rhino affiliation. Ship the NVIDIA driver license text with the ISO; do not ship the CUDA toolkit.

**Depends on:** ISO build pipeline and CI

**Risk:** Only applies if the ISO is distributed. The Canonical IP policy's 'will need to recompile the source code to create your own binaries' clause cannot be satisfied and is not satisfied by any Ubuntu derivative including Rhino itself — the honest posture is full debrand plus a prominent disclaimer, accepting a residual and apparently-unenforced risk knowingly.

### 13. Documentation and screenshot regression testing  _(risk: low)_
**Purpose:** Write tapes for charmbracelet/vhs and use `vhs docs/tapes/*.tape && git diff --exit-code docs/img/` as a genuine TUI regression test — I verified locally that VHS PNG output is byte-identical across six runs while GIF output produced four distinct hashes across the same six runs. Auto-commit PNGs only; generate GIFs on tagged releases. Install fonts-firacode on the CI runner or every docs image silently renders in JetBrains Mono. Assert each expected PNG exists: a `Screenshot` as the final tape command produces no file while exiting 0.

**Depends on:** Console and terminal session stack

**Risk:** Cheap and high-leverage. The main trap is committing regenerated GIFs, which churns the repo with a new binary blob on every CI run.

### 14. Distribution: USB writing, checksums and signing  _(risk: medium)_
**Purpose:** Publish SHA256SUMS plus a detached signature (Ubuntu's SHA256SUMS + SHA256SUMS.gpg layout, or cosign keyless from CI) — upstream Rhino ships only a bare .sha256 next to the ISO on the same host, which provides no protection against a compromised mirror. For USB writing, recommend Ventoy (copy the ISO onto a prepared stick; a browser CAN legitimately do this part via showSaveFilePicker) plus documented native dd commands, and hand Windows users to Rufus. Mandate exFAT, not FAT32.

**Depends on:** ISO build pipeline and CI

**Risk:** Browser-based flashing is impossible (see hard blockers). Ventoy carries an unresolved supply-chain concern (issue #3224 open since 2025-05 with 132 comments) and its Secure Boot mode is an explicit bypass, so recommending it for a laptop-wiping operation is a judgement call. GitHub Releases caps assets at 2 GiB, so ISO hosting needs SourceForge/R2/B2 or split archives.


## TOP USER QUESTIONS (12)

### Q1. Does "TUI-only, no GUI" forbid a single fullscreen kiosk compositor (cage) whose only client is a terminal, or does it forbid the graphics stack entirely?
**Matters:** This is the highest-leverage question in the project and everything else cascades from it. Answer 'compositor is fine' and you get Fira Code ligatures, truecolor, a real clipboard, a real Cmd modifier, inline images, and a working croft. Answer 'bare VT only' and I must delete the ligature requirement, the croft requirement, the clipboard, and the Cmd keybindings from the spec — not partially satisfy them. It also changes the storage of your session config, the keybinding architecture, and whether wlroots-on-NVIDIA is a risk you carry.

**Options:** (A) cage + fullscreen kitty, with kmscon or a getty on tty2 as a rescue console — no desktop, no WM, no windows, no panel, no mouse-driven apps, 33 MB installed. (B) kmscon only — real antialiased Fira Code and 24-bit color with no compositor, but no ligatures and no images, ever. (C) bare kernel VT with a PSF font converted from Fira Code — letterforms only.

**Default:** (A). You asked by name for Fira Code ligatures, croft, and macOS keybindings; those three requirements together are a request for a real terminal emulator whether or not it was phrased that way. cage's own upstream says it 'will not fit into a regular desktop-style workflow', which is exactly the property you want.

### Q2. Is cdl-linux a machine you need working, or a distro other people will download and install?
**Matters:** Trademark debranding, the Canonical recompile clause, CUDA EULA analysis, LM Studio and Claude Code redistribution, ISO hosting above GitHub's 2 GiB cap, signed installers, checksum signing, and cross-platform USB tooling exist ONLY because of redistribution. If the audience is you, all of that disappears and the project shrinks by roughly half. If it is public, none of it is optional.

**Options:** (A) Personal machine — skip the ISO entirely for now; install Ubuntu Server 26.04, run Rhino's ub2r.sh selecting rhino-server-core, layer tooling from a config repo. Working machine in an afternoon. (B) Public flavor — fork rhino-linux/os, build a TUI environment overlay, debrand, add an installer, CI, hosting and signing. (C) Personal first, but every configuration decision expressed as an idempotent versioned script so productizing later is packaging, not archaeology.

**Default:** (C). It gets you a working Tensorbook this week without foreclosing the ISO, and it forces the discipline that makes an ISO cheap later.

### Q3. Should the base be Ubuntu's rolling `devel` archive (what Rhino actually tracks) or pinned to Ubuntu 26.04 LTS?
**Matters:** Ubuntu devel's Release file has a 14-day Valid-Until and rolls to 27.04 development weeks after 26.10 ships on 2026-10-15. Rhino's own docs say the state 'is unstable' and is 'strongly advised against using this in a production setting'. A real incident on 2026-02-14 left Pacstall unable to run any command after an upstream coreutils change. Tailscale publishes a `resolute` apt suite but 404s on `stonking`. NVIDIA's CUDA repos exist only for LTS releases. And with no GUI fallback, a broken driver after an update means recovery from a USB stick.

**Options:** (A) Track devel, mitigate with snapshots, two kernels, /etc/dkms/no-autoinstall-errors, and a boot-time nvidia-smi health check. (B) Pin to 26.04 LTS, keep Canonical's signed kernel and precompiled signed NVIDIA modules, adopt Pacstall + rpk + rhino-server-core on top. 'Rhino-flavored', not literally Rhino. (C) Snapshot-rolling — mirror the devel archive at a chosen date, advance deliberately after testing.

**Default:** (B). The concrete benefit of rolling on an Ampere laptop from 2022 is close to zero, and the cost is the single largest source of avoidable risk in the project. If 'rolling' is a value rather than a means, take (C), never (A).

### Q4. Should the two 1TB drives be one ~2TB volume, or two mounts with different roles? And do you want full-disk encryption?
**Matters:** Combining doubles total-loss probability with no redundancy on a laptop that gets carried around (computed: 7.73% vs 3.94% over four years at 1% AFR). Encryption then negates most of the throughput you paid that risk for — measured dm-crypt caps at ~1130 MB/s at 512-byte LUKS sector, ~1994 MB/s at 4096, and an independent 2xNVMe test found LUKS-on-RAID0 'hardly any better than a single LUKS-encrypted NVMe'. With 64 GB RAM, page cache makes striping matter only for the FIRST read of each model. This also determines the installer choice, since Rhino's Calamares cannot express any of it.

**Options:** (A) LVM VG across both PVs, / and /home pinned to PV1, a striped LV only for /var/lib/models (needs an lvcreate -i 2 late-command; curtin cannot declare striped LVs). (B) Do not combine: / on nvme0, models/datasets on nvme1. (C) mdadm RAID0 or btrfs multi-device for one flat namespace. (D) 1TB mirror plus an external 2TB in a Thunderbolt 4 enclosure. Encryption, if wanted: LUKS UNDER the combining layer, one container per drive, --sector-size 4096, --perf-no_read_workqueue/--perf-no_write_workqueue, --persistent, single passphrase via keyutils/decrypt_keyctl.

**Default:** (B), unless you can name a single working set above ~900 GB. 'Combine into 2TB' is a shape; the need is usually 'room for weights', which a second mount satisfies with none of the risk. If combining, (A) over (C).

### Q5. Which installer? Adopt subiquity, write a scripted TUI installer, or skip the ISO for now?
**Matters:** This is the largest single piece of work in the project and it cannot be inherited from Rhino — Calamares is Qt/QML-only with no ncurses component, is launched with Terminal=false, and its partition module cannot create LVM or RAID. curtin was dropped from the Ubuntu archive after 22.04, so a curtin-based path means vendoring it. Whichever you choose determines whether the two-NVMe layout is declarative and testable in QEMU or hand-rolled shell.

**Options:** (A) subiquity + autoinstall YAML — already a curses TUI, multi-disk via raw curtin storage config, multiple ESPs supported (LP#1817066 Fix Released), declaratively testable. Costs: AGPL-3.0 on the core, a classic snap dependency, and work to install a non-Ubuntu-Server rootfs. (B) Custom TUI over sgdisk/mdadm/LVM/unsquashfs/grub-install — total control, you own every edge case. (C) Ubuntu Server's stock installer + ub2r.sh selecting rhino-server-core — zero installer code, TUI end to end, handles multi-disk LVM today.

**Default:** (C) now, (A) if and when you commit to a distributable ISO. Do not write (B) — a bespoke installer is the highest-effort, highest-risk, lowest-differentiation component here, and the only thing it buys over subiquity is branding.

### Q6. Kernel and Secure Boot: Ubuntu's signed linux-image-generic, or Rhino's unsigned mainline kernel?
**Matters:** Rhino ships linux-image-unsigned-7.0.9 (and Pacstall's linux-kernel now tracks 7.2), which means Secure Boot must be off AND Ubuntu's prebuilt NVIDIA modules cannot be used (they are ABI-keyed to Ubuntu's own kernel), which forces DKMS, which has a confirmed 610.57.04 build failure on kernel 7.1.8. Ubuntu itself ships out-of-tree buildfix patches (buildfix_kernel_7.0.patch) because upstream NVIDIA does not compile cleanly on 7.0+. On a machine with no graphical fallback, a failed module rebuild is a USB-stick recovery.

**Options:** (A) Ubuntu signed linux-image-generic + linux-modules-nvidia-595-open-generic (precompiled, Canonical-signed, never compiles, Secure Boot stays ON, no MOK enrollment). (B) Rhino mainline kernel + nvidia-headless-610-open DKMS + Secure Boot off in the Razer BIOS. (C) Mainline kernel plus your own MOK, signing both vmlinuz and the modules with sbsigntool on every update.

**Default:** (A). Note also: use nvidia-headless-*-open, never nvidia-driver-*, since the latter depends on xserver-xorg-video-nvidia and libnvidia-gl. And whichever you pick, always ship a `nvidia-drm.modeset=0 nomodeset` recovery GRUB entry — nvidia-drm's fbdev console is known-broken on this kernel generation (NV-Kernels #176).

### Q7. Do you want models baked into the ISO, and if so how many gigabytes of ISO are acceptable?
**Matters:** I measured that GGUF is effectively incompressible — xz -6 reaches 96.28% of original, zstd -19 96.00%, gzip -9 96.39% — so squashfs saves ~4% and every GB of model is a GB of ISO on top of Rhino's 2.70 GiB baseline. A first-boot download measured ~4.1 min for 12 GB from Ollama and ~7.7 min from Hugging Face here, but ~32 min on a 50 Mbit/s home line. Offering a model *picker* at install time is arithmetically impossible because it would mean shipping every candidate.

**Options:** (A) Lean ~3.5 GB ISO, everything fetched at first boot. (B) One small model baked as an offline floor — gemma-4-E4B-it Q4_K_M (4.98 GB) or Qwen3-8B Q4_K_M (5.03 GB) — larger models on demand. (C) Two published images, a lean netinstall and a fat offline edition preloading the wheel cache. Regardless: move the picker to first boot and gate it on measured Hugging Face blob sizes against detected VRAM.

**Default:** (B). It gives a working local assistant with no network while keeping the ISO under ~10 GB. The size gate on the picker is non-negotiable — the 2026 headline 'Flash' models are 111-150 GB MoEs and a trending-list picker will offer models that cannot load.

### Q8. For the macOS keybindings: literal Cmd delivered as a real `super` modifier, or a Ctrl-based CUA scheme honestly labeled 'macOS-ish'? And which chords do you actually use, ranked?
**Matters:** The obvious implementation — aliasing the Cmd layer onto Control, which keyd's own examples/macos.conf does — is destructive in a terminal: Cmd-S becomes XOFF (looks like a hang), Cmd-Z becomes SIGTSTP, Cmd-D becomes logout, Cmd-W becomes kill-word, Cmd-C becomes SIGINT. On real macOS these never collide because Cmd and Ctrl are separate keys. I also need your actual chord list: a design serving {C,V,X,Z,S,A,F,W,T,arrows} is completely different from one that must also handle Cmd-Tab, Cmd-Space and Cmd-Option chords.

**Options:** (A) Literal Cmd via the kitty keyboard protocol; keyd only swaps the physical key position; terminal consumes Cmd-C/V for clipboard; helix/neovim/yazi/fish/zellij/Emacs-with-kkp bind super natively; bash/zsh/less get terminal-emitted byte sequences. Requires zellij over tmux. (B) Ctrl-based CUA (micro's defaults), works on the bare VT, documented as not-actually-macOS. (C) Bare-VT fallback via the kernel's F13-F20 strings, ~8 chords, no clipboard.

**Default:** (A), with one rule written into the spec: the Cmd layer must NEVER inherit Control. Re-target window-management chords onto the multiplexer (Cmd-T/W/D/Tab/Space) and explicitly leave Cmd-Q/M/H unmapped rather than letting them fall through to XON/Enter/Backspace.

### Q9. Which agent is the preinstalled flagship, and are the proprietary tools fetch-on-demand?
**Matters:** Claude Code and LM Studio cannot legally be shipped, so if either is the assumed default the distro has no working out-of-box AI experience. There is also a subtler trap: Anthropic states it 'doesn't support routing Claude Code to non-Claude models through any gateway', and setting ANTHROPIC_BASE_URL to a non-Anthropic host silently disables Remote Control and voice dictation — so making Claude Code the universal local front-end degrades it without telling the user. Additionally, if Codex CLI is included it constrains the whole gateway design, because custom providers now accept only wire_api="responses".

**Options:** (A) opencode (MIT, 202k stars, Pacstall-packaged, has `run` and `serve` headless modes). (B) goose (Apache-2.0, Linux Foundation, Pacstall-packaged, and ships CUSTOM_DISTROS.md — 'build your own goose distro with preconfigured providers, extensions, and branding' — which is exactly this use case). (C) Codex CLI (Apache-2.0, static musl, zero deps). Plus `cdl-linux install claude-code|lmstudio` helpers.

**Default:** (A) preinstalled with (B) also available, Claude Code and LM Studio via fetch helpers. Do not set ANTHROPIC_BASE_URL globally — ship a `claude-local` wrapper that sets it per-invocation.

### Q10. What is the backup target, exactly — make, model, and whether it can do SSH/SFTP, run a container, or only SMB/NFS?
**Matters:** I cannot pick a backup design without this and the design differs completely by answer. restic has no native SMB or NFS backend; pointing its local backend at a CIFS mount runs its lock protocol over a filesystem whose semantics restic's docs never address. Borg is worse — its own FAQ says 'Avoid using NFS or other network filesystems for repository storage if possible' and ssh:// requires borg installed on the NAS. This matters more than usual because a striped 2TB volume with no redundancy makes the backup load-bearing rather than nice-to-have.

**Options:** (A) SFTP: `restic -r sftp:user@nas:/path` — needs only sshd, works on nearly every NAS. (B) restic-rest-server on the NAS with --append-only (best security and locking; already packaged as restic-rest-server 0.14.0-1). (C) rclone's smb backend as restic's transport if SMB is truly the only option. (D) borgmatic, which ships ready-made systemd .service/.timer units.

**Default:** (A). Also decide the weights policy: `--exclude-caches` drops the whole HF cache for free (huggingface_hub writes CACHEDIR.TAG), but then keep a plain-text manifest (`hf cache ls --format json`, `ollama list`, a lockfile) inside the backup so restore is a scripted re-download rather than archaeology — and back up fine-tuned checkpoints unconditionally, since those are irreplaceable.

### Q11. Does the product name keep 'Rhino' in it, and are you willing to ask the Rhino maintainers for a branding license?
**Matters:** Rhino publishes no trademark policy and their branding repo has no license file at all, so their logo, wallpapers, Plymouth and LightDM themes are not redistributable by default copyright. Separately, the Linux Foundation requires a (free, perpetual) sublicense for any software mark containing the adjacent letters 'Linux' — 'cdl-linux' needs none, but 'LLM Rhino Linux' would. And Canonical's IP policy requires removing their trademarks from any redistributed modified Ubuntu.

**Options:** (A) Pick a name with no 'Ubuntu', 'Rhino' or 'Linux' in it; original art; lineage described only in prose (nominative use, not trademark use); a three-line disclaimer modeled on Rhino's own. (B) Ask on their Discord or open an issue on rhino-linux/tracker for an explicit license on the branding repo — and accept that the release may block on their reply. (C) Ignore it entirely because the ISO is private.

**Default:** (A) if distributing, (C) if not. Note that getting Rhino to add a LICENSE file to their branding repo would benefit every downstream, so (B) is worth doing in parallel even if you proceed with (A).

### Q12. How much of the system should be opinionated by default, and should each opinion be independently removable?
**Matters:** You have asked for keybindings, a default font, a default editor stack, preinstalled models and 'CUDA out of the box' — each is a decision made for the user, and each is a maintenance surface. A canonical Cmd table must be regenerated into eight config dialects. A blessed shared venv means users step on each other. Installing TLP without masking power-profiles-daemon leaves two daemons overwriting the same kernel tunables with a warning nobody sees on a headless box. Getting this wrong produces a distro that is either surprising or inert.

**Options:** (A) Heavily opinionated monolith — everything works together day one, deviating means fighting the distro. (B) Lightly opinionated — ship tools, and an opt-in `cdl-linux-config apply` installs the opinions. (C) Opinionated defaults packaged as individually-removable units: cdl-linux-keybindings, cdl-linux-fonts, cdl-linux-llm-defaults, cdl-linux-power.

**Default:** (C). It gives the day-one experience of (A) with the escape hatches of (B), and forces each opinion to be a discrete versioned artifact rather than accumulated dotfile sediment.


## VENDOR LIST (35)

| name | url | role | license |
|-|-|-|-|
| rhino-linux/os | https://github.com/rhino-linux/os | The fork target for an ISO. Branch v2 is the overlay-based multi-platform/multi-environment builder (`sudo ./rhino-os.sh build <platform> <environment> <dir>`) where a TUI flavor is an environment overlay, not a distro fork; branch main is what actually built the shipping 2026.1 ISO and has a single highest-leverage edit point (the one pacstall line in etc/config/hooks/live/099-install-custom-apps.chroot). Also contains ub2r.sh, the official Ubuntu-to-Rhino converter that offers rhino-server-core as a supported TUI-only configuration. | GPL-3.0 |
| rhino-linux/docker | https://github.com/rhino-linux/docker | Proven minimal headless Rhino recipe and the fastest prototyping loop — `pacstall -PI nala-deb rhino-server-core` on top of ubuntu:devel. Validate the entire userland here before touching the laptop. Prebuilt at ghcr.io/rhino-linux/docker:latest. | none declared (no LICENSE file — ask upstream before reusing) |
| pacstall/pacstall and pacstall/pacstall-programs | https://github.com/pacstall/pacstall | Rhino's source package manager (6.4.2) and its package tree. Contains rhino-server-core, rhino-core, ollama-bin, opencode-bin, goose-cli-bin, llama-swap-bin, helix, and the linux-image-unsigned-deb pacscript that is the source of the unsigned-kernel/Secure-Boot problem. Pin a known-good version: an upstream coreutils change broke Pacstall distro-wide in Feb 2026. | GPL-3.0 |
| canonical/subiquity | https://github.com/canonical/subiquity | The only mature TUI installer with a declarative unattended mode. Its autoinstall storage schema handles the two-NVMe case via a raw curtin `storage: config:` passthrough, and multiple ESPs are supported (LP#1817066 Fix Released). DESIGN.md documents the client/server split over /run/subiquity/socket; subiquity/common/apidef.py is the endpoint list. | AGPL-3.0-or-later (subiquity/ tree); GPL-3.0-only elsewhere |
| canonical/curtin | https://github.com/canonical/curtin | The actual install engine under subiquity. MUST be vendored from git — it is no longer published in the Ubuntu archive after jammy (22.04). curtin/block/schemas.py is authoritative for what is declaratively expressible (raidlevel enum, and the LVM_PARTITION property list that proves striped LVs are NOT expressible). | AGPL-3.0 |
| livecd-rootfs | https://git.launchpad.net/livecd-rootfs | Ubuntu's own live-image and (since 2026) ISO builder, v26.10.7. Fork it as an alternative to rhino-linux/os, or vendor live-build/isobuilder/ as the authoritative xorriso/shim/ESP hybrid-ISO recipe. README.local.md documents running it outside Launchpad. | AGPL-3.0 |
| mwhudson/livefs-editor | https://github.com/mwhudson/livefs-editor | Remaster an existing Ubuntu live ISO with declarative actions (inject autoinstall, add kernel cmdline args, add packages to the pool). Fastest path to a working unattended installer for bring-up. Actively maintained (2026-08-27). | GPL-3.0 |
| cage-kiosk/cage | https://github.com/cage-kiosk/cage | The 77 kB single-client Wayland kiosk that makes 'one fullscreen terminal, no desktop' a supported configuration. Vendor its wiki's cage@.service unit and /etc/pam.d/cage stack directly (`git clone https://github.com/cage-kiosk/cage.wiki.git`). Note WLR_LIBINPUT_NO_DEVICES=1 is needed if no input device is present at boot. | MIT |
| kovidgoyal/kitty | https://github.com/kovidgoyal/kitty | Recommended terminal: HarfBuzz shaping for Fira Code ligatures, 24-bit color, the originator of the graphics protocol croft names, and no GTK/Qt/libadwaita dependency. Also vendor docs/keyboard-protocol.rst as the normative spec for the Cmd/super modifier design. | GPL-3.0 |
| kmscon/kmscon | https://github.com/kmscon/kmscon | Real TrueType and truecolor console on bare KMS with no compositor — ship on tty2 as the rescue console regardless of the primary session choice. Revived 2025, v10.0.2, in the Ubuntu archive, and accepted as Fedora 45's fbcon replacement. Cannot do ligatures (single-codepoint render API) or images. | NOASSERTION on GitHub — audit COPYING before redistributing |
| rvaiya/keyd | https://github.com/rvaiya/keyd | The evdev/uinput remapper. The only candidate documenting bare-VT support. Use ONLY for the physical Super/Alt swap (put Cmd beside the spacebar) and, on a bare-VT fallback, for Cmd-to-F13..F20 translation. Read examples/macos.conf, take its two swap lines, and reject its `[meta_mac:C]` Control inheritance. Apt-installable (keyd 2.5.0-5). | MIT |
| benotn/kkp | https://github.com/benotn/kkp | Gives terminal Emacs a real `super` modifier via the kitty keyboard protocol, so Cmd-C binds as `s-c` and C-c stays the untouched user prefix — the only way to get Mac copy/paste in Emacs without cua-mode's permanent prefix tax. On MELPA; enable with (add-hook 'tty-setup-hook #'global-kkp-mode). Dies under tmux. | GPL-3.0 |
| zellij-org/zellij | https://github.com/zellij-org/zellij | The only mainstream multiplexer that can bind Super (`bind "Super c"`) and that passes the kitty protocol through to panes, so helix/neovim/Emacs-kkp keep working inside it. Required if you want literal Cmd. Not in Ubuntu or Pacstall — vendor the pinned zellij-no-web-x86_64-unknown-linux-musl.tar.gz (14.3 MiB). | MIT |
| helix-editor/helix | https://github.com/helix-editor/helix | The only editor with literal `Cmd-` binding syntax ('Meta-', 'Cmd-' and 'Win-' are synonyms for super). Available via Pacstall (`pacstall -I helix`), which Rhino already ships. Its wiki also maintains the citable terminal kitty-keyboard-protocol compatibility table you should use to pick the terminal emulator. | MPL-2.0 |
| ggml-org/llama.cpp | https://github.com/ggml-org/llama.cpp | The single most valuable LLM component: llama-server alone serves /v1/chat/completions, /v1/responses AND Anthropic /v1/messages from one MIT binary, so it backs Claude Code, Codex CLI and every OpenAI-compatible client with no gateway. In the Ubuntu archive, but you must rebuild with -DGGML_CUDA=ON — there is no Linux CUDA prebuilt upstream and libggml0-backend-cuda in the archive is version-lagged and stuck in multiverse-proposed. | MIT |
| ollama/ollama | https://github.com/ollama/ollama | Best default local engine on this hardware: bundles its own CUDA runtime so the GPU works with only the driver installed, serves both OpenAI /v1/ and Anthropic /v1/messages, and measured ~49 MB/s from its registry (roughly twice Hugging Face). Already a Pacstall package (ollama-bin, current at 0.33.2) with a systemd unit and pinned checksums. | MIT |
| anomalyco/opencode | https://github.com/anomalyco/opencode | Redistributable flagship agent candidate. MIT, 202k stars, Pacstall-packaged as opencode-bin, with both headless modes (`opencode run`, `opencode serve`) and documented local-endpoint guides. Note the repo moved from sst/opencode. | MIT |
| aaif-goose/goose | https://github.com/aaif-goose/goose | The other redistributable flagship candidate, now a Linux Foundation (Agentic AI Foundation) project. Pacstall-packaged as goose-cli-bin. Crucially it ships CUSTOM_DISTROS.md — 'build your own goose distro with preconfigured providers, extensions, and branding' — which may save writing a provisioning layer outright. Note the repo moved from block/goose. | Apache-2.0 |
| BerriAI/litellm | https://github.com/BerriAI/litellm | The only gateway serving all three protocol families at once — chat-completions, /v1/responses (with automatic bridging for chat-only upstreams), and Anthropic /v1/messages — which is what makes Codex CLI and Claude Code both work against arbitrary providers. Exclude the enterprise/ directory, which is separately licensed. | MIT (except enterprise/, separately licensed) |
| mostlygeek/llama-swap | https://github.com/mostlygeek/llama-swap | Hot-swaps models behind a single stable port — the direct answer to holding one large model plus one fast small one on 16 GB of VRAM. Already a Pacstall package (llama-swap-bin), so no new build infrastructure. | MIT |
| astral-sh/uv | https://github.com/astral-sh/uv | The load-bearing answer to PEP 668 plus a moving system Python: supplies a standalone python-build-standalone interpreter immune to Ubuntu's staged 3.14-to-3.15 bump, and `--torch-backend=auto` detects the driver and picks the right PyTorch index. Vendor the 18.5 MiB release tarball rather than the curl/sh installer. Not packaged in Ubuntu. | MIT OR Apache-2.0 |
| tectonic-typesetting/tectonic | https://github.com/tectonic-typesetting/tectonic | 9.7 MiB musl binary for zero-config on-demand LaTeX. Set TECTONIC_CACHE_DIR to the big volume. IMPORTANT caveat: its default network bundle still resolves to TeX Live 2022 (default_bundle_v33.tar -> tlextras-2022.0r0.tar; v34-v37 are 404), so treat it as a convenience tool alongside apt's texlive 2026, not as the primary engine — or build your own bundle and pin it with TECTONIC_BUNDLE_PREFIX. | MIT |
| joouha/euporie | https://github.com/joouha/euporie | The TUI answer to Jupyter — notebook, console, preview and an SSH hub, with kitty/sixel graphics and rendering of markdown, tables, images, LaTeX, HTML, SVG and PDF in the terminal. Not packaged; `uv tool install euporie`. Single-maintainer, v2.10.4 dated 2026-02-23, so vendor a pinned version. | MIT |
| charmbracelet/vhs and charmbracelet/vhs-action | https://github.com/charmbracelet/vhs | Scripted, diffable terminal recordings that can drive an interactive TUI. I verified locally that PNG output is byte-identical across six runs while GIF output produced four distinct hashes, so `vhs docs/tapes/*.tape && git diff --exit-code docs/img/` is a genuine TUI regression test. vhs-action installs ttyd and ffmpeg for you; change its auto-commit example's file_pattern from '*.gif' to '*.png'. | MIT |
| os-autoinst/os-autoinst | https://github.com/os-autoinst/os-autoinst | The CI-usable standalone engine under openQA, for needle-based install testing in QEMU: `podman run --rm -it -v .:/tests registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-kvm casedir=/tests`, with a qemu-x86 variant for hosts lacking KVM. Prefer this over standing up the full openQA webui+worker stack. | GPL-2.0 |
| tonsky/FiraCode | https://github.com/tonsky/FiraCode | The requested font, OFL-1.1 with no Reserved Font Name declared, so freely shippable. Prefer Ubuntu's fonts-firacode package (6.2-3) over vendoring — it installs the unmodified TTFs with GSUB tables intact and drops the license at /usr/share/doc/fonts-firacode/copyright. Install it on the CI runner too, or VHS silently renders docs images in JetBrains Mono. | OFL-1.1 |
| ryanoasis/nerd-fonts | https://github.com/ryanoasis/nerd-fonts | Source for icon glyphs that TUIs (croft, lazygit, yazi) require. Prefer the fontconfig-fallback approach: unpatched fonts-firacode plus the fonts-nerd-symbols package, so Fira Code's ligature table is never touched by a patcher. NOTE fonts-nerd-symbols exists only in the stonking suite — confirm against your pinned base. Audit licensing per-font before redistributing. | NOASSERTION (aggregate — each patched font inherits its source font's license) |
| vitali87/croft | https://github.com/vitali87/croft | The 'croft' you named: a VS Code-style three-pane Rust TUI workspace, `cargo install croft-software --locked`. Its own requirements (Nerd Font, 256/truecolor, kitty-graphics or sixel for previews) are the strongest single argument for a real terminal emulator. HIGH RISK: repo created 2026-07-28, 42 stars, v0.1.x, 135 total crates.io downloads, in no distro archive — ship opt-in and version-pinned, never as a core component. | MIT |
| ventoy/Ventoy | https://github.com/ventoy/Ventoy | Prepare a stick once, then every future release is a file copy — the only design making a rolling distro's USB story a one-time cost, and the only one a browser can legitimately participate in. Requires exFAT for ISOs over 4 GiB. CAVEATS: its Secure Boot policy is an explicit bypass, and issue #3224 about unexplained binary blobs has been open since 2025-05 with no shipped remediation. | GPL-3.0 |
| raspberrypi/rpi-imager | https://github.com/raspberrypi/rpi-imager | The most rebrandable cross-platform USB writer if you decide to ship one: permissive license, runs on Windows/macOS/Ubuntu, and has a documented `--repo <url>` hook for a custom OS-list manifest (confirmed in src/main.cpp). A fork must strip Heroku telemetry and the Raspberry Pi device filtering. | Apache-2.0 |
| sigstore/cosign | https://github.com/sigstore/cosign | Keyless detached signing for the ISO with no long-lived private key to protect: `cosign sign-blob artifact --bundle artifact.sigstore.json --yes`, signed from GitHub Actions OIDC and logged to Rekor. Closes the gap upstream Rhino leaves open — it publishes only a bare .sha256 next to the ISO on the same host, which is no protection against a compromised mirror. | Apache-2.0 |
| restic/restic and restic/rest-server | https://github.com/restic/rest-server | The backup engine plus its NAS-side companion. rest-server gives append-only mode (a compromised laptop cannot delete history) and clean locking — which a CIFS mount does not. Already packaged as restic-rest-server 0.14.0-1. `--exclude-caches` drops the whole Hugging Face cache for free because huggingface_hub writes CACHEDIR.TAG. | BSD-2-Clause |
| NVIDIA/nvidia-container-toolkit | https://github.com/NVIDIA/nvidia-container-toolkit | GPU passthrough into containers. Version 1.19.0 is already in Ubuntu universe, so the NVIDIA apt repo is not needed for this. Use the upstream repo for the CDI documentation you need to automate `nvidia-ctk cdi generate` on first boot — nvidia-cdi-refresh.path/.service auto-regenerate the spec when modules.dep changes after a driver upgrade. | Apache-2.0 |
| encomjp/razer-control-revived | https://github.com/encomjp/razer-control-revived | Fan RPM, power profiles, CPU/GPU boost, battery charge limit and keyboard RGB on the Blade 15 chassis with NO kernel module and no DKMS (pure USB/HID) plus a CLI — exactly the right shape for a TUI-only distro on a rolling base. ArchWiki now points here instead of the archived rnd-ash/razer-laptop-control. Verify behavior on the actual unit; the explicitly tested model is the 2025 Blade 16. | UNVERIFIED — check LICENSE before vendoring |
| jlumbroso/free-disk-space | https://github.com/jlumbroso/free-disk-space | Reclaims up to ~31 GB on ubuntu-latest in about three minutes. Effectively mandatory as step 1 of the ISO workflow, since GitHub guarantees only 14 GB of free space. A maintained fork exists at HastD/free-disk-space. | MIT |

## COMPLETENESS CRITIC (full)

# COMPLETENESS CRITIQUE — cdl-linux feasibility research

## PART 1 — REQUIREMENTS WITH THIN OR ABSENT COVERAGE

**R1 (providers + API keys collected at setup) — HALF-COVERED, and the missing half is the dangerous half.**
The corpus verified 12 provider endpoints and the env-var name traps. Excellent. But "API keys collected at setup" got *zero* research. Nothing anywhere on:
- **Where keys live at rest.** The synthesis proposes `/etc/cdl-linux/providers.env` — a plaintext file on a laptop that may have no FDE, no screen lock, and autologin. That is the entire security model of the machine and nobody examined it. Unexamined candidates: `systemd-creds encrypt` (TPM-sealed, no external deps, works headless), `pass`/gopass + gpg-agent with a TTY pinentry, `age`/sops, kernel keyrings. Secret Service / gnome-keyring is *unavailable* on a TUI-only system — that alone kills the default assumption most tools make.
- **Secret leakage during install.** If keys are typed into an autoinstall flow, subiquity writes user-data to `/var/log/installer/` on the installed system. If typed into a first-boot script, they land in shell history and journald. Nobody checked either.
- **System-wide vs per-user keys.** `/etc` means every process on the box can read your Anthropic key. `~/.config` means the `ollama` system user and any service unit can't. Unaddressed.
- Key **validation** at setup (a test call per provider), and what the setup flow does when a key is wrong or the network is absent.

**R3 (emacs + croft) — croft is well researched; emacs is essentially unresearched.**
Emacs appears in the corpus exactly three times: the `emacs-nox` package version, the `kkp` package, and cua-mode. Missing entirely:
- **Emacs as an LLM client.** For a distro whose thesis is "LLM-first," gptel / ellama / aidermacs / llm.el got zero coverage. This is the most obvious integration in the whole project and nobody looked.
- Vanilla vs a configured base (Doom/Prelude/none) — never asked, never decided.
- `emacs --daemon` + `emacsclient -t`, which on a single-fullscreen-terminal system is not a nicety, it's how you get more than one Emacs frame. Unmentioned.
- Whether emacs is *the* editor or one of five (helix, neovim, micro, croft are all recommended somewhere). The synthesis ships a keybinding table for all of them without deciding which is default.

**R7 ("easy model installation later") — no concrete answer.**
"Models chosen at install" is well handled (size gate on HF blob API — good catch). "Easy installation later" resolves to `ollama pull`, which is not an answer to "easy." No model-management TUI was identified or evaluated (gollama, oterm's model pane, llama-swap's config UI). Worse, three things are entirely absent:
- **Disk quota / GC.** Nothing stops model pulls from filling the 2TB. No `ollama` prune policy, no HF cache ceiling (`HF_XET_SHARD_CACHE_SIZE_LIMIT` is noted but never wired into a policy), no low-disk warning on a machine with no desktop notifications.
- **A unified model store.** The corpus raises the question ("should Ollama, llama.cpp and HF share one directory?") and the synthesis's decomposition assigns it to nobody.
- Model **integrity/provenance** — pulling multi-GB weights over HTTP with no checksum policy.

**R8 ("modern conveniences") — this is where the biggest omissions hide.** See Part 2; suspend, lid handling, battery, screen lock, console font sizing, external displays, and keymap duplication are all inside this requirement and all missing or dropped.

**R10 ("full apt support") — waved at, not researched.** Concrete unexamined problems:
- Rhino's ISO hook **purges `snapd`** and patches its prerm/postrm to force removal. The synthesis then recommends **subiquity, which ships only as a classic-confinement snap**. That is a direct contradiction inside the recommended plan and it is not flagged.
- Rhino also purges `update-manager`, `update-notifier`, `apport`, `sudo-rs`, and force-reverts uutils coreutils to GNU with `--allow-remove-essential`. So out of the box there is **no security-update mechanism at all**, and an essential-package override that "full apt" users will trip over.
- **Third-party repo pinning.** The plan mixes an Ubuntu base with NVIDIA's `ubuntu2604` repo and Tailscale's `resolute` repo. That needs explicit `/etc/apt/preferences.d` entries or apt will make surprising choices. Nobody wrote them.
- **`unattended-upgrades`: on or off?** Never asked. On a rolling base this is the difference between "wakes up broken" and "never gets security fixes." Directly load-bearing.
- Does "full apt" mean `apt install firefox` must work? On a TUI-only box it will succeed and install a useless binary plus half of X11. Acceptable or not? Nobody asked.
- apt vs Pacstall **conflict surface** — the kernel is the known case, but no general policy exists for "who owns this package."

**R13 (docs with screenshots + tutorials) — the mechanism is well researched; the content and one hard limitation are not.**
- **VHS cannot screenshot the things that most need screenshots.** VHS renders inside its own ttyd pty. It cannot capture the boot sequence, GRUB, the installer, the bare VT, kmscon, or anything outside a pty. Installer walkthroughs need QEMU + framebuffer capture (which is exactly what os-autoinst does) — a *different* tool. The synthesis treats VHS as the whole answer.
- **Screenshot fidelity.** If the shipped session is cage+kitty with Fira Code and a chosen theme, VHS must be configured to match or every published screenshot depicts a system that doesn't exist. The synthesis catches the font half and misses the theme/terminal half.
- **Offline docs.** A TUI-only distro whose documentation lives only on a website is broken exactly when you need it (wifi driver failed, no boot). Nothing about shipping the docs on-disk, or man pages.
- Docs **hosting** and **content plan** (which tutorials, for whom) — unspecified.

---

## PART 2 — UNSTATED-BUT-ESSENTIAL CONCERNS THAT ARE ABSENT

**1. Boot failure recovery — mentioned once in passing, never designed.**
This is the single most important operational concern for a no-GUI, possibly-only machine, and it gets one clause ("ship a `nomodeset` recovery GRUB entry"). Missing:
- **Is the GRUB menu even reachable?** Ubuntu defaults to `GRUB_TIMEOUT_STYLE=hidden` with `GRUB_TIMEOUT=0` on single-OS installs. A user who can't see a menu can't select a recovery entry. This must be explicitly set to `menu` with a nonzero timeout.
- Previous-kernel retention policy, and whether the previous kernel's NVIDIA modules survive (they do for precompiled, they don't necessarily for DKMS).
- **Snapshot rollback from the bootloader** — `grub-btrfs`, Timeshift, or ZFS boot environments. The corpus notes Rhino ships `timeshift` but nothing connects it to a recovery workflow.
- `systemd.unit=rescue.target` / `emergency.target` documented for the user.
- **FDE interaction**: recovery requires typing a passphrase at a console that may be the broken component.
- A rescue image on a second ESP partition, or a permanently-retained Ubuntu live USB.

**2. Swap and hibernation — ZERO coverage anywhere in a 200-fact corpus.**
The word "swap" appears only as `swap-storage` (a CI disk-cleanup flag) and `swapm()` (a keyd action). This is a laptop with 64 GB RAM. Missing:
- **Hibernation requires a swap area ≥ RAM (64 GB)** plus a correct `resume=`/`resume_offset=` and initramfs config. With LVM+LUKS this is a known-fragile setup. Never mentioned.
- NVIDIA hibernate interaction: Ubuntu's shipped `nvidia-graphics-drivers-kms.conf` sets `NVreg_PreserveVideoMemoryAllocations=1` and `NVreg_TemporaryFilePath=/var` — meaning 16 GB of VRAM gets written to `/var` on suspend/hibernate. That has capacity and wear implications nobody costed.
- Rhino's package list includes `zram-config`. zram on a 64 GB machine is at best pointless and at worst harmful. Undiscussed.
- **OOM policy.** Loading a 30 B model with no swap and no `systemd-oomd`/`earlyoom` tuning means the kernel OOM killer picks a victim — possibly your login session, on a machine with no other session to fall back to. This is a *predictable, frequent* failure mode for the primary use case and it is completely unaddressed.

**3. Suspend / lid / battery — the corpus HAS the facts, the synthesis DROPPED them.**
The Razer dimension verified: spurious wake from XHC (`echo XHC > /proc/acpi/wakeup`), infinite suspend loop fixed by `button.lid_init_state=open`, `blacklist i2c_nvidia_gpu`, `acpi_sleep=nonvs`, `NVreg_EnableS0ixPowerManagement=1`, "S3 suspend does not work well… touchpad is super jumpy after resume," and Xid 79 "GPU has fallen off the bus" under runtime PM. **Not one of these appears in the synthesis.** No decomposition step owns power management. Additionally never raised anywhere:
- **Lid-close during a training run.** With no desktop environment, nothing inhibits sleep. `logind`'s `HandleLidSwitch=suspend` will suspend a 6-hour fine-tune. Needs an explicit policy (`HandleLidSwitch=ignore` + `systemd-inhibit` wrappers, or an `IdleAction` decision).
- **Critical-battery handling.** No GUI means no low-battery notification. The machine simply dies mid-write. Needs an `upower`/`acpid` hook or `systemd`'s `CriticalPowerAction`.
- Screen brightness with no DE (`brightnessctl`/`light`) — never mentioned.
- **Fan control.** A verified first-hand report on this exact machine says "I have not been able to do any fan control at all," and the only recommended tool (`razer-control-revived`) has an **unverified license** and is tested on a different model. Sustained CUDA load in a thin chassis with no fan control is a thermal-throttling-or-worse risk, and no question asks whether sustained load is a use case.

**4. Screen locking and autologin — a laptop with API keys and no lock screen.**
Zero occurrences of "lock," "physlock," "vlock," or "swaylock" in the corpus. The recommended cage session and the bare-VT fallback both imply autologin (cage's upstream unit and Ubuntu Server's `agetty --autologin` are both cited approvingly). Combined with plaintext API keys in `/etc`, that means: open the lid, get a root-capable shell with live credentials. No FDE decision has been made either. This is the security posture of the entire product and no one wrote it down.

**5. Reproducible ISO rebuild — absent, and worse than absent.**
Nothing in the corpus or synthesis addresses build reproducibility, and two verified facts make it currently *impossible*:
- Rhino's `terraform.conf` sets `VERSION="$(date +%Y).$RELEASE"` — the version is literally the build date.
- The ISO hook runs `pacstall -QPINs nala-deb firefox-bin … rhino-core …`, which resolves pacscripts from **`pacstall-programs` master HEAD at build time**. That repo was pushed the same day it was surveyed. **There is no lockfile.** Two builds a day apart install different software with the same version string.
- The base suite is a live pre-release archive with a 14-day `Valid-Until`.
- **`snapshot.ubuntu.com` is never mentioned anywhere.** That is the actual mechanism for pinning an Ubuntu archive to a timestamp and it is the missing piece of the "snapshot-rolling" option the synthesis proposes without saying how.
- No per-ISO package manifest, no `SOURCE_DATE_EPOCH`, no pinned pacscript commits.

**6. Upgrade path for an installed system — absent.**
Nothing answers "how does an installed cdl-linux get from 2026.1 to 2026.2 without reinstalling." Specific unaddressed items:
- **There is no cdl-linux package repository in the plan.** The synthesis recommends shipping `cdl-linux-keybindings`, `cdl-linux-fonts`, `cdl-linux-llm-defaults` as removable packages, but no decomposition step creates a PPA, a Pacstall third-party repo, or a self-hosted apt archive to deliver updates to them. Everything downstream of "opinionated defaults are packages" depends on this and it's unowned.
- **The `./devel` suite auto-follows.** `ub2r.sh` rewrites sources to `./devel`, which means an installed machine silently becomes a 27.04-development machine weeks after 26.10 ships in October. That is a scheduled, dated future breakage on any rolling install and nobody flagged it.
- Rhino's own `rhino-hotfix` channel accepts an arbitrary `user/repo` — a ready-made delivery mechanism for cdl-linux fixes that the synthesis lists as an asset but assigns to no plan.

**7. First boot with no network — partially addressed, key failure modes missing.**
The synthesis covers the offline model floor. It does not cover:
- **Ordering.** Wifi must be configured before provisioning, so `nmtui` has to run first — and enterprise wifi may require certs that are not yet on the machine. Chicken-and-egg, unaddressed.
- **Resumability and idempotence.** If the first-boot fetch (torch + CUDA + models, ~3–15 GB) fails halfway, what state is the machine in? Is there an `cdl-linux-setup --resume`? Does it retry? What does the user see while 8 minutes of downloading happens on a console with no progress UI?
- **No decomposition step owns the first-boot provisioning service**, despite nearly every recommendation offloading work to it.

**8. Unattended vs interactive install — the synthesis waffles, and there's a contradiction it misses.**
"API keys collected at setup" and "fully unattended install" are mutually exclusive by definition. Add wifi credentials, a LUKS passphrase, and (under Secure Boot) MOK enrollment, and the install is irreducibly interactive. Nobody states this plainly or asks the user to choose which of setup/first-boot collects what.

**9. Disaster recovery when this is the only machine — the inventory step is not enough.**
The synthesis's step 1 captures hardware facts. It does not address:
- **The USB-writing chapter assumes a second computer exists.** Every recommended path (dd on macOS, Rufus on Windows, Ventoy prep) requires a working non-Tensorbook machine. If this is the only machine, the ISO must be built and written *from the machine being wiped*, before wiping it — and you need a second stick to keep a rescue image.
- Nothing about retaining a known-good Ubuntu live USB permanently.
- Nothing about **where the pre-wipe backup goes**, given that reaching the NAS requires wifi credentials that are about to be destroyed.
- Nothing about writing down on paper, before the wipe: LUKS passphrase, restic repo password, Tailscale auth key, provider API keys.
- **"Do you have a second computer?" is never asked.** It gates this entire concern.

**10. Miscellaneous, each small but each a real day-one bug:**
- **Two keymap systems.** The console uses `loadkeys`/PSF; cage/Wayland uses XKB. A macOS keybinding layer must configure *both* or the rescue console behaves differently from the session. Never flagged.
- **Console font on a 2560×1440 15" panel.** The default VT font will be unreadable. Needs an explicit large PSF (`setfont`) and a kitty `font_size`. Never mentioned.
- **External displays / docking under cage.** Zero coverage. `wlr-randr`/`kanshi` exist; whether cage (a single-output kiosk) handles hotplug at all is unknown and unresearched.
- **NTP/chrony.** A wrong clock breaks TLS to every provider API. Trivial, absent.
- **sshd.** The synthesis's notebook/graphics story assumes "you SSH in from a machine with a good terminal," but nothing specifies whether sshd is enabled, how keys get provisioned at install, or hardening. sshd is also the only remote rescue path for a machine whose display breaks.
- **`fstrim.timer`** on the NVMe — the corpus does the LUKS discard analysis and the synthesis drops the actual periodic trim.
- **`fwupd` / BIOS updates** on a Razer chassis (LVFS coverage is poor; Razer BIOS updates are typically Windows-only). Zero mention.
- **Prompt logging as a privacy/backup artifact.** `llm` (simonw) logs every prompt and response to unencrypted SQLite. On a laptop with no FDE decision, that's a data-at-rest issue *and* a backup include/exclude decision. Unraised.
- **Spend controls.** An LLM-first distro that collects API keys and ships no budget/usage visibility. Not a technical blocker, but a genuine product gap nobody named.
- **First-run experience.** No decomposition step owns what the user sees at first login. Rhino's own `rhino-setup` is GTK (unusable) and `hello-rhino` is a greeter. For this product the first-run experience *is* the product.

---

## PART 3 — CRITICAL QUESTIONS THE SYNTHESIS DOES NOT ASK

1. **"Do you have a second working computer?"** Gates the entire USB-writing plan and the disaster-recovery plan. Never asked.
2. **"Where should API keys be stored, and do you want full-disk encryption?"** Encryption is asked about in the corpus for *performance*; nobody asks about it for *secrets*. These are the same decision.
3. **"Will this laptop suspend, close its lid, and run on battery — or is it a mains-tethered box?"** The corpus asks this. **The synthesis dropped it.** That is a regression, and it determines the entire power/NVIDIA-runtime-PM policy.
4. **"Do you want hibernation?"** Determines whether you carve 64 GB of swap out of the volume, and whether the volume layout can even support it.
5. **"Should the console autologin, and is this single-user?"** Determines the security model and where keys live.
6. **"Should sshd be on by default?"** It is your only remote rescue path.
7. **"Should unattended-upgrades be enabled?"** On a rolling base this is the "wakes up broken" switch.
8. **"How do you expect to update an installed machine — and do you accept that a `./devel` install auto-follows into 27.04 development in October?"**
9. **"Is sustained multi-hour GPU load a use case?"** Fan control on this chassis is reported non-functional. If yes, thermals become a first-class risk.
10. **"What is your time budget?"** The decomposition is 14 sub-projects with three marked high-risk. Nobody asked whether this is a weekend or a quarter.
11. **"Does 'full apt support' mean GUI packages must install successfully?"**
12. **"Do you want the docs to work offline on the machine itself?"**

---

## PART 4 — LOAD-BEARING "UNKNOWN" / "UNVERIFIED" CLAIMS

Ranked by how much a recommendation rests on them.

**A. "I could NOT verify that the classic subiquity snap runs correctly in a non-Ubuntu-Server live session… must be prototyped." (confidence: unknown)**
The synthesis recommends subiquity as installer option A and as the answer to both the TUI-installer and multi-disk-storage conflicts. That recommendation rests entirely on an explicitly unverified assumption, and the synthesis does not label it as such. Compounding it: **Rhino's ISO build actively purges `snapd`**, and subiquity is a classic snap. The plan as written contains a direct collision. This should be the #1 spike before any installer work.

**B. Intel VMD/RST on the Blade 15 2022 BIOS. (unknown)**
If VMD is enabled and cannot be disabled, a stock installer sees **no disks at all** and the entire project stops. The synthesis buries this inside a bullet list in the inventory step. It should be a go/no-go gate checked before anything else is built.

**C. /dev/kvm on GitHub-hosted runners — THE CORPUS CONTRADICTS ITSELF.**
One dimension: "/dev/kvm on GitHub-hosted standard runners is NOT reliably available… I could not verify a current guarantee" (unknown). Another dimension: nested virt "has now shipped :) All Linux runners are now on a SKU that supports nested virtualization" (verified, GitHub staff quote). **The synthesis silently adopted the optimistic one** and built the QEMU install-testing plan on it. Reconcile before planning CI.

**D. NVIDIA 595/610 DKMS building against mainline 7.2. (unknown, with a confirmed 7.1.8 failure adjacent)**
Load-bearing for the kernel decision. The synthesis handles this well by recommending the precompiled/LTS path, but if the user picks rolling, this is untested and there is a known-adjacent failure.

**E. Ventoy booting a Rhino/cdl-linux ISO. (unknown — "needs a physical test")**
Ventoy is the synthesis's *recommended* USB path. Nobody has verified it boots this ISO family, and Ventoy's own docs disclaim hardware coverage. Test before documenting.

**F. Which Razer chassis / which GPU / whether both drives are NVMe. (unknown, sources conflict)**
Correctly routed to the inventory step. Note the sharpest consequence, which the synthesis states but should state louder: **one documented Tensorbook config shipped 1 TB NVMe + 1 TB M.2 SATA.** If true here, striping is actively harmful and the whole "combine into 2 TB" analysis changes.

**G. Panel MUX / Advanced Optimus variant. (likely)**
Determines whether the console comes from i915/simpledrm (safe) or nvidia-drm (three verified fbdev bugs on this kernel generation). Routed to inventory — correct — but it also gates the cage-on-wlroots-with-NVIDIA risk, which is separately marked "likely" and untested.

**H. NVIDIA `ubuntu2604` repo on a 26.10/devel system. ("unsupported-but-likely-working")**
Load-bearing only if the user takes the rolling path. Worth naming explicitly as an *additional* argument for pinning to LTS.

**I. `CONFIG_MD_LINEAR` on Ubuntu 26.x kernels. (likely-off)**
`raidlevel: linear` validates in curtin's schema and then fails at runtime. Correctly flagged; make sure it survives into the storage spec as a hard pre-check.

**J. `razer-control-revived` license. (UNVERIFIED)**
It is in the vendor list as the recommended fan/power tool. If it is not redistributable, the thermal story has no tool at all.

**K. Nerd Fonts patched-FiraCode ligature status. (likely)**
Routed around via the fontconfig-fallback design — good. But see the suite conflict below.

---

## PART 5 — INTERNAL INCONSISTENCIES IN THE SYNTHESIS

1. **"Pin to 26.04 LTS" silently downgrades or deletes recommended components.** The corpus shows `fonts-nerd-symbols` exists **only in stonking** (not resolute), and `chawan` **only in stonking**. Pinning to LTS therefore (a) breaks the recommended ligatures-plus-icons fontconfig design, forcing you to vendor Symbols Nerd Font yourself, and (b) removes the recommended modern text browser. It also downgrades cage (0.2.1 vs 0.3.1), kitty (0.45 vs 0.47), and foot (1.25 vs 1.27). **This cost is never mentioned** in the tension that recommends LTS.

2. **snapd purge vs subiquity snap** — described in Part 4A. Two top-line recommendations that cannot both hold.

3. **The `cdl-linux-*` opinion packages have no delivery mechanism.** Recommended in the philosophy section, absent from the decomposition.

4. **The first-boot provisioning service** is the load-bearing dependency of four separate recommendations and is not a named sub-project.

5. **Power management** appears in the corpus with a dozen verified Razer-specific facts and appears in the synthesis **zero times**. No decomposition step, no tension, no question.

6. Minor: one corpus dimension claims Rhino 2026.1 is "based on Ubuntu 26.04 LTS" (from news coverage, confidence *likely*) while the authoritative dimension proves it tracks `devel`/stonking. The synthesis uses the correct one, but the contradiction should be marked so a future reader doesn't re-litigate it.

---

## PART 6 — SUGGESTED ADDITIONS TO THE DECOMPOSITION

- **Sub-project: Secrets and identity.** FDE decision, key storage mechanism, autologin/lock policy, sshd policy, restic repo password, Tailscale auth key. Depends on the storage decision, blocks the LLM tooling layer.
- **Sub-project: Power, thermals and suspend.** Owns the verified Razer workarounds, lid/inhibit policy for long jobs, critical-battery action, fan control, nvidia runtime-PM vs Xid 79. Depends on hardware inventory.
- **Sub-project: Boot recovery and rollback.** GRUB menu visibility, previous-kernel policy, snapshot rollback, rescue partition/USB, documented emergency-target path. Should gate first install, not follow it.
- **Sub-project: Swap, hibernation and OOM policy.** Depends on the storage layout; blocks it, actually, since 64 GB of swap has to be carved before the volume is created.
- **Sub-project: cdl-linux package repository and update channel.** Blocks every "shipped as a removable package" recommendation.
- **Sub-project: First-boot provisioning service.** Named, with resumability, no-network behavior, and progress UX as explicit requirements.
- **Add to inventory step, as a hard go/no-go before anything else:** BIOS VMD/RST state.
- **Add as spike zero:** does subiquity run in a non-Ubuntu-Server live session, and can it coexist with Rhino's snapd removal?
