#!/usr/bin/env bash
# run_pilot_docker.sh — the supervisor-authorized OpenFHE pilot: CKKS,
# N=8192, category 1, measured in ONE session together with SEAL under the
# same conditions, plus SEAL's scale test.
#
# Run on the HOST with sudo (the CPU governor of the pinned core is set to
# "performance" and restored on exit, as in run_standard_docker.sh):
#   sudo bash experiments/openfhe/run_pilot_docker.sh
# Prerequisites (no sudo): bash experiments/seal/docker_build_and_run.sh and
# bash experiments/openfhe/docker_build.sh.
#
# Cells (22), all with the Standard-scenario protocol of the SEAL campaign:
# 100 measured repetitions after 5 warm-up, inner loop 1000 (keygen and
# rotate: one call per repetition, as in SEAL), one docker run per cell,
# process pinned to one core (_inner_measure.sh: taskset + peak memory),
# randomized order with a recorded seed, CPU temperature logged every 5 s.
#   OpenFHE: keygen encrypt decrypt decrypt_full add add_inplace multiply relinearize rotate
#            (decrypt_full and add_inplace: diagnostics, see bench_openfhe.cpp)
#   SEAL:    keygen encrypt decrypt add multiply relinearize rotate
#   SEAL at CKKS scale 2^30 instead of 2^40, same primes (scale test):
#            encrypt decrypt add multiply relinearize rotate
# OpenFHE cells also write a per-repetition correctness check (checks/).
# Outputs: experiments/results/raw/pilot/ (raw CSVs, checks, run log copy),
# experiments/results/logs/pilot/ (memory logs). Statistics:
#   cd experiments/scripts && python3 aggregate.py --scenario=pilot
# Resume: a cell whose CSV already has 105 data rows is skipped.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP="$(cd "$SCRIPT_DIR/.." && pwd)"
# Test-only overrides (a dry run must not touch the real pilot directory):
#   PILOT_NAME=_pilot_test REPS=2 WARMUP=1 INNER_LOOP=5 bash run_pilot_docker.sh
NAME="${PILOT_NAME:-pilot}"
RAW="$EXP/results/raw/$NAME"
LOGS="$EXP/results/logs/$NAME"
REPS="${REPS:-100}"
WARMUP="${WARMUP:-5}"
INNER_LOOP="${INNER_LOOP:-1000}"
EXPECTED_ROWS=$((REPS + WARMUP))
TASKSET_CORE="${TASKSET_CORE:-0}"
mkdir -p "$RAW/checks" "$LOGS"

for f in "$EXP/seal/build/bench_seal" "$EXP/openfhe/build/bench_openfhe"; do
    [ -x "$f" ] || { echo "ERROR: $f not built (see the header of this script)" >&2; exit 1; }
done

# CPU state: governor enforced on the pinned core, restored on exit.
GOV="/sys/devices/system/cpu/cpu${TASKSET_CORE}/cpufreq/scaling_governor"
ORIG_GOV="$(cat "$GOV" 2>/dev/null || echo "")"
GOV_OK=0
if [ -n "$ORIG_GOV" ] && echo performance > "$GOV" 2>/dev/null; then GOV_OK=1; else
    echo "WARNING: could not set the governor (run with sudo) -- only logged." >&2; fi
TEMP_SRC=""
for z in /sys/class/thermal/thermal_zone*/; do
    if grep -qiE "x86_pkg_temp|cpu" "${z}type" 2>/dev/null && [ -r "${z}temp" ]; then TEMP_SRC="${z}temp"; break; fi
done
[ -z "$TEMP_SRC" ] && TEMP_SRC=/sys/class/thermal/thermal_zone0/temp
echo "timestamp,temp_millic,source" > "$RAW/temperature_log.csv"
( while true; do echo "$(date -Iseconds),$(cat "$TEMP_SRC" 2>/dev/null),$TEMP_SRC" >> "$RAW/temperature_log.csv"; sleep 5; done ) &
TEMP_PID=$!
cleanup() {
    [ "$GOV_OK" -eq 1 ] && echo "$ORIG_GOV" > "$GOV" 2>/dev/null || true
    kill "$TEMP_PID" 2>/dev/null || true
}
trap cleanup EXIT

SEED="${RUN_ORDER_SEED:-$RANDOM$RANDOM}"
{
    echo "date: $(date -Iseconds)"
    echo "scaling_governor (as found): $ORIG_GOV; enforced performance: $([ $GOV_OK -eq 1 ] && echo yes || echo NO)"
    echo "boost: $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo 'not readable')"
    echo "taskset_core: $TASKSET_CORE"
    echo "reps: $REPS warmup: $WARMUP inner_loop: $INNER_LOOP"
    echo "run_order_seed: $SEED"
    echo "cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2-)"
    echo "kernel: $(uname -r)"
    G=(git -c safe.directory='*' -C "$EXP/..")
    echo "code commit: $("${G[@]}" rev-parse HEAD 2>/dev/null || echo unknown); uncommitted changes in experiments/{openfhe,seal/src,scripts}: $("${G[@]}" status --porcelain -- experiments/openfhe experiments/seal/src experiments/scripts 2>/dev/null | wc -l)"
    echo "images: seal-env $(docker image inspect -f '{{.Id}}' seal-env) openfhe-env $(docker image inspect -f '{{.Id}}' openfhe-env)"
} > "$RAW/cpu_state.txt"
RUN_META="$EXP/results/run_metadata.csv"
[ -f "$RUN_META" ] || echo "timestamp,scenario,run_order_seed,num_cells" > "$RUN_META"

CELLS=()
for op in keygen encrypt decrypt decrypt_full add add_inplace multiply relinearize rotate; do CELLS+=("openfhe,$op,"); done
for op in keygen encrypt decrypt add multiply relinearize rotate; do CELLS+=("seal,$op,"); done
for op in encrypt decrypt add multiply relinearize rotate; do CELLS+=("seal,$op,30"); done
mapfile -t ORDER < <(printf '%s\n' "${CELLS[@]}" | \
    shuf --random-source=<(openssl enc -aes-256-ctr -pass pass:"$SEED" -nosalt </dev/zero 2>/dev/null))
[ "$NAME" = "pilot" ] && echo "$(date -Iseconds),openfhe_pilot,$SEED,${#ORDER[@]}" >> "$RUN_META"
echo "Pilot: ${#ORDER[@]} cells, order seed $SEED, governor enforced: $GOV_OK"

i=0
for cell in "${ORDER[@]}"; do
    i=$((i + 1))
    IFS=, read -r LIB OP SCALE <<< "$cell"
    TAG="${LIB}_ckks_N8192_cat1_${OP}${SCALE:+_scale$SCALE}"
    OUT="$RAW/$TAG.csv"
    if [ -f "$OUT" ] && [ "$(tail -n +2 "$OUT" | wc -l)" -ge "$EXPECTED_ROWS" ]; then
        echo "[$i/${#ORDER[@]}] SKIPPED (complete): $TAG"; continue
    fi
    [ "$OP" = "keygen" ] || [ "$OP" = "rotate" ] && LOOP=1 || LOOP=$INNER_LOOP
    echo "[$i/${#ORDER[@]}] $(date +%H:%M:%S) $TAG  (CPU $(( $(cat "$TEMP_SRC") / 1000 )) °C)"
    COMMON=(--scheme=CKKS --N=8192 --category=1 --operation="$OP" --reps="$REPS" --warmup="$WARMUP"
            --out="/work/results/raw/$NAME/$TAG.csv")
    if [ "$LIB" = "openfhe" ]; then
        docker run --rm -e TASKSET_CORE="$TASKSET_CORE" -e LD_LIBRARY_PATH=/usr/local/lib -v "$EXP":/work -w /work/openfhe \
            openfhe-env bash /work/scripts/_inner_measure.sh /work/openfhe/build/bench_openfhe \
            "/work/results/logs/$NAME/${TAG}_mem.log" "${COMMON[@]}" --inner-loop="$LOOP" \
            --eligible=/work/openfhe/probe/eligible_v2.csv \
            --check-out="/work/results/raw/$NAME/checks/${TAG}_check.csv" || echo "   (non-zero exit -- check)"
    else
        EXTRA=(); [ "$OP" != "keygen" ] && [ "$OP" != "rotate" ] && EXTRA+=(--inner-loop="$LOOP")
        [ -n "$SCALE" ] && EXTRA+=(--ckks-scale-bits="$SCALE")
        docker run --rm -e TASKSET_CORE="$TASKSET_CORE" -v "$EXP":/work -w /work/seal \
            seal-env bash /work/scripts/_inner_measure.sh /work/seal/build/bench_seal \
            "/work/results/logs/$NAME/${TAG}_mem.log" "${COMMON[@]}" "${EXTRA[@]}" \
            --grid=/work/config/param_grid.csv || echo "   (non-zero exit -- check)"
    fi
done
echo "Pilot complete: $(date +%H:%M:%S). Next: cd experiments/scripts && python3 aggregate.py --scenario=pilot"
