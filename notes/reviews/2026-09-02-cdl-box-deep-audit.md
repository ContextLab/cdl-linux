# CDL Linux design deep audit

**Date:** 2026-09-02  
**Audience:** project owner and future implementers  
**Decision:** how to revise `cdl-box` into a standalone, installable, branded Ubuntu
Server-derived distribution with equally supported local and SSH interaction.

## Executive conclusion

The project should no longer be described as a headless Ubuntu installation plus a
provisioning script. The desired product is an **Ubuntu-based appliance distribution**:
it has its own bootable installer ISO, identity and boot presentation, package set,
configuration defaults, release artifacts, update channel, recovery path, and acceptance
tests. It remains server-shaped rather than desktop-shaped.

The best v1 architecture is:

1. Start from a pinned official Ubuntu Server 26.04 LTS point-release ISO.
2. Produce a declaratively remastered hybrid ISO using Canonical's `livefs-editor`, rather
   than forking Ubuntu's whole image-production stack immediately.
3. Retain Subiquity. Make the interactive installer the default and place any destructive
   unattended profile behind a separately labelled boot entry and hardware guard.
4. Put CDL behavior in signed `.deb` packages (`cdl-base`, `cdl-branding`,
   `cdl-console`, `cdl-services`, `cdl-release`, and `cdl-archive-keyring`) rather than in
   a growing collection of installer `late-commands`.
5. Preserve Canonical's signed shim, GRUB, kernel and module path. Brand configuration and
   artwork, not the signed binaries.
6. Make the default local interface a branded but authenticated text console: Plymouth and
   LUKS prompt, stock getty/PAM login, then an optional `cdl` home screen for status and
   Zellij workspace selection. Keep a plain recovery getty on another VT.
7. Treat SSH as a peer interface to the same account and tools, not as the only real
   interface. Separate local and remote Zellij workspaces by default; attaching both clients
   to one workspace must be deliberate and visible.
8. Use a signed CDL APT repository with staging and stable suites for ongoing updates. The
   ISO is bootstrap and recovery media, not the update mechanism.

This preserves the valuable parts of the existing design—Ubuntu LTS, Secure Boot, minimal
services, measured hardware constraints, explicit backup risk, per-process provider
credentials, and staged validation—while correcting its product boundary.

## Scope and assumptions

This audit assumes a single primary operator, one TensorBook target initially, Ubuntu
Server 26.04 LTS as the package base, Secure Boot enabled, and no requirement for a full
desktop. “Local interaction” is interpreted as a high-quality physical-console workflow,
not necessarily Wayland applications. If a browser, graphical Emacs, or local Jupyter UI is
required, that becomes an optional graphical profile with a separate threat and resource
model.

There is a material legal fork: Canonical permits modification for personal/internal use,
but its policy places additional requirements on redistribution of modified Ubuntu and use
of Ubuntu trademarks. Decide **internal appliance image versus public distribution** before
publishing an ISO. A public CDL image needs a trademark/licensing review, debranding and
source-compliance plan, or Canonical permission. See [Canonical's intellectual-property
policy](https://canonical.com/legal/intellectual-property-policy).

## Findings requiring design changes

### Critical: the declared product is the opposite of the wanted product

The current design says “Not a custom ISO,” makes SSH the interface, and uses a stock
installer followed by provisioning. The whitepaper repeats those statements as the central
reason the system is simple. They are not isolated stale sentences: they drive the current
build order, local-security model, test harness and release story. Both documents require a
new thesis, not amendments.

Replace “headless” with **console-first, remotely accessible**. A system can have no desktop
and still provide a first-class local interface. Replace “script, not image” with **image
plus packages plus reproducible build**, while retaining idempotent provisioning for repair,
development and migration.

### Critical: a remastered ISO alone is not a distribution

A durable distribution requires six owned outputs:

- installer ISO and recovery media;
- signed CDL packages and metapackages;
- signed repository metadata and update channels;
- release manifest, checksums, signatures and SBOM;
- upgrade/rollback and support policy;
- installation, recovery and release-test documentation.

Canonical documents its full production path as `livecd-rootfs` followed by
`ubuntu-cdimage`, while its 2026 Image Cookbook recommends declarative `livefs-editor` for
customized installer images because patching the production tools is error-prone. Use the
lighter path first and keep the full seed/live-build pipeline as a later option. Sources:
[Create an installer image](https://ubuntu.com/hardware/docs/image-cookbook/howto/images/create_installer_image/)
and [Customize an installer image](https://ubuntu.com/hardware/docs/image-cookbook/howto/images/customize_installer_image/).

Do not select Cubic for release builds: it is convenient interactively but is not a strong
CI/reproducibility foundation. Packer may test an ISO by producing VM disks; it is not the
ISO factory. `ubuntu-image` deserves a bounded spike because its newer schema mentions
installer artifacts, but Canonical's current installer recipe still points elsewhere.

### Critical: installer personas and secret flow are missing

The current VM autoinstall is correctly labelled as test-only, but it cannot become the
product installer: it fixes disk paths, hostname, username, LUKS key and SSH password.
Curtin also warns that a `dm_crypt.key` appears in plaintext configuration and is copied to
the target. The product must never embed a reusable password, private SSH key, Tailscale
credential, provider key, backup credential or production LUKS secret.

Ship two explicit boot paths:

- **Install CDL** (default): interactive identity, local password, network and destructive
  storage confirmation; sensible CDL defaults fill the remaining screens.
- **Automated factory install—erases disks**: non-default, requires external NoCloud data or
  an explicit confirmation token, verifies exact disk model/serial/capacity, and aborts on
  mismatch.

Subiquity supports `interactive-sections`, embedded media configuration, schema validation,
and NoCloud delivery. Keep persistent configuration in packages and keep `late-commands`
thin. Sources: [Autoinstall reference](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html),
[configuration delivery](https://canonical-subiquity.readthedocs-hosted.com/en/latest/tutorial/providing-autoinstall.html),
and [Curtin storage](https://curtin.readthedocs.io/en/latest/topics/storage.html).

The installer itself exposes a temporary SSH route in standard Ubuntu Server media. Treat
installer SSH and installed-system SSH as distinct security surfaces; document the former's
LAN exposure and root-equivalent privilege.

### Critical: the VM storage harness does not implement the specification

The autoinstall creates one btrfs filesystem mounted at `/`; it does **not** create `@`,
`@home`, or `@models`. The verifier only checks the filesystem type and therefore passes a
layout that contradicts the design. It also enables SSH password authentication for the
test VM, while the production policy requires keys only, and the ARM-first direct-kernel
boot bypasses the ISO's GRUB/shim/branding/Secure Boot path.

Fix the harness in layers:

1. Storage test: create and mount the promised subvolumes; verify subvolume IDs, mount
   options, `/etc/fstab`, crypttab UUIDs, md metadata, initramfs contents, swap behavior and
   degraded/failure behavior.
2. Installer test: boot the actual ISO via UEFI, exercise interactive and automated paths,
   and confirm no production secret is present.
3. Distribution boot test: verify branded GRUB and Plymouth, text fallback, LUKS entry,
   local login, SSH, recovery menu and Secure Boot state.
4. Architecture test: run amd64 before hardware. ARM remains useful for fast storage
   iteration but cannot validate the target boot chain.
5. Hardware test: Secure Boot on, NVIDIA installed, local panel and external connectors,
   network, power loss, wrong LUKS passphrase, missing RAID member and recovery media.

Replace `/dev/vda` assumptions in production configuration with guarded stable identity.
Put the ESP on both physical drives if bootability after loss of the ESP-bearing drive is a
goal—but note that RAID0 still makes the root filesystem unusable after either member fails;
the second ESP helps only with diagnostics/recovery, not service continuity.

### Critical: the GPU lock cannot work as specified

The design says inference services hold shared locks for their lifetimes and training takes
an exclusive lock. Therefore training can never acquire its lock while either inference
server is running. It simultaneously promises that an already-resident model continues
serving while training owns the exclusive lock, which is impossible under that protocol.

Choose one honest policy:

- **Exclusive workload policy (recommended initially):** training acquisition stops model
  servers cleanly, takes the lock, runs, then restarts them. Predictable, but inference is
  unavailable during training.
- **Admission lock only:** briefly lock model load/unload and training start, then use
  measured free VRAM admission rather than a lifetime lock. Existing inference may coexist,
  but out-of-memory risk remains and must be tested.
- **Explicit partitions/containers:** only if later hardware and NVIDIA support provide a
  real enforceable isolation mechanism worth the complexity.

Revise B5 to match the selected policy. A lock file cannot reliably contain one “holder”
when multiple shared holders exist; keep holder records separately under `/run/cdl/gpu/` or
query systemd process metadata.

### High: design a local console, not merely local login

Recommended default journey:

```text
firmware/OEM screen
  -> branded GRUB menu (visible recovery entry)
  -> branded Plymouth + integrated LUKS prompt
  -> branded getty on tty1
  -> stock PAM authentication
  -> optional `cdl` home screen
       status | create workspace | attach workspace | maintenance | plain shell
```

Keep tty6 (or tty2) as an unmodified recovery getty. Do not autologin. Do not unconditionally
launch Zellij from `.profile`, because that also catches noninteractive SSH/scp workflows
unless carefully guarded and makes recovery harder. A post-login `cdl` launcher should
always offer a plain-shell escape.

Local login needs a strong Unix password even when `sshd` has password authentication off.
Use separate SSH authorization (`AllowGroups`, no root login, Ed25519 keys) and test effective
configuration with `sshd -T`. Logout is the safest unattended-console lock. Screen blanking
is not locking, and `loginctl lock-session` only works when the session implements locking.
If a TTY lock is required, `vlock` for the current VT is safer than locking every VT.

Zellij supports multiple clients on one session, which also means either client can see pane
contents and inject input. Default to separate local and remote sessions; expose “attach
shared” explicitly and show connected clients. Keep viewport/scrollback resurrection off by
default, protect logs and cache as secrets, audit plugins, and never put credentials in command
arguments or pane output. Relevant upstream references: [Zellij commands](https://zellij.dev/documentation/commands),
[session resurrection](https://zellij.dev/documentation/session-resurrection.html), and
[plugin permissions](https://zellij.dev/documentation/plugin-api-permissions).

An optional graphical profile can use an authenticated greeter, a minimal Wayland compositor
and terminal/dashboard, preferably on the Intel iGPU. It must be separately installable,
must retain the recovery VT, must implement a real screen lock, and must be benchmarked for
VRAM/KMS/NVIDIA-update interference. Cage is a one-application kiosk, not a local workstation
shell. Do not make this profile a v1 dependency unless local graphical applications are an
explicit requirement.

### High: branding is a chain, not one splash image

Specify and test each visible stage independently:

- firmware/BGRT OEM logo: normally outside CDL's control;
- shim and MokManager: retain Canonical behavior;
- GRUB menu/background: CDL theme with an obvious diagnostics/recovery path;
- kernel/initramfs: CDL Plymouth theme including LUKS prompt and text fallback;
- installer: CDL title, help, warnings and defaults around Subiquity;
- installed console: `/etc/issue`, hostname policy, login and `cdl` home screen;
- shell, dashboard, documentation and package metadata.

GRUB supports themes and backgrounds but warns that early graphics modes can fail; retain a
text path. Plymouth runs in the initramfs, supports password prompts, hides logs, exposes them
with Escape, and falls back to text without KMS. Sources: [GRUB configuration](https://www.gnu.org/software/grub/manual/grub/html_node/Simple-configuration.html)
and [Plymouth architecture](https://wiki.freedesktop.org/www/Software/Plymouth/).

Branding configuration and artwork do not require replacing signed boot binaries. Ubuntu's
Secure Boot chain is Microsoft-signed shim, Canonical-signed GRUB, Canonical-signed kernel,
and signed kernel modules; the initrd is not validated in the described GRUB chain. Do not
claim full verified boot. Source: [Ubuntu Secure Boot](https://documentation.ubuntu.com/security/docs/security-features/platform-protections/secure-boot/).

### High: release, package and update ownership is absent

Create package boundaries early:

- `cdl-archive-keyring`: repository trust anchor and rotation;
- `cdl-release`: `/etc/os-release` policy, repository definitions and release identity;
- `cdl-base`: dependency-only base metapackage;
- `cdl-branding`: GRUB, Plymouth, issue/MOTD and assets;
- `cdl-console`: launcher, Zellij layouts and local UX;
- `cdl-services`: dashboard, thermal, backup and GPU units;
- `cdl-ml`: NVIDIA/CUDA/PyTorch policy and compatibility metadata;
- optional `cdl-graphical` profile.

Use repository-specific `Signed-By`, an offline root key and restricted release-signing
subkey, documented rotation/revocation, and separate staging/stable suites. Promote identical
artifacts rather than rebuilding them. Publish ISO SHA256 and detached signature, package and
source manifests, upstream ISO digest, build-tool/container versions and an SBOM.

Ubuntu 26.04 LTS receives standard maintenance through May 2031, but the standard guarantee
is not identical for `main` and `universe`; do not promise five-year security coverage for
the entire CDL package set without qualification. Sources: [Ubuntu releases](https://documentation.ubuntu.com/project/how-ubuntu-is-made/concepts/ubuntu-releases/)
and [release list](https://documentation.ubuntu.com/project/release-team/list-of-releases/).

Keep Ubuntu security updates and phasing. Add a CDL canary test before promoting updates.
NVIDIA, CUDA, kernel and PyTorch require an explicit compatibility matrix—not indefinite
holds. Preserve at least one known-good kernel/initramfs and test MOK enrollment or prefer
Canonical prebuilt signed NVIDIA module packages where possible.

### High: rollback is still only a slogan

“Boot-time subvolume swap” does not define a safe rollback. Specify snapshot creation,
naming, read-only state, retention, cleanup under disk pressure, selection at boot, writable
clone creation, `/boot` and package-database consistency, failed-upgrade detection,
confirmation/finalization, and forward recovery. Because `/boot` is outside the root
subvolume, rolling root back across a kernel/initramfs update can produce a mismatch.

Either build and test a complete btrfs rollback transaction or reduce the promise to
“snapshots support file recovery.” The latter is safer for v1. Recovery media plus package
reinstallation and restic restore may be a more honest disaster path than clever bootable
snapshots.

### High: backup is functional but not yet protected

The repository correctly proves restic-over-rclone works with an HF Storage Bucket and
correctly states that the bucket lacks versioning, lifecycle rules and deletion protection.
HF's current documentation confirms those limitations. Sources: [Storage Buckets](https://huggingface.co/docs/hub/storage-buckets)
and [S3 compatibility](https://huggingface.co/docs/hub/storage-buckets-s3).

The “second machine pulls with `copy`” mitigation needs an operational contract: owner,
schedule, maximum recovery-point gap, retention, encryption at the second destination,
capacity alert, pull-failure alert, periodic `restic check --read-data-subset`, and restore
drill. Merely never deleting files may grow forever and does not prove repository consistency.
Prefer a destination with snapshots/object lock if available. Until that exists, state that
T5 remains open and block destructive installation on B0.

Do not embed backup or HF credentials in the ISO. First-run enrollment should write root-only
credentials, test access, and make redacted status visible. Review whether `/etc` really needs
raw backup or whether package state plus an allowlisted configuration set is safer and easier
to restore across releases.

### High: networking and dashboard authentication need sharper boundaries

Binding only to a current Tailscale address is operationally brittle when the interface/address
is absent at service start. Prefer service ordering plus firewall policy, or bind locally and
publish through a controlled Tailscale mechanism. Define behavior before Tailscale enrollment,
during reauthentication, and on LAN-only recovery.

For the dashboard, remove the stale assertion that two write actions exist. Define precisely
which `tailscale whois` identity or tag is accepted, proxy/header trust, timeouts and fail-closed
behavior. The model endpoint also needs an explicit authorization decision: “on the tailnet”
is reachability, not necessarily authorization. Use Tailscale ACLs/grants and firewall tests,
and decide whether model prompts/results are acceptable to every tailnet principal.

The local dashboard can be rendered in the `cdl` TUI or opened in an optional graphical
profile; it should not require networking to inspect the machine locally.

### Medium and correctness defects

- §8.2 says the dashboard is read-only while §8.3 still describes two write actions.
- §13 still asks whether S1 works even though §10.5 and §12 mark it complete.
- §5.2 points S3 to §11, but S3 is in §12.
- §10.3 says B0/B7 are in §11, but they are in §12.
- §11.3 says CLI updates are followed by B4; CLI acceptance is B6.
- The whitepaper's “Budget” section belongs to the archived orchestrator, not this design.
- The design still mentions a NAS in the early storage discussion after switching to HF.
- `rclone copy` preserves deleted remote objects locally, but without a catalog/retention
  design it is not itself a coherent second restic repository lifecycle.
- “16 GB fits one large model or one large plus one small” is too vague for an acceptance
  criterion. Record model, quantization, context length, KV-cache policy, concurrency and
  measured peak VRAM.
- Thermal control observes CPU package temperature but the GPU is the principal sustained
  workload. Specify independent CPU/GPU thresholds, NVIDIA power/temperature telemetry,
  sensor failure behavior, state persistence and a disable/override path.
- Masking all `systemd-sleep` targets should be tested against lid-close and power-key policy;
  explicitly configure logind rather than relying only on masks.
- Persistent session logs can capture prompts, source code and secrets. Define redaction
  limitations, directory permissions, backup inclusion, rotation semantics and an obvious
  no-log mode.
- “Single-user” should mean one supported human operator, not one Unix account or absence of
  service accounts. Services need least-privilege users, filesystem ownership and systemd
  hardening.
- The PDF is visually clean across all four rendered pages, but it is untagged and therefore
  weak for accessibility. Its thesis, title and most conclusions are obsolete under the new
  requirements; revise the Markdown first, then add PDF metadata/tagging if the toolchain
  permits.

## Proposed replacement specification structure

1. Product definition and non-goals
2. Supported hardware and portability boundary
3. Trust, threat and physical-access model
4. Distribution architecture and package boundaries
5. ISO build, provenance and release process
6. Installer UX, automated install and first boot
7. Storage, encryption, swap and recovery
8. Secure Boot, kernel, NVIDIA and CUDA lifecycle
9. Local console experience
10. SSH, Tailscale, firewall and remote recovery
11. Sessions, agents and credential handling
12. Model serving, training and GPU admission
13. Dashboard and observability
14. Backup, restore and disaster recovery
15. Updates, rollback and support lifecycle
16. Branding and accessibility
17. Validation matrix and release gates
18. Open decisions and deferred profiles

Every requirement should map to an implementation artifact, an owner/package, and an
acceptance test. Keep hardware-measured facts separate from policies and unverified
assumptions.

## Recommended phased plan

### Phase 0 — settle product/legal decisions

- Choose private/internal image or publicly redistributed distribution.
- Name the product without implying Canonical endorsement.
- Define “local” as text console for v1; decide whether graphical apps are required.
- Decide GPU exclusivity policy and backup second-copy destination.
- Freeze v1 supported hardware: TensorBook only, or a small compatibility class.

Exit: revised product statement, threat model, trademark decision and requirement matrix.

### Phase 1 — build distribution foundations

- Create package skeletons and signed local test repository.
- Package branding, console launcher and configuration rather than editing base files ad hoc.
- Build a `livefs-editor` prototype from a pinned 26.04 point-release ISO.
- Emit ISO manifest, hashes, signature and SBOM.
- Add CI checks for package install/upgrade/remove/purge and clean conffile handling.

Exit: ISO boots in amd64 UEFI VM and installs packages exclusively from declared sources.

### Phase 2 — installer and boot experience

- Implement interactive-default and guarded automated entries.
- Collect local password and SSH key separately; keep all secrets external to media.
- Create the full btrfs layout and validate it after reboot.
- Add GRUB/Plymouth/getty branding with Escape/text fallback and recovery entry.
- Test Secure Boot without replacing Canonical-signed boot components.

Exit: two clean amd64 installs are equivalent; no secret appears in ISO, logs or target
configuration; local login and SSH both work after LUKS unlock.

### Phase 3 — local/remote workspace and operations

- Implement `cdl` console home, plain-shell escape and recovery VT.
- Add local and remote Zellij workflows with explicit shared attachment.
- Implement firewall/Tailscale enrollment and recovery behavior.
- Add update channels, reboot/inhibitor reporting, least-privilege services and logging.

Exit: simultaneous local and SSH acceptance suite passes, including detach/reconnect,
logout persistence, key-only SSH, console password, recovery VT and shutdown inhibitors.

### Phase 4 — storage safety and hardware enablement

- Complete B0 protected second copy and restore drill before touching either NVMe.
- Run the ISO on the TensorBook with Secure Boot, md/LUKS/btrfs, iGPU console and NVIDIA.
- Test failure and recovery paths, not just successful boot.
- Establish kernel/NVIDIA/CUDA/PyTorch compatibility matrix and known-good rollback.

Exit: recovery media boots; wrong/missing storage components fail intelligibly; backup
restores; GPU works after kernel and driver reboot.

### Phase 5 — model/agent workload

- Correct the GPU admission protocol before implementation.
- Add Ollama first, measure exact models and thermals, then add llama-swap only for a proven
  API need.
- Add agent CLIs through redistributable packages or first-run vendor installers according
  to each license; never let a non-redistributable binary silently enter the ISO.
- Add credentials, transcript policy, dashboard and training environments.

Exit: workload matrix, thermal soak, concurrent-session tests, credential isolation and
backup exclusions all pass.

### Phase 6 — release candidate

- Perform clean install, upgrade from prior build, interrupted install, offline install,
  recovery, restore and rollback drills.
- Test Secure Boot, text fallback, local and SSH use, and accessibility.
- Cold-review the new spec, installer, release manifest and destructive paths.
- Publish only after legal/branding gate and signature verification instructions pass.

## Release-gate checklist

A release is not ready unless:

- the upstream ISO digest and every extra package source are pinned and recorded;
- the ISO signature, repository signature and SBOM verify independently;
- interactive install is the default and destructive automation is visibly gated;
- the exact target disks are verified before wipe;
- no reusable credential exists in the ISO or repository;
- Secure Boot remains enabled and verified after installation;
- GRUB, Plymouth/LUKS, text fallback and recovery media are tested;
- local authenticated login, recovery VT and key-only SSH all work;
- simultaneous local/remote sessions cannot accidentally share input;
- storage subvolumes match the spec and the verifier checks them;
- the backup second copy and restore drill predate destructive installation;
- kernel/NVIDIA/CUDA/PyTorch compatibility is tested after reboot;
- update, upgrade, downgrade and package-removal paths are exercised;
- failed network/Tailscale/HF/GPU sensor states fail safely and visibly;
- all stale spec references and the whitepaper are regenerated from the revised design.

## Validation performed for this audit

The current spec checker reports all 38 syntactic section references as resolving, but the
manual audit found semantically wrong references listed above. All three existing repository
test suites pass; they primarily cover hardware capture and the archived orchestration schema,
not the new distribution. Shell syntax passes. The VM harness was reviewed statically but not
executed because doing so requires downloading a multi-gigabyte ISO and a long QEMU install.
All four PDF pages were rendered and visually inspected; no clipping or overlap was found.

Research stopped after the installer/distribution, Secure Boot/branding, local-console,
backup, storage and release-lifecycle claims had primary-source support and the remaining
uncertainties were hardware experiments or product choices rather than discoverable facts.
