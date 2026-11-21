#!/usr/bin/env python3
"""make_params.py -- the Lattigo configurations of the latency pilot: SEAL's
EXACT primes for N=8192, category 1 (../../security/seal_moduli.csv: the
primes SEAL 4.1.2 builds, last one = its special key-switching prime), with
SEAL's plaintext modulus for BFV/BGV (1032193, as bench_seal/bench_openfhe
seal_t) and SEAL's CKKS scale for this row (2^40, openfhe/probe/
ckks_differences_v2.csv). Lattigo takes explicit primes (ParametersLiteral Q,
P), so the pilot uses the same moduli as SEAL; bench_lattigo checks that the
parameters Lattigo builds hold exactly these primes. Nothing typed by hand
except the choice of the grid row. Output: lattigo_params.csv."""
import csv
N, CAT = 8192, 1
row = next(r for r in csv.DictReader(open("../../security/seal_moduli.csv")) if int(r["N"]) == N and int(r["category"]) == CAT)
primes = row["primes"].split()
scale = next(r for r in csv.DictReader(open("../../openfhe/probe/ckks_differences_v2.csv"))
             if int(r["N"]) == N and int(r["category"]) == CAT)["seal_log2_scale"]
SEAL_T = {(8192, 1): 1032193}   # = seal_t() in openfhe/src/bench_openfhe.cpp and bench_seal.cpp
with open("lattigo_params.csv", "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["scheme", "N", "category", "log_n", "q_primes", "p_primes", "seal_chain_bits", "seal_log2_q",
                "plaintext_modulus", "ckks_log2_scale", "source"])
    for scheme in ("BFV", "BGV", "CKKS"):
        w.writerow([scheme, N, CAT, N.bit_length() - 1, " ".join(primes[:-1]), primes[-1], row["chain_bits"],
                    row["log2_q"], "" if scheme == "CKKS" else SEAL_T[(N, CAT)], scale if scheme == "CKKS" else "",
                    "SEAL 4.1.2 exact primes (security/seal_moduli.csv)"])
print(open("lattigo_params.csv").read())
