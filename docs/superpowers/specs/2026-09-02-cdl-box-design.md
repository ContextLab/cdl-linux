# `cdl-box` - a headless model and agent workstation

**Status:** draft 1, for review.
**Supersedes:** everything in `docs/archive/` (see that directory's README for what was
retired and why).
**Hardware facts:** `notes/hardware/tensorbook-profile.md`, which stays live. Every number
below that describes this machine was measured there, not assumed.

## 1. What this is

A minimal Ubuntu Server install on the Tensorbook that runs continuously, is reached over
SSH, and does three jobs:

1. **Runs coding agents** (Claude Code, Codex, Gemini, OpenCode) in terminal sessions that
   survive disconnection.
2. **Serves local models** to the machine itself and to other devices on the tailnet.
3. **Trains and fine-tunes models** on the RTX 3080, with a working CUDA and PyTorch stack.

The interface is a terminal you SSH into, plus a small web dashboard for the things a
terminal is bad at answering (§8).

### 1.1 The machine is headless, and that decision does most of the work

No compositor, no display manager, no session lock, no autologin, no keybindings, no X or
Wayland. The internal panel shows a console login and nothing else.

This comes first because it is what makes the rest small. A previous design
carried a display session, and with it a locking problem that had no clean solution (the
kiosk compositor under consideration ships no session-lock protocol at all), plus
autologin, plus a compositor crash-recovery path. None of that exists here.

**Hibernation is out of scope for the same reason.** An always-on server does not
hibernate, so the Secure Boot and kernel-lockdown conflict recorded in the hardware profile
stops being a blocker and becomes an observation. Secure Boot stays **on**.

### 1.2 What this is not

- **Not an agent orchestration system.** Agents run in `zellij` sessions and a human
  decides what to run. The archived design describes the orchestration layer; it may get
  built later, on top of this, and this does not depend on it.
- **Not a custom ISO.** §3.
- **Not multi-user.** One person, one machine, one tailnet.
- **Not a general-purpose desktop.**

## 2. Base system

| Choice | Value | Why |
|-|-|-|
| Distribution | **Ubuntu Server 26.04 LTS** | Signed NVIDIA modules under Secure Boot; five years of updates; the CUDA path is well-trodden |
| Install | Stock installer, minimal, **no** `ubuntu-desktop` | Nothing needs a display |
| Kernel | Stock HWE | The AX210 wifi is on in-kernel `iwlwifi`, so no firmware package is needed (measured) |
| Secure Boot | **On** | Signed NVIDIA modules load; nothing here needs hibernation |
| Swap | 8 GiB file | Sized for pressure relief, not for hibernation |

### 2.1 Storage: one striped 2 TB volume

The machine has two identical 1 TB NVMe drives, both healthy (`PASSED`, zero media errors,
100 % spare, 2 % and 0 % endurance used). **They are striped into one ~2 TB volume**, which
is the user's decision, taken against a recommendation to mount them separately.

The stack, bottom to top:

```
nvme0n1 + nvme1n1  ->  md0 (RAID0)  ->  LUKS  ->  btrfs
                                                    @        -> /
                                                    @home    -> /home
                                                    @models  -> /srv/models
```

One `md` device means one LUKS container and one passphrase at boot. btrfs subvolumes then
give the separation that separate mounts would have given, plus snapshots, without a second
unlock. There is deliberately **no remote unlock**: an unattended reboot parks at the prompt
rather than putting a credential on unencrypted `/boot`.

**What striping costs, recorded once so the trade is visible rather than argued.** Either
drive failing destroys the volume, and the two drives are unequally worn (48 TB
written on `nvme0n1` against 5.5 TB on `nvme1n1`), so the volume's life is governed by the
more heavily used one. Two consequences follow and both are requirements rather than advice:

- **SMART on both drives is monitored, and a warning is surfaced on the dashboard** (§8.1).
  On a striped pair, the first sign of trouble on either device is the only warning there
  will be.
- **The backup becomes the only copy**, which lands awkwardly against
  §10.1: the NAS runs no containers, so backups have no append-only protection yet. Until
  the snapshot substitute in §10.1 is confirmed, this machine has **no redundancy and no
  protected backup at the same time.** That is an exposure, it is stated here rather than
  in a footnote, and confirming NAS snapshots is the cheapest thing that closes it.

**A considered alternative, rejected for a practical reason.** Two LUKS devices with btrfs
spanning both (`-d raid0 -m raid1`) would stripe data while mirroring metadata, so a
single-device failure would leave a mountable filesystem that can at least enumerate what
was lost. The Ubuntu installer cannot produce that layout, and building it by hand
contradicts §3's stock-installer premise. It should be revisited if the storage layout is ever
rebuilt outside the installer.

### 2.2 Two hardware findings that need OS-level fixes

Both came out of the firmware walk and neither has a firmware setting to fix it.

- **XHCI wake is armed at S3**, which is what this machine suspends to, and is the leading
  explanation for 65 and 66 unsafe shutdowns across 255 and 206 power-on hours.
  `/proc/acpi/wakeup` resets every boot, so a `systemd` unit must disable it at every
  start. Since the box is always on, suspend is also disabled outright
  (`systemd-sleep` masked), which addresses the same failure from the other side.
- **`bolt`/`boltctl` is a hard dependency.** The firmware exposes no Thunderbolt security
  policy at all, so if `boltd` is missing after a reinstall the dock cannot be authorised
  and no firmware setting can rescue it.

### 2.3 Thermal policy

There is **no fan control on this machine**, in firmware or in the OS (0 fan inputs, 0
writable PWM, measured). The only levers are `intel_pstate`'s `no_turbo` and
`max_perf_pct`, both confirmed writable, plus refusing to start work.

A `cdl-thermal` unit samples package and GPU temperature and steps `max_perf_pct` down
when a threshold is crossed. This is a **best-effort comfort measure, not a safety
mechanism**: the hardware throttles itself regardless, and this exists to make sustained
inference less thermally punishing, and to spin the fans up less often, rather than to prevent
damage.

## 3. Provisioning: a script, not an image

**Everything below is installed by a re-runnable script**, not baked into a custom ISO.
`scripts/provision/` holds numbered, idempotent modules (`10-base.sh`, `20-nvidia.sh`,
`30-agents.sh`, and so on) driven by one entry point.

The requirement that matters: **running it twice changes nothing the second time**, and
running it on a fresh install of the same Ubuntu version reproduces the machine. That is
the reproducibility a remix ISO was going to buy, at a small fraction of the cost, and it
is testable in a VM on every change.

An ISO stays possible later. It is not a prerequisite for finding out whether the machine
is pleasant to use, which is the actual open question.

## 4. Agent CLIs

Four, behind a thin wrapper that supplies each one's environment per process:

| CLI | Licence | How it is installed |
|-|-|-|
| `openai/codex` | Apache-2.0 | Pinned release binary |
| `sst/opencode` | MIT | Pinned release binary |
| `google-gemini/gemini-cli` | Apache-2.0 | Pinned release binary |
| `anthropics/claude-code` | **none** | **Vendor installer, fetched on demand.** The repository carries no licence field (verified via `gh api`), so it cannot be redistributed |

### 4.1 Credentials are built per process, never set globally

This is the one rule carried forward from the archived design without change, because it
came from measured behaviour rather than preference.

Claude Code's Remote Control (phone steering) **refuses to run when `ANTHROPIC_BASE_URL`
points anywhere but `api.anthropic.com`**, and `DISABLE_TELEMETRY`, `DO_NOT_TRACK`,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` and `DISABLE_GROWTHBOOK` each disable it
outright. The obvious design (one local gateway, privacy variables on by default, set in
`/etc/environment`) would therefore silently remove a capability you are paying for.

So: keys live in a keystore at `~/.config/cdl/keys` (mode 0600), and a launcher exports
only what that agent needs, only into that process. Nothing goes into a shell profile or
`/etc/environment`. Both spellings of the divergent provider variables are set where a
provider needs it (`TOGETHER_API_KEY` and `TOGETHERAI_API_KEY`; `FIREWORKS_API_KEY` and
`FIREWORKS_AI_API_KEY`; `OPENROUTER_API_KEY` and `OR_API_KEY`).

### 4.2 Sessions

Agents run inside `zellij`, which survives disconnection and is what you reattach to over
SSH. There is no custom supervisor. If a session needs to outlive a logout, `linger` is
enabled for the user.

This is the deliberate simplification against the archived design, and it costs
something: `zellij` holds scrollback in memory, so the record of a session dies with it.
§8's dashboard partly compensates by recording what was started and when, and a per-session
`script(1)` log is available for anything that needs to be kept.

## 5. Local model serving

### 5.1 One endpoint

Two servers, one stable address:

- **Ollama** for everyday use: a good catalogue, one-command pulls, and an OpenAI-compatible
  API. This is the default.
- **`llama.cpp`'s `llama-server` behind `llama-swap`** for cases Ollama does not cover.
  `llama-server` uniquely serves OpenAI chat-completions, OpenAI Responses **and** Anthropic
  Messages from one binary, which is what lets all four agent CLIs point at a local model.
  Codex in particular accepts only `wire_api="responses"` for custom providers.

Both are `systemd` units. Models live under `/srv/models` with a shared cache, so a model
pulled once is not downloaded again by the other server.

### 5.2 LM Studio is out

**Decided 2026-09-02, on documentation rather than preference.** The desktop app's headless
mode *"works on Mac, Windows, and Linux machines with a graphical user interface"*, so it
cannot run on this box at all. Its server-native daemon (`llmster`, *"the core of the LM
Studio desktop app, packaged to be server-native, without reliance on the GUI"*) does run
headless, but it installs by `curl -fsSL https://lmstudio.ai/install.sh | bash` with no
licence stated, so it cannot be part of a provisioned image.

The value LM Studio adds over Ollama is its catalogue and its GUI, and the GUI is exactly
the part that does not come to a headless box. It is documented in the runbook as a
one-line optional install for anyone who wants it, and nothing depends on it.

### 5.3 VRAM is the binding constraint

16 GB, measured. That fits one large model or one large plus one small, which is what
`llama-swap` exists to manage. A `flock` semaphore guards the GPU so a training run and a
serving model do not both claim it and fail confusingly.

## 6. Training and fine-tuning

The stack, installed by `20-nvidia.sh` and `40-ml.sh`:

- NVIDIA driver from the Ubuntu archive (signed, loads under Secure Boot), CUDA toolkit,
  and `nvidia-smi` working as the acceptance check.
- PyTorch with CUDA, `transformers`, `datasets`, `peft`, `accelerate`, `bitsandbytes`.
- **`uv` for every environment**, so packages hardlink from one shared cache instead of
  being copied per project.
- Jupyter available but bound to localhost, reached by SSH port-forward rather than exposed.

16 GB of VRAM sets the realistic ceiling: LoRA and QLoRA fine-tunes of 7B-class models, not
full fine-tunes of large ones. The spec says so plainly so that nobody plans around
capacity the card does not have.

## 7. Remote access

- **Tailscale** for reachability, so the box is available from a laptop or phone without
  port-forwarding or a public address.
- **OpenSSH**, key-only, password authentication off, bound to the tailnet and the LAN.
- **`mosh`** for sessions over poor links, which matters more than it sounds when the
  alternative is a dropped agent session.
- **The model endpoint is served on the tailnet**, so other devices use this machine's GPU
  by pointing at one URL. It binds to the tailnet interface, never `0.0.0.0`.

There is no remote LUKS unlock (§2.1). An unattended reboot parks at the passphrase prompt
and needs someone at the keyboard, which is accepted deliberately.

## 8. The web dashboard

A terminal is bad at ambient questions. `cdl status` answers "what is running?" only when
you remember to run it, and a machine you are not sitting at cannot page you at all.

**`cdl-dash` is a small read-mostly web page served from the box, bound to the tailnet.**
It exists so that the state of the machine is glanceable from a phone.

### 8.1 What it shows

| Panel | Content |
|-|-|
| **GPU** | VRAM used and free, utilisation, temperature, and which model is resident |
| **Model servers** | Ollama and `llama-swap` up or down, loaded model, requests served |
| **Sessions** | `zellij` sessions, when each was started, and which agent CLI is running in it |
| **Machine** | CPU temperature, `max_perf_pct` (so throttling is visible rather than mysterious), load, memory, disk free on both mounts |
| **Storage** | Volume usage, largest models, last backup time and result, and **SMART status for both drives** (§2.1: on a striped pair this is the only early warning) |

### 8.2 What it can do

Deliberately little, because every action is a way to break something from a phone:

- Load or unload a model.
- Stop a `zellij` session.
- Nothing else. No shell, no file access, no editing.

### 8.3 How it is built and secured

A single Python service (FastAPI) under `systemd`, serving one page that polls a JSON
endpoint. No build step, no framework, no database: it reads `nvidia-smi`, the model
servers' own APIs, `zellij list-sessions` and `df`, and caches for a second.

**Authentication is Tailscale's.** The service binds to the tailnet interface only and
trusts `tailscale whois` for identity. It has no password of its own, because a hand-rolled
login on a single-user box is a liability rather than a control. If it cannot resolve a
caller's tailnet identity, it refuses the request.

**It is read-mostly by design.** The two write actions are idempotent and reversible from
the terminal. Anything that could destroy work belongs in SSH, where the friction is
appropriate.

## 9. Terminal environment

The part that decides whether this is pleasant to use daily.

- **Shell**: `zsh`, with a prompt showing host, path, git branch and GPU state, so a
  reattached session says what machine it is on.
- **Multiplexer**: `zellij`, with a layout for agent work.
- **Editor**: Emacs, plus one LLM integration.
- **Colours**: one palette across the shell prompt, `zellij`, `bat`, `eza`, `delta` and
  Emacs, checked for contrast at the terminal level rather than assumed. The panel is on
  the Intel iGPU (measured), so console rescue works without the NVIDIA driver.
- **Tools**: `git`, `gh`, `rg`, `fd`, `jq`, `htop`, `nvtop`, `restic`, `croft`.

Theming for the shell side is configured on the box, and the client terminal's own configuration
(fonts, window) stays on the client, where it belongs.

## 10. Backup

**`restic` over SFTP** to the NAS, on a timer, with `--exclude-caches` and `CACHEDIR.TAG`
honoured. `restic -r sftp:user@nas:/path` needs only `sshd` on the far end and no software
installed there, which is what makes it the right transport here.

### 10.1 The NAS runs no containers, so append-only has to come from the storage layer

**Decided 2026-09-02.** The archived design's primary choice was `restic` talking to
`rest-server --append-only` in a container on the NAS, which closed threat T5 (a stolen
backup credential) on the strength of rest-server's own guarantee: it *"allows creation of
new backups but prevents deletion and modification of existing backups"*. The NAS does not
run containers, so that option is gone and **T5 is not closed by the backup transport any
more**.

This is a genuine loss and the spec says so rather than substituting a weaker claim. Over
SFTP the laptop's key has full write access to the repository path. Anyone who takes the
machine can run `restic forget --prune`, or simply delete the files, and the history goes
with it. Encryption does not help: the repository password is on the laptop by necessity.

**The substitute is NAS-side snapshots**, which give the same property from underneath
instead of from the protocol. A scheduled snapshot of the backup dataset cannot be deleted
by a client that has no administrative access to the NAS, so a wiped repository is
recoverable from the most recent snapshot. Conceptually, the storage layer becomes the
append-only layer.

Two conditions have to hold for that to work, and neither is assumed:

- The NAS must actually be snapshotting the dataset that holds the repository, on a schedule,
  with a retention window longer than the gap between backup checks. If it is not, T5 is
  simply open and should be recorded as open.
- The laptop's SSH credential must not be able to reach the snapshots. In practice this
  means a dedicated unprivileged user, chrooted to the repository path via
  `ForceCommand internal-sftp`, and no NAS administrative access from that account.

**Retention pruning now runs from the laptop**, because there is no NAS-side component to
run it. That is the direct consequence of the same change: the machine being backed up is
also the machine that deletes old snapshots, which is exactly the arrangement rest-server
existed to avoid.

- `/home` and `/etc` are backed up.
- **`/srv/models` is not**, by default. Model weights are large and re-downloadable, and
  backing up 200 GB of files that a `pull` command restores is a poor trade. Checkpoints
  and datasets that are *not* re-downloadable live in `/srv/models/keep`, which **is**
  backed up.
- A restore drill is part of the acceptance criteria, not a later exercise. A backup nobody
  has restored from is a hypothesis.
- **The snapshot path is drilled too**, once: delete something from the repository
  deliberately, then recover it from a NAS snapshot. That is the only way to find out
  whether §10.1's substitute works before it is needed.

## 11. Build order

Each milestone has an exit test, not a judgement.

| # | Milestone | Exit test |
|-|-|-|
| **B1** | Base install, headless, SSH, Tailscale | Reboot; reachable over the tailnet by name without touching the machine, and `wakeup` shows XHCI disabled |
| **B2** | NVIDIA, CUDA, PyTorch | `nvidia-smi` reports the 3080, and `torch.cuda.is_available()` returns true after a reboot |
| **B3** | Model serving | A model answers on the endpoint from **another device** on the tailnet |
| **B4** | Agent CLIs | All four launch, authenticate, and run a trivial task; Claude Code's phone steering still works, which is what §4.1 protects |
| **B5** | Terminal environment | A day of real work in it, which is a judgement and is marked as one |
| **B6** | Dashboard | The panels in §8.1 are correct against the machine's real state, checked from a phone |
| **B7** | Backup | Restore `/home` to a scratch directory and diff it |
| **B8** | Provisioning is reproducible | The script runs clean on a fresh VM, then runs again and changes nothing |

**B1 to B4 is the machine you can actually work on.** Everything after that improves it.

## 12. Open questions

| # | Question | Why it is open |
|-|-|-|
| 1 | Which GPU drives the dock's external display | Deferred from M0, and it only matters if a monitor is ever attached to this box. On a headless server it may never need answering. |
| 2 | Whether `croft` and the Emacs LLM integration are still wanted | Both came from the original requirements list, which predates the headless decision. |
| 3 | **Does the NAS snapshot the backup dataset, and can the laptop's credential reach those snapshots?** | Answered in part: the NAS runs no containers, so `rest-server --append-only` is out and transport is SFTP (§10.1). What is still open is whether the snapshot substitute exists. If the answer is no, threat T5 is open rather than mitigated, and the honest move is to record it as open instead of describing the backup as protected. Check before B7. |
| 4 | Whether `zellij` scrollback loss is tolerable in practice | If it is not, the answer is per-session `script(1)` logging rather than the archived supervisor design. |
