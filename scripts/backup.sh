#!/usr/bin/env bash
# Backup of what lives only on the servers: the Nomad and Consul raft snapshots (jobs, variables, ACLs, KV, intentions),
# the tofu states that belong to them (task restore needs both from the same moment), the database of authelia (second factors, SQL dump), Grafana's database (SQL dump) and traefik's acme.json (the ACME account and certificates, only with a public ACME CA). NOT included: application
# data, host volumes, anything the cluster repo already holds (inventory, encrypted secrets, states).
# Every file is age-encrypted to the recipients of .sops.yaml, so the backups are safe to move off site. Inside the tools
# container, via `task backup`; written to <cluster repo>/backups/<name>-<time>/ (git-ignored), the newest BACKUP_KEEP stay.
# Restore with `task restore -- <backup dir>`, see the README ("Backup and restore").
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "${CLUSTER_DIR:-/work}"
cd "${CLUSTER_DIR:-/work}" || exit 1
keep=${BACKUP_KEEP:-10}
server=${CLUSTER_SERVER:-$(inventory_group cluster_servers | head -1)}
name=$(cvar cluster_name)
mapfile -t recipients < <(grep -o 'age1[a-z0-9]*' .sops.yaml | sort -u)
[ ${#recipients[@]} -gt 0 ] || { echo "no age recipient in .sops.yaml (task age:init)" >&2; exit 1; }
rflags=(); for r in "${recipients[@]}"; do rflags+=(-r "$r"); done
out=backups/$name-$(date -u +%Y%m%dT%H%M%SZ)
umask 077
mkdir -p "$out"
work=$(mktemp -d /dev/shm/backup.XXXXXX)
trap 'rm -rf "$work"; [ -e "$out/.complete" ] || { echo "backup failed, removing $out" >&2; rm -rf "$out"; }' EXIT
nm=$(nomad_ops_token)
cm=$(consul_ops_token)

# snapshot <file> <env assignment> <snapshot save command>: the server writes it into a private temp dir and streams it back
snapshot() {
  cluster_exec "$server" env "$2" sh -lc "umask 077; d=\$(mktemp -d); trap 'rm -rf \$d' EXIT; $3 \$d/s.snap >/dev/null && cat \$d/s.snap" \
    | age "${rflags[@]}" > "$out/$1.snap.age"
}
snapshot nomad "NOMAD_TOKEN=$nm" "nomad operator snapshot save"
snapshot consul "CONSUL_HTTP_TOKEN=$cm" "consul snapshot save"

# The tofu states of the two roots hold the ids and secrets of the acl objects that are in these snapshots. They belong to the snapshots:
# a restore needs the states of this very moment (they are encrypted by tofu already; age-encrypted again like everything here).
for r in tofu-consul tofu-nomad; do
  [ -s "state/$r/terraform.tfstate" ] || { echo "no state/$r/terraform.tfstate: a backup of a cluster that was never deployed?" >&2; exit 1; }
  age "${rflags[@]}" < "state/$r/terraform.tfstate" > "$out/state-$r.tfstate.age"
done

# acme.json of the traefik volume (only exists with an ACME CA)
for n in $(inventory_group cluster_ingress); do
  if cluster_root "$n" "test -s /var/lib/nomad/volumes/traefik/acme.json" >/dev/null 2>&1; then
    cluster_root "$n" "cat /var/lib/nomad/volumes/traefik/acme.json" | age "${rflags[@]}" > "$out/acme-$n.json.age"
  fi
done

# authelia's database (sqlite: second factors, devices, bans) from every node that has one, as an SQL dump made by sqlite3 itself (in a throwaway container, nothing is installed on the node) (`.dump` reads in
# one transaction: consistent even if authelia writes meanwhile; a copy of the file could catch a half-written page). Restore replays it into a new file.
sqlite_image=$(cvar cluster_sqlite_image)
# both instances: authelia (the public names) and authelia-internal (the zone behind the VPN); files authelia-<node>.sql.age / authelia-internal-<node>.sql.age
for inst in authelia:cluster_authelia_dir authelia-internal:cluster_authelia_internal_dir; do
  iname=${inst%%:*}; adir=$(cvar "${inst#*:}")
  for n in $( { inventory_group cluster_servers; inventory_group cluster_clients; } | sort -u); do
    if cluster_root "$n" "test -s $adir/db.sqlite3" >/dev/null 2>&1; then
      [ -n "$sqlite_image" ] || { echo "cluster_sqlite_image is not set (an image with sqlite3, see the defaults): needed to dump the database of authelia" >&2; exit 1; }
      # a throwaway container: no network, only the authelia folder (rw: sqlite needs the -shm file of a WAL database even to read)
      cluster_root "$n" "docker run --rm --network none --read-only --user 0 -v $adir:/data --entrypoint sqlite3 $sqlite_image -cmd '.timeout 10000' /data/db.sqlite3 .dump" | age "${rflags[@]}" > "$out/$iname-$n.sql.age"
      age -d -i "${SOPS_AGE_KEY_FILE:-/age/keys.txt}" "$out/$iname-$n.sql.age" > "$work/authelia.sql"
      grep -q 'CREATE TABLE' "$work/authelia.sql" || { echo "$iname dump of $n is empty" >&2; exit 1; }
      rm -f "$work/authelia.sql"
    fi
  done
done

# step-ca's database (issued certificates, ACME accounts and orders; no key): streamed out of its allocation as a tar (badger, an LSM store: the tables are
# written once and a copy of a running store is almost always whole; if it ever fails to open after a restore, remove the folder: the CA starts
# empty and traefik asks for its certificates again, nothing else is lost)
if [ "$(cvar cluster_stepca_enabled)" = True ] || [ "$(cvar cluster_stepca_enabled)" = true ]; then
  nport=$(cvar cluster_nomad_http_port); tdir=$(cvar cluster_tls_dir)
  if printf '%s\n' "$nm" | cluster_exec "$server" sh -c "read -r t; export NOMAD_TOKEN=\$t NOMAD_ADDR=https://127.0.0.1:$nport NOMAD_CACERT=$tdir/ca.pem
      a=\$(nomad job allocs -json step-ca | jq -r '[.[] | select(.ClientStatus == \"running\")] | sort_by(.CreateTime) | last | .ID // empty')
      [ -n \"\$a\" ] || exit 3
      nomad alloc exec -i=false -t=false -task step-ca \$a tar -C /db -cf - ." 2>/dev/null | age "${rflags[@]}" > "$out/step-ca-db.tar.age" && [ -s "$out/step-ca-db.tar.age" ]; then
    age -d -i "${SOPS_AGE_KEY_FILE:-/age/keys.txt}" "$out/step-ca-db.tar.age" | tar -tf - >/dev/null || { echo "step-ca database tar is not readable" >&2; exit 1; }
  else
    rm -f "$out/step-ca-db.tar.age"; echo "(step-ca is not running: its database is not in this backup)" >&2
  fi
fi

# Grafana's database (dashboards, folders, alert rules, users): a pg_dump made inside the running postgres container of the monitoring stack. The logs and
# metrics (Loki, Prometheus) are not part of any backup.
if [ "$(cvar cluster_monitoring_enabled)" = True ] || [ "$(cvar cluster_monitoring_enabled)" = true ]; then
  mnode=$(cvar cluster_monitoring_node)
  # shellcheck disable=SC2016 # runs on the node
  dump='c=$(docker ps -q --filter label=com.hashicorp.nomad.job_name=monitoring-server --filter label=com.hashicorp.nomad.task_name=postgres | head -1); [ -n "$c" ] && docker exec "$c" pg_dump -U grafana --clean --if-exists grafana'
  if cluster_root "$mnode" "$dump" | age "${rflags[@]}" > "$out/grafana-db.sql.age" && [ -s "$out/grafana-db.sql.age" ] \
     && age -d -i "${SOPS_AGE_KEY_FILE:-/age/keys.txt}" "$out/grafana-db.sql.age" > "$work/grafana.sql" && grep -q 'PostgreSQL database dump' "$work/grafana.sql"; then
    rm -f "$work/grafana.sql"
  else
    rm -f "$out/grafana-db.sql.age"; echo "(the monitoring stack is not running: Grafana's database is not in this backup)" >&2
  fi
fi

# prove they are readable: decrypt on tmpfs and let the product inspect its snapshot (binaries from `task build`)
for p in nomad consul; do
  [ -s "$out/$p.snap.age" ] || { echo "$p snapshot is empty" >&2; exit 1; }
  age -d -i "${SOPS_AGE_KEY_FILE:-/age/keys.txt}" "$out/$p.snap.age" > "$work/$p.snap"
  bin=$(find /artifacts -maxdepth 1 -name "$p-*alpine*" 2>/dev/null | head -1)
  if [ -z "$bin" ]; then echo "(no $p binary in /artifacts, snapshot not inspected)"; continue; fi
  if [ "$p" = nomad ]; then "$bin" operator snapshot inspect "$work/$p.snap" >/dev/null; else "$bin" snapshot inspect "$work/$p.snap" >/dev/null; fi
done
touch "$out/.complete"
du -h "$out"/*.age
# keep the newest $keep
# shellcheck disable=SC2012
ls -1dt backups/"$name"-* 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -rf
echo "backup written to $out (readable only with the age key of this cluster)"
