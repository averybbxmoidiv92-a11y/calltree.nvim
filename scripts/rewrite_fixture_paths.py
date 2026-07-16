#!/usr/bin/env python3
"""Rewrite hardcoded project paths in compile_commands.json fixtures.

Handles paths like:
  /home/z/my-project/work/calltree.nvim/calltree.nvim/tests/...
  /home/user/calltree.nvim/tests/...
  /any/path/calltree.nvim/tests/...

Replaces everything up to and including the LAST "calltree.nvim/" with
the actual project root prefix.
"""
import json
import os
import re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
NEW_PREFIX = PROJECT_ROOT + "/"

def rewrite_value(val):
    """Rewrite a single string value. Returns (new_value, changed)."""
    if not isinstance(val, str):
        return val, False
    if val.startswith(NEW_PREFIX):
        return val, False

    # Find ALL "calltree.nvim/" occurrences and use the LAST one as the
    # project root boundary. Everything before and including it gets
    # replaced with NEW_PREFIX.
    # For command strings like "gcc -c /path/...", preserve the "gcc -c " prefix.

    # Find the last occurrence of "calltree.nvim/"
    marker = "calltree.nvim/"
    last_pos = val.rfind(marker)
    if last_pos < 0:
        return val, False

    # The end of the old prefix is just after "calltree.nvim/"
    old_prefix_end = last_pos + len(marker)

    # Find the start of the old prefix: walk backwards from last_pos to
    # find the beginning of the path (either start of string, or right
    # after a space for command strings).
    start = last_pos
    while start > 0 and val[start - 1] not in " ":
        start -= 1

    # Build the new value: everything before the path + NEW_PREFIX + everything after "calltree.nvim/"
    new_val = val[:start] + NEW_PREFIX + val[old_prefix_end:]
    return new_val, True


count = 0
for dirpath, dirnames, filenames in os.walk(os.path.join(PROJECT_ROOT, "tests")):
    for fname in filenames:
        if fname == "compile_commands.json":
            fpath = os.path.join(dirpath, fname)
            with open(fpath) as f:
                try:
                    data = json.load(f)
                except json.JSONDecodeError:
                    continue
            changed = False
            for entry in data:
                for key in ("directory", "command", "file"):
                    new_val, did_change = rewrite_value(entry.get(key, ""))
                    if did_change:
                        entry[key] = new_val
                        changed = True
            if changed:
                with open(fpath, "w") as f:
                    json.dump(data, f, indent=2)
                count += 1

print(f"Rewrote {count} compile_commands.json file(s)")
print(f"  new prefix: {NEW_PREFIX}")
