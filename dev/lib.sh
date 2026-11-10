#!/usr/bin/env bash
# Helpers of the dev tools (sourced). These tools are for LOCAL DEVELOPMENT of the platform against a throw-away test cluster. They run on the
# host, from the cluster repo (the one with base/ in it), and are not part of any deployment: no role, playbook or task of the platform uses them.
# See CLAUDE.md ("Working on this repo").

dev_die() { echo "dev: $*" >&2; exit 1; }

# The cluster repo is the working directory (or the one in $DEV_CLUSTER_DIR); the platform repo itself has no Taskfile, no inventory and no tools container
dev_cluster_repo() {
  [ -z "${DEV_CLUSTER_DIR:-}" ] || cd "$DEV_CLUSTER_DIR" || dev_die "cannot cd to $DEV_CLUSTER_DIR"
  if ! grep -qs '^CLUSTER_NAME=.' .env || [ ! -d inventory ] || [ ! -f base/VERSION ]; then
    dev_die "$PWD is not a cluster repo (needs .env with CLUSTER_NAME, inventory/ and base/). Run it from the test cluster, e.g. cd ../incusos-test-cluster (or set DEV_CLUSTER_DIR)"
  fi
}

# tools <command...>: in the long-running tools container of this cluster (stdin passes through)
tools() { docker compose exec -T tools "$@"; }

# remote <mode> [node] [args...]: dev/remote.sh inside the tools container (modes: run, root, write, put). The node defaults to the first server.
remote() { tools /work/base/dev/remote.sh "$@"; }

# on_server <script>: run a shell script on the server with the ops tokens (NOMAD_TOKEN, CONSUL_HTTP_TOKEN set, nomad and consul talk to localhost)
on_server() { remote run "" "$1"; }

# the nodes of the cluster, one per line
dev_nodes() { tools bash -c '. /work/base/scripts/lib.sh; cd /work; { inventory_group cluster_servers; inventory_group cluster_clients; } | sort -u'; }

dev_clients() { tools bash -c '. /work/base/scripts/lib.sh; cd /work; inventory_group cluster_clients | sort -u | wc -l' | tr -d ' \r'; }
