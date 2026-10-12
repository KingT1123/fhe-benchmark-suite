"""Lattice Estimator runs for the SEAL parameter grid (round 6 of the review).

Run inside the SageMath Docker image, with the Lattice Estimator checked out
at the pinned commit (see run_estimator_docker.sh, which does all of this):

    sage -python estimate_seal.py --mode rough --out results_rough.csv
    sage -python estimate_seal.py --mode full --N 2048 4096 --jobs 2 --out results_full.csv

Inputs (one row per configuration, from seal_moduli.csv): the ring dimension
N and the exact coefficient-modulus primes SEAL 4.1.2 generates for that row
of config/param_grid.csv; q is their product, the full modulus including the
special key-switching prime (the modulus an attacker sees in the public key).

Distributions, read from SEAL 4.1.2's own source (seal/util/rlwe.cpp):
  * secret: uniform ternary {-1, 0, 1}            -> ND.UniformMod(3)
  * error:  centered binomial from 21 bits a side  -> ND.CenteredBinomial(21)
            (SEAL_USE_GAUSSIAN_NOISE is off in this build; variance 21/2,
             standard deviation sqrt(10.5) ~= 3.24)
The estimator models distributions through their standard deviation (and
support), so CBD(21) is used as-is; as a sensitivity check every
configuration is also run with the conventional approximation
ND.DiscreteGaussian(3.19) used by the estimator's own SEAL examples.
Number of samples m: the estimator's default (unbounded), as in its SEAL
examples -- a conservative choice for the attacker.

Modes: "rough" = LWE.estimate.rough (the estimator's fast mode: usvp and
dual-hybrid with simplified cost models); "full" = LWE.estimate (every
attack the estimator implements; expensive at large N).
Output: one row per (configuration, error model, attack), plus the minimum
over attacks, as log2 of the estimated cost ("rop").
"""
import argparse
import csv
import math
import os
import time

from estimator import LWE, ND

CATEGORIES = {1, 3, 5}
ERROR_MODELS = {
    "CBD21_exact": ND.CenteredBinomial(21),
    "Gaussian3.19_approx": ND.DiscreteGaussian(3.19),
}


def load_configs(path, Ns):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            if int(r["N"]) in Ns:
                q = math.prod(int(p) for p in r["primes"].split())
                rows.append((int(r["N"]), int(r["category"]), q))
    rows = [x for x in rows if x[1] in CATEGORIES]
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["rough", "full"], required=True)
    ap.add_argument("--N", type=int, nargs="+", default=[2048, 4096, 8192])
    ap.add_argument("--categories", type=int, nargs="+", default=[1, 3, 5])
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("--moduli", default="seal_moduli.csv")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    global CATEGORIES
    CATEGORIES = set(args.categories)

    commit = os.environ.get("ESTIMATOR_COMMIT", "unknown")  # set by run_estimator_docker.sh
    with open(args.out, "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["N", "category", "log2_q", "secret", "error_model", "mode",
                    "attack", "log2_rop", "seconds", "estimator_commit"])
        for N, cat, q in load_configs(args.moduli, set(args.N)):
            for name, Xe in ERROR_MODELS.items():
                params = LWE.Parameters(n=N, q=q, Xs=ND.UniformMod(3), Xe=Xe,
                                        tag=f"SEAL_N{N}_cat{cat}_{name}")
                t0 = time.time()
                print(f"{time.strftime('%H:%M:%S')} START N={N} cat={cat} {name} {args.mode}", flush=True)
                if args.mode == "rough":
                    res = LWE.estimate.rough(params)
                else:
                    # Arora-GB and BKW are never competitive at these sizes
                    # (Arora-GB: about 2^597 even in the rough run) and dominate the
                    # running time, so they are excluded; every other attack
                    # of the estimator runs with its default cost model.
                    res = LWE.estimate(params, jobs=args.jobs, deny_list=("arora-gb", "bkw"))
                dt = time.time() - t0
                costs = {a: float(math.log2(c["rop"])) for a, c in res.items()
                         if c.get("rop") not in (None, float("inf"))}
                for a, v in sorted(costs.items()):
                    w.writerow([N, cat, f"{math.log2(q):.4f}", "uniform_ternary", name,
                                args.mode, a, f"{v:.2f}", f"{dt:.0f}", commit])
                w.writerow([N, cat, f"{math.log2(q):.4f}", "uniform_ternary", name, args.mode,
                            "MIN", f"{min(costs.values()):.2f}", f"{dt:.0f}", commit])
                f.flush()
                print(f"{time.strftime('%H:%M:%S')} DONE  N={N} cat={cat} {name} {args.mode}: "
                      f"min log2(rop) = {min(costs.values()):.2f} ({dt:.0f} s)", flush=True)


if __name__ == "__main__":
    main()
