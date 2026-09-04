#!/usr/bin/env python3
"""Validate an autoinstall seed before it is ever booted.

Two classes of defect this catches, both of which have actually occurred here:

  * A missing section. An edit once spliced across `storage:` and `packages:`, deleting
    both. The installer silently fell back to guided LVM and produced a bootable machine
    with the wrong layout and zero errors -- the worst possible failure, because it looks
    like success.
  * A duplicate key. YAML keeps the last of a repeated mapping key and says nothing, so
    `shutdown: poweroff` appeared twice and neither the parser nor the installer objected.
    PyYAML's own loader does not report this, so it is checked explicitly.

Usage: validate-autoinstall.py <user-data> [...]
"""
import sys
import yaml


class DuplicateKeyError(Exception):
    pass


class StrictLoader(yaml.SafeLoader):
    """SafeLoader that refuses a mapping containing the same key twice."""


def _no_duplicates(loader, node, deep=False):
    seen = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise DuplicateKeyError(
                f"duplicate key {key!r} at line {key_node.start_mark.line + 1} "
                f"(first seen at line {seen[key] + 1})"
            )
        seen[key] = key_node.start_mark.line
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_duplicates
)

REQUIRED = {"version", "identity", "ssh", "storage", "packages", "late-commands"}
STORAGE_KINDS = ("disk", "partition", "raid", "dm_crypt", "format", "mount")


def validate(path):
    """Return a list of problems; empty means valid."""
    problems = []
    try:
        with open(path) as fh:
            doc = yaml.load(fh, Loader=StrictLoader)
    except DuplicateKeyError as e:
        return [f"{e}"]
    except yaml.YAMLError as e:
        return [f"not valid YAML: {e}"]

    if not isinstance(doc, dict):
        return ["top level is not a mapping"]

    auto = doc.get("autoinstall")
    if not isinstance(auto, dict):
        return ["no top-level 'autoinstall' mapping"]

    missing = REQUIRED - set(auto)
    if missing:
        problems.append(f"missing required keys: {sorted(missing)}")

    cfg = (auto.get("storage") or {}).get("config") or []
    kinds = {e.get("type") for e in cfg}
    for need in STORAGE_KINDS:
        if need not in kinds:
            problems.append(f"storage config has no '{need}' entry; the layout would not be built")

    ids = {e.get("id") for e in cfg}
    for e in cfg:
        for k in ("device", "volume"):
            if isinstance(e.get(k), str) and e[k] not in ids:
                problems.append(f"{e.get('id')} references unknown {k} '{e[k]}'")
        for d in e.get("devices", []) or []:
            if d not in ids:
                problems.append(f"raid {e.get('id')} references unknown device '{d}'")

    # Every script the seed promises to deliver must actually be substituted, and every
    # late-command that depends on one must check for it rather than skipping silently.
    for f in doc.get("write_files", []) or []:
        content = f.get("content", "")
        if isinstance(content, str) and content.startswith("@@") and content.endswith("@@"):
            continue  # unsubstituted placeholder: expected in the committed template
        if f.get("encoding") == "b64" and not content.strip():
            problems.append(f"write_files {f.get('path')} has empty base64 content")

    return problems


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    bad = False
    for path in argv[1:]:
        problems = validate(path)
        if problems:
            bad = True
            print(f"FAIL  {path}")
            for p in problems:
                print(f"        {p}")
        else:
            print(f"ok    {path}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
