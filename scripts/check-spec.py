#!/usr/bin/env python3
"""Mechanical consistency checks for a cdl-linux design spec.

Three checks, each of which has caught a real defect that human re-reading missed:

  1. Every internal section reference resolves to a heading that exists.
  2. Every SQL identifier named in prose exists in the schema.
  3. The schema DDL actually executes in SQLite.

Plus a REPORT (not a check) pairing every reference with its target's title, because a
reference can resolve perfectly and still point at the wrong section after a renumber --
which is exactly what happened, nine times, and no pass/fail check catches it.

Usage: scripts/check-spec.py docs/superpowers/specs/<spec>.md
"""
import io, re, sqlite3, sys, tempfile, os

def schema_block(text):
    """The DDL block, found by content. Selecting the FIRST ```sql fence silently checked an
    illustrative snippet once a spec grew a second one, and reported success."""
    blocks = [b for b in re.findall(r'```sql\n(.*?)\n```', text, re.S) if 'CREATE TABLE' in b]
    if len(blocks) != 1:
        raise SystemExit(f"expected exactly one CREATE TABLE block, found {len(blocks)}")
    return blocks[0]

def main(path):
    text = io.open(path, encoding='utf-8').read()
    lines = text.split('\n')
    fail = 0

    heads = {}
    for ln in lines:
        m = re.match(r'^#{2,4} (\d+(?:\.\d+)*)\.? +(.*)', ln)
        if m:
            heads[m.group(1)] = m.group(2).strip()

    # 1. references resolve. "overview §N" points at another document and is skipped.
    dangling = []
    refs = {}
    for i, ln in enumerate(lines, 1):
        for m in re.finditer(r'(overview )?§(\d+(?:\.\d+)*)', ln, re.I):
            if m.group(1):
                continue
            r = m.group(2)
            if r not in heads:
                dangling.append((i, r))
            else:
                refs.setdefault(r, []).append(i)
    if dangling:
        fail = 1
        print("FAIL  dangling section references:")
        for i, r in dangling:
            print(f"        line {i}: §{r}")
    else:
        print(f"ok    all {sum(len(v) for v in refs.values())} internal section references resolve")

    ddl = schema_block(text)
    cols = set(re.findall(r'^\s+([a-z_]+)\s+(?:TEXT|INTEGER|REAL)', ddl, re.M))
    cols |= set(re.findall(r'CREATE TABLE (\w+)', ddl))
    cols |= set(re.findall(r'CREATE (?:UNIQUE )?INDEX (\w+)', ddl))

    # 2. prose identifiers exist. Allow-list is for non-schema snake_case (kernel knobs etc).
    allow = set()
    m = re.search(r'<!-- check-spec-allow:(.*?)-->', text, re.S)
    if m:
        allow = set(m.group(1).split())
    prose = text.replace(ddl, '')
    missing = sorted(c for c in set(re.findall(r'`([a-z][a-z0-9_]*_[a-z0-9_]+)`', prose))
                     if c not in cols and c not in allow)
    if missing:
        fail = 1
        print("FAIL  prose names identifiers absent from the schema:")
        for c in missing:
            print(f"        {c}")
    else:
        print("ok    every schema identifier named in prose exists in the schema")

    # 3. the DDL runs.
    fd, tmp = tempfile.mkstemp(suffix='.db'); os.close(fd); os.unlink(tmp)
    try:
        con = sqlite3.connect(tmp)
        con.executescript(ddl)
        con.close()
        print("ok    schema DDL executes in sqlite")
    except sqlite3.Error as e:
        fail = 1
        print(f"FAIL  schema DDL does not execute: {e}")
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

    print("\n--- reference targets (verify by eye; resolving is not the same as being right) ---")
    for r in sorted(refs, key=lambda x: [int(v) for v in x.split('.')]):
        print(f"  §{r:<7} -> {heads[r]}   [{len(refs[r])}x]")
    return fail

if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    sys.exit(main(sys.argv[1]))
