#!/usr/bin/env bash
# Set the password of an authelia user (host side, needs docker): asks twice (gum, no echo), hashes it with the
# authelia image (argon2id), stores only the hash sops-encrypted in the cluster repo. Via `task authelia:user -- <user>`.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "${CLUSTER_DIR:-.}"
user=${1:?user name}
# same rule as authelia-users.sh, checked here first because the name is used in commands below
[[ $user =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { echo "user names: lowercase letters, digits, . _ -" >&2; exit 2; }
exec_tools() { docker compose exec -T tools "$@"; }
pw=$(gum input --password --placeholder "password for $user")
pw2=$(gum input --password --placeholder "again")
[ -n "$pw" ] && [ "$pw" = "$pw2" ] || { echo "empty or different passwords" >&2; exit 1; }
# shellcheck disable=SC2016 # the variables are the container's
image=$(exec_tools bash -c '. "$CLUSTER_DIR/base/scripts/lib.sh"; cvar cluster_authelia_image')
hash=$(docker run --rm "$image" authelia crypto hash generate argon2 --password "$pw" | sed -nE 's/^Digest: //p')
unset pw pw2
# shellcheck disable=SC2016 # $CLUSTER_DIR and $1 are the container's
printf '%s' "$hash" | exec_tools bash -c '"$CLUSTER_DIR/base/scripts/authelia-users.sh" set "$1"' _ "$user"
