#!/usr/bin/env bash
# Run tofu on one of the roots whose state is client-side encrypted (tofu-consul, tofu-nomad), e.g.
#   scripts/tofu-enc.sh tofu-consul output -json service_tokens
# The passphrase comes from the sops-encrypted secrets; same settings as role tofu_stage.
# `init` gets the state path of the cluster repo added (unless -backend=false).
set -euo pipefail
CLUSTER_DIR=${CLUSTER_DIR:-/work}; BASE=$CLUSTER_DIR/base; export BASE
cd "$CLUSTER_DIR" || exit 1
root=${1:?tofu root, e.g. tofu-consul}; shift
here=$(dirname "$0")
pass=$("$here/secrets.sh" get cluster_tofu_state_passphrase)
TF_ENCRYPTION=$(cat <<HCL
key_provider "pbkdf2" "cluster" {
  passphrase = "$pass"
}
method "aes_gcm" "cluster" {
  keys = key_provider.pbkdf2.cluster
}
state {
  method   = method.aes_gcm.cluster
  enforced = true
}
plan {
  method   = method.aes_gcm.cluster
  enforced = true
}
HCL
)
export TF_ENCRYPTION
# code is the base's, state and plugin dir are the cluster's (cluster_state_dir, see role tofu_stage)
state=$CLUSTER_DIR/state/$root
export TF_DATA_DIR=$state/.terraform
if [ "${1:-}" = init ] && [[ " $* " != *" -backend=false "* ]]; then
  set -- init "-backend-config=path=$state/terraform.tfstate" "${@:2}"
fi
exec tofu -chdir="$BASE/tofu/$root" "$@"
