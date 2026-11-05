# Builds one HashiCorp binary (nomad or consul) from source for one OS variant.
#   docker build --target out --build-arg PRODUCT=nomad --build-arg VERSION=2.0.2 \
#                --build-arg VARIANT=alpine|ubuntu --output type=local,dest=<dir> .
# The `out` stage only holds the binary, so `--output` writes it straight to the host:
# no `docker create/cp/rm`, no leftover images, no multi-GB containers to clean up.
#
# alpine: links against musl, for the OpenRC / Alpine hosts.
# ubuntu: links against glibc. Built on the OLDEST Ubuntu we want to run on, because a glibc
#         binary runs on newer glibc but not on older (built on 26.04 => runs on 26.04 and later).
# No defaults on purpose: binaries/build.sh passes every version from the cluster's .env, so there is one place to change them.
ARG VARIANT
ARG ALPINE_VERSION
ARG UBUNTU_VERSION
ARG GO_VERSION

# The Go toolchain is copied from the official image of the same libc family.
FROM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS go-alpine
FROM golang:${GO_VERSION}-trixie AS go-ubuntu
# (COPY --from cannot expand variables, hence the extra alias stages below.)
FROM go-${VARIANT} AS go

FROM alpine:${ALPINE_VERSION} AS base-alpine
RUN apk add --no-cache git make bash build-base linux-headers binutils

FROM ubuntu:${UBUNTU_VERSION} AS base-ubuntu
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git make bash build-essential binutils \
 && rm -rf /var/lib/apt/lists/*

FROM base-${VARIANT} AS build
ARG VARIANT
ARG PRODUCT
ARG VERSION
COPY --from=go /usr/local/go/ /usr/local/go/
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"

# `make dev` only chooses the quick build target; what is built is the checkout of the release tag. The build FAILS unless the
# result really is that tag (checked by verify-build.sh): no `-dev`/`+dirty` version, the tag points at HEAD, same revision.
RUN git clone --depth 1 --branch "v${VERSION}" "https://github.com/hashicorp/${PRODUCT}.git" /src
COPY verify-build.sh /verify-build.sh
WORKDIR /src

# Go caches are kept between builds (per libc, since cgo objects differ) so a rebuild
# after a version bump does not re-download and re-compile every dependency.
# `make bootstrap` (nomad only) installs the code generators; consul has no such target.
RUN --mount=type=cache,id=go-mod,target=/root/go/pkg/mod \
    --mount=type=cache,id=go-build-${VARIANT},target=/root/.cache/go-build \
    if [ "${PRODUCT}" = nomad ]; then make bootstrap; fi \
 && make dev \
 && strip --strip-all "bin/${PRODUCT}" \
 && /verify-build.sh "${PRODUCT}" "${VERSION}"

FROM scratch AS out
ARG PRODUCT
COPY --from=build /src/bin/${PRODUCT} /${PRODUCT}
