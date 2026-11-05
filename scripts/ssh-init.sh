#!/usr/bin/env bash
# Host side, run once by `task ssh:init [-- <private key file>]`: the key ansible and the scripts log in to the nodes with
# ($SSH_KEY_DIR, default ./secrets/ssh, gitignored; the file name there is always ansible_ed25519, whatever the type).
#   no argument   a new key: ed25519, one per cluster, only valid for the ansible user
#   <key file>    use that one (copied to $SSH_KEY_DIR; checked: readable, no passphrase, an algorithm the nodes accept)
# The key never has a passphrase: nothing could type it in a CI run. The public half goes onto the nodes, see `task ssh:bootstrap-cmd`.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "${CLUSTER_DIR:-.}"
cd "${CLUSTER_DIR:-.}"
dir=${SSH_KEY_DIR:-./secrets/ssh}
image=$(docker compose config --images | head -1)
mkdir -p "$dir"
name=${CLUSTER_NAME:-cluster}
src=${1:-}
ok=0
if [ -n "$src" ]; then
  [ -r "$src" ] || { echo "cannot read $src" >&2; exit 1; }
  [ ! -e "$dir/ansible_ed25519" ] || { echo "$dir/ansible_ed25519 exists already: remove it first if it should be replaced" >&2; exit 1; }
  cp "$src" "$dir/ansible_ed25519"
  chmod 600 "$dir/ansible_ed25519"
  # a key that fails the checks below must not stay behind as if it were the cluster's key
  trap '[ "$ok" = 1 ] || rm -f "$dir/ansible_ed25519" "$dir/ansible_ed25519.pub"' EXIT
fi
# ssh-keygen wants a passwd entry for its uid: run as root, hand the files to the host user afterwards
docker run --rm -v "$(cd "$dir" && pwd):/ssh" "$image" sh -c "
  if [ ! -s /ssh/ansible_ed25519 ]; then
    ssh-keygen -q -t ed25519 -N '' -C 'ansible@$name' -f /ssh/ansible_ed25519 && echo 'created $dir/ansible_ed25519' >&2
  fi
  chmod 600 /ssh/ansible_ed25519
  pub=\$(ssh-keygen -y -P '' -f /ssh/ansible_ed25519 2>/dev/null) || {
    echo 'the key is protected by a passphrase or is not a private key: use one without a passphrase' >&2; exit 1; }
  echo \"\$(echo \"\$pub\" | cut -d' ' -f1,2) ansible@$name\" > /ssh/ansible_ed25519.pub
  chown $(id -u):$(id -g) /ssh/ansible_ed25519 /ssh/ansible_ed25519.pub"
ok=1
cat "$dir/ansible_ed25519.pub"
type=$(awk '{print $1}' "$dir/ansible_ed25519.pub")
allowed=$(docker compose exec -T tools bash -c '. "$CLUSTER_DIR/base/scripts/lib.sh"; cvar "cluster_ssh_pubkey_algorithms | join(\",\")"' 2>/dev/null || true)
if [ -n "$allowed" ]; then
  case ",$allowed," in
    *",$type,"*) echo "key type $type: accepted (cluster_ssh_pubkey_algorithms: $allowed)" >&2 ;;
    *) if [ "$type" = ssh-rsa ] && [[ $allowed == *rsa-sha2-* ]]; then echo "key type rsa: accepted through $allowed" >&2
       else echo "WARNING: key type $type is not in cluster_ssh_pubkey_algorithms ($allowed); site.yml refuses it until you use an allowed type or extend the list" >&2; fi ;;
  esac
fi
