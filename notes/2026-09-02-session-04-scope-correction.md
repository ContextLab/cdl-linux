# Session 04 (2026-09-02) - scope correction

## What happened

The user read the whitepaper and said the scope was much larger than what they had pictured.
What they actually want: a minimal Ubuntu Server install on the Tensorbook carrying the four
agent CLIs, Ollama, local model serving and fitting, some remote tools, and CLI theming.
Something to keep running, SSH into, and serve models from to other devices.

They also observed that the orchestration system described in the whitepaper probably needs
its own GUI rather than being purely TUI-based, which is correct and is why the dashboard is
in the new spec.

**The scope error was mine.** D28 ("5-10 API agents + 1-2 local + 2-4 on the GPU host") was
recorded as a requirement when it was closer to an upper bound the user named in answer to a
question I posed. Designing against sixteen concurrent units across three machines is what
generated the state machine, the registry, the reconciliation ladders and the two-phase
remote launch. None of it is needed for the box.

## The decision that cascades

**Headless.** No compositor, no session lock, no autologin, no keybindings, no display stack.
SSH is the interface. That one choice retires:

- spike 1 (cage + kitty + swaylock), which research had already shown was probably unworkable
- D34 (minimal sway) and the T2 threat argument behind it
- D29 (hibernation as a launch requirement), and with it the Secure Boot / lockdown conflict
- D36 (136 GiB swap), which existed only for hibernation
- most of the case for a custom remix ISO

Two new decisions in the same spirit:

- **Do not stripe the drives.** RAID0 doubles the blast radius to buy a few seconds on model
  load. Separate mounts instead, with `/srv/models` on the already heavily-written drive.
- **LM Studio is out.** Checked rather than assumed: the desktop app's headless mode "works
  on Mac, Windows, and Linux machines with a graphical user interface", so it cannot run
  here. Its server-native daemon `llmster` can, but installs by `curl | bash` with no stated
  licence, so it cannot be provisioned. Ollama plus llama.cpp cover serving and are
  redistributable. Recorded as an optional one-line install.

## State

- `docs/archive/` holds the overview, the lifecycle spec and the whitepaper, frozen, with a
  README recording what was retired and the short list of findings that carry forward.
- `docs/superpowers/specs/2026-09-02-cdl-box-design.md` is the new spec. 317 lines against
  the archived 2,318.
- `tests/test-schema.py` still runs against the archived schema deliberately. It is the
  evidence that the archived design was sound, and it costs 0.02s.

## Resume here

1. User review of the box spec.
2. Answer open question 3 (does the NAS run containers, for `rest-server --append-only`)
   before writing the backup module.
3. Then B1: base install, headless, SSH, Tailscale. Exit test is a reboot that comes back
   reachable by name with XHCI wake disabled.
