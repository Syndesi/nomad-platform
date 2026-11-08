#!/usr/bin/env bash
# Usage: binaries/build-runsc.sh <alpine|ubuntu>
# Writes $ARTIFACTS_DIR/runsc-<version>-<variant>-<arch>.tar (runsc + its gvisor-bin/ sidecars) next to the nomad and consul binaries (same cache, same rules as build.sh:
# skips an existing file, FORCE=1 rebuilds, ARCH=amd64|arm64 for a foreign arch). Versions come from the cluster's .env:
# GVISOR_VERSION (e.g. 20261102.0) and GVISOR_GO_COMMIT (the commit of gvisor's `go` branch that merges that release, see Dockerfile.gvisor).
set -euo pipefail
cd "$(dirname "$0")/.."

variant=${1:?variant: alpine|ubuntu}
case "$variant" in alpine|ubuntu) ;; *) echo "unknown variant: $variant" >&2; exit 2 ;; esac
version=${GVISOR_VERSION:?set GVISOR_VERSION in .env}
commit=${GVISOR_GO_COMMIT:?set GVISOR_GO_COMMIT in .env}

if [ -z "${ARCH:-}" ]; then
  case "$(uname -m)" in
    x86_64)        ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "unsupported host arch $(uname -m); set ARCH=" >&2; exit 2 ;;
  esac
fi

ARTIFACTS_DIR=${ARTIFACTS_DIR:-$HOME/.cache/nomad-platform/artifacts}
mkdir -p "$ARTIFACTS_DIR"
target="${ARTIFACTS_DIR}/runsc-${version}-${variant}-${ARCH}.tar"
if [ -f "$target" ] && [ "${FORCE:-0}" != 1 ]; then
  echo "[runsc/$variant] $target exists, skipping (FORCE=1 to rebuild)"
  exit 0
fi

tmp=$(mktemp -d "$ARTIFACTS_DIR/.build-runsc-${variant}.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "[runsc/$variant] building release-$version for linux/$ARCH ..."
DOCKER_BUILDKIT=1 docker build \
  --platform "linux/${ARCH}" \
  --file binaries/Dockerfile.gvisor \
  --target out \
  --build-arg "VERSION=${version}" \
  --build-arg "GO_COMMIT=${commit}" \
  --build-arg "VARIANT=${variant}" \
  --build-arg "ALPINE_VERSION=${ALPINE_VERSION:?set ALPINE_VERSION in .env}" \
  --build-arg "UBUNTU_VERSION=${UBUNTU_BUILD_VERSION:?set UBUNTU_BUILD_VERSION in .env}" \
  --build-arg "GO_VERSION=${GO_VERSION:?set GO_VERSION in .env}" \
  --output "type=local,dest=${tmp}" \
  binaries

mv "$tmp/runsc.tar" "$target"
chmod 0644 "$target"
ls -lh "$target"
