#!/usr/bin/env bash
# run_estimator_docker.sh — reproduce the Lattice Estimator results of the
# SEAL report (security-level validation). No sudo.
#
#   bash run_estimator_docker.sh rough          # all 9 configurations, N<=8192 (minutes)
#   bash run_estimator_docker.sh full 2048 4096 # every attack, selected N (slower)
#   options: CPU_SHARE=0.6 (cooler, slower), CATS="1 3" (subset of categories),
#            OUT_SUFFIX=_N2048 (output file results_<mode><suffix>.csv)
#
# Fetches the estimator at the pinned commit into ./lattice-estimator (not
# tracked), regenerates nothing else, and runs estimate_seal.py inside the
# SageMath image, limited to one core -- or a fraction of one, CPU_SHARE=0.6 -- at low priority (it is CPU-heavy).
# Inputs: seal_moduli.csv (exact SEAL primes; produced by seal_moduli.cpp in
# the seal-env image). Outputs: results_<mode>.csv in this directory.
set -euo pipefail
ESTIMATOR_COMMIT=3e48ef4   # malb/lattice-estimator, 2026-06-27
SAGE_IMAGE="${SAGE_IMAGE:-sagemath/sagemath@sha256:310dfe23fc786f3a5a06a7b0387c60201ec79b32c0db941b7624505ee5edb565}"  # pinned digest
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:?usage: run_estimator_docker.sh rough|full [N ...]}"; shift || true
NS=("$@"); [ ${#NS[@]} -eq 0 ] && NS=(2048 4096 8192)
# TARGET=seal (default): SEAL's own grid, estimate_seal.py, both error models.
# TARGET=openfhe: the OpenFHE candidates (openfhe_candidates.csv, actual
# Q and P primes), estimate_openfhe.py, OpenFHE's Gaussian 3.19 error; full
# mode only; output results_openfhe<OUT_SUFFIX>.csv.
# TARGET=sensitivity: the three OpenFHE candidates at N=8192/category 5
# under the cost models BDGL16 and ADPS16 (sensitivity_openfhe.py); full
# mode, N=8192 only; output results_sensitivity_N8192_cat5.csv.
#   TARGET=sensitivity CPU_SHARE=0.5 bash run_estimator_docker.sh full 8192
# TARGET=sensitivity_seal: the same two cost models for SEAL's own
# N=8192/category 5 configuration (reference point); output
# results_sensitivity_seal_N8192_cat5.csv.
TARGET="${TARGET:-seal}"

if [ ! -d "$HERE/lattice-estimator/.git" ]; then
    git clone -q https://github.com/malb/lattice-estimator.git "$HERE/lattice-estimator"
fi
git -C "$HERE/lattice-estimator" checkout -q "$ESTIMATOR_COMMIT"

# Runs as the image's own "sage" user (sage is installed under /home/sage,
# unreadable to other users); the result is streamed back on stdout so the
# output file belongs to the host user. Progress goes to stderr.
COMMIT="$(git -C "$HERE/lattice-estimator" rev-parse HEAD)"
LOG="$HERE/estimator_progress.log"   # watched live by monitor_estimator.sh
if [ "$TARGET" = "sensitivity" ] || [ "$TARGET" = "sensitivity_seal" ]; then
    [ "$MODE" = "full" ] && [ "${NS[*]}" = "8192" ] || { echo "TARGET=$TARGET: use 'full 8192'" >&2; exit 1; }
    if [ "$TARGET" = "sensitivity" ]; then
        OUT="results_sensitivity_N8192_cat5.csv"; TOTAL=6; CMD="sensitivity_openfhe.py --out /tmp/out.csv"
    else
        OUT="results_sensitivity_seal_N8192_cat5.csv"; TOTAL=2; CMD="sensitivity_openfhe.py --seal --out /tmp/out.csv"
    fi
elif [ "$TARGET" = "openfhe" ]; then
    [ "$MODE" = "full" ] || { echo "TARGET=openfhe supports full mode only" >&2; exit 1; }
    OUT="results_openfhe${OUT_SUFFIX:-}.csv"
    TOTAL=$(awk -F, -v ns=" ${NS[*]} " 'NR > 1 && index(ns, " " $2 " ") {n++} END {print n + 0}' "$HERE/openfhe_candidates.csv")
    CMD="estimate_openfhe.py --N ${NS[*]} --jobs 1 --out /tmp/out.csv"
else
    OUT="results_${MODE}${OUT_SUFFIX:-}.csv"
    TOTAL=$(( ${#NS[@]} * $(echo ${CATS:-1 3 5} | wc -w) * 2 ))
    CMD="estimate_seal.py --mode $MODE --N ${NS[*]} --categories ${CATS:-1 3 5} --jobs 1 --out /tmp/out.csv"
fi
echo "$(date +%H:%M:%S) RUN target=$TARGET mode=$MODE N=${NS[*]} cpu_share=${CPU_SHARE:-1} total=$TOTAL" >> "$LOG"
docker run --rm --cpus="${CPU_SHARE:-1}" \
    -v "$HERE":/work:ro -v "$HERE/lattice-estimator":/estimator:ro \
    -e PYTHONPATH=/estimator -e ESTIMATOR_COMMIT="$COMMIT" "$SAGE_IMAGE" \
    "cd /work && nice -n 19 sage -python $CMD >&2 && cat /tmp/out.csv" \
    > "$HERE/$OUT.part" \
    2> >(stdbuf -oL tee -a "$LOG" >&2)
mv "$HERE/$OUT.part" "$HERE/$OUT"
echo "wrote $OUT (estimator $COMMIT)" | tee -a "$LOG"
