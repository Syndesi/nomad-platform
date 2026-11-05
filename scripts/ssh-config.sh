#!/usr/bin/env bash
# (Re)render the controller's ssh client config from the cluster variables (the same file site.yml writes), so the
# scripts can reach a node without a deploy before. Inside the tools container.
set -euo pipefail
CLUSTER_DIR=${CLUSTER_DIR:-/work}
cd "$CLUSTER_DIR"
file=$(ANSIBLE_CALLBACK_RESULT_FORMAT=json ansible localhost -m ansible.builtin.debug -a 'msg={{ cluster_ssh_config_file }}' 2>/dev/null | sed -nE 's/^ *"msg": "([^"]*)".*/\1/p' | head -1)
[ -n "$file" ] || { echo "cannot read cluster_ssh_config_file (inventory problem?)" >&2; exit 1; }
mkdir -p "$(dirname "$file")" "$CLUSTER_DIR/ssh"
ansible localhost -m ansible.builtin.template -a "src=$CLUSTER_DIR/base/ansible/templates/ssh_config.j2 dest=$file mode=0600" >/dev/null
echo "$file"
