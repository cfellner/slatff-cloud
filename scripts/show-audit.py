"""Formats model gateway audit lines (JSON, one per line on stdin) as a table.
Works with the python3 that ships with macOS (3.9) and newer."""
import json
import sys

print("{:20} {:34} {:12} {:18} {:8} {}".format("time (UTC)", "user", "model", "labels", "decision", "reason"))
for line in sys.stdin:
    try:
        r = json.loads(line)
    except ValueError:
        continue
    print("{:20} {:34} {:12} {:18} {:8} {}".format(
        r.get("ts", ""), str(r.get("user")), str(r.get("model")),
        ",".join(r.get("labels") or []), r.get("decision", ""), r.get("reason", "")))
