#!/usr/bin/env bash
# run_validation_session.sh — the targeted validation requested after the
# pilot (one independent session, fail-closed, thermal/frequency log):
#
# A. Relinearization scale test, repeated. SEAL CKKS N=8192/category 1,
#    relinearize at scale 2^40 and 2^30 on the same primes, in 8 blocks of
#    25 measured repetitions (after 5 warm-up, inner loop 1000), alternating
#    the scales in counterbalanced order A B B A A B B A, so that a drift
#    over the session (warming, thermal state) affects both scales alike.
#    Pooled per scale: 100 measured repetitions, as in the pilot.
# B. Limited validation of the dedicated energy/memory procedure of the SEAL
#    campaign (scripts/run_energy_memory_docker.sh) applied to both
#    libraries: CKKS N=8192/category 1, keygen, encrypt, multiply,
#    relinearize, for SEAL and OpenFHE. Per cell: the energy invocation
#    (RAPL around the timed window only, 30 reps after 2 warm-up, idle
#    6 s settle + 4 s window, 2 s ramp, inner loop for a ~50 ms window:
#    validation/energy_plan_ckks8192.csv) run TWICE, for repeatability, and
#    3 memory invocations (inner loop 1, 10 reps after 2 warm-up, VmHWM).
#    Cells in randomized order (seed recorded).
#
# Run on the HOST with sudo (CPU governor; the RAPL counter needs root):
#   sudo bash experiments/openfhe/run_validation_session.sh
# Prerequisites (no sudo): bash experiments/seal/docker_build_and_run.sh and
# bash experiments/openfhe/docker_build.sh.
# Output: experiments/results/raw/validation_v2/. Statistics:
#   cd experiments/scripts && python3 aggregate.py --scenario=validation
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP="$(cd "$SCRIPT_DIR/.." && pwd)"
NAME="${SESSION_NAME:-validation_v2}"   # test runs: SESSION_NAME=_val_test QUICK=1
SESSION_DIR="$EXP/results/raw/$NAME"
LOG_DIR="$EXP/results/logs/$NAME"
TASKSET_CORE="${TASKSET_CORE:-0}"
QUICK="${QUICK:-0}"                     # QUICK=1: tiny repetition counts, for a dry run only
if [ "$QUICK" = 1 ]; then RB=2; WB=1; INNER=5; ER=2; EW=1; MR=2; MW=1; SETTLE=0; IDLE=1; RAMP=0
else RB=25; WB=5; INNER=1000; ER=30; EW=2; MR=10; MW=2; SETTLE=6; IDLE=4; RAMP=2; fi
DOCKER_EXTRA=()
source "$SCRIPT_DIR/session_lib.sh"

for f in "$EXP/seal/build/bench_seal" "$EXP/openfhe/build/bench_openfhe"; do
    [ -x "$f" ] || { echo "ERROR: $f not built (see the header of this script)" >&2; exit 1; }
done
RAPL_HOST_DIR="$(realpath /sys/class/powercap/intel-rapl:0)"
[ -r "$RAPL_HOST_DIR/energy_uj" ] || [ "$QUICK" = 1 ] || { echo "ERROR: RAPL counter not readable -- run with sudo" >&2; exit 1; }

SEED="${RUN_ORDER_SEED:-$RANDOM$RANDOM}"
session_start "validation_v2" "$SEED"
{
    echo "A: relinearize blocks: $RB measured + $WB warm-up, inner loop $INNER, order 40 30 30 40 40 30 30 40"
    echo "B: energy: $ER reps + $EW warm-up x 2 invocations; idle ${SETTLE}s settle + ${IDLE}s window, ${RAMP}s ramp; memory: 3 x ($MR reps + $MW warm-up) at inner loop 1"
} >> "$SESSION_DIR/cpu_state.txt"
[ "$NAME" = "validation_v2" ] && echo "$(date -Iseconds),validation_v2,$SEED,40" >> "$EXP/results/run_metadata.csv"

COMMON=(--scheme=CKKS --N=8192 --category=1)

echo "== A. relinearization scale test, 8 alternating blocks =="
b=0
for scale in 40 30 30 40 40 30 30 40; do
    b=$((b + 1))
    TAG="seal_ckks_N8192_cat1_relinearize_scale${scale}_b${b}"
    echo "[A $b/8] $(date +%H:%M:%S) $TAG  (CPU $(temp_c) °C)"
    run_cell seal "$TAG" $((RB + WB)) "$WB" "${COMMON[@]}" --operation=relinearize \
        --reps="$RB" --warmup="$WB" --inner-loop="$INNER" --ckks-scale-bits="$scale"
done

echo "== B. energy/memory validation =="
CELLS=()
while IFS=, read -r LIB OP LAT INNER_E SRC; do
    for k in 1 2; do CELLS+=("$LIB,$OP,$INNER_E,energy$k"); done
    for k in 1 2 3; do CELLS+=("$LIB,$OP,1,mem$k"); done
done < <(tail -n +2 "$SCRIPT_DIR/validation/energy_plan_ckks8192.csv")
mapfile -t ORDER < <(printf '%s\n' "${CELLS[@]}" | \
    shuf --random-source=<(openssl enc -aes-256-ctr -pass pass:"$SEED" -nosalt </dev/zero 2>/dev/null))
DOCKER_EXTRA=(--mount "type=bind,source=$RAPL_HOST_DIR,target=/rapl,readonly")
RUN_DIRECT=1   # energy/memory cells: harness started directly, no polling process (SEAL protocol)
i=0
for cell in "${ORDER[@]}"; do
    i=$((i + 1))
    IFS=, read -r LIB OP INNER_E KIND <<< "$cell"
    TAG="${LIB}_ckks_N8192_cat1_${OP}_${KIND}"
    [ "$QUICK" = 1 ] && [ "$INNER_E" -gt 5 ] && INNER_E=5
    echo "[B $i/${#ORDER[@]}] $(date +%H:%M:%S) $TAG  (CPU $(temp_c) °C)"
    if [[ "$KIND" == energy* ]]; then
        E_ARGS=(--rapl-dir=/rapl --idle-settle-seconds="$SETTLE" --idle-seconds="$IDLE" --ramp-seconds="$RAMP")
        [ "$QUICK" = 1 ] && [ ! -r "$RAPL_HOST_DIR/energy_uj" ] && E_ARGS=()
        run_cell "$LIB" "$TAG" $((ER + EW)) "$EW" "${COMMON[@]}" --operation="$OP" --reps="$ER" --warmup="$EW" \
            --inner-loop="$INNER_E" "${E_ARGS[@]}"
    else
        run_cell "$LIB" "$TAG" $((MR + MW)) "$MW" "${COMMON[@]}" --operation="$OP" --reps="$MR" --warmup="$MW" \
            --inner-loop=1 --peak-rss-out="/work/${SESSION_DIR#$EXP/}/memory/${TAG}_peak.log"
    fi
done
echo "Validation session complete: $(date +%H:%M:%S). Next: cd experiments/scripts && python3 aggregate.py --scenario=validation"
