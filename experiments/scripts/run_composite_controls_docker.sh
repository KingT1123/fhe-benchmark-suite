#!/usr/bin/env bash
# run_composite_controls_docker.sh — the Composite scenario's isolated
# rotate-only / add-only noise controls (bench_seal --operation=rotate_only /
# add_only, see bench_seal.cpp's header comment), through Docker.
#
# dot_product's noise-budget decline mixes k = ceil_log2(vec_len) rotations
# and k additions; these controls run ONLY the rotations or ONLY the
# additions, same k and same shifts, so the decline can be attributed.
# BFV/BGV only (CKKS has no noise-budget API), N=8192/category 1 only (the
# Composite scenario's scope, param_grid_composite.csv), same vec_len sweep
# as run_composite_docker.sh's dot_product.
#
# Noise-budget bit counts only -- no latency, energy or memory is measured,
# so no RAPL, no sudo, no core pinning (same reasoning as
# run_extended_metrics_docker.sh). Resume: an existing raw CSV with the
# full expected row count is skipped.
#
# Usage (from experiments/scripts/):  bash run_composite_controls_docker.sh
# then:                                python3 aggregate.py --scenario=composite_controls

set -euo pipefail
IMAGE="${IMAGE:-seal-env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GRID_HOST="${GRID:-$EXPERIMENTS_DIR/config/param_grid_composite.csv}"
GRID_CONTAINER="/work/config/$(basename "$GRID_HOST")"
RAW_DIR="$EXPERIMENTS_DIR/results/raw/composite_controls"
TRACE_REPS=10
VEC_LENS=(8 64 512 8192)

mkdir -p "$RAW_DIR"

ceil_log2() { local n=$1 k=0 p=1; while [ "$p" -lt "$n" ]; do p=$((p * 2)); k=$((k + 1)); done; echo "$k"; }

tail -n +2 "$GRID_HOST" | while IFS=, read -r N CATEGORY SEC CHAIN LOGQ DEPTH; do
    for SCHEME in BFV BGV; do
        for OP in rotate_only add_only; do
            for VL in "${VEC_LENS[@]}"; do
                TAG="seal_${SCHEME,,}_N${N}_cat${CATEGORY}_${OP}_veclen${VL}"
                OUT_HOST="$RAW_DIR/${TAG}.csv"
                EXPECTED=$((TRACE_REPS * ($(ceil_log2 "$VL") + 1)))
                if [ -f "$OUT_HOST" ] && [ "$(tail -n +2 "$OUT_HOST" | wc -l)" -ge "$EXPECTED" ]; then
                    echo "SKIPPED (already complete): ${TAG}.csv"
                    continue
                fi
                echo ">> $TAG"
                docker run --rm -v "$EXPERIMENTS_DIR":/work "$IMAGE" \
                    /work/seal/build/bench_seal --scheme="$SCHEME" --N="$N" --category="$CATEGORY" \
                    --operation="$OP" --vec-len="$VL" --trace-reps="$TRACE_REPS" \
                    --out="/work/results/raw/composite_controls/${TAG}.csv" --grid="$GRID_CONTAINER" \
                    || echo "   (non-zero exit — check $TAG)"
            done
        done
    done
done

echo "Composite noise controls complete. Raw CSVs in $RAW_DIR."
echo "Next: python3 $SCRIPT_DIR/aggregate.py --scenario=composite_controls"
