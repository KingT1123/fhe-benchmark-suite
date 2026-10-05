#!/usr/bin/env python3
"""Write experiments/config/energy_plan.csv: the --inner-loop each
(scheme, N, category, operation) cell uses in the round-3 energy run
(run_energy_memory_docker.sh), identical for Standard and Constrained.

Why per-cell: energy is read around the timed region only, and the RAPL
counter needs a window of tens of milliseconds to be measured accurately
(the counter advances in ~15 uJ steps and updates roughly every
millisecond). A fixed inner loop would give add at N=2048 a ~5 ms window
but multiply at N=16384 a ~50 s one. Instead each cell repeats its
operation enough times to fill ~TARGET_WINDOW_MS, using the Standard
scenario's measured mean latency. keygen ignores --inner-loop (one keygen
per rep), so it is always 1.

Run from experiments/scripts/:  python3 make_energy_plan.py
"""
import csv
import math

TARGET_WINDOW_MS = 50.0

with open("../results/final/seal_standard.csv", newline="") as f:
    rows = [r for r in csv.DictReader(f) if r["metric"] == "latency_ms" and r["mean"]]

with open("../config/energy_plan.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["scheme", "N", "category", "operation", "standard_latency_ms", "inner_loop"])
    for r in sorted(rows, key=lambda r: (r["scheme"], int(r["N"]), int(r["category"]), r["operation"])):
        lat = float(r["mean"])
        inner = 1 if r["operation"] == "keygen" else max(1, math.ceil(TARGET_WINDOW_MS / lat))
        w.writerow([r["scheme"], r["N"], r["category"], r["operation"], f"{lat:.6g}", inner])
print(f"wrote ../config/energy_plan.csv ({len(rows)} cells, target window {TARGET_WINDOW_MS} ms)")
