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

if [ ! -d "$HERE/lattice-estimator/.git" ]; then
    git clone -q https://github.com/malb/lattice-estimator.git "$HERE/lattice-estimator"
fi
git -C "$HERE/lattice-estimator" checkout -q "$ESTIMATOR_COMMIT"

# Runs as the image's own "sage" user (sage is installed under /home/sage,
# unreadable to other users); the result is streamed back on stdout so the
# output file belongs to the host user. Progress goes to stderr.
COMMIT="$(git -C "$HERE/lattice-estimator" rev-parse HEAD)"
LOG="$HERE/estimator_progress.log"   # watched live by monitor_estimator.sh
echo "$(date +%H:%M:%S) RUN mode=$MODE N=${NS[*]} categories=${CATS:-1 3 5} cpu_share=${CPU_SHARE:-1} total=$(( ${#NS[@]} * $(echo ${CATS:-1 3 5} | wc -w) * 2 ))" >> "$LOG"
docker run --rm --cpus="${CPU_SHARE:-1}" \
    -v "$HERE":/work:ro -v "$HERE/lattice-estimator":/estimator:ro \
    -e PYTHONPATH=/estimator -e ESTIMATOR_COMMIT="$COMMIT" "$SAGE_IMAGE" \
    "cd /work && nice -n 19 sage -python estimate_seal.py --mode $MODE --N ${NS[*]} --categories ${CATS:-1 3 5} --jobs 1 --out /tmp/out.csv >&2 && cat /tmp/out.csv" \
    > "$HERE/results_${MODE}${OUT_SUFFIX:-}.csv.part" \
    2> >(stdbuf -oL tee -a "$LOG" >&2)
mv "$HERE/results_${MODE}${OUT_SUFFIX:-}.csv.part" "$HERE/results_${MODE}${OUT_SUFFIX:-}.csv"
echo "wrote results_${MODE}${OUT_SUFFIX:-}.csv (estimator $COMMIT)" | tee -a "$LOG"
