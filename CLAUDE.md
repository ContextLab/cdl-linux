# cdl-linux

## Writing the remaining component specs

Overview §7 commissions four component specs. `cdl-agent-lifecycle` is written
(`docs/superpowers/specs/2026-09-01-cdl-agent-lifecycle-design.md`); three remain.

**Dispatch an independent reviewer before handing a spec to the user — do not rely on the
inline self-review.** The `superpowers:brainstorming` skill's checklist step 7 says to
self-review for placeholders, contradictions, scope and ambiguity, and ends *"No need to
re-review — just fix and move on."* On draft 1 of the lifecycle spec that inline pass found
nothing of substance; an independent review then returned ten findings, one a data-loss bug
(reconciliation checked the local `boot_id` for remote rows, so a laptop reboot would have
marked every live remote job `lost` and released its leases).

The same plugin **already ships the right tool** and its SKILL.md never points at it:
`~/.claude/plugins/cache/claude-plugins-official/superpowers/<version>/skills/brainstorming/spec-document-reviewer-prompt.md`
is a dispatch template for a cold reviewer subagent. Use it. Do not edit the plugin cache — it
is overwritten on update.

**Run `scripts/check-spec.py <spec>` on every spec revision.** It does three checks, each of
which has caught a real defect that re-reading missed: internal `§N.M` references resolve; every
SQL identifier named in prose exists in the schema; and the DDL actually executes in SQLite. A
bare `§N` means *this* document, `overview §N` means the frozen overview — the two documents both
number from 1.

**Know what it cannot catch.** Three blind spots, all of which produced real bugs:

- **A reference can resolve and still be wrong.** After renumbering, nine `§19.x` references
  pointed at the wrong sections and every one of them "resolved". The script prints a
  reference-to-title table for exactly this; read it.
- **Executing is not testing.** The DDL ran cleanly while `cdl worktree rm`'s deletion sequence
  was impossible — plain `REFERENCES` meant a `FOREIGN KEY constraint failed` on every worktree
  that had ever run a unit. **Run the operations the prose describes**, in `sqlite3`, against a
  scratch database. The bug was found that way and would not have been found any other way.
- **The prose/schema check is one-directional and shallow.** It matches backticked snake_case,
  so a behaviour promised in plain words with no column behind it passes silently.

**Then dispatch cold reviewers before calling a spec done** — plural, and genuinely cold: a fresh
agent given the file and no conversation context. Reviewing inside the working conversation is not
an independent check, and every round so far has proved it: three review rounds found 10, 13 and 16
defects respectively, including two that would have destroyed live work.

## Evidence files

Generated capture output under `notes/hardware/` is **evidence**. When it is wrong, annotate it
with the correction and the cause; never rewrite the captured output to say what it should have
said. See the boltd device-count block in `tensorbook-20260902T030111Z-firmware-verify.md`.
