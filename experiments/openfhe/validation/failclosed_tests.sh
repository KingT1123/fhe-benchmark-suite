#!/usr/bin/env bash
# failclosed_tests.sh — demonstrates the fail-closed behaviour of the session
# runner (run_pilot_docker.sh + session_lib.sh) and of the aggregation, on
# small dry-run sessions (2 repetitions after 1 warm-up; no sudo; timings not
# used). Writes validation/failclosed_tests.log; exit status 0 only if every
# test behaved as required:
#   1. resume after damage: a truncated cell and a cell with a leftover .tmp
#      are detected, moved to invalid/ (kept) and re-measured; valid cells
#      are skipped;
#   2. a wrong result (injected) stops the whole session at once: non-zero
#      exit, no later cell runs, no output file for the failed cell;
#   3. resuming the stopped session re-measures the failed cell and finishes;
#   4. aggregation excludes a truncated cell and a cell with a MISMATCH row.
# Usage:  bash experiments/openfhe/validation/failclosed_tests.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EXP="$(cd "$HERE/../.." && pwd)"
LOG="$HERE/failclosed_tests.log"
cd "$EXP"
clean() { docker run --rm -v "$EXP/results":/r seal-env rm -rf /r/raw/_fc1 /r/logs/_fc1 /r/raw/_fc2 /r/logs/_fc2 /r/raw/_fc4; }
clean
: > "$LOG"
note() { echo "$*" | tee -a "$LOG"; }
fails=0; req() { if eval "$1"; then note "  PASS: $2"; else note "  FAIL: $2"; fails=$((fails + 1)); fi; }
run() { env PILOT_NAME="$1" REPS=2 WARMUP=1 INNER_LOOP=5 RUN_ORDER_SEED=1 "${@:2}" bash openfhe/run_pilot_docker.sh; }
note "fail-closed tests $(date -Iseconds); code commit $(git -C "$EXP/.." rev-parse --short HEAD)"

note "TEST 1: resume with a truncated cell and a leftover .tmp"
run _fc1 > /dev/null 2>&1
docker run --rm -v "$EXP/results":/r seal-env bash -c \
  'f=/r/raw/_fc1/seal_ckks_N8192_cat1_add.csv; head -2 $f > /tmp/x && cp /tmp/x $f; touch /r/raw/_fc1/openfhe_ckks_N8192_cat1_rotate.csv.tmp'
out=$(run _fc1 2>&1); rc=$?
echo "$out" | grep -E "NOT valid|moved" | sed 's/^/    /' | tee -a "$LOG"
req "[ $rc -eq 0 ]" "session completes (exit $rc)"
req "[ $(echo "$out" | grep -c 'NOT valid') -eq 2 ]" "both damaged cells detected"
req "[ $(echo "$out" | grep -c 'SKIPPED (valid') -eq 20 ]" "the 20 valid cells skipped"
req "[ $(find results/raw/_fc1/invalid -type f | wc -l) -ge 2 ]" "damaged files kept in invalid/"

note "TEST 2: wrong result injected into openfhe add"
out=$(run _fc2 INJECT_TAG=openfhe_ckks_N8192_cat1_add INJECT_AT=1 2>&1); rc=$?
echo "$out" | grep -E "ERROR|STOPPED" | sed 's/^/    /' | tee -a "$LOG"
req "[ $rc -ne 0 ]" "session stops with a non-zero exit ($rc)"
req "[ ! -e results/raw/_fc2/openfhe_ckks_N8192_cat1_add.csv ]" "no output file for the failed cell"
req "[ \"\$(echo \"\$out\" | grep '^\[' | tail -1 | grep -c openfhe_ckks_N8192_cat1_add)\" -eq 1 ]" "no cell runs after the failure"

note "TEST 3: resume the stopped session without injection"
out=$(run _fc2 2>&1); rc=$?
req "[ $rc -eq 0 ]" "session completes (exit $rc)"
nbad=0
for f in results/raw/_fc2/*_ckks_*.csv; do t=$(basename "$f" .csv)
    python3 scripts/validate_cell.py "$f" --rows 3 --warmup 1 --check "results/raw/_fc2/checks/${t}_check.csv" >/dev/null || nbad=$((nbad + 1)); done
req "[ $(ls results/raw/_fc2/*_ckks_*.csv | wc -l) -eq 22 ] && [ $nbad -eq 0 ]" "all 22 cells present and valid"

note "TEST 4: aggregation of a session with a truncated cell and a MISMATCH row"
mkdir -p results/raw/_fc4 && cp -r results/raw/_fc1/. results/raw/_fc4/ && chmod -R u+w results/raw/_fc4
head -3 results/raw/_fc4/seal_ckks_N8192_cat1_add.csv > /tmp/fc4 && mv /tmp/fc4 results/raw/_fc4/seal_ckks_N8192_cat1_add.csv
sed -i '2s/correct$/MISMATCH/' results/raw/_fc4/checks/openfhe_ckks_N8192_cat1_rotate_check.csv
out=$(cd scripts && python3 aggregate.py --scenario=pilot --raw-dir=../results/raw/_fc4 --out=../results/raw/_fc4/agg.csv 2>&1)
echo "$out" | grep EXCLUDED | sed 's/^/    /' | tee -a "$LOG"
req "[ $(echo "$out" | grep -c EXCLUDED) -eq 2 ]" "both invalid cells excluded"
req "[ $(grep -cE 'SEAL,CKKS,8192,1,add,40|OpenFHE,CKKS,8192,1,rotate,40' results/raw/_fc4/agg.csv) -eq 0 ]" "no statistics row for them"

clean
note "RESULT: $([ $fails -eq 0 ] && echo 'all tests passed' || echo "$fails test(s) FAILED")"
[ $fails -eq 0 ]
