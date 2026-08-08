#!/usr/bin/env bash
# run_extended_metrics_docker.sh — Chapter 3's three previously-deferred
# metrics (storage, noise-budget evolution, CKKS error accumulation),
# through Docker.
#
# One Docker call per (scheme, N, category) cell PER METRIC -- not per the
# six timed operations from Scenario A/B/Edge-Batch. size/noise_trace/
# ckks_error each cover their own artifacts/steps internally in one call
# (see bench_seal.cpp's header comment), so the "one call = one cell"
# convention here means one call per (scheme, N, category, metric), not
# one call per (scheme, N, category, six-operations).
#
# No RAPL/peak-memory wrapping (unlike run_standard_docker.sh /
# run_edge_batch_docker.sh's use of _inner_measure.sh): these three are not
# latency/energy/memory measurements, so that machinery doesn't apply.
#
# noise_trace is BFV/BGV-only and ckks_error is CKKS-only, but this script
# invokes both operations for BOTH schemes uniformly -- the scheme-mismatch
# skip (skipped_not_applicable_ckks / skipped_not_applicable_bfv) is
# handled inside bench_seal.cpp itself (returns before build_context is
# even called), so the sweep script doesn't need its own branching for it.
#
# Raw CSVs go to results/raw/extended_metrics/ (a subdirectory, not the
# shared results/raw/), same reasoning as run_edge_batch_docker.sh: keeps
# these out of aggregate.py's --scenario=standard glob (`seal_*.csv` minus
# "_constrained" would otherwise silently sweep these in).
#
# --trace-reps=10 for both noise_trace and ckks_error: pinned explicitly
# here rather than relying on bench_seal's compiled-in default, since this
# is the actual value the sweep uses and should be visible/auditable, not
# implicit.
#
# Grid override: set GRID=/path/to/subset.csv (must live under
# experiments/config/ so it's inside the Docker mount) to sweep a subset
# instead of the full grid, e.g. for a small verification run before
# committing to the full 144-row sweep.

set -euo pipefail
IMAGE="${IMAGE:-seal-env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GRID_HOST="${GRID:-$EXPERIMENTS_DIR/config/param_grid.csv}"
GRID_CONTAINER="/work/config/$(basename "$GRID_HOST")"
RAW_DIR="$EXPERIMENTS_DIR/results/raw/extended_metrics"
TRACE_REPS=10

mkdir -p "$RAW_DIR"

if [ ! -x "$EXPERIMENTS_DIR/seal/build/bench_seal" ]; then
    echo "ERROR: bench_seal not built yet (or stale). Run docker_build_and_run.sh first." >&2
    exit 1
fi

SCHEMES=("BFV" "CKKS")

run_one() {
    local TAG="$1"; shift
    local OUT_CSV="/work/results/raw/extended_metrics/${TAG}.csv"
    echo ">> $TAG"
    docker run --rm -v "$EXPERIMENTS_DIR":/work "$IMAGE" \
        /work/seal/build/bench_seal "$@" --out="$OUT_CSV" --grid="$GRID_CONTAINER" \
        || echo "   (non-zero exit — check $TAG)"
}

tail -n +2 "$GRID_HOST" | while IFS=, read -r N CATEGORY SEC CHAIN LOGQ DEPTH; do
    for SCHEME in "${SCHEMES[@]}"; do
        run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_size" \
            --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation=size

        run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_noise_trace" \
            --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation=noise_trace \
            --trace-reps="$TRACE_REPS"

        run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_ckks_error" \
            --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation=ckks_error \
            --trace-reps="$TRACE_REPS"
    done
done

# ---- Consolidate the per-cell CSVs into three master raw files ----
# Simple concatenation (shared header once, then every cell's data rows),
# NOT statistics -- aggregate.py stays the only place stats get computed,
# per convention. The glob requires "_N*_cat*_" so it structurally cannot
# match the master output filenames themselves (seal_sizes.csv etc. have
# no "_N"/"_cat" segment) even on a re-run where they already exist.
consolidate() {
    local suffix="$1" outname="$2"
    local files=()
    while IFS= read -r -d '' f; do files+=("$f"); done < \
        <(find "$RAW_DIR" -maxdepth 1 -name "seal_*_N*_cat*_${suffix}.csv" -print0 | sort -z)

    if [ "${#files[@]}" -eq 0 ]; then
        echo "  WARNING: no per-cell files found for suffix '$suffix', skipping $outname" >&2
        return
    fi

    local first_header
    first_header=$(head -1 "${files[0]}")
    for f in "${files[@]}"; do
        if [ "$(head -1 "$f")" != "$first_header" ]; then
            echo "  ERROR: mismatched header in $f, aborting consolidation for $suffix" >&2
            return 1
        fi
    done

    { echo "$first_header"; for f in "${files[@]}"; do tail -n +2 "$f"; done; } > "$RAW_DIR/$outname"
    echo "  $outname: $(tail -n +2 "$RAW_DIR/$outname" | wc -l) data rows from ${#files[@]} files"
}

echo "-- Consolidating per-cell CSVs into master raw files --"
consolidate size seal_sizes.csv
consolidate noise_trace seal_noise_budget.csv
consolidate ckks_error seal_ckks_error.csv

echo "Extended metrics sweep complete. Raw CSVs in $RAW_DIR."
echo "Next: aggregate.py support for these three schemas (not yet written)."
