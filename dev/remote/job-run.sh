#!/bin/sh
# ON THE SERVER NODE (POSIX sh; ops tokens in the environment). Piped in by dev/job.sh:
#   sh -s -- <job> <job file name> <dir with the staged files> <timeout s> <restart 0|1> <patient 0|1> < job-run.sh
# Registers the job without waiting (`-detach`), then waits for ITS deployment itself and stops at the first failed allocation instead of after
# the progress deadline (10 minutes). Exit 0 = healthy (or the spec did not change), 1 = failed or timeout, with the diagnosis printed.
job=$1 file=$2 dir=$3 timeout=${4:-420} restart=${5:-0} patient=${6:-0}
ver() { nomad job inspect "$job" 2>/dev/null | jq -r '.Job.Version // empty'; }
consul_critical() { curl -s -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" https://127.0.0.1:8501/v1/health/state/critical | jq -r '.[]|"  \(.ServiceName) / \(.Name): \(.Output[0:110])"' 2>/dev/null | head -8; }

diag() { # <allocs json of this version>
  echo "--- allocations (newest first)"; nomad job allocs "$job" 2>/dev/null | head -8
  for id in $(printf '%s' "$1" | jq -r '[.[]|select(.ClientStatus!="running" and .ClientStatus!="complete")]|.[:3][]|.ID'); do
    echo "--- alloc $id: tasks and their events"
    nomad alloc status "$id" 2>/dev/null | sed -n '/^Task "/,$p' | head -40
    for t in $(nomad alloc status -json "$id" 2>/dev/null | jq -r '.TaskStates // {} | to_entries[] | select(.value.State!="running" or .value.Failed) | .key'); do
      echo "--- $t: stderr (tail)"; nomad alloc logs -stderr -task "$t" "$id" 2>&1 | tail -12
      echo "--- $t: stdout (tail)"; nomad alloc logs -task "$t" "$id" 2>&1 | tail -6
    done
  done
  pf=$(nomad job status "$job" 2>/dev/null | sed -n '/Placement Failure/,/^$/p'); [ -z "$pf" ] || { echo "--- placement"; echo "$pf"; }
  c=$(consul_critical); [ -z "$c" ] || { echo "--- consul checks that are critical"; echo "$c"; }
}

before=$(ver)
nomad job validate -var-file="$dir/$job.vars.json" "$dir/$file.nomad.hcl" >/dev/null 2>"$dir/validate.err" || { echo "validate failed:"; cat "$dir/validate.err"; exit 1; }
if [ "$restart" = 1 ]; then nomad job stop -detach "$job" >/dev/null 2>&1; sleep 3; fi
out=$(nomad job run -detach -var-file="$dir/$job.vars.json" "$dir/$file.nomad.hcl" 2>&1) || { echo "$out"; exit 1; }
after=$(ver)
if [ "$after" = "$before" ] && [ "$restart" = 0 ]; then
  echo "unchanged: the spec is identical to version $after, Nomad made no new version and restarted nothing (--restart to restart anyway)"; exit 0
fi
echo "registered: version ${before:-none} -> $after, waiting up to ${timeout}s for its deployment"

start=$(date +%s); stable=0
while :; do
  allocs=$(nomad job allocs -json "$job" 2>/dev/null | jq -c --argjson v "$after" '[.[]|select(.JobVersion==$v)]') || allocs='[]'
  [ -n "$allocs" ] || allocs='[]'
  dep=$(nomad job deployments -json "$job" 2>/dev/null | jq -r --argjson v "$after" '[.[]|select(.JobVersion==$v)]|first // empty|"\(.Status)|\(.StatusDescription)"')
  nfail=$(printf '%s' "$allocs" | jq '[.[]|select(.ClientStatus=="failed" or .ClientStatus=="lost")]|length')
  nrun=$(printf '%s' "$allocs" | jq '[.[]|select(.ClientStatus=="running")]|length')
  nother=$(printf '%s' "$allocs" | jq '[.[]|select(.ClientStatus!="running" and .ClientStatus!="complete" and .ClientStatus!="failed" and .ClientStatus!="lost")]|length')
  el=$(( $(date +%s) - start ))
  case $dep in
    successful*) echo "ok: deployment of version $after successful after ${el}s ($nrun running)"; exit 0 ;;
    failed*|cancelled*) echo "FAILED: deployment of version $after: ${dep#*|} (an auto_revert has probably put the previous spec back: nomad job history $job)"; diag "$allocs"; exit 1 ;;
  esac
  if [ "$nfail" -gt 0 ] && [ "$patient" = 0 ]; then echo "FAILED after ${el}s: $nfail allocation(s) of version $after failed (--patient waits for the deployment instead)"; diag "$allocs"; exit 1; fi
  if [ -z "$dep" ] && [ "$nrun" -gt 0 ] && [ "$nother" -eq 0 ] && [ "$nfail" -eq 0 ]; then
    stable=$((stable + 1)); [ "$stable" -lt 3 ] || { echo "ok: $nrun allocation(s) of version $after running after ${el}s (no deployment for this job type)"; exit 0; }
  else stable=0; fi
  [ "$el" -lt "$timeout" ] || { echo "TIMEOUT after ${timeout}s: deployment ${dep:-none}, $nrun running, $nother pending, $nfail failed"; diag "$allocs"; exit 1; }
  sleep 5
done
