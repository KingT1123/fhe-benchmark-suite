#!/usr/bin/env bash
# docker_build.sh -- compile bench_lattigo in the lattigo-env image (Go
# 1.22.12), offline (GOPROXY=off): Lattigo v5.0.7 and its dependencies come
# from experiments/lattigo/gomodcache/ (downloaded once from proxy.golang.org
# on 21 Nov 2026, verified against go.sum; not in git). The binary sets GOMAXPROCS=1 itself. It is a static Go binary;
# it runs inside lattigo-env like the other harnesses in their images.
# Usage:  bash experiments/lattigo/docker_build.sh
set -euo pipefail
cd "$(dirname "$0")"
EXP="$(cd .. && pwd)"
docker run --rm -u "$(id -u):$(id -g)" -v "$EXP":/work -w /work/lattigo \
    -e GOFLAGS=-mod=mod -e GOPROXY=off -e GOCACHE=/tmp/gocache -e GOMODCACHE=/work/lattigo/gomodcache lattigo-env bash -c '
  set -e
  mkdir -p build
  go mod verify
  go build -trimpath -o build/bench_lattigo ./src
  go version
  echo "Build OK: experiments/lattigo/build/bench_lattigo"
'
