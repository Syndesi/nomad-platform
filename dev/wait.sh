#!/usr/bin/env bash
# Wait until the test cluster has settled (consul members alive, a nomad leader, nodes ready, every job running, no failed deployment). Use it after
# a node or VM restart, a deploy that was interrupted, or before `task smoke`: smoke run on a cluster that is still starting reports failures
# that are none. Prints the open problems whenever they change. Host side, from the cluster repo (`task dev:wait -- [seconds]`, default 600).
# It can take minutes: run it in the background (run_in_background) instead of polling with sleep.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
dev_cluster_repo
secs=${1:-600}
remote run "" "sh -s -- $(dev_clients) $secs" < "$(dirname "$0")/remote/state.sh"
