#!/usr/bin/env bash
# docker_build.sh -- compile bench_helib in the helib-env image (HElib v2.3.0, commit 3e337a6, whose version header reports 2.2.0;
# NTL and GMP from Ubuntu 24.04) with the SEAL/OpenFHE harness flags: g++
# 13.3.0, -std=c++17 -O2. HElib is linked statically (libhelib.a, built
# RelWithDebInfo); NTL's thread pool is not activated, so the binary is
# single-threaded (bench_helib checks NTL::AvailableThreads() == 1). It runs
# inside helib-env.  Usage:  bash experiments/helib/docker_build.sh
set -euo pipefail
cd "$(dirname "$0")"
EXP="$(cd .. && pwd)"
docker run --rm -u "$(id -u):$(id -g)" -v "$EXP":/work -w /work/helib helib-env bash -c '
  set -e
  mkdir -p build
  g++ -std=c++17 -O2 -I/usr/local/include src/bench_helib.cpp -o build/bench_helib \
      -L/usr/local/lib -lhelib -lntl -lgmp -pthread
  g++ --version | head -1
  echo "Build OK: experiments/helib/build/bench_helib"
'
