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

A `cdl-thermal` unit samples package and GPU temperature and steps `max_perf_pct` down when
a threshold is crossed. This is a **best-effort comfort measure, not a safety mechanism**:
the hardware throttles itself regardless, and this exists to make sustained inference less
thermally punishing, and to spin the fans up less often, rather than to prevent damage.

The parameters, so the unit is buildable rather than gestured at. All are configurable and
these are the starting values:

| Parameter | Value |
|-|-|
| Sample interval | 5 s |
| Step down | Package ≥ 90 °C: `max_perf_pct` −10, floor 40 |
| Step up | Package ≤ 75 °C **for 60 s continuously**: `max_perf_pct` +10, ceiling 100 |
| Hysteresis | The 15 °C gap between those thresholds, plus the 60 s dwell, which is what stops it oscillating once a minute |
| Recovery | On unit stop or failure, `max_perf_pct` is restored to 100. A dead thermal daemon must not leave the machine throttled silently |
| `no_turbo` | Set only if stepping reaches the floor and the package is still ≥ 90 °C |

**"Refusing to start work" applies to exactly one thing: `cdl-thermal` publishes a gate that
the model-server wrapper reads before loading a new model.** It does not stop training runs,
does not kill anything already running, and does not touch agent sessions. A person who
starts a long job on a hot machine is making a choice, and this is not the component that
overrules it.

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

So: keys live in a **permissions-protected credentials file** at `~/.config/cdl/keys`,
mode 0600, owned by the user. It is **not** a keystore and is not encrypted at rest; anything
that can read the user's files can read it, and the boundary is file permissions plus
LUKS while the machine is off, which is less than the word keystore implies. A launcher exports
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

**Persistent session logging is therefore on by default**, not opt-in. Agent sessions launch
under `script(1)`, appending to `~/.local/state/cdl/sessions/<name>-<date>.log` at mode 0600.
Losing the only transcript of what an agent did, at the moment the session exits, is the
kind of loss that is invisible until it matters and then cannot be repaired. Logs rotate by
size and age on the same policy as §11.1, and `--no-log` opts out per session.

## 5. Local model serving

### 5.1 Ollama is the endpoint; llama-swap is a second, separate one

Draft 1 said "two servers, one stable address" without saying what did the addressing.
There is **no reverse proxy and no unified router**, because inventing one is work with no
payoff at this scale. Instead:

| Service | Port | Bind | Role |
|-|-|-|-|
| **Ollama** | `11434` | tailnet + localhost | **The endpoint.** Everything points here by default, including other devices |
| `llama-swap` → `llama-server` | `8081` | localhost only | The escape hatch, for models or APIs Ollama does not serve |

**Model selection is by server, not by a routing rule.** A client picks Ollama's port and
names an Ollama model, or picks llama-swap's port and names one of its configured models.
Nothing translates between them, and nothing guesses. That is a deliberately dull design:
one address for the common case, a second address when you need the other thing.

**Guaranteed API: OpenAI chat-completions, on Ollama, at `11434`.** That is what other
devices and every agent CLI can rely on. `llama-server` additionally serves OpenAI Responses
and Anthropic Messages, which is why it exists at all, since Codex accepts only
`wire_api="responses"` for custom providers. Those two are available on `8081` and are
**not** promised on the main endpoint.

### 5.2 Model storage is not shared, and draft 1 was wrong to imply it

Draft 1 claimed a model pulled once would not be downloaded again by the other server. That
is **not true and should not have been asserted**. Ollama keeps content-addressed blobs
under its own directory with manifests; `llama-server` wants a GGUF file path. They are not
interchangeable without work.

Both trees live under `/srv/models` (`/srv/models/ollama`, `/srv/models/gguf`) so they share
a **disk location**, which is all the sharing this spec claims. Whether a single copy can
serve both is **spike S3** (§11): find whether an Ollama blob can be handed to
`llama-server` directly, for the exact versions and quantisations in use. Until that spike
passes, assume a model wanted by both servers is stored twice.

### 5.3 VRAM, and what happens when training holds the GPU

16 GB, measured. That fits one large model, or one large plus one small, which is what
`llama-swap` exists to manage.

**The GPU lock is a contract, and it only works if every entry point honours it** (§6.1).
When a training run holds the lock:

- `llama-swap` **refuses to load a new model** and returns an error naming the holder. It
  does not queue, because a queued inference request that arrives an hour later is worse
  than a refusal.
- **An already-resident model keeps serving.** Eviction on lock acquisition would make
  training silently break inference, and the person training is usually the person serving.
- Ollama is started under the same wrapper and behaves the same way.

This is cooperative, not enforced. Anything that runs `python train.py` directly, without
the wrapper, will take VRAM and the lock will not stop it.

## 6. Training and fine-tuning

The stack, installed by `20-nvidia.sh` and `40-ml.sh`:

- NVIDIA driver from the Ubuntu archive (signed, loads under Secure Boot), CUDA toolkit,
  and `nvidia-smi` working as the acceptance check.
- PyTorch with CUDA, `transformers`, `datasets`, `peft`, `accelerate`, `bitsandbytes`.
- **`uv` for every environment**, so packages hardlink from one shared cache instead of
  being copied per project.
- **`hf-mount` for read-only access to Hub repos**, which is where mounting genuinely fits:
  its README names *"Loading models and datasets without downloading the full repo"* and
  *"Environments where disk space is limited"* as what it is best for. A large evaluation
  dataset can be read lazily from `hf://` instead of occupying part of a 2 TB volume shared
  with checkpoints. Read-only, and never in the backup path (§10.4).
- Jupyter available but bound to localhost, reached by SSH port-forward rather than exposed.

16 GB of VRAM sets the realistic ceiling: LoRA and QLoRA fine-tunes of 7B-class models, not
full fine-tunes of large ones. The spec says so plainly so that nobody plans around capacity
the card does not have.

### 6.1 The GPU lock contract

A `flock` only works if every entry point takes it, so the contract has to be written down
rather than assumed:

| Element | Value |
|-|-|
| Lock file | `/run/cdl/gpu.lock`, created by a `tmpfiles.d` rule, mode 0664, group `cdl` |
| Who takes it | `cdl-gpu <command>`, a wrapper that acquires the lock and `exec`s. **Ollama, `llama-swap` and every training entry point start under it** |
| Mode | Exclusive for training; shared for inference servers, so two servers can coexist while a training run excludes both |
| Timeout | Training waits up to 30 s then fails with the holder named. Inference does not wait at all: it refuses immediately (§5.3) |
| Holder identity | The wrapper writes pid, command and start time into the lock file, so a refusal can say what is holding it rather than only that something is |
| Release | `flock` releases on process exit, including a crash, so a killed job cannot strand the GPU |

**This is cooperative and the spec does not pretend otherwise.** A bare `python train.py`
takes VRAM and honours nothing. The wrapper is made the path of least resistance (it is what
the shell aliases and the systemd units call), which is the only enforcement available
without a container or cgroup device policy, and neither earns its cost here.

## 7. Remote access

- **Tailscale** for reachability, so the box is available from a laptop or phone without
  port-forwarding or a public address.
- **OpenSSH**, key-only, password authentication off, bound to the tailnet and the LAN.
- **`mosh`** for sessions over poor links, which matters more than it sounds when the
  alternative is a dropped agent session.
- **The model endpoint is served on the tailnet**, so other devices use this machine's GPU
  by pointing at one URL. It binds to the tailnet interface, never `0.0.0.0`.

### 7.1 A reboot takes the machine offline until someone visits it

There is no remote LUKS unlock (§2.1), and with the machine in an office rather than at
hand, that is the sharpest trade in this design. **A reboot from any cause parks at the
passphrase prompt and the machine stays unreachable until a person types it.** Causes
include a power cut, an automatic kernel update, and `reboot` typed over SSH by someone who
forgot.

The operator has to be able to tell that state apart from a machine that has crashed, so:

- **Reboots are never automatic.** `/var/run/reboot-required` is reported on the dashboard
  and by a login notice; nothing acts on it (§11.2).
- **`cdl reboot` warns before it does anything**, naming the consequence, and requires
  confirmation. A plain `reboot` still works, because making it not work would be worse.
- **The expected offline state is documented behaviour, not an incident.** Tailscale shows
  the node offline and the dashboard is unreachable, which looks identical to a hardware
  fault from outside. Anyone diagnosing it should check the reboot notice first.
- A UPS would convert the commonest cause (a brief power cut) from a trip to the office
  into nothing at all. Out of scope here, noted because it is the
  cheapest fix for the biggest annoyance this decision creates.

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
| **Machine** | CPU temperature, `max_perf_pct` (so throttling is visible rather than mysterious), load, memory |
| **Storage** | **One figure for free space, not one per subvolume.** `@`, `@home` and `@models` share a single btrfs allocation pool, so per-subvolume `df` output implies an isolation that does not exist and would read as three separate budgets. Also: largest models, last backup time and result, and **SMART status for both drives** (§2.1: on a striped pair this is the only early warning) |

### 8.2 What it can do: nothing, in v1

**The dashboard is read-only.** Draft 1 offered two actions and justified them as
"idempotent and reversible from the terminal", which was wrong about one of them: stopping a
`zellij` session can destroy unsaved work in an editor or an agent mid-task, and no amount
of terminal access undoes that. A control that can lose work does not belong behind a phone
screen in v1.

Controls get added later, one at a time, when terminal use has shown which are actually
wanted. Whichever come first must define graceful-versus-forced behaviour explicitly and
require a deliberate confirmation. Model load and unload is the likely first candidate,
because it genuinely cannot lose anything.

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

There is no NAS. The machine goes in an office, and the striped array has no redundancy, so
this section is the only thing standing between a drive failure and total loss.

### 10.1 Destination: a Hugging Face Storage Bucket

**Decided 2026-09-02, on documentation.** HF Storage Buckets are S3-compatible object
storage on the Xet backend, reached through a gateway at `https://s3.hf.co/<namespace>`, and
the Hub's own documentation states this use case: *"Buckets are well-suited for maintaining
rolling backups."* Unlike a Git-backed dataset repo, buckets are not versioned, so deleting
old data actually reclaims it rather than accumulating history.

`restic` speaks S3, so the repository is `s3:https://s3.hf.co/<namespace>/<bucket>`.
Credentials come from an HF access token via **Generate S3 credentials**, producing an
`HFAK…` key ID and a secret shown once. The client settings the gateway requires:

| Setting | Value | Why |
|-|-|-|
| `region` | `us-east-1` | Required; the gateway is single-region |
| addressing style | `path` | Buckets are path segments, not subdomains |
| list version | **`ListObjectsV2` only** | *"`ListObjectsV1` is not supported"* |
| checksum calculation / validation | `when_required` | Recent clients send trailing CRC32 framing the gateway does not parse |

**Capacity is not a constraint here.** The account is on the free tier (100 GB private), and
`contextlab` carries an Academia plan with substantially more. `/srv/models` is excluded
(§10.3), so the repository holds `/home` and `/etc`, which is tens of gigabytes.

### 10.2 What this destination does not give us, stated plainly

**It gives no protection against deletion, and that is worse than the QNAP plan it
replaces.** The Hub's own words: *"Since buckets are non-versioned, deletions are immediate
and permanent — there is no way to recover a deleted file."* The S3 gateway confirms it from
the other direction: *"object versioning, lifecycle rules"* are among the *"unsupported
features"*.

So **threat T5 is open**. Anyone who takes the machine, or any process that runs as the user,
holds a write-capable token and can erase the backup history in one command. The
repository password does not help, since it sits on the box by necessity.

**The mitigation is a second copy the box cannot reach**, and it is required rather than
advisory given RAID0:

- A separate trusted machine (a laptop, not this box) periodically pulls the bucket with
  `rclone copy` (never `sync`, which propagates deletions) to local storage.
- That machine holds its own token. **The box's token is never present on it**, and the box
  has no credential for the second copy.
- The pull runs on a schedule long enough to notice a wipe before it propagates, which is
  the reason for `copy` over `sync`: it never deletes at the destination, so a bucket erased on Monday is
  still present in the second copy on Tuesday.

Fine-grained HF tokens can be scoped to a single bucket, which limits blast radius without
preventing deletion inside that scope. Use one; it is free and it bounds the damage.

### 10.3 What is backed up

- `/home` and `/etc`, with `--exclude-caches` so `CACHEDIR.TAG` directories drop out. The
  Hugging Face cache writes that tag, so the model cache is excluded for free.
- **`/srv/models` is not backed up.** Weights are re-downloadable and large. Checkpoints and
  datasets that are *not* re-downloadable live in `/srv/models/keep`, which **is** backed up.
- Restore drills are in B0 and B7 (§11), not deferred. A backup nobody has restored from is
  a hypothesis.

### 10.4 Mounting the bucket as a drive: considered, rejected

**The idea:** mount the bucket with `hf-mount` and point a backup application at it, to get
versioned backups. Rejected for two reasons, the first of which matters more.

**Versioning is not the missing piece.** `restic` already stores versioned snapshots and can
restore any of them; §10.2's gap is not versioning but **immutability**. A mounted bucket is
writable by whatever mounted it, so anything that can write a backup can also delete every
backup, exactly as with the S3 path. Changing the transport does not change who can delete,
and no backup application can add a guarantee the storage underneath it does not provide.

**Mounting also makes the transport worse.** `hf-mount`'s own README lists it as **not for**
*"General-purpose networked filesystem (no multi-writer support, no cross-node file
locking)"* and not for *"Workloads that need strong consistency (files can be stale for up
to 10 s)"*. A repository needs consistent reads of its index and lock files, so this is the
trap the round-1 research already recorded: `restic` has no native network-filesystem
backend, and pointing its local backend at one runs its lock protocol over semantics its
documentation never addresses. Borg's FAQ says the same thing more bluntly, advising against
network filesystems for repository storage.

`restic`'s S3 backend speaks the object API directly and needs no POSIX semantics over the
network, which makes it the better path rather than the fallback. **The second copy in
§10.2 stays the answer to deletion**, because immutability has to come from a place the box
cannot reach, not from a different way of reaching the same place.

### 10.5 One spike before this is relied on

**Does `restic` work against the HF S3 gateway?** The gateway supports only
`ListObjectsV2`, does not store `x-amz-meta-*`, restricts object key shapes, and redirects
`GetObject` to a CDN edge for clients it does not recognise. `restic` uses `minio-go`, which
none of that obviously breaks, but none of it is confirmed either. The spike is small: create
a bucket, `restic init`, back up a directory, `restic check --read-data`, restore, and diff.
Until that passes, the backup destination is a plan rather than a mechanism.

## 11. Updates, logs and maintenance

Draft 1 had no update policy at all, which for an always-on machine is a gap rather than an
omission.

### 11.1 Log retention

Session logs (§4.2), the dashboard's own log and any service logs outside the journal rotate
at **64 MiB or 30 days, whichever comes first**, keeping five prior segments. `journald` is
capped with `SystemMaxUse=2G`. A machine that runs for a year without anyone looking at it
should not fill its root subvolume with text.

### 11.2 OS and driver updates

| Class | Policy |
|-|-|
| Security updates | `unattended-upgrades`, security pocket only, applied automatically |
| Everything else | Manual, by running the provisioning script, which is where version pins live |
| **NVIDIA driver and CUDA** | **Pinned, and never in the unattended set.** A driver that updates under an in-flight training run, or that ships a kernel module mismatched to a running kernel, breaks the GPU quietly. Updated deliberately, followed by B2's acceptance test |
| Kernel | Automatic within the HWE series, and it is the main reason a reboot gets scheduled |
| Reboot required | `/var/run/reboot-required` is surfaced **on the dashboard**, never acted on automatically. §2.1's passphrase means an automatic reboot would take the machine offline until someone visits it |

### 11.3 Pinned CLI refresh

The four agent CLIs are pinned (§4). They are refreshed **deliberately, together, and
followed by B4's acceptance test**, because a silent auto-update to an agent CLI changes
behaviour mid-task. A monthly check that reports what is behind, without applying it, is
enough.

### 11.4 Rollback

btrfs snapshots of `@` are taken before the provisioning script runs and before a manual
apt upgrade, retained for 30 days. Rolling back is a boot-time subvolume swap. **This is not
a substitute for backup** (§10): the snapshots live on the same striped array that a drive
failure destroys.

## 12. Build order

Each milestone has an exit test, not a judgement, except where a judgement is the point and
is labelled as one. **Two spikes and one preflight come before anything destructive.**

### The preflight, which must finish before either NVMe is touched

| # | Item | Exit test |
|-|-|-|
| **S1** | **Does `restic` work against the HF S3 gateway?** (§10.4) | Create a bucket, `restic init`, back up a directory, `restic check --read-data`, restore to scratch, `diff -r` clean. If it fails, the backup destination is unresolved and B0 cannot complete |
| **B0** | **Back up the machine that exists today, and prove the backup is real** | The Tensorbook currently holds work. Before repartitioning: back up `/home` and `/etc` to the bucket, restore to scratch storage on a *different* machine, and diff. Then set up the §10.2 second copy and confirm it pulls. **Record explicitly that T5 is open** (a write-capable token on the box can erase the bucket) and that RAID0 is being accepted on those terms |
| **S2** | **Rehearse the storage install in a disposable VM** | Two full installs from a written runbook, the second reproducing the first exactly. The runbook records partitioning and EFI layout, `mdadm` assembly during early boot, LUKS creation and unlock, btrfs subvolume creation and mount options, `/etc/crypttab`, `/etc/fstab`, initramfs contents, and behaviour when one array member is absent |

**S2 exists because the provisioning script starts after installation**, so the most
consequential part of the machine, the storage layout, is currently reproduced by nothing.
A runbook that has been executed twice is the artifact; prose describing the layout is not.

### The machine

| # | Milestone | Exit test |
|-|-|-|
| **B1** | Base install, headless, SSH, Tailscale, power policy | Reboot, **enter the LUKS passphrase at the machine**, and after boot completes it becomes reachable over the tailnet by name with no further intervention. `/proc/acpi/wakeup` shows XHCI disabled and `systemd-sleep` masked |
| **B1a** | Network exposure is what the spec says | From off-tailnet: SSH refused, dashboard refused, model port refused. From on-tailnet: SSH accepted, dashboard accepted. `mosh`'s UDP range reachable on the tailnet only. Jupyter bound to localhost and **not** reachable from another device even on the tailnet |
| **B2** | NVIDIA, CUDA, PyTorch | `nvidia-smi` reports the 3080 and `torch.cuda.is_available()` returns true, both **after a reboot**, not only after install |
| **B3** | Live with it | Several days of real work over SSH. This is a judgement, and it is the one that decides whether any of the rest is worth building |
| **B4** | Ollama | A model answers on `11434` from **another device** on the tailnet. Measure and record actual VRAM use, load time, tokens/sec and package temperature under sustained load, because §2.3's thresholds are guesses until then |
| **S3** | **Can one stored copy serve both servers?** (§5.2) | Hand an Ollama blob to `llama-server` for the exact quantisation in use. Pass means one copy; fail means storage is doubled and the spec says so |
| **B5** | `llama-swap`, and the GPU lock | Codex talks to `llama-server` over Responses on `8081`. A training run holding the lock makes a new model load **refuse with the holder named**, while an already-resident model keeps serving |
| **B6** | Agent CLIs, `zellij`, session logging | All four launch, authenticate and run a trivial task. Claude Code's phone steering still works, which is what §4.1 protects. Kill a session and confirm its `script(1)` log survives with the transcript intact |
| **B7** | Backup, on the new machine | Restore `/home` to a scratch directory and diff it. Confirm the second copy (§10.2) is still pulling |
| **B8** | Read-only dashboard | Panels in §8.1 match the machine's real state, checked from a phone. No write actions exist |
| **B9** | Provisioning reproduces the machine | The script runs clean on a fresh VM, then runs again and changes nothing. Together with S2's runbook, this is the whole reproducibility claim |

**B1 through B3 is the decision point.** If the machine is not pleasant to work on over SSH,
that needs finding out before the model-serving and agent layers get built on top of it.

## 13. Open questions

| # | Question | Why it is open |
|-|-|-|
| 1 | Does `restic` work against the HF S3 gateway? | **S1 in §12, and it blocks B0.** The gateway supports only `ListObjectsV2`, drops `x-amz-meta-*`, restricts key shapes and redirects `GetObject` to a CDN. None of that obviously breaks `minio-go`, and none of it is confirmed |
| 2 | Which machine holds the second backup copy, and how often does it pull? | §10.2 makes a second copy a requirement rather than advice, because the HF bucket has no versioning and no lifecycle rules. The schedule sets how long a wipe can go unnoticed |
| 3 | Can one stored copy serve both Ollama and `llama-server`? | **S3 in §12.** Decides whether `/srv/models` holds one copy of a model or two |
| 4 | Are `croft` and the Emacs LLM integration still wanted? | Both came from the original requirements list, which predates the headless decision |
| 5 | Is a UPS worth buying? | §7.1: it converts the commonest cause of an unattended reboot from an office trip into nothing. Cheap, and outside this spec |
| 6 | Which GPU drives an external display, if one is ever attached | Deferred from M0. On a headless server it may never need answering |
