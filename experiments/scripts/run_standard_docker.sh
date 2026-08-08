#!/usr/bin/env bash
# run_standard_docker.sh — Scenario A (standard/unconstrained), through Docker.
#
# Run this on your HOST machine. For each (scheme, N, category, operation)
# cell: runs a `docker run` (which itself runs _inner_measure.sh for peak
# memory), and reads /sys/class/powercap/intel-rapl:0/energy_uj directly
# before/after for energy -- more reliable than perf's power PMU, which needs
# extra permissions on top of perf_event_paranoid. This sysfs file exists on
# this machine even though it's AMD, not Intel: AMD's newer chips expose
# RAPL-compatible registers that the kernel reports through the same driver.

set -euo pipefail
IMAGE="${IMAGE:-seal-env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GRID="$EXPERIMENTS_DIR/config/param_grid.csv"
RAW_DIR="$EXPERIMENTS_DIR/results/raw"
LOG_DIR="$EXPERIMENTS_DIR/results/logs/standard"
REPS=100
WARMUP=5

RAPL_ENERGY_FILE="/sys/class/powercap/intel-rapl:0/energy_uj"
RAPL_MAX_FILE="/sys/class/powercap/intel-rapl:0/max_energy_range_uj"

mkdir -p "$RAW_DIR" "$LOG_DIR"

if [ ! -x "$EXPERIMENTS_DIR/seal/build/bench_seal" ]; then
    echo "ERROR: bench_seal not built yet. Run docker_build_and_run.sh first." >&2
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
OPERATIONS=("keygen" "encrypt" "decrypt" "add" "multiply" "relinearize")

tail -n +2 "$GRID" | while IFS=, read -r N CATEGORY SEC CHAIN LOGQ DEPTH; do
    for SCHEME in "${SCHEMES[@]}"; do
        for OP in "${OPERATIONS[@]}"; do
            TAG="seal_${SCHEME,,}_N${N}_cat${CATEGORY}_${OP}"
            OUT_CSV="/work/results/raw/${TAG}.csv"
            MEM_LOG="/work/results/logs/standard/${TAG}_mem.log"
            ENERGY_LOG="$LOG_DIR/${TAG}_energy.log"

            echo ">> $TAG"

            DOCKER_CMD=(docker run --rm -v "$EXPERIMENTS_DIR":/work "$IMAGE" \
                bash /work/scripts/_inner_measure.sh /work/seal/build/bench_seal "$MEM_LOG" \
                --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation="$OP" \
                --reps="$REPS" --warmup="$WARMUP" --out="$OUT_CSV" \
                --grid=/work/config/param_grid.csv)

            if [ "$HAVE_RAPL" -eq 1 ]; then
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
        done
    done
done

echo "Scenario A sweep complete. Raw CSVs in $RAW_DIR, logs in $LOG_DIR."
echo "Next: python3 $SCRIPT_DIR/aggregate.py --scenario=standard"
