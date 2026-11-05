#!/usr/bin/env bash
# Backup of what lives only on the servers: the Nomad and Consul raft snapshots (jobs, variables, ACLs, KV, intentions),
# the tofu states that belong to them (task restore needs both from the same moment), the folder of authelia (second factors) and traefik's acme.json (the ACME account and certificates, only with a public ACME CA). NOT included: application
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
nm=$("$BASE/scripts/secrets.sh" get cluster_nomad_management_token)
cm=$("$BASE/scripts/secrets.sh" get cluster_consul_management_token)

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

# authelia's folder (sqlite: second factors, devices, bans) from every node that has one: tar as root through ansible, base64 for the trip. A plain copy of
# the files: authelia writes rarely (a login, a ban), but a backup in the middle of a login could in theory catch a half-written file.
adir=$(cvar cluster_authelia_dir)
for n in $( { inventory_group cluster_servers; inventory_group cluster_clients; } | sort -u); do
  if cluster_root "$n" "test -s $adir/db.sqlite3" >/dev/null 2>&1; then
    cluster_root "$n" "tar -C $adir -cf - . | base64" | base64 -d | age "${rflags[@]}" > "$out/authelia-$n.tar.age"
  fi
done

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
