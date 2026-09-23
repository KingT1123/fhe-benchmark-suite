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
GRID="${GRID:-$EXPERIMENTS_DIR/config/param_grid.csv}"
RAW_DIR="$EXPERIMENTS_DIR/results/raw/edge_batch"
LOG_DIR="$EXPERIMENTS_DIR/results/logs/edge_batch"
TASKSET_CORE="${TASKSET_CORE:-0}"
# inner-loop pinned to 1 (bench_seal's default is 1000, see bench_seal.cpp's
# --inner-loop header comment): Edge/Batch's own batch_size dimension already
# repeats the core op B times per timed trial, and aggregate.py's per-
# invocation RAPL/peak-memory accounting (n=1_invocation_not_repeated) assumes
# exactly one B-item trial per process. Stacking a 1000x inner-loop on top
# would both break that accounting and multiply an already-large sweep
# (B=100 * inner-loop=1000 = 100,000 fresh ciphertexts per rep) for no benefit
# this scenario needs (timing-noise reduction isn't Edge/Batch's problem).
INNER_LOOP=1

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
    echo "inner_loop: $INNER_LOOP"
} > "$CPU_STATE_LOG"
echo "CPU state (governor/boost/pinned core) logged to $CPU_STATE_LOG"

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
BATCH_OPERATIONS=("encrypt" "decrypt" "add" "multiply" "relinearize")
BATCH_SIZES=(1 10 100)

# (c) reps/warmup shrink as batch size grows, so total work per cell
# (batch_size * reps) doesn't blow up the sweep's wall-clock time.
declare -A REPS_FOR_BATCH=(  [1]=100 [10]=30 [100]=10 )
declare -A WARMUP_FOR_BATCH=([1]=5   [10]=3  [100]=2  )

run_one() {
    local TAG="$1"; shift
    local EXPECTED_ROWS="$1"; shift  # resume support -- see run_standard_docker.sh.
                                      # Edge/Batch's reps+warmup varies by batch
                                      # size (REPS_FOR_BATCH/WARMUP_FOR_BATCH), so
                                      # unlike Standard/Constrained this can't be a
                                      # single script-wide constant -- callers pass
                                      # the count that matches their own --reps/
                                      # --warmup.
    local OUT_CSV_HOST="$RAW_DIR/${TAG}.csv"
    local OUT_CSV="/work/results/raw/edge_batch/${TAG}.csv"
    local MEM_LOG="/work/results/logs/edge_batch/${TAG}_mem.log"
    local ENERGY_LOG="$LOG_DIR/${TAG}_energy.log"

    if [ -f "$OUT_CSV_HOST" ] && [ "$(tail -n +2 "$OUT_CSV_HOST" | wc -l)" -ge "$EXPECTED_ROWS" ]; then
        echo "SKIPPED (already complete): ${TAG}.csv"
        return
    fi

    echo ">> $TAG"

    local DOCKER_CMD=(docker run --rm -e TASKSET_CORE="$TASKSET_CORE" \
        -v "$EXPERIMENTS_DIR":/work "$IMAGE" \
        bash /work/scripts/_inner_measure.sh /work/seal/build/bench_seal "$MEM_LOG" \
        "$@" --inner-loop="$INNER_LOOP" --out="$OUT_CSV" --grid=/work/config/param_grid.csv)

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
# from run_standard_docker.sh's simpler 4-tuple flatten: this scenario has
# TWO different kinds of work unit -- one batch-invariant keygen call per
# (scheme,N,category), and a separate (operation x batch_size) grid -- so
# each flattened entry is tagged with its KIND ("keygen" or "op") and the
# dispatch loop below branches on that tag. This lets keygen's position
# relative to the batch operations be randomized too, not just the batch
# operations among themselves.
RUN_ORDER_SEED="${RUN_ORDER_SEED:-$RANDOM$RANDOM}"
echo "run_order_seed: $RUN_ORDER_SEED" >> "$CPU_STATE_LOG"
mapfile -t ALL_CELLS < <(
    tail -n +2 "$GRID" | while IFS=, read -r N CATEGORY SEC CHAIN LOGQ DEPTH; do
        for SCHEME in "${SCHEMES[@]}"; do
            echo "keygen,$N,$CATEGORY,$SCHEME,,"
            for OP in "${BATCH_OPERATIONS[@]}"; do
                for B in "${BATCH_SIZES[@]}"; do
                    echo "op,$N,$CATEGORY,$SCHEME,$OP,$B"
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
echo "$(date -Iseconds),edge_batch,$RUN_ORDER_SEED,${#SHUFFLED_CELLS[@]}" >> "$RUN_METADATA_CSV"

for CELL in "${SHUFFLED_CELLS[@]}"; do
    IFS=, read -r KIND N CATEGORY SCHEME OP B <<< "$CELL"
    if [ "$KIND" = "keygen" ]; then
        # (d) keygen: once per cell, batch-size-invariant.
        run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_keygen_batch1" 105 \
            --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation=keygen \
            --reps=100 --warmup=5 --batch-size=1
    else
        run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_${OP}_batch${B}" \
            "$((REPS_FOR_BATCH[$B] + WARMUP_FOR_BATCH[$B]))" \
            --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation="$OP" \
            --reps="${REPS_FOR_BATCH[$B]}" --warmup="${WARMUP_FOR_BATCH[$B]}" \
            --batch-size="$B"
    fi
done

measure_idle_power "after"

echo "Edge/Batch sweep complete. Raw CSVs in $RAW_DIR, logs in $LOG_DIR."
echo "aggregate.py does not yet support --scenario=edge_batch -- that's the next step, not run here."
