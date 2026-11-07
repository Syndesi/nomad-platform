#!/usr/bin/env bash
# Cluster PKI. Runs inside the tools container (needs openssl), via `task pki:*`.
#   pki.sh ca                  create the PKI ONCE (refuses to overwrite): the root and its two intermediates
#   pki.sh intermediate <ansible|stepca>
#                              replace an intermediate (new key, signed by the root): `stepca` yearly, `ansible` rarely
#   pki.sh info                subject, validity and days left of the root and the intermediates
# The three levels (all name-constrained, critical, see cluster_ca_permitted_* in defaults.yml):
#   root               pki/ca.pem (public, the only thing nodes and clients trust); key pki/root.sops.yml (sops/age). The key is NOT in the
#                      inventory, so no deploy ever loads it: only this script reads it (to make an intermediate). Move the file out of the
#                      cluster repo when you like, and put it back for the yearly `pki.sh intermediate stepca`.
#   ansible            pki/intermediate-ansible.pem; key inventory/group_vars/all/ca.sops.yml (cluster_intermediate_key). What the controller
#                      signs with: agent certs of nomad / consul, node certs, the ingress certificate, internal wildcard.
#   stepca             pki/intermediate-stepca.pem; key inventory/group_vars/all/stepca.sops.yml (cluster_stepca_intermediate_key). Handed to
#                      the step-ca job (which issues the short-lived certs of the internal services), lifetime cluster_stepca_intermediate_valid_days.
# Leaf certs are NOT made here: every node creates its own key + CSR and ansible (role cluster_tls)
# signs it with the ansible intermediate, so keys never leave the nodes and `task maintenance` can renew them.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "${CLUSTER_DIR:-/work}"
cd "${CLUSTER_DIR:-/work}"
CA_CERT=pki/ca.pem
ROOT_KEY_FILE=pki/root.sops.yml
declare -A INT_CERT=([ansible]=pki/intermediate-ansible.pem [stepca]=pki/intermediate-stepca.pem)
declare -A INT_KEY_FILE=([ansible]=inventory/group_vars/all/ca.sops.yml [stepca]=inventory/group_vars/all/stepca.sops.yml)
declare -A INT_KEY_VAR=([ansible]=cluster_intermediate_key [stepca]=cluster_stepca_intermediate_key)
declare -A INT_DAYS_VAR=([ansible]=cluster_intermediate_valid_days [stepca]=cluster_stepca_intermediate_valid_days)

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

# name_constraints: the nameConstraints extension value, from cluster_ca_permitted_dns / _ips
name_constraints() {
  local nc="" d i
  IFS=, read -ra dns <<< "$(cvar "cluster_ca_permitted_dns | join(',')")"; IFS=, read -ra ips <<< "$(cvar "cluster_ca_permitted_ips | join(',')")"
  [ "${#dns[@]}" -gt 0 ] && [ -n "${dns[0]}" ] && [ "${#ips[@]}" -gt 0 ] && [ -n "${ips[0]}" ] \
    || { echo "cluster_ca_permitted_dns / cluster_ca_permitted_ips are empty" >&2; return 1; }
  for d in "${dns[@]}"; do nc="$nc${nc:+,}permitted;DNS:$d"; done
  for i in "${ips[@]}"; do nc="$nc,permitted;IP:$(cidr_mask "$i")"; done
  echo "$nc"
}

# sops_write <var> <key file> <target>: a yaml file with the private key, encrypted
sops_write() {
  { echo "---"; echo "# Private key, sops/age encrypted. Made by scripts/pki.sh."; echo "$1: |"; sed 's/^/  /' "$2"; } \
    | sops --config .sops.yaml --encrypt --input-type yaml --output-type yaml --filename-override "$PWD/$3" /dev/stdin > "$3"
}

# make_intermediate <ansible|stepca> <work dir with root.key>: new key, certificate signed by the root, files in place
make_intermediate() {
  local which=$1 work=$2 name days nc
  name=$(cvar cluster_name); days=$(cvar "${INT_DAYS_VAR[$which]}"); nc=$(name_constraints)
  openssl ecparam -name prime256v1 -genkey -noout -out "$work/$which.key"
  openssl req -new -key "$work/$which.key" -subj "/O=$name cluster/CN=$name cluster $which intermediate" -out "$work/$which.csr"
  # pathlen 0: it signs leaves only. The name constraints are the root's again (a verifier applies every level's).
  printf '%s\n' "basicConstraints=critical,CA:TRUE,pathlen:0" "keyUsage=critical,keyCertSign,cRLSign" "nameConstraints=critical,$nc" \
    "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid" > "$work/$which.ext"
  openssl x509 -req -in "$work/$which.csr" -CA "$CA_CERT" -CAkey "$work/root.key" -CAcreateserial -CAserial "$work/root.srl" \
    -days "$days" -sha256 -extfile "$work/$which.ext" -out "$work/$which.pem" 2>/dev/null
  # the chain must verify the way a client will do it (name constraints included)
  openssl verify -CAfile "$CA_CERT" "$work/$which.pem" >/dev/null
  cp "$work/$which.pem" "${INT_CERT[$which]}"; chmod 0644 "${INT_CERT[$which]}"
  sops_write "${INT_KEY_VAR[$which]}" "$work/$which.key" "${INT_KEY_FILE[$which]}"
  echo "intermediate $which: ${INT_CERT[$which]} (valid $days days), key ${INT_KEY_FILE[$which]} (encrypted)"
}

case "${1:-}" in
  ca)
    for f in "$CA_CERT" "$ROOT_KEY_FILE" "${INT_CERT[@]}" "${INT_KEY_FILE[@]}"; do
      if [ -e "$f" ]; then
        echo "PKI already exists ($f) - refusing to overwrite (delete pki/ and the sops files of the intermediates by hand to start over;" >&2
        echo "that invalidates every issued leaf cert, so all nodes must be re-deployed)." >&2
        exit 1
      fi
    done
    [ -e .sops.yaml ] || { echo "no .sops.yaml: run 'task age:init' first" >&2; exit 1; }
    name=$(cvar cluster_name); CA_DAYS=$(cvar cluster_ca_valid_days)
    [ -n "$name" ] || { echo "cluster_name is not set in inventory/group_vars/all/" >&2; exit 1; }
    nc=$(name_constraints)
    mkdir -p pki
    work=$(mktemp -d /dev/shm/ca.XXXXXX)   # tmpfs: the clear text keys never touch a disk
    ok=
    # no half-made PKI if anything below fails
    trap 'rm -rf "$work"; [ -n "$ok" ] || rm -f "$CA_CERT" "$ROOT_KEY_FILE" "${INT_CERT[@]}" "${INT_KEY_FILE[@]}"' EXIT
    umask 077
    openssl ecparam -name prime256v1 -genkey -noout -out "$work/root.key"
    # pathlen 1: the root signs intermediates, they sign leaves
    openssl req -x509 -new -key "$work/root.key" -sha256 -days "$CA_DAYS" \
      -subj "/O=$name cluster/CN=$name cluster CA" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -addext "nameConstraints=critical,$nc" \
      -addext "subjectKeyIdentifier=hash" \
      -out "$CA_CERT"
    chmod 0644 "$CA_CERT"
    sops_write cluster_root_key "$work/root.key" "$ROOT_KEY_FILE"
    echo "root: $CA_CERT (valid $CA_DAYS days), key $ROOT_KEY_FILE (encrypted, not read by any deploy)"
    make_intermediate ansible "$work"
    make_intermediate stepca "$work"
    ok=1
    ;;
  intermediate)
    which=${2:-}; [ -n "${INT_CERT[$which]:-}" ] || { echo "usage: $0 intermediate ansible|stepca" >&2; exit 2; }
    [ -e "$CA_CERT" ] && [ -e "$ROOT_KEY_FILE" ] || { echo "the root ($CA_CERT, $ROOT_KEY_FILE) is not here: put the key file back, or run 'task pki:ca' on a fresh start" >&2; exit 1; }
    work=$(mktemp -d /dev/shm/ca.XXXXXX); trap 'rm -rf "$work"' EXIT
    umask 077
    sops --decrypt --extract '["cluster_root_key"]' "$ROOT_KEY_FILE" > "$work/root.key"
    make_intermediate "$which" "$work"
    echo "a new ansible intermediate: redeploy (task deploy:ansible) and renew the leaf certs (task maintenance); a new stepca one: redeploy"
    ;;
  info)
    [ -e "$CA_CERT" ] || { echo "no CA yet: run 'task pki:ca'" >&2; exit 1; }
    printf 'root         %-34s until %s (%s days left)\n' "$(openssl x509 -noout -subject -in "$CA_CERT" | sed 's/^subject=//')" \
      "$(openssl x509 -noout -enddate -in "$CA_CERT" | cut -d= -f2)" "$(days_left "$CA_CERT")"
    for w in ansible stepca; do
      [ -e "${INT_CERT[$w]}" ] || { printf '%-12s missing (%s)\n' "$w" "${INT_CERT[$w]}"; continue; }
      printf '%-12s %-34s until %s (%s days left)\n' "$w" "$(openssl x509 -noout -subject -in "${INT_CERT[$w]}" | sed 's/^subject=//')" \
        "$(openssl x509 -noout -enddate -in "${INT_CERT[$w]}" | cut -d= -f2)" "$(days_left "${INT_CERT[$w]}")"
    done
    echo "(leaf certs live on the nodes only: 'task pki:nodes' shows them)"
    ;;
  *) echo "usage: $0 ca|intermediate ansible|stepca|info" >&2; exit 2 ;;
esac
