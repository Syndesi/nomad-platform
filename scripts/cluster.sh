#!/usr/bin/env bash
# Look at the cluster with the read-only tokens (outputs of the encrypted tofu states), run on the
# server node. Inside the tools container, via `task cluster`.
set -euo pipefail
cd "${CLUSTER_DIR:-/work}" || exit 1
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
server=${CLUSTER_SERVER:-$(inventory_group cluster_servers | head -1)}
case "${1:-status}" in
  status)
    nt=$("$BASE/scripts/tofu-enc.sh" tofu-nomad output -json nomad_tokens | jq -r .readonly)
    ct=$("$BASE/scripts/tofu-enc.sh" tofu-consul output -json service_tokens | jq -r .readonly)
    cluster_exec_tokens "$server" "$nt" "$ct" '
      echo == consul members; consul members
      echo == nomad servers; nomad server members
      echo == nomad nodes; nomad node status
      echo == nomad jobs; nomad job status'
    ;;
  tokens) # accessor ids only
    "$BASE/scripts/tofu-enc.sh" tofu-consul show -json | jq -r '.values.root_module.resources[] | select(.type=="consul_acl_token") | "consul \(.values.description)\t\(.values.accessor_id)"'
    "$BASE/scripts/tofu-enc.sh" tofu-nomad show -json | jq -r '.values.root_module.resources[] | select(.type=="nomad_acl_token") | "nomad  \(.values.name)\t\(.values.accessor_id)"'
    ;;
  *) echo "usage: $0 status|tokens" >&2; exit 2 ;;
esac
