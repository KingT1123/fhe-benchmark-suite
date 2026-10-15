# Dockerfile for the openfhe-env image (OpenFHE 1.5.1 build environment).
#
# Pinned like experiments/seal/Dockerfile, on purpose identical where the two
# libraries share anything, so the two campaigns run in comparable
# environments:
#   * the same base image digest and the same dated Ubuntu package snapshot,
#     hence the same compiler (g++ 13.3.0), CMake 3.28.3 and C library;
#   * OpenFHE pinned by tag AND verified commit (v1.5.1 = 1306d14f);
#   * CMake Release build (-O3 -DNDEBUG), as SEAL's; no CPU-specific code
#     generation (WITH_NATIVEOPT=OFF), as SEAL is built without HEXL;
#   * WITH_OPENMP=OFF: SEAL is single-threaded, so OpenFHE is built without
#     OpenMP and therefore cannot use extra threads by accident (a runtime
#     OMP_NUM_THREADS setting could be forgotten);
#   * NATIVE_SIZE=64 (OpenFHE's default native integer width).
# Build (from experiments/openfhe/):  docker build -t openfhe-env .
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
    && printf 'Acquire::Check-Valid-Until "false";\nAcquire::Retries "10";\n' > /etc/apt/apt.conf.d/99snapshot

RUN apt-get update && apt-get install -y --allow-downgrades \
        build-essential=12.10ubuntu1 \
        cmake=3.28.3-1build7 \
        git=1:2.43.0-1ubuntu7.3 \
        libc6=2.39-0ubuntu8.7 \
        perl-base=5.38.2-3.2ubuntu0.2 \
        bzip2=1.0.8-5.1build0.1 \
        libbz2-1.0=1.0.8-5.1build0.1 \
    && rm -rf /var/lib/apt/lists/*

ARG OPENFHE_TAG=v1.5.1
ARG OPENFHE_COMMIT=1306d14f
ARG BUILD_JOBS=3
RUN git clone --branch "$OPENFHE_TAG" --depth 1 https://github.com/openfheorg/openfhe-development.git /openfhe \
    && test "$(git -C /openfhe rev-parse --short=8 HEAD)" = "$OPENFHE_COMMIT" \
    && cmake -S /openfhe -B /openfhe/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DWITH_OPENMP=OFF \
        -DWITH_NATIVEOPT=OFF \
        -DNATIVE_SIZE=64 \
        -DBUILD_UNITTESTS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_BENCHMARKS=OFF \
    && cmake --build /openfhe/build --parallel "$BUILD_JOBS" \
    && cmake --install /openfhe/build \
    && ldconfig

WORKDIR /workspace
CMD ["/bin/bash"]
