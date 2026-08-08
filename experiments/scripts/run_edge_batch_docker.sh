#!/usr/bin/env bash
# run_edge_batch_docker.sh — Edge/Batch scenario, through Docker.
#
# Per Chapter 3: "packs multiple values per ciphertext and measures
# throughput on the baseline workstation" -- a multi-user/streaming
# scenario, not an IoT scenario, despite the name. Decision log:
#   (a) Runs on FULL resources, like Scenario A -- no --cpuset-cpus/--memory
#       cap. (Scenario B already showed the resource ceiling doesn't bind
#       on this hardware anyway, so this isolates "does batching change
#       throughput" as its own variable.)
#   (b) Batch sizes swept: 1, 10, 100.
#   (c) Repetitions are reduced at larger batch sizes to keep total sweep
#       time bounded (a batch-size-100 trial does 100x the work of a
#       batch-size-1 trial). This is recorded plainly in the raw CSVs
#       (however many rows each file has), the same honest-limitation
#       spirit as the existing n=1_invocation_not_repeated energy/memory
#       flag -- aggregate.py's future edge_batch mode should flag any cell
#       with fewer than the batch=1 rep count, the same way it already
#       flags HIGH_VARIANCE.
#   (d) keygen is batch-size-invariant (see bench_seal.cpp), so it's run
#       ONCE per (scheme, N, category) here, not once per batch size --
#       amortized keygen-per-item rows are a downstream aggregate.py
#       computation (keygen_ms / batch_size), not a re-measurement.
#
# Raw CSVs and logs go to *separate* subdirectories (results/raw/edge_batch,
# results/logs/edge_batch) rather than the shared results/raw/ used by
# Scenario A/B. This is deliberate: aggregate.py's standard-scenario file
# glob is `seal_*.csv` minus anything containing "_constrained" -- an
# edge/batch filename wouldn't contain that substring either, so sharing
# the flat raw/ directory would let these files get silently swept into a
# future `aggregate.py --scenario=standard` re-run. A subdirectory is
# invisible to glob.glob() without recursive=True, so this can't happen.
#
# NOTE: aggregate.py does not yet have a --scenario=edge_batch mode. This
# script only produces the raw data; deriving throughput_ops_per_sec and
# keygen_amortized_ms rows is a separate, not-yet-written step.

set -euo pipefail
IMAGE="${IMAGE:-seal-env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GRID="$EXPERIMENTS_DIR/config/param_grid.csv"
RAW_DIR="$EXPERIMENTS_DIR/results/raw/edge_batch"
LOG_DIR="$EXPERIMENTS_DIR/results/logs/edge_batch"

RAPL_ENERGY_FILE="/sys/class/powercap/intel-rapl:0/energy_uj"
RAPL_MAX_FILE="/sys/class/powercap/intel-rapl:0/max_energy_range_uj"

mkdir -p "$RAW_DIR" "$LOG_DIR"

if [ ! -x "$EXPERIMENTS_DIR/seal/build/bench_seal" ]; then
    echo "ERROR: bench_seal not built yet (or stale -- rebuild after the" >&2
    echo "  --batch-size change). Run docker_build_and_run.sh first." >&2
    exit 1
fi

HAVE_RAPL=1
if [ ! -r "$RAPL_ENERGY_FILE" ]; then
    echo "WARNING: cannot read $RAPL_ENERGY_FILE."
    echo "  Try re-running this whole script with sudo."
    echo "  Energy columns will be empty for this run."
    HAVE_RAPL=0
    MAX_ENERGY_UJ=0
else
    MAX_ENERGY_UJ=$(cat "$RAPL_MAX_FILE" 2>/dev/null || echo 0)
    echo "RAPL OK: reading energy from $RAPL_ENERGY_FILE ($(cat /sys/class/powercap/intel-rapl:0/name 2>/dev/null))"
fi

SCHEMES=("BFV" "CKKS")
BATCH_OPERATIONS=("encrypt" "decrypt" "add" "multiply" "relinearize")
BATCH_SIZES=(1 10 100)

# (c) reps/warmup shrink as batch size grows, so total work per cell
# (batch_size * reps) doesn't blow up the sweep's wall-clock time.
declare -A REPS_FOR_BATCH=(  [1]=100 [10]=30 [100]=10 )
declare -A WARMUP_FOR_BATCH=([1]=5   [10]=3  [100]=2  )

run_one() {
    local TAG="$1"; shift
    local OUT_CSV="/work/results/raw/edge_batch/${TAG}.csv"
    local MEM_LOG="/work/results/logs/edge_batch/${TAG}_mem.log"
    local ENERGY_LOG="$LOG_DIR/${TAG}_energy.log"

    echo ">> $TAG"

    local DOCKER_CMD=(docker run --rm -v "$EXPERIMENTS_DIR":/work "$IMAGE" \
        bash /work/scripts/_inner_measure.sh /work/seal/build/bench_seal "$MEM_LOG" \
        "$@" --out="$OUT_CSV" --grid=/work/config/param_grid.csv)

    if [ "$HAVE_RAPL" -eq 1 ]; then
        local E_BEFORE E_AFTER DELTA_UJ DELTA_J
        E_BEFORE=$(cat "$RAPL_ENERGY_FILE")
        "${DOCKER_CMD[@]}" || echo "   (non-zero exit — check logs)"
        E_AFTER=$(cat "$RAPL_ENERGY_FILE")
        if [ "$E_AFTER" -ge "$E_BEFORE" ]; then
            DELTA_UJ=$((E_AFTER - E_BEFORE))
        else
            DELTA_UJ=$((E_AFTER + MAX_ENERGY_UJ - E_BEFORE))  # counter wrapped
        fi
        DELTA_J=$(awk "BEGIN{printf \"%.6f\", $DELTA_UJ/1000000}")
        echo "$DELTA_J Joules power/energy-pkg/" > "$ENERGY_LOG"
    else
        "${DOCKER_CMD[@]}" || echo "   (non-zero exit — check logs)"
    fi
}

tail -n +2 "$GRID" | while IFS=, read -r N CATEGORY SEC CHAIN LOGQ DEPTH; do
    for SCHEME in "${SCHEMES[@]}"; do
        # (d) keygen: once per cell, batch-size-invariant.
        run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_keygen_batch1" \
            --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation=keygen \
            --reps=100 --warmup=5 --batch-size=1

        for OP in "${BATCH_OPERATIONS[@]}"; do
            for B in "${BATCH_SIZES[@]}"; do
                run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_${OP}_batch${B}" \
                    --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation="$OP" \
                    --reps="${REPS_FOR_BATCH[$B]}" --warmup="${WARMUP_FOR_BATCH[$B]}" \
                    --batch-size="$B"
            done
        done
    done
done

echo "Edge/Batch sweep complete. Raw CSVs in $RAW_DIR, logs in $LOG_DIR."
echo "aggregate.py does not yet support --scenario=edge_batch -- that's the next step, not run here."
