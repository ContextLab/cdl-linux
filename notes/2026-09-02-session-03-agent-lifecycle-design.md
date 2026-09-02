# Session 03 (2026-09-02): designing `cdl-agent-lifecycle`

Resume item 2 from `notes/2026-08-31-session-02-spec-review.md`. Brainstorming path:
**architectural** (new subsystem, no existing flow in the repo, defines interfaces other
components depend on). Target artefact:
`docs/superpowers/specs/YYYY-MM-DD-cdl-agent-lifecycle-design.md`.

Context read before starting: design overview §7 (commissioning brief), §8 (architecture),
§2.1/D28 (working shape), §9 spike 2 (durable interactive agent), session-02 review findings.
**The overview is frozen** — amend only on new evidence, not to refine wording.

## Design decisions taken so far

### DA1 — Spec scope: the full commissioning brief
*User-chosen, 2026-09-02.* The spec covers everything §7 assigns the component: agent **and job**
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
*Recommended by Claude, user deferred to the recommendation, 2026-09-02.*

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
