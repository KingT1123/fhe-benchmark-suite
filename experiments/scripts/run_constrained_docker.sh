#!/usr/bin/env bash
# run_constrained_docker.sh — Scenario B (simulated resource-constrained), Docker.
#
# Reproduces the Raspberry Pi 4 Model B's resource CEILING (4 CPU cores,
# 4 GB RAM) using Docker's own --cpuset-cpus and --memory flags. Does NOT
# reproduce the Pi 4's ARM architecture (see Chapter 3, Sec 3.3).
#
# Energy via direct RAPL sysfs read (see run_standard_docker.sh for why).

set -euo pipefail
IMAGE="${IMAGE:-seal-env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GRID="$EXPERIMENTS_DIR/config/param_grid.csv"
RAW_DIR="$EXPERIMENTS_DIR/results/raw"
LOG_DIR="$EXPERIMENTS_DIR/results/logs/constrained"
REPS=100
WARMUP=5
CPUSET="0-3"
MEMLIMIT="4g"

RAPL_ENERGY_FILE="/sys/class/powercap/intel-rapl:0/energy_uj"
RAPL_MAX_FILE="/sys/class/powercap/intel-rapl:0/max_energy_range_uj"

mkdir -p "$RAW_DIR" "$LOG_DIR"

if [ ! -x "$EXPERIMENTS_DIR/seal/build/bench_seal" ]; then
    echo "ERROR: bench_seal not built yet. Run docker_build_and_run.sh first." >&2
    exit 1
fi

HAVE_RAPL=1
if [ ! -r "$RAPL_ENERGY_FILE" ]; then
    echo "WARNING: cannot read $RAPL_ENERGY_FILE. Try sudo. Energy columns will be empty."
    HAVE_RAPL=0
    MAX_ENERGY_UJ=0
else
    MAX_ENERGY_UJ=$(cat "$RAPL_MAX_FILE" 2>/dev/null || echo 0)
fi

SCHEMES=("BFV" "CKKS")
OPERATIONS=("keygen" "encrypt" "decrypt" "add" "multiply" "relinearize")

tail -n +2 "$GRID" | while IFS=, read -r N CATEGORY SEC CHAIN LOGQ DEPTH; do
    for SCHEME in "${SCHEMES[@]}"; do
        for OP in "${OPERATIONS[@]}"; do
            TAG="seal_${SCHEME,,}_N${N}_cat${CATEGORY}_${OP}"
            OUT_CSV="/work/results/raw/${TAG}_constrained.csv"
            MEM_LOG="/work/results/logs/constrained/${TAG}_mem.log"
            ENERGY_LOG="$LOG_DIR/${TAG}_energy.log"

            echo ">> $TAG (constrained: ${CPUSET}, ${MEMLIMIT})"

            DOCKER_CMD=(docker run --rm --cpuset-cpus="$CPUSET" --memory="$MEMLIMIT" \
                -v "$EXPERIMENTS_DIR":/work "$IMAGE" \
                bash /work/scripts/_inner_measure.sh /work/seal/build/bench_seal "$MEM_LOG" \
                --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation="$OP" \
                --reps="$REPS" --warmup="$WARMUP" --out="$OUT_CSV" \
                --grid=/work/config/param_grid.csv)

            if [ "$HAVE_RAPL" -eq 1 ]; then
                E_BEFORE=$(cat "$RAPL_ENERGY_FILE")
                "${DOCKER_CMD[@]}" || echo "   (non-zero exit — check logs, or OOM if it needed >4GB)"
                E_AFTER=$(cat "$RAPL_ENERGY_FILE")
                if [ "$E_AFTER" -ge "$E_BEFORE" ]; then
                    DELTA_UJ=$((E_AFTER - E_BEFORE))
                else
                    DELTA_UJ=$((E_AFTER + MAX_ENERGY_UJ - E_BEFORE))
                fi
                DELTA_J=$(awk "BEGIN{printf \"%.6f\", $DELTA_UJ/1000000}")
                echo "$DELTA_J Joules power/energy-pkg/" > "$ENERGY_LOG"
            else
                "${DOCKER_CMD[@]}" || echo "   (non-zero exit — check logs, or OOM if it needed >4GB)"
            fi
        done
    done
done

echo "Scenario B sweep complete. Raw CSVs in $RAW_DIR, logs in $LOG_DIR."
echo "Next: python3 $SCRIPT_DIR/aggregate.py --scenario=constrained"
