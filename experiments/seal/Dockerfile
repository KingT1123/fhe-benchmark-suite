# Dockerfile for the seal-env image (Microsoft SEAL 4.1.2 build environment).
#
# Reconstructed from the running image's own `docker history` (no Dockerfile
# had ever been committed for the image actually used to produce this
# project's results) and pinned throughout so a rebuild today is a genuine,
# verifiable path back to (very close to) the same environment, not just a
# description of what once existed:
#   - base image pinned by DIGEST, not just the "24.04" tag (which drifts
#     as Ubuntu ships point releases)
#   - every apt package pinned to the exact version found installed inside
#     the currently-running seal-env container (`dpkg -l`)
#   - SEAL and Microsoft GSL both built from their official tagged GitHub
#     releases (exact commit hashes noted below), not from an untracked
#     local copy -- the original image's `COPY seal-src` / `COPY gsl-include`
#     steps pulled from local directories that no longer exist on disk and
#     were never captured anywhere, so those specific bytes are NOT
#     recoverable; this rebuilds the same tagged upstream releases instead,
#     which is the closest genuinely reproducible substitute.
#
# Reproducibility of the apt layer specifically: pinning package *versions*
# alone isn't enough on Ubuntu, because the default archive only keeps the
# latest build of each package -- an exact old version can roll off within
# weeks (confirmed directly: the plain `apt-get install pkg=version` form
# below, tried against the live archive on 2026-09-23, failed with "Version
# ... was not found" for libssl-dev and zlib1g-dev). The fix used here is
# to point apt at a dated snapshot of the Ubuntu archive instead of the
# rolling one. snapshot.ubuntu.com (Canonical's official archive-snapshot
# service) was searched by date until one serial was found that serves ALL
# SEVEN exact versions below simultaneously: 20260501T000000Z. That match
# (not just each version existing *somewhere*, but all seven co-existing at
# one timestamp) is strong evidence this is close to the archive state the
# original seal-env image was actually built against. This makes the build
# genuinely durable: snapshot.ubuntu.com serves that exact archive state
# indefinitely, so this Dockerfile keeps building the same way regardless
# of what the live archive looks like by the time someone runs it.
FROM ubuntu@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3

# The base image ships with no CA trust store at all, so switching straight
# to an https snapshot URL fails TLS verification. Install ca-certificates
# first, from whatever the base image's own default sources are, before
# repointing apt at the pinned snapshot below.
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

# Same package list as the original image, each pinned to the exact
# version `dpkg -l` reported inside the running seal-env container at
# audit time (2026-09-23), plus a handful of their transitive
# dependencies (libc6, libssl3t64, perl-base, zlib1g, bzip2, libbz2-1.0)
# pinned alongside them. Those extra pins are needed because the base
# image is necessarily pulled fresh (its original digest is gone, see
# above) and so already carries those packages newer than the 2026-05-01
# snapshot's dependency chain expects -- confirmed directly: installing
# just the 7 packages above on their own fails with e.g. "libc6-dev :
# Depends: libc6 (= ...) but a newer version is to be installed".
# `apt-get dist-upgrade --allow-downgrades` does NOT fix this on its own
# (tried first): dist-upgrade only ever considers *upgrades* to a newer
# candidate, and every already-installed package here is already newer
# than the snapshot has, so it finds nothing to do and leaves the
# mismatch in place. Naming the specific blocking packages, pinned,
# alongside the main install (one apt-get transaction, not two) is what
# actually gets apt's solver to downgrade them together consistently.
RUN apt-get update && apt-get install -y --allow-downgrades \
        build-essential=12.10ubuntu1 \
        cmake=3.28.3-1build7 \
        git=1:2.43.0-1ubuntu7.3 \
        libssl-dev=3.0.13-0ubuntu3.9 \
        libzstd-dev=1.5.5+dfsg2-2build1.1 \
        libgtest-dev=1.14.0-1 \
        zlib1g-dev=1:1.3.dfsg-3.1ubuntu2.1 \
        libc6=2.39-0ubuntu8.7 \
        libssl3t64=3.0.13-0ubuntu3.9 \
        perl-base=5.38.2-3.2ubuntu0.2 \
        zlib1g=1:1.3.dfsg-3.1ubuntu2.1 \
        bzip2=1.0.8-5.1build0.1 \
        libbz2-1.0=1.0.8-5.1build0.1 \
    && rm -rf /var/lib/apt/lists/*

# Microsoft GSL v4.2.0 (tag confirmed against upstream at
# github.com/microsoft/GSL, commit 2828399820ef4928cc89b65605dca5dc68efca6e)
# -- header-only, install just copies headers + CMake package config to the
# same /usr/local paths the original image's COPY steps put them at
# (/usr/local/include/gsl, /usr/local/share/cmake/Microsoft.GSL).
RUN git clone --branch v4.2.0 --depth 1 https://github.com/microsoft/GSL.git /gsl \
    && cmake -S /gsl -B /gsl/build -DCMAKE_BUILD_TYPE=Release -DGSL_TEST=OFF \
    && cmake --install /gsl/build \
    && rm -rf /gsl

# Microsoft SEAL v4.1.2 (tag confirmed against upstream at
# github.com/microsoft/SEAL, commit 119dc32e135cb89c1062076a69310d4413ebc824).
# SEAL_BUILD_DEPS=OFF -- GSL/zlib/zstd are already provided above, matching
# the original image's build flags exactly (see its `docker history`).
RUN git clone --branch v4.1.2 --depth 1 https://github.com/microsoft/SEAL.git /seal \
    && cmake -S /seal -B /seal/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DSEAL_BUILD_EXAMPLES=ON \
        -DSEAL_BUILD_DEPS=OFF \
    && cmake --build /seal/build --parallel "$(nproc)" \
    && cmake --install /seal/build \
    && ldconfig

WORKDIR /workspace
CMD ["/bin/bash"]
