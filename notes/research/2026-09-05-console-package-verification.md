# Console stack: package availability in Ubuntu 26.04, verified 2026-09-05

Method: no container. Docker Desktop's daemon on this Mac hangs mid-start (two probes
killed at 120 s and 30 s), so package existence was established by fetching the real
archive indices and grepping them:

```
http://archive.ubuntu.com/ubuntu/dists/resolute/Release      -> Version: 26.04
http://archive.ubuntu.com/ubuntu/dists/resolute/{main,universe,restricted,multiverse}/binary-amd64/Packages.gz
http://ports.ubuntu.com/ubuntu-ports/dists/resolute/{main,universe}/binary-arm64/Packages.gz
http://archive.ubuntu.com/ubuntu/dists/resolute/Contents-amd64.gz
```

`resolute` is 26.04 — confirmed from the suite's own `Release` file, not assumed from the
alphabet.

## The S4 question: is `kmscon` in 26.04?

**Yes.** `kmscon 9.3.2-1`, in **universe**, on both amd64 and arm64.

**S4 (§12) is NOT blocked, and the fallback branch was not needed.** What is now
established, and what still is not:

| Established | How |
|-|-|
| The package exists on both architectures | archive index |
| `mod-pango.so` ships in it | `dpkg-deb -c` on the real .deb |
| `font-engine=pango` is a real option | `kmscon.conf(5)`, extracted from the .deb |
| `kmsconvt@.service` ships, with `Conflicts=`/`OnFailure=getty@%i` | the unit, read from the .deb |
| The 18 `palette-*` option names | the packaged `/etc/kmscon/kmscon.conf` |

| NOT established | Why not |
|-|-|
| kmscon starts against `i915` on the Tensorbook's panel with the NVIDIA driver loaded | needs the machine |
| pango actually shapes `=>` `!=` `->` into ligatures there | needs the machine and a photograph |

Those two are the whole of S4 and they still need the hardware. Everything that could
make S4 fail for a *packaging* reason has been ruled out.

### One correction to the spec

§9.6 says kmscon is "actively maintained (10.0.0, May 2026)". The archive carries
**9.3.2-1**, and upstream is `github.com/kmscon/kmscon`. The claim that it is in the
Ubuntu archive is correct; the version number in the spec is not what 26.04 ships.

### Two traps found in the packaged unit

1. `kmsconvt@.service` has `[Install] Alias=autovt@.service`. Enabling the **bare
   template** (`systemctl enable kmsconvt@.service`, which is what the package's own
   `README.Debian` tells you to do) makes systemd-logind spawn kmscon on **every** newly
   allocated VT — including tty2, which §9.2 requires to stay an ordinary getty. The
   module enables the `kmsconvt@tty1` **instance** instead.

2. The same unit already declares `Conflicts=getty@tty1.service` and
   `OnFailure=getty@tty1.service`. That *is* §9.6's "if kmscon does not start, tty1 falls
   back to the kernel VT". Masking `getty@tty1` — the obvious way to "make sure kmscon
   wins" — would delete that fallback. The module disables it and does not mask it.

Both are asserted in `tests/test-console.sh` and `tests/vm/verify-console.sh`.

## Everything else §9.5 asks for

Present in 26.04 (amd64): `fonts-firacode 6.2-3`, `zsh 5.9-8ubuntu3`, `git 2.53.0`,
`gh 2.46.0`, `ripgrep 15.1.0`, `fd-find 10.3.0`, `jq 1.8.1`, `htop 3.4.1`, `bat 0.25.0`,
`eza 0.23.4`, `git-delta 0.18.2`, `emacs-nox 30.2`, `nvtop 3.2.0`, `plymouth` +
`plymouth-themes` + `plymouth-label 24.004.60`, `librsvg2-bin 2.61.3`, `webp 1.5.0`,
`kbd 2.7.1`, `fontconfig 2.17.1`.

**Not in the archive: `zellij`.** Hence the pinned release binary.

`nvtop` has **no arm64 build**, so the module installs it only where there is an NVIDIA
GPU — which is also the only place it would report anything.

`setvtrgb` is at **`/usr/sbin/setvtrgb`** (package `kbd`), not `/usr/bin`. The unit names
the absolute path, so this mattered.

## The motd directory

26.04 uses **`/etc/update-motd.d/`**. `/etc/motd.d/` has *no* packaged entries in the
whole 26.04 Contents index. §9.1 writes "`/etc/motd.d/10-cdl`"; the module installs to
`/etc/update-motd.d/10-cdl`, which is the one pam_motd actually runs on this release.

Noise scripts confirmed to exist and be worth silencing: `10-help-text`, `50-motd-news`
(both `base-files`), `60-ubuntu-server-tip` (`fortunes-ubuntu-server`),
`91-contract-ua-esm-status` (`ubuntu-pro-client`). `90-updates-available`
(`update-notifier-common`) is **kept**: §11.2 wants update notices.

## Pinned artefacts, checksums computed by downloading them

| Artefact | Version | sha256 |
|-|-|-|
| `zellij-no-web-x86_64-unknown-linux-musl.tar.gz` | 0.45.1 | `d7bda1e18c30a688833ae7627f1d6a253bbba5349a4bc48e4f0ec008aaf75ed1` |
| `zellij-no-web-aarch64-unknown-linux-musl.tar.gz` | 0.45.1 | `7c0725cd433299eaf171d673df3b8e7ceceae1b06f8265ba552ff3b9c3c82ea0` |
| `NerdFontsSymbolsOnly.zip` | 3.5.1 | `fdca3682534f6f65e1ccb2345b0362ccf67d9b8eca7c8025330946e93e2473bc` |
| `CDL_Avatar.png` (actually WebP) | n/a | `3d75ca7e3181175d900f55a1c031bb1c526f1f8fbb99ebb09debb6bf43311e6c` |

**Upstream's `.sha256sum` files do not cover the tarballs.** They cover the *binary inside*
them: `zellij-no-web-x86_64-unknown-linux-musl.sha256sum` contains
`0ec6ef07…  target/x86_64-unknown-linux-musl/release/zellij`. A first comparison against
the tarball looked like a checksum mismatch and was not one. Both values are pinned: the
tarball's, which `cdl_fetch_verified` checks on download, and the binary's, which the
module checks after extraction because it is the one upstream actually attests to.

The **`no-web`** zellij build is used deliberately: the default build embeds a web server,
and §7.2 ("being on the tailnet is not authorisation") is cheapest to honour by not
installing a listener nobody asked for.

## The logo

`https://context-lab.com/images/CDL_Avatar.png` is **WebP despite the `.png` name** —
533×533, RGBA, 1316 bytes. Decoded and inspected: it is the 3×3 green-squares avatar, and
`#00703c` is its third most common colour, which corroborates the accent choice.

It is **fetched at install time, not committed.** `ContextLab/contextlab.github.io` is MIT
with no separate asset grant; a public repository should not redistribute a lab's mark on
the strength of an inference about licensing. `install/assets/cdl-logo.svg` is a
self-identifying placeholder used only if the download fails its checksum, because
Plymouth with no image is a black screen and a black screen is indistinguishable from a
hang.
