# `cdl-agent-lifecycle` — Component Specification

**Status:** draft 3. Reviewed twice (2026-09-02, both rounds); findings and resolutions in §21.
**Commissioned by:** `docs/superpowers/specs/2026-08-31-cdl-design.md` ("the overview") §7, which says of this
component: *"Write this one first — it holds the differentiating functionality and drives M1."*
**Design decisions taken during this spec:** `notes/2026-09-01-session-03-agent-lifecycle-design.md`
(DA1–DA5).

<!-- check-spec-allow:
busy_timeout foreign_keys journal_mode
intel_pstate max_perf_pct no_turbo apparmor_restrict_unprivileged_userns
launch_failed budget_exceeded node_modules record_sha256 wire_api
-->

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

Per DA1 this document specifies the **whole** commissioning brief. **Implementation is sliced, and
§21 is the order**: the first executable slice is one local interactive agent against a test
adapter, with remote execution, controlled egress, GPU admission and spend accounting deliberately
held back until the local core survives its failure tests.

The schema, state machine and backend interface are nevertheless designed against all three D28
locations, because those are the expensive things to change later and D28 is *"the single most
consequential requirement in the document."* Specifying a layer and shipping it are different
commitments, and §21 marks which is which — draft 1 specified some layers at a depth that implied
they were ready to build, which they were not.

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
            admission grants leases,            supervisor acknowledges
            writes launch_id + deadline         (OWNERSHIP TRANSFERS HERE)
  queued ──────────────────────────────▶ starting ──────────────────────▶ running ⇄ waiting
    │                                        │                                  │
    │ cancel requested                       │ spawn failed, or deadline         │ cancel requested
    │ (admission owns it; no                 │ passed unacknowledged             │
    │  supervisor exists to ask)             │ (admission still owns it)         ▼
    │                                        │                               stopping
    ▼                                        ▼                        (SIGTERM, grace, SIGKILL)
 terminal                             terminal                                   │
 (cancelled)                          (launch_failed)                            ▼
                                                                             terminal
```

`stopping` is reachable **only from a state that has a live process**. A `queued` unit has none,
so its cancellation goes straight to `terminal`; draft 2's diagram routed it through `stopping`
and contradicted §3.4 four pages later.

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
| `launch_failed` | Never reached `running`. Written by **admission** for pre-handoff failures (unsupported adapter/provider pair, thermal denial, sandbox precheck, port exhaustion, concurrency-permanent refusal) and by the **supervisor** for post-handoff ones (worktree, PTY, sandbox construction, `exec`). §3.4 says which. |
| `cancelled` | Terminated at the operator's request. |
| `budget_exceeded` | Terminated by cdl because the unit passed its declared budget (§13.1). Distinct from `cancelled`, because "you stopped this" and "your money ran out" lead to different next actions, and draft 4 recorded both as `cancelled`. |
| `lost` | Reconciliation found no live process for a row that claimed to be live. |

**`lost` is deliberately distinct from `failed`.** "We do not know what happened" and "it returned
3" are different facts, and collapsing them turns post-crash triage into guesswork. `lost` is the
outcome crash reconciliation writes after a reboot, an OOM kill, or a supervisor crash.

**New failure modes add an outcome, not a state.** The graph in §3.1 is intended to stop changing.

### 3.3 Jobs use the same machine

Jobs share the lifecycle and outcome vocabulary with two differences: they never enter `waiting`
(there is nothing to attend to on a batch unit), and their `queued` may represent a *remote* queue,
distinguished by `backend` plus `remote_id` on the row rather than by a separate state.

**A job may be local, and `local` is the default.** The schema permits it, the lifecycle permits it,
and a batch unit on this machine — a test run, a long build, an unattended agent with no PTY — is an
ordinary case. Draft 2's CLI offered `--backend ssh|slurm|hfjobs` only, which contradicted both. A
local job is a unit with a supervisor, a log and no PTY.

This is what allows `cdl status` to show local agents and remote jobs in one table, and makes
`cdl reconcile` one code path with per-backend probes rather than per-backend implementations.

### 3.4 Who may write a transition

This is the rule that keeps ~16 concurrent writers from corrupting the registry, and it answers
"SQLite ownership". Draft 1 stated it as *"only a unit's own supervisor writes that unit's
`starting` … rows"* and then assigned `queued → starting` to the admission controller in the very
next table. It also left a `queued` unit's cancellation to a supervisor that does not exist yet.
The correct invariant is not *one actor* but **one owner at a time**:

> **Every row has exactly one owning actor at any instant. Only the owner writes it. Ownership
> transfers at three defined points, and each transfer is itself a single write.**

| Phase | Owner | May write |
|-|-|-|
| From row insert | **Creator** (`cdl agent new` / `cdl job submit`) | The initial `queued` row. Nothing else, ever. |
| From insert commit **until the launch is acknowledged** | **Admission controller** | `queued → starting`, `queued → terminal(launch_failed \| cancelled)`, and — the case draft 2 had no owner for — `starting → terminal(launch_failed \| cancelled)` when the spawn fails or the deadline passes unacknowledged |
| From the **acknowledgement commit** (§4.5) | **Supervisor**, for `backend = 'local'`; the **backend controller** (§19.2) for every remote backend | `starting → running`, `running ⇄ waiting`, live → `stopping`, live → `terminal` |
| Only when the owner is provably absent, or the launch deadline has passed | **Reconciler** | → `terminal(lost)` where a confirmed-running unit vanished; → `terminal(launch_failed)` at `L0′`; and, for a remote unit, → `terminal(<outcome from the imported result>)` at `R3` (§7.2) |

Draft 3 first gave the reconciler `terminal(lost)` alone, which contradicted its own §7.2: `L0′`
writes `launch_failed` and `R3` imports `completed` / `failed` / `cancelled` from a remote result.
A write layer built from the narrow rule would have rejected the writes the ladders require. The
reconciler still never invents an outcome — at `R3` it is **transcribing one the remote host
decided**, which is why importing is not the same as concluding.

**A remote unit's owner is a local process, never the remote one.** The registry is local and
authoritative (§5.1) and an SSH supervisor cannot write it, so assigning post-handoff transitions
to "the supervisor" was meaningless for three of the four backends. §19.2 defines the backend
controller that owns those rows and turns authenticated remote observations into local
transactions.

**The handoff is acknowledged, and that is the whole of §4.5.** Draft 2 transferred ownership at
the `starting` write and *then* started the systemd unit, which left a window in which the row's
declared owner did not exist yet. Everything went wrong in that window: a concurrent reconcile saw
an inactive service and called a perfectly healthy launch `lost`; a cancel request had nobody to
process it; and a `systemctl start` failure became `lost` rather than `launch_failed`. **Admission
keeps the row until the supervisor proves it started.** The protocol is §4.5.

**Cancellation is a request, never a transition.** `cdl agent cancel` sets `cancel_requested_at`
and returns; it kills nothing and transitions nothing. **Whichever actor owns the row acts on it**,
which is what makes queued cancellation work:

- A **`queued`** unit is cancelled by the admission controller, which owns it, writing
  `queued → terminal(cancelled)` directly. No supervisor is ever started. There is no process to
  signal and no grace period to serve, so `stopping` is skipped — it exists to describe a
  `SIGTERM` in flight.
- A **live** unit is cancelled by its supervisor, which observes the flag and drives
  `stopping → terminal(cancelled)`.

Each row therefore has exactly one writer at any moment. **That prevents lost updates; it does not
prevent lock contention, and draft 3 called the pattern "conflict-free", which is wrong.** WAL
allows one writer *for the whole database*, not one per row: a second writer gets
`SQLITE_BUSY` — measured as `database is locked` after the 5 s `busy_timeout` — even when it is
updating a different row entirely. Single-owner-per-row is a rule about **correctness**, not about
concurrency.

Two consequences the implementation must respect, because ~16 supervisors share this database:

- **Write transactions are short and contain only writes.** No filesystem operation, no network
  I/O, and no `ssh` inside a write transaction. §6.1 renames the directory *before* it opens one,
  and §19.2's controller does its probing outside one, for exactly this reason.
- **`SQLITE_BUSY` is retried with backoff, and a retry that exhausts its budget is an error the
  caller sees** — never a silently skipped state write, which would break §3.5 invariant 1.

### 3.5 Two invariants, and honestly which is enforced where

Draft 2 said "two invariants the schema enforces". Only the second one is:

1. **A state change and its event row are one transaction.** A `unit.state` that advanced without
   a matching `unit_event` makes the event log lie about history, and §7 reads that history.
   **This is enforced by the write layer, not by the schema** — every transition goes through one
   function that writes both tables inside a single transaction, and no other code path issues an
   `UPDATE unit SET state`. SQLite cannot express "this update requires that insert". Calling it a
   schema invariant would misdescribe where the guarantee actually is, which matters to anyone
   auditing the database directly or restoring it from backup.
2. **`outcome` is non-null if and only if `state = 'terminal'`.** This one *is* a `CHECK`
   constraint (§5.2), so a terminal row with no outcome — or a live row carrying one — is
   unrepresentable rather than merely discouraged.

---

## 4. Process architecture

### 4.1 The unit template

One transient unit per unit of work, with this shape:

```
cdl-agent-<unit-id>.service      # transient; created by systemd-run, NOT a shipped template
  Type=simple
  Restart=no                     # overview §8; see §4.4 below
  ExecStart=/usr/lib/cdl/cdl-agent-supervisor --unit-id <id> --launch-id <launch-id>
  Slice=cdl-agent-<unit-id>.slice
```

**It is created by `systemd-run`, and §20.5 is the authority on how.** There is no shipped
`cdl-agent@.service` template: a template cannot carry a per-unit slice, per-unit memory limits, or
the `launch_id` that §4.5 step 3 checks. Draft 3 showed a template here *and* a `systemd-run`
invocation in §20.5, which are two different mechanisms whose unit names would have collided.

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
5. Reaps the child and, **in one transaction**, records its exit status, writes the terminal row
   and **releases the unit's GPU lease** (§11). Draft 3 specified lease release only on the
   reconciliation path (§7.5), so a unit that simply finished normally — the common case — left its
   lease held, and §11.3's live-lease sum would have drifted upward until nothing could be
   admitted. Then it unlinks its socket and exits.

**Why the supervisor and not zellij or `abduco`** (DA2): the deciding argument is D28, not the
local case. Agents on the lab GPU host arrive over ssh, where cdl cannot rely on a multiplexer it
does not control, so a cdl-owned holder is required for the ssh backend regardless. Using the same
holder locally yields one contract and one reconciliation path instead of two. Secondary: zellij's
scrollback is in-memory and dies with the session, so the record of what an agent did would vanish
exactly when the agent finishes — the opposite of what a supervisory system needs.

### 4.3 The attach protocol

`cdl agent attach <id>` is a thin client:

1. Connects to the unit's socket. **More than one client may attach at once, but exactly one is
   the writer** (§4.3.1). Every client receives the same output stream.
2. The supervisor sends a **replay window** — the last *N* bytes of the log (default 64 KiB,
   configurable) — so the client's terminal shows recent context immediately.
3. The client puts its own terminal in raw mode, forwards stdin to the socket, and writes socket
   output to stdout.
4. On `SIGWINCH` the client sends its new dimensions. **The supervisor applies `TIOCSWINSZ` only
   from the writer** (§4.3.1). The supervisor forwards **bytes only**: when the agent's terminal is
   in canonical mode the kernel's line discipline turns `^C` into `SIGINT` itself, and when the
   agent puts its terminal in raw mode it handles those bytes directly. Either way, signal
   translation is **not** the supervisor's job.
5. Detach is a client-side escape sequence and closes only the socket. **The supervisor never
   changes state on client disconnect.**

#### 4.3.1 One writer, many observers

Draft 1 let every attached client write and resize. Both halves are defects, and the second is the
worse one: two clients with different window sizes produce a `TIOCSWINSZ` fight in which the agent's
rendering is wrong for at least one of them continuously, and there is no error anywhere to notice.
Interleaved keystrokes from two writers corrupt input in a way neither operator can attribute.

The arbitration:

- The **first client to attach becomes the writer.** Later clients attach as **observers**: they
  receive the full output stream and their input is discarded, not queued.
- **The writer's dimensions alone drive `TIOCSWINSZ`.** An observer whose terminal is smaller
  renders the writer's geometry and may clip; this is visible to the operator, unlike a size fight.
  `cdl agent attach` prints the writer's dimensions on connect so a mismatch is not a mystery.
- **Takeover is explicit and always available**: `cdl agent attach --takeover <id>`, or the escape
  sequence's takeover key. The supervisor demotes the previous writer to observer and **tells both
  clients, in-band**, which one now holds the terminal. Silent transfer would be worse than a fight.
- **Releasing is implicit on disconnect.** When the writer detaches, the longest-attached observer
  is promoted and told. If no observer remains the unit has no writer, which is normal: the agent
  keeps running and logging regardless, per §4.2.

This is arbitration, not access control. Every client is the same uid — the socket is at
`$XDG_RUNTIME_DIR` with mode 0600 — so the mechanism exists to stop an operator fighting themselves
across two terminals, which with ~16 units is the likely case.

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

### 4.5 The acknowledged launch handoff

The window between "the row says `starting`" and "a supervisor exists" is real and cannot be
removed — a process takes time to start. What can be removed is the *ambiguity* about it, and that
needs two things on the row: **an identity for this launch attempt, and a deadline for it.**

| Column | Meaning |
|-|-|
| `launch_id` | A fresh nonce per launch attempt. The supervisor is passed it and must present it back. |
| `launch_deadline` | Absolute time by which the acknowledgement must have landed. Default 60 s, configurable. |
| `launch_ack_at` | Set by the supervisor's acknowledgement. **Null means admission still owns the row.** |

**The protocol:**

1. **Admission**, in one transaction: grant the leases, write `queued → starting`, generate
   `launch_id`, set `launch_deadline`. `launch_ack_at` stays null.
2. **Admission** starts the systemd unit, passing `launch_id`. **If that command fails, admission
   writes `starting → terminal(launch_failed)` itself** — it still owns the row, so a spawn failure
   is reported as what it is instead of decaying into `lost` at the next reconcile.
3. **The supervisor's first action**, before it opens a PTY or execs anything, is one transaction
   that: checks the row is `starting`, checks `launch_id` matches the one it was passed, sets
   `supervisor_pid`, `boot_id` and `launch_ack_at`. **That commit is the ownership transfer.** A
   `launch_id` mismatch means this supervisor belongs to a superseded attempt: it exits without
   starting anything, and touches nothing.
4. **Cancellation during the window is resolved inside the acknowledgement**, which is what makes
   it race-free. The supervisor's step-3 transaction reads `cancel_requested_at` in the same
   breath; if it is set, the supervisor writes `terminal(cancelled)` and exits **without ever
   exec'ing the agent**. No signal is sent because no process was started.

**What reconciliation may conclude about a `starting` row** (this is §7.2's `L0`, ahead of every
other check):

| Condition | Conclusion |
|-|-|
| `launch_ack_at` null, `now < launch_deadline` | **Launching. Leave it alone.** Not alive, not dead — in progress. |
| `launch_ack_at` null, `now >= launch_deadline` | `terminal(launch_failed)`, reason "supervisor never acknowledged". **Not `lost`**: nothing was ever confirmed running, so there is no lost work to describe. |
| `launch_ack_at` set | The supervisor owns it; fall through to the normal ladder. |

The first row is the one draft 2 lacked, and it is why a reconcile that happens to run during a
launch no longer kills it.

**Both writes are compare-and-swap, because the deadline itself is racy.** A reconciler can read a
row a microsecond before the deadline passes, decide `launch_failed`, and commit it *after* the
supervisor has acknowledged and `exec`'d the agent — leaving a live agent behind a terminal row
whose lease has been freed. Reading and deciding are not the same instant as writing, so neither
side may write unconditionally:

```sql
-- reconciler, L0′: only if nobody acknowledged in the meantime
UPDATE unit SET state='terminal', outcome='launch_failed', ...
 WHERE id=? AND state='starting' AND launch_ack_at IS NULL AND launch_deadline < :now;

-- supervisor, §4.5 step 3: only if nobody gave up on us in the meantime
UPDATE unit SET launch_ack_at=:now, supervisor_pid=?, boot_id=?
 WHERE id=? AND state='starting' AND launch_ack_at IS NULL AND launch_id=?;
```

**Every write into this window is conditional — all four of them.** Draft 4 made two of them
compare-and-swap and left admission's spawn-failure write (step 2) and admission's cancellation
(§3.4) unconditional, which reopened the race from the other side: a `systemd-run` reporting
failure *after* the supervisor already acknowledged would overwrite a `running` row with
`terminal(launch_failed)` and free its lease, leaving a live agent behind a terminal row. Both
carry the same guard:

```sql
-- admission, step 2: the spawn failed -- but only if nobody acknowledged first
UPDATE unit SET state='terminal', outcome='launch_failed', ended_at=:now
 WHERE id=? AND state='starting' AND launch_ack_at IS NULL;

-- admission, cancelling a unit it still owns
UPDATE unit SET state='terminal', outcome='cancelled', ended_at=:now
 WHERE id=? AND state IN ('queued','starting') AND launch_ack_at IS NULL;
```

**Each checks the affected row count and yields if it is zero.** A reconciler that loses exits
without writing an event. A supervisor that loses has been declared failed: it **exits without
`exec`ing the agent**, which is what keeps the outcome honest — the row says nothing ran, and
nothing ran. Admission that loses a spawn-failure race logs the discrepancy and leaves the row to
its supervisor. Whichever commits first wins, and the loser can tell that it lost.

**A backwards clock must not strand a row.** `launch_deadline < :now` is the only exit from
`starting` with a null acknowledgement, so a clock stepping backwards leaves `L0` answering
*"leave it alone"* forever, holding a GPU lease and a §14 slot. `L0` therefore carries a second,
clock-independent bound: a `starting` row whose `created_at` is older than a hard maximum
(default 1 h, always far above `launch_deadline`) is resolved `launch_failed` whatever the
deadline comparison says. Timestamps compare in the one pinned format §5.2 fixes; comparing them
as free-form text is measurably wrong.

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

-- Exactly one row, enforced. A second row makes "what version is this database?" ambiguous
-- at the one moment it must not be: §5.3's startup check, before any other statement runs.
CREATE TABLE schema_version (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    version     INTEGER NOT NULL,
    applied_at  TEXT    NOT NULL
);

-- TIMESTAMP FORMAT, and it is load-bearing rather than a convention. Every TEXT timestamp in
-- this schema is UTC ISO-8601 with milliseconds and a literal Z -- `YYYY-MM-DDTHH:MM:SS.sssZ`,
-- exactly what strftime('%Y-%m-%dT%H:%M:%fZ','now') produces. SQLite compares TEXT
-- lexicographically, so mixed formats compare WRONG rather than failing:
--     '2026-09-01T10:00:00Z'  < '2026-09-01T10:00:00.5Z'  ->  0   (should be 1)
--     '2026-09-01 10:00:00'   < '2026-09-01T09:00:00Z'    ->  1   (should be 0)
-- Both measured. §4.5's `launch_deadline < :now` is an inequality on one of these columns, so
-- an unpinned format is a correctness bug in the launch handoff, not a formatting preference.
-- One helper in the write layer produces every timestamp; nothing formats one inline.

CREATE TABLE unit (
    id                  TEXT PRIMARY KEY,          -- ULID: sorts by creation time
    kind                TEXT NOT NULL CHECK (kind IN ('agent','job')),

    state               TEXT NOT NULL CHECK (state IN
                          ('queued','starting','running','waiting','stopping','terminal')),
    outcome             TEXT CHECK (outcome IN
                          ('completed','failed','launch_failed','cancelled','budget_exceeded','lost')),
    exit_code           INTEGER,

    backend             TEXT NOT NULL CHECK (backend IN ('local','ssh','slurm','hfjobs')),
    remote_id           TEXT,                      -- queue id on a remote backend
    remote_host         TEXT,
    remote_dir          TEXT,                      -- remote working directory (§19)
    remote_pid          INTEGER,                   -- remote-side supervisor pid
    remote_boot_id      TEXT,                      -- boot id OF THE REMOTE HOST; never the local one

    -- Launch handoff (§4.5). launch_ack_at NULL means admission still owns the row.
    launch_id           TEXT,
    launch_deadline     TEXT CHECK (launch_deadline IS NULL OR
                          launch_deadline GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9][0-9][0-9]Z'),
    launch_ack_at       TEXT,

    -- Probe state (§7.2). Two timestamps, because they answer different questions:
    -- last_probe_at is when we last TRIED (so "still checking" is visible), and
    -- last_successful_probe_at is when we last KNEW, which is what staleness means.
    -- Draft 2 had only the first and then described the second in §15.2.
    last_probe_at            TEXT,
    last_successful_probe_at TEXT,
    probe_status        TEXT CHECK (probe_status IN ('alive','dead','unreachable')),

    queued_reason       TEXT,                      -- what a queued unit is waiting for (§14, §15.2)
    waiting_source      TEXT CHECK (waiting_source IN ('adapter','idle')),  -- §9.3, §15.2
    recovered_at        TEXT,                      -- set when §7.3.1 rebuilt this row
    egress_allow        TEXT,                      -- JSON array of permitted hostnames (§12.2)

    adapter             TEXT NOT NULL,             -- 'claude-code' | 'codex' | 'gemini' | 'opencode'
    provider            TEXT NOT NULL,             -- 'anthropic' | 'openai' | ... | 'local'
    model               TEXT,

    -- Reproducibility: what was actually run.
    launch_argv         TEXT NOT NULL,             -- JSON array, REDACTED per §20.3
    launch_prompt       TEXT,                      -- recorded ONCE (§4.4); may be a digest (§20.4)
    launch_prompt_mode  TEXT NOT NULL DEFAULT 'full'
                          CHECK (launch_prompt_mode IN ('full','digest','absent')),
    launch_env_keys     TEXT NOT NULL,             -- JSON array of NAMES only; never values

    -- ON DELETE SET NULL is load-bearing, not decoration. A unit row is never deleted (its
    -- history is the record, and unit_event/spend_ledger/artifact all reference it), but its
    -- worktree and port block ARE deleted, by §6.1. Without these clauses both deletions fail
    -- with FOREIGN KEY constraint failed for any worktree that ever ran a unit -- that is, all
    -- of them -- so `cdl worktree rm` could not execute at all. Measured, not reasoned about.
    -- Denormalised at creation, and NOT nulled when the worktree is collected. The FK below
    -- must be ON DELETE SET NULL for §6.1 to run at all, which means the reference disappears
    -- when the worktree does -- measured. Without these two columns a terminal unit stops
    -- recording which branch its work happened on, which is what §20.1's log retention and
    -- any post-hoc review read. History belongs on the unit row; the FK is only a live link.
    worktree_path       TEXT,
    branch              TEXT,

    worktree_id         TEXT REFERENCES worktree(id)   ON DELETE SET NULL,
    port_block_id       TEXT REFERENCES port_block(id) ON DELETE SET NULL,
    gpu_lease_id        TEXT REFERENCES gpu_lease(id),

    log_path            TEXT NOT NULL,
    supervisor_pid      INTEGER,
    systemd_unit        TEXT,
    boot_id             TEXT,                      -- /proc/sys/kernel/random/boot_id at start

    -- Money is INTEGER MICROS (1 USD = 1_000_000). Never REAL: binary floating point
    -- cannot represent a cent exactly, and a budget ceiling compared with `>=` against an
    -- accumulated sum of REALs drifts in a way that is invisible until it matters.
    vram_mib            INTEGER,                   -- the REQUEST (§11.3); gpu_lease.vram_mib is
                                                   -- the grant. A queued unit has a request and
                                                   -- no lease, so it cannot live only on the lease.
    budget_micros       INTEGER,                   -- per-unit declared budget (D33)
    spend_micros        INTEGER NOT NULL DEFAULT 0,
    tokens_in           INTEGER NOT NULL DEFAULT 0,
    tokens_out          INTEGER NOT NULL DEFAULT 0,
    spend_is_estimated  INTEGER NOT NULL DEFAULT 0,-- see §13.3

    resumed_from        TEXT REFERENCES unit(id),
    cancel_requested_at TEXT,
    created_at          TEXT NOT NULL,
    started_at          TEXT,
    ended_at            TEXT,

    -- §3.5 invariant 2, enforced rather than merely documented.
    CHECK ((state = 'terminal') = (outcome IS NOT NULL)),
    CHECK ((state = 'terminal') = (ended_at IS NOT NULL)),
    -- §3.3: a job has no human in the loop, so it can never be `waiting`. The database
    -- refused nothing here until draft 4; the rule existed only in prose.
    CHECK (NOT (kind = 'job' AND state = 'waiting'))
    -- NO biconditional on waiting_source. Draft 4 had
    --   CHECK ((state='waiting') = (waiting_source IS NOT NULL))
    -- which made `waiting` a TRAP STATE: every exit from it -- to running, to stopping, to
    -- terminal -- failed the constraint, because no transition cleared the column. Measured.
    -- waiting_source is a record of the detector that most recently moved this unit into
    -- `waiting` (§9.3); it is read only while state='waiting' and ignored otherwise.
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
    actor       TEXT NOT NULL    -- who wrote the transition; see §3.4
                  CHECK (actor IN ('cli','admission','supervisor','controller','reconciler')),
    detail      TEXT
);

-- INVARIANT: a worktree row exists exactly as long as its directory exists (§6).
-- Draft 2 kept released-but-not-collected rows, then had to scope one uniqueness constraint
-- around them while leaving `path` permanently reserved -- two bugs out of one bad lifecycle.
-- Deleting the row and the directory in one transaction makes plain UNIQUE correct again:
-- a value is reserved while, and only while, the thing it names exists on disk.
CREATE TABLE worktree (
    id          TEXT PRIMARY KEY,
    repo_path   TEXT NOT NULL,
    branch      TEXT NOT NULL,
    path        TEXT NOT NULL UNIQUE,
    created_at  TEXT NOT NULL,
    UNIQUE (repo_path, branch)
);

-- Same lifetime as its worktree, and the FK behaviour is stated rather than defaulted.
-- ON DELETE RESTRICT is what SQLite already does here; writing it down is the point, because
-- draft 2's §7.6 described reconciling "a port_block whose owner_worktree row is gone" and its
-- acceptance test told an implementer to create that state. Under PRAGMA foreign_keys = ON the
-- deletion just fails, so the scenario could not arise and the test could not have passed.
CREATE TABLE port_block (
    id              TEXT PRIMARY KEY,
    base_port       INTEGER NOT NULL UNIQUE,
    size            INTEGER NOT NULL,
    owner_worktree  TEXT NOT NULL REFERENCES worktree(id) ON DELETE RESTRICT,
    preferred       INTEGER NOT NULL,   -- 1 if the hash's first choice was free
    created_at      TEXT NOT NULL
);

CREATE TABLE gpu_lease (
    id          TEXT PRIMARY KEY,
    unit_id     TEXT NOT NULL REFERENCES unit(id),
    vram_mib    INTEGER NOT NULL,
    acquired_at TEXT NOT NULL,
    released_at TEXT
);

CREATE TABLE spend_ledger (           -- append-only; unit.spend_micros is a cached rollup
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    unit_id     TEXT NOT NULL REFERENCES unit(id),
    at          TEXT NOT NULL,
    provider    TEXT NOT NULL,
    tokens_in   INTEGER,
    tokens_out  INTEGER,
    micros      INTEGER,          -- USD micros; see the note on unit.spend_micros
    estimated   INTEGER NOT NULL DEFAULT 0,
    source      TEXT NOT NULL,    -- 'adapter' | 'provider-api' | 'price-table' | 'remote'
    remote_ref  TEXT              -- the remote's own id for this record; the dedupe key
);

-- Artifacts produced by a job (§15.1 `cdl job artifacts`, §19.8). Draft 1 offered the command
-- with no table behind it.
CREATE TABLE artifact (
    id          TEXT PRIMARY KEY,
    unit_id     TEXT NOT NULL REFERENCES unit(id),
    name        TEXT NOT NULL,    -- the manifest's key for this artifact; dedupe key
    kind        TEXT NOT NULL CHECK (kind IN ('file','dir','log')),
    remote_path TEXT,             -- where it was produced, if a remote backend
    local_path  TEXT,             -- where it was retrieved to, once fetched
    bytes       INTEGER,
    sha256      TEXT,
    fetched_at  TEXT,
    created_at  TEXT NOT NULL
);
CREATE INDEX artifact_unit ON artifact(unit_id);
-- One row per artifact per unit. R3 can import the same terminal result more than once -- two
-- reconcilers, or one retried after a crash between the import and the commit -- and without
-- this the manifest is appended again each time.
-- Local path, not remote: remote_path is NULL for a local job's artifacts, and NULLs do not
-- collide in a UNIQUE index, so keying on it deduplicated nothing for exactly the rows that
-- needed it. `name` is the manifest's own key and is never null.
CREATE UNIQUE INDEX artifact_identity ON artifact(unit_id, name);

-- Imported spend is deduplicated on the REMOTE's record id, which draft 4's comment claimed
-- and its index did not have -- it keyed on (unit_id, source, at), which both admits two
-- imports of one record whose timestamps differ AND rejects two genuine records that share a
-- timestamp, silently dropping spend that §13.2's ceiling depends on. Both measured.
CREATE UNIQUE INDEX spend_import ON spend_ledger(unit_id, remote_ref) WHERE remote_ref IS NOT NULL;
```

**Every state change writes both tables in one transaction** (§3.5 invariant 1). There is no code
path that updates `unit.state` alone: a row whose state advanced without a corresponding
`unit_event` makes the event log lie about history, and §7 reads that history to decide what to do
with a unit it cannot see.

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
5. Directs the operator to `cdl reconcile --rebuild`, which discovers still-running supervisors
   **without reading the registry** — from `cdl-agent@*.service` units and from the runtime sockets
   — `describe`s each, and rebuilds its row from the launch manifest (§7.3.1).

**What `--rebuild` does not recover, stated plainly.** A rebuilt row carries the unit's creation
facts and its current state. Its **spend ledger and event history are gone**, because both lived
only in the destroyed database. Rebuilt rows are therefore marked `recovered`, their `spend_micros`
reset to 0 with `spend_is_estimated` set, and §13.2's daily ceiling is understated for the rest of
that day. A unit whose supervisor is *also* gone cannot be rebuilt at all: nothing on the machine
knows it existed except its log file and manifest, which `--rebuild` lists for the operator as
**orphaned artifacts** rather than resurrecting into rows that would claim a state nobody verified.

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

1. Creates the worktree and its branch. Git enforces uniqueness among **checked-out** worktrees —
   one branch cannot be checked out twice — so collisions between *live* worktrees are impossible by
   construction rather than by policy. That guarantee ends at release: once a worktree is removed,
   git will happily check the branch out again, and §5.2's constraint matches because the row is
   **deleted** with the directory (§6.1) rather than lingering in a released state. Draft 3 said
   the index was "scoped to active rows only", which was left over from the design §6.1 replaced —
   there is no `released_at` to scope on any more.
2. Creates the venv with `uv`, so packages hardlink from one shared cache.
3. Reflink-copies large gitignored directories (`cp --reflink=auto`, free on btrfs).
4. Allocates a port block, **owned by the worktree** (§8).
5. Records the row in `worktree`.

### 6.1 One lifecycle: the row exists exactly as long as the directory

**Worktrees outlive their agent by default.** When a unit reaches `terminal` its worktree is not
touched: the work is usually the point.

Removal is a single operation, and there is no intermediate "released" state. Draft 2 had one —
`released_at` — and it caused two separate defects: `worktree.path` and `port_block.base_port`
stayed reserved forever by rows nothing would ever collect, and the branch-uniqueness index had to
be scoped around released rows in a way that let a second row claim a branch whose directory was
still on disk. A state that means *"this exists but does not count"* is what produced both.

```
cdl worktree rm <id>        # explicit, one worktree
cdl worktree gc [--force]   # bulk: every worktree whose units are all terminal, older than <age>
```

**A filesystem removal cannot be inside a SQL transaction** — `git worktree remove` does not roll
back when the transaction does — so the sequence is ordered to make every crash point land in a
state that is either correct or merely untidy, and never one the schema forbids:

1. Refuse if any unit in this worktree is non-terminal.
2. Refuse if the working tree has uncommitted changes or unpushed commits, unless `--force`.
3. **`rename()` the directory** to a sibling `.cdl-trash-<worktree-id>`. Atomic within one
   filesystem, and it is what makes the rest safe: after it, no path collision is possible.
   **It does not make the worktree invisible to git** — draft 4 claimed that and it is wrong:
   `git worktree list` still shows the entry, marked `prunable`, until `git worktree prune` runs.
4. **One transaction**: `DELETE FROM port_block WHERE owner_worktree = ?` first — the reference is
   `ON DELETE RESTRICT`, so the reverse order fails — then `DELETE FROM worktree WHERE id = ?`.
   Both succeed only because `unit.worktree_id` and `unit.port_block_id` are `ON DELETE SET NULL`
   (§5.2); with plain references the whole command is impossible. **A foreign-key violation aborts
   the statement, not the transaction**, so the caller checks each result and issues an explicit
   `ROLLBACK` — a loop that ignores the error and commits would delete the worktree row and leave
   the block behind.
5. `git worktree prune`, then remove the trash directory.

**Every crash point is recoverable, and recovery must not depend on the rows**, because after
step 4 there are none. `gc` therefore begins by scanning for `.cdl-trash-*` directories **by name**
and running `git worktree prune` unconditionally, before it looks at any row:

| Crash after | State left | How `gc` finishes it |
|-|-|-|
| step 2 | Nothing changed | — |
| step 3 | Trash directory, rows still present, git entry `prunable` | Name scan finds the trash, rows are still there to delete, then prune |
| step 4 | Trash directory, **no rows**, git entry still `prunable` | Name scan finds the trash; prune clears the git entry. Draft 4 iterated rows here, found none, and never pruned — leaving `git worktree add` failing with *"is a missing but already registered worktree"* |

**A `worktree` row whose directory is already renamed away exists between steps 3 and 4**, and
draft 4 claimed that state never occurs. It does, briefly, and §7.6 covers it: a row whose path is
absent while a matching `.cdl-trash-*` sibling exists is an interrupted removal, reported as
**resumable** rather than as corruption.

**Reuse needs the right git command.** After removal the *branch still exists* — correctly; a
branch is not a worktree — so recreating uses `git worktree add <path> <branch>` against the
existing branch. `git worktree add -b <branch>` fails with *"a branch named '<branch>' already
exists"*, which is git working as intended and not a defect to design around.

That is the whole lifecycle, and it is what makes the plain `UNIQUE` constraints in §5.2 correct:
a path or a port is reserved while the thing it names exists, and free the moment it does not.

**The port block belongs to the worktree, not the unit** (§8), so a branch keeps the same
dev-server ports across successive agents. Draft 1 allocated it at worktree creation but released
it when the *unit* terminated, so the second agent on a branch could be handed a different block
while the branch's own tooling still pointed at the old one.

---

## 7. Crash reconciliation

### 7.1 The problem

Rows claiming `starting`, `running`, `waiting` or `stopping` assert that a process exists. After a
reboot, an OOM kill, a supervisor crash or a registry restore, that assertion may be false, and
nothing in the row itself reveals it.

### 7.1.1 Two long-lived services, and why the CLI is not one

Draft 3 named an "admission controller" and a "reconciler" without saying what process either is,
which left `queued` units with no one to advance them once `cdl agent new` exited.

| Service | `systemd --user`, lingering | Owns |
|-|-|-|
| `cdl-admissiond` | one | Every `queued` row: admitting it when leases and limits allow (§11, §14), cancelling it in place (§3.4), and driving §4.5 steps 1–2 |
| `cdl-controller@<host>` | one per remote host | That host's rows after acknowledgement (§19.2) |

`cdl agent new` **inserts a `queued` row and exits.** It does not wait, admit, or launch — so
closing the terminal cannot strand a unit, and a queue that is not draining is a service to
inspect rather than a lost invocation.

**Reconciliation is serialized to one at a time**, by an exclusive advisory lock (a `flock` on a
file beside the registry) taken for the whole pass. Two concurrent passes over the same rows will
both decide, both write, and — where a pass imports a remote result (`R3`) — both import; the
uniqueness indexes in §5.2 make that idempotent rather than duplicative, and the lock makes it
rare. `cdl reconcile` run by hand while the timer fires waits for the lock rather than racing it.

### 7.2 The probe is dispatched on `backend` first

Draft 1 ran one ordered checklist over every row, beginning with *"`boot_id` differs from the
current boot → **Dead**"*. That is **unsafe for anything but a local unit**: `boot_id` is
`/proc/sys/kernel/random/boot_id` *on the Tensorbook*, and a job running on the lab GPU host has no
relationship to it. Rebooting the laptop would have marked every live remote job `lost` and released
its leases — the precise fabrication §7.2 elsewhere forbids. **The identity of a process is a fact
about the machine it runs on**, so the probe dispatches on `backend` before it checks anything.

`cdl reconcile` runs at login (via a `systemd --user` unit ordered after the registry is available)
and on demand, **over rows in `starting`, `running`, `waiting` or `stopping`** — exactly the states
§7.1 says assert that a process exists. For each: select the ladder by `backend`, then take the
first definite answer.

**`queued` rows are deliberately excluded, and draft 3 did not exclude them.** It said "each
non-`terminal` row", which includes `queued` — and a queued unit has no `boot_id`, no systemd unit
and no pid, so `L1`/`L2`/`L3` would have concluded **Dead** and `R4`/`R5` `lost`. Every queued unit
on the machine would have been killed by any reconcile, including the one that runs at login. A
queued row asserts nothing about a process; it is owned by the admission controller (§3.4), and
what reconciliation does with it is **report** it, with its `queued_reason`, if no admission
controller is running to make progress on it.

**Every backend, first** — the launch window (§4.5), because a row still being launched is neither
alive nor dead and draft 2 had no way to say so:

| # | Check | Conclusion |
|-|-|-|
| L0 | `state = 'starting'`, `launch_ack_at` null, `now < launch_deadline` | **Launching. Leave the row alone.** |
| L0′ | `state = 'starting'`, `launch_ack_at` null, and either `now >= launch_deadline` or `created_at` older than the hard maximum | `terminal(launch_failed)` — the supervisor never acknowledged. Not `lost`: nothing was confirmed running. |
| L0″ | `state = 'starting'`, `launch_ack_at` **set**, but the ladder below finds no process | `terminal(launch_failed)` — the supervisor acknowledged, then died before reaching `running`, so it never `exec`'d the agent. Draft 4 fell through to `L2` here and wrote `lost`, which §3.2 reserves for a unit that *was* confirmed running. A unit that never left `starting` did not lose work; it failed to launch. |

**`backend = 'local'`** — the local boot is the right frame of reference:

| # | Check | Conclusion |
|-|-|-|
| L1 | `boot_id` differs from the current boot | **Dead.** No local process from a previous boot survives. |
| L2 | `systemctl --user is-active <unit>` is not `active` | **Dead.** |
| L3 | `supervisor_pid` absent, or present but not a `cdl-agent-supervisor` with the matching unit id in its cmdline | **Dead.** PID reuse is why the cmdline is checked, not just existence. |
| L4 | The unit's socket exists and answers `describe` (§7.3) | **Alive.** Re-adopt. |
| L5 | L1–L3 all indicate a live process, but L4 is silent or absent | **Alive, degraded.** The process exists — that is what L2 and L3 established — so it is not dead, and the row is left alone. `cdl status` marks it *unreachable supervisor*: attach will not work, the log is still being written, and the socket is **not** unlinked (§7.6). |

**L5 exists because draft 3 had no entry for it**, and the omission was not harmless: with no
conclusion, the resource pass would reach a live supervisor's silent socket and unlink it under
§7.6 tier 1, severing attach for a healthy agent. A socket may be removed only when the ladder has
concluded its unit is **dead**, never merely because it did not answer.

**`backend = 'ssh'`** — the local boot is irrelevant; only the remote host's frame counts. **The
terminal result is read before any liveness check**, because the commonest remote event of all is a
job finishing successfully, and a finished job has no process:

| # | Check | Conclusion |
|-|-|-|
| R1 | Host unreachable | **Unknown.** Record the attempt; leave `state` untouched. Never `lost`. |
| R2 | Reachable, but the marker's `unit_id`/`launch_id` do not match the row | **Not ours.** Report the directory as unattributable; conclude nothing about the unit. |
| R2′ | Reachable, and the marker is **absent** (the remote directory was collected by §19.10, or the host was rebuilt) | Fall through to `R4`–`R6`. A missing marker is not a mismatch: draft 4's `R2` matched nothing here and concluded nothing, so the row stayed `running` for ever with no ladder row able to resolve it. |
| R3 | Reachable, marker carries a **complete and verified terminal result** (§19.6) | **Finished.** Import it: `outcome`, `exit_code`, `started_at`, `ended_at`, artifacts. |
| R4 | Reachable, no terminal result, remote boot id differs from `remote_boot_id` | **Dead** (`lost`). The remote machine rebooted mid-run. |
| R5 | Reachable, same boot, no result, no process matching `remote_pid` **and** the unit id in its cmdline | **Dead** (`lost`). |
| R6 | Reachable, same boot, process matches | **Alive.** |

**R3 before R4/R5 is the whole point, and draft 2 had it the wrong way round.** There, a job that
completed normally left no process, fell through to the liveness check, and was written
`terminal`/`lost` — so *the successful path was the one that lost its result*. §19.9 even had the
remote supervisor writing a terminal record, and nothing ever read it.

R4 is the exact analogue of L1, against the boot id that actually governs the process. It is why
§5.2 stores `remote_boot_id` as a distinct column: reusing `boot_id` for both is how draft 1's bug
would grow back.

**A corrupt or partial terminal result is treated as absent**, so the row falls through to R4/R5
and resolves to `lost` — with the corruption named in `unit_event.detail`. That is the honest
outcome: `lost` means "we do not know what happened" (§3.2), and a half-written result is exactly
that. §19.6 makes complete results atomic so this stays rare.

Rows concluded dead are written `terminal` / `lost`, with a `unit_event` recording `actor =
'reconciler'` and the check id (`L2`, `R5`, …) that decided it.

**Two timestamps, because "when did we last look" and "when did we last know" are different
questions.** Every attempt writes `last_probe_at` and `probe_status`; only a reachable probe writes
`last_successful_probe_at`. Draft 2 had one column, said every attempt wrote it, and then described
`cdl status` as showing *"the age of the last successful probe"* — which that column could not
answer, since a host down for a week would show a probe age of seconds.

**An unreachable remote host is not evidence of death.** Such rows are left in place, their
`state` untouched, and `cdl status` marks them *stale* with the age of `last_successful_probe_at`. A
network partition must never be allowed to fabricate a `lost` outcome, because that would release
the unit's GPU lease and port block while the work is still running.

### 7.3 Re-adoption, and the `describe` handshake

A supervisor that is still alive is re-adopted rather than restarted: its socket is live, its log is
appending, and the registry resumes trusting it. This is the normal case after a terminal crash or a
logout, and it is why `linger` is enabled for the user.

Re-adoption is a **handshake, not an assumption**. The supervisor answers a `describe` request on
its socket with its unit id, its `launch_argv` digest, its log path, its current lifecycle state,
its start time, and — **required, because L3 checks them** — its **pid and boot id**. Draft 3 omitted
those two, so a row rebuilt by §7.3.1 had a null `supervisor_pid` and the very next reconcile
concluded `L3` → dead → `lost`: recovery that undid itself one pass later. Reconciliation compares that to the row and re-adopts only on a match; a socket at
the expected path answering with a *different* unit id is a stale socket, not the unit, and the row
falls through to the next check. Authentication is `SO_PEERCRED` against the socket's own uid, which
is sufficient because the whole system is single-user by design and the socket is mode 0600 inside
`$XDG_RUNTIME_DIR`.

**`describe` has a timeout — default 2 s, configurable** — and exceeding it counts as *silent*,
not as dead. Without a stated bound "the socket did not answer" has no operational meaning, `L5`
cannot be reached deterministically, and §18.2.3's silent-socket test has nothing to induce.

#### 7.3.1 Discovery without the registry

`describe` also makes re-adoption possible when the registry cannot name the rows to probe — the
case §5.4 creates. Reconciliation can enumerate live supervisors **independently of the database**,
from two sources that do not depend on it:

1. `systemctl --user list-units 'cdl-agent-*.service'` — one spelling, §20.5's
2. The sockets in `$XDG_RUNTIME_DIR/cdl/*.sock`

Each is `describe`d. Any supervisor that answers is real regardless of what the registry knows.

**A rebuilt row carries no live references.** `worktree_id`, `port_block_id`, `gpu_lease_id` and
`resumed_from` all point at rows a fresh database does not have, so a rebuild that copied them
from the manifest fails with `FOREIGN KEY constraint failed` — measured. The rebuild writes them
**null** and restores the *facts* instead, from the manifest's `worktree_path` and `branch`
(§5.2), which is why those two columns are denormalised onto the unit in the first place. The
worktree directory itself is reported as unmanaged (§7.6) rather than re-adopted.

**What a handshake cannot recover is the unit's creation facts** — its launch prompt, budget,
provider, worktree and port block are not things a running supervisor can be trusted to reconstruct
from memory after its database is gone. So the supervisor writes them **once, at launch**, to a
sidecar manifest beside its log: `<log_path>.manifest.json`, mode 0600, containing exactly the
immutable columns of §5.2 (never the environment *values*, per §10.3). The manifest is what makes
§5.4's recovery work: rebuild the row from the manifest, take the live
state from `describe`, and mark the row `recovered` in `unit_event.detail` so a rebuilt row is never
mistaken for an original one. Mutable history — the spend ledger and the event log — is genuinely
lost, and §5.4 says so.

### 7.4 Restored-but-stale rows

The case a restore actually creates. After a registry restore, `cdl reconcile` runs with **every**
row treated as unverified. Check 1 resolves nearly all of them, because a restored registry
necessarily carries a `boot_id` from a previous boot. Rows for remote backends are probed; those
whose hosts are unreachable are marked stale rather than lost, per §7.2.

### 7.5 Lease release

Reconciling a unit to `terminal` releases its **GPU lease** in the same transaction as the state
write — the same rule §4.2 step 5 applies on the normal path. **Every path to `terminal` releases
the lease**, and there is no other way to release one. A lease outliving its unit is how a machine
slowly runs out of GPU capacity with nothing visibly wrong.

**The port block is not released here**, because it belongs to the worktree and outlives the unit by
design (§6.1, §8). Blocks are deleted with their worktree. The two resources have genuinely
different lifetimes: VRAM is contended right now, a port block is reserved for as long as the
branch it serves exists.

### 7.6 Reconciling the resources that outlive units

§7.2 reconciles *units*. Some resources outlive them and can be left stale in a way no unit probe
sees, so `cdl reconcile` makes a second pass. **Two things are separated here that draft 2 ran
together**, and both were wrong:

**What actually outlives a unit, and what merely leaks.** Worktrees and port reservations outlive
their units *by design* — the work is the point and the branch keeps its ports (§6.1). A
supervisor's **socket and service do not**: the supervisor unlinks its socket and exits once it has
written the terminal row (§4.2), so a socket that is still there afterwards is a **leak, not a
policy**. Draft 2 lumped all four together as "deliberately outlive", which reads as though a
lingering socket were intended.

**Three tiers of disposal, because "reports rather than removes" was not true as written.** Draft 2
claimed nothing here deletes a file and, in the same table, had reconcile unlinking sockets — a
socket *is* a filesystem entry, and unlinking it *is* deletion. The distinction that actually
matters is not file-versus-row, it is **whether the thing holds data nobody can reconstruct**:

| Tier | Rule | Applies to |
|-|-|-|
| **1 · Ephemeral** | Reconcile **removes** it, no confirmation | A socket belonging to a unit **the ladder concluded is dead**; a failed systemd unit's metadata (`systemctl --user reset-failed`). Neither holds data. **A silent socket is not sufficient** — `L5` covers a live supervisor whose socket stopped answering, and unlinking that severs attach for a healthy agent. Draft 4 said "a socket whose `describe` did not answer", contradicting `L5` one section above. |
| **2 · Data-bearing** | Reconcile **only reports** | Worktrees, remote directories, log files, unmanaged directories. Removing any of these can destroy uncommitted work. |
| **3 · Administrative** | Only an explicit command removes it | `cdl worktree rm` / `gc` (§6.1), `cdl job gc` (§19.10). Confirmation and refusal rules live there. |

The resource pass:

| Stale shape | How it arises | Tier | What reconcile does |
|-|-|-|-|
| A worktree whose units all reached `terminal` | The operator finished and moved on | 2 | Lists it as **collectable**, with branch, age and whether it has uncommitted changes or unpushed commits. Removes nothing. |
| A `cdl-agent-*.service` or socket whose row is **absent** | Registry loss (§5.4) | 1 / 2 | `describe`d. Answers → rebuild the row from the launch manifest (§7.3.1). Silent → unlink the socket and `reset-failed` the unit. |
| …whose row is **terminal** | Registry restored from a backup older than the unit's completion, or a supervisor that outlived its own terminal write | — | **Never re-adopted.** `terminal` is final (§3.1) and no actor may leave it, so a running supervisor here is the anomaly, not the row. cdl asks it to shut down, reports the conflict with both timestamps, and unlinks the socket only once it has exited. Draft 3's "answers → re-adopt" would have written `terminal → running`, which the state machine forbids and §3.4 gives nobody the authority to do. |
| A worktree directory on disk with no `worktree` row | Registry loss (§5.4), or a manual `git worktree add` | 2 | Reported as unmanaged. cdl does not adopt directories it cannot prove it created, and does not delete them either. |
| A `worktree` row whose `path` is absent, with a matching `.cdl-trash-*` sibling | A removal interrupted between §6.1 steps 3 and 4 | 3 | Reported as a **resumable removal**, finished by `cdl worktree gc`. |

**There is no orphaned-port-block row, and draft 2's was impossible.** It described reconciling *"a
`port_block` whose `owner_worktree` row is gone"* and its acceptance test instructed an implementer
to create that state by deleting the worktree row out from under a live block. With
`PRAGMA foreign_keys = ON` and an `ON DELETE RESTRICT` reference (§5.2), **that deletion fails** —
the state cannot arise, and the test would have failed at its first step. §6.1 deletes the block
first, inside the same transaction, which is the real answer.

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
3. **Collision detection** against every `port_block` row. There is no released-but-present state
   to exclude: a row exists exactly while its block is reserved (§6.1).
4. **Documented fallback**: linear probe upward from the preferred block, wrapping once. `preferred`
   is recorded as `0` when the fallback was used, so drift from the deterministic ideal is visible.
5. **Exhaustion is an error**, not a wrap-into-someone-else's-block: `launch_failed` with a message
   naming the range and the number of live blocks.

**The block is owned by the worktree** (`port_block.owner_worktree`), allocated with it and deleted
with it by `cdl worktree rm` / `gc` (§6.1). Every unit that runs in a worktree uses that worktree's
block; a unit terminating does not free it. This is the model §6 needs: a branch's dev server keeps its port
across a sequence of agents, and the number of live blocks tracks the number of live *branches*
rather than the number of agent launches.

A unit with no worktree — every job, and any agent launched with `--no-worktree` — gets no port
block. Nothing in the job path binds a port.

Ports are recorded, not enforced — nothing prevents a process binding outside its block. The
registry's purpose is to stop cdl *itself* handing the same block to two worktrees.

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

### 11.3 Sizing, and what a lease actually is

A unit declares `vram_mib`, recorded **on the unit row** at creation (§5.2) — the lease records the
*grant*, and a `queued` unit has a request with no lease yet, so the request cannot live only on
`gpu_lease`. Admission grants a lease when the sum of live leases plus the request fits the
budget (total VRAM minus a configurable reserve for the compositor and display, default
1024 MiB).

**A lease is an admission ceiling, not a measurement, and the two will drift.** Draft 1 said the
swap layer "honours" the lease, which overstates what cdl knows. llama-swap decides which models are
resident and when to evict them; cdl does not sit in the inference path and cannot make VRAM appear
or disappear. So:

- The lease sum is an **upper bound cdl refuses to exceed when admitting**, and nothing stronger.
- Two units sharing one model through llama-swap consume **one** model's VRAM while holding two
  leases, so the sum over-counts and admission is conservative. That is the safe direction.
- A model llama-swap has not yet evicted keeps VRAM after its lease is released, so the sum can
  also under-count transiently. That is the unsafe direction, and it is why the reserve exists.

**Admission therefore reconciles against the device before granting.** It reads actual free VRAM
(`nvidia-smi --query-gpu=memory.free`) and grants only if *both* the lease arithmetic and the
measured free memory admit the request. When the two disagree by more than a configurable margin,
the measurement wins and the discrepancy is recorded.

The honest summary: **cdl admits work it believes will fit, and verifies against the device rather
than against its own bookkeeping.** An out-of-memory failure inside `llama-server` remains possible
and surfaces as an ordinary unit failure.

### 11.4 The thermal gate

Overview §16.5 makes this component the enforcement point: policy *"has to be throttling, temperature
thresholds, whether sustained local inference requires AC power, and **refusal to launch local jobs
when conditions are unsafe**, which makes it an input to GPU admission control in
`cdl-agent-lifecycle`."*

Admission therefore consults a gate owned by `cdl-first-boot-and-environment`, which returns
`allow` / `deny(reason)`. This component does not define the thresholds; it defines that they are
consulted, that a denial produces `launch_failed` with the reason shown to the operator, and that the gate is
re-consulted on every admission rather than cached.

**The M0 firmware walk hardened this.** No fan control exists in firmware *or* OS on this machine,
so throttling and refusal-to-launch are the only mechanisms available — not a fallback. The levers
were measured present: `intel_pstate` exposes `no_turbo` and `max_perf_pct`.

---

## 12. Sandbox — T4a and T4e

The overview marks both rows **Open**, and says *"none may be closed by assertion."* This section
answers both by mechanism, and is exact about which is closed *when*:

| Row | Status after this spec |
|-|-|
| **T4e** — agent reads other worktrees, `$HOME`, other agents' state | **Closed by §12.1, in slice 1.** The bubblewrap policy is one of the first things built, and §18.6 tests it. |
| **T4a** — agent exfiltrates secrets over permitted egress | **Defined, and closed in slice 4** (§12.2 stage 2). Until then it is *accepted explicitly*, which is the alternative the overview itself offers: *"must define an egress policy, or this is accepted explicitly rather than by omission."* |

Saying T4a is closed while slice 1 ships without the mechanism would be the assertion the overview
forbids. It is specified here, sequenced in §21, and open until then.

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

The unit's own log is written by the *supervisor*, which runs outside the sandbox, so the agent
cannot rewrite its own history.

### 12.2 T4a — network egress policy

> *"Agent exfiltrates secrets over permitted network egress ... No control in v1 as designed. The
> sandbox's network policy is the only possible boundary and is currently unspecified. Open.
> `cdl-agent-lifecycle` must define an egress policy, or this is accepted explicitly rather than by
> omission."*

The policy is delivered in **two stages**, because one of them is buildable now and the other is a
subsystem. Draft 1 stated the endpoint without the topology, which made a substantial piece of
network engineering read like a settled detail.

#### Stage 1 — `cdl`'s `--net=none`, and it is all that slice 1 ships

The unit runs with **no network namespace connectivity at all**: no interfaces but loopback, no
routes, no resolver. `--net=none` is cdl's flag; `bwrap --unshare-net` is the implementation. It has
no moving parts and is **strictly stronger than any allow-list** — there is no egress to control.

It is the **default, and sufficient, for two cases**:

- **Units whose provider is `local`**, which lose nothing: llama-swap is reached over a unix socket
  bind-mounted into the sandbox, and a unix socket needs no network namespace.
- **The whole of slice 1**, whose test adapter (§21) makes no network calls at all.

**What stage 1 does *not* do is serve an API-backed agent.** Claude Code and its peers speak HTTPS
to a provider over TCP, and they read their credentials from their own environment (§10.3) — the
supervisor cannot proxy on their behalf without terminating and re-originating their traffic, which
is stage 2's job. So between slice 2 and slice 4, **an API-backed unit runs with ordinary
unrestricted egress**, which is precisely the state **overview §5** (the threat model) records for
T4a today. That is a
gap this spec carries openly rather than one it closes early; §21 is where it closes.

#### Stage 2 — controlled egress for units that need the open internet

Some work genuinely needs it: `pip`/`npm` installs, `git fetch` from a forge, documentation lookups.
For those:

- The unit's namespace is connected to nothing but a **per-unit unix socket**, bind-mounted at a
  fixed path, on which a **cdl-run `CONNECT` proxy** listens. There is no veth pair, no bridge, no
  NAT, and no IP route out of the namespace — the socket is the only egress path.
- **The socket is the unit's identity.** Because each unit gets its own socket, the proxy knows
  which unit is calling from *which socket accepted the connection*, and applies that unit's
  allow-list. No tokens, no credentials, nothing for an agent to steal or forge — an agent cannot
  reach another unit's socket because it is not mounted in its namespace (§12.1).
- **DNS does not exist inside the namespace.** No resolver is configured and no UDP egress is
  possible. The agent hands the proxy a *hostname* in the `CONNECT` request and the proxy resolves
  it. This is what makes hostname allow-listing enforceable rather than advisory: an agent cannot
  resolve a name to an IP and then connect to the IP behind the list's back.
- Allow-listing is by **hostname**, not IP, because provider APIs sit behind CDNs whose address
  sets change without notice; an IP list would break working agents and tempt an operator into
  disabling the whole mechanism.
- The list is per-unit — its adapter's provider endpoints, its repository's configured git remotes,
  and its toolchain's package indexes — and is recorded in `unit.egress_allow` (§5.2), so what an
  agent was permitted to reach is auditable after the fact.
- **`git` over SSH works, and needed saying.** A `CONNECT` proxy carries arbitrary TCP, not only
  HTTP, so `ssh` reaches an allow-listed forge through it via `ProxyCommand`, which cdl writes into
  the unit's sandboxed SSH config pointing at the unit's socket. Port 22 to allow-listed hosts only.
  Without this, stage 2 would have silently broken every `git@github.com:` remote — the common case.
- **Teardown is the supervisor's**, in the same path that reaps the child: the namespace dies with
  its last process, and the supervisor unlinks the socket and closes the proxy listener. A crashed
  supervisor leaves a stale socket in `$XDG_RUNTIME_DIR`, which `cdl reconcile` removes once it has
  established that no live supervisor answers `describe` on it (§7.3).

**Stage 2 does not ship in the first slice.** It is specified here so the schema and the sandbox
interface can carry it, and so §21's ordering has something concrete to defer.

**Honest limits of stage 2, stated because the threat model demands honesty over completeness.**
Two, and neither is closable by this mechanism:

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
consequence of that assumption being wrong is an unsandboxed agent. cdl checks it itself.

---

## 13. Spend controls (D33)

D33, verbatim: *"Spend controls are owned by `cdl-agent-lifecycle`, best-effort but not unowned.
Minimum: per-job declared budget, per-provider concurrency ceiling, global daily warning and
hard-stop where the API permits, runtime and token accounting, cost visible in `cdl status`, and
defined behaviour when a provider exposes no reliable cost data."*

### 13.0 What "enforced" can mean here

D33 says spend control is *"best-effort but not unowned"*, and the design must be exact about which
half applies where, because the two look identical in a status table and are not.

**cdl controls admission, not requests.** It decides whether a unit starts; it does not sit between
an agent and its provider, so it cannot refuse an individual API call. That fixes what is possible:

| Control | Status | Why |
|-|-|-|
| Refusing to **start** a unit when the daily ceiling is reached | **Enforced** | cdl owns admission |
| Refusing to start a unit whose declared budget is already spent | **Enforced** | Same |
| **Terminating** a running unit that exceeds its budget | **Enforced, after the fact** | cdl can kill the process, but only once it has observed the overspend — the request that crossed the line was already paid for |
| Preventing a single request from exceeding a budget | **Not possible** | Would require cdl to proxy provider traffic and parse every request |
| Knowing spend in real time | **Observed, best-effort** | §13.3; many CLIs report cost only after a response, some not at all |

So a per-unit budget is a **stop-loss, not a cap**: overshoot is bounded by one request's cost plus
the detection interval, not by zero. `cdl status` and the docs use that word, because "budget" reads
like a cap and would be believed as one.

### 13.1 Per-unit budget

`--budget <usd>` at creation, converted to micros and recorded in `budget_micros` (§5.2). On observed
exceedance the supervisor drives `stopping → terminal(budget_exceeded)` and records the overshoot. Absent a budget, the global ceiling (§13.2) still applies.

### 13.2 Global daily ceiling

Two thresholds in config: a **warning** level, shown in `cdl status` and by the notifier, and a
**hard stop** level, at which admission refuses new units. Running units are not killed by the
global ceiling — only new admissions are refused — because killing work already paid for to save
money is the wrong trade.

### 13.3 When a provider exposes no reliable cost data

The case D33 requires a defined behaviour for.

1. If the adapter reports usage, use it (`source = 'adapter'`).
2. Otherwise, if the provider offers a usage API, poll it (`source = 'provider-api'`).
3. Otherwise, estimate from a **shipped price table** keyed by model (`source = 'price-table'`), and
   set `spend_is_estimated`.

The price table is versioned and dated, and `cdl doctor` warns when it is older than a configurable
age. A stale price table produces confidently wrong numbers, which is worse than obviously missing
ones.

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
              [--budget USD] [--prompt-file F] [--vram MIB] [--no-worktree]
              [--no-record-prompt]              # §20.4
cdl agent list | cancel <id> | logs <id> [-f] [--raw]   # --raw: §20.2
cdl agent attach <id> [--takeover]          # §4.3.1: writer if none, else observer
cdl job submit [--backend local|ssh|slurm|hfjobs] ... | list | status <id>
              | logs <id> [-f] | cancel <id>     # local is the default; §3.3
cdl job artifacts <id> [--fetch]            # §19.8
cdl job gc --host <h> [--force]             # §19.10; remote directories
cdl status [--json] [--attention]
cdl worktree new <branch> | list | rm <id> [--force] | gc [--force]   # §6.1
cdl reconcile [--rebuild]                   # --rebuild: after registry loss, §7.3.1
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
- **`NOTE`** carries exactly one short reason, and each has a column behind it rather than being
  reconstructed at render time: why a unit is queued (`queued_reason`); that a remote row is stale
  and how long since it was last *reachable* (`last_successful_probe_at` with `probe_status`); that
  a cancel is recorded but undelivered to an unreachable host (`cancel_requested_at` with
  `probe_status = 'unreachable'`, §19.9); that a row was rebuilt after registry loss
  (`recovered_at`); that a `waiting` came from the idle heuristic rather than the adapter's pattern
  (`waiting_source`, §9.3). The last two were added in draft 4 — draft 3 made this promise while
  leaving one of them in `unit_event.detail` and the other nowhere at all.
- **`SPEND` is a stop-loss reading, not a cap**, and §13.0 governs what it can be trusted to mean.
- **`--json`** emits the same data with stable field names, and is the interface the notifier and
  any status bar consume. Human formatting is never parsed by another component.
- **Degraded, never blank.** If a remote backend cannot be probed, its rows still render, marked
  stale. A status surface that hides what it cannot verify is worse than one that admits it.

---

## 16. Where this spec cites new evidence against the frozen overview

Two places, both permitted because the overview allows amendment *"on new evidence from a spike, a
hardware capture, or a component spec."*

1. **Overview §8's "one inference server"** is preserved rather than contradicted, but its *content*
   is now specified as llama-swap + `llama-server` (§10.1), which the overview did not name.
   **This is a divergence and needs declaring as one.** Overview §7.1 routes the LLM layer — and
   the llama-swap rationale with it — to `cdl-first-boot-and-environment`, marking the rationale
   "not yet rewritten anywhere". Draft 4 read that as *no destination* and claimed this spec was
   it, which took content the frozen document assigns elsewhere. The split that actually holds:
   **`cdl-first-boot-and-environment` owns installation, the model store and packaging**
   (§1.2 already says so); this spec specifies only the **serving topology**, because §11's GPU
   admission is meaningless without knowing what holds VRAM resident. The rationale text still
   belongs to that other spec.
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

**Then kill the supervisor and assert nothing restarts it.** Draft 4's sequence passes unchanged
under `Restart=always`, so it never tested §4.4's `Restart=no` — the guarantee the whole
no-replay argument rests on.

### 18.2 Reconciliation

Each of these is a separate test, and the last two are the ones draft 1 would have failed:

1. `SIGKILL` a unit's supervisor, run `cdl reconcile`; the row becomes `terminal`/`lost` with a
   `unit_event` naming the reconciler and the deciding check id.
2. Reboot with a local unit running; check `L1` resolves it.
3. Restore a registry backup; every row is re-probed.
4. Make a remote host unreachable; its rows are marked **stale, not lost**, `last_probe_at`
   advances, and — the assertion that matters — **`last_successful_probe_at` does *not*.** Without
   that second clause the test passes on the single-column design this split was meant to fix.
5. **Reboot the laptop with a remote job still running on a reachable host.** The job must remain
   `running`, and **`R6`** must be the deciding check — `R4` is the remote-reboot case and concludes
   `lost`. This is the regression test for the draft 1 defect in which the local `boot_id` was
   consulted for every backend (§22.2 finding 2).
6. **Queued units survive a reconcile.** Queue several units behind a concurrency limit and run
   `cdl reconcile`. **Every one is still `queued` afterwards.** Draft 3 ran its ladders over each
   non-`terminal` row, so a queued unit — with no `boot_id`, no service and no pid — would have been
   concluded dead at `L1`; the login reconcile would have emptied the queue every boot.
7. **A live supervisor that does not answer.** Make a running unit's socket unresponsive while the
   process stays alive. `L5` marks it *unreachable supervisor*, the row stays `running`, and **the
   socket is not unlinked** — reconcile may remove a socket only after concluding its unit is dead.
8. **A supervisor whose row is terminal.** The setup has to produce that pairing directly — a
   backup taken *before* completion restores a `running` row, not a terminal one, so draft 4's
   description could not create the state it tested. Instead: let a unit reach `terminal`, then
   start a supervisor process for it that answers `describe` (a stale supervisor that outlived its
   own terminal write). The row **stays terminal**, is never written back to `running`, the
   conflict is reported with both timestamps, and the socket is unlinked only after it exits.
9. **Two reconcilers at once.** Run two passes concurrently over the same rows; the advisory lock
   serializes them, and a remote result imported twice produces **one** artifact row per artifact,
   not two.
10. **Corrupt the registry, then `cdl reconcile --rebuild`.** Live supervisors are rediscovered from
   their systemd units and sockets, their rows rebuilt from the launch manifests and marked
   `recovered`; a unit whose supervisor is also gone is reported as an orphaned artifact and **not**
   resurrected into a row (§5.4).

### 18.2.1 The launch window (§4.5)

The four cases draft 2 could not distinguish:

1. **Reconcile during a launch.** Start a unit and run `cdl reconcile` while it is `starting` and
   before acknowledgement, within the deadline. The row is **untouched** — not `lost`, not
   `launch_failed` — and the unit goes on to reach `running`. This is the regression test for the
   race; run it in a loop, because it is a timing bug and one pass proves little.
2. **Spawn failure.** Make `systemd-run` fail (an invalid property is enough). The unit reaches
   `terminal`/`launch_failed`, the deciding `unit_event` names `actor = 'admission'`, and the
   message names the failure. It is never `lost`.
3. **Deadline passed unacknowledged.** Start a unit whose supervisor exits before acknowledging.
   After `launch_deadline` it becomes `terminal`/`launch_failed` — again not `lost`, because
   nothing was ever confirmed running.
4. **Cancellation during handoff.** Set `cancel_requested_at` between the `starting` write and the
   acknowledgement. The unit reaches `terminal`/`cancelled` and no signal is sent. **Assert the
   agent binary never ran** — via a test adapter that records its own invocation to a file — not
   merely that the row is right. A supervisor that `exec`s and then checks would pass a row-only
   assertion while violating §4.5 step 3.
5. **Superseded launch.** Run a supervisor carrying a stale `launch_id`. It exits without writing
   anything, the row's `launch_ack_at` stays null, `supervisor_pid` is unchanged, and — again by
   the adapter's own record — **the agent binary never ran**.
6. **The deadline race.** Hold a reconciler between reading a past-deadline row and writing its
   `launch_failed`, and let the supervisor acknowledge in the gap. **Exactly one wins**, and the
   outcome is consistent either way: if the supervisor won, the row is `running` and the reconciler
   wrote nothing; if the reconciler won, the row is `launch_failed` and **the agent binary never
   ran**. Assert the process, not just the row — the failure being tested for is a live agent
   behind a terminal row whose GPU lease has been freed.

### 18.2.1b The database refuses what the prose forbids

Run against a fresh database built from §5.2's DDL, since these are the rules an implementer would
otherwise have to remember: a `job` in `waiting` is rejected; a second `schema_version` row is
rejected (with `UNIQUE constraint failed`, not `CHECK` — draft 4's test named the wrong error); an `actor` outside the five is rejected; `state='terminal'` with a null `outcome` or null
`ended_at` is rejected; `waiting` without a `waiting_source` is rejected. Each must fail with a
`CHECK constraint failed`, not merely be avoided by convention.

**And the sequence §6.1 depends on**: create a worktree, a port block and a terminal unit
referencing both; run §6.1 step 4 in one transaction; it **succeeds**, the unit row survives with
both references nulled, and the same branch, the same path and the same `base_port` can all be
allocated again. Draft 3 failed this at the first `DELETE`.

### 18.2.2 Remote completion and its failure modes

1. **A remote job that succeeds is `completed`, not `lost`.** Run a job to normal completion, then
   reconcile. It imports the terminal result: `outcome = 'completed'`, the real `exit_code`, real
   timestamps. **This is the regression test for the draft 2 defect in which the successful path
   was the one that lost its result.**
2. **Remote crash with no result.** Kill the agent **process** on a still-reachable host, leaving
   no result record. `R5` fires and the unit is `lost` — correct, because nothing knows what
   happened. Killing the *host* instead tests `R1`, which must yield **unreachable, never `lost`**
   (test 4 above); draft 4 conflated the two and left `R5` with no test at all.
3. **Partial result write.** Truncate `.cdl-result.json` mid-file, and separately corrupt its
   `record_sha256`. Both are treated as **absent**: the unit resolves to `lost`, never
   `completed`, and `unit_event.detail` names the verification failure.
4. **Mismatched identity.** Point a row at a `remote_dir` whose marker carries a different
   `unit_id`. R2 fires: the directory is reported unattributable and the unit's state is not
   changed.
5. **Reboot the laptop with a remote job running on a reachable host.** It stays `running` and
   `R6` decides it — the local `boot_id` is never consulted for a remote row.

### 18.2.3 Stale resources (§7.6)

Finish a unit and leave its worktree in place; `cdl reconcile` lists it as **collectable**, says
whether it has uncommitted changes, and removes nothing. Leave a socket behind whose supervisor is
dead; reconcile unlinks it after `describe` is silent, and re-adopts instead when `describe`
answers. Create a worktree directory with no row; it is reported unmanaged and **not** deleted.

**Deleting a `worktree` row while a `port_block` references it must fail** with a foreign-key
error — this asserts the constraint that made draft 2's "orphaned port block" scenario impossible,
and draft 2's test asked an implementer to produce that state. `cdl worktree rm` succeeds because
it deletes the block first, in the same transaction (§6.1).

### 18.3 State-machine invariants

- **Queued cancellation.** Cancel a unit that is still `queued` behind a concurrency limit. It
  reaches `terminal`/`cancelled` **without a supervisor ever being started** — no systemd unit, no
  PTY, no log — and the deciding `unit_event` names `actor = 'admission'` (§3.4).
- **Pre-handoff `launch_failed`.** Request an unsupported adapter/provider pair; the unit reaches
  `terminal`/`launch_failed` written by admission, with no supervisor started.
- **The schema refuses illegal rows.** Writing `state = 'terminal'` with a null `outcome`, or a
  non-terminal state carrying one, is rejected by the `CHECK` constraints rather than by
  application code (§3.5).
- **No state change without its event.** Kill the process between the two writes; the transaction
  rolls back and `unit.state` and `unit_event` still agree.

### 18.4 Attach arbitration

Attach two clients with **different terminal sizes**. The second is an observer, its keystrokes are
discarded, and `TIOCSWINSZ` follows the writer alone. **The agent reports its own width** — the
test adapter prints `COLUMNS` on demand — because asserting that cdl *sent* no resize does not
establish that the agent saw none. `--takeover` transfers the writer role and **both** clients
are told in-band. When the writer detaches, the observer is promoted and told (§4.3.1).

### 18.5 Port allocation

Two concurrent `cdl worktree new` invocations that hash to the same preferred block receive
different blocks, both recorded, the second with `preferred = 0`. Exhausting the range yields
`launch_failed` naming the range. **Separately**: run two agents in sequence in one worktree and
confirm the second is handed the *same* port block as the first, because the block belongs to the
worktree (§8).

**Reuse after removal**, which draft 2 failed on two of three values: `cdl worktree rm` a worktree,
then create a new one on the **same branch**, at the **same path**, and confirm it can also be
handed the **same `base_port`**. Draft 2 fixed only branch uniqueness and left `worktree.path` and
`port_block.base_port` permanently reserved by rows that were never deleted (§5.2, §6.1).

### 18.6 Sandbox

From inside a running agent: reading another unit's worktree fails; reading the keystore fails;
reading the registry fails. **Under stage 1 (§12.2), the namespace has no interface but loopback and
no resolver**, which is the property slice 1 tests — not an allow-list. Stage 2's test, when it
ships, is that egress to a non-allow-listed host fails *and* that a `git@` remote over an
allow-listed forge still works. With
`kernel.apparmor_restrict_unprivileged_userns` set so `bwrap` cannot start, admission produces
`launch_failed` and **no agent process is created** — the test that matters, because the failure
mode being guarded against is running unsandboxed.

### 18.7 Spend

A unit with `--budget` below its projected cost is stopped and recorded `cancelled`, and the
recorded overshoot is non-zero — the test asserts a **stop-loss, not a cap**, because §13.0 says
that is what it is, and a test asserting zero overshoot would be asserting something the design
does not claim. A unit whose spend is estimated is **not** hard-stopped, and its `cdl status` row
shows `~`. Budget arithmetic is exercised in integer micros with a value chosen to be
unrepresentable in binary floating point (e.g. `$0.10`), asserting no drift over many increments.

### 18.8 The claims draft 4 asserted and never tested

A cold review of the suite found these guarantees stated in the design with nothing exercising
them. Each is a test, not a note:

| Claim | Test |
|-|-|
| §4.2 step 5 / §7.5 — a lease is released on **normal** completion | Run a local-provider unit to completion; `gpu_lease.released_at` is set and the live-lease sum returns to its prior value. This is the draft-3 defect the spec names; nothing checked it. |
| §3.1, §9.3 — `running ⇄ waiting` | Drive the test adapter to emit its waiting pattern, then to produce output. The unit enters `waiting` with `waiting_source='adapter'` and returns to `running`. Separately, block it silently past the idle threshold: `waiting_source='idle'`. |
| §3.1 — live cancellation | Cancel a `running` unit. It passes through `stopping`, gets `SIGTERM`, and on a unit that ignores `SIGTERM` is `SIGKILL`ed after the grace period, reaching `terminal`/`cancelled`. Only *queued* cancellation was tested. |
| §3.4 — only the owner writes | With a unit `running`, have the admission controller attempt each of its transitions. Every one affects **zero rows** (§4.5's guards) and no `unit_event` appears. |
| §3.4 — `SQLITE_BUSY` surfaces | Hold a write transaction open past the `busy_timeout` while another actor attempts a state write. The second **fails loudly**; it must never skip the write, which would break §3.5 invariant 1. |
| §19.4 — launch idempotency | Drop the ssh connection after the remote process starts but before the pid is read back. Re-run the launch: it adopts the existing process via the marker and **starts nothing new**; exactly one agent process exists on the remote host. |
| §20.3 — argv redaction | Launch an adapter that takes a key as an argument. `launch_argv` contains `«redacted:…»` and **not** the key; `cdl doctor`'s scan reports nothing. Then deliberately mis-declare the secret position and confirm `cdl doctor` **does** report it. |
| §20.2 — log sanitizing | Have the adapter emit a window-title escape sequence. `cdl agent logs` strips it, `--raw` does not, and the on-disk log retains the original bytes. |
| §20.1 — rotation | Emit more than the rotation threshold; segments appear, the agent keeps running, and a log write failure does not kill it. |
| §11.3 — device reconciliation | Present a lease table that disagrees with `nvidia-smi` by more than the margin. The **measurement** decides admission and the discrepancy is recorded. |
| §11.4 — thermal denial | A gate returning `deny(reason)` produces `launch_failed` with the reason, and **no process is created**. |
| §13.2 — daily ceiling | At the hard stop, new admissions are refused and **running units are not killed** (§13.2 is explicit about that trade). |
| §14 — limits queue rather than fail | Exceed each limit; units sit in `queued` with a populated `queued_reason` and start when capacity frees. |

### 18.9 Confirm the reported values

The overview marks the `systemd-oomd` defaults and the AppArmor/bubblewrap interaction *reported,
not reproduced*. Before either is relied on, both are to be measured on the target and the result
recorded here.

---

## 19. The `ssh` backend protocol

### 19.1 Why this is a protocol

D28 puts 2–4 units on the lab GPU host, so `ssh` is not an optional extra — it is a third of the
working shape, and overview §7 commissions the backend contract from this component. Draft 1 named
the backend in six places and never defined it, which left `cdl job submit --backend ssh` looking
specified when what existed was a column value.

A remote unit must satisfy **the same guarantees as a local one**: it survives the laptop's reboot,
its logs outlive the connection, reconciliation can tell alive from dead, and cancellation works.
An `ssh` invocation gives none of those; a protocol has to.

The rule that generates the rest: **the connection is not the unit.** A dropped ssh session must be
indistinguishable, from the unit's point of view, from nothing happening at all.

### 19.2 The backend controller owns the row

**The registry is local and an SSH supervisor cannot write it.** §3.4 nonetheless assigned every
post-handoff transition to "the supervisor", which is meaningless for a process on another machine:
it has no database to write, and giving it one would mean either a network-mounted SQLite (§5.1
forbids it) or a second source of truth.

So for every backend except `local`, the row's owner after acknowledgement is the **backend
controller** — a local, long-lived `systemd --user` service, one per remote host, that:

- performs the launch and writes the acknowledgement (§4.5 step 3) on the remote supervisor's
  behalf, once the remote side has confirmed its pid and boot id;
- runs that host's probes on a schedule and on demand (§19.7);
- **translates authenticated remote observations into local transactions.** Nothing the remote
  reports becomes registry state except through the controller, in one transaction, with a
  `unit_event` naming `actor = 'controller'` and the observation it acted on.

The controller is a *reader* of the remote and the sole *writer* of those rows. That keeps §3.4's
one-owner invariant intact across the network without pretending a remote process can participate
in a local transaction. If the controller for a host is not running, that host's units are simply
un-probed — `probe_status` goes stale and `cdl status` says so, which is the same degraded-not-blank
behaviour §15.2 requires everywhere else.

### 19.3 Remote identity

Every remote unit records three things at launch, and §7.2's `R` ladder reads all three:

| Column | Source | Why |
|-|-|-|
| `remote_host` | The target | Which frame of reference applies |
| `remote_boot_id` | `/proc/sys/kernel/random/boot_id` **on the remote host** | A remote reboot kills remote processes; the local boot id says nothing about them (§7.2) |
| `remote_pid` | The remote supervisor's pid | Identity, checked together with the cmdline against PID reuse |

The remote side also writes a **marker file** at `<remote_dir>/.cdl-unit.json`, mode 0600,
containing the unit id, the boot id and the pid. It is the same role the local launch manifest plays
in §7.3.1: it lets a probe re-establish identity when the registry and the remote host disagree, and
it lets an orphaned remote directory be attributed to the unit that created it.

### 19.4 Launch, and idempotency

The backend controller (§19.2) performs these, and **the order is §4.5's, not a separate one**.
Draft 3 wrote `queued → starting` at the end, so the remote process ran while the row still said
`queued` and nothing owned it — and the marker at step 2 needed a `launch_id` that did not exist
until step 4. Corrected:

1. **One transaction**: grant leases, write `queued → starting`, generate `launch_id`, set
   `launch_deadline` (§4.5 step 1). Admission owns the row from here.
2. Ensure `remote_dir` exists — `<configurable base>/<unit-id>`, unique by construction, so two
   launches cannot collide in the filesystem.
3. Write the marker file, carrying that `launch_id`, **before** starting anything.
4. Start the remote supervisor **detached from the ssh session**, under `systemd-run --user` where
   the remote host has a user manager, and `setsid` + `nohup` otherwise. Which one was used is
   recorded, because it determines how §19.7 probes and how §19.9 cancels.
5. Read back the pid and remote boot id and, in one transaction, record them **and**
   `launch_ack_at` — the controller writes the acknowledgement on the remote supervisor's behalf
   (§19.2), which is the ownership transfer. Until it commits, admission still owns the row and
   `L0`/`L0′` govern it exactly as they do locally.

**Idempotency is by the unit id, and it has to be**, because the failure that actually happens is the
ssh connection dropping *after* the remote process started but *before* cdl learned its pid. Re-running
launch for the same unit id finds the marker file, adopts the running process, and starts nothing
new. A launch that cannot determine whether it started something resolves to `launch_failed` and
says which remote directory to inspect — **it never retries blind**, because a blind retry is how one
job becomes two jobs writing to one directory.

### 19.5 Durable logs

The remote supervisor appends to `<remote_dir>/log` on the **remote** disk, exactly as the local one
appends locally. It does not stream to the laptop as its system of record: a log that exists only in
a live ssh pipe is lost when the connection drops, which is the condition it most needs to survive.

`cdl job logs <id>` tails the remote file over ssh. `-f` follows and **reconnects on drop**, marking
the gap in its output rather than silently resuming, since a silent resume is indistinguishable from
a quiet period. On terminal transition the log is fetched once into the local log directory, after
which the unit's history is local and survives the remote host being decommissioned.

### 19.6 The terminal result record

This is what R3 reads, and the reason a completed remote job is no longer indistinguishable from a
dead one. When the remote supervisor reaps its child it writes `<remote_dir>/.cdl-result.json`,
mode 0600, containing:

| Field | Why it is needed |
|-|-|
| `unit_id`, `launch_id` | Identity. R2 rejects a directory whose marker does not match the row, so a reused `remote_dir` can never donate its result to the wrong unit. |
| `outcome`, `exit_code` | The actual answer. `completed` / `failed` are decided remotely, from the real exit status. |
| `started_at`, `ended_at` | Runtime, which cannot be reconstructed locally once the process is gone. |
| `artifacts[]` — path, bytes, `sha256` | The manifest §19.8 fetches against. Digests are computed on the remote, where the bytes are. |
| `record_sha256` | A digest over the rest of the record, so a partial write is detectable rather than plausible. |

**Importing it is idempotent, not merely deduplicated.** `R3` may run twice — two reconcilers, or
one retried after a crash between the import and the commit — so every insert derived from this
record uses `INSERT … ON CONFLICT DO NOTHING` against the uniqueness indexes in §5.2. A bare
`INSERT` would raise `UNIQUE constraint failed` and abort the whole `R3` transaction, so the
second attempt would fail to import a result the first had already half-written.

**It is written atomically**: to a temporary file in the same directory, `fsync`, then `rename`.
A `rename` within one filesystem is atomic, so a reader sees either no record or a whole one —
never a half-written one that parses. This matters more than it looks: the failure being designed
against is the remote host losing power *while writing the result*, and a torn JSON file that
happens to parse would be imported as fact.

**Verification before import**, in this order: the record parses; `record_sha256` matches; `unit_id`
and `launch_id` match the row; `outcome` is one of the permitted values; `exit_code` agrees with
`outcome` (zero for `completed`, non-zero for `failed`). Any failure means the record is treated as
**absent**, the row falls through to R4/R5, and the reason is recorded in `unit_event.detail`. A
result that cannot be trusted must not become a `completed` row.

### 19.7 Reconnect and probe

The probe is §7.2's `R` ladder. It is one ssh invocation carrying a small script: read the boot id,
read the marker, test the pid and its cmdline. `ConnectTimeout` is short and bounded, and its
exhaustion means **unreachable, never dead** (`R1`). Probe results are written to `last_probe_at`
and `probe_status` whether they succeeded or not, so `cdl status` can say how old its knowledge is.

### 19.8 Artifacts

A job declares artifact paths relative to its `remote_dir`. On terminal transition cdl lists them,
records a row per artifact in the `artifact` table (§5.2) with size and `sha256` **computed on the
remote host**, and fetches on demand rather than automatically — a multi-GB checkpoint should not
cross the network because a job finished.

`cdl job artifacts <id>` lists them; `--fetch` retrieves, verifies the digest locally, and sets
`local_path` and `fetched_at`. **A digest mismatch is an error, never a warning.**

### 19.9 Cancellation

`cancel_requested_at` is set locally, as for any unit (§3.4). The remote supervisor polls the marker
directory for a `cancel` file that the controller writes over ssh, and on seeing it runs the same
`SIGTERM` → grace → `SIGKILL` sequence a local supervisor runs, then writes a terminal result
(§19.6) with `outcome = 'cancelled'` for the next probe to import.

**Cancellation must work while the unit is unreachable**, so the request is durable rather than
delivered: if the host is down, `cancel_requested_at` stays set and the file is written on the next
successful contact. `cdl status` shows the unit as *cancel pending* — the operator's intent is
recorded and will be acted on, which is different from a request that was dropped.

### 19.10 Cleanup

`remote_dir` outlives the unit by default, for the same reason a worktree does: the output is
usually the point. `cdl job gc --host <h>` removes remote directories for units that reached
`terminal` more than a configurable age ago, **refusing any with unfetched artifacts** unless
`--force`. Remote directories with no matching registry row are reported as orphans and never
deleted automatically — the registry is the less trustworthy of the two after a restore (§5.5), so
it must not be the thing that authorises a deletion.

### 19.11 Not in the first slice

None of this ships in slice 1 (§21). It is specified now because the schema, the state machine and
the backend interface must carry it, and because writing it down is what turned four columns and a
command name into a set of operations with defined failure behaviour.

---

## 20. Data handling and operational safety

Five things drafts 1 and 2 left unspecified. Each is small, and each has a wrong default that would
otherwise be chosen by whoever implements it first.

### 20.1 Log retention and rotation

A supervisor appends every PTY byte for the unit's whole life (§4.2), so a long-running chatty agent
writes an unbounded file. Logs are `<state_dir>/logs/<unit-id>.log`, mode **0600**, created before
the first byte.

- **Rotation is by size**, default 64 MiB, keeping a configurable number of prior segments. Rotation
  never blocks the PTY reader: a supervisor that cannot write its log **keeps the agent running** and
  records the failure, because losing the transcript is bad and killing working agents to protect a
  log is worse.
- **Retention is tied to the worktree, not to a timer.** A unit's logs live until its worktree is
  collected (§6.1) or a configurable age passes, whichever is later. The transcript is usually
  needed exactly when the work is being reviewed.
- **Disk pressure has a floor, not a policy of silence**: below a configurable free-space threshold
  `cdl` stops admitting units and says why, rather than letting logs fill the volume the registry
  is on.

### 20.2 Terminal control sequences in logs

The log is raw PTY output, so it contains whatever escape sequences the agent emitted — including
cursor manipulation, and on some terminals sequences that relabel the window or drive a response. A
log is also the one artifact an operator is most likely to `cat`, and an agent's output is
**untrusted content**: it may contain text a model was told to emit by a document it read.

- `cdl agent logs` and `cdl job logs` **sanitize by default**, passing SGR colour through and
  stripping other control sequences.
- `--raw` opts out, for replaying into a terminal deliberately.
- The replay window on attach (§4.3 step 2) is **not** sanitized, because it is being fed to a live
  terminal that is already showing that agent's output.

### 20.3 Credentials must not reach `launch_argv`

`launch_argv` is recorded for reproducibility (§5.2) and the registry is backed up (§5.5). Some CLIs
accept a key as an argument, so recording argv verbatim would put provider credentials in a
backed-up database — the leak §10.3 avoids for the environment, reintroduced through the other door.

Each adapter therefore declares **which argv positions are secret**, and cdl stores the redacted
form: the value is replaced with `«redacted:<NAME>»`, preserving the shape of the command without
its content. Argv is redacted **before it is written**, never after.

**The unredacted argv is still what gets `exec`'d** — redaction applies to the record, not the
launch. And `cdl doctor` scans stored `launch_argv` values against the keystore's known secrets and
reports any match, because an adapter that forgets to declare a position is the failure this
guards against and it is otherwise invisible.

### 20.4 Prompt retention

`launch_prompt` is recorded once (§4.4) and is often the most sensitive text in the system. Three
modes, on the row as `launch_prompt_mode`:

| Mode | Stores | For |
|-|-|-|
| `full` | The prompt | Default. Reproducibility, and the §18.1 assertion that it appears exactly once. |
| `digest` | Only a SHA-256 | `--no-record-prompt`. The no-replay guarantee still holds, and identity is still checkable, but the text is not in the backup. |
| `absent` | Nothing | Prompt supplied interactively after launch; there was never one to record. |

`digest` weakens nothing in §4.4: the guarantee against prompt replay comes from the prompt being
passed only once, during a single transition, not from its being readable afterwards.

### 20.5 How the unit is actually constructed

§4.1 shows a template unit, which cannot carry a per-unit slice or per-unit resource limits. The
concrete mechanism, since "systemd will handle it" is where this kind of design usually stops:

```
systemd-run --user --unit=cdl-agent-<unit-id> --slice=cdl-agent-<unit-id>.slice \
  --property=Restart=no --property=MemoryHigh=<n> --property=MemoryMax=<n> \
  --property=ManagedOOMPreference=avoid --collect \
  /usr/lib/cdl/cdl-agent-supervisor --unit-id <unit-id> --launch-id <launch-id>
```

- `systemd-run` rather than a static template, because the slice, the memory limits and the
  `launch_id` all vary per unit and a template unit file cannot express them.
- `--collect` so a failed unit's metadata does not accumulate; §7.6 tier 1 handles the residue when
  it does.
- **The `launch_id` is passed as an argument**, which is what makes §4.5 step 3's check possible: a
  supervisor from a superseded attempt presents a stale id and exits without touching anything.
- Failure of this command is a `starting → terminal(launch_failed)` written by admission (§4.5
  step 2), never a row left for reconciliation to guess at.

---

## 21. Implementation order

The design covers the whole §7 brief (DA1). **Implementation does not**, and the ordering is part of
the design rather than a scheduling detail: the durable local supervisor is the component's
correctness core, and remote execution, controlled egress, GPU admission and spend accounting are
each large enough to obscure whether that core works.

### Slice 1 — the local core

| In | Out |
|-|-|
| One local interactive agent, one **test adapter** with deterministic output | The four real CLI adapters |
| SQLite registry, state + event in one transaction (§3.5) | Remote backends of any kind |
| Supervisor-owned PTY; append-only log at mode 0600 | Controlled egress (stage 2, §12.2) |
| One writer, observers, takeover (§4.3.1) | GPU admission and llama-swap |
| Admission → supervisor handoff (§3.4), including queued cancellation | Spend accounting beyond recording zero |
| `cdl reconcile` over the local ladder, plus `--rebuild` (§7.3.1) | Worktree GC policy beyond a manual command |
| bubblewrap with `--unshare-net` (stage 1, §12.2) | |
| Crash, reboot and corruption acceptance tests (§18) | |

**A test adapter comes before the real ones deliberately.** Slice 1's questions are *does the state
machine hold under a crash* and *does reconciliation reach the right verdict*, and answering them
against a real agent CLI means debugging someone else's TUI while trying to establish that your own
lifecycle is sound. A deterministic adapter that can be told to hang, exit 7, or emit a waiting
pattern on cue makes every §18 test reproducible.

### Slice 2 — real agents locally

The four adapters (§9), the provider matrix and per-process environment (§10.3), worktrees and port
blocks (§6, §8), and spike 2 run against Claude Code for real.

### Slice 3 — the remote backend

§19 in full, gated on slice 1's failure tests passing — because a reconciliation bug that is
awkward locally is very hard to diagnose across a network.

### Slice 4 — the contended resources

Controlled egress (§12.2 stage 2), GPU admission with device reconciliation (§11.3), and spend
accounting with the price table (§13). Each needs the core to be trustworthy first: all three are
mechanisms for *refusing* work, and a refusal that fires because of a lifecycle bug is
indistinguishable from one that fires correctly.

---

## 22. The reviews this spec answers

### 22.1 The overview's revision-1 review — findings #6 and #7

Overview §7 commissions this component to resolve findings **#6 (the proposed orchestrator is
underspecified)** and **#7 (the remote-job interface is too small)** of the 2026-09-01 review of
overview revision 1. That review existed nowhere in the repository — only references to it — so
both were carried as an open item through drafts 1 and 2. **It was recovered from the prompt
history on 2026-09-02 and is now stored verbatim** at
`notes/reviews/2026-09-01-overview-revision-1-review.md`.

Each bullet, against where this spec answers it. **The finding text is quoted, not paraphrased**,
because a requirement restated from memory is how it silently changes:

**#6 — *"it does not yet describe a usable agent lifecycle"***

| The review asked | Answered in |
|-|-|
| *"How an interactive agent gets a PTY"* | §4.2 — the supervisor opens the pair; the agent gets the slave as controlling terminal via `setsid` + `TIOCSCTTY` |
| *"How the user attaches and detaches"* | §4.3, and §4.3.1 for who may write |
| *"How input is injected"* | §4.3 step 3; the supervisor forwards bytes only, never translating signals |
| *"How blocked/waiting/completed state is detected"* | §9.3 (two signals, marked best-effort), §3.1 (`waiting` is a state, not a flag), §3.2 (completion is an outcome) |
| *"How exit status is preserved"* | §4.2 step 5, `unit.exit_code` (§5.2) |
| *"How prompts and launch commands are recorded"* | §5.2 `launch_argv`, `launch_prompt`, `launch_env_keys` — names, never values |
| *"How agents are cancelled"* | §3.4 — cancellation is a request; the row's owner acts on it, which is what makes queued cancellation work |
| *"How stale worktrees and services are reconciled"* | §7.6. **This was the one genuine gap**: drafts 1 and 2 reconciled units only, and `worktree gc` considers released rows, so a worktree whose unit died unreleased had no path at all |
| *"How a user resumes work without replaying the initial prompt"* | §4.4, and §18.1 asserts the prompt appears exactly once in the log |
| *"There is also no process sandbox in the final spec"* | §12 |
| *"A hash needs collision detection and an allocation registry protected by a lock"* | §8 — `IMMEDIATE`-locked check-and-record, detection against live blocks, documented fallback, exhaustion as an error |

**#7 — *"the remote-job interface is too small"***

| The review asked | Answered in |
|-|-|
| submit · list · status · logs · cancel | §15.1 |
| *"artifacts or result location"* | §19.8 and the `artifact` table (§5.2) — draft 1 offered the command with no table behind it |
| reconcile | §7.2's `R` ladder, §19.7 |
| *"Idempotency semantics"* | §19.4 — keyed on the unit id, with the marker file written **before** anything starts, and a launch that cannot tell whether it started something failing rather than retrying blind |
| *"Backend-native and CDL job identifiers"* | §5.2 — `id` (ULID) is cdl's; `remote_id`, `remote_pid`, `remote_boot_id` are the backend's |
| *"Atomic registry writes and locking"* | §3.5 invariant 1, §5.1 (WAL, `busy_timeout`), §8's `IMMEDIATE` transaction |
| *"Per-worktree JSON is especially risky … SQLite would likely be simpler"* | Adopted. §5 is SQLite throughout; there is no per-worktree JSON anywhere in the design |

**Verdict: both are resolved**, one of them only as of this draft. Most were already answered
because the overview's §7 brief was derived from these findings — but the traceability had never
been written down, so nobody could check it, and §7.6's gap survived two drafts as a result.

### 22.2 Draft 1 review of this document

Draft 1 was reviewed 2026-09-02. Ten findings, all accepted; the review's own sequencing
recommendation became §21. Recorded so a later reader can see what changed and why, rather than
diffing two drafts.

| # | Finding | Resolved in |
|-|-|-|
| 1 | Transition ownership contradictory: the rule said the supervisor writes `starting`, the table said admission did; queued cancellation had no owner; some `launch_failed` cases precede the supervisor | §3.4 rewritten as one-owner-at-a-time with three defined handoffs; §3.2 says which actor writes `launch_failed` when |
| 2 | Reconciliation started with local `boot_id` for **every** row, so a laptop reboot would mark live remote jobs `lost` | §7.2 dispatches on `backend` first; `remote_boot_id` added (§5.2) |
| 3 | §5.4 promised re-adoption after corruption, but §7.2 iterated over rows a rebuilt database does not have | §7.3.1 discovery from systemd units and sockets, a `describe` handshake, and a launch manifest; §5.4 states what is *not* recoverable |
| 4 | Port blocks allocated per worktree but released per unit | §8: owned by the worktree, released at `worktree gc`; §7.5 releases only the GPU lease |
| 5 | `ssh` backend named in six places, never specified | New §19 |
| 6 | Every attached client could write and resize, producing input interleaving and a `TIOCSWINSZ` fight | §4.3.1: one writer, observers, explicit takeover |
| 7 | Network policy stated an endpoint without topology, DNS, proxy identity, cleanup or git-over-SSH | §12.2 split into stage 1 (`--net=none`, ships first) and stage 2, with per-unit sockets as identity |
| 8 | GPU summation and spend precision both overpromised | §11.3 leases are admission ceilings reconciled against the device; §13.0 tabulates what is enforced vs observed; money moved to integer micros |
| 9 | Schema lacked artifacts, egress lists, queued reasons, remote fields, probe timestamps; no state/event atomicity or terminal invariants | §5.2 throughout; §3.5 states the two invariants as `CHECK` constraints |
| 10 | Permanent `UNIQUE (repo_path, branch)` made a branch unusable after release | Superseded by draft 3's §6.1: the row is deleted with the directory, so plain `UNIQUE` is correct and no partial index is needed. Draft 2's partial-index fix covered one of three constraints — see §22.3 |

### 22.3 Draft 2 review of this document

Reviewed the same day. **Two of these were defects introduced by draft 2's own fixes**, which is
the lesson worth keeping: the fix for finding 4 (port ownership) created a foreign-key scenario
that cannot occur, and the fix for finding 10 (branch uniqueness) corrected one of three permanent
constraints and left the other two.

| Finding | Resolved in |
|-|-|
| **Admission-to-supervisor handoff was race-prone.** Between the `starting` write and the spawn the declared owner did not exist: a concurrent reconcile called a healthy launch `lost`, cancellation had no processor, and a spawn failure became `lost` rather than `launch_failed` | §4.5 acknowledged handoff (`launch_id`, `launch_deadline`, `launch_ack_at`); §7.2's `L0`/`L0′`; §3.4 keeps admission the owner until acknowledgement |
| **A successful remote job was written `lost`.** The remote supervisor wrote a terminal record and reconciliation never read it, so a finished job — having no process — fell through the liveness check | §19.6 defines the record, atomic and verified; §7.2's `R3` reads it **before** any liveness check |
| **Remote transition ownership was undefined** — the owner was "the supervisor", which cannot write a local database from another machine | §19.2 backend controller: a local service, sole writer of that host's rows |
| **§7.6's orphaned `port_block` could not exist** under `PRAGMA foreign_keys = ON`, and its acceptance test began by creating that state | Row removed; §5.2 states `ON DELETE RESTRICT`; §6.1 deletes the block first in one transaction; §18.2.3 now asserts the deletion *fails* |
| **`worktree.path` and `port_block.base_port` were still permanently unique**, so removed worktrees reserved both forever | §6.1: one lifecycle, `released_at` dropped, rows deleted with the directory — which makes plain `UNIQUE` correct rather than needing three partial indexes |
| **§7.6 contradicted itself on deletion** — "nothing here deletes a file" beside a table that unlinked sockets | §7.6's three disposal tiers, keyed on whether a thing holds unreconstructable data |
| **"Services outlive units deliberately" was misleading** — a supervisor's socket should not outlive it | §7.6 separates designed survival (worktrees, ports) from leaks (sockets, failed-unit metadata) |
| `last_probe_at` recorded attempts while §15.2 described successes | §5.2 adds `last_successful_probe_at`; §7.2 says which is written when |
| The state diagram routed queued cancellation through `stopping`, contrary to §3.4 | §3.1 redrawn |
| §3.5 claimed the schema enforced state/event atomicity | §3.5 now says invariant 1 is enforced by the write layer; only invariant 2 is a `CHECK` |
| `cdl job submit` offered no `local` backend though schema and lifecycle permit it | §3.3, §15.1 |
| Still labelled draft 2 | Header |
| Log retention, control-sequence safety, prompt retention, credentials in `launch_argv`, concrete systemd construction unspecified | New §20 |

### 22.4 Cold review of draft 3

Draft 3 was reviewed by two **cold** agents — no conversation context, given only the file — because
draft 2's review noted, correctly, that reviewing inside the working conversation is not an
independent check. Both ran the DDL in SQLite rather than reasoning about it, and that is how the
blocker was found.

| Finding | Resolved in |
|-|-|
| **BLOCKING: §6.1's deletion sequence could never run.** `unit.worktree_id` and `port_block_id` were plain references, so with `foreign_keys = ON` both `DELETE`s fail for any worktree that ever ran a unit — all of them. Reproduced: `FOREIGN KEY constraint failed` | §5.2 `ON DELETE SET NULL` on both. Verified: the sequence now succeeds, the unit row survives with references nulled, and branch, path and port are all reusable |
| **Every `queued` unit would be killed by any reconcile.** The ladders ran over each non-`terminal` row; a queued row has no `boot_id`, service or pid, so `L1`–`L3` concluded dead | §7.2 scoped to `starting`/`running`/`waiting`/`stopping`, matching §7.1; §18.2 test 6 |
| **A deadline race could leave a live agent behind a terminal row.** Reading and writing are not the same instant, and neither `L0′` nor the acknowledgement was conditional | §4.5: both are compare-and-swap on `launch_ack_at`, each checks the affected row count, and the losing supervisor exits without `exec`ing |
| **§3.4 called the write pattern "conflict-free."** WAL permits one writer *database-wide*; measured `database is locked` on a different row after the 5 s timeout | §3.4 distinguishes correctness from contention, and forbids filesystem or network work inside a write transaction |
| **A rebuilt row died on the next pass.** `describe` returned no pid or boot id, so `supervisor_pid` was null and `L3` concluded dead | §7.3.1: `describe` returns pid and boot id, because `L3` checks them |
| **A live supervisor's silent socket was unlinked**, severing attach — `L1`–`L3` alive with `L4` silent reached no conclusion at all | §7.2 `L5` (alive, degraded); §7.6 may unlink only after a dead conclusion |
| **A socket answering for a terminal row would have been re-adopted**, writing `terminal → running`, which §3.1 forbids and §3.4 authorises nobody to do | §7.6: the row wins, the supervisor is asked to exit, the conflict is reported |
| **GPU leases leaked on the normal path.** Release was specified only under reconciliation, so a unit that simply finished held its lease forever | §4.2 step 5 releases it in the terminal transaction; §7.5 states every path does |
| **§19.4 ran the remote process while the row was `queued`**, and wrote a marker needing a `launch_id` that did not yet exist | §19.4 reordered onto §4.5's sequence |
| `unit` had no `vram_mib`, so a queued unit could not record its request | §5.2 |
| Schema accepted a `job` in `waiting`, duplicate `schema_version` rows, and any `actor` string; concurrent reconciles could duplicate imported artifacts | §5.2 `CHECK`s and two uniqueness indexes; §7.1.1 serializes reconcile |
| §15.2's "each has a column behind it" was false for two of its notes | §5.2 `waiting_source`, `recovered_at` |
| The admission controller and reconciler had no process model, so nothing advanced a `queued` row after the CLI exited | §7.1.1: `cdl-admissiond` and `cdl-controller@<host>` |
| §4.1's shipped template contradicted §20.5's `systemd-run`, with colliding unit names | §4.1 defers to §20.5 |
| A filesystem removal sat inside a "transaction" that cannot roll back | §6.1: atomic rename first, then the transaction, then cleanup |
| Nine cross-references resolved to the wrong section after renumbering | Fixed; see the note on checker limits in `CLAUDE.md` |

### 22.5 Cold review of draft 4 — three agents

Three cold agents, one on the whole document, one on the sections draft 4 rewrote, one on the
acceptance tests alone. **35 findings, one blocking.** All were verified here — in `sqlite3`, in
`git`, or against the text — before anything was changed.

**The blocking one was mine, introduced by draft 4's own fix.** To make §15.2's promise true I
added `CHECK ((state='waiting') = (waiting_source IS NOT NULL))`, which made `waiting` a **trap
state**: every exit from it — to `running`, to `stopping`, to `terminal` — failed the constraint,
because nothing cleared the column. Reproduced on all three transitions. The constraint is gone;
`waiting_source` is a detector record, read only while the unit is waiting.

The findings that were not simply mechanical:

| Finding | Resolved in |
|-|-|
| **`waiting` was a trap state** — no transition could leave it | §5.2, constraint removed |
| **Timestamps were compared as free-form TEXT.** `'…T10:00:00Z' < '…T10:00:00.5Z'` is **0**; `'2026-09-01 10:00:00' < '…T09:00:00Z'` is **1**. §4.5's deadline is such a comparison | §5.2 pins one format and a `GLOB` `CHECK` enforces it on `launch_deadline` |
| **Only two of four writes into the launch window were compare-and-swap.** Admission's spawn-failure write could overwrite a `running` row after acknowledgement | §4.5: all four carry `launch_ack_at IS NULL` |
| **A backwards clock stranded a row in `L0` for ever**, holding a lease and a slot | §4.5: a clock-independent `created_at` bound |
| **`ON DELETE SET NULL` — draft 4's own blocker fix — erased provenance.** After `worktree rm`, a terminal unit no longer recorded which branch it worked on | §5.2 denormalises `worktree_path` and `branch` onto the unit |
| **`--rebuild` could not insert a row into a fresh database** (`FOREIGN KEY constraint failed` on `worktree_id`) | §7.3.1: rebuilt rows carry null references and restore the facts instead |
| **Acknowledged-then-crashed-before-`exec` was written `lost`**, which §3.2 reserves for a unit confirmed running | §7.2 `L0″` → `launch_failed` |
| **§6.1's crash recovery depended on rows that step 4 deletes**, so a crash between 4 and 5 left git refusing the path for ever (*"missing but already registered worktree"*) | §6.1: `gc` scans for trash by name and prunes before reading any row |
| **"The rename makes it invisible to git" was false** — `git worktree list` shows it `prunable` — and the claimed impossible state does occur between steps 3 and 4 | §6.1 and a new §7.6 row for the interrupted removal |
| **`R2` concluded nothing when the marker was simply absent**, leaving the row `running` for ever | §7.2 `R2′` |
| **Both idempotence indexes were wrong.** `artifact_identity` keyed on a column that is NULL for local jobs; `spend_import` both admitted duplicate imports and rejected genuine records sharing a timestamp | §5.2: key on `artifact.name` and on `spend_ledger.remote_ref` |
| **§7.6 tier 1 still removed a silent socket**, contradicting `L5` one section above | §7.6 |
| **A budget stop recorded `cancelled`**, indistinguishable from an operator's cancel | New `budget_exceeded` outcome |
| **§16 claimed content the frozen overview routes elsewhere.** Overview §7.1 assigns the llama-swap rationale to `cdl-first-boot-and-environment` | §16 declares the divergence and narrows the claim to serving topology |
| **T4a was cited as overview §12**, which is *Session and display*; it is overview §5 | §12.2 |
| Four spellings of the systemd unit name; `attach`'s documented default contradicted §4.3.1 | §4.1/§7.3.1/§7.6/§20.5; §15.1 |
| **The acceptance suite was inadequate.** Several tests passed on a broken implementation, one had an impossible setup, and fourteen stated guarantees had no test at all | §18 throughout; new §18.8 |

---

## 23. Open items

| # | Item | Why it is open |
|-|-|-|
| 1 | T4c (destructive push to a git remote) | Named in the threat model, not closed here. Candidate: deny-by-default push credentials. Belongs to `cdl-security-and-recovery`, but agents are the actor. |
| 2 | T4f (one credential set shared by every agent) | Per-agent credential scoping is not designed. §12.1 removes the keystore from the agent's namespace, which is a partial mitigation, not a closure. |
| 3 | Slurm backend | Designed as a backend row and a state mapping; ships **disabled** per D30 until its auth is testable. |
| 4 | HF Jobs backend | Depends on overview §16.4's funding question, which is unresolved. |
| 5 | Model integrity and provenance | Research flagged pulling multi-GB weights with no checksum policy. Sits between this component and `cdl-first-boot-and-environment`; unassigned. |
| 6 | `goose` as a fifth adapter | Apache-2.0 and Pacstall-packaged, so cheap to add. Not in v1. |
