#!/usr/bin/env bash
# run_lattigo_pilot.sh -- the Lattigo latency pilot (supervisor, 7 and 18 Nov
# 2026: one latency pilot, documenting the security parameters, the operation
# boundaries and the achieved CKKS precision). N=8192, category 1, BFV, BGV
# and CKKS, with SEAL's EXACT primes (lattigo/probe/lattigo_params.csv),
# measured in ONE session together with SEAL under the same conditions, with
# the settings of the HElib pilot (helib/run_helib_pilot.sh). Fail-closed
# (openfhe/session_lib.sh): every cell is validated with its correctness
# checks, a failure stops the session, resume re-validates.
#
# Run on the HOST with sudo (the CPU governor of the pinned core is set to
# "performance" and restored on exit; boost as found, recorded):
#   sudo bash experiments/lattigo/run_lattigo_pilot.sh
# Prerequisites (no sudo): bash experiments/seal/docker_build_and_run.sh and
# bash experiments/lattigo/docker_build.sh.
#
# Cells (45): 100 measured repetitions after 5 warm-up, inner loop 10 calls
# per repetition (one call for keygen and rotate), one docker run per cell,
# process pinned to one core, randomized order with a recorded seed,
# thermal/frequency log every second. The inner loop is that of the HElib
# pilot, so that the SEAL cells of both pilots have the same settings.
#   Lattigo (BFV, BGV, CKKS): keygen encrypt decrypt decrypt_full add multiply relinearize rotate
#   SEAL    (BFV, BGV, CKKS): keygen encrypt decrypt add multiply relinearize rotate
# Outputs: experiments/results/raw/<PILOT_NAME>/ (raw CSVs, checks/, memory
# logs, cpu_state.txt, thermal_log.csv, cell_times.csv).
#
# Test-only overrides (a dry run must not touch the real pilot directory):
#   PILOT_NAME=_lattigo_dry REPS=2 WARMUP=1 INNER_LOOP=2 bash run_lattigo_pilot.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP="$(cd "$SCRIPT_DIR/.." && pwd)"
NAME="${PILOT_NAME:-lattigo_pilot}"
SESSION_DIR="$EXP/results/raw/$NAME"
LOG_DIR="$EXP/results/logs/$NAME"
REPS="${REPS:-100}"; WARMUP="${WARMUP:-5}"; INNER_LOOP="${INNER_LOOP:-10}"
ROWS=$((REPS + WARMUP))
TASKSET_CORE="${TASKSET_CORE:-0}"
DOCKER_EXTRA=()
source "$EXP/openfhe/session_lib.sh"

for f in "$EXP/seal/build/bench_seal" "$EXP/lattigo/build/bench_lattigo" "$EXP/lattigo/probe/lattigo_params.csv"; do
    [ -e "$f" ] || { echo "ERROR: $f missing (see the header of this script)" >&2; exit 1; }
done

SEED="${RUN_ORDER_SEED:-$RANDOM$RANDOM}"
session_start "lattigo_pilot" "$SEED"
{
    echo "reps: $REPS warmup: $WARMUP inner_loop: $INNER_LOOP (keygen, rotate: 1)"
    echo "lattigo params: $(sha256sum "$EXP/lattigo/probe/lattigo_params.csv" | cut -c1-16) (lattigo/probe/lattigo_params.csv)"
} >> "$SESSION_DIR/cpu_state.txt"

CELLS=()
for s in bfv bgv ckks; do
    for op in keygen encrypt decrypt decrypt_full add multiply relinearize rotate; do CELLS+=("lattigo,$s,$op"); done
    for op in keygen encrypt decrypt add multiply relinearize rotate; do CELLS+=("seal,$s,$op"); done
done
mapfile -t ORDER < <(printf '%s\n' "${CELLS[@]}" | \
    shuf --random-source=<(openssl enc -aes-256-ctr -pass pass:"$SEED" -nosalt </dev/zero 2>/dev/null))
RUN_META="$EXP/results/run_metadata.csv"
[ "$NAME" = "lattigo_pilot" ] && echo "$(date -Iseconds),lattigo_pilot,$SEED,${#ORDER[@]}" >> "$RUN_META"
echo "Lattigo pilot: ${#ORDER[@]} cells, order seed $SEED, governor enforced: $GOV_OK"

i=0
for cell in "${ORDER[@]}"; do
    i=$((i + 1))
    IFS=, read -r LIB S OP <<< "$cell"
    TAG="${LIB}_${S}_N8192_cat1_${OP}"
    LOOP=$INNER_LOOP
    { [ "$OP" = "keygen" ] || [ "$OP" = "rotate" ]; } && LOOP=1
    echo "[$i/${#ORDER[@]}] $(date +%H:%M:%S) $TAG  (CPU $(temp_c) °C)"
    ARGS=(--scheme="${S^^}" --N=8192 --category=1 --operation="$OP" --reps="$REPS" --warmup="$WARMUP" --inner-loop="$LOOP")
    [ "$TAG" = "${INJECT_TAG:-}" ] && ARGS+=(--inject-mismatch-at="${INJECT_AT:-1}")  # TESTS ONLY
    run_cell "$LIB" "$TAG" "$ROWS" "$WARMUP" "${ARGS[@]}"
done
echo "Lattigo pilot complete: $(date +%H:%M:%S). Next: cd experiments/scripts && python3 aggregate.py --scenario=lattigo_pilot"
