"""Sensitivity check of the tightest OpenFHE candidates (round 8).

The three OpenFHE candidates at N=8192/category 5 (BFV, BGV, CKKS) meet the
256-bit target by only 0.86 bits under the setting used for every estimate
in this repository (estimate_openfhe.py: full LWE.estimate, default cost
model MATZOV, Gaussian error sigma=3.19, uniform ternary secret, unbounded
samples). A margin this small could depend on the model, so the same
instances -- same N, same actual Q*P, same distributions -- are re-estimated
under other lattice-reduction cost models of the same estimator commit:

  BDGL16  classical sieving [BDGL16], 2^(0.292 beta + 16.4) per SVP call,
          times the number of calls, plus LLL: an older, simpler model
          than MATZOV;
  ADPS16  "core-SVP" [ADPS16, classical mode]: 2^(0.292 beta), a single
          SVP call with no constant and no repetitions -- deliberately
          pessimistic for the defender (a conservative lower bound used in
          post-quantum design, not the cost of an actual attack).

Nothing else changes; Arora-GB and BKW stay excluded, as everywhere else
(never competitive here, and too slow to run: Arora-GB alone did not finish
within 5 minutes for one of these instances). The MATZOV values are not
recomputed: they are read back from results_openfhe_N8192.csv and copied
into the output for comparison.

Reference point (--seal): SEAL's own N=8192/category 5 configuration (exact
primes from seal_moduli.csv, Gaussian sigma=3.19 as in its baseline row of
results_full_N8192.csv: 272.82 bits under MATZOV), estimated under the same
two cost models. It shows how much each model moves a configuration that
has a comfortable margin under the default model, so that the OpenFHE
result is read against the model and not against OpenFHE alone.

Run inside the SageMath image via run_estimator_docker.sh (TARGET=sensitivity,
or TARGET=sensitivity_seal for the reference point).
Output: one row per (configuration, cost model, attack) plus the minimum.
"""
import argparse
import csv
import math
import os
import time

from estimator import LWE, ND, RC

TARGET_BITS = {1: 128, 3: 192, 5: 256}
MODELS = {"BDGL16": RC.BDGL16, "ADPS16": RC.ADPS16}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidates", default="openfhe_candidates.csv")
    ap.add_argument("--baseline", default="results_openfhe_N8192.csv")
    ap.add_argument("--N", type=int, default=8192)
    ap.add_argument("--category", type=int, default=5)
    ap.add_argument("--models", nargs="+", default=list(MODELS))
    ap.add_argument("--seal", action="store_true", help="estimate SEAL's configuration instead")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    commit = os.environ.get("ESTIMATOR_COMMIT", "unknown")
    if args.seal:
        rows = [{"scheme": "SEAL", "N": r["N"], "category": r["category"], "variant": "-",
                 "q_primes": r["primes"], "p_primes": ""}
                for r in csv.DictReader(open("seal_moduli.csv"))
                if int(r["N"]) == args.N and int(r["category"]) == args.category]
        base = [dict(r, scheme="SEAL", variant="-", log2_qp=r["log2_q"], error_model="Gaussian3.19",
                     target_bits=str(TARGET_BITS[args.category]),
                     verdict=("meets category" if float(r["log2_rop"]) >= TARGET_BITS[args.category]
                              else "BELOW category") if r["attack"] == "MIN" else "")
                for r in csv.DictReader(open("results_full_N8192.csv"))
                if int(r["category"]) == args.category and r["error_model"] == "Gaussian3.19_approx"]
    else:
        rows = [r for r in csv.DictReader(open(args.candidates))
                if int(r["N"]) == args.N and int(r["category"]) == args.category]
        base = [r for r in csv.DictReader(open(args.baseline)) if int(r["category"]) == args.category]
    cols = ["scheme", "N", "category", "variant", "log2_qp", "secret", "error_model", "cost_model",
            "attack", "log2_rop", "target_bits", "verdict", "seconds", "estimator_commit"]
    with open(args.out, "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(cols)
        for b in base:  # the baseline, copied (cost model MATZOV, the estimator default)
            w.writerow([b["scheme"], b["N"], b["category"], b["variant"], b["log2_qp"], b["secret"],
                        b["error_model"], "MATZOV (baseline, copied)", b["attack"], b["log2_rop"],
                        b["target_bits"], b["verdict"], b["seconds"], b["estimator_commit"]])
        for model in args.models:
            for r in rows:
                N, cat = int(r["N"]), int(r["category"])
                q = math.prod(int(p) for p in (r["q_primes"] + " " + r["p_primes"]).split())  # SEAL: all primes
                params = LWE.Parameters(n=N, q=q, Xs=ND.UniformMod(3), Xe=ND.DiscreteGaussian(3.19),
                                        tag=f"{'SEAL' if args.seal else 'OpenFHE'}_{r['scheme']}_N{N}_cat{cat}_{r['variant']}")
                label = f"{r['scheme']} N={N} cat={cat} variant={r['variant']} model={model}"
                print(f"{time.strftime('%H:%M:%S')} START {label}", flush=True)
                t0 = time.time()
                res = LWE.estimate(params, red_cost_model=MODELS[model], jobs=1,
                                   deny_list=("arora-gb", "bkw"))
                dt = time.time() - t0
                costs = {a: float(math.log2(c["rop"])) for a, c in res.items()
                         if c.get("rop") not in (None, float("inf"))}
                best = min(costs.values())
                verdict = "meets category" if best >= TARGET_BITS[cat] else "BELOW category"
                for a, v in sorted(costs.items()) + [("MIN", best)]:
                    w.writerow([r["scheme"], N, cat, r["variant"], f"{math.log2(q):.4f}", "uniform_ternary",
                                "Gaussian3.19", model, a, f"{v:.2f}", TARGET_BITS[cat],
                                verdict if a == "MIN" else "", f"{dt:.0f}", commit])
                f.flush()
                print(f"{time.strftime('%H:%M:%S')} DONE  {label}: min log2(rop) = {best:.2f} "
                      f"({verdict}, {dt:.0f} s)", flush=True)


if __name__ == "__main__":
    main()
