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
GRID="${GRID:-$EXPERIMENTS_DIR/config/param_grid.csv}"
RAW_DIR="$EXPERIMENTS_DIR/results/raw"
LOG_DIR="$EXPERIMENTS_DIR/results/logs/constrained"
REPS=100
WARMUP=5
EXPECTED_ROWS=$((REPS + WARMUP))  # resume support -- see run_standard_docker.sh
CPUSET="0-3"
MEMLIMIT="4g"
INNER_LOOP=100          # LOWER than Standard's 1000 (see run_standard_docker.sh)
                        # -- Standard has 14GB of host headroom, but Constrained
                        # caps the container at 4GB, and add/multiply pre-build
                        # TWO vectors of batch_size*inner_loop fresh ciphertexts
                        # before the timed region starts (see time_add/
                        # time_multiply in bench_seal.cpp). At N=16384/category 1,
                        # a fresh ciphertext is 2,097,265 bytes (confirmed in
                        # seal_sizes.csv), so at the old inner_loop=1000 that
                        # pre-build alone is 2 * 1000 * 2,097,265 bytes ~= 4.19GB
                        # -- over the 4GiB (4,294,967,296-byte) cap once the
                        # 18.88MB relin_keys and container/OS overhead are added,
                        # so add/multiply would very likely get OOM-killed.
                        # relinearize is lower risk in total (one vector of
                        # products, not two) but each product is a pre-
                        # relinearization size-3 ciphertext, confirmed 3,145,841
                        # bytes -- 1000 of those is ~3.15GB, still too close to
                        # the cap for comfort. At inner_loop=100: add/multiply's
                        # pre-build drops to ~420MB and relinearize's to ~315MB,
                        # both comfortably clear of the cap while still averaging
                        # 100 calls per rep (versus the old single-shot timing).
TASKSET_CORE="${TASKSET_CORE:-0}"  # must be inside CPUSET above -- 0 is.

RAPL_ENERGY_FILE="/sys/class/powercap/intel-rapl:0/energy_uj"
RAPL_MAX_FILE="/sys/class/powercap/intel-rapl:0/max_energy_range_uj"

mkdir -p "$RAW_DIR" "$LOG_DIR"

# Document host CPU governor/boost state per run -- see run_standard_docker.sh
# for why and for the acpi-cpufreq/amd_pstate vs. intel_pstate fallback logic.
GOVERNOR_FILE="/sys/devices/system/cpu/cpu${TASKSET_CORE}/cpufreq/scaling_governor"
BOOST_FILE="/sys/devices/system/cpu/cpufreq/boost"
INTEL_NOTURBO_FILE="/sys/devices/system/cpu/intel_pstate/no_turbo"
CPU_STATE_LOG="$LOG_DIR/cpu_state.txt"

# --- Extra-rigor item 5: ENFORCE the governor on the pinned core (same
# pattern as run_standard_docker.sh). Affinity is already enforced via
# _inner_measure.sh's taskset -c, unaffected by this.
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
    echo "taskset_core: $TASKSET_CORE (within cpuset $CPUSET, enforced -- see _inner_measure.sh's taskset -c call)"
    echo "inner_loop: $INNER_LOOP"
} > "$CPU_STATE_LOG"
echo "CPU state (governor/boost/pinned core) logged to $CPU_STATE_LOG"

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

# --- Extra-rigor item 2: idle-power baseline (same pattern as
# run_standard_docker.sh), measured on the HOST -- Docker's --cpuset-cpus
# only restricts what the CONTAINER can use, it doesn't idle the host core
# any differently, so this baseline is directly comparable across scenarios.
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

# --- Extra-rigor item 6: randomize run order, seeded and logged (same
# pattern as run_standard_docker.sh).
RUN_ORDER_SEED="${RUN_ORDER_SEED:-$RANDOM$RANDOM}"
echo "run_order_seed: $RUN_ORDER_SEED" >> "$CPU_STATE_LOG"
mapfile -t ALL_CELLS < <(
    tail -n +2 "$GRID" | while IFS=, read -r N CATEGORY SEC CHAIN LOGQ DEPTH; do
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
echo "$(date -Iseconds),constrained,$RUN_ORDER_SEED,${#SHUFFLED_CELLS[@]}" >> "$RUN_METADATA_CSV"

for CELL in "${SHUFFLED_CELLS[@]}"; do
    IFS=, read -r N CATEGORY SCHEME OP <<< "$CELL"
    TAG="seal_${SCHEME,,}_N${N}_cat${CATEGORY}_${OP}"
    OUT_CSV_HOST="$RAW_DIR/${TAG}_constrained.csv"
    OUT_CSV="/work/results/raw/${TAG}_constrained.csv"
    MEM_LOG="/work/results/logs/constrained/${TAG}_mem.log"
    ENERGY_LOG="$LOG_DIR/${TAG}_energy.log"

    if [ -f "$OUT_CSV_HOST" ] && [ "$(tail -n +2 "$OUT_CSV_HOST" | wc -l)" -ge "$EXPECTED_ROWS" ]; then
        echo "SKIPPED (already complete): ${TAG}_constrained.csv"
        continue
    fi

    echo ">> $TAG (constrained: ${CPUSET}, ${MEMLIMIT})"

    DOCKER_CMD=(docker run --rm --cpuset-cpus="$CPUSET" --memory="$MEMLIMIT" \
        -e TASKSET_CORE="$TASKSET_CORE" \
        -v "$EXPERIMENTS_DIR":/work "$IMAGE" \
        bash /work/scripts/_inner_measure.sh /work/seal/build/bench_seal "$MEM_LOG" \
        --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation="$OP" \
        --reps="$REPS" --warmup="$WARMUP" --inner-loop="$INNER_LOOP" --out="$OUT_CSV" \
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

measure_idle_power "after"

echo "Scenario B sweep complete. Raw CSVs in $RAW_DIR, logs in $LOG_DIR."
echo "Next: python3 $SCRIPT_DIR/aggregate.py --scenario=constrained"
