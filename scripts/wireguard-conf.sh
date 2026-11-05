#!/usr/bin/env bash
# The wg-quick config of the wireguard client that runs next to traefik (cluster_traefik_wireguard), stored sops/age
# encrypted in inventory/group_vars/all/wireguard.sops.yml as cluster_traefik_wireguard_conf (the private key is in it).
# Runs inside the tools container; `task wireguard:conf -- <file>` feeds the file in.
#   wireguard-conf.sh set        read the config from stdin and store it
#   wireguard-conf.sh show       print it decrypted
set -euo pipefail
CLUSTER_DIR=${CLUSTER_DIR:-/work}
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "$CLUSTER_DIR"
cd "$CLUSTER_DIR"
FILE=inventory/group_vars/all/wireguard.sops.yml
case "${1:-}" in
  set)
    conf=$(cat)
    if ! { grep -q '^\[Interface\]' <<<"$conf" && grep -qE '^PrivateKey *=' <<<"$conf" && grep -q '^\[Peer\]' <<<"$conf"; }; then
      echo "not a wg-quick config: needs [Interface] with PrivateKey and at least one [Peer]" >&2; exit 2
    fi
    # the client runs in a container: wg-quick cannot manage resolv.conf there, and a full tunnel (0.0.0.0/0) would also
    # swallow the traffic to consul and nomad on the node
    grep -qE '^DNS *=' <<<"$conf" && echo "warning: DNS= makes wg-quick call resolvconf, which does not exist in the container; remove it" >&2
    grep -qE '^(PostUp|PostDown|PreUp|PreDown) *=' <<<"$conf" && echo "warning: PostUp/PostDown/PreUp/PreDown run inside the container (no iptables rules of a server config wanted there); remove them" >&2
    grep -qE '^AllowedIPs *=.*0\.0\.0\.0/0' <<<"$conf" && echo "note: AllowedIPs 0.0.0.0/0 is a full tunnel; traffic to the cluster subnet, the node and its dns stays direct (cluster_wireguard_bypass)" >&2
    # a client that only receives connections (nothing of its own to send) needs a keepalive: without traffic wireguard sends nothing,
    # the server never learns the client's address and its NAT mapping expires
    grep -qE '^PersistentKeepalive *= *[1-9]' <<<"$conf" || echo "warning: no PersistentKeepalive in the [Peer] section; a client behind NAT that only receives connections needs one (25)" >&2
    [ -e .sops.yaml ] || { echo "no .sops.yaml: run 'task age:init' first" >&2; exit 1; }
    { echo "---"; echo "cluster_traefik_wireguard_conf: |"; printf '%s\n' "  ${conf//$'\n'/$'\n'  }"; } \
      | sops --config .sops.yaml --encrypt --input-type yaml --output-type yaml --filename-override "$PWD/$FILE" /dev/stdin > "$FILE.new"
    mv "$FILE.new" "$FILE"
    echo "stored in $FILE (encrypted). Set cluster_traefik_wireguard: true and cluster_wireguard_image, then task deploy:ansible"
    ;;
  show) sops decrypt --extract '["cluster_traefik_wireguard_conf"]' --output-type binary "$FILE" ;;
  *) echo "usage: $0 set (config on stdin) | show" >&2; exit 2 ;;
esac
