#!/usr/bin/env bash
# run_composite_checks_docker.sh — decrypt-and-compare correctness checks for
# the Composite workloads (bench_seal --operation=dot_product_check /
# poly_eval_check), added in round 4 of the supervisor's review.
#
# The main Composite runs (run_composite_docker.sh) timed the dot product
# and the polynomial evaluation; only BFV/BGV dot products were checked
# there. These checks run the SAME workload functions (same setup, timed
# region and keys) for TRACE_REPS trials and record only the verdict:
# exact match mod t for BFV/BGV, normalized error
# |decoded - expected| / max(1, |expected|) < 1e-2 for CKKS (the project's
# CKKS_CORRECTNESS_THRESHOLD). No latency/energy is recorded, so no sudo.
#
# Two input sets (round 5): "fixed" = the timing runs' own inputs (dot
# product a_i=i+1, b_i=i+2 -- x0.01 for CKKS; polynomial x in {0,1} for
# BFV/BGV, uniform [-1,1] for CKKS); "random" = --check-inputs=random,
# uniform over the whole plaintext range [0,t) for BFV/BGV and uniform
# [-1,1] for CKKS, drawn from the harness's seeded generator (varied
# across trials, reproducible).
#
# Two kinds of failure are kept strictly apart (round 6):
#   * a WRONG RESULT detected by a check is a valid outcome: the program
#     exits 0 and the row says correctness=MISMATCH;
#   * a PROGRAM OR DOCKER FAILURE (non-zero exit, missing or incomplete
#     output) is never a result: the partial file is deleted (so a later
#     resume cannot mistake it for a finished cell), the cell is listed in
#     $RAW_DIR/FAILED_CELLS.txt, and the script exits non-zero at the end.
# A cell counts as complete only if its file has exactly TRACE_REPS rows,
# all with status=measured and correctness in {correct, MISMATCH}.
#
# Usage (from experiments/scripts/):  bash run_composite_checks_docker.sh
# then:                                python3 aggregate.py --scenario=composite_checks

set -euo pipefail
IMAGE="${IMAGE:-seal-env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GRID_HOST="${GRID:-$EXPERIMENTS_DIR/config/param_grid_composite.csv}"
GRID_CONTAINER="/work/config/$(basename "$GRID_HOST")"
RAW_DIR="$EXPERIMENTS_DIR/results/raw/composite_checks"
NEG_DIR="$EXPERIMENTS_DIR/results/raw/composite_checks_negative"
TRACE_REPS=10
FAILED="$RAW_DIR/FAILED_CELLS.txt"
mkdir -p "$RAW_DIR" "$NEG_DIR"
rm -f "$FAILED"

# 0 if $1 is a complete, well-formed check file (see header).
complete() {
    [ -f "$1" ] || return 1
    awk -F, -v want="$TRACE_REPS" '
        NR == 1 { for (i = 1; i <= NF; i++) { if ($i == "correctness") c = i; if ($i == "status") s = i }; next }
        { n++; if ($s != "measured" || ($c != "correct" && $c != "MISMATCH")) bad = 1 }
        END { exit (c && s && n == want && !bad) ? 0 : 1 }' "$1"
}

# $1 = output dir, $2 = tag, $3 = container grid, rest = bench_seal args
run() {
    local DIR="$1" TAG="$2" GRIDC="$3"; shift 3
    local OUT="$DIR/${TAG}.csv"
    if complete "$OUT"; then echo "SKIPPED (complete): ${TAG}.csv"; return; fi
    rm -f "$OUT"
    echo ">> $TAG"
    local REL="${DIR#"$EXPERIMENTS_DIR"/}"
    if docker run --rm -v "$EXPERIMENTS_DIR":/work "$IMAGE" /work/seal/build/bench_seal "$@" \
            --trace-reps="$TRACE_REPS" --out="/work/$REL/${TAG}.csv" --grid="$GRIDC" \
       && complete "$OUT"; then
        return
    fi
    echo "   PROGRAM/DOCKER FAILURE (not a check result): $TAG" >&2
    rm -f "$OUT"
    echo "$TAG" >> "$FAILED"
}

tail -n +2 "$GRID_HOST" | while IFS=, read -r N CATEGORY SEC CHAIN LOGQ DEPTH; do
    for SCHEME in BFV BGV CKKS; do
      for INPUTS in fixed random; do
        SUF=""; [ "$INPUTS" = "random" ] && SUF="_random"
        BASE="seal_${SCHEME,,}_N${N}_cat${CATEGORY}"
        run "$RAW_DIR" "${BASE}_poly_eval_check${SUF}" "$GRID_CONTAINER" \
            --scheme="$SCHEME" --N="$N" --category="$CATEGORY" \
            --operation=poly_eval_check --check-inputs="$INPUTS"
        # same vector lengths as run_composite_docker.sh (CKKS slot count is N/2)
        if [ "$SCHEME" = "CKKS" ]; then VLS="8 64 512 $((N / 2))"; else VLS="8 64 512 $N"; fi
        for VL in $VLS; do
            run "$RAW_DIR" "${BASE}_dot_product_check_veclen${VL}${SUF}" "$GRID_CONTAINER" \
                --scheme="$SCHEME" --N="$N" --category="$CATEGORY" \
                --operation=dot_product_check --vec-len="$VL" --check-inputs="$INPUTS"
        done
      done
    done
done

# Negative control: the same check at a configuration where it SHOULD fail
# (N=4096/category 1: about 7-8 bits (BFV) and 0-6 bits (BGV) of noise
# budget left after one multiplication, then 12 rotate-and-add steps), to
# show the check detects wrong results rather than always passing. Not part
# of the composite results; aggregated separately. A MISMATCH here is the
# expected outcome; a program failure is still a failure.
for SCHEME in BFV BGV; do
    run "$NEG_DIR" "seal_${SCHEME,,}_N4096_cat1_dot_product_check_veclen4096_random" \
        /work/config/param_grid.csv \
        --scheme="$SCHEME" --N=4096 --category=1 --operation=dot_product_check \
        --vec-len=4096 --check-inputs=random
done

if [ -s "$FAILED" ]; then
    echo "ERROR: $(wc -l < "$FAILED") cell(s) failed to RUN (program or Docker error, not a" >&2
    echo "       check result) -- listed in $FAILED. Their outputs were removed." >&2
    exit 1
fi
echo "Composite checks complete: every cell ran to completion. Raw CSVs in $RAW_DIR"
echo "(negative control in $NEG_DIR). Next: python3 aggregate.py --scenario=composite_checks"
