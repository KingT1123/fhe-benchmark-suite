#!/usr/bin/env python3
"""make_params.py -- the HElib configurations of the latency pilot, taken from
probe_results.csv (run_probe_docker.sh): nothing typed by hand.

Pilot configuration = the grid's N=8192, category 1 (SEAL: 60+40+40 | 60,
depth 2). HElib takes no list of primes, only bits and c. Chosen: among the
candidates whose c equals the number of ciphertext primes (one key-switching
digit per prime, as SEAL), which reach at least the grid's depth (2) with
public-key encryption, whose log2(Q*P) over ciphertext and special primes is
within the HE standard's bound for N=8192 at 128 bits (218) and whose HElib
security estimate is >= 128: the SMALLEST log2(Q*P) (the usual choice: the
smallest modulus for the required depth). HElib's chain jumps from 2
ciphertext primes (bits <= 119) to 3 (bits >= 120): BGV gets depth 1 with 2
primes and depth 3 with 3, so no BGV configuration has exactly depth 2.
CKKS precision 20 (HElib's default: with 2 primes a higher precision leaves
depth 1, see probe_results.csv). BGV: p = SEAL's
plaintext modulus for N=8192 (1032193), r = 1.
Output: helib_params.csv (read by bench_helib, which checks the primes)."""
import csv
HE_STANDARD_LOG2QP_MAX = {(8192, 1): 218}
rows = list(csv.DictReader(open("probe_results.csv")))
out = []
for scheme, param in (("CKKS", "20"), ("BGV", "1032193")):
    cand = [r for r in rows if r["scheme"] == scheme and r["param"] == param
            and int(r["c"]) == len(r["ctxt_primes"].split()) and int(r["depth_ok"]) >= 2 and float(r["log2QP_ctxt_special"]) <= HE_STANDARD_LOG2QP_MAX[(8192, 1)]
            and float(r["helib_security"]) >= 128]
    r = min(cand, key=lambda r: (float(r["log2QP_ctxt_special"]), int(r["bits_req"])))
    out.append({"scheme": scheme, "N": r["N"], "category": 1, "m": r["m"], "bits": r["bits_req"], "c": r["c"],
                "param": param, "small_primes": r["small_primes"], "ctxt_primes": r["ctxt_primes"],
                "special_primes": r["special_primes"], "ctxt_bits": r["ctxt_bits"], "special_bits": r["special_bits"],
                "log2Q": r["log2Q_fresh"], "log2P": r["log2P_special"], "log2QP": r["log2QP_ctxt_special"],
                "he_standard_log2QP_max": HE_STANDARD_LOG2QP_MAX[(8192, 1)],
                "helib_security": r["helib_security"], "depth_reached": r["depth_ok"], "slots": r["slots"], "gens": r["gens"]})
with open("helib_params.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(out[0]), lineterminator="\n")
    w.writeheader(); w.writerows(out)
for r in out:
    print(r["scheme"], "bits", r["bits"], "Q", r["ctxt_bits"], "P", r["special_bits"], "log2QP %.1f" % float(r["log2QP"]),
          "security %.0f" % float(r["helib_security"]))
