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
# Grid override: set GRID=/path/to/subset.csv (must live under
# experiments/config/ so it's inside the Docker mount) to sweep a subset
# instead of the full grid -- same convention as
# run_extended_metrics_docker.sh, e.g. for a small validation run before
# committing to the full 144-row sweep.
GRID_HOST="${GRID:-$EXPERIMENTS_DIR/config/param_grid.csv}"
GRID_CONTAINER="/work/config/$(basename "$GRID_HOST")"
RAW_DIR="$EXPERIMENTS_DIR/results/raw"
LOG_DIR="$EXPERIMENTS_DIR/results/logs/standard"
REPS=100
WARMUP=5
EXPECTED_ROWS=$((REPS + WARMUP))  # resume support: a cell's output CSV is
                        # only considered complete once it has this many data
                        # rows (header not counted) -- fewer (missing file,
                        # 0 rows, or a truncated file from an interrupted
                        # run) means "not done", so bench_seal reruns it and
                        # overwrites the file (std::ofstream truncates by
                        # default, no --append flag exists, so this is safe).
INNER_LOOP=1000        # pinned explicitly (not left at bench_seal's compiled-in
                        # default) so it's visible/auditable, same convention as
                        # run_extended_metrics_docker.sh's TRACE_REPS.
TASKSET_CORE="${TASKSET_CORE:-0}"  # single core the benchmark process is pinned
                        # to (see _inner_measure.sh) -- override if core 0 is
                        # reserved for something else on this machine.

RAPL_ENERGY_FILE="/sys/class/powercap/intel-rapl:0/energy_uj"
RAPL_MAX_FILE="/sys/class/powercap/intel-rapl:0/max_energy_range_uj"

mkdir -p "$RAW_DIR" "$LOG_DIR"

# Document the host's CPU frequency governor and turbo/boost state per run,
# rather than assuming it -- these affect timing variance/repeatability and
# aren't otherwise recorded anywhere. Read on the HOST (not inside the
# container): the container shares the host's CPU, these sysfs files aren't
# namespaced by cgroups/Docker. Checks acpi-cpufreq/amd_pstate's generic
# "boost" toggle first (this machine is AMD, confirmed working), falls back
# to intel_pstate's "no_turbo" for Intel hosts, else records "not readable".
GOVERNOR_FILE="/sys/devices/system/cpu/cpu${TASKSET_CORE}/cpufreq/scaling_governor"
BOOST_FILE="/sys/devices/system/cpu/cpufreq/boost"
INTEL_NOTURBO_FILE="/sys/devices/system/cpu/intel_pstate/no_turbo"
CPU_STATE_LOG="$LOG_DIR/cpu_state.txt"

# --- Extra-rigor item 5: ENFORCE the governor on the pinned core, don't just
# log it. CPU affinity was already enforced (taskset -c "$TASKSET_CORE" in
# _inner_measure.sh, unrelated to this) -- the governor was the actual gap.
# Original value is remembered and restored on exit (normal, error, or
# Ctrl-C) so this script doesn't leave the machine's power settings changed
# behind it.
ORIGINAL_GOVERNOR="$(cat "$GOVERNOR_FILE" 2>/dev/null || echo "")"
GOVERNOR_ENFORCED=0
if [ -n "$ORIGINAL_GOVERNOR" ]; then
    if echo performance > "$GOVERNOR_FILE" 2>/dev/null; then
        GOVERNOR_ENFORCED=1
    else
        echo "WARNING: could not write $GOVERNOR_FILE (needs root) -- governor NOT enforced, only logged below." >&2
    fi
fi

# --- Extra-rigor item 7: periodic CPU temperature logging throughout the
# sweep, alongside cpu_state.txt. Sysfs thermal zone (no extra package
# needed) rather than lm-sensors, since the zone file is already guaranteed
# present on any Linux host -- prefers a zone whose type mentions the
# package/cpu, falls back to the first readable zone otherwise.
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

# --- Extra-rigor item 2: idle-power baseline, measured fresh (never a
# hardcoded guess), before and after the sweep, via the SAME RAPL mechanism
# used for every per-cell energy reading. IDLE_SECONDS of genuinely idle
# time (nothing scheduled on the pinned core) bracket the whole sweep;
# aggregate.py (or any later analysis) can subtract this baseline from a
# cell's measured energy if it wants energy net of idle draw -- this script
# only measures and records it, per the "statistics live in one place" rule.
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
OPERATIONS=("keygen" "encrypt" "decrypt" "add" "multiply" "relinearize")

# --- Extra-rigor item 6: randomize run order, seeded and logged so the
# specific order is reproducible. Flatten the (N,category)x scheme x
# operation grid into one list first (chain/logq/depth from the grid row
# aren't used in the per-cell body below -- bench_seal re-reads them itself
# via --grid=), then shuffle that flat list with a seed recorded in
# cpu_state.txt, rather than always running in the same fixed nested-loop
# sequence.
RUN_ORDER_SEED="${RUN_ORDER_SEED:-$RANDOM$RANDOM}"
echo "run_order_seed: $RUN_ORDER_SEED" >> "$CPU_STATE_LOG"
mapfile -t ALL_CELLS < <(
    tail -n +2 "$GRID_HOST" | while IFS=, read -r N CATEGORY SEC CHAIN LOGQ DEPTH; do
        for SCHEME in "${SCHEMES[@]}"; do
            for OP in "${OPERATIONS[@]}"; do
                echo "$N,$CATEGORY,$SCHEME,$OP"
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
echo "$(date -Iseconds),standard,$RUN_ORDER_SEED,${#SHUFFLED_CELLS[@]}" >> "$RUN_METADATA_CSV"

for CELL in "${SHUFFLED_CELLS[@]}"; do
    IFS=, read -r N CATEGORY SCHEME OP <<< "$CELL"
    TAG="seal_${SCHEME,,}_N${N}_cat${CATEGORY}_${OP}"
    OUT_CSV_HOST="$RAW_DIR/${TAG}.csv"
    OUT_CSV="/work/results/raw/${TAG}.csv"
    MEM_LOG="/work/results/logs/standard/${TAG}_mem.log"
    ENERGY_LOG="$LOG_DIR/${TAG}_energy.log"

    if [ -f "$OUT_CSV_HOST" ] && [ "$(tail -n +2 "$OUT_CSV_HOST" | wc -l)" -ge "$EXPECTED_ROWS" ]; then
        echo "SKIPPED (already complete): ${TAG}.csv"
        continue
    fi

    echo ">> $TAG"

    DOCKER_CMD=(docker run --rm -e TASKSET_CORE="$TASKSET_CORE" \
        -v "$EXPERIMENTS_DIR":/work "$IMAGE" \
        bash /work/scripts/_inner_measure.sh /work/seal/build/bench_seal "$MEM_LOG" \
        --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation="$OP" \
        --reps="$REPS" --warmup="$WARMUP" --inner-loop="$INNER_LOOP" --out="$OUT_CSV" \
        --grid="$GRID_CONTAINER")

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

measure_idle_power "after"

echo "Scenario A sweep complete. Raw CSVs in $RAW_DIR, logs in $LOG_DIR."
echo "Next: python3 $SCRIPT_DIR/aggregate.py --scenario=standard"
