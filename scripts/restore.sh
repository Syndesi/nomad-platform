#!/usr/bin/env bash
# Restore a backup of `task backup` into a cluster that has just been built (`task deploy:tofu` made the nodes; nothing runs on them yet).
# Inside the tools container, via `task restore -- <backup dir name>`.
#   restore.sh prepare <name>   checks the backup, puts its tofu states in place (the playbook then restores the snapshots)
#   restore.sh wait             waits until `smoke.sh` is green (the old nodes go down, the jobs are placed on the new ones)
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "${CLUSTER_DIR:-/work}"
cd "${CLUSTER_DIR:-/work}" || exit 1
key=${SOPS_AGE_KEY_FILE:-/age/keys.txt}
die() { echo "restore: $*" >&2; exit 1; }

case "${1:-}" in
  prepare)
    name=${2:?usage: restore.sh prepare <backup dir name under backups/>}
    # a name inside backups/, never a path
    [ "$name" = "$(basename "$name")" ] && [ "$name" != . ] && [ "$name" != .. ] || die "give the name of a directory in backups/, not a path"
    dir=backups/$name
    [ -f "$dir/.complete" ] || die "$dir is not a complete backup (no .complete)"
    [ -r "$key" ] || die "no age identity at $key (secrets/age/keys.txt of the old cluster: from your password manager)"
    for f in nomad.snap.age consul.snap.age state-tofu-consul.tfstate.age state-tofu-nomad.tfstate.age; do
      [ -s "$dir/$f" ] || die "$dir/$f is missing (backups from before the states were included cannot be restored with this task)"
      age -d -i "$key" "$dir/$f" >/dev/null || die "$dir/$f does not decrypt with $key"
    done
    for r in tofu-consul tofu-nomad; do
      mkdir -p "state/$r"
      tmp=$(mktemp "state/$r/.restore.XXXXXX")
      age -d -i "$key" "$dir/state-$r.tfstate.age" > "$tmp"
      if [ -e "state/$r/terraform.tfstate" ] && ! cmp -s "$tmp" "state/$r/terraform.tfstate"; then echo "state/$r/terraform.tfstate replaced by the one of the backup"; fi
      mv "$tmp" "state/$r/terraform.tfstate"
    done
    # the plugin dir of a clone is empty; the playbook runs `tofu init` itself
    echo "backup $name is complete and readable; states are in place"
    ;;
  wait)
    for i in $(seq 1 30); do
      if "$(dirname "$0")/smoke.sh" >/tmp/restore-smoke.log 2>&1; then cat /tmp/restore-smoke.log; echo "smoke is green"; exit 0; fi
      echo "smoke not green yet ($i/30), waiting"; sleep 20
    done
    cat /tmp/restore-smoke.log; die "smoke did not turn green"
    ;;
  *) echo "usage: $0 prepare <backup dir name> | wait" >&2; exit 2 ;;
esac
