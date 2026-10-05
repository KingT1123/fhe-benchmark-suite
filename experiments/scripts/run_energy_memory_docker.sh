#!/usr/bin/env bash
# run_energy_memory_docker.sh — round-3 dedicated energy + memory measurement
# for the Standard and Constrained scenarios, with ONE protocol for both.
#
# Why: the original Standard/Constrained runs read RAPL around the whole
# `docker run` (container start, context/keys, and the untimed pre-build of
# inner_loop fresh ciphertexts per rep -- ~90% of the window for most
# cells), never subtracted idle power, and polled peak RSS of a process
# that pre-built 1000 (Standard) or 100 (Constrained) ciphertexts per rep,
# so memory measured the harness, not one SEAL operation. Latency results
# are unaffected and are NOT re-measured here.
#
# Per cell (scheme, N, category, operation):
#   1. Energy: one invocation, --rapl-dir (host RAPL bind-mounted read-only;
#      Docker masks /sys/devices/virtual/powercap otherwise), RAPL read
#      around the timed region only, --idle-seconds=3 idle measurement just
#      before the reps (after a 6 s settle, see bench_seal.cpp), REPS measured reps, --inner-loop from
#      config/energy_plan.csv (~50 ms window per rep, same for both
#      scenarios -- see make_energy_plan.py).
#   2. Memory: MEM_RUNS separate invocations at --inner-loop=1 (one op per
#      rep), exact peak RSS (VmHWM) read in-process via --peak-rss-out.
# aggregate.py computes everything else (idle correction, stats).
#
# Scope: Standard = N<=8192 all categories + N=16384 category 1 (the
# report's existing Standard scope); Constrained = N<=8192.
#
# Needs root for the CPU governor (enforced to 'performance', restored on
# exit) -- run it with sudo. Progress: one line per cell, also appended to
# results/logs/energy_memory/<scenario>/progress.log (tail -f that file).
#
# Test on a subset (no sudo needed, governor then not enforced):
#   CELL_FILTER='^BFV,2048,1,' bash run_energy_memory_docker.sh standard
#
# Usage (from experiments/scripts/):
#   sudo bash run_energy_memory_docker.sh standard
#   sudo bash run_energy_memory_docker.sh constrained
# then: python3 aggregate.py --scenario=standard   (and constrained)

set -euo pipefail
SCENARIO="${1:-}"
case "$SCENARIO" in
    standard)    DOCKER_LIMITS=() ;;
    constrained) DOCKER_LIMITS=(--cpuset-cpus=0-3 --memory=4g) ;;
    *) echo "Usage: $0 standard|constrained" >&2; exit 1 ;;
esac

IMAGE="${IMAGE:-seal-env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GRID="$EXPERIMENTS_DIR/config/param_grid.csv"
PLAN="$EXPERIMENTS_DIR/config/energy_plan.csv"
RAW_DIR="$EXPERIMENTS_DIR/results/raw/energy_memory/$SCENARIO"
LOG_DIR="$EXPERIMENTS_DIR/results/logs/energy_memory/$SCENARIO"
PROGRESS_LOG="$LOG_DIR/progress.log"
REPS=30
WARMUP=2
IDLE_SETTLE_SECONDS=6   # package power needs ~4 s to fall back to idle after load (measured)
IDLE_SECONDS=4
RAMP_SECONDS=2          # package needs ~0.5 s of load to reach loaded power from idle (measured)
MEM_RUNS=3
MEM_REPS=10
TASKSET_CORE=0
RAPL_HOST_DIR="$(realpath /sys/class/powercap/intel-rapl:0)"

mkdir -p "$RAW_DIR" "$LOG_DIR"

if [ ! -x "$EXPERIMENTS_DIR/seal/build/bench_seal" ]; then
    echo "ERROR: bench_seal not built. Run seal/docker_build_and_run.sh first." >&2; exit 1
fi
if [ ! -f "$PLAN" ]; then
    echo "ERROR: $PLAN missing. Run: python3 make_energy_plan.py" >&2; exit 1
fi

# ---- CPU governor (root) + temperature log, same as the other run scripts
GOVERNOR_FILE="/sys/devices/system/cpu/cpu${TASKSET_CORE}/cpufreq/scaling_governor"
ORIGINAL_GOVERNOR="$(cat "$GOVERNOR_FILE" 2>/dev/null || echo "")"
GOVERNOR_ENFORCED=0
if [ -n "$ORIGINAL_GOVERNOR" ] && echo performance > "$GOVERNOR_FILE" 2>/dev/null; then
    GOVERNOR_ENFORCED=1
else
    echo "WARNING: could not set the CPU governor (needs sudo) -- continuing, but this is logged." >&2
fi

TEMP_LOG="$LOG_DIR/temperature_log.csv"
TEMP_SOURCE=""
for zone in /sys/class/thermal/thermal_zone*/; do
    if [ -r "${zone}type" ] && grep -qiE "x86_pkg_temp|cpu" "${zone}type" 2>/dev/null && [ -r "${zone}temp" ]; then
        TEMP_SOURCE="${zone}temp"; break
    fi
done
[ -z "$TEMP_SOURCE" ] && for zone in /sys/class/thermal/thermal_zone*/temp; do [ -r "$zone" ] && TEMP_SOURCE="$zone" && break; done
TEMP_LOGGER_PID=""
if [ -n "$TEMP_SOURCE" ]; then
    [ -f "$TEMP_LOG" ] || echo "timestamp,temp_millic,source" > "$TEMP_LOG"
    ( while true; do echo "$(date -Iseconds),$(cat "$TEMP_SOURCE" 2>/dev/null || echo ''),$TEMP_SOURCE" >> "$TEMP_LOG"; sleep 5; done ) &
    TEMP_LOGGER_PID=$!
fi

cleanup() {
    [ "$GOVERNOR_ENFORCED" -eq 1 ] && echo "$ORIGINAL_GOVERNOR" > "$GOVERNOR_FILE" 2>/dev/null || true
    [ -n "$TEMP_LOGGER_PID" ] && kill "$TEMP_LOGGER_PID" 2>/dev/null || true
}
trap cleanup EXIT

temp_c() { [ -n "$TEMP_SOURCE" ] && awk '{printf "%.0f", $1/1000}' "$TEMP_SOURCE" 2>/dev/null || echo "?"; }

# ---- cells: plan rows within this scenario's scope, randomized order
mapfile -t ALL_CELLS < <(
    tail -n +2 "$PLAN" | while IFS=, read -r SCHEME N CATEGORY OP LAT INNER; do
        if [ "$N" = "16384" ] && { [ "$SCENARIO" = "constrained" ] || [ "$CATEGORY" != "1" ]; }; then continue; fi
        echo "$SCHEME,$N,$CATEGORY,$OP,$INNER"
    done | grep -E "${CELL_FILTER:-.}"   # CELL_FILTER: optional regex, for test runs only
)
RUN_ORDER_SEED="${RUN_ORDER_SEED:-$RANDOM$RANDOM}"
mapfile -t CELLS < <(printf '%s\n' "${ALL_CELLS[@]}" | \
    shuf --random-source=<(openssl enc -aes-256-ctr -pass pass:"$RUN_ORDER_SEED" -nosalt </dev/zero 2>/dev/null))

{
    echo "scenario: $SCENARIO (energy_memory protocol, round 3)"
    echo "started: $(date -Iseconds)"
    echo "scaling_governor (as found): $ORIGINAL_GOVERNOR; enforced to performance: $([ "$GOVERNOR_ENFORCED" -eq 1 ] && echo yes || echo NO)"
    echo "docker limits: ${DOCKER_LIMITS[*]:-none}; taskset_core: $TASKSET_CORE"
    echo "energy: reps=$REPS warmup=$WARMUP idle: ${IDLE_SETTLE_SECONDS}s settle then ${IDLE_SECONDS}s window, ${RAMP_SECONDS}s ramp; inner_loop=per energy_plan.csv"
    echo "memory: $MEM_RUNS invocations x (reps=$MEM_REPS warmup=$WARMUP) at inner_loop=1"
    echo "run_order_seed: $RUN_ORDER_SEED; cells: ${#CELLS[@]}"
} >> "$LOG_DIR/run_info.txt"

RUN_METADATA_CSV="$EXPERIMENTS_DIR/results/run_metadata.csv"
[ -f "$RUN_METADATA_CSV" ] || echo "timestamp,scenario,run_order_seed,num_cells" > "$RUN_METADATA_CSV"
echo "$(date -Iseconds),${SCENARIO}_energy_memory,$RUN_ORDER_SEED,${#CELLS[@]}" >> "$RUN_METADATA_CSV"

docker_run() {
    docker run --rm "${DOCKER_LIMITS[@]}" \
        --mount "type=bind,source=$RAPL_HOST_DIR,target=/rapl,readonly" \
        -v "$EXPERIMENTS_DIR":/work "$IMAGE" \
        taskset -c "$TASKSET_CORE" /work/seal/build/bench_seal "$@" \
        --grid=/work/config/param_grid.csv
}

TOTAL=${#CELLS[@]}
START=$(date +%s)
I=0
echo "== $SCENARIO: $TOTAL cells. Progress also in $PROGRESS_LOG ==" | tee -a "$PROGRESS_LOG"
for CELL in "${CELLS[@]}"; do
    IFS=, read -r SCHEME N CATEGORY OP INNER <<< "$CELL"
    I=$((I + 1))
    TAG="seal_${SCHEME,,}_N${N}_cat${CATEGORY}_${OP}"
    E_CSV="$RAW_DIR/${TAG}_energy.csv"
    CELL_START=$(date +%s)
    STATUS="done"

    # 1. energy (skip if already complete: header + WARMUP+REPS rows, or a skip row)
    if [ -f "$E_CSV" ] && { [ "$(tail -n +2 "$E_CSV" | wc -l)" -ge $((REPS + WARMUP)) ] || grep -q skipped_depth0 "$E_CSV"; }; then
        STATUS="skipped (already complete)"
    else
        docker_run --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation="$OP" \
            --reps="$REPS" --warmup="$WARMUP" --inner-loop="$INNER" \
            --rapl-dir=/rapl --idle-settle-seconds="$IDLE_SETTLE_SECONDS" --idle-seconds="$IDLE_SECONDS" --ramp-seconds="$RAMP_SECONDS" \
            --out="/work/results/raw/energy_memory/$SCENARIO/${TAG}_energy.csv" \
            2>> "$LOG_DIR/bench_stderr.log" || STATUS="ENERGY FAILED (see bench_stderr.log)"
    fi

    # 2. memory, MEM_RUNS separate invocations at inner_loop=1
    if ! grep -q skipped_depth0 "$E_CSV" 2>/dev/null; then
        for K in $(seq 1 "$MEM_RUNS"); do
            M_LOG="$RAW_DIR/${TAG}_mem${K}.log"
            [ -s "$M_LOG" ] && continue
            docker_run --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation="$OP" \
                --reps="$MEM_REPS" --warmup="$WARMUP" --inner-loop=1 \
                --peak-rss-out="/work/results/raw/energy_memory/$SCENARIO/${TAG}_mem${K}.log" \
                --out="/work/results/raw/energy_memory/$SCENARIO/${TAG}_memrun.csv" \
                2>> "$LOG_DIR/bench_stderr.log" || STATUS="MEMORY FAILED (see bench_stderr.log)"
        done
        rm -f "$RAW_DIR/${TAG}_memrun.csv"   # latencies of the memory runs are not used
    fi

    NOW=$(date +%s)
    ELAPSED=$((NOW - START))
    ETA=$(( ELAPSED * (TOTAL - I) / I ))
    printf '[%3d/%d] %-40s %-28s %3ds  temp %s C  elapsed %dm  ETA ~%dm\n' \
        "$I" "$TOTAL" "$TAG" "$STATUS" $((NOW - CELL_START)) "$(temp_c)" $((ELAPSED / 60)) $((ETA / 60)) \
        | tee -a "$PROGRESS_LOG"
done

echo "== $SCENARIO finished $(date -Iseconds). Next: python3 aggregate.py --scenario=$SCENARIO ==" | tee -a "$PROGRESS_LOG"
echo "finished: $(date -Iseconds)" >> "$LOG_DIR/run_info.txt"
