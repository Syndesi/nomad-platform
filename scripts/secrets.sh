#!/usr/bin/env bash
# Pre-generated cluster secrets (the values that need no running cluster), stored sops/age
# encrypted next to the inventory: ansible reads them as ordinary group vars (community.sops
# vars plugin), nothing secret is ever written to disk in clear text. Runs inside the tools
# container via `task secrets:*`.
#   secrets.sh init     create group_vars/all/secrets.sops.yml (refuses to overwrite)
#   secrets.sh show     print it decrypted
#   secrets.sh get <v>  print one value (e.g. cluster_consul_management_token)
#   secrets.sh edit     open it in $EDITOR through sops (interactive: use `task shell`)
#   secrets.sh uuid|key|string   print one fresh UUID / 32 byte base64 key / 64 char hex string
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "${CLUSTER_DIR:-/work}"
cd "${CLUSTER_DIR:-/work}"
FILE=inventory/group_vars/all/secrets.sops.yml

uuid()   { cat /proc/sys/kernel/random/uuid; }
key()    { openssl rand -base64 32; }
string() { openssl rand -hex 32; }

case "${1:-}" in
  init)
    if [ -e "$FILE" ]; then echo "$FILE exists - refusing to overwrite" >&2; exit 1; fi
    [ -e .sops.yaml ] || { echo "no .sops.yaml: run 'task age:init' first" >&2; exit 1; }
    cat <<YAML | sops --config .sops.yaml --encrypt --input-type yaml --output-type yaml --filename-override "$PWD/$FILE" /dev/stdin > "$FILE.new"
---
# Generated $(date -u +%FT%TZ) by scripts/secrets.sh. Encrypted with sops/age: edit with \`sops $FILE\`.
# Consul gossip encryption key (consul keygen format)
cluster_consul_gossip_key: "$(key)"
# Nomad gossip encryption key (nomad operator gossip keyring format)
cluster_nomad_gossip_key: "$(key)"
# Consul: acl.tokens.initial_management - the BOOTSTRAP token, only in the config while the cluster is built; tofu-consul then mints the ops token
# and the deploy deletes this one from the cluster
cluster_consul_management_token: "$(uuid)"
# Nomad: SecretID handed to 'nomad acl bootstrap <file>' (works once per cluster) - the BOOTSTRAP token; tofu-nomad then mints the ops token
# and the deploy deletes this one from the cluster
cluster_nomad_management_token: "$(uuid)"
# Passphrase of the client-side state encryption of the tofu roots that hold tokens (tofu-consul, tofu-nomad)
cluster_tofu_state_passphrase: "$(string)"
# Authelia
cluster_authelia_session_secret: "$(string)"
cluster_authelia_storage_encryption_key: "$(string)"
cluster_authelia_reset_password_jwt_secret: "$(string)"
YAML
    mv "$FILE.new" "$FILE"
    echo "written $FILE (encrypted)"
    ;;
  show)   sops --decrypt "$FILE" ;;
  get)    sops --decrypt --extract "[\"${2:?variable name}\"]" "$FILE" ;;
  edit)   sops "$FILE" ;;
  uuid)   uuid ;;
  key)    key ;;
  string) string ;;
  *) echo "usage: $0 init|show|get <var>|edit|uuid|key|string" >&2; exit 2 ;;
esac
