#!/usr/bin/env bash
# run_probe_docker.sh -- records what Lattigo v5.0.7 builds from SEAL's exact
# primes (lattigo_params.csv) for BFV, BGV and CKKS at N=8192, category 1:
# primes, log2 QP, secret and error distributions, slots, and a depth test
# (fresh inputs, multiplication + relinearization (+ rescaling for BGV and
# CKKS) repeated three times, every result decrypted and checked).
# Requires experiments/lattigo/build/bench_lattigo (docker_build.sh). No sudo.
set -euo pipefail
cd "$(dirname "$0")/.."
EXP="$(cd .. && pwd)"
docker run --rm -u "$(id -u):$(id -g)" -v "$EXP":/work -w /work/lattigo lattigo-env bash -c '
  build/bench_lattigo --scheme=BFV --N=8192 --category=1 --operation=probe --params=probe/lattigo_params.csv | head -1
  for s in BFV BGV CKKS; do build/bench_lattigo --scheme=$s --N=8192 --category=1 --operation=probe --params=probe/lattigo_params.csv | tail -1; done
' > probe/probe_results.csv
echo "wrote experiments/lattigo/probe/probe_results.csv"
