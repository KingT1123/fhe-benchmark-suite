#!/usr/bin/env python3
"""
aggregate.py — turns raw per-iteration CSVs + perf/time logs into the single
final CSV that Chapter 5 reads.

Statistics policy (Chapter 3, Section 3.4):
  - warm-up rows (status == "warmup", the first 5 iterations) are discarded
  - mean, std, and 95% CI are computed over the remaining "measured" rows
  - if std > 5% of mean, the row is flagged in the `flag` column for
    manual re-run investigation (per the Weiser et al. 2018 protocol)

Usage:
    python3 aggregate.py --scenario=standard
    python3 aggregate.py --scenario=constrained
    python3 aggregate.py --scenario=edge_batch
    python3 aggregate.py --scenario=size
    python3 aggregate.py --scenario=noise_trace
    python3 aggregate.py --scenario=ckks_error

--scenario=edge_batch reads experiments/results/raw/edge_batch/ (a separate
subdirectory from the other two scenarios, written by
run_edge_batch_docker.sh) and additionally computes, per batch size:
  - throughput_items_per_sec, derived from the measured batch latency
  - keygen_amortized_ms, derived by dividing the single (batch-size-
    invariant) keygen measurement across the swept batch sizes -- keygen
    itself is only ever measured once per (scheme, N, category) cell, not
    re-run per batch size (see bench_seal.cpp)
Batch trials that used fewer than the batch-size=1 baseline's 100 reps (see
run_edge_batch_docker.sh's REPS_FOR_BATCH) are flagged
"reduced_reps_at_batch_size", the same honest-limitation spirit as the
existing n=1_invocation_not_repeated energy/memory flag.

--scenario=size / noise_trace / ckks_error are Chapter 3's three previously
-deferred metrics (storage, noise-budget evolution, CKKS error
accumulation). Kept as their own separate aggregation path, not folded
into the standard/constrained/edge_batch path above -- none of the three
come from a --reps/--warmup timed loop in bench_seal.cpp, so "statistics"
means something different for each:
  - size is a single deterministic measurement per (scheme, N, category,
    artifact) -- there is no trial to average over, so mean/std/CI stay
    empty and the row is flagged deterministic_single_measurement instead
    of silently looking like an n=1 statistical claim.
  - noise_trace/ckks_error use bench_seal's --trace-reps (10 by default)
    independent trials per step, which DO get real mean/std/95% CI here,
    same policy (and the same HIGH_VARIANCE > 5%-relative-std threshold)
    as the six timed operations.
Each reads its already-consolidated master raw file directly (written by
run_extended_metrics_docker.sh's consolidate() step) rather than globbing
per-cell files the way standard/constrained/edge_batch do, since that
consolidation already happened once, upstream, by design.
"""

import argparse
import csv
import glob
import math
import os
import re
import statistics
from pathlib import Path

try:
    from scipy import stats as scipy_stats
    HAVE_SCIPY = True
except Exception:
    HAVE_SCIPY = False


def t_critical(n, confidence=0.95):
    """95% CI multiplier. Uses Student's t (df = n-1) if scipy is available,
    otherwise falls back to the normal-approximation 1.96 (fine for n>=30,
    which is always true here since reps defaults to 100)."""
    if n <= 1:
        return 0.0
    if HAVE_SCIPY:
        return float(scipy_stats.t.ppf((1 + confidence) / 2, df=n - 1))
    return 1.96


def parse_energy_log(path):
    """Extract Joules from a `perf stat -e power/energy-pkg/,power/energy-cores/`
    log. Returns (energy_pkg_j, energy_cores_j), either possibly None if the
    counter wasn't available (e.g. no RAPL access)."""
    if not os.path.exists(path):
        return None, None
    pkg, cores = None, None
    with open(path, "r", errors="replace") as f:
        text = f.read()
    # perf stat lines look like: "      1.23 Joules power/energy-pkg/"
    m = re.search(r"([\d.,]+)\s*Joules\s+power/energy-pkg/", text)
    if m:
        pkg = float(m.group(1).replace(",", ""))
    m = re.search(r"([\d.,]+)\s*Joules\s+power/energy-cores/", text)
    if m:
        cores = float(m.group(1).replace(",", ""))
    return pkg, cores


def parse_mem_log(path):
    """Extract peak RSS (MB) from `/usr/bin/time -v` output."""
    if not os.path.exists(path):
        return None
    with open(path, "r", errors="replace") as f:
        text = f.read()
    m = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", text)
    if m:
        return int(m.group(1)) / 1024.0
    return None


def aggregate_latency_file(path):
    """Read one raw per-iteration CSV, return a dict of summary stats,
    or None if the file represents a skipped (depth==0) configuration."""
    rows = list(csv.DictReader(open(path)))
    if not rows:
        return None
    if rows[0].get("status") == "skipped_depth0":
        return {"status": "skipped_depth0", **{k: rows[0][k] for k in
                ("library", "scheme", "N", "category", "operation")}}

    measured = [float(r["latency_ms"]) for r in rows if r["status"] == "measured"]
    if not measured:
        return None

    mean = statistics.mean(measured)
    std = statistics.stdev(measured) if len(measured) > 1 else 0.0
    tcrit = t_critical(len(measured))
    margin = tcrit * std / math.sqrt(len(measured))
    flag = "HIGH_VARIANCE" if mean > 0 and (std / mean) > 0.05 else ""

    base = rows[0]
    return {
        "library": base["library"], "scheme": base["scheme"], "N": base["N"],
        "category": base["category"], "operation": base["operation"],
        "n_measured": len(measured), "mean_ms": mean, "std_ms": std,
        "ci_low_ms": mean - margin, "ci_high_ms": mean + margin, "flag": flag,
        "status": "ok",
    }


# ---------- Edge/Batch scenario ----------

BASELINE_REPS = 100  # reps used at batch_size=1 -- the reference point for
                      # "reduced reps" flagging at larger batch sizes.
BATCH_SIZES = [1, 10, 100]  # must match run_edge_batch_docker.sh's sweep;
                             # used only to fan keygen's single measurement
                             # out into amortized-per-batch-size rows.


def aggregate_batched_latency_file(path):
    """Like aggregate_latency_file, but reads the batch_size column that
    only edge_batch raw files have, and adds a reduced_reps_at_batch_size
    flag when a file has fewer than BASELINE_REPS measured rows (expected
    at batch_size=10/100 -- run_edge_batch_docker.sh deliberately reduces
    reps there so the sweep stays tractable)."""
    rows = list(csv.DictReader(open(path)))
    if not rows:
        return None  # header-only file: SEAL failed to build params at all
                      # (e.g. N=2048/cat5) -- same "missing, not fabricated"
                      # treatment as the other scenarios.
    if rows[0].get("status") == "skipped_depth0":
        r0 = rows[0]
        return {"status": "skipped_depth0", **{k: r0[k] for k in
                ("library", "scheme", "N", "category", "operation", "batch_size")}}

    measured = [float(r["latency_ms"]) for r in rows if r["status"] == "measured"]
    if not measured:
        return None

    mean = statistics.mean(measured)
    std = statistics.stdev(measured) if len(measured) > 1 else 0.0
    tcrit = t_critical(len(measured))
    margin = tcrit * std / math.sqrt(len(measured))
    flags = []
    if mean > 0 and (std / mean) > 0.05:
        flags.append("HIGH_VARIANCE")
    if len(measured) < BASELINE_REPS:
        flags.append("reduced_reps_at_batch_size")

    base = rows[0]
    return {
        "library": base["library"], "scheme": base["scheme"], "N": base["N"],
        "category": base["category"], "operation": base["operation"],
        "batch_size": int(base["batch_size"]),
        "n_measured": len(measured), "n_total_rows": len(rows),
        "mean_ms": mean, "std_ms": std,
        "ci_low_ms": mean - margin, "ci_high_ms": mean + margin,
        "flag": ";".join(flags), "status": "ok",
    }


def aggregate_edge_batch(args):
    log_dir = args.log_dir or "../results/logs/edge_batch"
    out_path = args.out or "../results/final/seal_edge_batch.csv"

    files = sorted(glob.glob(os.path.join(args.raw_dir, "seal_*.csv")))
    keygen_files = [f for f in files if f.endswith("_keygen_batch1.csv")]
    batch_files = [f for f in files if not f.endswith("_keygen_batch1.csv")]

    out_rows = []

    # ---- keygen: measured once, own latency row, plus derived amortized
    # rows fanned out across the swept batch sizes (arithmetic, not a
    # re-measurement -- bench_seal deliberately ignores --batch-size here) ----
    for f in keygen_files:
        summary = aggregate_batched_latency_file(f)
        if summary is None:
            continue  # e.g. N=2048/cat5 prime-search failure
        tag = Path(f).stem
        energy_pkg, _ = parse_energy_log(os.path.join(log_dir, f"{tag}_energy.log"))
        mem_mb = parse_mem_log(os.path.join(log_dir, f"{tag}_mem.log"))

        common = {"library": summary["library"], "scheme": summary["scheme"],
                   "N": summary["N"], "category": summary["category"],
                   "scenario": "edge_batch", "operation": "keygen"}

        out_rows.append({**common, "batch_size": 1, "metric": "latency_ms",
                          "mean": summary["mean_ms"], "std": summary["std_ms"],
                          "ci_low": summary["ci_low_ms"], "ci_high": summary["ci_high_ms"],
                          "flag": summary["flag"]})
        if energy_pkg is not None:
            out_rows.append({**common, "batch_size": 1, "metric": "energy_pkg_j_per_op",
                              "mean": energy_pkg / summary["n_total_rows"],
                              "std": "", "ci_low": "", "ci_high": "",
                              "flag": "n=1_invocation_not_repeated"})
        if mem_mb is not None:
            out_rows.append({**common, "batch_size": 1, "metric": "peak_memory_mb",
                              "mean": mem_mb, "std": "", "ci_low": "", "ci_high": "",
                              "flag": "n=1_invocation_not_repeated"})

        for b in BATCH_SIZES:
            out_rows.append({**common, "batch_size": b, "metric": "keygen_amortized_ms",
                              "mean": summary["mean_ms"] / b,
                              "std": "", "ci_low": "", "ci_high": "",
                              "flag": "derived_not_measured"})

    # ---- encrypt/decrypt/add/multiply/relinearize: latency + derived
    # throughput per batch size ----
    for f in batch_files:
        summary = aggregate_batched_latency_file(f)
        if summary is None:
            continue

        if summary.get("status") == "skipped_depth0":
            out_rows.append({
                "library": summary["library"], "scheme": summary["scheme"],
                "N": summary["N"], "category": summary["category"],
                "scenario": "edge_batch", "operation": summary["operation"],
                "batch_size": int(summary["batch_size"]), "metric": "latency_ms",
                "mean": "", "std": "", "ci_low": "", "ci_high": "",
                "flag": "skipped_depth0_undefined_at_this_config",
            })
            continue

        common = {"library": summary["library"], "scheme": summary["scheme"],
                   "N": summary["N"], "category": summary["category"],
                   "scenario": "edge_batch", "operation": summary["operation"]}
        b = summary["batch_size"]
        tag = Path(f).stem
        energy_pkg, _ = parse_energy_log(os.path.join(log_dir, f"{tag}_energy.log"))
        mem_mb = parse_mem_log(os.path.join(log_dir, f"{tag}_mem.log"))

        out_rows.append({**common, "batch_size": b, "metric": "latency_ms",
                          "mean": summary["mean_ms"], "std": summary["std_ms"],
                          "ci_low": summary["ci_low_ms"], "ci_high": summary["ci_high_ms"],
                          "flag": summary["flag"]})

        throughput = b / (summary["mean_ms"] / 1000.0)
        out_rows.append({**common, "batch_size": b, "metric": "throughput_items_per_sec",
                          "mean": throughput, "std": "", "ci_low": "", "ci_high": "",
                          "flag": summary["flag"]})  # carries HIGH_VARIANCE /
                          # reduced_reps_at_batch_size forward: it's derived
                          # from the same limited-sample latency mean.

        if energy_pkg is not None:
            # Energy is summable across the batch -> normalize to per-item,
            # keeping this metric's meaning consistent with Standard/
            # Constrained's "per operation" semantics.
            out_rows.append({**common, "batch_size": b, "metric": "energy_pkg_j_per_op",
                              "mean": (energy_pkg / summary["n_total_rows"]) / b,
                              "std": "", "ci_low": "", "ci_high": "",
                              "flag": "n=1_invocation_not_repeated"})
        if mem_mb is not None:
            # Peak memory is NOT summable (it's a high-water mark while all
            # b items are held at once) -- reported as-is, not divided.
            out_rows.append({**common, "batch_size": b, "metric": "peak_memory_mb",
                              "mean": mem_mb, "std": "", "ci_low": "", "ci_high": "",
                              "flag": "n=1_invocation_not_repeated"})

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    fieldnames = ["library", "scheme", "N", "category", "scenario", "operation",
                  "batch_size", "metric", "mean", "std", "ci_low", "ci_high", "flag"]
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in out_rows:
            w.writerow({k: r.get(k, "") for k in fieldnames})

    n_flagged = sum(1 for r in out_rows if "HIGH_VARIANCE" in r.get("flag", ""))
    n_reduced = sum(1 for r in out_rows if "reduced_reps_at_batch_size" in r.get("flag", ""))
    print(f"Wrote {len(out_rows)} rows to {out_path}")
    print(f"{n_flagged} row(s) flagged HIGH_VARIANCE (std > 5% of mean).")
    print(f"{n_reduced} row(s) flagged reduced_reps_at_batch_size (fewer than "
          f"{BASELINE_REPS} reps -- expected at batch_size=10/100, an honest "
          f"limitation, not a bug).")


def _write_final(out_path, out_rows,
                  fieldnames=("library", "scheme", "N", "category", "scenario",
                              "operation", "metric", "mean", "std", "ci_low",
                              "ci_high", "flag")):
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(fieldnames))
        w.writeheader()
        for r in out_rows:
            w.writerow({k: r.get(k, "") for k in fieldnames})


def _stats_over_trials(values):
    """Real mean/std/95% CI + HIGH_VARIANCE flag over independent trials --
    same policy as aggregate_latency_file, just over --trace-reps trials
    instead of --reps iterations."""
    n = len(values)
    mean = statistics.mean(values)
    std = statistics.stdev(values) if n > 1 else 0.0
    tcrit = t_critical(n)
    margin = tcrit * std / math.sqrt(n) if n > 0 else 0.0
    flag = "HIGH_VARIANCE" if mean != 0 and (std / abs(mean)) > 0.05 else ""
    return mean, std, mean - margin, mean + margin, flag


def aggregate_size(args):
    """size is deterministic per (scheme, N, category, artifact) -- one
    measurement, not a trial to average. mean carries the raw byte count;
    std/ci stay empty and the row is flagged so that emptiness reads as
    "not applicable", not as missing data."""
    in_path = args.raw_dir or "../results/raw/extended_metrics/seal_sizes.csv"
    out_path = args.out or "../results/final/seal_sizes.csv"

    rows = list(csv.DictReader(open(in_path)))
    out_rows = []
    for r in rows:
        skipped = r["status"] == "skipped_depth0"
        out_rows.append({
            "library": r["library"], "scheme": r["scheme"], "N": r["N"],
            "category": r["category"], "scenario": "size", "operation": r["artifact"],
            "metric": "size_bytes",
            "mean": "" if skipped else r["size_bytes"],
            "std": "", "ci_low": "", "ci_high": "",
            "flag": "skipped_depth0_undefined_at_this_config" if skipped
                    else "deterministic_single_measurement",
        })

    _write_final(out_path, out_rows)
    n_skipped = sum(1 for r in out_rows if "skipped_depth0" in r["flag"])
    print(f"Wrote {len(out_rows)} rows to {out_path}")
    print(f"{n_skipped} row(s) skipped_depth0 (relin_keys at depth==0 configs).")


def aggregate_noise_trace(args):
    """noise_trace groups by (scheme, N, category, step_name) across the
    --trace-reps trials and computes real mean/std/95% CI per step. CKKS
    rows are a single skipped_not_applicable_ckks row per cell (SEAL has
    no CKKS noise-budget API), passed through as-is, not grouped."""
    in_path = args.raw_dir or "../results/raw/extended_metrics/seal_noise_budget.csv"
    out_path = args.out or "../results/final/seal_noise_budget.csv"

    rows = list(csv.DictReader(open(in_path)))
    groups = {}
    skip_rows = []
    for r in rows:
        if r["status"] == "skipped_not_applicable_ckks":
            skip_rows.append(r)
            continue
        key = (r["library"], r["scheme"], int(r["N"]), int(r["category"]), r["step_name"])
        groups.setdefault(key, []).append(int(r["noise_budget_bits"]))

    out_rows = []
    # step_name sorts lexically (fresh, after_add, after_multiply_N, ...);
    # matches numeric order here since the grid's deepest cell is depth=7
    # (single-digit multiply/relinearize indices only).
    for (library, scheme, N, category, step_name), values in sorted(groups.items()):
        mean, std, ci_low, ci_high, flag = _stats_over_trials(values)
        out_rows.append({
            "library": library, "scheme": scheme, "N": N, "category": category,
            "scenario": "noise_trace", "operation": step_name,
            "metric": "noise_budget_bits", "mean": mean, "std": std,
            "ci_low": ci_low, "ci_high": ci_high, "flag": flag,
        })

    for r in skip_rows:
        out_rows.append({
            "library": r["library"], "scheme": r["scheme"], "N": r["N"],
            "category": r["category"], "scenario": "noise_trace", "operation": "",
            "metric": "noise_budget_bits", "mean": "", "std": "", "ci_low": "",
            "ci_high": "", "flag": "skipped_not_applicable_ckks",
        })

    _write_final(out_path, out_rows)
    n_flagged = sum(1 for r in out_rows if r["flag"] == "HIGH_VARIANCE")
    n_skipped = sum(1 for r in out_rows if r["flag"] == "skipped_not_applicable_ckks")
    print(f"Wrote {len(out_rows)} rows to {out_path}")
    print(f"{n_flagged} row(s) flagged HIGH_VARIANCE (std > 5% of mean across "
          f"{len(next(iter(groups.values()), []))} trials).")
    print(f"{n_skipped} row(s) skipped_not_applicable_ckks (CKKS has no SEAL "
          f"noise-budget API -- see bench_seal.cpp).")


def aggregate_ckks_error(args):
    """ckks_error mirrors aggregate_noise_trace, but each step carries two
    metrics (max_abs_error, mean_abs_error), each grouped and averaged
    separately. BFV rows are a single skipped_not_applicable_bfv row per
    cell (BFV/BGV are exact schemes, no rounding error by construction)."""
    in_path = args.raw_dir or "../results/raw/extended_metrics/seal_ckks_error.csv"
    out_path = args.out or "../results/final/seal_ckks_error.csv"

    rows = list(csv.DictReader(open(in_path)))
    groups_max, groups_mean = {}, {}
    skip_rows = []
    for r in rows:
        if r["status"] == "skipped_not_applicable_bfv":
            skip_rows.append(r)
            continue
        key = (r["library"], r["scheme"], int(r["N"]), int(r["category"]), r["step_name"])
        groups_max.setdefault(key, []).append(float(r["max_abs_error"]))
        groups_mean.setdefault(key, []).append(float(r["mean_abs_error"]))

    out_rows = []
    for key in sorted(groups_max.keys()):
        library, scheme, N, category, step_name = key
        common = {"library": library, "scheme": scheme, "N": N, "category": category,
                   "scenario": "ckks_error", "operation": step_name}

        mean, std, ci_low, ci_high, flag = _stats_over_trials(groups_max[key])
        out_rows.append({**common, "metric": "max_abs_error", "mean": mean,
                          "std": std, "ci_low": ci_low, "ci_high": ci_high, "flag": flag})

        mean2, std2, ci_low2, ci_high2, flag2 = _stats_over_trials(groups_mean[key])
        out_rows.append({**common, "metric": "mean_abs_error", "mean": mean2,
                          "std": std2, "ci_low": ci_low2, "ci_high": ci_high2, "flag": flag2})

    for r in skip_rows:
        for metric in ("max_abs_error", "mean_abs_error"):
            out_rows.append({
                "library": r["library"], "scheme": r["scheme"], "N": r["N"],
                "category": r["category"], "scenario": "ckks_error", "operation": "",
                "metric": metric, "mean": "", "std": "", "ci_low": "", "ci_high": "",
                "flag": "skipped_not_applicable_bfv",
            })

    _write_final(out_path, out_rows)
    n_flagged = sum(1 for r in out_rows if r["flag"] == "HIGH_VARIANCE")
    n_skipped = sum(1 for r in out_rows if r["flag"] == "skipped_not_applicable_bfv")
    print(f"Wrote {len(out_rows)} rows to {out_path}")
    print(f"{n_flagged} row(s) flagged HIGH_VARIANCE (std > 5% of mean across "
          f"{len(next(iter(groups_max.values()), []))} trials).")
    print(f"{n_skipped} row(s) skipped_not_applicable_bfv (BFV/BGV are exact "
          f"schemes, no rounding error by construction).")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", required=True,
                     choices=["standard", "constrained", "edge_batch",
                              "size", "noise_trace", "ckks_error"])
    ap.add_argument("--raw-dir", default=None)
    ap.add_argument("--log-dir", default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    if args.scenario in ("size", "noise_trace", "ckks_error"):
        # --raw-dir means the consolidated master FILE for these three, not
        # a directory to glob (see module docstring) -- args.raw_dir is left
        # None here so each aggregate_* function's own default path is used.
        {"size": aggregate_size, "noise_trace": aggregate_noise_trace,
         "ckks_error": aggregate_ckks_error}[args.scenario](args)
        return

    if args.raw_dir is None:
        args.raw_dir = ("../results/raw/edge_batch" if args.scenario == "edge_batch"
                         else "../results/raw")

    if args.scenario == "edge_batch":
        aggregate_edge_batch(args)
        if not HAVE_SCIPY:
            print("NOTE: scipy not found, used 1.96 normal-approx instead of Student's t "
                  "for the 95% CI. Fine for n>=30; batch_size=100 trials only have 10 "
                  "reps, so this approximation is coarser there -- worth installing "
                  "scipy (`pip install scipy`) before trusting those CIs closely.")
        return

    log_dir = args.log_dir or f"../results/logs/{args.scenario}"
    out_path = args.out or f"../results/final/seal_{args.scenario}.csv"

    suffix = "_constrained" if args.scenario == "constrained" else ""
    pattern = os.path.join(args.raw_dir, f"seal_*{suffix}.csv")
    # Avoid double-matching: standard files have no _constrained suffix
    files = sorted(glob.glob(os.path.join(args.raw_dir, "seal_*.csv")))
    if args.scenario == "standard":
        files = [f for f in files if "_constrained" not in f]
    else:
        files = [f for f in files if "_constrained" in f]

    out_rows = []
    for f in files:
        summary = aggregate_latency_file(f)
        if summary is None:
            continue
        tag = Path(f).stem.replace("_constrained", "")
        energy_pkg, energy_cores = parse_energy_log(
            os.path.join(log_dir, f"{tag}_energy.log"))
        mem_mb = parse_mem_log(os.path.join(log_dir, f"{tag}_mem.log"))

        if summary.get("status") == "skipped_depth0":
            out_rows.append({
                "library": summary["library"], "scheme": summary["scheme"],
                "N": summary["N"], "category": summary["category"],
                "scenario": args.scenario, "operation": summary["operation"],
                "metric": "latency_ms", "mean": "", "std": "", "ci_low": "",
                "ci_high": "", "flag": "skipped_depth0_undefined_at_this_config",
            })
            continue

        n_total = summary["n_measured"] + 5  # + warmup, for per-op energy division
        out_rows.append({
            "library": summary["library"], "scheme": summary["scheme"],
            "N": summary["N"], "category": summary["category"],
            "scenario": args.scenario, "operation": summary["operation"],
            "metric": "latency_ms", "mean": summary["mean_ms"],
            "std": summary["std_ms"], "ci_low": summary["ci_low_ms"],
            "ci_high": summary["ci_high_ms"], "flag": summary["flag"],
        })
        if energy_pkg is not None:
            out_rows.append({
                "library": summary["library"], "scheme": summary["scheme"],
                "N": summary["N"], "category": summary["category"],
                "scenario": args.scenario, "operation": summary["operation"],
                "metric": "energy_pkg_j_per_op", "mean": energy_pkg / n_total,
                "std": "", "ci_low": "", "ci_high": "",
                "flag": "n=1_invocation_not_repeated",
            })
        if mem_mb is not None:
            out_rows.append({
                "library": summary["library"], "scheme": summary["scheme"],
                "N": summary["N"], "category": summary["category"],
                "scenario": args.scenario, "operation": summary["operation"],
                "metric": "peak_memory_mb", "mean": mem_mb,
                "std": "", "ci_low": "", "ci_high": "",
                "flag": "n=1_invocation_not_repeated",
            })

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    fieldnames = ["library", "scheme", "N", "category", "scenario", "operation",
                  "metric", "mean", "std", "ci_low", "ci_high", "flag"]
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in out_rows:
            w.writerow({k: r.get(k, "") for k in fieldnames})

    n_flagged = sum(1 for r in out_rows if r.get("flag") == "HIGH_VARIANCE")
    print(f"Wrote {len(out_rows)} rows to {out_path}")
    print(f"{n_flagged} row(s) flagged HIGH_VARIANCE (std > 5% of mean) — "
          f"consider re-running those configs.")
    if not HAVE_SCIPY:
        print("NOTE: scipy not found, used 1.96 normal-approx instead of Student's t "
              "for the 95% CI. Fine for n>=30 (default reps=100), install scipy "
              "(`pip install scipy`) for exactness at smaller n.")


if __name__ == "__main__":
    main()
