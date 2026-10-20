#!/usr/bin/env bash
# run_pilot_docker.sh — the OpenFHE pilot: CKKS, N=8192, category 1, measured
# in ONE session together with SEAL under the same conditions, plus SEAL's
# scale test. Fail-closed (session_lib.sh): every cell is validated with its
# correctness checks, a failure stops the session, resume re-validates.
#
# Run on the HOST with sudo (the CPU governor of the pinned core is set to
# "performance" and restored on exit):
#   sudo bash experiments/openfhe/run_pilot_docker.sh
# Prerequisites (no sudo): bash experiments/seal/docker_build_and_run.sh and
# bash experiments/openfhe/docker_build.sh.
#
# Cells (22), Standard-scenario protocol of the SEAL campaign: 100 measured
# repetitions after 5 warm-up, inner loop 1000 (keygen and rotate: one call
# per repetition), one docker run per cell, process pinned to one core,
# randomized order with a recorded seed; thermal/frequency log every second.
#   OpenFHE: keygen encrypt decrypt decrypt_full add add_inplace multiply relinearize rotate
#   SEAL:    keygen encrypt decrypt add multiply relinearize rotate
#   SEAL at CKKS scale 2^30 instead of 2^40, same primes:
#            encrypt decrypt add multiply relinearize rotate
# Outputs: experiments/results/raw/<PILOT_NAME>/ (raw CSVs, checks/, memory/,
# cpu_state.txt, thermal_log.csv). Statistics:
#   cd experiments/scripts && python3 aggregate.py --scenario=pilot
#
# Test-only overrides (a dry run must not touch the real pilot directory):
#   PILOT_NAME=_pilot_test REPS=2 WARMUP=1 INNER_LOOP=5 bash run_pilot_docker.sh
# and, to demonstrate fail-closed behaviour, a wrong result injected in one cell:
#   ... INJECT_TAG=openfhe_ckks_N8192_cat1_add INJECT_AT=1 bash run_pilot_docker.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP="$(cd "$SCRIPT_DIR/.." && pwd)"
NAME="${PILOT_NAME:-pilot}"
SESSION_DIR="$EXP/results/raw/$NAME"
LOG_DIR="$EXP/results/logs/$NAME"
REPS="${REPS:-100}"; WARMUP="${WARMUP:-5}"; INNER_LOOP="${INNER_LOOP:-1000}"
ROWS=$((REPS + WARMUP))
TASKSET_CORE="${TASKSET_CORE:-0}"
DOCKER_EXTRA=()
source "$SCRIPT_DIR/session_lib.sh"

for f in "$EXP/seal/build/bench_seal" "$EXP/openfhe/build/bench_openfhe"; do
    [ -x "$f" ] || { echo "ERROR: $f not built (see the header of this script)" >&2; exit 1; }
done

SEED="${RUN_ORDER_SEED:-$RANDOM$RANDOM}"
session_start "openfhe_pilot" "$SEED"
echo "reps: $REPS warmup: $WARMUP inner_loop: $INNER_LOOP" >> "$SESSION_DIR/cpu_state.txt"

CELLS=()
for op in keygen encrypt decrypt decrypt_full add add_inplace multiply relinearize rotate; do CELLS+=("openfhe,$op,"); done
for op in keygen encrypt decrypt add multiply relinearize rotate; do CELLS+=("seal,$op,"); done
for op in encrypt decrypt add multiply relinearize rotate; do CELLS+=("seal,$op,30"); done
mapfile -t ORDER < <(printf '%s\n' "${CELLS[@]}" | \
    shuf --random-source=<(openssl enc -aes-256-ctr -pass pass:"$SEED" -nosalt </dev/zero 2>/dev/null))
RUN_META="$EXP/results/run_metadata.csv"
[ "$NAME" = "pilot" ] && echo "$(date -Iseconds),openfhe_pilot,$SEED,${#ORDER[@]}" >> "$RUN_META"
echo "Pilot: ${#ORDER[@]} cells, order seed $SEED, governor enforced: $GOV_OK"

i=0
for cell in "${ORDER[@]}"; do
    i=$((i + 1))
    IFS=, read -r LIB OP SCALE <<< "$cell"
    TAG="${LIB}_ckks_N8192_cat1_${OP}${SCALE:+_scale$SCALE}"
    { [ "$OP" = "keygen" ] || [ "$OP" = "rotate" ]; } && LOOP=1 || LOOP=$INNER_LOOP
    echo "[$i/${#ORDER[@]}] $(date +%H:%M:%S) $TAG  (CPU $(temp_c) °C)"
    ARGS=(--scheme=CKKS --N=8192 --category=1 --operation="$OP" --reps="$REPS" --warmup="$WARMUP" --inner-loop="$LOOP")
    [ -n "$SCALE" ] && ARGS+=(--ckks-scale-bits="$SCALE")
    [ "$TAG" = "${INJECT_TAG:-}" ] && ARGS+=(--inject-mismatch-at="${INJECT_AT:-1}")  # TESTS ONLY
    run_cell "$LIB" "$TAG" "$ROWS" "$WARMUP" "${ARGS[@]}"
done
echo "Pilot complete: $(date +%H:%M:%S). Next: cd experiments/scripts && python3 aggregate.py --scenario=pilot"
