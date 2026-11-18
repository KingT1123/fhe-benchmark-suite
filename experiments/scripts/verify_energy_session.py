#!/usr/bin/env python3
"""verify_energy_session.py — checks that one session of the energy/memory
campaign (openfhe/run_energy_campaign.sh) produced everything its plan
requires. It computes no statistics; it only checks presence and validity.

For every invocation of the session's plan (<session>/plan.csv):
  * the cell is valid (validate_cell.py: complete rows, every repetition
    checked correct);
  * energy invocation: the energy columns are present, every energy_uj is
    > 0 and the idle reading is > 0;
  * memory invocation: the peak-RSS file exists and holds a positive value.
For every invocation set aside after a loss of mains power (set_aside.csv):
  * its original files are still there (kept, not deleted);
  * the invocation was measured again and is valid.
It also reports the power state over the session (samples off mains, samples
with boost on) from power_log.csv.

Usage: python3 verify_energy_session.py SESSION_DIR [--dry]
  --dry: dry-run session (no energy counter): energy columns not required.
Exit status 0 = everything present and valid, 1 = something missing.
"""
import argparse
import csv
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from validate_cell import validate  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session_dir")
    ap.add_argument("--dry", action="store_true")
    a = ap.parse_args()
    d = a.session_dir.rstrip("/")
    exp = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    state = open(os.path.join(d, "cpu_state.txt")).read()
    ew = int(re.search(r"energy: plan repetitions \+ (\d+) warm-up", state).group(1))
    mr, mw = map(int, re.search(r"memory: (\d+) reps \+ (\d+) warm-up", state).groups())
    plan = list(csv.DictReader(open(os.path.join(d, "plan.csv"))))
    problems, n_energy, n_mem = [], 0, 0

    def tag_of(p, kind):
        label = f"_{p['label']}" if p["label"] else ""
        return f"{p['library']}_{p['scheme'].lower()}_N{p['N']}_cat{p['category']}_{p['operation']}{label}_{kind}"

    def cell_ok(tag, rows, warm):
        ok, why = validate(os.path.join(d, tag + ".csv"), rows, warm, os.path.join(d, "checks", tag + "_check.csv"))
        if not ok:
            problems.append(f"{tag}: {why}")
        return ok

    for p in plan:
        reps = int(p["energy_reps"])
        if a.dry:
            reps = min(reps, 2)
        for k in range(1, int(p["energy_runs"]) + 1):
            tag = tag_of(p, f"energy{k}")
            if not cell_ok(tag, reps + ew, ew):
                continue
            rows = list(csv.DictReader(open(os.path.join(d, tag + ".csv"))))
            if "energy_uj" not in rows[0]:
                if not a.dry:
                    problems.append(f"{tag}: no energy columns (counter not read)")
                    continue
            elif any(int(r["energy_uj"]) <= 0 for r in rows):
                problems.append(f"{tag}: an energy reading is zero")
                continue
            elif float(rows[0]["idle_power_w"]) <= 0:
                problems.append(f"{tag}: idle reading is zero")
                continue
            n_energy += 1
        for k in range(1, int(p["memory_runs"]) + 1):
            tag = tag_of(p, f"mem{k}")
            if not cell_ok(tag, mr + mw, mw):
                continue
            pk = os.path.join(d, "memory", tag + "_peak.log")
            m = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", open(pk).read()) if os.path.exists(pk) else None
            if not m or int(m.group(1)) <= 0:
                problems.append(f"{tag}: peak-RSS file missing or empty")
                continue
            n_mem += 1

    aside = list(csv.DictReader(open(os.path.join(d, "set_aside.csv"))))
    kept = 0
    for s in aside:
        if not s.get("kept_in"):
            continue   # an idle window repeated: nothing to keep
        q = os.path.join(exp, s["kept_in"])
        if not (os.path.isdir(q) and any(f.startswith(s["tag"] + ".csv") for f in os.listdir(q))):
            problems.append(f"set aside {s['tag']}: original files not found in {s['kept_in']}")
        else:
            kept += 1

    power = list(csv.DictReader(open(os.path.join(d, "power_log.csv"))))
    off = sum(r["mains_online"] != "1" for r in power)
    boost = sum(r["boost"] != "0" for r in power)
    want_e = sum(int(p["energy_runs"]) for p in plan)
    want_m = sum(int(p["memory_runs"]) for p in plan)
    print(f"session check: {os.path.basename(d)}")
    print(f"  plan: {len(plan)} cells -> {want_e} energy invocations, {want_m} memory invocations")
    print(f"  energy invocations with their files, valid, energy > 0: {n_energy}/{want_e}")
    print(f"  memory invocations with their files, valid, peak RSS > 0: {n_mem}/{want_m}")
    print(f"  set aside (mains loss, or time-based after a recorded disturbance): {len(aside)} (original files kept: {kept}); each measured again: "
          f"{'yes' if not any(p_.startswith(s['tag'] + ':') for s in aside for p_ in problems) else 'NO'}")
    print(f"  power log: {len(power)} samples; off mains: {off}; with boost on: {boost}")
    for p_ in problems:
        print(f"  PROBLEM: {p_}")
    print("  RESULT: " + ("all expected files present and valid" if not problems else f"{len(problems)} problem(s)"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
