#!/usr/bin/env bash
# docker_build.sh — compile bench_openfhe in the pinned openfhe-env image
# (experiments/openfhe/Dockerfile) with the SEAL harness flags: g++ 13.3.0,
# -std=c++17 -O2. OpenFHE is built without OpenMP, so the binary is
# single-threaded. It links OpenFHE's shared libraries, so it runs only
# inside openfhe-env (LD_LIBRARY_PATH=/usr/local/lib), like bench_seal in
# seal-env.  Usage:  bash experiments/openfhe/docker_build.sh
set -euo pipefail
cd "$(dirname "$0")"
EXP="$(cd .. && pwd)"
docker run --rm -u "$(id -u):$(id -g)" -v "$EXP":/work -w /work/openfhe openfhe-env bash -c '
  set -e
  mkdir -p build
  I=/usr/local/include/openfhe
  g++ -std=c++17 -O2 -I$I -I$I/core -I$I/pke -I$I/binfhe -I$I/cereal src/bench_openfhe.cpp \
      -o build/bench_openfhe -L/usr/local/lib -lOPENFHEpke -lOPENFHEcore -lOPENFHEbinfhe
  g++ --version | head -1
  echo "Build OK: experiments/openfhe/build/bench_openfhe"
'
