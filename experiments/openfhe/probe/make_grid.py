#!/usr/bin/env python3
"""Build the SEAL/OpenFHE correspondence grid from the probe results.

Inputs:  ../../security/seal_moduli.csv  (SEAL's exact chain per row)
         probe_results.csv               (openfhe_param_probe output)
Outputs: correspondence_grid.csv and correspondence_grid.tex (LaTeX table)

For every (scheme, N, category) it picks, among the OpenFHE variants that
OpenFHE ACCEPTED with its security check on, the one closest to SEAL, and
classifies the cell. In SEAL a ciphertext lives modulo the data primes
(every prime but the last); the last prime is a special prime used only for
key switching. So:
  identical    - OpenFHE's ciphertext primes Q equal SEAL's data primes and
                 its key-switching primes P equal SEAL's special prime;
  same-Q       - Q equal, key switching different (P size, or BV with no P):
                 encrypt/decrypt/add directly comparable; keygen,
                 relinearize, rotate not;
  near         - same number of Q primes, each within 2 bits of SEAL's;
  different    - accepted, but a different chain (e.g. BFV's automatic one);
  not available- rejected in every variant (reason recorded).
Run from experiments/openfhe/probe/:  python3 make_grid.py
"""
import csv

RANK = {"identical": 0, "same-Q": 1, "near": 2, "different": 3}
LABEL = {"identical": "identical", "same-Q": "same $Q$, other key switching",
         "near": "near ($\\le$2 bits/prime)", "different": "different chain",
         "not available": "not available"}
VARIANT = {"A": "default", "B": "hybrid, 1 prime/digit", "C": "BV"}


def seal_chains():
    out = {}
    for r in csv.DictReader(open("../../security/seal_moduli.csv")):
        bits = []
        for tok in r["chain_bits"].split("+"):
            if "*" in tok:
                b, n = tok.split("*"); bits += [int(b)] * int(n)
            else:
                bits.append(int(tok))
        out[(r["N"], r["category"])] = (bits, float(r["log2_q"]))
    return out


def compact(bits):
    """[60, 40, 40, 40, 60] -> '60+40x3+60' (LaTeX: \\times)."""
    out, i = [], 0
    while i < len(bits):
        j = i
        while j < len(bits) and bits[j] == bits[i]:
            j += 1
        out.append(f"{bits[i]}" if j - i == 1 else f"{bits[i]}$\\times${j - i}")
        i = j
    return "+".join(out) if out else "--"


def classify(seal_bits, q, p):
    data, special = (seal_bits[:-1], [seal_bits[-1]]) if len(seal_bits) > 1 else (seal_bits, [])
    if q == data:
        return "identical" if p == special else "same-Q"
    if len(q) == len(data) and all(abs(a - b) <= 2 for a, b in zip(q, data)):
        return "near"
    return "different"


def main():
    seal = seal_chains()
    probe = {}
    for r in csv.DictReader(open("probe_results.csv")):
        probe.setdefault((r["scheme"], r["N"], r["category"]), {})[r["request"][0]] = r
    rows = []
    for (N, cat) in sorted(seal, key=lambda k: (int(k[0]), int(k[1]))):
        bits, lq = seal[(N, cat)]
        for scheme in ("BFV", "BGV", "CKKS"):
            best = None
            for v, r in probe[(scheme, N, cat)].items():
                if r["status"] != "accepted":
                    continue
                q = [int(b) for b in r["q_prime_bits"].split()]
                p = [int(b) for b in r["p_prime_bits"].split()] if r["p_prime_bits"] else []
                c = classify(bits, q, p)
                cand = (RANK[c], v, q, p, float(r["log2_qp"]), c)
                if best is None or cand[:2] < best[:2]:
                    best = cand
            if best:
                _, v, q, p, qp, c = best
                reason = ""
            else:
                v, q, p, qp, c = "", [], [], "", "not available"
                errs = {r["error"].split("():")[-1].strip()[:90] for r in probe[(scheme, N, cat)].values()}
                reason = " / ".join(sorted(errs))
            rows.append({"scheme": scheme, "N": N, "category": cat,
                         "seal_chain": "+".join(map(str, bits)), "seal_log2_q": f"{lq:.1f}",
                         "openfhe_variant": v, "openfhe_q_bits": "+".join(map(str, q)),
                         "openfhe_p_bits": "+".join(map(str, p)),
                         "openfhe_log2_qp": f"{qp:.1f}" if qp != "" else "",
                         "class": c, "reason_if_rejected": reason})
    with open("correspondence_grid.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]), lineterminator="\n")
        w.writeheader(); w.writerows(rows)

    tex = [r"\begin{longtable}{@{}llrlrlrl@{}}", r"\toprule",
           r"Scheme & $N$/cat. & SEAL chain & $\log q$ & Key switching & $Q$ \,|\, $P$ (bits) & $\log QP$ & Class \\",
           r"\midrule", r"\endhead"]
    for r in rows:
        tobits = lambda x: [int(b) for b in x.split("+")] if x else []
        qp = (f"{compact(tobits(r['openfhe_q_bits']))} \\,|\\, {compact(tobits(r['openfhe_p_bits']))}"
              if r["openfhe_variant"] else "--")
        tex.append(f"{r['scheme']} & {r['N']}/{r['category']} & {compact(tobits(r['seal_chain']))} & {r['seal_log2_q']} & "
                   f"{VARIANT.get(r['openfhe_variant'], '--')} & {qp} & {r['openfhe_log2_qp'] or '--'} & "
                   f"{LABEL[r['class']]} \\\\")
    tex += [r"\bottomrule", r"\end{longtable}"]
    open("correspondence_grid.tex", "w").write("% GENERATED by make_grid.py from probe_results.csv\n" + "\n".join(tex) + "\n")
    from collections import Counter
    print(Counter(r["class"] for r in rows))


if __name__ == "__main__":
    main()
