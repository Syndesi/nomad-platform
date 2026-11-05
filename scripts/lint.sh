#!/usr/bin/env bash
# Everything of the BASE that can be checked without a cluster (the cluster repo supplies the inventory). Inside the tools container, via `task lint`.
# Runs all checks, prints which ones failed, exits 1 if any did.
set -uo pipefail
CLUSTER_DIR=${CLUSTER_DIR:-/work}; BASE=$CLUSTER_DIR/base; export BASE
cd "$CLUSTER_DIR" || exit 1
failed=()
step() { # <name> <command...>
  local name=$1; shift
  echo "== $name"
  "$@" || failed+=("$name")
}

# lint the base (its code), with the cluster's inventory for the syntax check
step ansible-lint bash -c "cd $BASE/ansible && ansible-lint --nocolor playbooks roles"
step yamllint yamllint -c "$BASE/ansible/.yamllint.yml" "$BASE/ansible/inventory" "$BASE/ansible/playbooks" "$BASE/ansible/roles" "$BASE/ansible/templates" "$BASE/ansible/requirements.yml" "$BASE/tofu"
step shellcheck shellcheck -x -P SCRIPTDIR "$BASE"/scripts/*.sh
for d in tofu-consul tofu-nomad; do
  step "tofu fmt $d" tofu -chdir="$BASE/tofu/$d" fmt -check -diff
  # the roots have a local backend whose state lives in the cluster repo: validate without it
  step "tofu validate $d" bash -c "export TF_DATA_DIR=/tmp/lint-$d; tofu -chdir=$BASE/tofu/$d init -backend=false -input=false -no-color >/dev/null && tofu -chdir=$BASE/tofu/$d validate -no-color"
done
# the alpine build of nomad runs in this (alpine) container
nomad_bin=$(find /artifacts -maxdepth 1 -name "nomad-*alpine*" 2>/dev/null | head -1)
if [ -n "$nomad_bin" ]; then
  step "nomad fmt jobs" "$nomad_bin" fmt -check -recursive "$BASE/jobs" "$BASE/tests"
else
  echo "== nomad fmt jobs: skipped (no built nomad binary: task build)"
fi
step "playbook syntax" bash -c "cd $BASE/ansible && ansible-playbook playbooks/site.yml playbooks/maintenance.yml playbooks/pki-info.yml --syntax-check >/dev/null"

echo
if [ ${#failed[@]} -eq 0 ]; then echo "lint: all checks passed"; else echo "lint: FAILED: ${failed[*]}"; exit 1; fi
