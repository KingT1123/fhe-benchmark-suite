#!/usr/bin/env python3
"""Quick breakdown of which operations got flagged HIGH_VARIANCE, and by how
much -- run this against results/final/seal_standard.csv to see whether the
flags cluster on fast operations (expected, timer-noise territory) or are
spread across slow ones too (would suggest background load during the run)."""
import csv
import sys
from collections import defaultdict
from pathlib import Path

if len(sys.argv) > 1:
    path = Path(sys.argv[1])
else:
    # Resolve relative to this script's own location, not the current
    # working directory -- works no matter where you call it from.
    path = Path(__file__).resolve().parent.parent / "results" / "final" / "seal_standard.csv"

if not path.exists():
    print(f"ERROR: no file at {path}")
    print("Did you run aggregate.py --scenario=standard yet? It writes exactly this file.")
    print(f"Check what's actually there: ls {path.parent}")
    sys.exit(1)

by_op = defaultdict(lambda: [0, 0])  # operation -> [flagged, total]

with open(path) as f:
    for row in csv.DictReader(f):
        if row["metric"] != "latency_ms" or not row["mean"]:
            continue
        op = row["operation"]
        by_op[op][1] += 1
        if row["flag"] == "HIGH_VARIANCE":
            by_op[op][0] += 1

print(f"Reading: {path}\n")
print(f"{'operation':<14} {'flagged/total'}")
for op, (flagged, total) in sorted(by_op.items()):
    pct = 100 * flagged / total if total else 0
    print(f"{op:<14} {flagged}/{total} ({pct:.0f}%)")