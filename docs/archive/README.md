# Archive — frozen, superseded, kept for reference

**Frozen 2026-09-02. Nothing in this directory is being built.**

These documents describe a larger system than the project actually needs: a full
multi-provider agent orchestration layer, running on a custom Linux distribution with its
own display session. The design work is sound and it was reviewed hard (six rounds, three
of them by cold reviewers). It is archived because the **scope was wrong**, not because the
content is.

## What changed

The scope was set by D28 — *"5–10 API agents + 1–2 local + 2–4 on the GPU host"* — which
was recorded as a requirement when it was closer to an upper bound. Designing against
sixteen concurrent units across three machines is what produced the state machine, the
registry, the reconciliation ladders and the two-phase remote launch protocol.

What the project actually needs is **a headless model-and-agent workstation**: a minimal
Ubuntu Server install on the Tensorbook, carrying the agent CLIs and local model serving,
reachable over SSH and Tailscale, serving models to other devices. That is specified in
`docs/superpowers/specs/2026-09-02-cdl-box-design.md`, which supersedes everything here.

## The decision that cascades

**The machine is headless.** No compositor, no session lock, no autologin, no keybindings,
no display stack. SSH is the interface. That single choice retires a large amount of the
risk in these documents:

| Retired | Why |
|-|-|
| Spike 1 (cage + kitty + swaylock) | There is no display session to lock. Research had already found cage ships no session-lock protocol, with the upstream issue open. |
| D34 (minimal sway as the T2 default) | Same. |
| D29 (hibernation as a launch requirement) | An always-on server does not hibernate. This also retires the Secure Boot ↔ `integrity` lockdown conflict and the §3.2 branch. |
| D36 (136 GiB swap) | Sized for hibernation, which is gone. |
| The custom remix ISO | A re-runnable provisioning script against a stock install is reproducible enough and far cheaper. |

## What carried forward

Small, and named explicitly so nobody re-derives it:

- **Per-process provider credentials.** Claude Code's phone-steering refuses to run when
  `ANTHROPIC_BASE_URL` points anywhere but the vendor endpoint, so a global gateway would
  silently remove a paid-for capability. Measured, not assumed.
- **One local inference endpoint** rather than several competing servers.
- **Pinned agent CLI versions**, and the licence finding that Claude Code carries no
  licence field and cannot ship in an image.
- **The `cdl status` idea**, which becomes the web dashboard.
- **The hardware profile** (`notes/hardware/`), which stays live and is not archived.

## Contents

| File | What it is |
|-|-|
| `2026-08-31-cdl-design.md` | The product/architecture overview, revision 2.3. Frozen. |
| `2026-09-01-cdl-agent-lifecycle-design.md` | The agent lifecycle component spec, draft 6. The most heavily reviewed document here. |
| `2026-09-02-agent-orchestration-whitepaper.md` | A 2,400-word note written for outside review of the orchestration design. |

If the orchestration layer is ever built, start from the lifecycle spec rather than from
scratch: its state machine, ownership rules and recovery semantics survived five review
rounds and two live-data-loss bugs were found and fixed in them.
