#!/usr/bin/env bash
# Configure ONE node (new, or reinstalled), on the host (uses the long-running tools container):
#   node.sh <hostname> [ansible-playbook args]
# = site.yml with --limit <hostname>,localhost, then the cluster repo's own playbooks/*.yml (name order) limited to this node
# only. localhost stays in the limit of site.yml: the plays that load the tokens and run the tofu stages are on localhost,
# and a new node gets its consul agent token from tofu-consul.
# Creating or replacing the machine itself is not the platform's business (the cluster repo's tofu/ansible/hands).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "${CLUSTER_DIR:-.}"
cd "${CLUSTER_DIR:-.}"
host=${1:?hostname as in the inventory}
shift
run() { docker compose exec -T -w /work tools ansible-playbook "$@"; }
run base/ansible/playbooks/site.yml --limit "$host,localhost" "$@"
for f in playbooks/*.yml; do
  [ -e "$f" ] || exit 0
  echo "== cluster playbook $f on $host"
  run "/work/$f" --limit "$host" "$@"
done
