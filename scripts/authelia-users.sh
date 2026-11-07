#!/usr/bin/env bash
# Password hashes and TOTP seeds of the authelia users, stored sops/age encrypted in inventory/group_vars/all/authelia.sops.yml as
# authelia_password_hashes: {<user>: <argon2id hash>}, authelia_totp_seeds and authelia_internal_totp_seeds: {<user>: <base32 secret>} (one seed per
# authelia instance, the public one and the internal one behind the VPN, never shared; generated here, once per user;
# the deploy registers it with authelia, so the second factor of a user survives a lost database). The users themselves (name, mail, groups) are plain data in
# the cluster's authelia.yml. Runs inside the tools container; `task authelia:user` is the interactive front end
# (it asks for the password on the host and pipes only the hash in here).
#   authelia-users.sh set <user>     read an argon2id hash from stdin and store it for <user> (and make a TOTP seed if there is none)
#   authelia-users.sh seed <user>    make the TOTP seed of <user> if there is none
#   authelia-users.sh remove <user>
#   authelia-users.sh list           users that have a hash
set -euo pipefail
CLUSTER_DIR=${CLUSTER_DIR:-/work}
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "$CLUSTER_DIR"
cd "$CLUSTER_DIR"
FILE=inventory/group_vars/all/authelia.sops.yml

valid_name() { [[ $1 =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { echo "user names: lowercase letters, digits, . _ -" >&2; exit 2; }; }
ensure_file() {
  [ -e "$FILE" ] && return
  [ -e .sops.yaml ] || { echo "no .sops.yaml: run 'task age:init' first" >&2; exit 1; }
  printf -- '---\nauthelia_password_hashes: {}\nauthelia_totp_seeds: {}\nauthelia_internal_totp_seeds: {}\n' \
    | sops --config .sops.yaml --encrypt --input-type yaml --output-type yaml --filename-override "$PWD/$FILE" /dev/stdin > "$FILE.new"
  mv "$FILE.new" "$FILE"
}

# a seed is 160 random bits as base32 without padding (32 characters), the format of `authelia storage user totp generate --secret`
make_seed() {
  local user=$1 map seed
  ensure_file
  for map in authelia_totp_seeds authelia_internal_totp_seeds; do
    if [[ $(sops decrypt --extract "[\"$map\"][\"$user\"]" "$FILE" 2>/dev/null) =~ ^[A-Z2-7]{32}$ ]]; then continue; fi
    seed=$(python3 -c 'import base64, os; print(base64.b32encode(os.urandom(20)).decode().rstrip("="))')
    [[ $seed =~ ^[A-Z2-7]{32}$ ]] || { echo "could not generate a TOTP seed" >&2; exit 1; }
    sops set "$FILE" "[\"$map\"][\"$user\"]" "\"$seed\""
    echo "TOTP seed of '$user' ($map) generated in $FILE"
  done
}

case "${1:-}" in
  set)
    user=${2:?user name}; valid_name "$user"
    hash=$(cat); [[ $hash == \$argon2id\$* ]] || { echo "stdin is not an argon2id hash" >&2; exit 2; }
    ensure_file
    sops set "$FILE" "[\"authelia_password_hashes\"][\"$user\"]" "\"$hash\""
    echo "password of '$user' stored in $FILE"
    make_seed "$user"
    ;;
  seed)
    user=${2:?user name}; valid_name "$user"
    make_seed "$user"
    ;;
  remove)
    user=${2:?user name}; valid_name "$user"
    [ -e "$FILE" ] || exit 0
    sops unset "$FILE" "[\"authelia_password_hashes\"][\"$user\"]"
    sops unset "$FILE" "[\"authelia_totp_seeds\"][\"$user\"]" 2>/dev/null || true
    sops unset "$FILE" "[\"authelia_internal_totp_seeds\"][\"$user\"]" 2>/dev/null || true
    ;;
  list)
    [ -e "$FILE" ] && sops decrypt --extract '["authelia_password_hashes"]' "$FILE" | sed -nE 's/^([^ :]+):.*/\1/p'
    ;;
  *) echo "usage: $0 set <user> (hash on stdin) | seed <user> | remove <user> | list" >&2; exit 2 ;;
esac
