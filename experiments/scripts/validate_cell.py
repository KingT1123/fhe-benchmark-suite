#!/usr/bin/env python3
"""validate_cell.py — the single definition of a VALID measurement cell
(fail-closed). Used by the run scripts (resume: a cell is skipped only if it
is valid; an invalid one is moved aside and re-run) and by aggregate.py (only
valid cells enter the statistics). It computes no statistics.

A cell = one raw CSV written by bench_seal/bench_openfhe, plus its
correctness-check CSV. It is valid only if ALL of these hold:
  * the CSV exists, no leftover <csv>.tmp or <csv>.invalid next to it, and no
    line starting with '#' (diagnostic marker);
  * header has iteration, latency_ms and status columns;
  * exactly warmup + reps data rows; iteration = 0, 1, ... in order; status
    "warmup" for the first `warmup` rows and "measured" for the others;
  * every latency_ms is a finite number > 0; energy columns, when present,
    are integers (inner_loop >= 1, energy_uj >= 0) and idle_power_w a number;
  * library/scheme/N/category/operation identical on every row;
  * the check CSV (when required) has one row per repetition, the same
    iterations, and every row "correct".
Usage (exit status 0 = valid, 1 = invalid, reason on stdout):
  python3 validate_cell.py CSV --rows 105 --warmup 5 [--check CHECK_CSV]
"""
import argparse
import csv
import math
import os
import sys


def validate(path, rows, warmup, check=None):
    """Returns (True, "ok") or (False, reason)."""
    if not os.path.exists(path):
        return False, "missing output file"
    for suffix in (".tmp", ".invalid"):
        if os.path.exists(path + suffix):
            return False, f"leftover {os.path.basename(path)}{suffix} (interrupted or failed attempt)"
    try:
        lines = open(path, newline="").read().splitlines()
    except OSError as e:
        return False, f"unreadable: {e}"
    if any(l.startswith("#") for l in lines):
        return False, "diagnostic marker in file"
    data = list(csv.DictReader(lines))
    if not data or not {"iteration", "latency_ms", "status"} <= set(data[0]):
        return False, "missing columns or no data rows"
    if len(data) != rows:
        return False, f"{len(data)} data rows, expected {rows}"
    ident = {k: data[0].get(k) for k in ("library", "scheme", "N", "category", "operation")}
    for i, r in enumerate(data):
        if any(r.get(k) != v for k, v in ident.items()):
            return False, f"row {i}: identity columns differ"
        if r["iteration"] != str(i):
            return False, f"row {i}: iteration {r['iteration']}"
        if r["status"] != ("warmup" if i < warmup else "measured"):
            return False, f"row {i}: status {r['status']}"
        try:
            lat = float(r["latency_ms"])
        except (TypeError, ValueError):
            return False, f"row {i}: latency not a number"
        if not (math.isfinite(lat) and lat > 0):
            return False, f"row {i}: latency {lat}"
        if "energy_uj" in r:
            try:
                if int(r["inner_loop"]) < 1 or int(r["energy_uj"]) < 0:
                    return False, f"row {i}: energy columns out of range"
                float(r["idle_power_w"])
            except (TypeError, ValueError):
                return False, f"row {i}: energy columns not numbers"
    if check is not None:
        if not os.path.exists(check):
            return False, "missing correctness-check file"
        if os.path.exists(check + ".tmp"):
            return False, "leftover check .tmp"
        c = list(csv.DictReader(open(check, newline="")))
        if len(c) != rows:
            return False, f"check file has {len(c)} rows, expected {rows}"
        for i, r in enumerate(c):
            if r.get("iteration") != str(i):
                return False, f"check row {i}: iteration {r.get('iteration')}"
            if r.get("correctness") != "correct":
                return False, f"check row {i}: {r.get('correctness')}"
    return True, "ok"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--rows", type=int, required=True)
    ap.add_argument("--warmup", type=int, required=True)
    ap.add_argument("--check", default=None)
    a = ap.parse_args()
    ok, reason = validate(a.csv, a.rows, a.warmup, a.check)
    print(reason)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
