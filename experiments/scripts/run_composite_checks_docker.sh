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
# Usage (from experiments/scripts/):  bash run_composite_checks_docker.sh
# then:                                python3 aggregate.py --scenario=composite_checks

set -euo pipefail
IMAGE="${IMAGE:-seal-env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GRID_HOST="${GRID:-$EXPERIMENTS_DIR/config/param_grid_composite.csv}"
GRID_CONTAINER="/work/config/$(basename "$GRID_HOST")"
RAW_DIR="$EXPERIMENTS_DIR/results/raw/composite_checks"
TRACE_REPS=10
mkdir -p "$RAW_DIR"

run() {  # $1 = tag, rest = bench_seal args
    local TAG="$1"; shift
    if [ -f "$RAW_DIR/${TAG}.csv" ] && [ "$(tail -n +2 "$RAW_DIR/${TAG}.csv" | wc -l)" -ge "$TRACE_REPS" ]; then
        echo "SKIPPED (already complete): ${TAG}.csv"; return
    fi
    echo ">> $TAG"
    docker run --rm -v "$EXPERIMENTS_DIR":/work "$IMAGE" /work/seal/build/bench_seal "$@" \
        --trace-reps="$TRACE_REPS" --out="/work/results/raw/composite_checks/${TAG}.csv" \
        --grid="$GRID_CONTAINER" || echo "   (non-zero exit — check $TAG)"
}

tail -n +2 "$GRID_HOST" | while IFS=, read -r N CATEGORY SEC CHAIN LOGQ DEPTH; do
    for SCHEME in BFV BGV CKKS; do
      for INPUTS in fixed random; do
        SUF=""; [ "$INPUTS" = "random" ] && SUF="_random"
        BASE="seal_${SCHEME,,}_N${N}_cat${CATEGORY}"
        run "${BASE}_poly_eval_check${SUF}" --scheme="$SCHEME" --N="$N" --category="$CATEGORY" \
            --operation=poly_eval_check --check-inputs="$INPUTS"
        # same vector lengths as run_composite_docker.sh (CKKS slot count is N/2)
        if [ "$SCHEME" = "CKKS" ]; then VLS="8 64 512 $((N / 2))"; else VLS="8 64 512 $N"; fi
        for VL in $VLS; do
            run "${BASE}_dot_product_check_veclen${VL}${SUF}" --scheme="$SCHEME" --N="$N" --category="$CATEGORY" \
                --operation=dot_product_check --vec-len="$VL" --check-inputs="$INPUTS"
        done
      done
    done
done
# Negative control: the same check at a configuration where it SHOULD fail
# (N=4096/category 1: about 7-8 bits (BFV) and 0-6 bits (BGV) of noise
# budget left after one multiplication, then 12 rotate-and-add steps), to
# show the check detects wrong results rather than always passing. Not part
# of the composite results; aggregated separately.
NEG_DIR="$EXPERIMENTS_DIR/results/raw/composite_checks_negative"
mkdir -p "$NEG_DIR"
for SCHEME in BFV BGV; do
    TAG="seal_${SCHEME,,}_N4096_cat1_dot_product_check_veclen4096_random"
    if [ -f "$NEG_DIR/${TAG}.csv" ] && [ "$(tail -n +2 "$NEG_DIR/${TAG}.csv" | wc -l)" -ge "$TRACE_REPS" ]; then
        echo "SKIPPED (already complete): ${TAG}.csv"; continue
    fi
    echo ">> negative control: $TAG"
    docker run --rm -v "$EXPERIMENTS_DIR":/work "$IMAGE" /work/seal/build/bench_seal \
        --scheme="$SCHEME" --N=4096 --category=1 --operation=dot_product_check --vec-len=4096 \
        --check-inputs=random --trace-reps="$TRACE_REPS" \
        --out="/work/results/raw/composite_checks_negative/${TAG}.csv" \
        --grid=/work/config/param_grid.csv || echo "   (non-zero exit — check $TAG)"
done

echo "Composite checks complete. Raw CSVs in $RAW_DIR (negative control in $NEG_DIR)."
