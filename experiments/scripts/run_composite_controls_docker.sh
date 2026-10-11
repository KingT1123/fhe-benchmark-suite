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

FAILED="$RAW_DIR/FAILED_CELLS.txt"
mkdir -p "$RAW_DIR"
rm -f "$FAILED"

# Program/Docker failures are kept apart from results (round 6, same rule as
# run_composite_checks_docker.sh): a cell is complete only with exactly the
# expected row count, all status=measured and correctness in {correct,
# MISMATCH}; a failed run's partial file is deleted, the cell is listed in
# $FAILED, and the script exits non-zero at the end.
complete() {  # $1 = file, $2 = expected data rows
    [ -f "$1" ] || return 1
    awk -F, -v want="$2" '
        NR == 1 { for (i = 1; i <= NF; i++) { if ($i == "correctness") c = i; if ($i == "status") s = i }; next }
        { n++; if ($s != "measured" || ($c != "correct" && $c != "MISMATCH")) bad = 1 }
        END { exit (c && s && n == want && !bad) ? 0 : 1 }' "$1"
}

ceil_log2() { local n=$1 k=0 p=1; while [ "$p" -lt "$n" ]; do p=$((p * 2)); k=$((k + 1)); done; echo "$k"; }

tail -n +2 "$GRID_HOST" | while IFS=, read -r N CATEGORY SEC CHAIN LOGQ DEPTH; do
    for SCHEME in BFV BGV; do
        for OP in rotate_only add_only; do
            for VL in "${VEC_LENS[@]}"; do
                TAG="seal_${SCHEME,,}_N${N}_cat${CATEGORY}_${OP}_veclen${VL}"
                OUT_HOST="$RAW_DIR/${TAG}.csv"
                EXPECTED=$((TRACE_REPS * ($(ceil_log2 "$VL") + 1)))
                if complete "$OUT_HOST" "$EXPECTED"; then
                    echo "SKIPPED (complete): ${TAG}.csv"
                    continue
                fi
                rm -f "$OUT_HOST"
                echo ">> $TAG"
                if ! { docker run --rm -v "$EXPERIMENTS_DIR":/work "$IMAGE" \
                        /work/seal/build/bench_seal --scheme="$SCHEME" --N="$N" --category="$CATEGORY" \
                        --operation="$OP" --vec-len="$VL" --trace-reps="$TRACE_REPS" \
                        --out="/work/results/raw/composite_controls/${TAG}.csv" --grid="$GRID_CONTAINER" \
                       && complete "$OUT_HOST" "$EXPECTED"; }; then
                    echo "   PROGRAM/DOCKER FAILURE (not a result): $TAG" >&2
                    rm -f "$OUT_HOST"
                    echo "$TAG" >> "$FAILED"
                fi
            done
        done
    done
done

if [ -s "$FAILED" ]; then
    echo "ERROR: $(wc -l < "$FAILED") cell(s) failed to RUN (program or Docker error) -- listed in $FAILED." >&2
    exit 1
fi
echo "Composite noise controls complete. Raw CSVs in $RAW_DIR."
echo "Next: python3 $SCRIPT_DIR/aggregate.py --scenario=composite_controls"
