#!/bin/sh
# Run in /src (a checkout of the gvisor `go` branch): verify-gvisor.sh <version> <go-branch commit>
# Fails unless HEAD is that commit and it merges exactly the master commit that the release tag release-<version> points at.
set -eu
version=$1 commit=$2
[ "$(git rev-parse HEAD)" = "$commit" ] || { echo "HEAD is not $commit" >&2; exit 1; }
# the subject of a go branch commit: "Merge release-<previous release>-<n>-g<abbreviated master commit> (automated)"
merged=$(git log -1 --format=%s | sed -nE 's/^Merge release-[0-9.]+-[0-9]+-g([0-9a-f]+) \(automated\)$/\1/p')
[ -n "$merged" ] || { echo "commit $commit is not an automated merge of a master commit" >&2; exit 1; }
tag=$(git ls-remote origin "refs/tags/release-${version}^{}" | cut -f1)
[ -n "$tag" ] || { echo "no tag release-${version} in the gvisor repo" >&2; exit 1; }
case "$tag" in "$merged"*) ;; *) echo "tag release-${version} is $tag, commit $commit merges $merged" >&2; exit 1 ;; esac
echo "release-${version} = master ${merged}, go branch ${commit}"
