#!/usr/bin/env python3
"""Write the plans of the SEAL-OpenFHE energy/memory campaign
(run_energy_campaign.sh), one row per cell:

  energy_plan_campaign.csv  the full measurement matrix: every valid cell of
      the Standard latency campaign (results/final/openfhe_standard.csv)
      except rotation, whose energy and peak RSS are reported as not
      available (one rotation per repetition lasts a few milliseconds and
      SEAL's rotation branch does not read the energy counter).
  energy_plan_check.csv     stage-1 short check: representative cells of the
      matrix, including configurations outside the validation (which used
      N=8192/category 1 only) and the two OpenFHE-only operations.
  energy_plan_window.csv    stage-1 window test: the same operation measured
      with blocks of about 5, 10, 20, 50 and 100 ms (does the energy per
      operation depend on the block length; is there a fixed cost per
      counter read), and key generation with 100 repetitions.
  energy_plan_guard.csv     stage-1 mains-guard test: two cells.

Columns: library, scheme, N, category, operation, latency_ms (mean of the
latency campaign, boost on; the cell's latest session), inner_loop,
energy_reps, energy_runs, memory_runs, label (suffix of the output tag).

Inner loop: the rule of scripts/make_energy_plan.py (a block of about
TARGET_WINDOW_MS). Key generation: 1, except when one key generation lasts
less than KEYGEN_MIN_WINDOW_MS at fixed frequency (OpenFHE only, N <= 8192):
the energy counter, updated about once per millisecond, cannot resolve it
(campaign session d1 stopped on a zero reading for a 0.8 ms key generation),
so K key generations are timed in one window of about TARGET_WINDOW_MS
(bench_openfhe --keygen-per-window=K). At the fixed frequency of the
energy runs the blocks last about 1.3 times longer than computed here.
KEYGEN_REPS: 30, confirmed by the window test (session w1,
results/final/energy_campaign_window_decision.csv).

Run from experiments/openfhe/campaign/:  python3 make_energy_plans.py
"""
import csv
import math

TARGET_WINDOW_MS = 50.0
ENERGY_REPS = 30
KEYGEN_REPS = 30          # confirmed by the window test (session w1)
KEYGEN_MIN_WINDOW_MS = 10.0
ENERGY_RUNS, MEMORY_RUNS = 2, 3
FIXED_FREQ_FACTOR = 1.3   # latency at 3.27 GHz over latency with boost (validation sessions e1/e2)
FIELDS = ["library", "scheme", "N", "category", "operation", "latency_ms", "inner_loop",
          "energy_reps", "energy_runs", "memory_runs", "label"]
SCHEMES = ["BFV", "BGV", "CKKS"]
OPS = ["keygen", "encrypt", "decrypt", "decrypt_full", "add", "add_inplace", "multiply", "relinearize"]

latest = {}
for r in csv.DictReader(open("../../results/final/openfhe_standard.csv")):
    k = (r["library"].lower(), r["scheme"], r["N"], r["category"], r["operation"])
    if k not in latest or r["session"] > latest[k]["session"]:
        latest[k] = r


def row(k, inner=None, reps=None, eruns=ENERGY_RUNS, mruns=MEMORY_RUNS, label=""):
    lib, scheme, n, cat, op = k
    ms = float(latest[k]["mean_ms"])
    if inner is None:
        if op != "keygen":
            inner = max(1, math.ceil(TARGET_WINDOW_MS / ms))
        elif ms * FIXED_FREQ_FACTOR >= KEYGEN_MIN_WINDOW_MS:
            inner = 1
        else:
            assert lib == "openfhe", k   # --keygen-per-window exists in bench_openfhe only
            inner = math.ceil(TARGET_WINDOW_MS / (ms * FIXED_FREQ_FACTOR))
    if reps is None:
        reps = KEYGEN_REPS if op == "keygen" else ENERGY_REPS
    return dict(zip(FIELDS, [lib, scheme, n, cat, op, f"{ms:.6g}", inner, reps, eruns, mruns, label]))


def dump(name, rows):
    with open(name, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {name} ({len(rows)} cells)")


order = lambda k: (int(k[2]), int(k[3]), SCHEMES.index(k[1]), k[0] != "seal", OPS.index(k[4]))
matrix = sorted((k for k in latest if k[4] != "rotate"), key=order)
dump("energy_plan_campaign.csv", [row(k) for k in matrix])

# short check: all cells of two configurations outside the validation, the
# key-switching cells of a third, and the operations of CKKS 8192/1 that the
# validation did not cover (decrypt, add and the two OpenFHE-only operations)
check = [k for k in matrix if (k[1], k[2], k[3]) in (("CKKS", "16384", "1"), ("BFV", "4096", "3"))]
check += [k for k in matrix if (k[1], k[2], k[3]) == ("BGV", "8192", "3") and k[4] in ("keygen", "multiply", "relinearize")]
check += [k for k in matrix if (k[1], k[2], k[3]) == ("CKKS", "8192", "1") and k[4] in ("decrypt", "decrypt_full", "add", "add_inplace")]
dump("energy_plan_check.csv", [row(k) for k in check])

window = []
for lib in ("seal", "openfhe"):
    for op in ("encrypt", "multiply"):
        k = (lib, "CKKS", "8192", "1", op)
        per_op = float(latest[k]["mean_ms"]) * FIXED_FREQ_FACTOR
        for target in (5, 10, 20, 50, 100):
            inner = max(1, round(target / per_op))
            window.append(row(k, inner=inner, mruns=0, label=f"w{target}"))
    for scheme in ("CKKS", "BFV"):
        window.append(row((lib, scheme, "8192", "1", "keygen"), reps=100, mruns=0, label="r100"))
dump("energy_plan_window.csv", window)

dump("energy_plan_guard.csv", [row((lib, "CKKS", "8192", "1", "multiply"), eruns=2, mruns=1) for lib in ("seal", "openfhe")])
