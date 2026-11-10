#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # "check && ok || bad" output style; the remote shell expands its own variables
# "Can I work on the test cluster right now?" - the failure modes of the sessions so far, checked in seconds instead of found out an hour into a
# deploy. Host side, from the cluster repo: `task dev:doctor` (read only) or `task dev:doctor -- --fix` (also repairs what is safe to repair).
# NOT the platform's `task smoke` (that one asks whether the deployed cluster works; this one asks whether the sandbox around it is in order).
# Order matters: later checks need the earlier ones. Exit 1 if a check fails.
#   ok / WARN / FAIL  one line each;  fix  what --fix did
# A cluster repo can add its own checks (machine layer: the incus host, ssh forwards...) in scripts/dev-doctor.sh; it gets --fix too and prints the
# same lines.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
dev_cluster_repo
fix=0; [ "${1:-}" = --fix ] && fix=1
fail=0
ok()   { printf 'ok    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }
did()  { printf 'fix   %s\n' "$*"; }

# 1. the tools that are only in the container (a "command not found" on the host is not a problem of the repo)
missing=""; for t in docker task rsync jq; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
[ -z "$missing" ] && ok "host tools: docker task rsync jq (ansible, tofu, yamllint, shellcheck are in the tools container only: task lint, task shell, dev/x.sh)" || bad "missing on the host:$missing"

# 2. the machine layer of this cluster repo (incus host reachable, VMs running, ssh forwards listening...)
if [ -x scripts/dev-doctor.sh ]; then
  out=$(scripts/dev-doctor.sh "$@" 2>&1); rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || fail=1
fi

# 3. the tools container: running, and with the current image (a changed Dockerfile or .env version needs `task up`)
if [ -n "$(docker compose ps --status running -q tools 2>/dev/null)" ]; then ok "tools container is running"
elif [ "$fix" = 1 ]; then task up >/dev/null 2>&1 && did "task up (tools container started)" || bad "task up failed"
else bad "tools container is not running: task up"; fi

# 4. base/ is a COPY of the platform checkout: uncommitted changes only reach the cluster after `task base:sync`; a smoke or a deploy on a stale
#    base/ tests the old code and says nothing about the change
src=${PLATFORM_SRC:-$(cd ../nomad-platform 2>/dev/null && pwd)}
if [ -n "${src:-}" ] && [ -d "$src" ]; then
  drift=$(rsync -ani --delete --exclude=/.git "$src/" base/ | grep -v '^\.d' | head -5)
  if [ -z "$drift" ]; then ok "base/ equals the working tree of $src"
  elif [ "$fix" = 1 ] && [ -x scripts/sync-base.sh ]; then scripts/sync-base.sh >/dev/null && did "base/ synced from $src"
  else bad "base/ is not the working tree of $src (task base:sync): $(printf '%s' "$drift" | tr '\n' ';' | cut -c1-160)"; fi
else warn "no platform checkout at ../nomad-platform (set PLATFORM_SRC): cannot tell whether base/ is stale"; fi

# 5. the secrets and keys the tasks need (a missing one makes a task fail late and with a confusing message)
miss=""; for f in .sops.yaml pki/ca.pem inventory/group_vars/all/secrets.sops.yml; do [ -e "$f" ] || miss="$miss $f"; done
[ -z "$miss" ] && ok "age identity, CA and secrets exist" || bad "missing:$miss (task age:init pki:ca secrets:init, or task secrets:ensure after an update)"

# 6. every node answers over ssh (through the tools container, as the scripts and ansible do it)
nodes=$(dev_nodes 2>/dev/null)
if [ -z "$nodes" ]; then bad "no nodes in the inventory (is the tools container up and base/ synced?)"; else
  for n in $nodes; do
    if tools bash -c ". /work/base/scripts/lib.sh; cd /work; cluster_exec $n true" >/dev/null 2>&1; then ok "ssh to $n"
    else bad "ssh to $n does not work (ssh forwards down? VM stopped? the nodes refuse root and passwords: only the ansible user with the key)"; fi
  done
fi

# 7. has the cluster settled (a node restart or an interrupted deploy leaves jobs starting for minutes: `task smoke` then fails for nothing)
if [ "$fail" = 0 ]; then
  out=$(remote run "" "sh -s -- $(dev_clients) 0" < "$here/remote/state.sh" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then ok "cluster has settled (consul members alive, nomad leader, nodes ready, jobs running, no failed deployment)"
  else warn "cluster has not settled: $(printf '%s' "$out" | tr '\n' ';' | cut -c1-300) -> task dev:wait (background), then task smoke"; fi
fi

echo
[ "$fail" = 0 ] && echo "doctor: ok" || echo "doctor: FAILED (task dev:doctor -- --fix repairs the safe ones)"
exit "$fail"
