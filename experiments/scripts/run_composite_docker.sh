#!/usr/bin/env bash
# run_composite_docker.sh — Composite scenario, through Docker.
#
# Chapter 3's chained-workload question: does single-operation timing
# (Standard scenario) predict multi-operation (chained) cost? Structure/
# conventions mirror run_packing_docker.sh as closely as possible on purpose
# (GRID override, resume/skip-if-complete, CPU governor/pinning logging),
# same as run_packing_docker.sh itself mirrored run_edge_batch_docker.sh.
#
# Three operations swept, all three schemes:
#   - rotate: a real, isolated, single rotate-by-1 measurement -- feeds the
#     prediction formula (see aggregate.py --scenario=composite) as the
#     per-step rotation cost, rather than approximating it with another
#     operation's cost.
#   - dot_product: needs --vec-len (a literal count, NOT a percentage --
#     distinct from Packing's --fill-pct). Swept at 8, 64, 512, and the
#     scheme's own full slot count (BFV/BGV: N=8192; CKKS: N/2=4096, since
#     CKKSEncoder's usable slot count is N/2, not N) -- see
#     FULL_SLOTS_FOR_SCHEME below.
#   - poly_eval: single fully-packed measurement, no --vec-len (purely
#     elementwise, no rotation -- see bench_seal.cpp's header comment for
#     why a length sweep isn't expected to add anything here).
#
# Scoped to N=8192/category=1 only, via its own small grid file
# (../config/param_grid_composite.csv, a single row identical to
# param_grid.csv's own N=8192/category=1 row) rather than editing any
# existing grid or run_*.sh script.
#
# Raw CSVs and logs go to their own subdirectories (results/raw/composite,
# results/logs/composite), same "invisible to aggregate.py's flat
# seal_*.csv glob" isolation reasoning as run_edge_batch_docker.sh/
# run_packing_docker.sh's own header comments.
#
# Timing protocol: same as Standard/Constrained/Packing -- 100 reps, 5
# warmup (EXPECTED_ROWS=105) for all three operations (rotate, dot_product,
# poly_eval all use the standard reps/warmup timed-loop shape, unlike
# size/noise_trace/ckks_error/config_metadata's separate deterministic/
# trace-reps shapes).

set -euo pipefail
IMAGE="${IMAGE:-seal-env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Grid override: set GRID=/path/to/subset.csv (must live under
# experiments/config/ so it's inside the Docker mount) -- same convention as
# run_standard_docker.sh/run_packing_docker.sh. Defaults to Composite's own
# small grid (N=8192/category=1 only), NOT param_grid.csv.
GRID_HOST="${GRID:-$EXPERIMENTS_DIR/config/param_grid_composite.csv}"
GRID_CONTAINER="/work/config/$(basename "$GRID_HOST")"
RAW_DIR="$EXPERIMENTS_DIR/results/raw/composite"
LOG_DIR="$EXPERIMENTS_DIR/results/logs/composite"
TASKSET_CORE="${TASKSET_CORE:-0}"
REPS=100
WARMUP=5
EXPECTED_ROWS=$((REPS + WARMUP))  # resume support, same convention as
                        # run_standard_docker.sh/run_packing_docker.sh -- a
                        # cell's output CSV is only "complete" once it has
                        # this many data rows.

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
    echo "  rotate/dot_product/poly_eval change). Run docker_build_and_run.sh first." >&2
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
VEC_LENS_BASE=(8 64 512)

# Full-slot-count level, per scheme: BFV/BGV batching uses N slots;
# CKKSEncoder's usable slot count is N/2 (see bench_seal.cpp's
# fresh_ciphertext()/build_context()) -- both are simply c.*_encoder->
# slot_count() at N=8192, computed here rather than queried since the grid
# is fixed to N=8192 for this whole script.
declare -A FULL_SLOTS_FOR_SCHEME=(["BFV"]=8192 ["BGV"]=8192 ["CKKS"]=4096)

run_one() {
    local TAG="$1"; shift
    local OUT_CSV_HOST="$RAW_DIR/${TAG}.csv"
    local OUT_CSV="/work/results/raw/composite/${TAG}.csv"
    local MEM_LOG="/work/results/logs/composite/${TAG}_mem.log"
    local ENERGY_LOG="$LOG_DIR/${TAG}_energy.log"

    if [ -f "$OUT_CSV_HOST" ] && [ "$(tail -n +2 "$OUT_CSV_HOST" | wc -l)" -ge "$EXPECTED_ROWS" ]; then
        echo "SKIPPED (already complete): ${TAG}.csv"
        return
    fi

    echo ">> $TAG"

    local DOCKER_CMD=(docker run --rm -e TASKSET_CORE="$TASKSET_CORE" \
        -v "$EXPERIMENTS_DIR":/work "$IMAGE" \
        bash /work/scripts/_inner_measure.sh /work/seal/build/bench_seal "$MEM_LOG" \
        "$@" --reps="$REPS" --warmup="$WARMUP" --out="$OUT_CSV" --grid="$GRID_CONTAINER")

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
# like run_edge_batch_docker.sh: rotate/poly_eval are simple per-(N,
# category,scheme) units, but dot_product also varies by vec_len (including
# a scheme-dependent full-slot value from FULL_SLOTS_FOR_SCHEME) -- each
# flattened entry carries a KIND tag ("rotate"/"poly_eval"/"dot_product")
# plus a vec_len field (empty unless KIND=dot_product).
RUN_ORDER_SEED="${RUN_ORDER_SEED:-$RANDOM$RANDOM}"
echo "run_order_seed: $RUN_ORDER_SEED" >> "$CPU_STATE_LOG"
mapfile -t ALL_CELLS < <(
    tail -n +2 "$GRID_HOST" | while IFS=, read -r N CATEGORY SEC CHAIN LOGQ DEPTH; do
        for SCHEME in "${SCHEMES[@]}"; do
            echo "rotate,$N,$CATEGORY,$SCHEME,"
            echo "poly_eval,$N,$CATEGORY,$SCHEME,"
            VEC_LENS=("${VEC_LENS_BASE[@]}" "${FULL_SLOTS_FOR_SCHEME[$SCHEME]}")
            for VL in "${VEC_LENS[@]}"; do
                echo "dot_product,$N,$CATEGORY,$SCHEME,$VL"
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
echo "$(date -Iseconds),composite,$RUN_ORDER_SEED,${#SHUFFLED_CELLS[@]}" >> "$RUN_METADATA_CSV"

for CELL in "${SHUFFLED_CELLS[@]}"; do
    IFS=, read -r KIND N CATEGORY SCHEME VL <<< "$CELL"
    case "$KIND" in
        rotate)
            run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_rotate" \
                --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation=rotate
            ;;
        poly_eval)
            run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_poly_eval" \
                --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation=poly_eval
            ;;
        dot_product)
            run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_dot_product_veclen${VL}" \
                --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation=dot_product \
                --vec-len="$VL"
            ;;
    esac
done

measure_idle_power "after"

echo "Composite sweep complete. Raw CSVs in $RAW_DIR, logs in $LOG_DIR."
echo "Next: python3 $SCRIPT_DIR/aggregate.py --scenario=composite"
