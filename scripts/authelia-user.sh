#!/usr/bin/env bash
# Set the password of an authelia user (host side, needs docker): asks twice (authelia's own prompt, no echo), hashes it with the
# authelia image (argon2id), stores only the hash sops-encrypted in the cluster repo. Via `task authelia:user -- <user>`.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "${CLUSTER_DIR:-.}"
user=${1:?user name}
# same rule as authelia-users.sh, checked here first because the name is used in commands below
[[ $user =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { echo "user names: lowercase letters, digits, . _ -" >&2; exit 2; }
exec_tools() { docker compose exec -T tools "$@"; }
# shellcheck disable=SC2016 # the variables are the container's
image=$(exec_tools bash -c '. "$CLUSTER_DIR/base/scripts/lib.sh"; cvar cluster_authelia_image')
# authelia asks for the password itself (twice, no echo) on the terminal of a `docker run -t`: it is never an argument of a command
# (visible in ps, docker inspect) nor a shell variable. tee shows the prompts, the output is only read for the digest.
[ -t 0 ] || { echo "needs a terminal to ask for the password" >&2; exit 1; }
out=$(docker run --rm -it "$image" authelia crypto hash generate argon2 | tee /dev/tty) || true
hash=$(printf '%s\n' "$out" | tr -d '\r' | sed -nE 's/^Digest: //p')
[ -n "$hash" ] || { echo "no hash made (different or empty passwords?)" >&2; exit 1; }
# shellcheck disable=SC2016 # $CLUSTER_DIR and $1 are the container's
printf '%s' "$hash" | exec_tools bash -c '"$CLUSTER_DIR/base/scripts/authelia-users.sh" set "$1"' _ "$user"
