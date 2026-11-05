#!/usr/bin/env bash
# Summary of the phases that scripts/timed.sh logged during the last `task deploy`.
log=${1:-.deploy-timing.log}
[ -f "$log" ] || { echo "no timing yet: run task deploy"; exit 0; }
awk -F'\t' '$1 != "deploy:wall-clock" {t += $2} {printf "%-24s %5ss\n", $1, $2} END {printf "%-24s %5ss\n", "(sum of phases)", t}' "$log"
