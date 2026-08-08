#!/usr/bin/env bash
# docker_build_and_run.sh
#
# Run this on your HOST machine (normal terminal, NOT inside Docker).
# It does everything for you: opens your seal-env container, finds SEAL
# inside it, compiles bench_seal, and runs one test to prove it works.
#
# Usage:
#   cd experiments/seal
#   bash docker_build_and_run.sh
#
# If your image isn't called "seal-env", run:
#   IMAGE=your-image-name bash docker_build_and_run.sh

set -e
IMAGE="${IMAGE:-seal-env}"
SEAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # .../experiments/seal
EXPERIMENTS_DIR="$(dirname "$SEAL_DIR")"                       # .../experiments

echo "== Using Docker image: $IMAGE =="
echo "   (check available images with: docker images)"
echo "== Mounting: $EXPERIMENTS_DIR -> /work inside the container =="
echo

docker run --rm -v "$EXPERIMENTS_DIR":/work -w /work/seal "$IMAGE" bash -c '
set -e
echo "-- Locating SEAL inside the container --"
SEAL_H=$(find / -iname "seal.h" -path "*seal/seal.h" 2>/dev/null | head -1)
CONFIG_H=$(find / -path "*seal/util/config.h" 2>/dev/null | head -1)
LIBSEAL=$(find / -iname "libseal*.a" 2>/dev/null | head -1)
GSL_SPAN=$(find / -path "*gsl/span" 2>/dev/null | head -1)
LIBZSTD=$(find / -iname "libzstd.a" 2>/dev/null | head -1)
LIBZ=$(find / -iname "libz.a" 2>/dev/null | head -1)

echo "  seal.h found at   : ${SEAL_H:-NOT FOUND}"
echo "  config.h found at : ${CONFIG_H:-NOT FOUND}"
echo "  libseal found at  : ${LIBSEAL:-NOT FOUND}"
echo "  gsl/span found at : ${GSL_SPAN:-NOT FOUND}"
echo "  libzstd found at  : ${LIBZSTD:-not found, will try without it}"
echo "  libz found at     : ${LIBZ:-not found, will try without it}"
echo

if [ -z "$SEAL_H" ] || [ -z "$LIBSEAL" ] || [ -z "$GSL_SPAN" ] || [ -z "$CONFIG_H" ]; then
    echo "STOP: could not auto-locate SEAL inside this image."
    echo "Paste this whole output back to Claude and we will fix the paths by hand."
    exit 1
fi

SEAL_INCLUDE=$(dirname $(dirname "$SEAL_H"))          # .../native/src (source headers)
SEAL_BUILD_INCLUDE=$(dirname $(dirname $(dirname "$CONFIG_H")))  # .../native/src (generated config.h, separate build-dir tree)
GSL_INCLUDE=$(dirname $(dirname "$GSL_SPAN"))          # .../include
LIB_DIR=$(dirname "$LIBSEAL")

echo "-- Compiling bench_seal --"
mkdir -p build
g++ -std=c++17 -O2 \
  -I"$SEAL_INCLUDE" -I"$SEAL_BUILD_INCLUDE" -I"$GSL_INCLUDE" \
  -c src/bench_seal.cpp -o build/bench_seal.o

EXTRA_LIBS=""
[ -n "$LIBZSTD" ] && EXTRA_LIBS="$EXTRA_LIBS $LIBZSTD"
[ -n "$LIBZ" ] && EXTRA_LIBS="$EXTRA_LIBS $LIBZ"

g++ build/bench_seal.o "$LIBSEAL" $EXTRA_LIBS -lpthread -o build/bench_seal
echo "-- Build OK: build/bench_seal --"
echo

echo "-- Running ONE test (CKKS, N=8192, category=1, multiply, 20 reps) --"
mkdir -p ../results/raw
./build/bench_seal --scheme=CKKS --N=8192 --category=1 --operation=multiply \
  --reps=20 --warmup=5 --out=../results/raw/sanity_check.csv --grid=../config/param_grid.csv
echo
echo "-- Result (this is the small file the sanity check produces): --"
cat ../results/raw/sanity_check.csv
echo
echo "SUCCESS. The binary at experiments/seal/build/bench_seal now works."
echo "It will keep working for future runs from OUTSIDE Docker too, as long"
echo "as you run it through this same docker wrapper (the binary was linked"
echo "against the containers static libraries, so it is not portable to the"
echo "bare host — every future run also goes through docker run, same as this)."
'
