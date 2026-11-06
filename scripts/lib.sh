#!/usr/bin/env bash
# Shared helpers of the platform scripts (sourced). Inside the tools container: /work = the cluster repo,
# /work/base = this repo (pinned in the cluster repo as a submodule).
BASE=${BASE:-${CLUSTER_DIR:-/work}/base}

# require_cluster_repo [dir]: call it first in every script that reads or writes cluster state. It fails unless the calling script is
# the platform checked out as the submodule `base/` of a real cluster repo (dir, default $CLUSTER_DIR or the current directory): the script
# sits in <dir>/base/scripts, <dir> has the cluster's .env (CLUSTER_NAME) and inventory/, and base/ is a checked out repo with a VERSION.
# Run from the platform repo itself, from a copy, or from the wrong directory, a script would act on whatever it finds there.
require_cluster_repo() {
  local caller=${BASH_SOURCE[1]:-} dir=${1:-${CLUSTER_DIR:-$PWD}} here root why=""
  root=$(cd "$dir" 2>/dev/null && pwd -P) || { echo "not a cluster repo: $dir does not exist" >&2; exit 1; }
  here=$(cd "$(dirname "$caller")" 2>/dev/null && pwd -P) || here=""
  if [ "$here" != "$root/base/scripts" ]; then why="this script is not $root/base/scripts/$(basename "$caller")"
  elif ! grep -qs '^CLUSTER_NAME=.' "$root/.env"; then why="$root/.env has no CLUSTER_NAME"
  elif [ ! -d "$root/inventory" ]; then why="$root/inventory is missing"
  elif [ ! -e "$root/base/.git" ] || [ ! -f "$root/base/VERSION" ]; then why="$root/base is not a checked out platform (git submodule update --init)"
  fi
  [ -z "$why" ] || { echo "$(basename "$caller"): refusing to run outside a cluster repo: $why" >&2; exit 1; }
}

# cvar <name>: value of an ansible variable of this cluster (templated, as the playbooks see it)
cvar() {
  ANSIBLE_CALLBACK_RESULT_FORMAT=json ansible localhost -m ansible.builtin.debug -a "msg={{ $1 }}" 2>/dev/null \
    | sed -nE 's/^ *"msg": "?([^"]*)"?,?$/\1/p' | head -1
}

# inventory_group <group>: the hosts of a cluster group, one per line
inventory_group() { ansible-inventory --list | jq -r --arg g "$1" '.[$g].hosts // [] | .[]'; }

# cluster_exec <host> <command...>: run a command on a node as the unprivileged ansible user (no root needed by the
# scripts). Default: ssh with the controller's client config (ssh-config.sh). $CLUSTER_EXEC (cluster .env) replaces the
# remote shell, %HOST% = the node, e.g. "incus exec myremote:%HOST% --user 1000 --". stdin and the exit status pass through.
cluster_exec() {
  local host=$1 tpl=${CLUSTER_EXEC:-} arg quoted="" sq="'"; shift
  if [ -z "$tpl" ]; then
    [ -s "${CLUSTER_RUN_DIR:-/dev/shm/cluster}/ssh_config" ] || "$BASE/scripts/ssh-config.sh" >/dev/null
    # ssh joins the arguments with spaces and the remote shell parses the result again: quote every argument for it
    for arg in "$@"; do quoted+=" '${arg//$sq/$sq\\$sq$sq}'"; done
    ssh -F "${CLUSTER_RUN_DIR:-/dev/shm/cluster}/ssh_config" "$host" "$quoted"
    return
  fi
  # shellcheck disable=SC2086 # the template is a command line on purpose
  ${tpl//%HOST%/$host} "$@"
}

# cluster_root <host> <shell command>: run a command as root on a node, through ansible (become, with the stored password if
# there is one: group_vars ansible_become_password). Prints the command's stdout, returns its exit status; 255 = unreachable.
# Used where a script needs root; everything else runs unprivileged through cluster_exec.
cluster_root() {
  local host=$1 out rc
  out=$(ANSIBLE_LOAD_CALLBACK_PLUGINS=1 ANSIBLE_STDOUT_CALLBACK=ansible.builtin.json ansible "$host" -b -m ansible.builtin.shell -a "$2" 2>/dev/null | sed -n '/^{$/,/^}$/p') || true
  if [ "$(jq -r --arg h "$host" '.plays[0].tasks[0].hosts[$h].unreachable // false' <<<"$out" 2>/dev/null)" = true ]; then
    jq -r --arg h "$host" '.plays[0].tasks[0].hosts[$h].msg' <<<"$out" >&2; return 255
  fi
  jq -r --arg h "$host" '.plays[0].tasks[0].hosts[$h].stdout // ""' <<<"$out"
  rc=$(jq -r --arg h "$host" '.plays[0].tasks[0].hosts[$h].rc // 1' <<<"$out" 2>/dev/null || echo 1)
  return "${rc:-1}"
}

# The consul management token for the scripts: the ops token from the state of tofu-consul once the deploy handed over to it, else the bootstrap token
consul_ops_token() {
  local t
  t=$("$BASE/scripts/tofu-enc.sh" tofu-consul output -json service_tokens 2>/dev/null | jq -r '.ops // empty' 2>/dev/null) || t=""
  if [ -n "$t" ]; then printf '%s\n' "$t"; else "$BASE/scripts/secrets.sh" get cluster_consul_management_token; fi
}
