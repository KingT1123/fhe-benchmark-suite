#!/usr/bin/env python3
"""Round-7 SEAL/OpenFHE correspondence grid, from ACTUAL primes.

Inputs (run from experiments/openfhe/probe/):
  ../../security/seal_moduli.csv   SEAL 4.1.2's exact primes per grid row
  params_v2.csv                    openfhe_probe_v2: OpenFHE's actual Q and P
  functional_v2.csv                openfhe_probe_v2: per-operation functional checks
  ../../results/final/seal_standard.csv, seal_composite.csv
                                   which operations SEAL actually measured
Outputs: grid_v2.csv, operations_v2.csv, security_v2.csv and the LaTeX tables
  grid_v2.tex, operations_v2.tex, rejections_v2.tex, functional_v2.tex,
  security_v2.tex (security_v2 also reads ../../security/openfhe_candidates.csv
  and results_openfhe_N*.csv)

Configuration classes (SEAL: data primes Q_S, special key-switching prime P_S;
OpenFHE: ciphertext primes Q_O, key-switching primes P_O):
  exact match        Q_O == Q_S and P_O == P_S, prime by prime (values);
  same size profile  same number of primes and the same nominal size
                     (log2 rounded to the nearest bit) for each, for both Q
                     and P, but not the same primes in the same roles;
  partially comparable  Q matches (values or size profile) but the
                     key-switching modulus differs (other size, or none);
  separate analysis  the ciphertext modulus itself differs, or no accepted
                     variant passes the functional check.
Per-operation rule (consistent with the SEAL report, Section 6):
  * decrypt, add and multiply (without relinearization) act only on the
    ciphertext modulus Q: comparable when Q matches;
  * encrypt also depends on the key-switching modulus in SEAL (SEAL encrypts
    at the key level, including its special prime, then drops it), and key
    generation, relinearization and rotation all use key switching: these
    are comparable only when P matches as well;
  * no comparison where SEAL has no measurement (N=16384 categories 3 and 5;
    multiply/relinearize at depth 0; rotation outside N=8192/category 1) or
    where the OpenFHE operation failed its functional check.
The selected variant per cell is the best class whose functional checks
pass for every operation SEAL measured.
"""
import csv
import math
from collections import defaultdict

OPS = ["keygen", "encrypt", "decrypt", "add", "multiply", "relinearize", "rotate"]
Q_ONLY = {"decrypt", "add", "multiply"}
RANK = {"exact match": 0, "same size profile": 1, "partially comparable": 2, "separate analysis": 3}
FUNC_STEP = {"keygen": ["keygen", "relin_keygen"], "encrypt": ["encrypt"], "decrypt": ["decrypt"],
             "add": ["add"], "multiply": ["multiply"], "relinearize": ["relinearize"],
             "rotate": ["rotation_keygen", "rotate"]}


def bits(p):
    """Nominal size of a prime: log2 rounded to the nearest bit -- what "a
    40-bit prime" means for both libraries (SEAL picks primes just below
    2^40, OpenFHE's scaling primes may lie just above it)."""
    return round(math.log2(int(p)))


def seal_chains():
    out = {}
    for r in csv.DictReader(open("../../security/seal_moduli.csv")):
        primes = [int(x) for x in r["primes"].split()]
        Q, P = (primes[:-1], primes[-1:]) if len(primes) > 1 else (primes, [])
        out[(int(r["N"]), int(r["category"]))] = (Q, P, r["chain_bits"])
    return out


def seal_ckks_scale():
    """SEAL's CKKS initial scale (log2) per cell, from the configuration records."""
    return {(int(r["N"]), int(r["category"])): round(math.log2(float(r["initial_scale"])))
            for r in csv.DictReader(open("../../results/final/seal_config_metadata.csv"))
            if r["scheme"] == "CKKS" and r["initial_scale"]}


def openfhe_scale(f):
    d = f.get("encrypt", {}).get("detail", "")
    return d.split("log2_scale=")[1].split()[0] if "log2_scale=" in d else ""


def seal_measured():
    m = set()
    for r in csv.DictReader(open("../../results/final/seal_standard.csv")):
        if r["metric"] == "latency_ms" and r["mean"]:
            m.add((r["scheme"], int(r["N"]), int(r["category"]), r["operation"]))
    for r in csv.DictReader(open("../../results/final/seal_composite.csv")):
        if r["operation"] == "rotate" and r["metric"] == "latency_ms" and r["mean"]:
            m.add((r["scheme"], int(r["N"]), int(r["category"]), "rotate"))
    return m


def classify(QS, PS, QO, PO):
    q_exact, p_exact = QO == QS, PO == PS
    q_prof = [bits(x) for x in QO] == [bits(x) for x in QS]
    p_prof = [bits(x) for x in PO] == [bits(x) for x in PS]
    if q_exact and p_exact:
        return "exact match", q_exact, p_exact, q_prof, p_prof
    if q_prof and p_prof:
        return "same size profile", q_exact, p_exact, q_prof, p_prof
    if q_prof:
        return "partially comparable", q_exact, p_exact, q_prof, p_prof
    return "separate analysis", q_exact, p_exact, q_prof, p_prof


def main():
    seal = seal_chains()
    measured = seal_measured()
    sscale = seal_ckks_scale()
    params = defaultdict(dict)
    for r in csv.DictReader(open("params_v2.csv")):
        params[(r["scheme"], int(r["N"]), int(r["category"]))][r["variant"]] = r
    func = defaultdict(dict)
    for r in csv.DictReader(open("functional_v2.csv")):
        func[(r["scheme"], int(r["N"]), int(r["category"]), r["variant"])][r["step"]] = r

    grid, ops_rows = [], []
    for (N, cat) in sorted(seal):
        QS, PS, chain = seal[(N, cat)]
        for scheme in ("BFV", "BGV", "CKKS"):
            key = (scheme, N, cat)
            needed = [op for op in OPS if (scheme, N, cat, op) in measured]
            cands = []
            for v, r in sorted(params[key].items()):
                if r["status"] != "accepted":
                    continue
                QO = [int(x) for x in r["q_primes"].split()]
                PO = [int(x) for x in r["p_primes"].split()] if r["p_primes"] else []
                cls, qe, pe, qp, pp = classify(QS, PS, QO, PO)
                f = func[key + (v,)]
                ok = {op: all(f.get(s, {}).get("status") == "ok" for s in FUNC_STEP[op]) for op in OPS}
                cands.append((RANK[cls], -sum(ok[op] for op in needed), v, cls, qe, pe, QO, PO, r, ok))
            rej = sorted({f'{v}:{r["rejection_type"]}' for v, r in params[key].items() if r["status"] == "rejected"})
            if not cands:
                grid.append({"scheme": scheme, "N": N, "category": cat, "seal_chain": chain,
                             "variant": "", "class": "not available", "q_exact": "", "p_exact": "",
                             "primes_shared_with_seal": "",
                             "openfhe_q_bits": "", "openfhe_p_bits": "", "openfhe_log2_qp": "",
                             "functional_failures": "", "rejections": " ".join(rej),
                             "seal_ckks_log2_scale": "", "openfhe_ckks_log2_scale": ""})
                for op in OPS:
                    ops_rows.append({"scheme": scheme, "N": N, "category": cat, "operation": op,
                                     "verdict": "not available", "reason": "no accepted OpenFHE variant"})
                continue
            _, _, v, cls, qe, pe, QO, PO, r, ok = min(cands)
            fails = [op for op in needed if not ok[op]]
            shared = len(set(QO + PO) & set(QS + PS))
            grid.append({"scheme": scheme, "N": N, "category": cat, "seal_chain": chain, "variant": v,
                         "class": cls, "q_exact": qe, "p_exact": pe,
                         "primes_shared_with_seal": f"{shared}/{len(QO) + len(PO)}",
                         "openfhe_q_bits": "+".join(str(bits(x)) for x in QO),
                         "openfhe_p_bits": "+".join(str(bits(x)) for x in PO),
                         "openfhe_log2_qp": f'{float(r["log2_qp"]):.1f}',
                         "functional_failures": " ".join(fails), "rejections": " ".join(rej),
                         "seal_ckks_log2_scale": sscale.get((N, cat), "") if scheme == "CKKS" else "",
                         "openfhe_ckks_log2_scale": (str(round(float(openfhe_scale(func[key + (v,)]))))
                                                     if scheme == "CKKS" and openfhe_scale(func[key + (v,)]) else "")})
            for op in OPS:
                if (scheme, N, cat, op) not in measured:
                    verdict, why = "no SEAL measurement", "SEAL did not measure this operation here"
                elif not ok[op]:
                    verdict, why = "separate analysis", "OpenFHE functional check failed"
                elif cls in ("exact match", "same size profile"):
                    verdict, why = "directly comparable", cls
                elif cls == "partially comparable" and op in Q_ONLY:
                    verdict, why = "directly comparable", "same ciphertext modulus profile"
                elif cls == "partially comparable":
                    verdict, why = "separate analysis", "key-switching modulus differs"
                else:
                    verdict, why = "separate analysis", "ciphertext modulus differs"
                ops_rows.append({"scheme": scheme, "N": N, "category": cat, "operation": op,
                                 "verdict": verdict, "reason": why})

    for name, rows in (("grid_v2.csv", grid), ("operations_v2.csv", ops_rows)):
        with open(name, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0]), lineterminator="\n")
            w.writeheader(); w.writerows(rows)

    # LaTeX: configuration table and operation matrix
    vname = {"A": "A", "B": "B", "C": "C", "": "--"}  # A default, B hybrid 1 prime/digit, C BV

    def compact(sizes):
        """Prime sizes as LaTeX, runs collapsed: 60+40+40+40 -> 60+40$\\times$3."""
        out, i = [], 0
        while i < len(sizes):
            j = i
            while j < len(sizes) and sizes[j] == sizes[i]:
                j += 1
            out.append(str(sizes[i]) + (f"$\\times${j - i}" if j - i > 2 else "+" + str(sizes[i]) if j - i == 2 else ""))
            i = j
        return "+".join(out) or "--"

    t = [r"\begin{longtable}{@{}lllllllrl@{}}", r"\toprule",
         r"Scheme & $N$/cat. & SEAL $Q$ & SEAL $P$ & Var. & OpenFHE $Q$ & OpenFHE $P$ & $\log QP$ & Class \\",
         r"\midrule", r"\endhead"]
    for g in grid:
        QS, PS, _ = seal[(g["N"], g["category"])]
        if g["variant"]:
            oq = compact([int(x) for x in g["openfhe_q_bits"].split("+")])
            op = compact([int(x) for x in g["openfhe_p_bits"].split("+")] if g["openfhe_p_bits"] else [])
        else:
            oq = op = "--"
        t.append(f'{g["scheme"]} & {g["N"]}/{g["category"]} & {compact([bits(x) for x in QS])} & '
                 f'{compact([bits(x) for x in PS])} & {vname[g["variant"]]} & {oq} & {op} & '
                 f'{g["openfhe_log2_qp"] or "--"} & {g["class"]} \\\\')
    t += [r"\bottomrule", r"\end{longtable}"]
    open("grid_v2.tex", "w").write("% GENERATED by make_grid_v2.py\n" + "\n".join(t) + "\n")

    sym = {"directly comparable": r"\textbf{D}", "separate analysis": "S", "no SEAL measurement": r"--",
           "not available": "n/a"}
    by = defaultdict(dict)
    for o in ops_rows:
        by[(o["scheme"], o["N"], o["category"])][o["operation"]] = o["verdict"]
    t = [r"\begin{longtable}{@{}ll" + "c" * len(OPS) + "@{}}", r"\toprule",
         r"Scheme & $N$/cat. & " + " & ".join(OPS) + r" \\", r"\midrule", r"\endhead"]
    for (s, N, c), d in sorted(by.items(), key=lambda k: (k[0][1], k[0][2], k[0][0])):
        t.append(f"{s} & {N}/{c} & " + " & ".join(sym[d[op]] for op in OPS) + r" \\")
    t += [r"\bottomrule", r"\end{longtable}"]
    open("operations_v2.tex", "w").write("% GENERATED by make_grid_v2.py\n" + "\n".join(t) + "\n")

    rejections_table(params)
    functional_table(grid, func, seal, vname)
    security_table(grid, vname)

    from collections import Counter
    print("classes:", Counter(g["class"] for g in grid))
    print("operations:", Counter(o["verdict"] for o in ops_rows))


def rejections_table(params):
    """Outcome of every requested OpenFHE configuration (3 variants per cell),
    separating OpenFHE's security check from other parameter-generation
    failures."""
    word = {"accepted": "accepted", "security": "security check",
            "parameter-generation": "param.\\ generation"}
    t = [r"\begin{longtable}{@{}lllll@{}}", r"\toprule",
         r"Scheme & $N$/cat. & A: default & B: hybrid, 1 prime/digit & C: BV \\", r"\midrule", r"\endhead"]
    for (s, N, c), vs in sorted(params.items(), key=lambda k: (k[0][1], k[0][2], k[0][0])):
        cell = [word["accepted" if vs[v]["status"] == "accepted" else vs[v]["rejection_type"]] for v in "ABC"]
        t.append(f"{s} & {N}/{c} & " + " & ".join(cell) + r" \\")
    t += [r"\bottomrule", r"\end{longtable}"]
    open("rejections_v2.tex", "w").write("% GENERATED by make_grid_v2.py\n" + "\n".join(t) + "\n")


def functional_table(grid, func, seal, vname):
    """Functional check of the selected variant per cell. BFV/BGV: SEAL's
    plaintext modulus t, exact results mod t. CKKS: SEAL's and OpenFHE's
    initial scale, number of ciphertext primes (SEAL data primes / OpenFHE
    Q), largest normalized error over the steps that passed."""
    mark = {"ok": r"\checkmark", "wrong": "wrong", "unsupported": "exc."}
    steps = [("keygen", ["keygen", "relin_keygen", "rotation_keygen"]), ("enc", ["encrypt"]),
             ("dec", ["decrypt"]), ("add", ["add"]), ("mult", ["multiply"]),
             ("relin", ["relinearize"]), ("rescale", ["rescale"]), ("rot", ["rotate"])]
    t = [r"\begin{longtable}{@{}lllll" + "c" * len(steps) + "r@{}}", r"\toprule",
         r"Scheme & $N$/cat. & Var. & $t$ or scale S/O & $Q$ primes S/O & " +
         " & ".join(s for s, _ in steps) + r" & Max err. \\", r"\midrule", r"\endhead"]
    for g in grid:
        if not g["variant"]:
            continue
        f = func[(g["scheme"], g["N"], g["category"], g["variant"])]
        QS = seal[(g["N"], g["category"])][0]
        nq = len(g["openfhe_q_bits"].split("+"))
        ckks = g["scheme"] == "CKKS"
        if ckks:
            par = f'$2^{{{g["seal_ckks_log2_scale"]}}}$ / $2^{{{g["openfhe_ckks_log2_scale"]}}}$'
        else:
            par = f.get("encrypt", {}).get("detail", "").replace("t=", "")
        cells = []
        for _, ss in steps:
            if not ckks and ss == ["rescale"]:
                cells.append("n/a"); continue
            st = [f[s]["status"] if s in f else None for s in ss]
            if any(x is None for x in st):
                cells.append(r"--")
            else:
                bad = [x for x in st if x != "ok"]
                cells.append(mark[bad[0]] if bad else mark["ok"])
        errs = [float(r["detail"].split("norm_error=")[1].split()[0]) for r in f.values()
                if r["status"] == "ok" and "norm_error=" in r["detail"]]
        err = f"{max(errs):.1e}" if errs else "--" if ckks else "n/a"
        t.append(f'{g["scheme"]} & {g["N"]}/{g["category"]} & {vname[g["variant"]]} & {par} & '
                 f'{len(QS)}/{nq} & ' + " & ".join(cells) + f" & {err} \\\\")
    t += [r"\bottomrule", r"\end{longtable}"]
    open("functional_v2.tex", "w").write("% GENERATED by make_grid_v2.py\n" + "\n".join(t) + "\n")


def security_table(grid, vname):
    """Lattice Estimator verdict for every OpenFHE candidate
    (../../security/results_openfhe_N*.csv, inputs openfhe_candidates.csv).
    Candidates = every selected variant except N=16384 categories 3 and 5,
    which SEAL did not measure; checked here against the grid."""
    import glob
    sec = "../../security"
    cand = list(csv.DictReader(open(f"{sec}/openfhe_candidates.csv")))
    expect = {(g["scheme"], g["N"], g["category"], g["variant"]) for g in grid
              if g["variant"] and not (g["N"] == 16384 and g["category"] in (3, 5))}
    got = {(r["scheme"], int(r["N"]), int(r["category"]), r["variant"]) for r in cand}
    assert got == expect, f"openfhe_candidates.csv out of date: {got ^ expect}"
    res = defaultdict(dict)
    for path in sorted(glob.glob(f"{sec}/results_openfhe_N*.csv")):
        for r in csv.DictReader(open(path)):
            res[(r["scheme"], int(r["N"]), int(r["category"]), r["variant"])][r["attack"]] = r
    cls = {(g["scheme"], g["N"], g["category"], g["variant"]): g["class"] for g in grid}
    shared = {(g["scheme"], g["N"], g["category"], g["variant"]): g["primes_shared_with_seal"] for g in grid}
    rows = []
    for k in sorted(got, key=lambda k: (k[1], k[2], k[0])):
        a = res.get(k)
        assert a and "MIN" in a, f"no estimator result for {k}"
        best = a["MIN"]
        attack = min((r for n, r in a.items() if n != "MIN"), key=lambda r: float(r["log2_rop"]))["attack"]
        rows.append({"scheme": k[0], "N": k[1], "category": k[2], "variant": k[3], "class": cls[k],
                     "log2_qp": f'{float(best["log2_qp"]):.1f}', "cheapest_attack": attack,
                     "log2_cost": best["log2_rop"], "target_bits": best["target_bits"],
                     "margin_bits": f'{float(best["log2_rop"]) - int(best["target_bits"]):.2f}',
                     "verdict": best["verdict"], "estimator_commit": best["estimator_commit"]})
    with open("security_v2.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]), lineterminator="\n")
        w.writeheader(); w.writerows(rows)
    t = [r"\begin{longtable}{@{}lllllrlrrrl@{}}", r"\toprule",
         r"Scheme & $N$/cat. & Var. & Class & Shared primes & $\log QP$ & Cheapest attack & Cost & Target & Margin & Verdict \\",
         r"\midrule", r"\endhead"]
    for r in rows:
        k = (r["scheme"], r["N"], r["category"], r["variant"])
        t.append(f'{r["scheme"]} & {r["N"]}/{r["category"]} & {vname[r["variant"]]} & {r["class"]} & {shared[k]} & '
                 f'{r["log2_qp"]} & {r["cheapest_attack"].replace("_", " ")} & {float(r["log2_cost"]):.1f} & '
                 f'{r["target_bits"]} & {float(r["margin_bits"]):.1f} & {r["verdict"].replace("meets category", "meets")} \\\\')
    t += [r"\bottomrule", r"\end{longtable}"]
    open("security_v2.tex", "w").write("% GENERATED by make_grid_v2.py\n" + "\n".join(t) + "\n")


if __name__ == "__main__":
    main()
