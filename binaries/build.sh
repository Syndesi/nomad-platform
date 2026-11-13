#!/usr/bin/env bash
# Usage: binaries/build.sh <nomad|consul> <alpine|debian>
# Writes $ARTIFACTS_DIR/<product>-<version>-<variant>-<arch> (e.g. nomad-2.0.2-alpine-amd64). The artifacts dir is a
# cache OUTSIDE the repos (~100 MB per binary) that every cluster on this machine shares.
# Skips the build if that file exists (the version is in the name, so it is the cache key);
# FORCE=1 rebuilds. Versions/bases come from the environment (.env, loaded by Taskfile).
# Builds for the host architecture unless ARCH=amd64|arm64 is set (then needs qemu binfmt).
set -euo pipefail
cd "$(dirname "$0")/.."

product=${1:?product: nomad|consul}
variant=${2:?variant: alpine|debian}

case "$product" in
  nomad)  version=${NOMAD_VERSION:?set NOMAD_VERSION in .env} ;;
  consul) version=${CONSUL_VERSION:?set CONSUL_VERSION in .env} ;;
  *) echo "unknown product: $product" >&2; exit 2 ;;
esac
case "$variant" in alpine|debian) ;; *) echo "unknown variant: $variant" >&2; exit 2 ;; esac

if [ -z "${ARCH:-}" ]; then
  case "$(uname -m)" in
    x86_64)        ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "unsupported host arch $(uname -m); set ARCH=" >&2; exit 2 ;;
  esac
fi

ARTIFACTS_DIR=${ARTIFACTS_DIR:-$HOME/.cache/nomad-platform/artifacts}
mkdir -p "$ARTIFACTS_DIR"
target="${ARTIFACTS_DIR}/${product}-${version}-${variant}-${ARCH}"
if [ -f "$target" ] && [ "${FORCE:-0}" != 1 ]; then
  echo "[$product/$variant] $target exists, skipping (FORCE=1 to rebuild)"
  exit 0
fi

tmp=$(mktemp -d "$ARTIFACTS_DIR/.build-${product}-${variant}.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "[$product/$variant] building v$version for linux/$ARCH ..."
DOCKER_BUILDKIT=1 docker build \
  --platform "linux/${ARCH}" \
  --target out \
  --build-arg "PRODUCT=${product}" \
  --build-arg "VERSION=${version}" \
  --build-arg "VARIANT=${variant}" \
  --build-arg "ALPINE_VERSION=${ALPINE_VERSION:?set ALPINE_VERSION in .env}" \
  --build-arg "DEBIAN_VERSION=${DEBIAN_BUILD_VERSION:?set DEBIAN_BUILD_VERSION in .env}" \
  --build-arg "GO_VERSION=${GO_VERSION:?set GO_VERSION in .env}" \
  --output "type=local,dest=${tmp}" \
  binaries

mv "$tmp/$product" "$target"
chmod 0755 "$target"
ls -lh "$target"
