#!/usr/bin/env python3
"""
summarize_results.py — quick sanity-check summary over the final SEAL CSV.
Read-only: does not compute or alter any statistics (those belong solely to
aggregate.py per project convention). Just groups/reports what's already there.

Usage:
    python3 summarize_results.py
    python3 summarize_results.py --csv=../results/final/seal_standard.csv
"""

import argparse
import csv
import statistics
from collections import defaultdict


def load_rows(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def print_latency_summary(rows):
    print("=== Latency (ms) — min/mean/max per operation, successful configs only ===")
    by_op = defaultdict(list)
    for r in rows:
        if r["metric"] == "latency_ms" and r["mean"] != "":
            by_op[r["operation"]].append(float(r["mean"]))
    for op in sorted(by_op):
        vals = by_op[op]
        print(f"  {op:<14} min={min(vals):9.4f}  mean={statistics.mean(vals):9.4f}  "
              f"max={max(vals):9.4f}  (n={len(vals)})")


def print_grouped_by_n(rows, metric, label):
    print(f"\n=== {label} — operation=multiply, mean per N ===")
    by_n = defaultdict(list)
    for r in rows:
        if r["metric"] == metric and r["operation"] == "multiply" and r["mean"] != "":
            by_n[int(r["N"])].append(float(r["mean"]))
    for n in sorted(by_n):
        vals = by_n[n]
        print(f"  N={n:<7} mean={statistics.mean(vals):9.4f}  (n={len(vals)})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default="../results/final/seal_standard.csv")
    args = ap.parse_args()

    rows = load_rows(args.csv)

    print_latency_summary(rows)
    print_grouped_by_n(rows, "energy_pkg_j_per_op", "Energy (J/op)")
    print_grouped_by_n(rows, "peak_memory_mb", "Peak memory (MB)")


if __name__ == "__main__":
    main()
