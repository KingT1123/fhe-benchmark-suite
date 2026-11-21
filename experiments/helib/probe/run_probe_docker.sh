#!/usr/bin/env bash
# run_probe_docker.sh -- records what HElib v2.3.0 (commit 3e337a6; its version header reports 2.2.0) builds for each candidate
# (bits, c[, precision]) at N=8192 (m=16384), CKKS and BGV (p = SEAL's t),
# in the helib-env image. Output: helib/probe/probe_results.csv. No sudo.
set -euo pipefail
cd "$(dirname "$0")/.."
EXP="$(cd .. && pwd)"
docker run --rm -u "$(id -u):$(id -g)" -v "$EXP":/work -w /work/helib helib-env bash -c '
  set -e
  mkdir -p build
  g++ -std=c++17 -O2 -I/usr/local/include probe/helib_probe.cpp -o build/helib_probe -L/usr/local/lib -lhelib -lntl -lgmp -pthread
  build/helib_probe CKKS 119 2 | head -1
  for s in CKKS BGV; do for b in 100 119 120 130 140 150 160 170; do for c in 2 3; do build/helib_probe $s $b $c | tail -1; done; done; done
  for p in 25 30 35 40; do build/helib_probe CKKS 119 2 $p | tail -1; done
' > probe/probe_results.csv
echo "wrote experiments/helib/probe/probe_results.csv ($(($(wc -l < probe/probe_results.csv) - 1)) candidates)"
