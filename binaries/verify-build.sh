#!/bin/sh
# Run in the source tree after the build: verify-build.sh <nomad|consul> <version>
# Fails unless bin/<product> is exactly the release v<version>: tag at HEAD, clean tree, version line without a
# prerelease/dirty suffix, and the revision the binary reports is HEAD.
set -eu
product=$1 version=$2
case "$product" in nomad) label=Nomad ;; consul) label=Consul ;; *) echo "unknown product $product" >&2; exit 2 ;; esac
out=$("bin/$product" version)
first=$(printf '%s\n' "$out" | head -1)
[ "$first" = "$label v$version" ] || { echo "version line is '$first', want '$label v$version'" >&2; exit 1; }
tag=$(git describe --exact-match --tags HEAD 2>/dev/null) || { echo "HEAD is not at a tag" >&2; exit 1; }
[ "$tag" = "v$version" ] || { echo "HEAD is at tag $tag, want v$version" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "tracked files were modified by the build" >&2; exit 1; }
rev=$(printf '%s\n' "$out" | sed -n 's/^Revision //p' | head -1)
head=$(git rev-parse HEAD)
case "$head" in "$rev"*) ;; *) echo "binary reports revision '$rev', HEAD is $head" >&2; exit 1 ;; esac
echo "$first, revision $(printf "%.11s" "$head"), tag $tag"
