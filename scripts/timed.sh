#!/usr/bin/env bash
# Run a command and print how long it took: scripts/timed.sh <label> <command...>
# Used by `task deploy` so every phase shows up in the timing summary at the end.
set -uo pipefail
label=$1; shift
start=$(date +%s)
"$@"; rc=$?
end=$(date +%s)
printf '%s\t%s\t%s\n' "$label" "$((end - start))" "$rc" >> "${TIMING_LOG:-/tmp/deploy-timing.log}"
printf '⏱  %s: %ss (rc=%s)\n' "$label" "$((end - start))" "$rc"
exit "$rc"
