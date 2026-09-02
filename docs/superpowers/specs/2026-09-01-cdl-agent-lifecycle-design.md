# `cdl-agent-lifecycle` — Component Specification

**Status:** draft 1, for review.
**Commissioned by:** `docs/superpowers/specs/2026-08-31-cdl-design.md` ("the overview") §7, which says of this
component: *"Write this one first — it holds the differentiating functionality and drives M1."*
**Design decisions taken during this spec:** `notes/2026-09-01-session-03-agent-lifecycle-design.md`
(DA1–DA5).

**Reference convention.** A bare `§4.2` refers to a section *of this document*. A reference to the
frozen overview is always written **`overview §8`**. Both documents number their sections from 1, so
an unqualified number would otherwise be ambiguous.

**The overview is frozen.** Where this spec appears to contradict it, that is a defect in this
document unless it cites new evidence. Two places do cite new evidence and are called out in §16.

---

## 1. Purpose and boundaries

This component supervises **units of work** — interactive agents and batch jobs — across the three
execution locations D28 names, and is the authoritative record of what is running, what it cost,
and how it ended.

### 1.1 What this component owns

Agent and job state machines · PTY ownership and the attachment protocol · blocked/waiting/complete
detection · exit status · prompt and launch-command recording · cancellation · worktree ownership
and reconciliation after crashes · resume without replay · sandbox filesystem and network policy
(T4a, T4e) · port allocation registry · SQLite schema and migrations · GPU admission · spend
controls (D33) · provider and global concurrency limits · the `cdl status` output contract · the
local and ssh backend contracts.

### 1.2 What it explicitly does not own

Stated so the boundary is not re-litigated in a later spec:

| Concern | Owner | This component's interface to it |
|-|-|-|
| Model **installation**, quota, GC, unified model store | `cdl-first-boot-and-environment` | Reads the store path; never writes it |
| Provider **key entry**, validation, leakage avoidance | `cdl-first-boot-and-environment` | Reads the keystore to build a per-agent environment (§10.3) |
| Power, lid, battery and **thermal policy** | `cdl-first-boot-and-environment` (overview §16.5) | Consumes a thermal gate as an admission input (§11.4) |
| Packaging, vendoring, `apt` policy, Secure Boot | `cdl-install-and-packaging` | Declares what must be present (§17) |
| Threat model in full; secrets at rest; backups | `cdl-security-and-recovery` | Closes T4a and T4e only (§12) |

### 1.3 Delivery slicing

Per DA1 this document specifies the **whole** commissioning brief. Implementation is sliced: the
first executable slice is **one local interactive agent**, sufficient to run spike 2 (§18.1). The
schema, state machine and backend interface are nevertheless designed against all three D28
locations, because those are the expensive things to change later and D28 is *"the single most
consequential requirement in the document."*

---

## 2. Definitions

| Term | Meaning |
|-|-|
| **Unit** | One supervised piece of work. Either an *agent* or a *job*. The registry's primary entity. |
| **Agent** | An interactive unit with a PTY, attachable and detachable, expected to block on human input. |
| **Job** | A batch unit with no PTY and no human in the loop, which may produce artifacts. |
| **Supervisor** | `cdl-agent-supervisor`, the process that holds a unit's PTY master and is the systemd unit's main process. One per unit. |
| **Adapter** | Per-agent-CLI knowledge: how to launch it, detect that it is waiting, read its spend, and pass its sandbox flags. |
| **Backend** | Where a unit executes: `local`, `ssh`, or (designed, disabled) `slurm` / `hfjobs`. |
| **Provider** | Where inference happens: an API vendor, or the local llama-swap endpoint. |
| **Registry** | The SQLite database. Local, authoritative, single-machine. |

---

## 3. The state machine

The governing move is to **separate lifecycle position from outcome**. A state machine that encodes
every failure mode as a state grows without bound; one that separates them has a transition graph
that stops changing.

### 3.1 Lifecycle states

```
                    admission granted
   queued ──────────────────────────────▶ starting
     │  (GPU lease, concurrency cap,          │  worktree, port block,
     │   port block, remote queue)            │  PTY, env, sandbox, exec
     │                                        ▼
     │                                     running ⇄ waiting
     │                                        │
     │            cancel requested            │
     └──────────────┬─────────────────────────┤
                    ▼                         │
                stopping ────────────────────▶│
              (SIGTERM, grace, SIGKILL)       ▼
                                          terminal
```

| State | Meaning | Applies to |
|-|-|-|
| `queued` | Recorded and admissible, but not yet started. Covers local admission-wait *and* remote queue-wait. | agent, job |
| `starting` | Unit started; supervisor is preparing worktree, port block, PTY, sandbox and environment. The agent process has not been `exec`'d. | agent, job |
| `running` | The unit's process is alive and working. | agent, job |
| `waiting` | Alive, but blocked on human input. **Needs attention.** | agent only |
| `stopping` | Cancellation requested; `SIGTERM` sent, grace period running. | agent, job |
| `terminal` | Nothing further will happen. Carries an outcome. | agent, job |

`waiting` is a **first-class state, not a flag**, because "which of my ~16 units needs me?" is the
question the whole supervisory surface exists to answer, and it should be a `WHERE` clause rather
than a scan over parsed status text.

### 3.2 Outcomes

Meaningful only in `terminal`.

| Outcome | Meaning |
|-|-|
| `completed` | The unit's process exited `0`. |
| `failed` | Exited non-zero. The exit code is recorded separately. |
| `launch_failed` | Never reached `running`: worktree, port, admission, sandbox or `exec` error. |
| `cancelled` | Terminated at the operator's request. |
| `lost` | Reconciliation found no live process for a row that claimed to be live. |

**`lost` is deliberately distinct from `failed`.** "We do not know what happened" and "it returned
3" are different facts, and collapsing them turns post-crash triage into guesswork. `lost` is the
outcome crash reconciliation writes after a reboot, an OOM kill, or a supervisor crash.

**New failure modes add an outcome, not a state.** The graph in §3.1 is intended to stop changing.

### 3.3 Jobs use the same machine

Jobs share the lifecycle and outcome vocabulary with two differences: they never enter `waiting`
(there is nothing to attend to on a batch unit), and their `queued` may represent a *remote* queue,
distinguished by `backend` plus `remote_id` on the row rather than by a separate state.

This is what allows `cdl status` to show local agents and remote jobs in one table, and makes
`cdl reconcile` one code path with per-backend probes rather than per-backend implementations.

### 3.4 Who may write a transition

This is the rule that keeps ~16 concurrent writers from corrupting the registry, and it answers
"SQLite ownership":

> **Only a unit's own supervisor writes that unit's `starting`, `running`, `waiting` and `terminal`
> rows. Every other actor *requests* a transition; none performs one.**

| Transition | Written by |
|-|-|
| → `queued` | `cdl agent new` / `cdl job submit` (the row's creator) |
| `queued` → `starting` | The admission controller — it is the only actor holding the leases |
| `starting` → `running` / `terminal(launch_failed)` | The supervisor |
| `running` ⇄ `waiting` | The supervisor, on its adapter's detector |
| any live → `stopping` | The supervisor, having observed a cancel-request flag |
| any live → `terminal` | The supervisor |
| any live → `terminal(lost)` | **The reconciler — the single exception**, and only for rows whose supervisor is *provably* absent (§7) |

`cdl agent cancel` therefore does not kill anything. It sets `cancel_requested_at` and returns; the
supervisor observes it and drives the transition. Each row consequently has exactly one writer at
any moment, so SQLite's WAL mode provides durability for a write pattern that is already
conflict-free.

---

## 4. Process architecture

### 4.1 The unit template

```
cdl-agent@<unit-id>.service      # one per unit
  Type=simple
  Restart=no                     # overview §8; see §4.4 below
  ExecStart=/usr/lib/cdl/cdl-agent-supervisor --unit-id %i
  Slice=cdl-agent-<unit-id>.slice
```

`Restart=no` is load-bearing, not a default (§4.4).

Per-agent slices carry the `systemd-oomd` override the overview requires. Verbatim from overview §8:
*"Ubuntu ships `ManagedOOMMemoryPressure=kill` at a 50 % limit with a 20 s pressure duration, so an
arbitrary descendant cgroup is killed under pressure and the victim is not chosen — potentially the
multiplexer, taking every agent with it."* Each slice therefore sets `MemoryHigh` (which throttles)
with `MemoryMax` as a backstop, and `ManagedOOMPreference=avoid` is set on the supervisor and the
notifier. The overview marks these values *reported, not reproduced*; §18.6 requires confirming them
on the target before they are relied on.

### 4.2 The supervisor holds the PTY (DA2)

The supervisor is the unit's **main process**. It:

1. Opens a PTY pair; the agent gets the slave as its controlling terminal (`setsid` + `TIOCSCTTY`).
2. `fork`/`exec`s the agent as its child, inside the sandbox (§12).
3. Reads the master continuously and **appends every byte to a log file**, regardless of whether
   anyone is attached.
4. Listens on a unix socket at `$XDG_RUNTIME_DIR/cdl/<unit-id>.sock` for attach clients.
5. Reaps the child, records its exit status, writes the terminal row, and exits.

**Why the supervisor and not zellij or `abduco`** (DA2): the deciding argument is D28, not the
local case. Agents on the lab GPU host arrive over ssh, where cdl cannot rely on a multiplexer it
does not control, so a cdl-owned holder is required for the ssh backend regardless. Using the same
holder locally yields one contract and one reconciliation path instead of two. Secondary: zellij's
scrollback is in-memory and dies with the session, so the record of what an agent did would vanish
exactly when the agent finishes — the opposite of what a supervisory system needs.

### 4.3 The attach protocol

`cdl agent attach <id>` is a thin client:

1. Connects to the unit's socket. **More than one client may attach at once**; all receive the same
   stream, and any may write.
2. The supervisor sends a **replay window** — the last *N* bytes of the log (default 64 KiB,
   configurable) — so the client's terminal shows recent context immediately.
3. The client puts its own terminal in raw mode, forwards stdin to the socket, and writes socket
   output to stdout.
4. On `SIGWINCH` the client sends its new dimensions; the supervisor applies `TIOCSWINSZ` to the
   master. The supervisor forwards **bytes only**: when the agent's terminal is in canonical mode
   the kernel's line discipline turns `^C` into `SIGINT` itself, and when the agent puts its
   terminal in raw mode it handles those bytes directly. Either way, signal translation is **not**
   the supervisor's job.
5. Detach is a client-side escape sequence and closes only the socket. **The supervisor never
   changes state on client disconnect.**

Because the supervisor holds the master for the unit's whole life, killing the terminal — or every
terminal — cannot `SIGHUP` the agent. That is spike 2's *"kill the terminal and confirm the agent
neither dies nor restarts."*

### 4.4 Resume without replay

Two distinct hazards share the name, and only the first is dangerous:

- **Screen replay** (§4.3 step 2) is harmless: bytes to a client's terminal. It is what makes
  reattach useful.
- **Prompt replay** re-sends the unit's *launch prompt* to the agent, so the task runs twice.

The guarantees against the second:

1. The launch prompt is recorded in the registry **once, at creation**, and is passed to the agent
   only during the single `starting → running` transition.
2. `Restart=no`. If systemd could restart the unit, the supervisor would re-`exec` the agent with
   its launch prompt and silently repeat the work.
3. The supervisor never writes to the PTY master except bytes received from an attached client.
4. A unit that reaches `terminal` is never re-run. Re-running is a **new unit**, with a new id, that
   records its parent in `resumed_from`.

---

## 5. The registry

### 5.1 Placement and mode

SQLite in **WAL** mode at `~/.local/state/cdl/registry.db`.

**The database must never live on NFS or SMB**, where WAL locking is unreliable — the overview
states this requirement directly, and this spec adopts it as a startup check: `cdl` refuses to start
if the database path's filesystem type is in a deny-list (`nfs`, `nfs4`, `cifs`, `smb3`, `fuse.sshfs`),
with a message naming the detected type. Failing loudly at startup beats corrupting a registry
slowly.

The registry is **local and authoritative**. It records work executing elsewhere; remote hosts hold
no replica and are never written to directly.

### 5.2 Schema

```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;

CREATE TABLE schema_version (
    version     INTEGER NOT NULL,
    applied_at  TEXT    NOT NULL
);

CREATE TABLE unit (
    id                  TEXT PRIMARY KEY,          -- ULID: sorts by creation time
    kind                TEXT NOT NULL CHECK (kind IN ('agent','job')),

    state               TEXT NOT NULL CHECK (state IN
                          ('queued','starting','running','waiting','stopping','terminal')),
    outcome             TEXT CHECK (outcome IN
                          ('completed','failed','launch_failed','cancelled','lost')),
    exit_code           INTEGER,

    backend             TEXT NOT NULL CHECK (backend IN ('local','ssh','slurm','hfjobs')),
    remote_id           TEXT,                      -- queue id on a remote backend
    remote_host         TEXT,

    adapter             TEXT NOT NULL,             -- 'claude-code' | 'codex' | 'gemini' | 'opencode'
    provider            TEXT NOT NULL,             -- 'anthropic' | 'openai' | ... | 'local'
    model               TEXT,

    -- Reproducibility: what was actually run.
    launch_argv         TEXT NOT NULL,             -- JSON array, as exec'd
    launch_prompt       TEXT,                      -- recorded ONCE; see §4.4
    launch_env_keys     TEXT NOT NULL,             -- JSON array of NAMES only; never values

    worktree_id         TEXT REFERENCES worktree(id),
    port_block_id       TEXT REFERENCES port_block(id),
    gpu_lease_id        TEXT REFERENCES gpu_lease(id),

    log_path            TEXT NOT NULL,
    supervisor_pid      INTEGER,
    systemd_unit        TEXT,
    boot_id             TEXT,                      -- /proc/sys/kernel/random/boot_id at start

    budget_usd          REAL,                      -- per-unit declared budget (D33)
    spend_usd           REAL NOT NULL DEFAULT 0,
    tokens_in           INTEGER NOT NULL DEFAULT 0,
    tokens_out          INTEGER NOT NULL DEFAULT 0,
    spend_is_estimated  INTEGER NOT NULL DEFAULT 0,-- see §13.3

    resumed_from        TEXT REFERENCES unit(id),
    cancel_requested_at TEXT,
    created_at          TEXT NOT NULL,
    started_at          TEXT,
    ended_at            TEXT
);

CREATE INDEX unit_attention  ON unit(state) WHERE state = 'waiting';
CREATE INDEX unit_live       ON unit(state) WHERE state <> 'terminal';

-- Append-only transition log. Never updated, never deleted by normal operation.
CREATE TABLE unit_event (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    unit_id     TEXT NOT NULL REFERENCES unit(id),
    at          TEXT NOT NULL,
    from_state  TEXT,
    to_state    TEXT NOT NULL,
    outcome     TEXT,
    actor       TEXT NOT NULL,   -- 'supervisor' | 'admission' | 'reconciler' | 'cli'
    detail      TEXT
);

CREATE TABLE worktree (
    id          TEXT PRIMARY KEY,
    repo_path   TEXT NOT NULL,
    branch      TEXT NOT NULL,
    path        TEXT NOT NULL UNIQUE,
    created_at  TEXT NOT NULL,
    released_at TEXT,
    UNIQUE (repo_path, branch)
);

CREATE TABLE port_block (
    id          TEXT PRIMARY KEY,
    base_port   INTEGER NOT NULL UNIQUE,
    size        INTEGER NOT NULL,
    owner_unit  TEXT REFERENCES unit(id),
    preferred   INTEGER NOT NULL,   -- 1 if the hash's first choice was free
    created_at  TEXT NOT NULL,
    released_at TEXT
);

CREATE TABLE gpu_lease (
    id          TEXT PRIMARY KEY,
    unit_id     TEXT NOT NULL REFERENCES unit(id),
    vram_mib    INTEGER NOT NULL,
    acquired_at TEXT NOT NULL,
    released_at TEXT
);

CREATE TABLE spend_ledger (           -- append-only; unit.spend_usd is a cached rollup
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    unit_id     TEXT NOT NULL REFERENCES unit(id),
    at          TEXT NOT NULL,
    provider    TEXT NOT NULL,
    tokens_in   INTEGER,
    tokens_out  INTEGER,
    usd         REAL,
    estimated   INTEGER NOT NULL DEFAULT 0,
    source      TEXT NOT NULL     -- 'adapter' | 'provider-api' | 'price-table'
);
```

**Why `unit_event` exists.** The `unit` row holds current state; the event log holds how it got
there, including which actor wrote each transition. Reconciliation, spike-2 evidence and
post-incident triage all need the history, and an append-only table is cheap. It is also what makes
"the registry was restored from backup and is stale" diagnosable.

**Why `launch_env_keys` stores names only.** Recording the environment is necessary for
reproducibility; recording provider API keys into a database that is backed up is a credential leak.
Names satisfy the first without creating the second.

**Why `boot_id`.** A PID recorded before a reboot may be alive again afterwards as an unrelated
process. Comparing the stored `boot_id` to the current one makes "this row is from a previous boot"
a fact rather than an inference (§7).

### 5.3 Migrations

Forward-only, numbered, each in its own transaction, applied at startup by a single writer holding
an exclusive lock. `schema_version` is checked before any other statement. A database whose version
is **newer** than the binary is a hard refusal, not a downgrade attempt.

### 5.4 Corruption recovery

On `SQLITE_CORRUPT`, `cdl` does not attempt automatic repair. It:

1. Refuses further writes.
2. Moves the database aside to `registry.db.corrupt-<timestamp>`.
3. Creates a fresh database at the current schema version.
4. Reports how many units were lost from view, and that **their logs still exist** — logs are files
   on disk and do not depend on the registry.
5. Directs the operator to `cdl reconcile`, which will discover any still-running supervisors and
   re-adopt them (§7.3).

### 5.5 Backup treatment

The registry is inside `$HOME` and therefore inside the backup path `cdl-security-and-recovery`
owns. Two requirements specific to it:

- Back up a **consistent** copy — `VACUUM INTO` or the backup API, never a raw file copy of a WAL
  database.
- **Every restored row is suspect.** Restoring a registry re-introduces rows whose processes are
  long gone; §7.4 defines that reconciliation.

---

## 6. Worktrees

One worktree per agent, enforced. The overview's justification, *reported by a research subagent and
not independently reproduced*: agents sharing one checkout landed 24 of 100 commits with 75
`index.lock` failures; one worktree per agent landed 100/100.

`cdl worktree new <branch>` is the seeding hook, because `git worktree add` carries no untracked or
gitignored files, so a fresh workspace has no venv, no `node_modules`, no `.env`. It:

1. Creates the worktree and its branch. Git enforces uniqueness — one branch cannot be checked out
   twice — so branch collisions are impossible by construction rather than by policy.
2. Creates the venv with `uv`, so packages hardlink from one shared cache.
3. Reflink-copies large gitignored directories (`cp --reflink=auto`, free on btrfs).
4. Allocates a port block (§8).
5. Records the row in `worktree`.

**Release is explicit, and worktrees outlive their agent by default.** When a unit reaches
`terminal`, its worktree is *not* removed: the work is usually the point. `released_at` is set, and
`cdl worktree gc` removes released worktrees older than a configurable age, refusing any with
uncommitted changes unless `--force` is given.

---

## 7. Crash reconciliation

### 7.1 The problem

Rows claiming `starting`, `running`, `waiting` or `stopping` assert that a process exists. After a
reboot, an OOM kill, a supervisor crash or a registry restore, that assertion may be false, and
nothing in the row itself reveals it.

### 7.2 The probe

`cdl reconcile` runs at login (via a `systemd --user` unit ordered after the registry is available)
and on demand. For each non-`terminal` row, in order, stopping at the first definite answer:

| # | Check | Conclusion |
|-|-|-|
| 1 | `boot_id` differs from the current boot | **Dead.** No process from a previous boot survives. |
| 2 | `backend = 'local'` and `systemctl --user is-active <unit>` is not `active` | **Dead.** |
| 3 | `supervisor_pid` absent, or present but not a `cdl-agent-supervisor` with the matching unit id in its cmdline | **Dead.** PID reuse is why the cmdline is checked, not just existence. |
| 4 | The unit's socket exists and answers a ping | **Alive.** Re-adopt (§7.3). |
| 5 | `backend = 'ssh'` and the remote probe reports no such process | **Dead.** |
| 6 | Remote host unreachable | **Unknown** — see below. |

Rows concluded dead are written `terminal` / `lost`, with a `unit_event` recording `actor =
'reconciler'` and the check number that decided it.

**An unreachable remote host is not evidence of death.** Such rows are left in place, their
`state` untouched, and `cdl status` marks them *stale* with the age of the last successful probe. A
network partition must never be allowed to fabricate a `lost` outcome, because that would release
the unit's GPU lease and port block while the work is still running.

### 7.3 Re-adoption

A supervisor that is still alive is re-adopted rather than restarted: its socket is live, its log is
appending, and the registry simply resumes trusting it. This is the normal case after a terminal
crash or a logout, and it is why `linger` is enabled for the user.

### 7.4 Restored-but-stale rows

The case a restore actually creates. After a registry restore, `cdl reconcile` runs with **every**
row treated as unverified. Check 1 resolves nearly all of them, because a restored registry
necessarily carries a `boot_id` from a previous boot. Rows for remote backends are probed; those
whose hosts are unreachable are marked stale rather than lost, per §7.2.

### 7.5 Lease release

Reconciling a unit to `terminal` releases its GPU lease and port block in the **same transaction**
as the state write. A lease outliving its unit is how a machine slowly runs out of ports and GPU
capacity with nothing visibly wrong.

---

## 8. Port allocation

The overview's own correction to revision 1 is the specification here:

> *"Revision 1 described 'a deterministic, non-colliding port block derived from the branch name.' A
> hash is deterministic but **not** non-colliding."*

The design is therefore:

1. **Preferred block** = a hash of `(repo_path, branch)` mapped into the configured range
   (default base 20000–29999, block size 10).
2. **Allocate under an advisory lock** — one SQLite transaction taking an `IMMEDIATE` lock, so
   check-and-record is atomic across concurrent `cdl worktree new` invocations.
3. **Collision detection** against `port_block` for rows with `released_at IS NULL`.
4. **Documented fallback**: linear probe upward from the preferred block, wrapping once. `preferred`
   is recorded as `0` when the fallback was used, so drift from the deterministic ideal is visible.
5. **Exhaustion is an error**, not a wrap-into-someone-else's-block: `launch_failed` with a message
   naming the range and the number of live blocks.

Ports are recorded, not enforced — nothing prevents a process binding outside its block. The
registry's purpose is to stop cdl *itself* handing the same port to two units.

---

## 9. Adapters

### 9.1 Why an adapter interface

DA3 puts four agent CLIs in scope: **Claude Code, Codex, Gemini and OpenCode**. Launch flags,
waiting-detection, spend reporting and sandbox options differ across all four, and hard-coding any
one of them would make the other three special cases.

Licences verified 2026-09-01 via `gh api repos/<repo>`:

| CLI | SPDX | Ships in the image? |
|-|-|-|
| `openai/codex` | Apache-2.0 | Yes |
| `sst/opencode` | MIT | Yes |
| `google-gemini/gemini-cli` | Apache-2.0 | Yes |
| `anthropics/claude-code` | **none** | **No** — fetch-on-demand vendor installer |

The last row confirms the research's claim that *"Claude Code and LM Studio cannot legally be
shipped"* by direct measurement: the repository carries no licence field at all. Packaging is
`cdl-install-and-packaging`'s problem; this component must simply not assume Claude Code is present.

### 9.2 The interface

Each adapter provides:

| Member | Purpose |
|-|-|
| `argv(spec)` | The exact command line, returned for recording in `launch_argv` |
| `env(spec, keystore)` | The **per-process** environment (§10.3) |
| `sandbox_opts()` | Flags that make the CLI's own sandbox fail closed (§12.3) |
| `detect_waiting(recent_output, idle_for)` | Whether the unit is blocked on input (§9.3) |
| `parse_spend(recent_output)` | Tokens and cost, if the CLI reports them (§13.3) |
| `supports_provider(p)` | Whether this CLI can be pointed at provider `p` (§10.2) |

Adding a fifth CLI is a new adapter, not a redesign. `goose` (Apache-2.0) is a likely fifth and is
explicitly not in v1.

### 9.3 Waiting detection

Two signals, combined, because neither alone is adequate:

1. **Adapter pattern** — the CLI printed something matching its known prompt or approval-request
   pattern. Accurate, and specific to each CLI.
2. **Idle threshold** — no bytes written to the master for *N* seconds (default 30, configurable),
   *and* the child is blocked reading its PTY slave (`/proc/<pid>/wchan` or `syscall`). Generic
   fallback for anything the pattern misses.

A unit enters `waiting` when either fires and returns to `running` on the next byte of output or
input. **Detection is best-effort and the spec says so**: a missed `waiting` costs attention, not
correctness, and no other decision is derived from it. `cdl status` marks units whose `waiting` came
from the idle heuristic alone, so an operator can tell a confident signal from a guess.

---

## 10. Providers, local serving, and per-agent environment

### 10.1 One endpoint, many models (DA4)

Local inference is served by **llama-swap in front of llama.cpp's `llama-server`**, presenting a
single stable endpoint that loads and unloads models on demand. Ollama, LM Studio and HuggingFace
are **model sources** — places weights come from — not competing servers.

This reconciles overview §8's *"One inference server as a system service behind a `flock` semaphore"*, which
three concurrently-running servers would have contradicted, and gives overview §7.1's orphaned *"llama-swap
rationale"* its written destination. The research's rationale, verbatim: *"Hot-swaps models behind a
single stable port — the direct answer to holding one large model plus one fast small one on 16 GB
of VRAM."* The measured hardware is an **RTX 3080 Laptop with 16 GB VRAM**, so the figure the
recommendation was reasoned against is the figure this machine has.

`llama-server` is what makes one endpoint viable across four CLIs, because it *"uniquely serves
OpenAI chat-completions, OpenAI Responses AND Anthropic Messages from one binary."* That also
satisfies a Codex-specific constraint recorded in the research — custom providers *"now accept only
`wire_api=\"responses\"`"* — which only its Responses support makes possible.

### 10.2 The supported matrix

The spec states supported pairs rather than implying all of them.

| CLI | Its own vendor API | llama-swap (local) |
|-|-|-|
| Claude Code | Supported, **default** | Supported, **explicit and warned** (§10.4) |
| Codex | Supported | Supported via Responses |
| Gemini | Supported | Supported |
| OpenCode | Supported (multi-provider natively) | Supported |

`supports_provider()` returning false is a `launch_failed` at admission with a message naming the
pair, never a silent fallback to a different model than the operator asked for.

### 10.3 The environment is built per process, never machine-wide

**This is a hard rule, and it follows from measured behaviour.** Research,
verbatim: *"Remote Control refuses to run when `ANTHROPIC_BASE_URL` points anywhere but
api.anthropic.com, and `DISABLE_TELEMETRY` / `DO_NOT_TRACK` /
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` / `DISABLE_GROWTHBOOK` each disable it outright."* The
obvious distro design — one local gateway, privacy variables on by default, set globally — would
silently remove Claude Code's phone-steering and voice dictation.

Therefore:

- `cdl` **never** writes provider variables into a shell profile, `/etc/environment`, or a systemd
  global environment file.
- The supervisor constructs each unit's environment from the keystore at launch and passes it to
  that process alone.
- `launch_env_keys` records the names for reproducibility; values are never stored (§5.2).

This also gives overview §7.1's other orphan a home. The research requires shipping **both spellings** of the
divergent provider variables — `TOGETHER_API_KEY` *and* `TOGETHERAI_API_KEY`; `FIREWORKS_API_KEY`
*and* `FIREWORKS_AI_API_KEY`; `OPENROUTER_API_KEY` *and* `OR_API_KEY` — and the environment builder
is what sets both.

### 10.4 Claude Code against a local endpoint (DA5)

Allowed, explicit, and warned. Claude Code defaults to the Anthropic API. Requesting a local model
for it is per-unit only, and `cdl` prints, before starting:

```
This agent will use a local model, so Claude Code's Remote Control (phone steering)
and voice dictation will not work for it. Other agents are unaffected.
```

The other three CLIs route to llama-swap with no ceremony, having nothing to lose. The capability is
kept; the silence is not.

---

## 11. GPU admission

### 11.1 Mechanism

Admission control, not isolation — MIG and MPS are excluded by overview §2.3. A `flock` semaphore guards the
GPU, and `gpu_lease` records who holds capacity.

### 11.2 What is admitted

Only units whose provider is `local`. API-backed agents consume no VRAM and are limited by §14
instead.

### 11.3 Sizing

A unit declares `vram_mib`. Admission grants a lease when the sum of live leases plus the request
fits the budget (total VRAM minus a configurable reserve for the compositor and display, default
1024 MiB). llama-swap's model swapping is what makes a lease meaningful: a lease is permission to
have a model resident, and the swap layer honours it.

### 11.4 The thermal gate

Overview §16.5 makes this component the enforcement point: policy *"has to be throttling, temperature
thresholds, whether sustained local inference requires AC power, and **refusal to launch local jobs
when conditions are unsafe**, which makes it an input to GPU admission control in
`cdl-agent-lifecycle`."*

Admission therefore consults a gate owned by `cdl-first-boot-and-environment`, which returns
`allow` / `deny(reason)`. This component does not define the thresholds; it defines that they are
consulted, that a denial produces `launch_failed` with the reason surfaced, and that the gate is
re-consulted on every admission rather than cached.

**The M0 firmware walk hardened this.** No fan control exists in firmware *or* OS on this machine,
so throttling and refusal-to-launch are the only mechanisms available — not a fallback. The levers
were measured present: `intel_pstate` exposes `no_turbo` and `max_perf_pct`.

---

## 12. Sandbox — closing T4a and T4e

The overview marks both rows **Open**, and says *"none may be closed by assertion."* This section
closes them by mechanism.

### 12.1 T4e — filesystem policy

> *"Agent reads other worktrees, `$HOME`, or other agents' state ... Bubblewrap filesystem policy —
> currently unspecified. Open, and the reason worktrees must not be miscounted as isolation."*

Every agent runs under **bubblewrap**, deny-by-default:

| Path | Mode |
|-|-|
| Its own worktree | read-write |
| The shared `uv` cache, the model store | read-only |
| `/usr`, `/bin`, `/lib`, `/etc` (minus the keystore) | read-only |
| `/tmp` | private `tmpfs` per unit |
| **Other worktrees, other units' logs, the registry, the keystore, the rest of `$HOME`** | **not mounted** |

Not mounted, rather than mounted-and-denied: a path that does not exist in the namespace cannot be
read through a permission bug.

The unit's own log is written by the *supervisor*, which lives outside the sandbox, so the agent
cannot rewrite its own history.

### 12.2 T4a — network egress policy

> *"Agent exfiltrates secrets over permitted network egress ... No control in v1 as designed. The
> sandbox's network policy is the only possible boundary and is currently unspecified. Open.
> `cdl-agent-lifecycle` must define an egress policy, or this is accepted explicitly rather than by
> omission."*

The policy, stated rather than omitted:

- Each agent gets its **own network namespace**. It has no route to the outside directly.
- All egress is forced through a **cdl-run HTTPS `CONNECT` proxy** that allow-lists by **hostname**,
  and DNS resolution inside the namespace is restricted to that proxy. Hostname allow-listing rather
  than IP allow-listing is deliberate: provider APIs sit behind CDNs whose address sets change
  without notice, so an IP list would break working agents and tempt an operator into disabling it.
- The allow-list is per-unit — the provider endpoints its adapter needs, the local llama-swap
  endpoint, the git remotes configured for its repository, and the package indexes its toolchain
  needs — and is **recorded on the unit row**, so what an agent was permitted to reach is auditable
  after the fact.
- `--net=none` is available for units that need no network at all, and is the default for units
  whose provider is `local`, since llama-swap is reachable over a unix socket.

**Honest limits, stated because the threat model demands honesty over completeness.** Two, and
neither is closable by this mechanism:

1. This constrains *where* an agent may send data, not *what*. An agent permitted to reach its
   provider can send that provider anything in its worktree — which is T4d, accepted by the overview
   as *"what using a provider means."* Hostname allow-listing closes exfiltration to an *arbitrary*
   host; it cannot close exfiltration to a *permitted* one.
2. A `CONNECT` proxy sees the requested hostname, not the tunnel's contents. An agent that can reach
   an allowed host can tunnel arbitrary traffic to it. Closing that would require terminating TLS
   and inspecting content, which means holding a interception CA on the machine — a larger and more
   dangerous capability than the one it defends against. **Not done, deliberately.**

### 12.3 Fail closed

Research, *reported not reproduced*: on Ubuntu 24.04 and later the default AppArmor policy prevents
bubblewrap from creating the user namespaces it needs, and **Claude Code's default on sandbox
failure is to warn and then run unsandboxed.**

Therefore:

1. The image ships `/etc/apparmor.d/bwrap` and preinstalls bubblewrap
   (`cdl-install-and-packaging`).
2. Each adapter's `sandbox_opts()` sets its CLI's fail-closed option.
3. **cdl performs its own check**: at admission, it verifies `kernel.apparmor_restrict_unprivileged_userns`
   and attempts a trivial `bwrap` invocation. Failure is `launch_failed`, never a degraded launch.

Point 3 exists because points 1 and 2 depend on a vendor's flag behaving as documented, and the
consequence of that assumption being wrong is an unsandboxed agent. cdl verifies rather than trusts.

---

## 13. Spend controls (D33)

D33, verbatim: *"Spend controls are owned by `cdl-agent-lifecycle`, best-effort but not unowned.
Minimum: per-job declared budget, per-provider concurrency ceiling, global daily warning and
hard-stop where the API permits, runtime and token accounting, cost visible in `cdl status`, and
defined behaviour when a provider exposes no reliable cost data."*

### 13.1 Per-unit budget

`--budget <usd>` at creation, recorded in `budget_usd`. On exceedance the supervisor drives
`stopping → terminal(cancelled)` and records the reason. Absent a budget, the global ceiling
(§13.2) still applies.

### 13.2 Global daily ceiling

Two thresholds in config: a **warning** level, surfaced in `cdl status` and by the notifier, and a
**hard stop** level, at which admission refuses new units. Running units are not killed by the
global ceiling — only new admissions are refused — because killing work already paid for to save
money is the wrong trade.

### 13.3 When a provider exposes no reliable cost data

The case D33 requires a defined behaviour for.

1. If the adapter reports usage, use it (`source = 'adapter'`).
2. Otherwise, if the provider offers a usage API, poll it (`source = 'provider-api'`).
3. Otherwise, estimate from a **shipped price table** keyed by model (`source = 'price-table'`), and
   set `spend_is_estimated`.

**An estimated figure is never presented as measured.** `cdl status` renders estimates with a `~`
prefix, and a unit whose spend is estimated **cannot be hard-stopped on cost alone** — a guess must
not terminate work. It warns instead. Local-model units record zero cost and non-zero runtime, since
their real cost is electricity and wear, which this component does not model.

---

## 14. Concurrency limits

D28's shape — 5–10 API-backed agents, 1–2 local, 2–4 on the GPU host — is the sizing input.

| Limit | Default | Enforced at |
|-|-|-|
| Global live units | 20 | Admission |
| Per-provider concurrent units | 10 | Admission |
| Local (GPU) units | Whatever VRAM admits (§11) | Admission |
| Per-remote-host units | 4 | Admission |

Exceeding a limit leaves the unit in `queued` rather than failing it: the request was valid, the
machine is merely busy. `cdl status` shows what each queued unit is waiting for, so a queue that is
not draining shows what it is short of.

---

## 15. CLI surface

### 15.1 Commands

```
cdl agent new [--adapter X] [--provider Y] [--model Z] [--branch B]
              [--budget USD] [--prompt-file F] [--vram MIB]
cdl agent list | attach <id> | cancel <id> | logs <id> [-f]
cdl job submit [--backend ssh|slurm|hfjobs] ... | list | status <id>
              | logs <id> | cancel <id> | artifacts <id>
cdl status [--json] [--attention]
cdl worktree new <branch> | list | gc
cdl reconcile
cdl doctor
```

### 15.2 The `cdl status` output contract

`cdl status` is the attention surface, not a convenience. The contract:

- **Attention first.** Units in `waiting` sort to the top, unconditionally.
- **One row per unit**, columns: `ID`, `KIND`, `STATE`, `ADAPTER`, `MODEL`, `BRANCH`, `AGE`,
  `SPEND`, `NOTE`.
- **`STATE` is the state machine's own vocabulary** (§3), never a prettified synonym. What the
  registry stores is what the operator reads.
- **`SPEND`** shows `~` for estimates (§13.3).
- **`NOTE`** carries exactly one short reason: why a unit is queued, what a `lost` unit lost, that a
  remote row is stale and how old the last probe is, that a `waiting` came from the idle heuristic
  alone.
- **`--json`** emits the same data with stable field names, and is the interface the notifier and
  any status bar consume. Human formatting is never parsed by another component.
- **Degraded, never blank.** If a remote backend cannot be probed, its rows still render, marked
  stale. A status surface that hides what it cannot verify is worse than one that admits it.

---

## 16. Where this spec cites new evidence against the frozen overview

Two places, both permitted because the overview allows amendment *"on new evidence from a spike, a
hardware capture, or a component spec."*

1. **Overview §8's "one inference server"** is preserved rather than contradicted, but its *content* is now
   specified as llama-swap + `llama-server` (§10.1), which the overview did not name. Overview §7.1 lists the
   llama-swap rationale as content with no written destination; this is that destination.
2. **Overview §16.5's thermal input** is hardened by the M0 firmware walk of 2026-09-01: no fan control
   exists in firmware or OS, so the admission gate in §11.4 is the only enforcement mechanism, not
   one of several.

---

## 17. What this component requires from others

| Requirement | Owner | Why it is load-bearing here |
|-|-|-|
| `bolt`/`boltctl` present after install | `cdl-install-and-packaging` | Unrelated to agents, but recorded by the M0 walk as having no firmware fallback |
| `/etc/apparmor.d/bwrap`, bubblewrap preinstalled | `cdl-install-and-packaging` | §12.3 fails closed without it |
| llama-swap, `llama-server` packaged and pinned | `cdl-install-and-packaging` | §10.1 |
| Keystore with a readable interface | `cdl-first-boot-and-environment` | §10.3 |
| Model store path | `cdl-first-boot-and-environment` | §12.1 read-only mount |
| Thermal gate returning allow/deny | `cdl-first-boot-and-environment` | §11.4 |
| Registry included in backups, consistently | `cdl-security-and-recovery` | §5.5 |

---

## 18. Acceptance tests

### 18.1 Spike 2 — durable interactive agent

The overview's pass condition, unchanged: *"attach → detach → log out → log back in → attach again,
with the agent still running and its scrollback intact; then kill the terminal and confirm the agent
neither dies nor restarts."* Plus: the opening prompt appears exactly once in the log across the
whole sequence, and `exit_code` is recorded on completion.

### 18.2 Reconciliation

Start a unit, `SIGKILL` its supervisor, run `cdl reconcile`; the row becomes `terminal`/`lost` with
a `unit_event` naming the reconciler and the deciding check. Separately: reboot with a unit running,
confirm check 1 resolves it. Separately: restore a registry backup, confirm every row is re-probed.
Separately: make a remote host unreachable and confirm its rows are marked **stale, not lost**.

### 18.3 Port allocation

Two concurrent `cdl worktree new` invocations that hash to the same preferred block receive
different blocks, both recorded, the second with `preferred = 0`. Exhausting the range yields
`launch_failed` naming the range.

### 18.4 Sandbox

From inside a running agent: reading another unit's worktree fails; reading the keystore fails;
reading the registry fails. Egress to a non-allow-listed host fails. With
`kernel.apparmor_restrict_unprivileged_userns` set so `bwrap` cannot start, admission produces
`launch_failed` and **no agent process is created** — the test that matters, because the failure
mode being guarded against is running unsandboxed.

### 18.5 Spend

A unit with `--budget` below its projected cost is stopped and recorded `cancelled`. A unit whose
spend is estimated is **not** hard-stopped, and its `cdl status` row shows `~`.

### 18.6 Confirm the reported values

The overview marks the `systemd-oomd` defaults and the AppArmor/bubblewrap interaction *reported,
not reproduced*. Before either is relied on, both are to be measured on the target and the result
recorded here.

---

## 19. Open items

| # | Item | Why it is open |
|-|-|-|
| 1 | **Review findings #6 and #7** | Overview §7 requires this spec to resolve them, but their text is not recorded anywhere in the repository — only referenced. They must be reconciled against the original review before this spec is considered complete. |
| 2 | T4c (destructive push to a git remote) | Named in the threat model, not closed here. Candidate: deny-by-default push credentials. Belongs to `cdl-security-and-recovery`, but agents are the actor. |
| 3 | T4f (one credential set shared by every agent) | Per-agent credential scoping is not designed. §12.1 removes the keystore from the agent's namespace, which is a partial mitigation, not a closure. |
| 4 | Slurm backend | Designed as a backend row and a state mapping; ships **disabled** per D30 until its auth is testable. |
| 5 | HF Jobs backend | Depends on overview §16.4's funding question, which is unresolved. |
| 6 | Model integrity and provenance | Research flagged pulling multi-GB weights with no checksum policy. Sits between this component and `cdl-first-boot-and-environment`; unassigned. |
| 7 | `goose` as a fifth adapter | Apache-2.0 and Pacstall-packaged, so cheap to add. Not in v1. |
