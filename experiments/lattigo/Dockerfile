# Dockerfile for the lattigo-env image (Go build environment of the Lattigo
# latency pilot).
#
# RECONSTRUCTED on 21 Nov 2026 from the image actually used (image id
# recorded in the session's cpu_state.txt) and its `docker history`: no
# Dockerfile had been committed. NOT YET TEST-BUILT.
#   - base: the official Go image, Go 1.22.12 on Debian 12 (bookworm), as the
#     original (GOLANG_VERSION=1.22.12, GOTOOLCHAIN=local, Debian 12.9).
#   - Lattigo v5.0.7 and its dependencies are NOT taken from the image: the
#     harness is built offline (GOPROXY=off) from experiments/lattigo/
#     gomodcache, filled once from proxy.golang.org and checked against
#     experiments/lattigo/go.sum (docker_build.sh). To fill it on a new
#     machine: GOMODCACHE=$PWD/gomodcache go mod download (in experiments/lattigo/).
# Build (from experiments/lattigo/):  docker build -t lattigo-env .
FROM golang:1.22.12-bookworm
ENV GOTOOLCHAIN=local
WORKDIR /workspace
CMD ["/bin/bash"]
