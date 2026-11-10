#!/usr/bin/env bash
# Pre-generated cluster secrets (the values that need no running cluster), stored sops/age
# encrypted next to the inventory: ansible reads them as ordinary group vars (community.sops
# vars plugin), nothing secret is ever written to disk in clear text. Runs inside the tools
# container via `task secrets:*`.
#   secrets.sh init     create group_vars/all/secrets.sops.yml (refuses to overwrite)
#   secrets.sh ensure   add secrets that a newer version needs to an existing file (never changes existing ones)
#   secrets.sh show     print it decrypted
#   secrets.sh get <v>  print one value (e.g. cluster_consul_management_token)
#   secrets.sh edit     open it in $EDITOR through sops (interactive: use `task shell`)
#   secrets.sh uuid|key|string   print one fresh UUID / 32 byte base64 key / 64 char hex string
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "${CLUSTER_DIR:-/work}"
cd "${CLUSTER_DIR:-/work}"
FILE=inventory/group_vars/all/secrets.sops.yml

uuid()   { cat /proc/sys/kernel/random/uuid; }
key()    { openssl rand -base64 32; }
string() { openssl rand -hex 32; }


# The secrets of the monitoring stack and the hashes that go with them (printed as one json object; docs/monitoring.md). The hashes are made here, once:
# authelia's pbkdf2 and ntfy's bcrypt are not available as ansible filters in the tools container.
monitoring_json() {
  python3 - <<'MONEND'
import base64, hashlib, json, secrets, string, subprocess
import bcrypt

def ab64(b): return base64.b64encode(b).decode().rstrip("=").replace("+", ".")
def pbkdf2(pw, rounds=310000):
    salt = secrets.token_bytes(16)
    return "$pbkdf2-sha512$%d$%s$%s" % (rounds, ab64(salt), ab64(hashlib.pbkdf2_hmac("sha512", pw.encode(), salt, rounds, 64)))
def bc(pw): return bcrypt.hashpw(pw.encode(), bcrypt.gensalt(10)).decode().replace("$2b$", "$2a$")
def rnd(n): return "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(n))

oidc = secrets.token_hex(24)
ntfy_admin = rnd(24)
out = {
    "cluster_monitoring_postgres_password": rnd(32),
    "cluster_monitoring_grafana_secret_key": secrets.token_hex(32),
    "cluster_monitoring_grafana_admin_password": rnd(24),
    "cluster_monitoring_oidc_client_secret": oidc,
    "cluster_monitoring_oidc_client_secret_hash": pbkdf2(oidc),
    "cluster_authelia_oidc_hmac_secret": secrets.token_hex(32),
    "cluster_authelia_oidc_jwks_key": subprocess.run(["openssl", "genrsa", "4096"], capture_output=True, check=True, text=True).stdout,
    "cluster_authelia_internal_oidc_hmac_secret": secrets.token_hex(32),
    "cluster_authelia_internal_oidc_jwks_key": subprocess.run(["openssl", "genrsa", "4096"], capture_output=True, check=True, text=True).stdout,
    "cluster_monitoring_ntfy_admin_password": ntfy_admin,
    "cluster_monitoring_ntfy_admin_hash": bc(ntfy_admin),
    "cluster_monitoring_ntfy_alertmanager_hash": bc(rnd(40)),
    "cluster_monitoring_ntfy_alertmanager_token": "tk_" + "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(29)),
}
print(json.dumps(out))
MONEND
}

case "${1:-}" in
  init)
    if [ -e "$FILE" ]; then echo "$FILE exists - refusing to overwrite" >&2; exit 1; fi
    [ -e .sops.yaml ] || { echo "no .sops.yaml: run 'task age:init' first" >&2; exit 1; }
    cat <<YAML | sops --config .sops.yaml --encrypt --input-type yaml --output-type yaml --filename-override "$PWD/$FILE" /dev/stdin > "$FILE.new"
---
# Generated $(date -u +%FT%TZ) by scripts/secrets.sh. Encrypted with sops/age: edit with \`sops $FILE\`.
# Consul gossip encryption key (consul keygen format)
cluster_consul_gossip_key: "$(key)"
# Nomad gossip encryption key (nomad operator gossip keyring format)
cluster_nomad_gossip_key: "$(key)"
# Consul: acl.tokens.initial_management - the BOOTSTRAP token, only in the config while the cluster is built; tofu-consul then mints the ops token
# and the deploy deletes this one from the cluster
cluster_consul_management_token: "$(uuid)"
# Nomad: SecretID handed to 'nomad acl bootstrap <file>' (works once per cluster) - the BOOTSTRAP token; tofu-nomad then mints the ops token
# and the deploy deletes this one from the cluster
cluster_nomad_management_token: "$(uuid)"
# Passphrase of the client-side state encryption of the tofu roots that hold tokens (tofu-consul, tofu-nomad)
cluster_tofu_state_passphrase: "$(string)"
# Authelia
cluster_authelia_session_secret: "$(string)"
cluster_authelia_storage_encryption_key: "$(string)"
cluster_authelia_reset_password_jwt_secret: "$(string)"
# The second Authelia (authelia-internal, the zone behind the VPN): its own, never shared with the first
cluster_authelia_internal_session_secret: "$(string)"
cluster_authelia_internal_storage_encryption_key: "$(string)"
cluster_authelia_internal_reset_password_jwt_secret: "$(string)"
# The databases of both Authelias (job authelia-db): the superuser of Postgres, one user per instance, the password of Redis (sessions)
cluster_authelia_postgres_password: "$(string)"
cluster_authelia_db_password: "$(string)"
cluster_authelia_internal_db_password: "$(string)"
cluster_authelia_redis_password: "$(string)"
# Monitoring (docs/monitoring.md): database, Grafana, the OIDC client of Grafana at authelia-internal, ntfy
$(monitoring_json | python3 -c 'import sys,json; [print("%s: %s" % (k, json.dumps(v))) for k, v in json.load(sys.stdin).items()]')
YAML
    mv "$FILE.new" "$FILE"
    echo "written $FILE (encrypted)"
    ;;
  ensure)
    # secrets that later versions need, added to an existing file (existing values are never touched)
    [ -e "$FILE" ] || { echo "$FILE does not exist: task secrets:init" >&2; exit 1; }
    for k in cluster_authelia_internal_session_secret cluster_authelia_internal_storage_encryption_key cluster_authelia_internal_reset_password_jwt_secret cluster_authelia_postgres_password cluster_authelia_db_password cluster_authelia_internal_db_password cluster_authelia_redis_password; do
      if ! sops --decrypt --extract "[\"$k\"]" "$FILE" >/dev/null 2>&1; then
        sops set "$FILE" "[\"$k\"]" "\"$(string)\""
        echo "added $k"
      fi
    done

    # the monitoring stack (and the OIDC provider of authelia-internal that Grafana logs in with)
    mon=$(monitoring_json)
    for k in $(printf '%s' "$mon" | python3 -c 'import sys,json; print(" ".join(json.load(sys.stdin)))'); do
      if ! sops --decrypt --extract "[\"$k\"]" "$FILE" >/dev/null 2>&1; then
        sops set "$FILE" "[\"$k\"]" "$(printf '%s' "$mon" | K="$k" python3 -c 'import sys,json,os; print(json.dumps(json.load(sys.stdin)[os.environ["K"]]))')"
        echo "added $k"
      fi
    done
    ;;
  show)   sops --decrypt "$FILE" ;;
  get)    sops --decrypt --extract "[\"${2:?variable name}\"]" "$FILE" ;;
  edit)   sops "$FILE" ;;
  uuid)   uuid ;;
  key)    key ;;
  string) string ;;
  *) echo "usage: $0 init|ensure|show|get <var>|edit|uuid|key|string" >&2; exit 2 ;;
esac
