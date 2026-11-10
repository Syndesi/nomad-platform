#!/usr/bin/env bash
# The fast loop for a change in ONE job file: put the job (and its template directory) from base/jobs/ on the server and run it, without the
# 15 to 30 minutes of `task deploy:ansible` (which also waits up to 10 minutes per job that does not become healthy, and re-runs every other job).
# Host side, from the cluster repo: `task dev:job -- <job> [options]`.
#   dev/job.sh <job> [--file <job file>] [--restart] [--patient] [--timeout <s>]
#   --file     the job file without .nomad.hcl, if it differs from the job name (authelia-internal runs authelia.nomad.hcl)
#   --restart  stop the job first (an unchanged spec would restart nothing)
#   --patient  keep waiting for the deployment although an allocation already failed (default: stop and diagnose at the first failure)
# It runs with the same variables the last full deploy used (/etc/cluster/jobs/<job>.vars.json, so the job must have been deployed once) and the
# ops token. It does NOT replace the deploy: variables that come from the inventory (defaults.yml, cluster_jobs_list) and everything outside the
# job file (roles, tofu) only change through `task base:sync` + `task deploy:ansible`. Do one full deploy at the end.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
dev_cluster_repo
job="" file="" restart=0 patient=0 timeout=420
while [ $# -gt 0 ]; do
  case $1 in
    --file) file=$2; shift ;; --restart) restart=1 ;; --patient) patient=1 ;; --timeout) timeout=$2; shift ;;
    -*) dev_die "unknown option $1" ;;
    *) job=$1 ;;
  esac
  shift
done
[ -n "$job" ] || dev_die "usage: job.sh <job> [--file <job file>] [--restart] [--patient] [--timeout <s>]"
file=${file:-$job}
[ -f "base/jobs/$file.nomad.hcl" ] || dev_die "base/jobs/$file.nomad.hcl does not exist (is base/ synced? task base:sync; for authelia-internal: --file authelia)"
stage=/tmp/dev-jobs/$job

# the job file and every template directory next to it (jobs/<name>/, jobs/<file>/), as the deploy puts them on the server
dirs=()
for d in "$job" "$file"; do [ -d "base/jobs/$d" ] && dirs+=("$d"); done
tar -C base/jobs -c "$file.nomad.hcl" "${dirs[@]}" | remote put "" "$stage" || dev_die "could not copy the job to the server (task dev:doctor)"

# the variables of the last deploy (root only: /etc/cluster/jobs is 0700), with the template directory pointed at the copy above
vars=$(remote root "" "cat /etc/cluster/jobs/$job.vars.json") || dev_die "no /etc/cluster/jobs/$job.vars.json on the server: the job was never deployed (task deploy:ansible)"
printf '%s' "$vars" | jq --arg d "$stage" 'if has("templates_dir") then .templates_dir = ($d + "/" + (.templates_dir | split("/") | last)) else . end' \
  | remote write "" "$stage/$job.vars.json" || dev_die "could not write the variables file"

remote run "" "sh -s -- $job $file $stage $timeout $restart $patient" < "$(dirname "$0")/remote/job-run.sh"
rc=$?
remote run "" "rm -rf $stage" >/dev/null 2>&1 || true
exit $rc
