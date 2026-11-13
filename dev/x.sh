#!/usr/bin/env bash
# Run a command on a node of the test cluster, from the host, without quoting trouble. Host side, from the cluster repo (`task dev:x -- ...`).
#   dev/x.sh [-n <node>] [-r] '<command>'        e.g.  dev/x.sh 'nomad job status; consul members'
#   dev/x.sh [-n <node>] [-r] <<'EOF' ... EOF     a longer script on stdin: nothing in it is touched by the local shell, ansible or docker
# Default: on the first server, as the ansible user, with the ops tokens of nomad and consul in the environment (nomad, consul, curl to the
# local APIs work as they are). -r: as root (ansible become; NO tokens). -n: another node (inventory name, e.g. itc-debian).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
dev_cluster_repo
node="" root=0
while getopts n:r o; do case $o in n) node=$OPTARG ;; r) root=1 ;; *) exit 2 ;; esac; done
shift $((OPTIND - 1))
if [ "$root" = 1 ]; then
  [ $# -gt 0 ] || set -- "$(cat)"
  remote root "$node" "$1"
elif [ $# -gt 0 ]; then
  remote run "$node" "$1"
else
  remote run "$node" -
fi
