#!/usr/bin/env bash
# Host side, run from the cluster repo: show or change the pinned version of the platform (the submodule base/).
#   upgrade.sh version         the pinned version (VERSION file, tag/commit)
#   upgrade.sh <tag|commit>    show what changes (changelog, commits), check out that version, stage the new pointer
# The new pointer is only staged: review it, then commit it in the cluster repo. Nothing is deployed.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "${CLUSTER_DIR:-.}"
cd "${CLUSTER_DIR:-.}"
[ -e base/.git ] || { echo "base/ is not a checked out submodule (git submodule update --init)" >&2; exit 1; }
describe() { git -C base describe --tags --always --dirty; }
case "${1:-version}" in
  version)
    echo "platform $(cat base/VERSION) ($(describe)) in cluster ${CLUSTER_NAME:-?}"
    ;;
  *)
    target=$1
    git -C base fetch --tags -q
    git -C base rev-parse --verify -q "$target^{commit}" >/dev/null || { echo "no such tag or commit: $target" >&2; exit 1; }
    [ -z "$(git -C base status --porcelain)" ] || { echo "base/ has local changes - the cluster repo must not edit the platform" >&2; exit 1; }
    echo "== $(describe)  ->  $target"
    git -C base log --oneline "HEAD..$target" || true
    echo "== changelog"
    git -C base diff "HEAD..$target" -- CHANGELOG.md | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' || echo "(no changelog entry)"
    git -C base checkout -q "$target"
    git add base
    echo "staged. Review, then: git commit -m 'platform $target'; task deploy:ansible"
    ;;
esac
