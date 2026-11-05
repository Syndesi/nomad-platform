#!/usr/bin/env bash
# Cluster CA handling. Runs inside the tools container (needs openssl), via `task pki:*`.
#   pki.sh ca      create the CA ONCE (refuses to overwrite): certificate pki/ca.pem, key sops-encrypted
#   pki.sh info    print subject, validity and days left of the CA
# Leaf certs are NOT made here: every node creates its own key + CSR and ansible (role cluster_tls)
# signs it with this CA, so keys never leave the nodes and `task maintenance` can renew them.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "${CLUSTER_DIR:-/work}"
cd "${CLUSTER_DIR:-/work}"
CA_CERT=pki/ca.pem
CA_KEY_FILE=inventory/group_vars/all/ca.sops.yml

days_left() { # <cert>
  local end now
  # busybox date: needs an explicit input format, and openssl prints the zone as a trailing "GMT"
  end=$(date -u -D '%b %e %H:%M:%S %Y' -d "$(openssl x509 -noout -enddate -in "$1" | cut -d= -f2 | sed 's/ GMT$//')" +%s)
  now=$(date +%s)
  echo $(( (end - now) / 86400 ))
}

case "${1:-}" in
  ca)
    if [ -e "$CA_CERT" ] || [ -e "$CA_KEY_FILE" ]; then
      echo "CA already exists ($CA_CERT, $CA_KEY_FILE) - refusing to overwrite (delete both by hand to start over;" >&2
      echo "that invalidates every issued leaf cert, so all nodes must be re-deployed)." >&2
      exit 1
    fi
    [ -e .sops.yaml ] || { echo "no .sops.yaml: run 'task age:init' first" >&2; exit 1; }
    name=$(cvar cluster_name); CA_DAYS=$(cvar cluster_ca_valid_days)
    [ -n "$name" ] || { echo "cluster_name is not set in inventory/group_vars/all/" >&2; exit 1; }
    work=$(mktemp -d /dev/shm/ca.XXXXXX)   # tmpfs: the clear text key never touches a disk
    ok=
    # no half-made CA if anything below fails
    trap 'rm -rf "$work"; [ -n "$ok" ] || rm -f "$CA_CERT" "$CA_KEY_FILE"' EXIT
    umask 077
    openssl ecparam -name prime256v1 -genkey -noout -out "$work/ca.key"
    openssl req -x509 -new -key "$work/ca.key" -sha256 -days "$CA_DAYS" \
      -subj "/O=$name cluster/CN=$name cluster CA" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -addext "subjectKeyIdentifier=hash" \
      -out "$CA_CERT"
    chmod 0644 "$CA_CERT"
    { echo "---"; echo "# Cluster CA private key, sops/age encrypted. The certificate is pki/ca.pem."; echo "cluster_ca_key: |"; sed 's/^/  /' "$work/ca.key"; } \
      | sops --config .sops.yaml --encrypt --input-type yaml --output-type yaml --filename-override "$PWD/$CA_KEY_FILE" /dev/stdin > "$CA_KEY_FILE"
    ok=1
    echo "CA created: $CA_CERT (valid $CA_DAYS days), key $CA_KEY_FILE (encrypted)"
    ;;
  info)
    [ -e "$CA_CERT" ] || { echo "no CA yet: run 'task pki:ca'" >&2; exit 1; }
    printf 'CA   %-28s until %s (%s days left)\n' "$(openssl x509 -noout -subject -in "$CA_CERT" | sed 's/^subject=//')" \
      "$(openssl x509 -noout -enddate -in "$CA_CERT" | cut -d= -f2)" "$(days_left "$CA_CERT")"
    echo "(leaf certs live on the nodes only: 'task pki:nodes' shows them)"
    ;;
  *) echo "usage: $0 ca|info" >&2; exit 2 ;;
esac
