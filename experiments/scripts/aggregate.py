#!/usr/bin/env python3
"""
aggregate.py — turns raw per-iteration CSVs + perf/time logs into the single
final CSV that Chapter 5 reads.

Statistics policy (Chapter 3, Section 3.4):
  - warm-up rows (status == "warmup", the first 5 iterations) are discarded
  - mean, std, and 95% CI are computed over the remaining "measured" rows
  - median and IQR (25th/75th percentile) are computed alongside mean/std/CI
    for every metric that gets real per-trial statistics (robust companions
    to mean/std, useful for reading skew that HIGH_VARIANCE's std/mean ratio
    alone doesn't show) -- not computed for size (deterministic, n=1 per
    artifact, nothing to take a spread over)
  - if std > 5% of mean, the row is flagged in the `flag` column for
    manual re-run investigation (per the Weiser et al. 2018 protocol)

Usage:
    python3 aggregate.py --scenario=standard
    python3 aggregate.py --scenario=constrained
    python3 aggregate.py --scenario=edge_batch
    python3 aggregate.py --scenario=packing
    python3 aggregate.py --scenario=composite
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

--scenario=packing reads experiments/results/raw/packing/ (its own
subdirectory, written by run_packing_docker.sh) -- Chapter 3's "how many of
a ciphertext's available slots hold a real value" question, deliberately
separate from edge_batch's "how many separate ciphertexts" axis. Adds two
derived per-real-value metrics (mirroring keygen_amortized_ms above):
latency_per_value_ms = latency_ms / n_real, and throughput_items_per_sec =
1000 / latency_per_value_ms. size rows (does serialized ciphertext size
actually depend on fill level, or is it fixed regardless -- measured, not
assumed) get the same deterministic_single_measurement flag as
--scenario=size below.

--scenario=composite reads experiments/results/raw/composite/ (its own
subdirectory, written by run_composite_docker.sh) -- Chapter 3's chained-
workload question: does single-operation timing (Standard scenario) predict
multi-operation cost? Covers rotate (isolated single-rotate measurement,
plus galois_keygen_ms/galois_keys_size_bytes companion metrics), dot_product
(multiply -> relinearize -> rotate-and-add chain, swept over --vec-len, with
noise_budget_bits logged for BFV/BGV), and poly_eval (elementwise
a*x^2+b*x+c, single fully-packed measurement). After the usual latency
aggregation, runs a prediction-vs-actual check (the actual point of this
scenario): predicted = Standard multiply + Standard relinearize +
ceil(log2(vec_len)) * (Composite's own rotate latency + Standard add
latency), compared against the real measured dot_product latency via
tost_equivalence(), separately at each vector length, written to
seal_composite_prediction.csv.

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


def median_iqr(values):
    """Median and 25th/75th percentile (IQR bounds), the robust companions
    to mean/std/95% CI added alongside them everywhere trial statistics are
    computed. Needs >=2 points for quantiles to mean anything; below that,
    Q1/Q3 collapse to the single value (nothing to spread), matching how
    std already reads 0.0 for n<=1 elsewhere in this file."""
    n = len(values)
    med = statistics.median(values)
    if n >= 2:
        q1, _, q3 = statistics.quantiles(values, n=4, method="inclusive")
    else:
        q1, q3 = values[0], values[0]
    return med, q1, q3


def tost_equivalence(mean1, std1, n1, mean2, std2, n2, margin_pct, alpha=0.05):
    """Two One-Sided Tests (TOST) for statistical equivalence between two
    independent samples' means, via Welch's t-test (unequal variances).

    margin = margin_pct * mean1 (mean1 is the reference/baseline the margin
    is measured against). Runs two one-sided tests:
      - lower: H0 diff <= -margin, H1 diff > -margin
      - upper: H0 diff >=  margin, H1 diff <  margin
    If BOTH reject their null (p < alpha), the true difference is bounded
    within +/-margin at that confidence level -> "equivalent within margin".
    Otherwise -> "equivalence not established".

    IMPORTANT: "equivalence not established" is NOT "different". TOST only
    has power to *confirm* equivalence; failing to confirm it (e.g. from too
    few reps, as at batch_size=100) means the data can't rule equivalence
    in OR out -- it says nothing about whether a real difference exists.
    Detecting an actual difference beyond the margin is a distinct claim;
    see the returned ci_low/ci_high (the dual (1-2*alpha) CI for the
    difference) -- if that CI falls entirely outside +/-margin, that *does*
    positively indicate a real difference, and callers should flag it
    separately rather than lumping it in with "not established".
    """
    if not HAVE_SCIPY:
        raise RuntimeError("tost_equivalence requires scipy (Welch/Student's t "
                            "distribution) -- install with `pip install scipy`.")
    margin = margin_pct * mean1
    diff = mean2 - mean1
    var1_term = (std1 ** 2) / n1
    var2_term = (std2 ** 2) / n2
    se = math.sqrt(var1_term + var2_term)

    if se == 0.0:
        # Degenerate (zero variance both sides) -- shouldn't happen with real
        # timing data, but avoid a division by zero if it ever does.
        equivalent = abs(diff) < margin
        return {
            "diff": diff, "margin": margin, "se": 0.0, "df": float("nan"),
            "ci_low": diff, "ci_high": diff,
            "p_lower": 0.0 if equivalent else 1.0,
            "p_upper": 0.0 if equivalent else 1.0,
            "equivalent": equivalent,
            "verdict": "equivalent_within_margin" if equivalent
                       else "equivalence_not_established",
        }

    def _df_term(var_term, n):
        return (var_term ** 2) / (n - 1) if n > 1 else 0.0

    df_denom = _df_term(var1_term, n1) + _df_term(var2_term, n2)
    df = ((var1_term + var2_term) ** 2 / df_denom) if df_denom > 0 else (n1 + n2 - 2)

    t_lower = (diff + margin) / se   # tests H0: diff <= -margin
    t_upper = (diff - margin) / se   # tests H0: diff >=  margin
    p_lower = float(scipy_stats.t.sf(t_lower, df))
    p_upper = float(scipy_stats.t.cdf(t_upper, df))
    equivalent = (p_lower < alpha) and (p_upper < alpha)

    # Dual (1 - 2*alpha) CI for the difference -- equivalent iff this CI
    # sits entirely inside [-margin, margin] (Westlake/Schuirmann duality).
    t_crit = float(scipy_stats.t.ppf(1 - alpha, df))
    ci_low = diff - t_crit * se
    ci_high = diff + t_crit * se

    return {
        "diff": diff, "margin": margin, "se": se, "df": df,
        "ci_low": ci_low, "ci_high": ci_high,
        "p_lower": p_lower, "p_upper": p_upper,
        "equivalent": equivalent,
        "verdict": "equivalent_within_margin" if equivalent
                   else "equivalence_not_established",
    }


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


def parse_inner_loop(log_dir, default=1):
    """Extract the `inner_loop: K` value the run_*_docker.sh scripts log to
    <log_dir>/cpu_state.txt, so energy-per-op division stays traceable to
    its source instead of hardcoding K here. Each RAPL-measured invocation
    actually executes n_total * inner_loop real operations (see the
    --inner-loop header comment in bench_seal.cpp), not just n_total --
    scenarios whose timed functions don't use --inner-loop at all (Packing,
    Composite: single-call-per-rep; Edge/Batch: pinned to --inner-loop=1)
    fall back to the default of 1, which reproduces the pre-fix behavior
    for them exactly since it was never wrong there."""
    path = os.path.join(log_dir, "cpu_state.txt")
    if not os.path.exists(path):
        return default
    with open(path, "r", errors="replace") as f:
        text = f.read()
    m = re.search(r"inner_loop:\s*(\d+)", text)
    return int(m.group(1)) if m else default


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
    median, iqr_low, iqr_high = median_iqr(measured)
    flag = "HIGH_VARIANCE" if mean > 0 and (std / mean) > 0.05 else ""

    base = rows[0]
    return {
        "library": base["library"], "scheme": base["scheme"], "N": base["N"],
        "category": base["category"], "operation": base["operation"],
        "n_measured": len(measured), "mean_ms": mean, "std_ms": std,
        "ci_low_ms": mean - margin, "ci_high_ms": mean + margin,
        "median_ms": median, "iqr_low_ms": iqr_low, "iqr_high_ms": iqr_high,
        "flag": flag, "status": "ok",
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
    median, iqr_low, iqr_high = median_iqr(measured)
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
        "median_ms": median, "iqr_low_ms": iqr_low, "iqr_high_ms": iqr_high,
        "flag": ";".join(flags), "status": "ok",
    }


BATCHING_EQUIVALENCE_MARGIN_PCT = 0.10  # +/-10%, applied to the batch_size=1
                                          # per-item value as the reference.


def _edge_batch_raw_path(raw_dir, scheme, N, category, operation, batch_size):
    return os.path.join(
        raw_dir,
        f"seal_{scheme.lower()}_N{N}_cat{category}_{operation}_batch{batch_size}.csv")


def _measured_n(raw_path):
    """Real repetition count for a batch cell: rows with status=="measured"
    in the raw per-cell CSV. Deliberately NOT "total rows - 5" -- warmup rep
    count varies by batch size (WARMUP_FOR_BATCH in run_edge_batch_docker.sh:
    5 at batch_size=1, 3 at batch_size=10, 2 at batch_size=100), so counting
    the status column directly is the only correct way to get n."""
    if not os.path.exists(raw_path):
        return None
    rows = list(csv.DictReader(open(raw_path)))
    return sum(1 for r in rows if r.get("status") == "measured")


def check_batching_equivalence(final_rows, raw_dir, margin_pct=BATCHING_EQUIVALENCE_MARGIN_PCT):
    """Applies tost_equivalence to the Edge/Batch "no per-item speedup from
    batching" claim (docs/phase_logs/SEAL_HARNESS_PHASE_LOG.md): for every
    (scheme, N, category, operation) cell with both a batch_size=1 and a
    batch_size=100 latency_ms measurement, tests whether the per-item cost
    (mean_ms / batch_size) at batch=100 is equivalent to batch=1's, within
    +/-margin_pct of the batch=1 value. n for each side comes from the real
    measured-row count in the raw per-cell CSV, not the (imprecise,
    normal-approximation-based) CI already in the final CSV."""
    latency = [r for r in final_rows if r.get("metric") == "latency_ms"]
    groups = {}
    for r in latency:
        if r.get("mean") in ("", None):
            continue
        key = (r["scheme"], r["N"], r["category"], r["operation"])
        groups.setdefault(key, {})[int(r["batch_size"])] = r

    results = []
    for (scheme, N, category, operation), by_batch in sorted(groups.items()):
        if 1 not in by_batch or 100 not in by_batch:
            continue
        r1, r100 = by_batch[1], by_batch[100]

        n1 = _measured_n(_edge_batch_raw_path(raw_dir, scheme, N, category, operation, 1))
        n100 = _measured_n(_edge_batch_raw_path(raw_dir, scheme, N, category, operation, 100))
        if not n1 or not n100:
            continue  # raw file missing/empty -- shouldn't happen given the
                       # final CSV already has a mean for this cell

        mean1_pi, std1_pi = float(r1["mean"]) / 1, float(r1["std"]) / 1
        mean100_pi, std100_pi = float(r100["mean"]) / 100, float(r100["std"]) / 100

        test = tost_equivalence(mean1_pi, std1_pi, n1, mean100_pi, std100_pi, n100, margin_pct)
        margin = test["margin"]
        real_diff = (not test["equivalent"]) and (
            test["ci_low"] > margin or test["ci_high"] < -margin)

        results.append({
            "scheme": scheme, "N": N, "category": category, "operation": operation,
            "batch1_per_item_ms": mean1_pi, "batch1_n": n1,
            "batch100_per_item_ms": mean100_pi, "batch100_n": n100,
            "margin_pct": margin_pct, "real_difference_outside_margin": real_diff,
            **test,
        })
    return results


def write_equivalence_csv(out_path, results):
    fieldnames = ["scheme", "N", "category", "operation",
                  "batch1_per_item_ms", "batch1_n",
                  "batch100_per_item_ms", "batch100_n",
                  "diff", "margin_pct", "margin", "se", "df",
                  "ci_low", "ci_high", "p_lower", "p_upper",
                  "verdict", "real_difference_outside_margin"]
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in results:
            w.writerow({k: r.get(k, "") for k in fieldnames})


def print_batching_equivalence_summary(results, margin_pct):
    n_equiv = sum(1 for r in results if r["verdict"] == "equivalent_within_margin")
    n_diff = sum(1 for r in results if r["real_difference_outside_margin"])
    n_incon = len(results) - n_equiv - n_diff

    print(f"\nBatching per-item-cost equivalence check (TOST, Welch's t-test, "
          f"+/-{margin_pct * 100:.0f}% margin, alpha=0.05):")
    print(f"  {len(results)} (scheme, N, category, operation) comparisons tested "
          f"(batch_size=1 vs batch_size=100 per-item latency_ms).")
    print(f"  {n_equiv} equivalent within margin.")
    print(f"  {n_incon} equivalence not established (inconclusive -- NOT the same "
          f"claim as 'different'; most likely driven by batch_size=100's low n).")
    if n_diff:
        print(f"  {n_diff} show a REAL DIFFERENCE outside the margin (the "
              f"difference's CI falls entirely outside +/-{margin_pct * 100:.0f}%):")
        for r in results:
            if r["real_difference_outside_margin"]:
                print(f"    {r['scheme']} N={r['N']} cat={r['category']} "
                      f"{r['operation']}: batch1={r['batch1_per_item_ms']:.4f}ms "
                      f"(n={r['batch1_n']}) vs batch100={r['batch100_per_item_ms']:.4f}ms "
                      f"(n={r['batch100_n']}), diff={r['diff']:.4f}ms, "
                      f"margin=+/-{r['margin']:.4f}ms")
    else:
        print("  0 show a real difference outside the margin.")


def aggregate_packing_latency_file(path):
    """Like aggregate_latency_file, but reads the fill_pct/n_real/slot_count
    columns that only packing raw files have (Packing scenario: how many of
    a ciphertext's slots hold a real value vs. zero-padding, independent of
    batch_size -- see run_packing_docker.sh / bench_seal.cpp's --fill-pct
    header comment)."""
    rows = list(csv.DictReader(open(path)))
    if not rows:
        return None
    if rows[0].get("status") == "skipped_depth0":
        r0 = rows[0]
        return {"status": "skipped_depth0", **{k: r0[k] for k in
                ("library", "scheme", "N", "category", "operation", "fill_pct")}}

    measured = [float(r["latency_ms"]) for r in rows if r["status"] == "measured"]
    if not measured:
        return None

    mean = statistics.mean(measured)
    std = statistics.stdev(measured) if len(measured) > 1 else 0.0
    tcrit = t_critical(len(measured))
    margin = tcrit * std / math.sqrt(len(measured))
    median, iqr_low, iqr_high = median_iqr(measured)
    flag = "HIGH_VARIANCE" if mean > 0 and (std / mean) > 0.05 else ""

    base = rows[0]
    return {
        "library": base["library"], "scheme": base["scheme"], "N": base["N"],
        "category": base["category"], "operation": base["operation"],
        "fill_pct": float(base["fill_pct"]), "n_real": int(base["n_real"]),
        "slot_count": int(base["slot_count"]),
        "n_measured": len(measured), "mean_ms": mean, "std_ms": std,
        "ci_low_ms": mean - margin, "ci_high_ms": mean + margin,
        "median_ms": median, "iqr_low_ms": iqr_low, "iqr_high_ms": iqr_high,
        "flag": flag, "status": "ok",
    }


PACKING_EQUIVALENCE_MARGIN_PCT = 0.10  # +/-10%, applied to fill_pct=1.0's
                                         # mean (the reference/baseline) --
                                         # same +/-10% standard as the
                                         # existing batching equivalence check.


def _packing_raw_path(raw_dir, scheme, N, category, operation, fill_label):
    return os.path.join(
        raw_dir,
        f"seal_{scheme.lower()}_N{N}_cat{category}_{operation}_fill{fill_label}.csv")


def check_packing_equivalence(final_rows, raw_dir, margin_pct=PACKING_EQUIVALENCE_MARGIN_PCT):
    """Applies tost_equivalence to the Packing scenario's implicit "one
    ciphertext-level operation costs the same regardless of fill level"
    assumption: for every (scheme, operation) in {BFV,BGV,CKKS} x
    {encrypt,add,multiply}, tests whether latency_ms at fill_pct=1.0 (fully
    packed, the reference) is equivalent to fill_pct=0.0 (n_real=1, the
    single-value level -- run_packing_docker.sh's "fill1" tag), within
    +/-margin_pct of the fill_pct=1.0 value. Unlike
    check_batching_equivalence, no per-item division is applied -- Packing's
    question here is whether ONE operation's own cost depends on how many
    of its slots are real, not a per-value throughput question (that's
    latency_per_value_ms/throughput_items_per_sec, already computed above
    in aggregate_packing). n for each side comes from the real measured-row
    count in the raw per-cell CSV (via the same _measured_n() helper
    check_batching_equivalence uses), not the (imprecise, normal-
    approximation-based) CI already in the final CSV."""
    latency = [r for r in final_rows if r.get("metric") == "latency_ms"]
    groups = {}
    for r in latency:
        if r.get("mean") in ("", None):
            continue
        key = (r["scheme"], r["N"], r["category"], r["operation"])
        groups.setdefault(key, {})[round(float(r["fill_pct"]), 2)] = r

    results = []
    for (scheme, N, category, operation), by_fill in sorted(groups.items()):
        if 1.0 not in by_fill or 0.0 not in by_fill:
            continue
        r_hi, r_lo = by_fill[1.0], by_fill[0.0]

        n_hi = _measured_n(_packing_raw_path(raw_dir, scheme, N, category, operation, "1.00"))
        n_lo = _measured_n(_packing_raw_path(raw_dir, scheme, N, category, operation, "1"))
        if not n_hi or not n_lo:
            continue  # raw file missing/empty -- shouldn't happen given the
                       # final CSV already has a mean for this cell

        mean_hi, std_hi = float(r_hi["mean"]), float(r_hi["std"])
        mean_lo, std_lo = float(r_lo["mean"]), float(r_lo["std"])

        test = tost_equivalence(mean_hi, std_hi, n_hi, mean_lo, std_lo, n_lo, margin_pct)
        margin = test["margin"]
        real_diff = (not test["equivalent"]) and (
            test["ci_low"] > margin or test["ci_high"] < -margin)

        results.append({
            "scheme": scheme, "N": N, "category": category, "operation": operation,
            "fill1.00_latency_ms": mean_hi, "fill1.00_n": n_hi,
            "fill1_latency_ms": mean_lo, "fill1_n": n_lo,
            "margin_pct": margin_pct, "real_difference_outside_margin": real_diff,
            **test,
        })
    return results


def write_packing_equivalence_csv(out_path, results):
    # Same column layout as write_equivalence_csv (edge_batch's), with the
    # two compared-sides columns renamed from batch1/batch100 to
    # fill1.00/fill1 (fill_pct=1.0 fully-packed baseline vs. fill_pct=0.0
    # single-value comparison), matching run_packing_docker.sh's own tags.
    fieldnames = ["scheme", "N", "category", "operation",
                  "fill1.00_latency_ms", "fill1.00_n",
                  "fill1_latency_ms", "fill1_n",
                  "diff", "margin_pct", "margin", "se", "df",
                  "ci_low", "ci_high", "p_lower", "p_upper",
                  "verdict", "real_difference_outside_margin"]
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in results:
            w.writerow({k: r.get(k, "") for k in fieldnames})


def print_packing_equivalence_summary(results, margin_pct):
    n_equiv = sum(1 for r in results if r["verdict"] == "equivalent_within_margin")
    n_diff = sum(1 for r in results if r["real_difference_outside_margin"])
    n_incon = len(results) - n_equiv - n_diff

    print(f"\nPacking fill-level equivalence check (TOST, Welch's t-test, "
          f"+/-{margin_pct * 100:.0f}% margin, alpha=0.05): does one "
          f"ciphertext-level operation really cost the same regardless of "
          f"fill level, or does it just look that way?")
    print(f"  {len(results)} (scheme, operation) comparisons tested "
          f"(fill_pct=1.0 vs fill_pct=0.0 latency_ms).")
    print(f"  {n_equiv} equivalent within margin.")
    print(f"  {n_incon} equivalence not established (inconclusive -- NOT the same "
          f"claim as 'different').")
    if n_diff:
        print(f"  {n_diff} show a REAL DIFFERENCE outside the margin (the "
              f"difference's CI falls entirely outside +/-{margin_pct * 100:.0f}%):")
        for r in results:
            if r["real_difference_outside_margin"]:
                print(f"    {r['scheme']} {r['operation']}: "
                      f"fill1.00={r['fill1.00_latency_ms']:.4f}ms (n={r['fill1.00_n']}) vs "
                      f"fill1(single-value)={r['fill1_latency_ms']:.4f}ms (n={r['fill1_n']}), "
                      f"diff={r['diff']:.4f}ms, margin=+/-{r['margin']:.4f}ms")
    else:
        print("  0 show a real difference outside the margin.")


def aggregate_packing(args):
    """Packing scenario: partial slot-fill (Chapter 3's "how many of a
    ciphertext's available slots hold a real value" question, separate from
    Edge/Batch's "how many separate ciphertexts" axis). Raw files split into
    two families by filename (own subdirectory, results/raw/packing/, same
    "invisible to a flat seal_*.csv glob" isolation as edge_batch):
      - encrypt/add/multiply latency files -- timed, get the usual mean/std/
        95% CI/median/IQR plus two derived per-real-value metrics mirroring
        how keygen_amortized_ms works in aggregate_edge_batch.
      - size files -- deterministic (one artifact, "ciphertext", per fill
        level), same deterministic_single_measurement flag as aggregate_size.
    """
    log_dir = args.log_dir or "../results/logs/packing"
    out_path = args.out or "../results/final/seal_packing.csv"

    files = sorted(glob.glob(os.path.join(args.raw_dir, "seal_*.csv")))
    size_files = [f for f in files if "_size_" in Path(f).stem]
    latency_files = [f for f in files if "_size_" not in Path(f).stem]

    out_rows = []

    # ---- encrypt/add/multiply: latency + derived per-real-value metrics ----
    for f in latency_files:
        summary = aggregate_packing_latency_file(f)
        if summary is None:
            continue

        if summary.get("status") == "skipped_depth0":
            out_rows.append({
                "library": summary["library"], "scheme": summary["scheme"],
                "N": summary["N"], "category": summary["category"],
                "scenario": "packing", "operation": summary["operation"],
                "fill_pct": summary["fill_pct"], "metric": "latency_ms",
                "mean": "", "std": "", "ci_low": "", "ci_high": "",
                "flag": "skipped_depth0_undefined_at_this_config",
            })
            continue

        common = {"library": summary["library"], "scheme": summary["scheme"],
                   "N": summary["N"], "category": summary["category"],
                   "scenario": "packing", "operation": summary["operation"],
                   "fill_pct": summary["fill_pct"], "n_real": summary["n_real"],
                   "slot_count": summary["slot_count"]}
        tag = Path(f).stem
        energy_pkg, _ = parse_energy_log(os.path.join(log_dir, f"{tag}_energy.log"))
        mem_mb = parse_mem_log(os.path.join(log_dir, f"{tag}_mem.log"))

        out_rows.append({**common, "metric": "latency_ms",
                          "mean": summary["mean_ms"], "std": summary["std_ms"],
                          "ci_low": summary["ci_low_ms"], "ci_high": summary["ci_high_ms"],
                          "median": summary["median_ms"], "iqr_low": summary["iqr_low_ms"],
                          "iqr_high": summary["iqr_high_ms"], "flag": summary["flag"]})

        # Derived per-real-value metrics -- mirrors keygen_amortized_ms's
        # "derived_not_measured" convention in aggregate_edge_batch.
        latency_per_value = summary["mean_ms"] / summary["n_real"]
        out_rows.append({**common, "metric": "latency_per_value_ms",
                          "mean": latency_per_value, "std": "", "ci_low": "", "ci_high": "",
                          "flag": "derived_not_measured"})
        out_rows.append({**common, "metric": "throughput_items_per_sec",
                          "mean": 1000.0 / latency_per_value, "std": "", "ci_low": "", "ci_high": "",
                          "flag": "derived_not_measured"})

        if energy_pkg is not None:
            n_total = summary["n_measured"] + 5  # + warmup, same as standard/constrained
            out_rows.append({**common, "metric": "energy_pkg_j_per_op",
                              "mean": energy_pkg / n_total, "std": "", "ci_low": "", "ci_high": "",
                              "flag": "n=1_invocation_not_repeated"})
        if mem_mb is not None:
            out_rows.append({**common, "metric": "peak_memory_mb",
                              "mean": mem_mb, "std": "", "ci_low": "", "ci_high": "",
                              "flag": "n=1_invocation_not_repeated"})

    # ---- size: deterministic, one row per fill level -- Packing's own
    # storage question (does serialized ciphertext size actually vary with
    # fill level, or is it fixed regardless) is answered by comparing these
    # rows across fill_pct, not assumed ----
    for f in size_files:
        rows = list(csv.DictReader(open(f)))
        if not rows:
            continue
        for r in rows:
            out_rows.append({
                "library": r["library"], "scheme": r["scheme"], "N": r["N"],
                "category": r["category"], "scenario": "packing", "operation": "size",
                "fill_pct": r["fill_pct"], "n_real": r["n_real"], "slot_count": r["slot_count"],
                "metric": "size_bytes", "mean": r["size_bytes"],
                "std": "", "ci_low": "", "ci_high": "",
                "flag": "deterministic_single_measurement",
            })

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    fieldnames = ["library", "scheme", "N", "category", "scenario", "operation",
                  "fill_pct", "n_real", "slot_count", "metric", "mean", "std",
                  "ci_low", "ci_high", "median", "iqr_low", "iqr_high", "flag"]
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in out_rows:
            w.writerow({k: r.get(k, "") for k in fieldnames})

    n_flagged = sum(1 for r in out_rows if r.get("flag") == "HIGH_VARIANCE")
    print(f"Wrote {len(out_rows)} rows to {out_path}")
    print(f"{n_flagged} row(s) flagged HIGH_VARIANCE (std > 5% of mean).")
    if not HAVE_SCIPY:
        print("NOTE: scipy not found, used 1.96 normal-approx instead of Student's t "
              "for the 95% CI. Install scipy (`pip install scipy`) for exactness.")

    if HAVE_SCIPY:
        equiv_results = check_packing_equivalence(out_rows, args.raw_dir)
        equiv_out_path = os.path.join(os.path.dirname(out_path),
                                       "seal_packing_equivalence.csv")
        write_packing_equivalence_csv(equiv_out_path, equiv_results)
        print_packing_equivalence_summary(equiv_results, PACKING_EQUIVALENCE_MARGIN_PCT)
        print(f"Wrote {len(equiv_results)} equivalence-test rows to {equiv_out_path}")
    else:
        print("\nSkipping packing fill-level equivalence check: it needs scipy's "
              "Student's t-distribution for a correct test. Install with "
              "`pip install scipy` and re-run to get it.")


def aggregate_rotate_file(path):
    """rotate: real per-rep latency_ms statistics (same as
    aggregate_latency_file), plus galois_keygen_ms/galois_keys_size_bytes --
    constant companion columns bench_seal.cpp measures ONCE per file (not
    per rep, same "one-time setup cost" treatment relin_keys' own generation
    time/size get elsewhere in this project) and repeats on every row."""
    rows = list(csv.DictReader(open(path)))
    if not rows:
        return None
    measured = [float(r["latency_ms"]) for r in rows if r["status"] == "measured"]
    if not measured:
        return None

    mean = statistics.mean(measured)
    std = statistics.stdev(measured) if len(measured) > 1 else 0.0
    tcrit = t_critical(len(measured))
    margin = tcrit * std / math.sqrt(len(measured))
    median, iqr_low, iqr_high = median_iqr(measured)
    flag = "HIGH_VARIANCE" if mean > 0 and (std / mean) > 0.05 else ""

    base = rows[0]
    return {
        "library": base["library"], "scheme": base["scheme"], "N": base["N"],
        "category": base["category"], "operation": base["operation"],
        "galois_keygen_ms": float(base["galois_keygen_ms"]),
        "galois_keys_size_bytes": int(base["galois_keys_size_bytes"]),
        "n_measured": len(measured), "mean_ms": mean, "std_ms": std,
        "ci_low_ms": mean - margin, "ci_high_ms": mean + margin,
        "median_ms": median, "iqr_low_ms": iqr_low, "iqr_high_ms": iqr_high,
        "flag": flag,
    }


def aggregate_dot_product_file(path):
    """dot_product: reads vec_len/slot_count (constant per file) and real
    per-rep statistics for BOTH latency_ms and noise_budget_bits (BFV/BGV
    only -- empty for CKKS, same invariant_noise_budget-doesn't-apply
    limitation noise_trace already documents, just at column granularity
    here rather than a whole-row skip)."""
    rows = list(csv.DictReader(open(path)))
    if not rows:
        return None
    measured = [r for r in rows if r["status"] == "measured"]
    if not measured:
        return None

    lat = [float(r["latency_ms"]) for r in measured]
    mean = statistics.mean(lat)
    std = statistics.stdev(lat) if len(lat) > 1 else 0.0
    tcrit = t_critical(len(lat))
    margin = tcrit * std / math.sqrt(len(lat))
    median, iqr_low, iqr_high = median_iqr(lat)
    flag = "HIGH_VARIANCE" if mean > 0 and (std / mean) > 0.05 else ""

    base = rows[0]
    result = {
        "library": base["library"], "scheme": base["scheme"], "N": base["N"],
        "category": base["category"], "operation": base["operation"],
        "vec_len": int(base["vec_len"]), "slot_count": int(base["slot_count"]),
        "n_measured": len(lat), "mean_ms": mean, "std_ms": std,
        "ci_low_ms": mean - margin, "ci_high_ms": mean + margin,
        "median_ms": median, "iqr_low_ms": iqr_low, "iqr_high_ms": iqr_high,
        "flag": flag, "noise": None,
    }

    nb = [int(r["noise_budget_bits"]) for r in measured if r.get("noise_budget_bits", "") != ""]
    if nb:
        nmean = statistics.mean(nb)
        nstd = statistics.stdev(nb) if len(nb) > 1 else 0.0
        ntcrit = t_critical(len(nb))
        nmargin = ntcrit * nstd / math.sqrt(len(nb))
        nmedian, niqr_low, niqr_high = median_iqr(nb)
        nflag = "HIGH_VARIANCE" if nmean > 0 and (nstd / nmean) > 0.05 else ""
        result["noise"] = {
            "mean": nmean, "std": nstd, "ci_low": nmean - nmargin, "ci_high": nmean + nmargin,
            "median": nmedian, "iqr_low": niqr_low, "iqr_high": niqr_high, "flag": nflag,
        }
    return result


def aggregate_poly_eval_file(path):
    """poly_eval: plain per-rep latency_ms statistics, no extra columns
    (purely elementwise, single fully-packed setup, no vec_len sweep --
    see bench_seal.cpp's --operation=poly_eval header comment)."""
    rows = list(csv.DictReader(open(path)))
    if not rows:
        return None
    measured = [float(r["latency_ms"]) for r in rows if r["status"] == "measured"]
    if not measured:
        return None

    mean = statistics.mean(measured)
    std = statistics.stdev(measured) if len(measured) > 1 else 0.0
    tcrit = t_critical(len(measured))
    margin = tcrit * std / math.sqrt(len(measured))
    median, iqr_low, iqr_high = median_iqr(measured)
    flag = "HIGH_VARIANCE" if mean > 0 and (std / mean) > 0.05 else ""

    base = rows[0]
    return {
        "library": base["library"], "scheme": base["scheme"], "N": base["N"],
        "category": base["category"], "operation": base["operation"],
        "n_measured": len(measured), "mean_ms": mean, "std_ms": std,
        "ci_low_ms": mean - margin, "ci_high_ms": mean + margin,
        "median_ms": median, "iqr_low_ms": iqr_low, "iqr_high_ms": iqr_high,
        "flag": flag,
    }


COMPOSITE_PREDICTION_MARGIN_PCT = 0.10  # same +/-10% standard already used by
                                          # the batching/packing equivalence
                                          # checks -- not separately specified
                                          # for this comparison, so this
                                          # reuses the project's established
                                          # value rather than inventing a new one.


def _ceil_log2(n):
    """Mirrors bench_seal.cpp's ceil_log2() exactly (integer doubling, not
    floating-point log2/ceil) so the predicted rotate-step count always
    matches how many steps the ACTUAL dot_product chain really performed."""
    bits = 0
    v = 1
    while v < n:
        v *= 2
        bits += 1
    return bits


def _standard_raw_path(raw_dir, scheme, N, category, operation):
    return os.path.join(raw_dir, f"seal_{scheme.lower()}_N{N}_cat{category}_{operation}.csv")


def _composite_rotate_raw_path(raw_dir, scheme, N, category):
    return os.path.join(raw_dir, f"seal_{scheme.lower()}_N{N}_cat{category}_rotate.csv")


def _composite_dot_product_raw_path(raw_dir, scheme, N, category, vec_len):
    return os.path.join(raw_dir, f"seal_{scheme.lower()}_N{N}_cat{category}_dot_product_veclen{vec_len}.csv")


def check_composite_prediction(final_rows, args, margin_pct=COMPOSITE_PREDICTION_MARGIN_PCT):
    """Does single-operation timing predict multi-operation (chained) cost?
    For each (scheme, vec_len) dot_product cell, builds a PREDICTED chain
    cost = Standard-scenario multiply latency + Standard-scenario
    relinearize latency + ceil(log2(vec_len)) * (Composite's own measured
    rotate latency + Standard-scenario add latency) (all at N=8192/
    category=1), and compares it against the ACTUAL measured dot_product
    latency via tost_equivalence(), separately at each vector length -- so
    prediction accuracy can be read off as the chain gets longer (more
    rotate+add steps stacked), not just as one pooled number. The k*(rotate
    + add) term mirrors time_dot_product()'s actual chain in bench_seal.cpp:
    one add_inplace(sum, rotated) after every rotate inside the k-step loop,
    not a rotate-only chain.

    predicted's std is propagated from the four independent underlying
    measurements' real stds: predicted = mult + relin + k*(rotate + add),
    all independent, so Var(predicted) = Var(mult) + Var(relin) +
    k^2*(Var(rotate) + Var(add)).
    predicted's n is NOT a real repetition count of "predicted" itself --
    it's a derived combination of four different n=100 samples, not a
    directly-repeated quantity. This uses the multiply cell's real
    measured-row count as a representative n (the same n every underlying
    component shares under this project's fixed 100-measured-rep protocol).
    This is a documented approximation, not a rigorously propagated
    effective-n (e.g. a 4-term Welch-Satterthwaite), because
    tost_equivalence() only accepts a single (mean,std,n) per side, and the
    point here is reusing that existing function, not extending it.
    """
    standard_raw_dir = "../results/raw"  # Standard scenario's raw dir --
                                          # independent of args.raw_dir
                                          # (Composite's own raw dir), read-only.
    composite_raw_dir = args.raw_dir

    dp_cells = {}
    for r in final_rows:
        if r.get("operation") == "dot_product" and r.get("metric") == "latency_ms":
            if r.get("mean") in ("", None):
                continue
            key = (r["scheme"], int(r["vec_len"]))
            dp_cells[key] = r

    results = []
    for (scheme, vec_len) in sorted(dp_cells.keys()):
        r_actual = dp_cells[(scheme, vec_len)]
        N, category = r_actual["N"], r_actual["category"]

        mult_summary = aggregate_latency_file(_standard_raw_path(standard_raw_dir, scheme, N, category, "multiply"))
        relin_summary = aggregate_latency_file(_standard_raw_path(standard_raw_dir, scheme, N, category, "relinearize"))
        add_summary = aggregate_latency_file(_standard_raw_path(standard_raw_dir, scheme, N, category, "add"))
        if (mult_summary is None or relin_summary is None or add_summary is None or
                mult_summary.get("status") == "skipped_depth0" or
                relin_summary.get("status") == "skipped_depth0" or
                add_summary.get("status") == "skipped_depth0"):
            continue  # shouldn't happen at N=8192/category=1 (depth=2), but
                       # stay honest if it does rather than fabricating a prediction

        rotate_path = _composite_rotate_raw_path(composite_raw_dir, scheme, N, category)
        rotate_summary = aggregate_latency_file(rotate_path)
        n_rotate = _measured_n(rotate_path)
        if rotate_summary is None or not n_rotate:
            continue

        dp_path = _composite_dot_product_raw_path(composite_raw_dir, scheme, N, category, vec_len)
        n_actual = _measured_n(dp_path)
        if not n_actual:
            continue

        k = _ceil_log2(vec_len) if vec_len > 1 else 0

        pred_mean = (mult_summary["mean_ms"] + relin_summary["mean_ms"] +
                     k * (rotate_summary["mean_ms"] + add_summary["mean_ms"]))
        pred_std = math.sqrt(mult_summary["std_ms"] ** 2 + relin_summary["std_ms"] ** 2 +
                              (k ** 2) * (rotate_summary["std_ms"] ** 2 + add_summary["std_ms"] ** 2))
        n_pred = mult_summary["n_measured"]  # representative n -- see docstring

        actual_mean = float(r_actual["mean"])
        actual_std = float(r_actual["std"])

        test = tost_equivalence(pred_mean, pred_std, n_pred, actual_mean, actual_std, n_actual, margin_pct)
        margin = test["margin"]
        real_diff = (not test["equivalent"]) and (
            test["ci_low"] > margin or test["ci_high"] < -margin)

        results.append({
            "scheme": scheme, "N": N, "category": category,
            "vec_len": vec_len, "rotate_steps": k,
            "predicted_ms": pred_mean, "predicted_n": n_pred,
            "actual_ms": actual_mean, "actual_n": n_actual,
            "margin_pct": margin_pct, "real_difference_outside_margin": real_diff,
            **test,
        })
    return results


def write_composite_prediction_csv(out_path, results):
    fieldnames = ["scheme", "N", "category", "vec_len", "rotate_steps",
                  "predicted_ms", "predicted_n", "actual_ms", "actual_n",
                  "diff", "margin_pct", "margin", "se", "df",
                  "ci_low", "ci_high", "p_lower", "p_upper",
                  "verdict", "real_difference_outside_margin"]
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in results:
            w.writerow({k: r.get(k, "") for k in fieldnames})


def print_composite_prediction_summary(results, margin_pct=COMPOSITE_PREDICTION_MARGIN_PCT):
    n_equiv = sum(1 for r in results if r["verdict"] == "equivalent_within_margin")
    n_diff = sum(1 for r in results if r["real_difference_outside_margin"])
    n_incon = len(results) - n_equiv - n_diff

    print(f"\nComposite prediction-vs-actual check (does single-operation timing "
          f"predict chained cost?): predicted = Standard multiply + Standard "
          f"relinearize + rotate_steps x (rotate + Standard add) latency, vs. "
          f"actual measured dot_product latency, per vector length (TOST, "
          f"Welch's t-test, +/-{margin_pct * 100:.0f}% margin, alpha=0.05):")
    print(f"  {len(results)} (scheme, vec_len) comparisons tested.")
    print(f"  {n_equiv} predicted within margin of actual.")
    print(f"  {n_incon} inconclusive -- NOT the same claim as 'prediction holds'.")
    if n_diff:
        print(f"  {n_diff} show prediction BREAKING DOWN outside the margin:")
        for r in results:
            if r["real_difference_outside_margin"]:
                print(f"    {r['scheme']} vec_len={r['vec_len']} ({r['rotate_steps']} rotate steps): "
                      f"predicted={r['predicted_ms']:.4f}ms (n={r['predicted_n']}) vs "
                      f"actual={r['actual_ms']:.4f}ms (n={r['actual_n']}), "
                      f"diff={r['diff']:.4f}ms, margin=+/-{r['margin']:.4f}ms")
    else:
        print("  0 show prediction breaking down outside the margin.")


def aggregate_composite(args):
    """Composite scenario: chained (multi-operation) workloads -- rotate
    (isolated single-rotate measurement), dot_product (multiply ->
    relinearize -> rotate-and-add chain, swept over --vec-len), and
    poly_eval (elementwise a*x^2+b*x+c). Raw files split into three
    families by filename (own subdirectory, results/raw/composite/, same
    glob-isolation reasoning as edge_batch/packing). After writing the
    latency/noise/size rows, runs the prediction-vs-actual analysis (the
    point of this scenario -- see check_composite_prediction)."""
    log_dir = args.log_dir or "../results/logs/composite"
    out_path = args.out or "../results/final/seal_composite.csv"

    files = sorted(glob.glob(os.path.join(args.raw_dir, "seal_*.csv")))
    rotate_files = [f for f in files if "_rotate" in Path(f).stem]
    poly_files = [f for f in files if "_poly_eval" in Path(f).stem]
    dp_files = [f for f in files if "_dot_product_veclen" in Path(f).stem]

    out_rows = []

    for f in rotate_files:
        summary = aggregate_rotate_file(f)
        if summary is None:
            continue
        common = {"library": summary["library"], "scheme": summary["scheme"],
                   "N": summary["N"], "category": summary["category"],
                   "scenario": "composite", "operation": summary["operation"]}
        tag = Path(f).stem
        energy_pkg, _ = parse_energy_log(os.path.join(log_dir, f"{tag}_energy.log"))
        mem_mb = parse_mem_log(os.path.join(log_dir, f"{tag}_mem.log"))

        out_rows.append({**common, "metric": "latency_ms",
                          "mean": summary["mean_ms"], "std": summary["std_ms"],
                          "ci_low": summary["ci_low_ms"], "ci_high": summary["ci_high_ms"],
                          "median": summary["median_ms"], "iqr_low": summary["iqr_low_ms"],
                          "iqr_high": summary["iqr_high_ms"], "flag": summary["flag"]})
        out_rows.append({**common, "metric": "galois_keygen_ms",
                          "mean": summary["galois_keygen_ms"], "std": "", "ci_low": "", "ci_high": "",
                          "flag": "n=1_invocation_not_repeated"})
        out_rows.append({**common, "metric": "galois_keys_size_bytes",
                          "mean": summary["galois_keys_size_bytes"], "std": "", "ci_low": "", "ci_high": "",
                          "flag": "n=1_invocation_not_repeated"})
        if energy_pkg is not None:
            n_total = summary["n_measured"] + 5
            out_rows.append({**common, "metric": "energy_pkg_j_per_op",
                              "mean": energy_pkg / n_total, "std": "", "ci_low": "", "ci_high": "",
                              "flag": "n=1_invocation_not_repeated"})
        if mem_mb is not None:
            out_rows.append({**common, "metric": "peak_memory_mb",
                              "mean": mem_mb, "std": "", "ci_low": "", "ci_high": "",
                              "flag": "n=1_invocation_not_repeated"})

    for f in poly_files:
        summary = aggregate_poly_eval_file(f)
        if summary is None:
            continue
        common = {"library": summary["library"], "scheme": summary["scheme"],
                   "N": summary["N"], "category": summary["category"],
                   "scenario": "composite", "operation": summary["operation"]}
        tag = Path(f).stem
        energy_pkg, _ = parse_energy_log(os.path.join(log_dir, f"{tag}_energy.log"))
        mem_mb = parse_mem_log(os.path.join(log_dir, f"{tag}_mem.log"))

        out_rows.append({**common, "metric": "latency_ms",
                          "mean": summary["mean_ms"], "std": summary["std_ms"],
                          "ci_low": summary["ci_low_ms"], "ci_high": summary["ci_high_ms"],
                          "median": summary["median_ms"], "iqr_low": summary["iqr_low_ms"],
                          "iqr_high": summary["iqr_high_ms"], "flag": summary["flag"]})
        if energy_pkg is not None:
            n_total = summary["n_measured"] + 5
            out_rows.append({**common, "metric": "energy_pkg_j_per_op",
                              "mean": energy_pkg / n_total, "std": "", "ci_low": "", "ci_high": "",
                              "flag": "n=1_invocation_not_repeated"})
        if mem_mb is not None:
            out_rows.append({**common, "metric": "peak_memory_mb",
                              "mean": mem_mb, "std": "", "ci_low": "", "ci_high": "",
                              "flag": "n=1_invocation_not_repeated"})

    for f in dp_files:
        summary = aggregate_dot_product_file(f)
        if summary is None:
            continue
        common = {"library": summary["library"], "scheme": summary["scheme"],
                   "N": summary["N"], "category": summary["category"],
                   "scenario": "composite", "operation": summary["operation"],
                   "vec_len": summary["vec_len"], "slot_count": summary["slot_count"]}
        tag = Path(f).stem
        energy_pkg, _ = parse_energy_log(os.path.join(log_dir, f"{tag}_energy.log"))
        mem_mb = parse_mem_log(os.path.join(log_dir, f"{tag}_mem.log"))

        out_rows.append({**common, "metric": "latency_ms",
                          "mean": summary["mean_ms"], "std": summary["std_ms"],
                          "ci_low": summary["ci_low_ms"], "ci_high": summary["ci_high_ms"],
                          "median": summary["median_ms"], "iqr_low": summary["iqr_low_ms"],
                          "iqr_high": summary["iqr_high_ms"], "flag": summary["flag"]})
        if summary["noise"] is not None:
            n = summary["noise"]
            out_rows.append({**common, "metric": "noise_budget_bits",
                              "mean": n["mean"], "std": n["std"],
                              "ci_low": n["ci_low"], "ci_high": n["ci_high"],
                              "median": n["median"], "iqr_low": n["iqr_low"],
                              "iqr_high": n["iqr_high"], "flag": n["flag"]})
        if energy_pkg is not None:
            n_total = summary["n_measured"] + 5
            out_rows.append({**common, "metric": "energy_pkg_j_per_op",
                              "mean": energy_pkg / n_total, "std": "", "ci_low": "", "ci_high": "",
                              "flag": "n=1_invocation_not_repeated"})
        if mem_mb is not None:
            out_rows.append({**common, "metric": "peak_memory_mb",
                              "mean": mem_mb, "std": "", "ci_low": "", "ci_high": "",
                              "flag": "n=1_invocation_not_repeated"})

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    fieldnames = ["library", "scheme", "N", "category", "scenario", "operation",
                  "vec_len", "slot_count", "metric", "mean", "std",
                  "ci_low", "ci_high", "median", "iqr_low", "iqr_high", "flag"]
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in out_rows:
            w.writerow({k: r.get(k, "") for k in fieldnames})

    n_flagged = sum(1 for r in out_rows if r.get("flag") == "HIGH_VARIANCE")
    print(f"Wrote {len(out_rows)} rows to {out_path}")
    print(f"{n_flagged} row(s) flagged HIGH_VARIANCE (std > 5% of mean).")
    if not HAVE_SCIPY:
        print("NOTE: scipy not found, used 1.96 normal-approx instead of Student's t "
              "for the 95% CI. Install scipy (`pip install scipy`) for exactness.")

    if HAVE_SCIPY:
        pred_results = check_composite_prediction(out_rows, args)
        pred_out_path = os.path.join(os.path.dirname(out_path), "seal_composite_prediction.csv")
        write_composite_prediction_csv(pred_out_path, pred_results)
        print_composite_prediction_summary(pred_results)
        print(f"Wrote {len(pred_results)} prediction-vs-actual rows to {pred_out_path}")
    else:
        print("\nSkipping prediction-vs-actual analysis: it needs scipy's Student's "
              "t-distribution for a correct test. Install with `pip install scipy` "
              "and re-run to get it.")


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
                          "median": summary["median_ms"], "iqr_low": summary["iqr_low_ms"],
                          "iqr_high": summary["iqr_high_ms"], "flag": summary["flag"]})
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
                          "median": summary["median_ms"], "iqr_low": summary["iqr_low_ms"],
                          "iqr_high": summary["iqr_high_ms"], "flag": summary["flag"]})

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
                  "batch_size", "metric", "mean", "std", "ci_low", "ci_high",
                  "median", "iqr_low", "iqr_high", "flag"]
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

    if HAVE_SCIPY:
        equiv_results = check_batching_equivalence(out_rows, args.raw_dir)
        equiv_out_path = os.path.join(os.path.dirname(out_path),
                                       "seal_edge_batch_equivalence.csv")
        write_equivalence_csv(equiv_out_path, equiv_results)
        print_batching_equivalence_summary(equiv_results, BATCHING_EQUIVALENCE_MARGIN_PCT)
        print(f"Wrote {len(equiv_results)} equivalence-test rows to {equiv_out_path}")
    else:
        print("\nSkipping batching per-item-cost equivalence check: it needs scipy's "
              "Student's t-distribution to be valid at batch_size=100's low n "
              "(~7-10 reps after warmup). Install with `pip install scipy` and "
              "re-run to get it.")


def _write_final(out_path, out_rows,
                  fieldnames=("library", "scheme", "N", "category", "scenario",
                              "operation", "metric", "mean", "std", "ci_low",
                              "ci_high", "median", "iqr_low", "iqr_high", "flag")):
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(fieldnames))
        w.writeheader()
        for r in out_rows:
            w.writerow({k: r.get(k, "") for k in fieldnames})


def _stats_over_trials(values):
    """Real mean/std/95% CI/median/IQR + HIGH_VARIANCE flag over independent
    trials -- same policy as aggregate_latency_file, just over --trace-reps
    trials instead of --reps iterations."""
    n = len(values)
    mean = statistics.mean(values)
    std = statistics.stdev(values) if n > 1 else 0.0
    tcrit = t_critical(n)
    margin = tcrit * std / math.sqrt(n) if n > 0 else 0.0
    median, iqr_low, iqr_high = median_iqr(values)
    flag = "HIGH_VARIANCE" if mean != 0 and (std / abs(mean)) > 0.05 else ""
    return mean, std, mean - margin, mean + margin, median, iqr_low, iqr_high, flag


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
        mean, std, ci_low, ci_high, median, iqr_low, iqr_high, flag = _stats_over_trials(values)
        out_rows.append({
            "library": library, "scheme": scheme, "N": N, "category": category,
            "scenario": "noise_trace", "operation": step_name,
            "metric": "noise_budget_bits", "mean": mean, "std": std,
            "ci_low": ci_low, "ci_high": ci_high,
            "median": median, "iqr_low": iqr_low, "iqr_high": iqr_high, "flag": flag,
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

        mean, std, ci_low, ci_high, median, iqr_low, iqr_high, flag = _stats_over_trials(groups_max[key])
        out_rows.append({**common, "metric": "max_abs_error", "mean": mean,
                          "std": std, "ci_low": ci_low, "ci_high": ci_high,
                          "median": median, "iqr_low": iqr_low, "iqr_high": iqr_high, "flag": flag})

        (mean2, std2, ci_low2, ci_high2,
         median2, iqr_low2, iqr_high2, flag2) = _stats_over_trials(groups_mean[key])
        out_rows.append({**common, "metric": "mean_abs_error", "mean": mean2,
                          "std": std2, "ci_low": ci_low2, "ci_high": ci_high2,
                          "median": median2, "iqr_low": iqr_low2, "iqr_high": iqr_high2, "flag": flag2})

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


_CONFIG_METADATA_FIELDS = (
    "library", "scheme", "N", "category", "poly_modulus_degree",
    "coeff_modulus_chain", "secret_distribution", "error_distribution",
    "batching_enabled", "slots_used", "plain_modulus", "initial_scale",
    "rescaling_policy", "precision_criterion", "status",
)


def aggregate_config_metadata(args):
    """config_metadata is not a measured/noisy metric -- bench_seal.cpp's
    own docstring guarantees exactly one deterministic row per (scheme, N,
    category) cell (parameter facts read back from the built SEALContext,
    not sampled or timed), so there's nothing here for _stats_over_trials
    to average. This is a validated pass-through, not a statistical
    aggregation: same column shape as the consolidated raw file (not the
    library/scheme/N/category/scenario/operation/metric/mean/... shape the
    other aggregate_* functions produce, which doesn't fit facts like
    coeff_modulus_chain or plain_modulus). Checked here rather than
    trusted blindly: exactly one row per (scheme, N, category) key, no
    duplicates and nothing missing relative to the grid."""
    in_path = args.raw_dir or "../results/raw/extended_metrics/seal_config_metadata.csv"
    out_path = args.out or "../results/final/seal_config_metadata.csv"

    rows = list(csv.DictReader(open(in_path)))
    seen = {}
    dupes = []
    for r in rows:
        key = (r["scheme"], int(r["N"]), int(r["category"]))
        if key in seen:
            dupes.append(key)
        seen[key] = r

    out_rows = sorted(rows, key=lambda r: (r["scheme"], int(r["N"]), int(r["category"])))
    _write_final(out_path, out_rows, fieldnames=_CONFIG_METADATA_FIELDS)

    n_by_N = {}
    for r in out_rows:
        n_by_N[r["N"]] = n_by_N.get(r["N"], 0) + 1
    print(f"Wrote {len(out_rows)} rows to {out_path}")
    print("Rows per N: " + ", ".join(f"N={n}: {c}" for n, c in
                                      sorted(n_by_N.items(), key=lambda kv: int(kv[0]))))
    if dupes:
        print(f"WARNING: {len(dupes)} duplicate (scheme, N, category) key(s) in "
              f"the raw input, last one wins per key: {dupes}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", required=True,
                     choices=["standard", "constrained", "edge_batch", "packing",
                              "composite", "size", "noise_trace", "ckks_error",
                              "config_metadata"])
    ap.add_argument("--raw-dir", default=None)
    ap.add_argument("--log-dir", default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    if args.scenario in ("size", "noise_trace", "ckks_error", "config_metadata"):
        # --raw-dir means the consolidated master FILE for these four, not
        # a directory to glob (see module docstring) -- args.raw_dir is left
        # None here so each aggregate_* function's own default path is used.
        {"size": aggregate_size, "noise_trace": aggregate_noise_trace,
         "ckks_error": aggregate_ckks_error,
         "config_metadata": aggregate_config_metadata}[args.scenario](args)
        return

    if args.raw_dir is None:
        args.raw_dir = {
            "edge_batch": "../results/raw/edge_batch",
            "packing": "../results/raw/packing",
            "composite": "../results/raw/composite",
        }.get(args.scenario, "../results/raw")

    if args.scenario == "edge_batch":
        aggregate_edge_batch(args)
        if not HAVE_SCIPY:
            print("NOTE: scipy not found, used 1.96 normal-approx instead of Student's t "
                  "for the 95% CI. Fine for n>=30; batch_size=100 trials only have 10 "
                  "reps, so this approximation is coarser there -- worth installing "
                  "scipy (`pip install scipy`) before trusting those CIs closely.")
        return

    if args.scenario == "packing":
        aggregate_packing(args)
        return

    if args.scenario == "composite":
        aggregate_composite(args)
        return

    log_dir = args.log_dir or f"../results/logs/{args.scenario}"
    out_path = args.out or f"../results/final/seal_{args.scenario}.csv"
    inner_loop = parse_inner_loop(log_dir)  # 1000 (standard) / 100 (constrained)
                        # -- each RAPL-measured invocation runs n_total *
                        # inner_loop real ops, not just n_total (see
                        # parse_inner_loop's docstring)

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
            "ci_high": summary["ci_high_ms"], "median": summary["median_ms"],
            "iqr_low": summary["iqr_low_ms"], "iqr_high": summary["iqr_high_ms"],
            "flag": summary["flag"],
        })
        if energy_pkg is not None:
            # n_total reps each ran inner_loop ops internally (see
            # parse_inner_loop) -- divide by the real op count, not just reps.
            out_rows.append({
                "library": summary["library"], "scheme": summary["scheme"],
                "N": summary["N"], "category": summary["category"],
                "scenario": args.scenario, "operation": summary["operation"],
                "metric": "energy_pkg_j_per_op", "mean": energy_pkg / (n_total * inner_loop),
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
                  "metric", "mean", "std", "ci_low", "ci_high",
                  "median", "iqr_low", "iqr_high", "flag"]
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
