#!/usr/bin/env bash
# Create a new cluster repo from cluster-template/ (run on the host, from anywhere):
#   init-cluster.sh <target dir> <cluster name> <domain> [platform repo url]
# The same as copying cluster-template/ by hand, then `git init`, `git submodule add <platform> base` and replacing the
# placeholders `example` / `example.org` with the name and the domain. The target becomes a git repo with the platform
# as submodule `base/` (default source: this repo's origin, or this checkout when it has none). It deploys nothing, see
# the README of the new repo.
set -euo pipefail
target=${1:?target directory}
name=${2:?cluster name, e.g. home}
domain=${3:?base domain, e.g. home.example.org}
here=$(cd "$(dirname "$0")/.." && pwd)
url=${4:-$(git -C "$here" remote get-url origin 2>/dev/null || echo "$here")}
[ ! -e "$target" ] || { echo "$target exists" >&2; exit 1; }

mkdir -p "$target"
cp -a "$here/cluster-template/." "$target/"
cd "$target"
# the README keeps its own examples (example.org); only the files that name the cluster are changed
sed -i "s/^CLUSTER_NAME=example$/CLUSTER_NAME=$name/; s/^COMPOSE_PROJECT_NAME=example$/COMPOSE_PROJECT_NAME=$name/" .env
sed -i "s/^cluster_name: example$/cluster_name: $name/; s/example\.org/$domain/g" inventory/group_vars/all/cluster.yml
sed -i "s/example\.org/$domain/g" inventory/group_vars/all/authelia.yml
git init -q -b main
git -c protocol.file.allow=always submodule add -q "$url" base
git add -A
git -c user.name="${GIT_AUTHOR_NAME:-$(git config user.name || echo cluster)}" -c user.email="${GIT_AUTHOR_EMAIL:-$(git config user.email || echo cluster@localhost)}" commit -qm "Initial cluster repo for $name"
case $url in *://* | *@*) shown=$url ;; *) shown=$(basename "$url") ;; esac # no local paths in the output
echo "created $target (platform: $shown @ $(git -C base rev-parse --short HEAD))"
