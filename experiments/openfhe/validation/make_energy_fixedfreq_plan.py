#!/usr/bin/env python3
"""Write experiments/openfhe/validation/energy_plan_fixedfreq.csv: the cells of
the limited energy/memory validation at fixed frequency
(run_energy_validation.sh) and the --inner-loop of each.

Cells: BFV, BGV and CKKS at N=8192, category 1 (the one configuration where
all three schemes support every operation in both libraries), operations
keygen, encrypt, multiply, relinearize, for SEAL and OpenFHE.

Inner loop: the rule of make_energy_plan.py (a timed window of about
TARGET_WINDOW_MS per repetition, keygen always 1), applied per library to the
mean latency of the Standard campaign session s2 (results/final/
openfhe_standard.csv), where both libraries were measured in the same
session. Those latencies were measured with boost on; at the fixed frequency
(3.27 GHz instead of ~4.2 GHz) the windows come out about 30% longer, which
only makes the RAPL reading more precise.

Run from experiments/openfhe/validation/:  python3 make_energy_fixedfreq_plan.py
"""
import csv
import math

TARGET_WINDOW_MS = 50.0
SCHEMES = ("BFV", "BGV", "CKKS")
OPS = ("keygen", "encrypt", "multiply", "relinearize")

lat = {}
for r in csv.DictReader(open("../../results/final/openfhe_standard.csv")):
    if r["session"] == "s2" and r["N"] == "8192" and r["category"] == "1" and r["operation"] in OPS:
        lat[(r["library"].lower(), r["scheme"], r["operation"])] = float(r["mean_ms"])

with open("energy_plan_fixedfreq.csv", "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["library", "scheme", "N", "category", "operation", "s2_latency_ms", "inner_loop"])
    for lib in ("seal", "openfhe"):
        for s in SCHEMES:
            for op in OPS:
                ms = lat[(lib, s, op)]
                inner = 1 if op == "keygen" else max(1, math.ceil(TARGET_WINDOW_MS / ms))
                w.writerow([lib, s, 8192, 1, op, f"{ms:.6g}", inner])
print(f"wrote energy_plan_fixedfreq.csv ({2 * len(SCHEMES) * len(OPS)} cells, target window {TARGET_WINDOW_MS} ms)")
