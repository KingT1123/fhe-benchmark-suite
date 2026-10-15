"""Lattice Estimator runs for the OpenFHE candidate configurations (round 7).

Run inside the SageMath Docker image via run_estimator_docker.sh
(TARGET=openfhe), with the Lattice Estimator at the same pinned commit as the
SEAL estimates.

Inputs: openfhe_candidates.csv -- for every OpenFHE configuration intended
for measurement (an accepted, functionally checked variant whose SEAL
counterpart was measured), the ACTUAL primes OpenFHE 1.5.1 generated:
ciphertext primes Q and key-switching primes P (experiments/openfhe/probe/).
q is the product of all of them, Q*P: the full modulus of the public and
key-switching keys, which OpenFHE's own security check also evaluates.

Distributions: OpenFHE's defaults, read from its source
(gen-cryptocontext-params-defaults.h): uniform ternary secret
(UNIFORM_TERNARY) -> ND.UniformMod(3); discrete Gaussian error with
standard deviation 3.19 -> ND.DiscreteGaussian(3.19). Number of samples m
unbounded (estimator default, conservative). Full LWE.estimate with the
default cost model; Arora-GB and BKW excluded as for SEAL (never
competitive, dominate the running time).

Output: one row per (configuration, attack) plus the minimum, as log2 of the
estimated cost, and the verdict against the configuration's category
(128/192/256 bits).
"""
import argparse
import csv
import math
import os
import time

from estimator import LWE, ND

TARGET_BITS = {1: 128, 3: 192, 5: 256}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--N", type=int, nargs="+", default=[2048, 4096, 8192, 16384])
    ap.add_argument("--candidates", default="openfhe_candidates.csv")
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    commit = os.environ.get("ESTIMATOR_COMMIT", "unknown")
    rows = [r for r in csv.DictReader(open(args.candidates)) if int(r["N"]) in set(args.N)]
    with open(args.out, "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["scheme", "N", "category", "variant", "log2_qp", "secret", "error_model",
                    "attack", "log2_rop", "target_bits", "verdict", "seconds", "estimator_commit"])
        for r in rows:
            N, cat = int(r["N"]), int(r["category"])
            primes = [int(p) for p in (r["q_primes"] + " " + r["p_primes"]).split()]
            q = math.prod(primes)
            params = LWE.Parameters(n=N, q=q, Xs=ND.UniformMod(3), Xe=ND.DiscreteGaussian(3.19),
                                    tag=f"OpenFHE_{r['scheme']}_N{N}_cat{cat}_{r['variant']}")
            label = f"{r['scheme']} N={N} cat={cat} variant={r['variant']}"
            print(f"{time.strftime('%H:%M:%S')} START {label} full", flush=True)
            t0 = time.time()
            res = LWE.estimate(params, jobs=args.jobs, deny_list=("arora-gb", "bkw"))
            dt = time.time() - t0
            costs = {a: float(math.log2(c["rop"])) for a, c in res.items()
                     if c.get("rop") not in (None, float("inf"))}
            best = min(costs.values())
            verdict = "meets category" if best >= TARGET_BITS[cat] else "BELOW category"
            for a, v in sorted(costs.items()):
                w.writerow([r["scheme"], N, cat, r["variant"], f"{math.log2(q):.4f}", "uniform_ternary",
                            "Gaussian3.19", a, f"{v:.2f}", TARGET_BITS[cat], "", f"{dt:.0f}", commit])
            w.writerow([r["scheme"], N, cat, r["variant"], f"{math.log2(q):.4f}", "uniform_ternary",
                        "Gaussian3.19", "MIN", f"{best:.2f}", TARGET_BITS[cat], verdict, f"{dt:.0f}", commit])
            f.flush()
            print(f"{time.strftime('%H:%M:%S')} DONE  {label} full: min log2(rop) = {best:.2f} "
                  f"({verdict}, {dt:.0f} s)", flush=True)


if __name__ == "__main__":
    main()
