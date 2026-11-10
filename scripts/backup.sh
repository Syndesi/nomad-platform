#!/usr/bin/env bash
# Backup of what lives only on the servers: the Nomad and Consul raft snapshots (jobs, variables, ACLs, KV, intentions),
# the tofu states that belong to them (task restore needs both from the same moment), the databases of both authelias (second factors, SQL dumps), Grafana's database (SQL dump) and traefik's acme.json (the ACME account and certificates, only with a public ACME CA). NOT included: application
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

# snapshot <file> <nomad token> <consul token> <snapshot save command>: the server writes it into a private temp dir and streams it back
snapshot() {
  cluster_exec_tokens "$server" "$2" "$3" "umask 077; d=\$(mktemp -d); trap 'rm -rf \$d' EXIT; $4 \$d/s.snap >/dev/null && cat \$d/s.snap" \
    | age "${rflags[@]}" > "$out/$1.snap.age"
}
snapshot nomad "$nm" "" "nomad operator snapshot save"
snapshot consul "" "$cm" "consul snapshot save"

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

# the databases of both authelias (second factors, devices, bans): a pg_dump made inside the running postgres container of the job authelia-db (runc, outside gVisor,
# so Postgres' own locking and shared memory are real and the dump is a consistent snapshot while authelia keeps writing). Replayed by `task restore`.
# files authelia-db-authelia.sql.age / authelia-db-authelia-internal.sql.age. The sessions (Redis) are not backed up.
# shellcheck disable=SC2016 # runs on the node
dump='c=$(docker ps -q --filter label=com.hashicorp.nomad.job_name=authelia-db --filter label=com.hashicorp.nomad.task_name=postgres | head -1); [ -n "$c" ] && docker exec "$c" pg_dump -U "$DB" --clean --if-exists "$DB"'
for inst in authelia authelia-internal; do
  db=${inst//-/_}
  found=
  for n in $( { inventory_group cluster_servers; inventory_group cluster_clients; } | sort -u); do
    if cluster_root "$n" "DB=$db; $dump" | age "${rflags[@]}" > "$out/authelia-db-$inst.sql.age" && [ -s "$out/authelia-db-$inst.sql.age" ] \
       && age -d -i "${SOPS_AGE_KEY_FILE:-/age/keys.txt}" "$out/authelia-db-$inst.sql.age" > "$work/authelia.sql" \
       && grep -q 'PostgreSQL database dump complete' "$work/authelia.sql"; then
      rm -f "$work/authelia.sql"; found=1; break
    fi
    rm -f "$work/authelia.sql"
  done
  [ -n "$found" ] || { rm -f "$out/authelia-db-$inst.sql.age"; echo "(authelia-db is not running: the database of $inst is not in this backup)" >&2; }
done

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
