#!/bin/sh
# ON THE SERVER NODE (POSIX sh, busybox-safe; nomad, consul, jq; the ops tokens are in the environment). Piped in by dev/doctor.sh and dev/wait.sh:
#   sh -s -- [<expected ready clients>] [<wait seconds>] < state.sh
# One line per problem; nothing = the cluster has settled. With <wait seconds>: poll every 5 s and print the problems whenever they change,
# exit 0 as soon as there are none (and they stay away for 10 s), 1 when the time is up. A restarting nomad or consul is a problem, not an error.
clients=${1:-0} wait=${2:-0}

problems() {
  up=$(cut -d. -f1 /proc/uptime)
  [ "$up" -ge 300 ] || echo "this node booted ${up}s ago: services are still starting, give it a few minutes"
  if out=$(consul members 2>/dev/null); then
    n=$(printf '%s\n' "$out" | awk 'NR>1 && $3!="alive"' | wc -l)
    [ "$n" -eq 0 ] || echo "consul: $n member(s) not alive"
  else echo "consul: API not answering"; fi
  if out=$(nomad server members 2>/dev/null); then
    n=$(printf '%s\n' "$out" | awk '$5=="true"' | wc -l)
    [ "$n" -eq 1 ] || echo "nomad: no leader"
  else echo "nomad: API not answering"; return; fi
  # a reinstalled node leaves its old (down) entry until node gc: count the ready ones, do not insist on "all"
  ready=$(nomad node status 2>/dev/null | grep -c ' ready *$' || true)
  [ "$ready" -ge "$clients" ] || echo "nomad: $ready of $clients clients ready"
  nomad job status 2>/dev/null | awk 'NR>1 && $1!="==>" && NF>=4 && $2!="batch" && $4!="running" {print "job " $1 " is " $4}'
  nomad job status -json 2>/dev/null | jq -r '.[] | .Summary.JobID as $j
    | (.Summary.Summary | to_entries[] | select(.value.Queued + .value.Starting > 0) | "job \($j): group \(.key) has \(.value.Queued) queued, \(.value.Starting) starting allocation(s)"),
      (.Summary.Summary | to_entries[] | select(.value.Running == 0 and .value.Queued + .value.Starting == 0) | "job \($j): group \(.key) has no running allocation"),
      (.LatestDeployment // empty | select(.Status != "successful") | "job \($j): deployment of version \(.JobVersion) is \(.Status) (\(.StatusDescription))")'
}

start=$(date +%s); last=""; clean=0
while :; do
  now=$(problems)
  if [ -z "$now" ]; then
    clean=$((clean + 1))
    # settled once; with --wait it has to stay that way for two polls (a job that is about to restart looks fine for a moment)
    [ "$wait" -gt 0 ] || { echo "settled"; exit 0; }
    [ "$clean" -lt 3 ] || { echo "settled after $(( $(date +%s) - start ))s"; exit 0; }
  else
    clean=0
    [ "$now" = "$last" ] || { printf '%s\n' "$now"; last=$now; }
    [ "$wait" -gt 0 ] || exit 1
  fi
  [ $(( $(date +%s) - start )) -lt "$wait" ] || { echo "not settled after ${wait}s"; exit 1; }
  sleep 5
done
