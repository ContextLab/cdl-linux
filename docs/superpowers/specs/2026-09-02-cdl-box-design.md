# `cdl-box` - a console-first model and agent workstation

**Status:** draft 1, for review.
**Supersedes:** everything in `docs/archive/` (see that directory's README for what was
retired and why).
**Hardware facts:** `notes/hardware/tensorbook-profile.md`, which stays live. Every number
below that describes this machine was measured there, not assumed.

## 1. What this is

**`cdl-linux` is a reproducible workstation configuration for Ubuntu Server 26.04,
optimised for local and remote agent work, model serving, and GPU training.**

In practice that is one install script. It runs on a stock Ubuntu Server 26.04 machine and
turns it into a workstation that serves local models, runs coding agents, and trains on the
GPU. The model is Lambda Stack, which is already on this hardware and installs with
`wget -nv -O- https://lambda.ai/install-lambda-stack.sh | sh -`: one command, vanilla
Ubuntu, hardware detected, everything configured. We want that experience.

```bash
git clone https://github.com/ContextLab/cdl-linux && cd cdl-linux && ./install.sh
```

Running it twice changes nothing the second time. Running it on a fresh Ubuntu Server
install of the same version reproduces the machine.

### 1.1 It is public, and it is not a product

The repository is public and others are welcome to use it or build on it. **There is no
maintenance promise, no support, and no testing beyond one person's daily use**, and saying
so plainly is fairer than implying otherwise by omission. Contributions are welcome;
guarantees are not offered.

That decision is why this is **not a distribution**. A deep audit on 2026-09-02 laid out
what a real one needs: a remastered installer ISO, CDL-owned signed Debian packages, a
signed APT repository with stable and staging channels, signing-key rotation and revocation,
release manifests, SBOMs, source and licence compliance, and an upgrade and rollback policy
for strangers. That list is correct, and every item on it exists to serve people who install
your software and then depend on it. **We are not taking that commitment**, so we do not
build the apparatus that discharges it. If this ever acquires users who need those
guarantees, the packages are the natural unit to add signing to, and that is the upgrade
path.

### 1.2 Two supported modes

| Mode | What it is |
|-|-|
| **Portable** | Run `./install.sh` on an existing Ubuntu Server 26.04 installation. **Storage is left exactly as it is.** Everything else is configured |
| **Appliance** | Install Ubuntu with the supplied autoinstall profile to get the storage layout in §2.1, then run `./install.sh` |

**The autoinstall profile is an optional hardware-specific companion, not a distribution.**
It exists because a script cannot repartition the disk it is running from: the striped,
encrypted layout has to be built before there is a root filesystem to run a script from.
Lambda Stack has the same boundary and does not touch your disks either.

Portable mode is the one that works on anyone else's machine, and it is the mode this
project can honestly claim to support. Appliance mode is specific to a two-NVMe Tensorbook
and is where all of the destructive risk lives.

**Branding starts after Ubuntu boots.** The installer and Canonical's signed boot components
stay recognisably Ubuntu: replacing shim, GRUB or the kernel means disabling Secure Boot or
enrolling our own key, and that cost buys nothing. Everything from the Plymouth theme and
the LUKS prompt onward -- getty and `kmscon` presentation, the `cdl` console launcher, the
shell, the palette, the dashboard and the documentation -- is ours. §9.8 has the stages.

### 1.3 Console-first, not headless

Draft 2 said "headless" and meant two different things by it. **No graphical stack** is
correct and stays: no X, no Wayland, no compositor, no display manager, no session lock, no
autologin. **A local console that is only good enough for emergencies** was a mistake, and
the audit was right to catch it. The machine now lives in an office you have to visit to
type a passphrase, so the console you are standing in front of should be usable.

So the local experience is a **branded, authenticated text console** (§9), and SSH is an
equal interface rather than the only one. That costs almost nothing: a getty, a login, and a
launcher. It does not bring back a display session, and none of the risk that came with one.

### 1.4 What it is not

- **Not an agent orchestration system.** Agents run in `zellij` workspaces and a human
  decides what to run. The archived design describes an orchestration layer; this does not
  depend on it and may never need it.
- **Not a Linux distribution** (§1.1).
- **Not multi-user.** One supported human operator, which is not the same as one Unix
  account: services still run as their own least-privileged users.
- **Not a general-purpose desktop.**

## 2. Base system

| Choice | Value | Why |
|-|-|-|
| Distribution | **Ubuntu Server 26.04 LTS** | Signed NVIDIA modules under Secure Boot; five years of updates; the CUDA path is well-trodden |
| Install | Stock installer, minimal, **no** `ubuntu-desktop` | Nothing needs a display |
| Kernel | `linux-generic-hwe-26.04`, tracking the HWE series and never a mainline or vendor kernel | Pinning to a specific version would strand the machine on unpatched kernels; a mainline kernel loses the signed modules Secure Boot needs (§2.1.1) and Canonical's NVIDIA packaging. The AX210 wifi is on in-kernel `iwlwifi`, so no firmware package is needed (measured) |
| Secure Boot | **On** | Signed NVIDIA modules load; nothing here needs hibernation. **Not the same as verified boot**, see §2.1.1 |
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
- **The backup becomes the only copy**, which lands awkwardly against §10.2: the Hugging
  Face bucket has no versioning and no lifecycle rules, so nothing prevents the box deleting
  its own backup history. Until the second copy in §10.2 exists, this machine has **no
  redundancy and no protected backup at the same time.** That is an exposure, it is stated
  here rather than in a footnote, and building the second copy is the cheapest thing that
  closes it.

### 2.1.1 What Secure Boot buys, and what it does not

Ubuntu's chain validates the shim, GRUB, the kernel and kernel modules, which is what lets
the signed NVIDIA modules load. **The initrd is not validated in that chain.** Anyone who can
write to `/boot` can therefore change what runs before the root filesystem is unlocked, and
§2.1 leaves `/boot` unencrypted by necessity, since GRUB has to read a kernel before anything
can be decrypted.

So this design claims **signed kernel and modules**, and does **not** claim verified boot.
The gap is real rather than theoretical, and it is part of what physical access to the
machine buys an attacker. Stating it narrowly is the point: a security property described
more broadly than it holds is worse than one nobody claimed.

### 2.1.2 The subvolume layout, and how it is built

**The contract.** Curtin creates the md/LUKS/btrfs stack with root initially in the
top-level subvolume, because curtin cannot create btrfs subvolumes from an autoinstall
storage config. An installer late-command then migrates the installed target into `@`,
`@home` and `@models` before first boot.

**V4 passed on 2026-09-04.** Three consecutive installs from clean disks: migration exit 0
through all eight stages, the machine boots, LUKS unlocks at the console, `verify.sh`
reports 21 passed and 0 failed, and the fixture reports 30 passed and 0 failed. The
refusal paths were exercised on a live machine: an already-migrated target exits 0, a
non-mountpoint is refused, and a partially migrated filesystem is refused with two
recovery routes and nothing touched.

**It is still only proven in a VM.** Nine VM runs were needed to get there, and six of the
nine failures were in the harness or the delivery mechanism rather than in the migration.
That ratio is the argument for H1 keeping recovery media to hand rather than a reason to
feel confident.

That is the whole of the normative decision. The measurements behind it -- what the stock
installer will and will not do, why the migration cannot run on a live system, and how the
first attempt failed -- are in `notes/2026-09-03-storage-experiments.md`. They are evidence
worth keeping and they were obscuring the contract by sitting inside it.

**Consequence for §1.2, and it is not a small one:** the appliance path is the *only* path
that produces this layout. Running `install.sh` on an existing machine cannot add it, so
`install/modules/15-btrfs-subvolumes.sh` is a guard that refuses and explains, not an
attempt. A machine without the layout is fully supported; what it loses is §11.4's rollback.

### 2.1.3 The migration runs in the installer, because it cannot run anywhere else

Both ways of migrating a live root were measured and both fail: btrfs will not snapshot the
top-level subvolume while it is mounted as root (`Text file busy`), and a directory with a
filesystem mounted on it cannot be renamed (`Device or resource busy` on `/boot`). Neither
is documented anywhere we could find, and each cost a VM cycle.

In `late-commands` the filesystem is mounted at `/target` and nothing is executing from it,
which makes the whole operation ordinary.

**The primitive matters more than the traversal.** A btrfs subvolume is a separate inode
namespace, so `rename(2)` across one returns `EXDEV` and `mv` silently degrades to
copy-then-unlink -- which breaks hardlinks between moved files and rewrites every inode.
`@` is therefore created with `btrfs subvolume snapshot`, which is atomic, costs no space,
and preserves hardlinks, ownership, modes, timestamps, xattrs and ACLs exactly. The two
directory-level splits (`/home` into `@home`, `/srv/models` into `@models`) use
`cp -a --reflink=auto`, whose `--preserve=all` includes hardlinks.

### 2.1.4 The migration is a script with stages, not a string in a YAML file

`install/installer/migrate-btrfs-root.sh` is delivered into the installer as base64 in
`write_files`, so the repository file is the single source of truth and no YAML indentation
rule can corrupt it.

It is a separate file because the first version was not, and the difference is not
stylistic. A destructive procedure written inside an autoinstall string cannot be
shellcheck'd, cannot be run outside an installer, and -- the part that cost six hours --
fails with a message naming the entire script while its trace goes to a journal the harness
cannot reach.

The script therefore:

| Property | Why |
|-|-|
| Refuses when `/target` and `/` are the same filesystem | It must never run on a live system, and a sentence saying so is not a check |
| Exits 0 when root is already on `@` | `late-commands` can re-run; "already done" is success |
| Distinguishes empty leftover subvolumes from a populated `@` | The first is clearable, the second must not be guessed at |
| Records each stage to `.cdl-migration-state` on the top-level subvolume | The failure that matters is the one that leaves you unable to ask what happened |
| Cleans up its mounts from an `EXIT` trap | An interrupted run must not leave `/tmp/cdl-top` mounted |
| Checks free space and that btrfs recognises the device first | Cheap, and the alternative is failing halfway |
| **Validates all three subvolumes, the fstab, and the moved system before touching the bootloader** | `update-grub` and `update-initramfs` against a half-migrated tree produce a machine that does not boot |
| Uses `chroot /target` for every target operation | One answer to "how do we run something in the target" rather than two that must agree |
| Writes evidence to `/var/log/cdl/migration.txt` in the target | The installed machine can say how it was built |

**V4 is not complete.** It requires two clean VM installations, root on `subvol=/@`, `/home`
and `/srv/models` on their subvolumes, SSH key login after reboot, and every fixture file
surviving with its ownership, modes, links, xattrs and content intact. The fixture is
generated in the installer before the migration and records a manifest of what is actually
on disk; `scripts/vm/fixture/verify.sh` diffs the same measurements after reboot, so no
expectation is written down twice where the two copies could drift.

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

**The GPU needs its own policy, and the thresholds above are the CPU's.** They are different
devices with different limits, sensors and remedies: the package is throttled through
`intel_pstate`, while the GPU's levers are a power cap (`nvidia-smi -pl`) and refusing to
admit work. Starting values, equally provisional and equally due for measurement under B4:

| Parameter | Value |
|-|-|
| Sample | GPU temperature from `nvidia-smi`, on the same 5 s interval |
| Soft limit | ≥ 80 °C: reduce the power cap by 15 W, floor 80 W |
| Recover | ≤ 70 °C for 60 s: raise by 15 W, ceiling the card's default |
| Admission | ≥ 87 °C: refuse to load a new model or start a training run, and say why |
| Never | Kill a running job on temperature. The card throttles itself, and losing an hour of training to a thermal spike is worse than the spike |

**"Refusing to start work" applies to exactly one thing: `cdl-thermal` publishes a gate that
the model-server wrapper reads before loading a new model.** It does not stop training runs,
does not kill anything already running, and does not touch agent sessions. A person who
starts a long job on a hot machine is making a choice, and this is not the component that
overrules it.

## 3. The install script

One entry point, `./install.sh`, which is what §1 promises and what the Lambda Stack model
implies. Underneath it are numbered idempotent modules in `install/modules/`
(`10-base.sh`, `20-nvidia.sh`, `30-models.sh`, `40-agents.sh`, `50-console.sh`,
`60-backup.sh`), but a person installing this runs one command and reads one summary.

### 3.1 The properties that matter

- **Idempotent.** Running it twice changes nothing the second time. This is the property
  that makes it safe to re-run after editing one module, and it is the one most easily lost,
  so §12's B9 tests it rather than assuming it.
- **Vanilla Ubuntu Server 26.04 is the only prerequisite.** Not a CDL ISO, not a
  pre-seeded image. Someone who wants to try this on their own machine should not first have
  to trust an image we built.
- **It refuses rather than guesses.** Wrong Ubuntu version, wrong architecture, no NVIDIA
  card: it stops and says which, instead of installing three quarters of a machine.
- **Every module can be run alone**, so a failure in `20-nvidia.sh` does not mean re-running
  the whole thing to retry one piece.
- **It does not touch storage** (§1.2). The layout in §2.1 has to exist before there is a
  root filesystem to run a script from, so the fresh-machine path uses
  `install/autoinstall.yaml` with the Ubuntu installer and the script runs afterwards.

### 3.2 What it changes, and what it leaves alone

The script adds third-party APT sources it needs (NVIDIA's, Tailscale's, and so on) and
installs from them. Those repositories are signed by their own vendors, which is the same
trust the machine already places in Ubuntu's archive.

**It does not create a CDL repository or CDL packages** (§1.1). Configuration files it owns
are written under `/etc/cdl/` and marked, so a later version can tell what it put there from
what a person changed. Anything it would overwrite is backed up beside the original first.

**Uninstall is not supported**, and saying so is fairer than a half-working `--uninstall`
that leaves a machine in a state nobody has tested. The recovery path for "I do not want
this any more" is reinstalling Ubuntu, which on this design is a documented procedure
rather than a disaster.

### 3.3 When a module fails

Not supporting uninstall is not a reason to leave a failed run undiagnosable, and these are
different problems: a failed module is the common case, and reinstalling Ubuntu is an absurd
answer to it.

A failed module stops the run. Modules after it do **not** execute, because continuing past
one builds on a state the script cannot describe. What the operator has afterwards:

| | |
|-|-|
| **What ran** | `/var/log/cdl/install-runs.jsonl`, one JSON object per module with its result and exit status. The run's own summary counts `ok`, `skipped`, `failed` and `did not run` |
| **What changed** | Every file a module edits is copied to `<file>.cdl-backup-<run-id>` first, so the previous content is beside the original |
| **What to do** | Fix the cause and run `sudo ./install.sh --module <name>`. Modules are idempotent, so re-running the whole script is equally safe |
| **What not to do** | Skip the module and continue. If a module is genuinely inapplicable it should exit 2, which the run records as `skipped` rather than `failed` |

The failure message names the exact re-run command, because a person reading it has just
had something go wrong and should not also have to work out the syntax.

### 3.4 Services run as their own users, and are hardened the same way

§1.4 says this machine is not multi-user, meaning one supported human operator. That is not
the same as everything running as one account, and the spec has so far implied the
distinction without stating it.

Every long-running service gets its own system account with no login shell and no home
worth having:

| Service | User | Owns |
|-|-|-|
| Ollama | `ollama` | `/srv/models/ollama`, read-write |
| `llama-swap` / `llama-server` | `llama` | `/srv/models/gguf`, **read-only** |
| Dashboard | `cdl-dash` | nothing; it reads through the interfaces in §8.1 |

`/srv/models` is group-readable by a `models` group that all three join, so weights are
shared without any service being able to modify another's. The dashboard being unable to
write anything is the enforcement behind §8.2's read-only claim -- a promise in prose that
the process could break is not a control.

Each unit carries the same hardening block, and the reason for each line is that it is cheap
here rather than that it is fashionable:

```ini
NoNewPrivileges=true          # no setuid escalation from a compromised model server
PrivateTmp=true               # a scratch file cannot be read by another service
ProtectSystem=strict          # / is read-only; only ReadWritePaths are not
ProtectHome=true              # /home is invisible: no service has business there
ReadWritePaths=/srv/models/…  # exactly one directory, named per service
ProtectKernelTunables=true
ProtectKernelModules=true     # nothing here loads a module
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=false  # false, deliberately: JIT and CUDA need W+X and would break
```

**`MemoryDenyWriteExecute` is off on purpose**, and it is listed rather than omitted so that
nobody adds it later assuming it was an oversight. CUDA and the JIT paths in these servers
map writable-executable memory, and enabling it makes them fail at load with an error that
does not mention systemd.

The GPU needs `/dev/nvidia*`, so `PrivateDevices` is not set for the model servers; the
dashboard, which touches no device, sets it.

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
serve both is **spike S3** (§12): find whether an Ollama blob can be handed to
`llama-server` directly, for the exact versions and quantisations in use. Until that spike
passes, assume a model wanted by both servers is stored twice.

### 5.3 VRAM, and what happens when training holds the GPU

16 GB, measured. That fits one large model, or one large plus one small, which is what
`llama-swap` exists to manage.

**Training and serving do not overlap** (§6.1). Starting a training run stops the model
servers, and they come back when it finishes. Draft 2 claimed a resident model would keep
serving through a training run, which was not achievable under the lock protocol it
described; the honest policy is the simpler one.

In practice a request to the model endpoint during a training run is refused rather than
answered slowly, and both `cdl status` and the dashboard show the GPU as held by training
with the holder named, so the cause is visible rather than mysterious.

This is cooperative, not enforced. Anything that runs `python train.py` directly, without
the wrapper, will take VRAM and the lock will not stop it.

## 6. Training and fine-tuning

The stack, installed by `20-nvidia.sh` and `40-ml.sh`:

- NVIDIA driver from the Ubuntu archive (signed, loads under Secure Boot), CUDA toolkit,
  and `nvidia-smi` working as the acceptance check.
- PyTorch with CUDA, `transformers`, `datasets`, `peft`, `accelerate`, `bitsandbytes`.
- **`uv` for every environment**, so packages hardlink from one shared cache instead of
  being copied per project.
- **`rclone`**, which is a hard dependency of the backup path rather than a convenience
  (§10.5): `restic` cannot reach an HF bucket without it.
- **`hf-mount` for read-only access to Hub repos**, which is where mounting genuinely fits:
  its README names *"Loading models and datasets without downloading the full repo"* and
  *"Environments where disk space is limited"* as what it is best for. A large evaluation
  dataset can be read lazily from `hf://` instead of occupying part of a 2 TB volume shared
  with checkpoints. Read-only, and never in the backup path (§10.4).
- Jupyter available but bound to localhost, reached by SSH port-forward rather than exposed.

16 GB of VRAM sets the ceiling, and it is worth stating in numbers rather than adjectives so
B2 and B4 can check it:

| Workload | Fits in 16 GB? |
|-|-|
| Inference, 7-8B parameters at Q4 | Yes, roughly 5-6 GB resident, leaving room for a second small model |
| Inference, 13-14B at Q4 | Yes, roughly 9-10 GB, one model only |
| Inference, 30B+ at Q4 | No |
| QLoRA fine-tune, 7-8B, 4-bit base, short sequences | Yes, and this is the intended training workload |
| LoRA fine-tune, 7-8B, 16-bit base | Marginal; depends on sequence length and batch size |
| Full fine-tune of anything above about 1B | No |

These are estimates from parameter counts and quantisation, **not measurements on this
card**. B4 replaces them with measured figures. They are here so a plan built on them is
checkable rather than vague.

### 6.1 The GPU lock contract

**Draft 2's protocol could not work, and it is worth saying why before replacing it.** It
gave inference servers a *shared* lock held for their whole lifetime and required training to
take an *exclusive* one. Under `flock` an exclusive lock cannot be acquired while any shared
holder exists, so **training could never start while either server was running**. It then
promised that an already-resident model would keep serving while training held the exclusive
lock, which is the same contradiction from the other side: if training holds it exclusively,
no shared holder exists.

**The policy is exclusive workload: inference stops for training.** It is the only available
option that is deterministic on 16 GB of VRAM, and it matches how the machine is used, since
serving does not have to continue through a training run.

| Element | Value |
|-|-|
| Lock file | `/run/cdl/gpu.lock`, created by a `tmpfiles.d` rule, mode 0664, group `cdl` |
| Who takes it | `cdl-gpu <command>`, a wrapper that acquires the lock and `exec`s. **Every training entry point starts under it** |
| Mode | **Exclusive, always.** There is no shared mode, because the shared mode is what made the protocol impossible |
| Inference servers | Do **not** hold the lock for their lifetime. `cdl-gpu train` stops `ollama` and `llama-swap` through systemd, waits for them to exit, then takes the lock |
| Restart | Whatever was stopped is restarted when training exits, including on a crash or `SIGKILL`, through a `systemd` unit's `ExecStopPost` rather than a shell trap the wrapper might never run |
| Confirmation | `cdl-gpu train` **names what it will stop and asks**, because that endpoint may be serving another device mid-request. `--force` skips the prompt for scripted runs |
| Holder identity | Recorded in `/run/cdl/gpu/holder`, not in the lock file, since a lock file is a poor place to keep state |
| Release | `flock` releases on process exit, including a crash, so a killed job cannot strand the GPU |

**This is cooperative and the spec does not pretend otherwise.** A bare `python train.py`
takes VRAM and honours nothing. The wrapper is made the path of least resistance (it is what
the shell aliases and the systemd units call), which is the only enforcement available
without a container or cgroup device policy, and neither earns its cost here.

**If continuous serving ever matters more than determinism**, the alternative is a brief
admission lock around model load and training start, plus a measured free-VRAM check, which
lets existing inference coexist. It accepts a real risk of running out of memory, would need
testing to characterise, and on 16 GB would refuse most of the same requests anyway, only
less predictably.

## 7. Remote access

- **Tailscale** for reachability, so the box is available from a laptop or phone without
  port-forwarding or a public address.
- **OpenSSH**, key-only, bound to the tailnet and the LAN. The specifics, because "key-only"
  is the sort of claim that is true of the config file and false of the running daemon:
  `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, and
  `AllowGroups cdl` so a future account does not get SSH merely by existing. **B1a asserts
  the *effective* configuration with `sshd -T`**, not the contents of `sshd_config`, since an
  `Include` or a `Match` block can make the two differ.
- **Console authentication is a separate problem with a separate answer.** SSH takes keys;
  the console takes a Unix password, because there is no key to present when you are standing
  at the machine. That password is also what `sudo` takes, so it needs to be a real one.
  Unlocking the disk authenticates the *disk*, not the person, which is why §9.1 puts a login
  after it.
- **`mosh`** for sessions over poor links, which matters more than it sounds when the
  alternative is a dropped agent session.
- **The model endpoint is served on the tailnet**, so other devices use this machine's GPU
  by pointing at one URL. It binds to the tailnet interface, never `0.0.0.0`.

### 7.1 What the network does when Tailscale is not working

Three states the design has to survive, because two of them are how a machine becomes
unreachable for a day.

**Before enrolment.** A freshly installed machine has no tailnet. `sshd` therefore also
listens on the LAN, so the first connection can happen without Tailscale, and enrolment is
one of the first things §9.1's console home screen offers. The console is what makes this
recoverable rather than a chicken-and-egg problem.

**During failure or re-authentication.** Tailscale keys expire and nodes get logged out.
When that happens the tailnet address stops working while the LAN address keeps working, so
the machine is reachable to anyone on the same network and unreachable from outside it.
`cdl status` and the console report tailnet state explicitly, because "Tailscale is logged
out" and "the machine is down" look identical from a laptop elsewhere.

**Key expiry is disabled for this node.** It is a server, and a server that logs itself out
on a timer while nobody is in the building is a machine that needs a car journey.

### 7.2 Being on the tailnet is not authorisation

The model endpoint and the dashboard bind to the tailnet, and draft 2 treated that as the
whole access control. It is not. **Every device on the tailnet, and every device
someone else shares into it, can reach both** — which means it can read prompts, model
output, and everything §8.1 displays.

For a single-person tailnet that is close enough to fine, and it is stated so the assumption
is visible rather than implied. Two things follow:

- **The dashboard checks identity**, not just reachability: it resolves the caller with
  `tailscale whois` and refuses anyone who is not the owner (§8.3).
- **The model endpoint does not**, because Ollama has no per-caller authentication and
  putting a proxy in front of it is work with no payoff on a one-person tailnet. **If the
  tailnet is ever shared, that endpoint is shared with it.** That is the trigger to revisit
  this, and it is written down so the trigger is recognisable.

### 7.3 A reboot takes the machine offline until someone visits it

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

**It is read-only, and §8.2 is the authority on that.** An earlier draft described two write
actions here and declared the dashboard read-only one section earlier, which is the kind of
contradiction that gets resolved by whoever implements it rather than by whoever wrote it.
Anything that changes state belongs in the console or over SSH, where the friction is
appropriate.

## 9. The console, and the shell

Two equal interfaces: the text console you sit at, and SSH. Draft 2 treated the console as
an emergency prompt, which was wrong. **Using a local model from the machine itself is a
stated use case**, so the console has to be somewhere work happens rather than somewhere
you go when SSH is broken.

### 9.1 The path from power-on to working

```
firmware
  -> GRUB          branded menu, recovery entry visible
  -> Plymouth      branded splash, LUKS passphrase prompt, Escape reveals the log
  -> getty tty1    branded /etc/issue
  -> login         ordinary PAM authentication
  -> cdl           the home screen
       status          what is running, GPU, disk, last backup
       chat            talk to a local model, right here
       workspace       create or attach a zellij workspace
       maintenance     updates, backup now, logs
       shell           drop to a plain shell
```

**`cdl` is launched from the login shell explicitly, never from `.profile`.** That
distinction is not cosmetic. A launcher in `.profile` runs for every non-interactive session
too, so it would capture `scp`, `rsync`, `git` over SSH, and any automation, all of which
expect a clean stdin and a clean stdout. It would also fire on the recovery session someone
is using precisely because the normal path is broken.

**So how does anyone find `cdl`?** Saying where it must not go leaves the actual mechanism
unstated, and "type `cdl`" is not discoverable on a machine used every few weeks.

| Where | What |
|-|-|
| The login banner | `/etc/issue` on tty1 carries the logo and one line: the machine's name, and `cdl` as the way in |
| After login | `/etc/motd.d/10-cdl` prints a two-line status -- services up, GPU state -- and names `cdl`. `motd.d` runs on interactive login only, which is the property `.profile` lacks |
| The shell | An alias is not enough; `cdl` is a real executable in `/usr/local/bin`, so `scp`, `rsync` and `ssh host cdl ...` all behave |

The distinction that matters: `motd.d` and `/etc/issue` are **displayed** on interactive
login, while `.profile` is **executed** on every shell including non-interactive ones. A
banner that mentions a command cannot capture a `git push`; a launcher that runs can.

**There is no autologin.** The disk was just unlocked by someone standing at the machine,
which authenticates the disk rather than the person, and the machine is in an office rather
than a locked room.

### 9.2 A recovery terminal that is nothing special

**tty2 is an ordinary getty with an ordinary login and an ordinary shell.** No `cdl`, no
launcher, no zellij. It exists so that a broken home screen, a broken shell configuration
or a broken zellij is an inconvenience rather than an incident, and it needs no
documentation beyond knowing it is there.

GRUB's recovery entry stays visible in the menu for the same reason.

### 9.3 Local and remote workspaces are separate by default

`zellij` lets several clients attach to one session, and both can then see the pane contents
and type into it. That is useful when you mean it and surprising when you do not: a console
session and an SSH session sharing one workspace means whoever is at the machine sees what
you are doing remotely, and either can interrupt the other's input.

So **`cdl workspace` gives the console and SSH different sessions by default**, named for
where they came from. Sharing is available as an explicit `cdl workspace attach --shared`,
which first lists the clients already connected. The default is separation; sharing is a
choice made with the information needed to make it.

### 9.4 Transcripts are sensitive, and are treated as such

Session logs (§4.2) capture everything an agent printed, which includes source code,
prompts, and anything a tool echoed. They are therefore mode 0600, under
`~/.local/state/cdl/sessions/`, and rotated on §11.1's schedule.

**They are excluded from every backup set, not merely the default one**, and the exclusion
lives in `restic`'s exclude file rather than in the arguments of one invocation. "Excluded
by default" was the earlier wording and it was ambiguous in the direction that costs
something: it reads as though a fuller backup would include them, which would put prompts
and source code in a bucket whose deletion protections §10.2 already describes as
incomplete. If a transcript is ever worth keeping, it gets copied somewhere deliberately.

`zellij`'s own session resurrection is **disabled**, because a pane's contents surviving a
reboot in a cache directory is a copy of the same material with none of the same care.
Anything genuinely worth keeping goes in the worktree, in git, deliberately.

### 9.5 The shell

The part that decides whether this is pleasant to use daily.

- **Shell**: `zsh`, with a prompt showing host, path, git branch and GPU state, so a
  reattached session says what machine it is on.
- **Multiplexer**: `zellij`, with a layout for agent work.
- **Editor**: Emacs, plus one LLM integration.
- **Colours**: one palette across the shell prompt, `zellij`, `bat`, `eza`, `delta` and
  Emacs, checked for contrast at the terminal level rather than assumed. The panel is on
  the Intel iGPU (measured), so console rescue works without the NVIDIA driver.
- **Tools**: `git`, `gh`, `rg`, `fd`, `jq`, `htop`, `nvtop`, `restic`, `rclone`, `croft`.

Theming for the shell side is configured on the box, and the client terminal's own
configuration (fonts, window) stays on the client, where it belongs.

### 9.6 Fira Code with ligatures, on the local console

**This is a requirement, not a preference.** The original brainstorming recorded it as D3:
*"macOS keybindings and font quality are HIGH priority, not cosmetic"*, and it named the font
specifically. It also recorded the tension it creates, as T1: *"'no GUI' vs 'Fira Code WITH
ligatures' — Linux VT uses bitmap PSF fonts, no shaping engine."*

That tension is real and worth restating, because it is a difference in rendering model
rather than a missing feature. The kernel's virtual terminal draws 1-bit PSF bitmaps from a
512-glyph table and has no text-shaping engine at all. **A ligature is a HarfBuzz `GSUB`
substitution**, so no console font, however well made, can produce one. Converting Fira Code
to PSF gives its letterforms and none of its ligatures.

The archived design resolved this with a fullscreen `kitty` under a Wayland compositor.
**The console-first decision silently dropped that, and with it a high-priority
requirement** — which is the kind of thing that happens when a simplification is judged only
against the things it obviously removes.

#### The answer: `kmscon` on tty1

`kmscon` is a KMS/DRM console emulator that runs in userspace and replaces the kernel VT. It
renders through freetype or pango rather than a bitmap table, so it does TrueType rasterising
**and shaping**, which is what ligatures need. It is actively maintained (10.0.0, May 2026)
and **is in the Ubuntu archive**, so this costs an `apt install` rather than a compositor.

What that buys, and what it does not: it gives real fonts and ligatures on the machine's own
screen without X, without Wayland, without a compositor, and therefore without the
session-lock problem that made the archived design's answer expensive. It is not a graphical
environment and nothing about it reintroduces one.

| Terminal | Font | Ligatures |
|-|-|-|
| **tty1** — `kmscon` | Fira Code, via freetype | **Yes** |
| **tty2** — kernel VT (§9.2) | Fira Code converted to PSF | No, and that is fine: it is the recovery path |
| **Over SSH** | Whatever the client uses | The client's business, not the box's |

**tty2 staying a kernel VT is deliberate.** `kmscon` is another thing that can fail, and the
recovery terminal must not depend on it. If `kmscon` does not start, tty1 falls back to the
kernel VT and the machine is still usable, just less pretty.

#### The font, and why it is two fonts

**`fonts-firacode` from the Ubuntu archive, plus Symbols Nerd Font as a fallback.** The
original notes settled this and the reasoning still holds: `croft` renders file and
activity-bar icons as Nerd Font glyphs, which plain Fira Code does not carry. The patched
Fira Code Nerd Font build is **not** in the Ubuntu archive, so rather than vendor a patched
font we use the packaged original and let fontconfig fall back to the symbols-only font for
the glyph ranges it lacks. That keeps the licensing simple (both are SIL OFL, so a public
repo can carry the configuration without carrying the fonts) and keeps Fira Code updatable
through `apt`.

**None of this is confirmed on the actual panel, and it is a spike rather than a plan.**
`kmscon` renders through DRM, and the Tensorbook's console is driven by the Intel iGPU with
an NVIDIA GPU also present. Two things are unverified: that `kmscon` starts at all against
`i915` on this machine with the NVIDIA driver loaded, and that shaping actually produces
ligatures at the console rather than merely rendering the font. **Spike S4** answers both
before P1 depends on them: install `kmscon`, start it on tty1, display a line containing
`=>`, `!=` and `->`, and photograph the screen. If it fails, the console keeps the kernel VT
and loses ligatures, which is a cosmetic loss rather than a design change -- §9.2's recovery
terminal is a kernel VT for exactly this reason.

### 9.7 The CDL palette, and the logo

**One palette, defined once, applied everywhere it can be.** Sixteen ANSI colours plus a
foreground and background, living in `/etc/cdl/palette.conf`, and consumed by:

| Surface | Mechanism |
|-|-|
| `kmscon` on tty1 | its own `palette` configuration |
| The kernel VT fallback | `setvtrgb`, from the same source file |
| Shell prompt, `bat`, `eza`, `delta`, `zellij`, Emacs | generated theme files, from the same source file |
| The dashboard (§8) | CSS variables, from the same source file |

Generating them from one file is the point. A palette maintained in six places is a palette
that is subtly different in six places.

**Contrast is checked rather than assumed.** The archived design found that its own ANSI
black sat at 1.24:1 against the background while the document claimed every colour cleared
4.5:1, which is the sort of error that survives because nobody measures a colour scheme.
Every foreground colour is checked against the background it is actually drawn on, and the
check runs in the test suite rather than living in someone's memory.

**The logo, centred, at boot.** Plymouth draws it (§9.8), centred on the panel, with the LUKS
passphrase prompt beneath it. GRUB carries a smaller version in its menu. Both are artwork
and configuration, never a signed executable, and both keep their escapes: Plymouth's Escape
still reveals the boot log, and GRUB still shows its recovery entry.

The logo itself does not exist yet, and is open item 7.

### 9.8 Branding, stage by stage

"A branded boot" is not one thing. It is six, each with a different mechanism and a
different failure mode, and the point of listing them is that skipping any one leaves an
obviously stock screen in the middle of an otherwise finished sequence.

| Stage | What we do | Constraint |
|-|-|-|
| Firmware / OEM splash | Nothing. It is not ours | Outside our control on this hardware |
| shim, MokManager | **Nothing** | These are Canonical's signed binaries. Replacing one breaks Secure Boot; see below |
| GRUB | Menu title, colours, background, and a visible **Recovery** entry | GRUB's own documentation warns that early graphical modes can fail on some hardware, so the theme degrades to a plain text menu rather than to a blank screen |
| Plymouth | **The CDL logo, centred**, plus the LUKS passphrase prompt beneath it (§9.7) | Needs a working text fallback, and **Escape must reveal the boot log**. A branded splash that hides a failure is worse than no splash |
| getty / login | `/etc/issue`, showing hostname, tailnet name and a one-line hint | Plain text, and it is the first thing a person at the machine reads |
| After login | The `cdl` home screen (§9.1) | |
| Shell, dashboard, docs | One palette, used consistently (§9.5) | |

**The hard rule: artwork and configuration only, never a signed executable.** Ubuntu's chain
validates shim, GRUB, the kernel and its modules (§2.1.1). Replacing any of those with a
rebuilt copy means either disabling Secure Boot or enrolling our own key, and both are
larger changes than a nicer boot screen justifies. Themes, backgrounds, fonts, colours and
config files are not signed and are ours to change.

**Every branded stage keeps an unbranded escape**, because branding that removes a
diagnostic is a cost paid at the worst moment: GRUB keeps its recovery entry and its edit
key, Plymouth keeps Escape, and tty2 keeps a plain getty (§9.2).

## 10. Backup

There is no NAS. The machine goes in an office, and the striped array has no redundancy, so
this section is the only thing standing between a drive failure and total loss.

### 10.1 Destination: a Hugging Face Storage Bucket

**Decided 2026-09-02, on documentation.** HF Storage Buckets are S3-compatible object
storage on the Xet backend, reached through a gateway at `https://s3.hf.co/<namespace>`, and
the Hub's own documentation states this use case: *"Buckets are well-suited for maintaining
rolling backups."* Unlike a Git-backed dataset repo, buckets are not versioned, so deleting
old data actually reclaims it rather than accumulating history.

**`restic` reaches the bucket through `rclone`, not through its own S3 backend.** Spike S1
ran on 2026-09-02 and settled this; §10.5 records what was measured. The repository is
`rclone:hf:<bucket>/restic`, and `rclone`'s `hf` remote carries the gateway settings:

```ini
[hf]
type = s3
provider = Other
endpoint = https://s3.hf.co/<namespace>
access_key_id = HFAK...
secret_access_key = ...
region = us-east-1
force_path_style = true
list_version = 2
upload_cutoff = 2G
chunk_size = 2G
```

`region` is required because the gateway is single-region; `force_path_style` because buckets
are path segments rather than subdomains; `list_version = 2` because *"`ListObjectsV1` is not
supported"*. Credentials come from an HF access token via **Generate S3 credentials**,
producing an `HFAK…` key ID and a secret shown once. A **fine-grained token scoped to the one
bucket** is what the box should hold (§10.2).

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

**The second copy needs operations, not just a principle.** Draft 2 described the idea and
nothing else, which is how a safeguard ends up existing on paper only:

| Question | Answer |
|-|-|
| Where | A machine that is not this one and holds no credential this one can read. A laptop is fine; the point is the trust boundary, not the hardware |
| How often | Daily. That sets the window in which a wipe can go unnoticed, and it is the number to argue about if any is |
| Retention | Keep 30 daily pulls. `rclone copy` never deletes at the destination, so "retention" here means pruning the second copy deliberately, from that machine, never from the box |
| Capacity | The repository is `/home` and `/etc` with caches excluded, so tens of GB. Check before assuming a laptop has room; a second copy that silently stops for want of space is worse than none, because it is believed in |
| Encryption | Already encrypted: it is a `restic` repository, and the second copy is a byte copy of it. The passphrase lives with the person, not on either machine |
| Alerting | The pulling machine reports success or failure somewhere a human sees it. A backup nobody is watching fails silently by construction |
| Ownership | One named person. "The system does it" is how a copy stops running and nobody notices |
| Restore test | Quarterly, from the **second copy** rather than the bucket, because that is the copy nobody exercises and therefore the one most likely to be broken |

### 10.3 What is backed up

**Nightly**, by a `restic backup` timer. This was previously unstated, and the omission
mattered: the recovery-point objective in §10.2 cannot be defined without it. With a nightly
backup and a daily pull, the bucket is at most 24 h behind and the second copy at most 48 h.

- `/home` and `/etc`, with `--exclude-caches` so `CACHEDIR.TAG` directories drop out. The
  Hugging Face cache writes that tag, so the model cache is excluded for free.
- **`/srv/models` is not backed up.** Weights are re-downloadable and large. Checkpoints and
  datasets that are *not* re-downloadable live in `/srv/models/keep`, which **is** backed up.
- Restore drills are in B0 and B7 (§12), not deferred. A backup nobody has restored from is
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

### 10.5 Spike S1, run 2026-09-02: measured, and it changed the design

**Result: `restic` works against an HF bucket, but only through `rclone`. Its native S3
backend cannot initialise a repository there.**

**What fails.** `restic -r s3:https://s3.hf.co/<namespace>/<bucket>/restic init` fails at
`client.BucketExists: 400 Bad Request`. The cause is addressing, not permissions: `restic`
splits the repository URL at the first path segment after the host, so it reads the
**namespace** as the bucket and everything after it as a key prefix. Running the same command
with `-o s3.bucket-lookup=dns` proves it, since it then tries
`https://<namespace>.s3.hf.co/`. That is the HF documentation's addressing option 2, which it
warns *"has issues with bucket-level operations such as creating or deleting buckets"*, and
`init` is exactly a bucket-level operation. Dropping the namespace from the path fails the
same way, because the gateway then cannot tell which namespace the bucket belongs to.

**What works.** `rclone`'s `s3` backend accepts an endpoint that already contains a path, so
the namespace stays in the endpoint and the bucket name stays a bare bucket name. `restic`'s
`rclone:` backend then runs over it. Measured end to end, 7 of 7:

| Step | Result |
|-|-|
| `restic init` | Repository created |
| `restic backup` | 3 files, 1.907 MiB |
| `restic snapshots` | Snapshot listed |
| `restic check --read-data` | *"read all data … no errors were found"* |
| Second backup | Incremental, 3.448 KiB stored |
| `restic restore` + `diff -r` | **Byte-identical** |
| `restic forget --keep-last 1 --prune` | Old index and pack deleted; `check` clean afterwards |

**Confirmed from inside a guest on 2026-09-03**, which is a different claim from S1's: a
different `restic` build (0.18.1 on linux/arm64), a much older packaged `rclone`
(v1.60.1-DEV against 1.75.0 on the host), and a machine whose only route out is QEMU's
user-mode NAT. All eight steps pass there too, including a root-privileged backup, a restore
and a `prune`. The older rclone handling the gateway matters: the design does not depend on
a recent build.

**Two things the spike also established.** `rclone` becomes a **dependency of the backup
path** and must be in the install script (§3), which it was not. And the `prune` step
succeeding is the empirical confirmation of §10.2: the credential on the box **can** delete
its own backup history, so the second copy is not a theoretical precaution.

**One cosmetic artefact, recorded so it is not mistaken for a fault.** `rclone` emits
`NOTICE: … Failed to read last modified` for data objects, because the gateway does not
return a last-modified time restic's rclone transport expects. It is noise: `check
--read-data` verified every pack and reported no errors.

### 10.6 The second copy, measured 2026-09-04

`scripts/backup/pull-second-copy.sh` is the mechanism, `scripts/backup/README.md` the
operations, and `tests/net-second-copy.sh` runs both against the real bucket. Fifteen
assertions pass. What they establish, in the order an attacker would try things:

| Event | Outcome |
|-|-|
| The bucket is wiped | Restore from the second copy alone is byte-identical |
| Pull again from the wiped bucket | Nothing is deleted locally |
| A bucket file is replaced with different content | The pull refuses and the local file is untouched |
| Replaced with the **same size and mtime** | rclone skips it; it never enters the second copy |
| A local file rots without its mtime changing | Detected by content hash; the run fails and says the copy is not trustworthy |

**Three findings changed the design, and none was in the documentation.**

`--checksum` makes the copy *less* safe against this gateway. It returns no content hash,
and rclone reads "no hash" as "same", so same-size corruption passes. The flag is not used.

`--immutable` is necessary and not sufficient. It compares size and mtime; rclone sets the
local mtime from the remote on pull, so an overwrite in the bucket is caught by its new
mtime -- unless the attacker preserves it. Measured both ways: a replacement whose mtime
differed by about a second was caught, and one whose mtime was copied exactly (`touch -r`)
was skipped. Exact preservation is what it takes, and an attacker who can write the bucket
can do that.

**Every restic file is named by the SHA-256 of its content** -- keys, index, snapshots and
data were all checked -- so the puller verifies the copy cryptographically **with no
repository password**. That check runs on every pull whatever rclone reported, because
bit-rot changes content and not mtime and is otherwise invisible. It is the check that
holds when the other two do not, and it keeps the password with the person (§10.2).

**One boundary is deliberate.** The puller keeps a copy it can vouch for; it does not audit
the bucket. A same-size look-alike in the bucket is the box's problem, and
`restic check --read-data` on the box is what finds it.

**What this does not establish: B0.** The machine that exists today has not been backed up,
because it is not reachable from here. The mechanism is proven; the first real backup, the
restore of it on another machine, and the named owner in `notes/` are the operator's to do
before either NVMe is touched.

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
| Everything else | Manual, by re-running `./install.sh`, which is where version pins live (§3) |
| **NVIDIA driver and CUDA** | **Pinned, and never in the unattended set.** A driver that updates under an in-flight training run, or that ships a kernel module mismatched to a running kernel, breaks the GPU quietly. Updated deliberately, followed by B2's acceptance test |
| Kernel | Automatic within the HWE series, and it is the main reason a reboot gets scheduled |
| Reboot required | `/var/run/reboot-required` is surfaced **on the dashboard**, never acted on automatically. §2.1's passphrase means an automatic reboot would take the machine offline until someone visits it |

### 11.3 Pinned CLI refresh

The four agent CLIs are pinned (§4). They are refreshed **deliberately, together, and
followed by B6's acceptance test** (which is where CLI acceptance lives), because a silent auto-update to an agent CLI changes
behaviour mid-task. A monthly check that reports what is behind, without applying it, is
enough.

### 11.4 Rollback

btrfs snapshots of `@` are taken before the install script runs and before a manual apt
upgrade, retained for 30 days. Rolling back is a boot-time subvolume swap. **This is not a
substitute for backup** (§10): the snapshots live on the same striped array that a drive
failure destroys.

**The `/boot` archive mechanism below is experimental until B7a passes, and is labelled so
here rather than only in §12.** Restoring `/boot` alongside a subvolume swap is a
destructive transaction across two resources that cannot be made atomic: the subvolume swap
and the `/boot` restore either both happen or the machine boots a kernel whose modules are
missing. Until it has been exercised across a real kernel change, treat rollback as a thing
to attempt with recovery media to hand, not as a routine undo.

**A snapshot of `@` alone is inconsistent across a kernel change, and that has to be handled
rather than discovered.** `/boot` is a separate ext4 partition (§2.1) and is not part of any
btrfs snapshot. So rolling `@` back to before a kernel upgrade restores the old
`/lib/modules` while `/boot` still holds only the new kernel: the machine boots a kernel
whose modules are gone, which on this design means no `md`, no `dm-crypt`, and no root.

The rule that avoids it: **`/boot` is archived into the snapshot at the moment the snapshot
is taken**, as a tarball under `@snapshots/<id>/boot.tar`, and a rollback restores both. It
costs a few hundred megabytes per snapshot and removes the failure entirely.

Two consequences worth stating. Ubuntu keeps several kernels in `/boot` already, so the
common case survives a rollback without this; the case that does not is a rollback after
`apt autoremove` has pruned the old kernel. And a rollback is therefore **not** a pure
subvolume swap, so §12's B-series should exercise one across a kernel change specifically,
rather than a rollback in general.

## 12. Build order

Each milestone has an exit test, not a judgement, except where a judgement is the point and
is labelled as one. **Nothing destructive happens until V4 and B0 both pass.**

The shortest sensible path: **prove V4 → establish the protected backup → build the
installer framework → plain console plus SSH → install the Tensorbook → use it for several
days → add NVIDIA and workloads one at a time.** That keeps the "stock Ubuntu plus a
script" simplicity while protecting the two places where the simplicity ends, which are
destructive storage setup and recovery.

### Before either NVMe is touched

| # | Milestone | Exit test |
|-|-|-|
| ~~**S1**~~ | ~~Does `restic` work against the HF S3 gateway?~~ | ✅ **Done 2026-09-02, and it changed the design** (§10.5). Direct S3 cannot `init`; `restic` over `rclone` passes all seven steps including restore-and-diff and `prune`. `rclone` is now a dependency |
| ~~**S2**~~ | ~~Rehearse the storage install in a VM~~ | ✅ **Done 2026-09-03.** md/LUKS/btrfs/`/boot`/unlock all work; **curtin creates no subvolumes** (§2.1.2). Superseded by V4 |
| ~~**V4**~~ | ~~The subvolume migration, proven~~ | ✅ **Done 2026-09-04**: three consecutive installs, 21/21 storage checks, 30/30 fixture checks, refusal paths exercised live. Criteria were: **two clean installs from empty disks.** Root on `subvol=/@`; `/home` and `/srv/models` on their subvolumes; SSH key login works after reboot; every fixture entry survives with content, ownership, mode, link count, symlink target, xattrs and ACLs intact; `fstab`, `crypttab`, md assembly, GRUB and initramfs all verify; a second run of the migration recognises the completed state and exits 0; and an injected failure at each stage either recovers or leaves instructions a person can follow |
| **B0** | **Back up the machine that exists today, and prove the backup is real** | Needs the Tensorbook. Back up `/home` and `/etc` to the bucket, restore to scratch storage on a *different* machine, and diff. Name the second copy's owner in `notes/`. Run one restore **from the second copy**. **Record explicitly that T5 is open** -- a write-capable token on the box can erase the bucket -- and that RAID0 is accepted on those terms |
| ~~**B2**~~ | ~~The second copy, proven~~ | ✅ **Done 2026-09-04** (§10.6): survives a wipe, an empty re-pull, visible corruption, a same-size look-alike and silent local rot; 15 assertions against the real bucket. Owner, schedule, retention, capacity floor, failure alert and RPO are defined in `scripts/backup/README.md` |

**RAID0 stays blocked until B0 passes.** Striping means either drive failing destroys the
volume, so the backup is not a precaution here, it is the only copy.

### The framework, before anything it configures

| # | Milestone | Exit test |
|-|-|-|
| **I1** | `install.sh`, `00-preflight`, `10-base` | A fresh Ubuntu run succeeds; an immediate second run changes nothing; a failed module stops the ones after it; re-running just the failed module works; unsupported OS and architecture fail **before any mutation**; a concurrent run is refused; existing user configuration is backed up or preserved; a machine-readable run record is written |
| **C1** | The plain console slice | tty1 presentation, tty2 recovery getty, local PAM login, a `cdl` launcher offering status/workspace/shell, key-only SSH, and separate local and remote workspaces. **The test is simultaneous local and SSH use**, including non-interactive `ssh host cmd`, `scp`, `rsync` and git-over-SSH: none may enter the launcher (§9.3) |

**`kmscon`, ligatures, palette generation, the logo and the dashboard are deliberately not
in C1.** They sit on top of a console that has to be reliable first, and every one of them
is a thing that can fail between a person and their recovery shell.

### The machine

| # | Milestone | Exit test |
|-|-|-|
| **H1** | Tensorbook base install | Only after V4 and B0. LUKS unlock at the machine, console login, SSH, both NVMe devices present with SMART monitoring, suspend disabled and lid/power behaviour correct, `/proc/acpi/wakeup` showing XHCI disabled. **Recovery media stays physically available.** Then stop |
| **H1a** | Network exposure is what the spec says | From off-tailnet: SSH, dashboard and model port all refused. From on-tailnet: SSH and dashboard accepted. Jupyter bound to localhost and **not** reachable from another device even on the tailnet |
| **H2** | **Live with it** | Several days of real work over SSH before any ML component is added. This is a judgement, and it is the one that decides whether the rest is worth building |
| **G1** | NVIDIA, CUDA, PyTorch | `nvidia-smi` reports the 3080 and `torch.cuda.is_available()` returns true **after a reboot**, not only after install. CPU and GPU telemetry running, and a thermal soak measured. **§2.3's temperature and VRAM thresholds are replaced with recorded numbers** |
| **M1** | Ollama | A model answers on `11434` from **another device** on the tailnet. Record cold-load time, peak and idle VRAM, tokens/sec, the effect of context length, CPU and GPU temperature, power, remote latency, and behaviour under concurrent requests |
| **S3** | **Can one stored copy serve both servers?** (§5.2) | Hand an Ollama blob to `llama-server` for the exact quantisation in use. Pass means one copy; fail means storage is doubled and the spec says so |
| **M2** | `llama-swap` | **Only if a concrete Responses or Anthropic-compatible requirement cannot be met by Ollama.** Codex talks to `llama-server` over Responses on `8081` |
| **A1** | Agent CLIs and the GPU training lifecycle | All four CLIs launch, authenticate and run a trivial task with per-process credentials. Claude Code's phone steering still works (§4.1). Then `cdl-gpu train` names the services it will stop, stops them, holds the GPU, and **restarts exactly those it stopped** on normal exit, non-zero exit, signal termination and `SIGKILL` -- the last being the case a shell trap would miss |
| **B7** | Backup, on the new machine | Restore `/home` to a scratch directory and diff. Confirm the second copy is still pulling, and run one restore **from the second copy** |
| **B7a** | Rollback across a kernel change | Snapshot, upgrade the kernel, `apt autoremove` the old one, roll back. The machine must boot: `/lib/modules` and `/boot` have to agree, which is what §11.4's `/boot` archive exists for and what a plain subvolume swap fails |
| **S4** | **Does `kmscon` shape ligatures on the real panel?** (§9.6) | Start `kmscon` on tty1 against the Intel iGPU with the NVIDIA driver loaded, display `=>`, `!=` and `->`, photograph the screen. Failure costs ligatures, not the design |
| **P1** | Presentation and observability | `kmscon` with Fira Code, palette generation, Plymouth branding, the read-only dashboard checked from a phone, backup and update notices, SMART and thermal alerts. Panels match the machine's real state and no write actions exist |
| **B9** | Provisioning reproduces the machine | `install.sh` runs clean on a fresh VM, then runs again and changes nothing. With V4's installs, that is the whole reproducibility claim |

**H1 through H2 is the decision point.** If the machine is not pleasant to work on over SSH,
that needs finding out before the model-serving and agent layers are built on top of it.

## 13. Open questions

| # | Question | Why it is open |
|-|-|-|
| 1 | Which machine holds the second backup copy? | **Half answered.** How often, retention, capacity, alerting and RPO are defined (`scripts/backup/README.md`, §10.6). *Which machine*, and *whose name goes in `notes/`*, remain the operator's to state -- the repository is public and does not name people |
| 2 | Can one stored copy serve both Ollama and `llama-server`? | **S3 in §12.** Decides whether `/srv/models` holds one copy of a model or two |
| 3 | Are `croft` and the Emacs LLM integration still wanted? | Both came from the original requirements list, which predates the console-first decision |
| 4 | Is a UPS worth buying? | §7.1: it converts the commonest cause of an unattended reboot from an office trip into nothing. Cheap, and outside this spec |
| 5 | Which GPU drives an external display, if one is ever attached | Deferred from M0. The console is text-only, so this only matters if a monitor is ever attached |
