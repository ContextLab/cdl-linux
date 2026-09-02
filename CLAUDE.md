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

**Two mechanical checks, on every spec revision.** Both found real defects on the lifecycle
spec and both are cheap:

1. **Every internal `§N.M` reference resolves to a real heading in that document.** This repo
   has two documents that both number sections from 1, so a bare `§7` is ambiguous: the
   convention is that bare `§N` means *this* document and `overview §N` means the frozen
   overview.
2. **Every schema identifier named in prose exists in the schema, and vice versa.** Draft 1
   advertised artifacts, egress allowlists, queued reasons, remote fields and probe timestamps
   in prose and in the CLI surface while the `CREATE TABLE` block had none of them. This is the
   single largest defect class found, and no amount of re-reading catches it.

## Evidence files

Generated capture output under `notes/hardware/` is **evidence**. When it is wrong, annotate it
with the correction and the cause; never rewrite the captured output to say what it should have
said. See the boltd device-count block in `tensorbook-20260902T030111Z-firmware-verify.md`.
