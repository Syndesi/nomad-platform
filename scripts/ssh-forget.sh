#!/usr/bin/env bash
# Forget the ssh host key of a node (after a reinstall). The node may sit behind another address or port in the
# inventory (ansible_host / ansible_port), so ask ssh itself where the name leads. Inside the tools container.
set -euo pipefail
node=${1:?usage: ssh-forget.sh <node>}
CLUSTER_DIR=${CLUSTER_DIR:-/work}
# only a node of the inventory: never an arbitrary name or address, so nothing else can be removed from known_hosts
# shellcheck source=lib.sh
. "$CLUSTER_DIR/base/scripts/lib.sh"
ansible-inventory --list | jq -e --arg n "$node" '._meta.hostvars | has($n)' >/dev/null || { echo "ssh-forget: $node is not a node of the inventory" >&2; exit 1; }
cfg=$("$CLUSTER_DIR/base/scripts/ssh-config.sh")
read -r host port < <(ssh -F "$cfg" -G "$node" | awk '$1=="hostname"{h=$2} $1=="port"{p=$2} END{print h, p}')
[ "$port" = 22 ] && entry=$host || entry="[$host]:$port"
# exactly this entry of this file; nothing else
ssh-keygen -q -R "$entry" -f "$CLUSTER_DIR/ssh/known_hosts" 2>/dev/null || true
rm -f "$CLUSTER_DIR/ssh/known_hosts.old"
echo "forgot $entry ($node)"
