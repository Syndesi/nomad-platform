#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # "check && ok || bad" output style; the remote shell expands its own variables
# INSIDE the tools container (called by dev/lib.sh `remote`): run things on a node.
#   remote.sh run   <node|""> <script>      sh -lc <script> as the ansible user with NOMAD_TOKEN / CONSUL_HTTP_TOKEN (ops tokens, they travel on stdin
#                                           and never in a command line). The script "-" reads the script from stdin: `sh -s -- <args>` is
#                                           also fine, e.g. remote.sh run "" "sh -s -- 2" < script.sh
#   remote.sh root  <node|""> <command>     as root (ansible become); prints stdout, returns the exit status
#   remote.sh write <node|""> <file>        stdin -> file on the node (umask 077)
#   remote.sh put   <node|""> <dir>         a tar stream on stdin is unpacked into <dir> on the node (created)
# An empty node is the first server (or $CLUSTER_SERVER).
set -euo pipefail
cd "${CLUSTER_DIR:-/work}"
# shellcheck source=../scripts/lib.sh
. "$(dirname "$0")/../scripts/lib.sh"
mode=${1:?mode} node=${2:-}
shift 2 || shift $#
[ -n "$node" ] || node=${CLUSTER_SERVER:-$(inventory_group cluster_servers | head -1)}
case $mode in
  run)
    script=${1:?script}
    nt=$(nomad_ops_token); ct=$(consul_ops_token)
    if [ "$script" = - ]; then cluster_exec_tokens "$node" "$nt" "$ct" "sh -s" /dev/stdin
    else
      # a script that starts with "sh -s" takes its body from stdin
      case $script in "sh -s"*) cluster_exec_tokens "$node" "$nt" "$ct" "$script" /dev/stdin ;; *) cluster_exec_tokens "$node" "$nt" "$ct" "$script" ;; esac
    fi ;;
  root)  cluster_root "$node" "${1:?command}" ;;
  write) cluster_exec "$node" sh -c 'umask 077; mkdir -p "$(dirname "$1")"; cat > "$1"' sh "${1:?file}" ;;
  put)   cluster_exec "$node" sh -c 'mkdir -p "$1" && tar -x -C "$1"' sh "${1:?dir}" ;;
  *) echo "usage: remote.sh run|root|write|put <node> ..." >&2; exit 2 ;;
esac
