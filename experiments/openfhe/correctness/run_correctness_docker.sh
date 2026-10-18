#!/usr/bin/env bash
# Build and run openfhe_correctness in the pinned openfhe-env image
# (experiments/openfhe/Dockerfile), with the SEAL harness flags
# (g++ 13.3.0, -std=c++17 -O2; OpenFHE without OpenMP: single-threaded).
# Input: ../probe/eligible_v2.csv. Output: correctness_v2.csv (this directory).
# Then a negative control (negative_controls.csv -> negative_controls_out.csv):
# two configurations known to be wrong (CKKS N=2048/category 3, whose
# decryption error exceeds the threshold, and BFV N=8192/category 5
# multiplication at depth 0), which must FAIL -- showing that the check can
# detect an incorrect operation and does not pass everything.
# Usage (from anywhere):  bash run_correctness_docker.sh [trials=100]
set -euo pipefail
cd "$(dirname "$0")"
TRIALS="${1:-100}"
EXP="$(cd .. && cd .. && pwd)"
docker run --rm -u "$(id -u):$(id -g)" -v "$EXP":/work -w /work/openfhe/correctness openfhe-env bash -c "
  set -e
  I=/usr/local/include/openfhe
  g++ -std=c++17 -O2 -I\$I -I\$I/core -I\$I/pke -I\$I/binfhe -I\$I/cereal openfhe_correctness.cpp \
      -o /tmp/correctness -L/usr/local/lib -lOPENFHEpke -lOPENFHEcore -lOPENFHEbinfhe
  LD_LIBRARY_PATH=/usr/local/lib /tmp/correctness ../probe/eligible_v2.csv correctness_v2.csv $TRIALS
  LD_LIBRARY_PATH=/usr/local/lib /tmp/correctness negative_controls.csv negative_controls_out.csv $TRIALS
"
