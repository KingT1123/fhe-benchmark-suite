#!/usr/bin/env bash
# harness_selftest.sh — functional self-test of both harnesses (no timing value
# is used; no sudo). For every eligible configuration (probe/eligible_v2.csv)
# and every operation to be timed there, plus OpenFHE's diagnostics:
#   * bench_openfhe and bench_seal in latency mode and in memory mode
#     (--peak-rss-out, checks in a forked child), 3 repetitions after 1
#     warm-up, every repetition checked (full rotated vector included);
#   * the produced cell must pass scripts/validate_cell.py;
#   * fault injection (--inject-mismatch-at) in each harness and each scheme
#     must END WITH EXIT CODE 3 AND NO OUTPUT FILE.
# Writes validation/harness_selftest.log; exit status 0 only if every case
# behaved as required.  Usage:  bash experiments/openfhe/validation/harness_selftest.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EXP="$(cd "$HERE/../.." && pwd)"
LOG="$HERE/harness_selftest.log"
T="results/raw/_selftest"   # scratch cells, removed at the end
mkdir -p "$EXP/$T"
: > "$LOG"
pass=0; fail=0
note() { echo "$*" | tee -a "$LOG"; }
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); note "FAIL: $*"; }

ofhe() { docker run --rm -u "$(id -u):$(id -g)" -e LD_LIBRARY_PATH=/usr/local/lib -v "$EXP":/work -w /work/openfhe openfhe-env \
             ./build/bench_openfhe --eligible=probe/eligible_v2.csv "$@" 2>&1; }
seal() { docker run --rm -u "$(id -u):$(id -g)" -v "$EXP":/work -w /work/seal seal-env \
             ./build/bench_seal --grid=../config/param_grid.csv "$@" 2>&1; }
valid() { python3 "$EXP/scripts/validate_cell.py" "$EXP/$T/$1.csv" --rows 4 --warmup 1 --check "$EXP/$T/$1_check.csv" >/dev/null; }

note "harness self-test $(date -Iseconds); code commit $(git -C "$EXP/.." rev-parse --short HEAD)"
while IFS=, read -r S N C V D F SC OPS QP PP; do
    for op in $OPS $( [[ " $OPS " == *" decrypt "* ]] && echo decrypt_full ) $( [[ " $OPS " == *" add "* ]] && echo add_inplace ); do
        for mode in latency memory; do
            extra=(--inner-loop=5); [ "$mode" = memory ] && extra=(--inner-loop=1 --peak-rss-out=../$T/peak.log)
            tag="o_${S}_${N}_${C}_${op}_${mode}"
            out=$(ofhe --scheme="$S" --N="$N" --category="$C" --operation="$op" --reps=3 --warmup=1 "${extra[@]}" \
                  --out="../$T/$tag.csv" --check-out="../$T/${tag}_check.csv")
            if [ $? -eq 0 ] && valid "$tag"; then ok; else bad "OpenFHE $S $N/$C $op ($mode): $(echo "$out" | tail -1)"; fi
            [[ "$op" == decrypt_full || "$op" == add_inplace ]] && continue
            tag="s_${S}_${N}_${C}_${op}_${mode}"
            [ "$mode" = memory ] && extra=(--inner-loop=1 --peak-rss-out=../$T/speak.log)
            out=$(seal --scheme="$S" --N="$N" --category="$C" --operation="$op" --reps=3 --warmup=1 "${extra[@]}" \
                  --out="../$T/$tag.csv" --check-out="../$T/${tag}_check.csv")
            if [ $? -eq 0 ] && valid "$tag"; then ok; else bad "SEAL $S $N/$C $op ($mode): $(echo "$out" | tail -1)"; fi
        done
    done
    note "  $S $N/$C: operations $OPS -- done (cumulative: $pass passed, $fail failed)"
done < <(tail -n +2 "$EXP/openfhe/probe/eligible_v2.csv" | python3 -c '
import csv, sys
for r in csv.reader(sys.stdin): print(",".join(r[:7] + [r[7]] + ["x", "x"]))')

note "fault injection (each must exit with code 3 and leave no output file):"
for S in CKKS BFV BGV; do
    for lib in ofhe seal; do
        tag="inj_${lib}_$S"
        out=$($lib --scheme="$S" --N=8192 --category=1 --operation=multiply --reps=3 --warmup=1 --inner-loop=2 \
              --inject-mismatch-at=1 --out="../$T/$tag.csv" --check-out="../$T/${tag}_check.csv"); rc=$?
        if [ $rc -eq 3 ] && [ ! -e "$EXP/$T/$tag.csv" ] && [ -e "$EXP/$T/$tag.csv.invalid" ]; then ok; note "  $lib $S: exit 3, no output file -- as required"
        else bad "$lib $S fault injection: exit $rc"; fi
    done
done
rm -rf "${EXP:?}/$T"
note "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
