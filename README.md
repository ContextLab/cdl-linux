# cdl-linux

A reproducible workstation configuration for Ubuntu Server 26.04, optimised for local and
remote agent work, model serving, and GPU training. In practice: one script that turns a
stock machine into that workstation, and runs again without changing anything.

It carries four agent CLIs (Claude Code, Codex, Gemini CLI, OpenCode), Ollama and
`llama.cpp` for serving models, a CUDA + PyTorch environment, Tailscale and key-only SSH
for reach, a read-only web dashboard, and a console configured to be pleasant: Fira Code
with ligatures on the machine's own screen, one palette everywhere, the lab's logo at boot.

**It is not a distribution.** No custom ISO, no package archive, no support promise. The
repository is public and contributions are welcome; guarantees are not offered.

## Two ways to install

| Mode | What it is |
|-|-|
| **Portable** | `./install.sh` on an existing Ubuntu Server 26.04. Storage is left exactly as it is. This is the mode that works on anyone's machine |
| **Appliance** | Install Ubuntu from `install/autoinstall/tensorbook.yaml` first, to get the striped, encrypted btrfs layout, then `./install.sh`. Specific to a two-NVMe Tensorbook; all of the destructive risk lives here. Read `install/autoinstall/README.md` before touching it |

```bash
git clone https://github.com/ContextLab/cdl-linux && cd cdl-linux
sudo ./install.sh              # everything, in order
sudo ./install.sh --list       # see the order
sudo ./install.sh --module 50-console   # re-run one
```

Modules refuse rather than guess: the script stops on an unsupported release or
architecture before changing anything, GPU modules skip themselves on a machine without an
x86_64 NVIDIA GPU, and a module that fails stops the ones after it and prints the exact
command to re-run. There is no uninstall; reinstalling Ubuntu is the documented way back.

## What it installs

| Module | Does |
|-|-|
| `00-preflight` | Ubuntu 26.04, x86_64, root — or stops |
| `10-base` | The packages everything else assumes |
| `15-btrfs-subvolumes` | A guard: the subvolume layout can only be built at install time (see the spec) |
| `20-nvidia` | Driver, CUDA, persistence daemon, power cap |
| `25-ml` | `uv`, a shared PyTorch venv at `/opt/cdl/ml`, `cdl-ml-check` |
| `30-models` | Ollama on `11434` (tailnet + localhost), `llama-swap` → `llama-server` on `8081` (localhost), each as its own hardened service user; `cdl-models` |
| `35-gpu-lock` | `cdl-gpu train -- …`: exclusive GPU, stops the model servers, restarts exactly those it stopped — even if the job is `SIGKILL`ed |
| `40-agents` | Codex, OpenCode, Gemini CLI as pinned, checksummed binaries; Claude Code via its vendor installer on first use; `cdl-agent` builds each one's credentials per process |
| `45-remote` | Tailscale, key-only SSH (`AllowGroups cdl`, verified with `sshd -T`), mosh, `cdl-net-check` |
| `50-console` | Palette, Fira Code + Nerd symbols via `kmscon` on tty1 (tty2 stays plain), zsh prompt, zellij layout, `/etc/issue`, the `cdl` launcher, GRUB and Plymouth branding |
| `55-dashboard` | One read-only page, bound to the tailnet, authenticated by `tailscale whois` |
| `60-backup` | `restic` nightly over `rclone`; unconfigured until you say where |

After login, type `cdl`. It is never started for you: a launcher in `.profile` would capture
`scp`, `rsync` and git-over-SSH.

## Verifying it

```bash
tests/run-all.sh      # fast: lint, every module's unit tests, the seed validator
tests/run-vm.sh       # a full install, reboot, storage and fixture checks, then install.sh
                      # on the booted machine, every module's own verifier, and a second
                      # run that must change nothing
```

## Where the reasoning is

- `docs/superpowers/specs/2026-09-02-cdl-box-design.md` — the design, with what was
  measured and what was decided
- `docs/whitepaper.md` / `docs/pdf/cdl-box-whitepaper.pdf` — the short version, for readers
  deciding whether to build it
- `notes/` — session notes, including every VM run and what it cost
