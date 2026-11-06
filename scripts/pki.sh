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

# cidr_mask <a.b.c.d/n>: "a.b.c.d/m.m.m.m" (openssl's nameConstraints wants the netmask form)
cidr_mask() {
  local ip=${1%/*} n=${1#*/} i m="" bits
  for i in 1 2 3 4; do
    bits=$(( n >= 8 ? 8 : (n > 0 ? n : 0) )); n=$(( n - bits ))
    m="$m${m:+.}$(( (256 - (1 << (8 - bits))) & 255 ))"
  done
  echo "$ip/$m"
}

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
    # name constraints: only the cluster's names and addresses (see cluster_ca_permitted_* in defaults.yml)
    nc=""; IFS=, read -ra dns <<< "$(cvar "cluster_ca_permitted_dns | join(',')")"; IFS=, read -ra ips <<< "$(cvar "cluster_ca_permitted_ips | join(',')")"
    [ "${#dns[@]}" -gt 0 ] && [ -n "${dns[0]}" ] && [ "${#ips[@]}" -gt 0 ] && [ -n "${ips[0]}" ] \
      || { echo "cluster_ca_permitted_dns / cluster_ca_permitted_ips are empty" >&2; exit 1; }
    for d in "${dns[@]}"; do nc="$nc${nc:+,}permitted;DNS:$d"; done
    for i in "${ips[@]}"; do nc="$nc,permitted;IP:$(cidr_mask "$i")"; done
    umask 077
    openssl ecparam -name prime256v1 -genkey -noout -out "$work/ca.key"
    openssl req -x509 -new -key "$work/ca.key" -sha256 -days "$CA_DAYS" \
      -subj "/O=$name cluster/CN=$name cluster CA" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -addext "nameConstraints=critical,$nc" \
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
