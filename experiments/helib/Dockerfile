# Dockerfile for the helib-env image (HElib build environment of the HElib
# latency pilot and of the HEProfiler validation).
#
# RECONSTRUCTED on 21 Nov 2026 from the image actually used (image id
# sha256:53317c291eee..., recorded in every session's cpu_state.txt), from its
# `docker history` and from inspecting it: no Dockerfile had been committed.
# NOT YET TEST-BUILT. What is exact and what is not:
#   - HElib: the original image copied a local git checkout (COPY helib-src),
#     which is at commit 3e337a66a91a92d49de6a9505340826b0eb71081, tagged
#     v2.3.0 (2023-07-18). Its VERSION file, and therefore helib/version.h,
#     still read 2.2.0. Rebuilt here from that tag of the official
#     repository, built as the original: CMAKE_BUILD_TYPE=RelWithDebInfo,
#     PACKAGE_BUILD=OFF (NTL and GMP from Ubuntu), static libhelib.a.
#   - apt packages: pinned to the versions dpkg reports inside the original
#     image (NTL 11.5.1-1, GMP 6.3.0+dfsg-2ubuntu6.1, cmake 3.28.3, g++ 13),
#     served by the same dated Ubuntu snapshot as seal/Dockerfile.
#   - base image: the original was an earlier Ubuntu 24.04 snapshot whose
#     digest is no longer known (base layer 8ce1caf2...); the project's
#     pinned 24.04 digest (as seal/ and openfhe/Dockerfile) is used instead.
# Build (from experiments/helib/):  docker build -t helib-env .
FROM ubuntu@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG SNAPSHOT=20260501T000000Z
RUN printf '%s\n' \
        "deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/${SNAPSHOT} noble main restricted universe multiverse" \
        "deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/${SNAPSHOT} noble-updates main restricted universe multiverse" \
        "deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/${SNAPSHOT} noble-security main restricted universe multiverse" \
        > /etc/apt/sources.list \
    && rm -f /etc/apt/sources.list.d/ubuntu.sources \
    && printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99snapshot

RUN apt-get update && apt-get install -y --allow-downgrades \
        build-essential=12.10ubuntu1 \
        cmake=3.28.3-1build7 \
        git=1:2.43.0-1ubuntu7.3 \
        libgmp-dev=2:6.3.0+dfsg-2ubuntu6.1 \
        libntl-dev=11.5.1-1 \
        m4=1.4.19-4build1 \
        libc6=2.39-0ubuntu8.7 \
    && rm -rf /var/lib/apt/lists/*

ARG HELIB_TAG=v2.3.0
ARG HELIB_COMMIT=3e337a66a91a92d49de6a9505340826b0eb71081
RUN git clone --branch "$HELIB_TAG" https://github.com/homenc/HElib.git /helib \
    && test "$(git -C /helib rev-parse HEAD)" = "$HELIB_COMMIT" \
    && cmake -S /helib -B /helib/build -DCMAKE_BUILD_TYPE=RelWithDebInfo -DPACKAGE_BUILD=OFF \
    && cmake --build /helib/build --parallel "$(nproc)" \
    && cmake --install /helib/build && ldconfig

WORKDIR /workspace
CMD ["/bin/bash"]
