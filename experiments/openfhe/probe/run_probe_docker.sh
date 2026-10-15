#!/usr/bin/env bash
# Build and run openfhe_probe_v2 in the pinned openfhe-env image
# (experiments/openfhe/Dockerfile), then rebuild the grid tables.
#
# Same compiler and flags as the SEAL harness: g++ 13.3.0, -std=c++17 -O2;
# OpenFHE built without OpenMP, so the probe is single-threaded.
# Outputs (in this directory): params_v2.csv, functional_v2.csv, then
# make_grid_v2.py -> grid_v2.*, operations_v2.*, security_v2.*, functional_v2.tex.
# Re-running reproduces params_v2.csv exactly and every ok/wrong/unsupported
# status in functional_v2.csv; only the CKKS error magnitudes vary slightly
# (the inputs use a fixed seed, but OpenFHE draws its own encryption noise).
#
# Usage (from experiments/openfhe/probe/):  bash run_probe_docker.sh [out_dir]
#   out_dir: where to write the two CSVs (default: this directory); must be
#   inside experiments/. With an out_dir the tables are not rebuilt.
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-.}"
EXP="$(cd ../.. && pwd)"
docker run --rm -u "$(id -u):$(id -g)" -v "$EXP":/work -w /work/openfhe/probe openfhe-env bash -c "
  set -e
  I=/usr/local/include/openfhe
  g++ -std=c++17 -O2 -I\$I -I\$I/core -I\$I/pke -I\$I/binfhe -I\$I/cereal openfhe_probe_v2.cpp \
      -o /tmp/probe -L/usr/local/lib -lOPENFHEpke -lOPENFHEcore -lOPENFHEbinfhe
  LD_LIBRARY_PATH=/usr/local/lib /tmp/probe ../../config/param_grid.csv '$OUT/params_v2.csv' '$OUT/functional_v2.csv'
"
if [ "$OUT" = "." ]; then python3 make_grid_v2.py; fi
