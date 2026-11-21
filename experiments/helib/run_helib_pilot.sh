#!/usr/bin/env bash
# run_helib_pilot.sh -- the HElib latency pilot (supervisor, 7 and 18 Nov
# 2026: one latency pilot, documenting the actual security parameters, the
# operation boundaries and the achieved CKKS precision). N=8192, category 1,
# CKKS and BGV (HElib has no BFV), measured in ONE session together with SEAL
# under the same conditions, as the OpenFHE pilot (openfhe/run_pilot_docker.sh).
# Fail-closed (openfhe/session_lib.sh): every cell is validated with its
# correctness checks, a failure stops the session, resume re-validates.
#
# Run on the HOST with sudo (the CPU governor of the pinned core is set to
# "performance" and restored on exit; boost as found, recorded):
#   sudo bash experiments/helib/run_helib_pilot.sh
# Prerequisites (no sudo): bash experiments/seal/docker_build_and_run.sh,
# bash experiments/helib/docker_build.sh, and helib/probe/helib_params.csv
# (helib/probe/run_probe_docker.sh, then make_params.py).
#
# Cells (30): Standard-scenario protocol with 100 measured repetitions after 5
# warm-up, one docker run per cell, process pinned to one core, randomized
# order with a recorded seed, thermal/frequency log every second.
#   HElib (CKKS, BGV): keygen encrypt decrypt decrypt_full add_inplace multiply relinearize rotate
#   SEAL  (CKKS, BGV): keygen encrypt decrypt add multiply relinearize rotate
# Inner loop: 10 calls per repetition (the SEAL/OpenFHE pilot used 1000; here
# every call needs a fresh HElib input, about 30 ms to encode and encrypt for
# BGV, outside the timing, so 1000 would make one cell last hours; 10 calls of
# the fastest operation, 0.06 ms, still last far longer than the clock's
# resolution). One call per repetition for keygen, rotate and BGV
# decrypt_full (about 0.6 s per call). SEAL cells use the same settings.
# Outputs: experiments/results/raw/<PILOT_NAME>/ (raw CSVs, checks/, memory
# logs, cpu_state.txt, thermal_log.csv, cell_times.csv, and helib.log: HElib's
# own warnings, e.g. "KS-noise-ratio" for rotations and "non-optimal
# targetSize" when a BGV context is built; every result is still checked).
#
# Test-only overrides (a dry run must not touch the real pilot directory):
#   PILOT_NAME=_helib_dry REPS=2 WARMUP=1 INNER_LOOP=2 bash run_helib_pilot.sh
# and, to demonstrate fail-closed behaviour, a wrong result injected in one cell:
#   ... INJECT_TAG=helib_ckks_N8192_cat1_add_inplace INJECT_AT=1 bash run_helib_pilot.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP="$(cd "$SCRIPT_DIR/.." && pwd)"
NAME="${PILOT_NAME:-helib_pilot}"
SESSION_DIR="$EXP/results/raw/$NAME"
LOG_DIR="$EXP/results/logs/$NAME"
REPS="${REPS:-100}"; WARMUP="${WARMUP:-5}"; INNER_LOOP="${INNER_LOOP:-10}"
ROWS=$((REPS + WARMUP))
TASKSET_CORE="${TASKSET_CORE:-0}"
DOCKER_EXTRA=()
source "$EXP/openfhe/session_lib.sh"

for f in "$EXP/seal/build/bench_seal" "$EXP/helib/build/bench_helib" "$EXP/helib/probe/helib_params.csv"; do
    [ -e "$f" ] || { echo "ERROR: $f missing (see the header of this script)" >&2; exit 1; }
done

SEED="${RUN_ORDER_SEED:-$RANDOM$RANDOM}"
session_start "helib_pilot" "$SEED"
{
    echo "reps: $REPS warmup: $WARMUP inner_loop: $INNER_LOOP (keygen, rotate, BGV decrypt_full: 1)"
    echo "helib params: $(sha256sum "$EXP/helib/probe/helib_params.csv" | cut -c1-16) (helib/probe/helib_params.csv)"
} >> "$SESSION_DIR/cpu_state.txt"

CELLS=()
for s in ckks bgv; do
    for op in keygen encrypt decrypt decrypt_full add_inplace multiply relinearize rotate; do CELLS+=("helib,$s,$op"); done
    for op in keygen encrypt decrypt add multiply relinearize rotate; do CELLS+=("seal,$s,$op"); done
done
mapfile -t ORDER < <(printf '%s\n' "${CELLS[@]}" | \
    shuf --random-source=<(openssl enc -aes-256-ctr -pass pass:"$SEED" -nosalt </dev/zero 2>/dev/null))
RUN_META="$EXP/results/run_metadata.csv"
[ "$NAME" = "helib_pilot" ] && echo "$(date -Iseconds),helib_pilot,$SEED,${#ORDER[@]}" >> "$RUN_META"
echo "HElib pilot: ${#ORDER[@]} cells, order seed $SEED, governor enforced: $GOV_OK"

i=0
for cell in "${ORDER[@]}"; do
    i=$((i + 1))
    IFS=, read -r LIB S OP <<< "$cell"
    TAG="${LIB}_${S}_N8192_cat1_${OP}"
    LOOP=$INNER_LOOP
    { [ "$OP" = "keygen" ] || [ "$OP" = "rotate" ] || [ "$S/$OP" = "bgv/decrypt_full" ]; } && LOOP=1
    echo "[$i/${#ORDER[@]}] $(date +%H:%M:%S) $TAG  (CPU $(temp_c) °C)"
    ARGS=(--scheme="${S^^}" --N=8192 --category=1 --operation="$OP" --reps="$REPS" --warmup="$WARMUP" --inner-loop="$LOOP")
    [ "$TAG" = "${INJECT_TAG:-}" ] && ARGS+=(--inject-mismatch-at="${INJECT_AT:-1}")  # TESTS ONLY
    run_cell "$LIB" "$TAG" "$ROWS" "$WARMUP" "${ARGS[@]}"
done
echo "HElib pilot complete: $(date +%H:%M:%S). Next: cd experiments/scripts && python3 aggregate.py --scenario=helib_pilot"
