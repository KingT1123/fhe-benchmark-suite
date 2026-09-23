#!/usr/bin/env bash
# run_packing_docker.sh — Packing scenario, through Docker.
#
# Chapter 3's "how many of a ciphertext's AVAILABLE slots hold a real value,
# as opposed to zero-padding" question — deliberately separate from
# Edge/Batch's "how many separate ciphertexts" axis (run_edge_batch_docker.sh
# already covers that one). Structure/conventions mirror
# run_edge_batch_docker.sh as closely as possible on purpose (GRID override,
# resume/skip-if-complete, CPU governor/pinning logging), rather than
# inventing new patterns for what is, mechanically, the same kind of sweep.
#
# Scope (deliberately narrow — see the task this was written for): N=8192,
# category=1 only, all three schemes, four fill levels, three operations
# (encrypt, add, multiply — keygen/decrypt/relinearize skipped, not central
# to the packing question). Scoped via its own small grid file
# (../config/param_grid_packing.csv, a single row identical to
# param_grid.csv's own N=8192/category=1 row) rather than editing any
# existing grid or run_*.sh script.
#
# Fill levels: "1" (n_real=1, a literal single value — passed to bench_seal
# as --fill-pct=0.0, which floors to n_real=1 via bench_seal's own
# max(1, round(fill_pct * slot_count)) formula, not a separate code path —
# see bench_seal.cpp's --fill-pct header comment) and 0.10/0.50/1.00
# (percentages of slot_count). FILL_PCT_FOR_LEVEL maps the human-readable
# level to the --fill-pct value bench_seal actually receives.
#
# Raw CSVs and logs go to their own subdirectories (results/raw/packing,
# results/logs/packing), same "invisible to aggregate.py's flat seal_*.csv
# glob" isolation reasoning as run_edge_batch_docker.sh's own header comment.
#
# Timing protocol: same as Standard/Constrained — 100 reps, 5 warmup
# (EXPECTED_ROWS=105), not edge_batch's per-batch-size reduced-rep scheme
# (fill level isn't a work-multiplier the way batch size is: one encrypt/
# add/multiply call costs about the same regardless of how many of its
# slots are real vs. zero-padded, so there's no reason to shrink reps here).
# size is deterministic (no reps loop), EXPECTED_ROWS=1, mirroring
# run_extended_metrics_docker.sh's own size handling.

set -euo pipefail
IMAGE="${IMAGE:-seal-env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Grid override: set GRID=/path/to/subset.csv (must live under
# experiments/config/ so it's inside the Docker mount) -- same convention as
# run_standard_docker.sh/run_extended_metrics_docker.sh. Defaults to
# Packing's own small grid (N=8192/category=1 only), NOT param_grid.csv.
GRID_HOST="${GRID:-$EXPERIMENTS_DIR/config/param_grid_packing.csv}"
GRID_CONTAINER="/work/config/$(basename "$GRID_HOST")"
RAW_DIR="$EXPERIMENTS_DIR/results/raw/packing"
LOG_DIR="$EXPERIMENTS_DIR/results/logs/packing"
TASKSET_CORE="${TASKSET_CORE:-0}"
REPS=100
WARMUP=5
EXPECTED_ROWS=$((REPS + WARMUP))  # resume support, same convention as
                        # run_standard_docker.sh -- a cell's output CSV is
                        # only "complete" once it has this many data rows.

RAPL_ENERGY_FILE="/sys/class/powercap/intel-rapl:0/energy_uj"
RAPL_MAX_FILE="/sys/class/powercap/intel-rapl:0/max_energy_range_uj"

mkdir -p "$RAW_DIR" "$LOG_DIR"

# Document host CPU governor/boost state per run -- see run_standard_docker.sh
# for why and for the acpi-cpufreq/amd_pstate vs. intel_pstate fallback logic.
GOVERNOR_FILE="/sys/devices/system/cpu/cpu${TASKSET_CORE}/cpufreq/scaling_governor"
BOOST_FILE="/sys/devices/system/cpu/cpufreq/boost"
INTEL_NOTURBO_FILE="/sys/devices/system/cpu/intel_pstate/no_turbo"
CPU_STATE_LOG="$LOG_DIR/cpu_state.txt"

# --- Extra-rigor item 5: ENFORCE the governor (same pattern as
# run_standard_docker.sh).
ORIGINAL_GOVERNOR="$(cat "$GOVERNOR_FILE" 2>/dev/null || echo "")"
GOVERNOR_ENFORCED=0
if [ -n "$ORIGINAL_GOVERNOR" ]; then
    if echo performance > "$GOVERNOR_FILE" 2>/dev/null; then
        GOVERNOR_ENFORCED=1
    else
        echo "WARNING: could not write $GOVERNOR_FILE (needs root) -- governor NOT enforced, only logged below." >&2
    fi
fi

# --- Extra-rigor item 7: periodic CPU temperature logging (same pattern as
# run_standard_docker.sh).
TEMP_LOG="$LOG_DIR/temperature_log.csv"
TEMP_SOURCE=""
for zone in /sys/class/thermal/thermal_zone*/; do
    if [ -r "${zone}type" ] && grep -qiE "x86_pkg_temp|cpu" "${zone}type" 2>/dev/null && [ -r "${zone}temp" ]; then
        TEMP_SOURCE="${zone}temp"; break
    fi
done
if [ -z "$TEMP_SOURCE" ]; then
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$zone" ] && TEMP_SOURCE="$zone" && break
    done
fi
TEMP_LOGGER_PID=""
if [ -n "$TEMP_SOURCE" ]; then
    echo "timestamp,temp_millic,source" > "$TEMP_LOG"
    ( while true; do
          echo "$(date -Iseconds),$(cat "$TEMP_SOURCE" 2>/dev/null || echo ''),$TEMP_SOURCE" >> "$TEMP_LOG"
          sleep 5
      done ) &
    TEMP_LOGGER_PID=$!
    echo "Temperature logging started (PID $TEMP_LOGGER_PID, source=$TEMP_SOURCE) -> $TEMP_LOG"
else
    echo "WARNING: no readable /sys/class/thermal/thermal_zone*/temp found -- temperature logging skipped." >&2
fi

cleanup() {
    if [ "$GOVERNOR_ENFORCED" -eq 1 ] && [ -n "$ORIGINAL_GOVERNOR" ]; then
        echo "$ORIGINAL_GOVERNOR" > "$GOVERNOR_FILE" 2>/dev/null || true
    fi
    if [ -n "$TEMP_LOGGER_PID" ]; then
        kill "$TEMP_LOGGER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

{
    echo "scaling_governor (as found): $ORIGINAL_GOVERNOR"
    echo "scaling_governor (enforced to 'performance' for this run): $([ "$GOVERNOR_ENFORCED" -eq 1 ] && echo yes || echo "NO -- see warning above")"
    if [ -r "$BOOST_FILE" ]; then
        echo "boost (acpi-cpufreq/amd_pstate generic toggle, 1=enabled): $(cat "$BOOST_FILE")"
    elif [ -r "$INTEL_NOTURBO_FILE" ]; then
        echo "no_turbo (intel_pstate, 1=turbo disabled): $(cat "$INTEL_NOTURBO_FILE")"
    else
        echo "boost/turbo state: not readable on this machine (checked acpi-cpufreq/amd_pstate boost and intel_pstate no_turbo)"
    fi
    echo "taskset_core: $TASKSET_CORE (enforced -- see _inner_measure.sh's taskset -c call)"
    echo "grid: $GRID_HOST"
} > "$CPU_STATE_LOG"
echo "CPU state (governor/boost/pinned core) logged to $CPU_STATE_LOG"

if [ ! -x "$EXPERIMENTS_DIR/seal/build/bench_seal" ]; then
    echo "ERROR: bench_seal not built yet (or stale -- rebuild after the" >&2
    echo "  --fill-pct change). Run docker_build_and_run.sh first." >&2
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

# --- Extra-rigor item 2: idle-power baseline (same pattern as
# run_standard_docker.sh).
IDLE_SECONDS=5
measure_idle_power() {
    local label="$1"
    if [ "$HAVE_RAPL" -ne 1 ]; then
        echo "idle_power_watts_${label}: unavailable (no RAPL)" >> "$CPU_STATE_LOG"
        return
    fi
    local before after delta_uj watts
    before=$(cat "$RAPL_ENERGY_FILE")
    sleep "$IDLE_SECONDS"
    after=$(cat "$RAPL_ENERGY_FILE")
    if [ "$after" -ge "$before" ]; then delta_uj=$((after - before)); else delta_uj=$((after + MAX_ENERGY_UJ - before)); fi
    watts=$(awk "BEGIN{printf \"%.4f\", $delta_uj/1000000/$IDLE_SECONDS}")
    echo "idle_power_watts_${label}: $watts (over ${IDLE_SECONDS}s, nothing scheduled on core $TASKSET_CORE)" >> "$CPU_STATE_LOG"
    echo "Idle power ($label): ${watts} W"
}
measure_idle_power "before"

SCHEMES=("BFV" "CKKS" "BGV")
PACKING_OPERATIONS=("encrypt" "add" "multiply")
FILL_LEVELS=("1" "0.10" "0.50" "1.00")

# Human-readable level -> the --fill-pct value bench_seal actually receives.
# "1" -> 0.0 deliberately: bench_seal's own max(1, round(fill_pct *
# slot_count)) formula floors that to n_real=1, the literal single-value
# level -- see bench_seal.cpp's --fill-pct header comment. Not a separate
# code path, just the same formula's boundary case.
declare -A FILL_PCT_FOR_LEVEL=(["1"]=0.0 ["0.10"]=0.10 ["0.50"]=0.50 ["1.00"]=1.00)

run_one() {
    local TAG="$1"; shift
    local EXPECTED="$1"; shift
    local OUT_CSV_HOST="$RAW_DIR/${TAG}.csv"
    local OUT_CSV="/work/results/raw/packing/${TAG}.csv"
    local MEM_LOG="/work/results/logs/packing/${TAG}_mem.log"
    local ENERGY_LOG="$LOG_DIR/${TAG}_energy.log"

    if [ -f "$OUT_CSV_HOST" ] && [ "$(tail -n +2 "$OUT_CSV_HOST" | wc -l)" -ge "$EXPECTED" ]; then
        echo "SKIPPED (already complete): ${TAG}.csv"
        return
    fi

    echo ">> $TAG"

    local DOCKER_CMD=(docker run --rm -e TASKSET_CORE="$TASKSET_CORE" \
        -v "$EXPERIMENTS_DIR":/work "$IMAGE" \
        bash /work/scripts/_inner_measure.sh /work/seal/build/bench_seal "$MEM_LOG" \
        "$@" --out="$OUT_CSV" --grid="$GRID_CONTAINER")

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

# --- Extra-rigor item 6: randomize run order, seeded and logged. Adapted
# like run_edge_batch_docker.sh/run_composite_docker.sh: "size" is a
# deterministic 1-row unit, the three PACKING_OPERATIONS are timed
# reps/warmup units -- each flattened entry carries a KIND tag ("size" or
# an operation name) alongside (N,category,scheme,level).
RUN_ORDER_SEED="${RUN_ORDER_SEED:-$RANDOM$RANDOM}"
echo "run_order_seed: $RUN_ORDER_SEED" >> "$CPU_STATE_LOG"
mapfile -t ALL_CELLS < <(
    tail -n +2 "$GRID_HOST" | while IFS=, read -r N CATEGORY SEC CHAIN LOGQ DEPTH; do
        for SCHEME in "${SCHEMES[@]}"; do
            for LEVEL in "${FILL_LEVELS[@]}"; do
                echo "size,$N,$CATEGORY,$SCHEME,$LEVEL"
                for OP in "${PACKING_OPERATIONS[@]}"; do
                    echo "$OP,$N,$CATEGORY,$SCHEME,$LEVEL"
                done
            done
        done
    done
)
mapfile -t SHUFFLED_CELLS < <(
    printf '%s\n' "${ALL_CELLS[@]}" | \
        shuf --random-source=<(openssl enc -aes-256-ctr -pass pass:"$RUN_ORDER_SEED" -nosalt </dev/zero 2>/dev/null)
)
echo "Run order randomized (seed=$RUN_ORDER_SEED, ${#SHUFFLED_CELLS[@]} cells) -- reproducible via RUN_ORDER_SEED=$RUN_ORDER_SEED"

# Durable record of the run-order seed: cpu_state.txt above lives under
# results/logs/, which is gitignored, so until now the seed actually used
# for any given run wasn't recoverable from anything that gets committed.
# Append one row per invocation to a small, git-tracked CSV instead.
RUN_METADATA_CSV="$EXPERIMENTS_DIR/results/run_metadata.csv"
if [ ! -f "$RUN_METADATA_CSV" ]; then
    echo "timestamp,scenario,run_order_seed,num_cells" > "$RUN_METADATA_CSV"
fi
echo "$(date -Iseconds),packing,$RUN_ORDER_SEED,${#SHUFFLED_CELLS[@]}" >> "$RUN_METADATA_CSV"

for CELL in "${SHUFFLED_CELLS[@]}"; do
    IFS=, read -r KIND N CATEGORY SCHEME LEVEL <<< "$CELL"
    FILL_PCT="${FILL_PCT_FOR_LEVEL[$LEVEL]}"
    if [ "$KIND" = "size" ]; then
        # size: deterministic, one row (artifact=ciphertext), no reps loop.
        run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_size_fill${LEVEL}" 1 \
            --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation=size \
            --fill-pct="$FILL_PCT"
    else
        run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_${KIND}_fill${LEVEL}" "$EXPECTED_ROWS" \
            --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation="$KIND" \
            --reps="$REPS" --warmup="$WARMUP" --fill-pct="$FILL_PCT"
    fi
done

measure_idle_power "after"

echo "Packing sweep complete. Raw CSVs in $RAW_DIR, logs in $LOG_DIR."
echo "Next: python3 $SCRIPT_DIR/aggregate.py --scenario=packing"
