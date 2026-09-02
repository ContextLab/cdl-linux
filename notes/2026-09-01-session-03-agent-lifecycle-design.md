# Session 03 (2026-09-01): designing `cdl-agent-lifecycle`

Resume item 2 from `notes/2026-08-31-session-02-spec-review.md`. Brainstorming path:
**architectural** (new subsystem, no existing flow in the repo, defines interfaces other
components depend on). Target artefact:
`docs/superpowers/specs/YYYY-MM-DD-cdl-agent-lifecycle-design.md`.

Context read before starting: design overview §7 (commissioning brief), §8 (architecture),
§2.1/D28 (working shape), §9 spike 2 (durable interactive agent), session-02 review findings.
**The overview is frozen** — amend only on new evidence, not to refine wording.

## Design decisions taken so far

### DA1 — Spec scope: the full commissioning brief
*User-chosen, 2026-09-01 (local; UTC 2026-09-02).* The spec covers everything §7 assigns the component: agent **and job**
state machines, PTY ownership and attachment, blocked/waiting/complete detection, exit status,
prompt and launch-command recording, cancellation, worktree ownership and crash reconciliation,
resume without replay, sandbox filesystem and network policy (T4a/T4e), port allocation registry,
SQLite schema and migrations, GPU admission, spend controls (D33), concurrency limits,
`cdl status` output contract, and the local and ssh backend contracts.

Implementation remains sliced: the first executable slice is one local interactive agent, then
spike 2. **Rationale for speccing wide but building narrow:** the schema, state machine and
backend interface are the expensive things to change later, and D28's three locations is
"the single most consequential requirement in the document". Designing them once against all
three locations avoids a rewrite when the GPU host and cloud arrive.

### DA2 — PTY ownership: a cdl-owned supervisor holds the master
*Recommended by Claude, user deferred to the recommendation, 2026-09-01.*

`cdl-agent@.service` runs `cdl-agent-supervisor` as the unit's **main process**. It opens the PTY,
spawns the agent as its child, tees the master through to an append-only log, and serves
attach/detach over a unix socket. `cdl agent attach` is a thin client.

Rejected: **zellij session per agent** — exit status is buried in a pane, scrollback is in-memory
and dies with the session (so the record vanishes exactly when an agent finishes), and it does not
generalise to the ssh backend. **abduco/dtach** — less new code, but logging and exit status remain
separate mechanisms, giving two sources of truth against an authoritative SQLite registry.

**The deciding argument is D28, not the local case.** Agents on the lab GPU host arrive over ssh,
where cdl cannot rely on a multiplexer it does not control. A cdl-owned holder is required for the
remote backend regardless, so using it locally too means one contract and one reconciliation path
instead of two.

**Consequences to carry into the spec:**
- The supervisor is the unit's main process, so systemd reports the *supervisor's* exit, and the
  supervisor is responsible for recording the *agent's* exit status into the registry.
- Logs are files and outlive the agent, satisfying "exit status and logs retained".
- "No prompt replay" is a supervisor guarantee, not an inherited property: the launch prompt must
  never be re-sent on reattach, and `Restart=no` (§8) exists so systemd cannot re-run the task.
- The supervisor must forward `TIOCSWINSZ` on client resize; the kernel line discipline already
  generates SIGINT etc., so signal handling is not the supervisor's job.

## Open questions still to settle

State machine states and transitions · SQLite schema and ownership · crash reconciliation ·
minimum sandbox boundary · blocked/waiting detection · `cdl status` contract · spend controls ·
port allocation · cancellation semantics · worktree retention · job layer and backend split.

### DA3 — Agent CLIs and model providers in scope
*User-chosen, 2026-09-01 (local; UTC 2026-09-02).* Two axes, deliberately separated:

- **Agent CLIs (supervised programs):** Claude Code, Codex, Gemini, OpenCode
- **Model providers (where inference happens):** Ollama, LM Studio, HuggingFace (cloud *and* local)

This is wider than any option offered and rules out a hard-coded single-vendor supervisor. The
adapter interface is therefore load-bearing, and the spec must state which (agent × provider)
pairs are supported rather than implying all of them.

### DA4 — Local serving: one endpoint, many models (llama-swap)
*User-chosen, 2026-09-01 (local; UTC 2026-09-02).* Reconciles §8's "one inference server ... behind a `flock` semaphore",
which three competing servers would have contradicted. Ollama / LM Studio / HF become **model
sources** (places weights come from), not competing servers.

Reconciles §7.1's orphaned "llama-swap rationale". Research (round1-digest.md:375, verbatim):
"Hot-swaps models behind a single stable port — the direct answer to holding one large model plus
one fast small one on 16 GB of VRAM. Already a Pacstall package (llama-swap-bin)." The 16 GB
figure matches the measured hardware: **RTX 3080 Laptop, 16 GB VRAM**.

## Research constraints that bind this design

**F1 — llama-server speaks every wire protocol we need.** round1-digest.md:223, verbatim:
llama.cpp's llama-server "uniquely serves OpenAI chat-completions, OpenAI Responses AND Anthropic
Messages from one binary". This is what makes one local endpoint viable across four different
agent CLIs. Behind llama-swap it is the whole local-serving story.

**F2 — Codex constrains the gateway.** round1-digest.md:324: "if Codex CLI is included it
constrains the whole gateway design, because custom providers now accept only
`wire_api=\"responses\"`." Covered by F1, but only because llama-server serves Responses.

**F3 — Claude Code and LM Studio CANNOT BE SHIPPED.** round1-digest.md:324: "Claude Code and LM
Studio cannot legally be shipped". Both are proprietary and get fetch-on-demand helpers that run
the vendor's own installer so the user accepts the licence directly and the project redistributes
nothing. Redistributable: Codex CLI (Apache-2.0, static musl), opencode (MIT), goose (Apache-2.0).
**Gemini CLI's licence is NOT established in the research and must be verified before it is
assumed shippable.**

**F4 — routing Claude Code at a local endpoint degrades it, silently.** round2-digest.md:70,
verbatim: "Remote Control refuses to run when ANTHROPIC_BASE_URL points anywhere but
api.anthropic.com, and DISABLE_TELEMETRY / DO_NOT_TRACK / CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
/ DISABLE_GROWTHBOOK each disable it outright." round1-digest.md:324 adds that Anthropic "doesn't
support routing Claude Code to non-Claude models through any gateway". The research's own
recommendation: "Scope local-model routing per-project or per-shell and drive local models through
ollama/vLLM directly rather than rewriting Claude Code's base URL machine-wide."

**Consequence, and it lands squarely in this component.** Provider environment must be constructed
**per agent process**, never set machine-wide. `cdl-agent-lifecycle` launches agents, so it owns
that environment — which is exactly the scoping the research asks for. This also gives §7.1's
orphaned "provider env-var spellings" (TOGETHER_API_KEY *and* TOGETHERAI_API_KEY, FIREWORKS_API_KEY
*and* FIREWORKS_AI_API_KEY, OPENROUTER_API_KEY *and* OR_API_KEY) a home: the keystore belongs to
`cdl-first-boot-and-environment` (§7 gives it "provider key entry, validation and leakage
avoidance"), while assembling a specific agent's environment from it belongs here.

## Component boundary, stated so it is not re-litigated

- `cdl-first-boot-and-environment` owns: model **installation**, quota and GC, the unified model
  store location, provider key entry and validation.
- `cdl-agent-lifecycle` owns: GPU **admission**, which model is resident when, the llama-swap
  endpoint contract, and per-agent environment construction.

### DA5 — Claude Code against a local endpoint: allowed, explicit, warned
*User-chosen, 2026-09-01 (local; UTC 2026-09-02).* Claude Code defaults to the Anthropic API. Routing it at llama-swap is
supported but **per-agent only** and prints what it costs — Remote Control and voice dictation —
before the agent starts. The other three CLIs route to llama-swap without ceremony, having nothing
to lose. This keeps the capability while removing the silence that F4 warned about.

### Licence verification (closes the F3 gap), `gh api repos/<r>`, 2026-09-01

| Repo | SPDX | Ships in the image? |
|-|-|-|
| `google-gemini/gemini-cli` | **Apache-2.0** | Yes — the research's unresolved gap, now closed |
| `openai/codex` | Apache-2.0 | Yes (confirms round1-digest:32) |
| `sst/opencode` | MIT | Yes (confirms round1-digest:326) |
| `anthropics/claude-code` | **none** | **No** — fetch-on-demand; the empty licence field is direct confirmation of round1-digest:324 |
| `mostlygeek/llama-swap` | MIT | Yes |
| `ggml-org/llama.cpp` | MIT | Yes |

**Three of four agent CLIs are redistributable.** Only Claude Code needs the vendor-installer path.
This is a packaging fact and belongs to `cdl-install-and-packaging`; recorded here because DA3
depends on it and because the research left it open.
