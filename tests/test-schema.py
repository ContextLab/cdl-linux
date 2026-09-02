#!/usr/bin/env python3
"""Executable tests for the cdl-agent-lifecycle schema, run against the spec's own DDL.

The spec's §18 acceptance cases are prose. Prose cannot fail, and across five review rounds
the defects that survived longest were exactly the ones where prose and schema disagreed:
a delete sequence forbidden by its own foreign keys, a CHECK that made `waiting` a state
nothing could leave, two uniqueness indexes keyed on the wrong columns. Each was found by
running SQL, not by reading it. These tests run the SQL.

The DDL is extracted from the spec at test time, so the spec is the single source of truth
and drift is impossible by construction.
"""
import re
import sqlite3
import sys
import unittest
from pathlib import Path

SPEC = Path(__file__).resolve().parent.parent / "docs/superpowers/specs/2026-09-01-cdl-agent-lifecycle-design.md"
TS = "2026-09-01T00:00:00.000Z"
TS2 = "2026-09-01T00:00:09.000Z"


def ddl():
    """The schema block, selected by content: the spec has several ```sql fences."""
    text = SPEC.read_text(encoding="utf-8")
    blocks = [b for b in re.findall(r"```sql\n(.*?)\n```", text, re.S) if "CREATE TABLE unit" in b]
    if len(blocks) != 1:
        raise AssertionError(f"expected one CREATE TABLE block in the spec, found {len(blocks)}")
    return blocks[0]


class SchemaTest(unittest.TestCase):
    def setUp(self):
        # isolation_level=None: no implicit transaction, so the BEGIN/COMMIT the spec
        # describes in §6.1 is the one actually executed here.
        self.db = sqlite3.connect(":memory:", isolation_level=None)
        self.db.executescript(ddl())
        self.db.execute("PRAGMA foreign_keys = ON")

    def tearDown(self):
        self.db.close()

    def unit(self, uid="u1", **kw):
        cols = dict(id=uid, kind="agent", state="queued", backend="local", adapter="test",
                    provider="local", launch_argv="[]", launch_env_keys="[]",
                    log_path=f"/logs/{uid}", created_at=TS)
        cols.update(kw)
        names = ",".join(cols)
        marks = ",".join("?" * len(cols))
        self.db.execute(f"INSERT INTO unit ({names}) VALUES ({marks})", list(cols.values()))
        return uid

    def worktree(self, wid="w1", branch="br", path="/wt/br"):
        self.db.execute("INSERT INTO worktree VALUES (?,?,?,?,?)", (wid, "/repo", branch, path, TS))
        return wid

    # --- permitted transitions -------------------------------------------------

    def test_full_agent_lifecycle_is_permitted(self):
        self.unit(state="queued")
        for sql in [
            "UPDATE unit SET state='starting' WHERE id='u1'",
            "UPDATE unit SET state='running' WHERE id='u1'",
            "UPDATE unit SET state='waiting', waiting_source='adapter' WHERE id='u1'",
            "UPDATE unit SET state='running', waiting_source=NULL WHERE id='u1'",
            "UPDATE unit SET state='stopping' WHERE id='u1'",
            f"UPDATE unit SET state='terminal', outcome='completed', ended_at='{TS2}' WHERE id='u1'",
        ]:
            with self.subTest(sql=sql):
                self.db.execute(sql)

    def test_every_outcome_is_accepted(self):
        for i, outcome in enumerate(
            ["completed", "failed", "launch_failed", "cancelled", "budget_exceeded", "lost"]
        ):
            self.unit(f"o{i}", state="terminal", outcome=outcome, ended_at=TS2)

    def test_waiting_can_be_entered_and_left(self):
        """Draft 4's CHECK made `waiting` a trap: every exit failed. Regression test."""
        self.unit(state="waiting", waiting_source="idle")
        for target in ["running", "stopping"]:
            with self.subTest(target=target):
                self.db.execute(
                    "UPDATE unit SET state=?, waiting_source=NULL WHERE id='u1'", (target,)
                )
                self.db.execute("UPDATE unit SET state='waiting', waiting_source='idle' WHERE id='u1'")
        self.db.execute(
            f"UPDATE unit SET state='terminal', outcome='lost', ended_at='{TS2}', "
            "waiting_source=NULL WHERE id='u1'"
        )

    # --- prohibited transitions and states ------------------------------------

    def assertRejects(self, sql, params=()):
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute(sql, params)

    def test_terminal_requires_outcome_and_ended_at(self):
        self.assertRejects("INSERT INTO unit (id,kind,state,backend,adapter,provider,launch_argv,"
                           "launch_env_keys,log_path,created_at) VALUES "
                           f"('x','agent','terminal','local','t','l','[]','[]','/l','{TS}')")

    def test_live_row_may_not_carry_an_outcome(self):
        self.assertRejects("INSERT INTO unit (id,kind,state,outcome,backend,adapter,provider,"
                           "launch_argv,launch_env_keys,log_path,created_at) VALUES "
                           f"('x','agent','running','completed','local','t','l','[]','[]','/l','{TS}')")

    def test_job_may_not_wait(self):
        """§3.3: a job has no human in the loop."""
        self.assertRejects("INSERT INTO unit (id,kind,state,waiting_source,backend,adapter,provider,"
                           "launch_argv,launch_env_keys,log_path,created_at) VALUES "
                           f"('x','job','waiting','idle','local','t','l','[]','[]','/l','{TS}')")

    def test_waiting_requires_a_source(self):
        self.assertRejects("INSERT INTO unit (id,kind,state,backend,adapter,provider,launch_argv,"
                           "launch_env_keys,log_path,created_at) VALUES "
                           f"('x','agent','waiting','local','t','l','[]','[]','/l','{TS}')")

    def test_leaving_waiting_without_clearing_source_is_rejected(self):
        """§3.4.1: the constraint and the clearing rule ship together."""
        self.unit(state="waiting", waiting_source="idle")
        self.assertRejects("UPDATE unit SET state='running' WHERE id='u1'")

    def test_unknown_actor_is_rejected(self):
        self.unit()
        self.assertRejects("INSERT INTO unit_event (unit_id,at,to_state,actor) VALUES "
                           f"('u1','{TS}','running','remote-supervisor')")

    def test_schema_version_holds_one_row(self):
        self.db.execute(f"INSERT INTO schema_version VALUES (1,1,'{TS}')")
        self.assertRejects(f"INSERT INTO schema_version VALUES (2,1,'{TS}')")

    def test_malformed_timestamp_is_rejected_on_the_compared_column(self):
        self.assertRejects("INSERT INTO unit (id,kind,state,launch_deadline,backend,adapter,"
                           "provider,launch_argv,launch_env_keys,log_path,created_at) VALUES "
                           f"('x','agent','starting','2026-09-01 10:00:00','local','t','l','[]','[]','/l','{TS}')")

    # --- worktree and port lifecycle ------------------------------------------

    def test_worktree_removal_sequence_succeeds_and_preserves_provenance(self):
        """§6.1. Draft 4's plain REFERENCES made both DELETEs fail for any used worktree."""
        self.worktree()
        self.db.execute("INSERT INTO port_block VALUES ('p1',20000,10,'w1',1,?)", (TS,))
        self.unit(state="terminal", outcome="completed", ended_at=TS2, worktree_id="w1",
                  port_block_id="p1", worktree_path="/wt/br", branch="br")
        self.db.execute("BEGIN")
        self.db.execute("DELETE FROM port_block WHERE owner_worktree='w1'")
        self.db.execute("DELETE FROM worktree WHERE id='w1'")
        self.db.execute("COMMIT")
        row = self.db.execute(
            "SELECT worktree_id, port_block_id, worktree_path, branch FROM unit WHERE id='u1'"
        ).fetchone()
        self.assertEqual(row[0], None, "live reference should be cleared")
        self.assertEqual(row[1], None, "live reference should be cleared")
        self.assertEqual(row[2], "/wt/br", "provenance must survive collection")
        self.assertEqual(row[3], "br", "provenance must survive collection")

    def test_branch_path_and_port_are_all_reusable_after_removal(self):
        self.test_worktree_removal_sequence_succeeds_and_preserves_provenance()
        self.worktree("w2")
        self.db.execute("INSERT INTO port_block VALUES ('p2',20000,10,'w2',1,?)", (TS,))

    def test_deleting_a_worktree_before_its_port_block_fails(self):
        """§18.2.3: the constraint that made draft 3's 'orphaned block' impossible."""
        self.worktree()
        self.db.execute("INSERT INTO port_block VALUES ('p1',20000,10,'w1',1,?)", (TS,))
        self.assertRejects("DELETE FROM worktree WHERE id='w1'")

    def test_two_live_worktrees_cannot_share_a_branch_or_a_path(self):
        self.worktree()
        self.assertRejects("INSERT INTO worktree VALUES ('w2','/repo','br','/wt/other',?)", (TS,))
        self.assertRejects("INSERT INTO worktree VALUES ('w3','/repo','other','/wt/br',?)", (TS,))

    # --- import idempotence ---------------------------------------------------

    def test_duplicate_artifact_import_is_refused(self):
        self.unit(state="terminal", outcome="completed", ended_at=TS2)
        self.db.execute("INSERT INTO artifact (id,unit_id,name,kind,created_at) VALUES "
                        "('a1','u1','out.txt','file',?)", (TS2,))
        self.assertRejects("INSERT INTO artifact (id,unit_id,name,kind,created_at) VALUES "
                           "('a2','u1','out.txt','file',?)", (TS2,))

    def test_local_artifacts_dedupe_even_though_remote_path_is_null(self):
        """Draft 4 keyed on remote_path, which is NULL locally, so nothing deduped."""
        self.unit(state="terminal", outcome="completed", ended_at=TS2)
        self.db.execute("INSERT INTO artifact (id,unit_id,name,kind,created_at) VALUES "
                        "('a1','u1','o','file',?)", (TS2,))
        self.assertRejects("INSERT INTO artifact (id,unit_id,name,kind,created_at) VALUES "
                           "('a2','u1','o','file',?)", (TS2,))

    def test_spend_dedupes_on_remote_ref_not_timestamp(self):
        """Two genuine records may share a timestamp; one record must not import twice."""
        self.unit()
        self.db.execute("INSERT INTO spend_ledger (unit_id,at,provider,micros,source,remote_ref) "
                        "VALUES ('u1',?,'anthropic',100,'remote','r1')", (TS,))
        self.db.execute("INSERT INTO spend_ledger (unit_id,at,provider,micros,source,remote_ref) "
                        "VALUES ('u1',?,'anthropic',200,'remote','r2')", (TS,))
        self.assertEqual(
            self.db.execute("SELECT count(*) FROM spend_ledger").fetchone()[0], 2,
            "records sharing a timestamp are distinct and must both land",
        )
        self.assertRejects("INSERT INTO spend_ledger (unit_id,at,provider,micros,source,remote_ref)"
                           " VALUES ('u1',?,'anthropic',100,'remote','r1')", (TS2,))

    # --- the four launch-window compare-and-swap races -------------------------

    def _starting(self, deadline=TS2):
        self.unit(state="starting", launch_id="L1", launch_deadline=deadline)

    def test_supervisor_ack_wins_and_reconciler_then_writes_nothing(self):
        self._starting()
        ack = self.db.execute(
            "UPDATE unit SET launch_ack_at=?, supervisor_pid=999 WHERE id='u1' "
            "AND state='starting' AND launch_ack_at IS NULL AND launch_id='L1'", (TS2,))
        self.assertEqual(ack.rowcount, 1)
        lost = self.db.execute(
            f"UPDATE unit SET state='terminal', outcome='launch_failed', ended_at='{TS2}' "
            "WHERE id='u1' AND state='starting' AND launch_ack_at IS NULL")
        self.assertEqual(lost.rowcount, 0, "reconciler must lose after an acknowledgement")

    def test_reconciler_wins_and_supervisor_ack_then_fails(self):
        self._starting()
        lost = self.db.execute(
            f"UPDATE unit SET state='terminal', outcome='launch_failed', ended_at='{TS2}' "
            "WHERE id='u1' AND state='starting' AND launch_ack_at IS NULL")
        self.assertEqual(lost.rowcount, 1)
        ack = self.db.execute(
            "UPDATE unit SET launch_ack_at=? WHERE id='u1' AND state='starting' "
            "AND launch_ack_at IS NULL AND launch_id='L1'", (TS2,))
        self.assertEqual(ack.rowcount, 0, "supervisor must lose and not exec")

    def test_admission_spawn_failure_cannot_overwrite_a_running_unit(self):
        """Draft 4 left this write unconditional: it could terminate a live agent."""
        self._starting()
        self.db.execute("UPDATE unit SET launch_ack_at=?, state='running' WHERE id='u1'", (TS2,))
        spawn_fail = self.db.execute(
            f"UPDATE unit SET state='terminal', outcome='launch_failed', ended_at='{TS2}' "
            "WHERE id='u1' AND state='starting' AND launch_ack_at IS NULL")
        self.assertEqual(spawn_fail.rowcount, 0)
        self.assertEqual(self.db.execute("SELECT state FROM unit WHERE id='u1'").fetchone()[0],
                         "running")

    def test_admission_cancel_cannot_overwrite_an_acknowledged_unit(self):
        self._starting()
        self.db.execute("UPDATE unit SET launch_ack_at=? WHERE id='u1'", (TS2,))
        cancel = self.db.execute(
            f"UPDATE unit SET state='terminal', outcome='cancelled', ended_at='{TS2}' "
            "WHERE id='u1' AND state IN ('queued','starting') AND launch_ack_at IS NULL")
        self.assertEqual(cancel.rowcount, 0)

    def test_a_stale_launch_id_cannot_acknowledge(self):
        self._starting()
        ack = self.db.execute(
            "UPDATE unit SET launch_ack_at=? WHERE id='u1' AND state='starting' "
            "AND launch_ack_at IS NULL AND launch_id='SUPERSEDED'", (TS2,))
        self.assertEqual(ack.rowcount, 0)


if __name__ == "__main__":
    if not SPEC.exists():
        print(f"spec not found: {SPEC}", file=sys.stderr)
        sys.exit(1)
    unittest.main(verbosity=2)
