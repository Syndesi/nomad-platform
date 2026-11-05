#!/usr/bin/env bash
# Does the deployed cluster work? Inside the tools container, via `task smoke [-- connect]`.
# Everything is checked on the server node with the read-only tokens; exits 1 if a check fails.
set -uo pipefail
cd "${CLUSTER_DIR:-/work}" || exit 1
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
server=${CLUSTER_SERVER:-$(inventory_group cluster_servers | head -1)}
domain=${CLUSTER_DOMAIN:-$(cvar cluster_domain)}
nt=$("$BASE/scripts/tofu-enc.sh" tofu-nomad output -json nomad_tokens | jq -r .readonly)
ct=$("$BASE/scripts/tofu-enc.sh" tofu-consul output -json service_tokens | jq -r .readonly)
fail=0
on_server() { cluster_exec "$server" env "NOMAD_TOKEN=$nt" "CONSUL_HTTP_TOKEN=$ct" sh -lc "$1"; }
check() { # <description> <command on the server> <expected stdout (grep -x)>
  local out
  out=$(on_server "$2" 2>&1)
  if printf '%s\n' "$out" | grep -qx -- "$3"; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s (got: %s)\n' "$1" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"; fail=1; fi
}

check "consul: every member alive"            "consul members | awk 'NR>1 && \$3!=\"alive\"' | wc -l" 0
nodes=$( { inventory_group cluster_servers; inventory_group cluster_clients; } | sort -u | wc -l)
clients=$(inventory_group cluster_clients | wc -l)
check "consul: all $nodes nodes are members"  "[ \$(consul members | wc -l) -ge $((nodes + 1)) ] && echo yes" yes
check "nomad: a leader is elected"            "nomad server members | awk 'NR>1 && \$5==\"true\"' | wc -l" 1
# a reinstalled node leaves its old (down) entry until nomad's node gc, so: enough ready nodes, not "all"
check "nomad: all $clients clients ready"          "[ \$(nomad node status | grep -c ' ready *\$') -ge $clients ] && echo yes" yes
check "nomad: authelia running"               "nomad job status authelia | grep -c 'running'" 2
check "nomad: traefik running"                "nomad job status traefik | grep -c 'running'" 2
check "consul: workload identity registered the services" "consul catalog services | grep -cx -e authelia -e traefik" 2
for h in nomad consul traefik; do
  check "ingress: $h.$domain asks for a login (302)" "curl -sk -o /dev/null -w '%{http_code}' --resolve $h.$domain:443:127.0.0.1 https://$h.$domain/" 302
done
# the names of the local proxy accept the hybrid post-quantum key exchange and nothing else; the browser names still take a classical one
for h in nomad-cli consul-cli auth-cli; do
  check "ingress: $h.$domain takes X25519MLKEM768"  "echo | openssl s_client -connect 127.0.0.1:443 -servername $h.$domain -tls1_3 -groups X25519MLKEM768 >/dev/null 2>&1 && echo accepted || echo refused" accepted
  check "ingress: $h.$domain refuses X25519 alone"  "echo | openssl s_client -connect 127.0.0.1:443 -servername $h.$domain -tls1_3 -groups X25519 >/dev/null 2>&1 && echo accepted || echo refused" refused
done
check "ingress: nomad.$domain still takes X25519"   "echo | openssl s_client -connect 127.0.0.1:443 -servername nomad.$domain -tls1_3 -groups X25519 >/dev/null 2>&1 && echo accepted || echo refused" accepted
check "ingress: auth.$domain answers"         "curl -sk -o /dev/null -w '%{http_code}' --resolve auth.$domain:443:127.0.0.1 https://auth.$domain/" 200
if [ "$(cvar cluster_acme_ca)" = internal ]; then
  check "ingress cert is from the cluster CA"   "echo | openssl s_client -connect 127.0.0.1:443 -servername nomad.$domain 2>/dev/null | openssl x509 -noout -issuer | grep -c 'CN *= *.* cluster CA'" 1
else
  check "ingress cert is from the ACME CA ($(cvar cluster_acme_ca))" "echo | openssl s_client -connect 127.0.0.1:443 -servername nomad.$domain 2>/dev/null | openssl x509 -noout -issuer | grep -c -E \"Let's Encrypt|STAGING\"" 1
fi
check "dns: authelia.service.consul resolves" "getent hosts authelia.service.consul | wc -l" 1
# the scripts run unprivileged; what needs root (docker, chronyc, nft) goes through ansible (cluster_root: become, with the password)
root_check() { # <description> <node> <command as root> <expected stdout (grep -x)>
  local out
  out=$(cluster_root "$2" "$3" 2>&1)
  if printf '%s\n' "$out" | grep -qx -- "$4"; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s (got: %s)\n' "$1" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"; fail=1; fi
}
root_check "ntp: clock is synchronized on $server" "$server" "{ chronyc tracking 2>/dev/null | grep -q '^Leap status *: Normal' || timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; } && echo yes" yes

# dns is what everything else hangs on: check it on EVERY node, as the node itself and (clients) from a container
for n in $( { inventory_group cluster_servers; inventory_group cluster_clients; } | sort -u); do
  nd() { cluster_exec "$n" sh -c "$1" 2>&1; }
  res=$(nd 'getent hosts authelia.service.consul >/dev/null && echo consul-ok; grep -qE "^nameserver 127[.]" /etc/resolv.conf && echo local-resolver')
  if [ "$(printf '%s\n' "$res" | sort | tr '\n' ' ')" = "consul-ok local-resolver " ]; then printf 'ok    dns on %s: consul name, local resolver\n' "$n"; else printf 'FAIL  dns on %s (got: %s)\n' "$n" "$(printf '%s' "$res" | tr '\n' ' ' | cut -c1-100)"; fail=1; fi
  if [ -n "$(nd 'command -v docker')" ]; then
    c=$(cluster_root "$n" "docker run --rm busybox:1.37 nslookup authelia.service.consul 2>&1 | grep -c '^Address: '")
    if [ "${c:-0}" -ge 1 ] 2>/dev/null; then printf 'ok    dns in a container on %s\n' "$n"; else printf 'FAIL  dns in a container on %s (got: %s)\n' "$n" "$c"; fail=1; fi
  fi
done

# firewall: the table is loaded, the input chain drops by default, and the cluster ports are limited to the subnet
if [ "$(cvar cluster_firewall_enabled)" = True ] || [ "$(cvar cluster_firewall_enabled)" = true ]; then
  for n in $( { inventory_group cluster_servers; inventory_group cluster_clients; } | sort -u); do
    root_check "firewall on $n: table loaded, input policy drop, ssh open, cluster ports limited" "$n" "nft list chain inet cluster input | grep -c -e 'policy drop' -e 'tcp dport 22 accept' -e 'ip saddr .* tcp dport' | tr -d ' '" 3
  done
fi

# ssh: the nodes must refuse root, passwords and every algorithm outside the restricted set (the controller's client
# config is the reference). Checked from here, so this is what an attacker with network access would see.
ssh_cfg=${CLUSTER_RUN_DIR:-/dev/shm/cluster}/ssh_config
[ -s "$ssh_cfg" ] || "$BASE/scripts/ssh-config.sh" >/dev/null
for n in $( { inventory_group cluster_servers; inventory_group cluster_clients; } | sort -u); do
  try() { ssh -F "$ssh_cfg" -o BatchMode=yes -o ConnectTimeout=10 "$@" true >/dev/null 2>&1; }
  if try -l "$(cvar cluster_ansible_user)" "$n"; then
    bad=""
    try -l root "$n" && bad="$bad root-login"
    try -o PubkeyAuthentication=no -o PreferredAuthentications=password -o PasswordAuthentication=yes "$n" && bad="$bad password-login"
    try -o KexAlgorithms=curve25519-sha256 "$n" && bad="$bad classic-kex"
    try -o Ciphers=aes128-ctr "$n" && bad="$bad weak-cipher"
    try -o HostKeyAlgorithms=rsa-sha2-512 "$n" && bad="$bad rsa-hostkey"
    if [ -z "$bad" ]; then printf 'ok    ssh on %s: key login works; root, passwords, other kex/ciphers/host keys are refused\n' "$n"; else printf 'FAIL  ssh on %s accepts:%s\n' "$n" "$bad"; fail=1; fi
  else
    printf 'FAIL  ssh on %s: the ansible user cannot log in\n' "$n"; fail=1
  fi
done

if [ "${1:-}" = connect ]; then
  echo "-- consul connect (envoy sidecars through the cni bridge)"
  mt=$("$BASE/scripts/secrets.sh" get cluster_consul_management_token)
  nm=$("$BASE/scripts/secrets.sh" get cluster_nomad_management_token)
  mgmt() { cluster_exec "$server" env "NOMAD_TOKEN=$nm" "CONSUL_HTTP_TOKEN=$mt" sh -lc "$1"; }
  mgmt "cat > /tmp/connect.nomad.hcl" < "$BASE/tests/connect.nomad.hcl"
  mgmt "consul intention create -replace -allow count-client count-api >/dev/null 2>&1 || true"
  if mgmt "nomad job run -var datacenter=$(cvar cluster_datacenter) /tmp/connect.nomad.hcl" >/tmp/connect-run.log 2>&1; then echo "ok    job deployed (both groups healthy)"; else echo "FAIL  job deploy"; tail -15 /tmp/connect-run.log; fail=1; fi
  alloc=$(mgmt "nomad job allocs -json connect-test | jq -r '.[]|select(.TaskGroup==\"client\")|.ID' | head -1")
  # the sidecars of a fresh deployment need a moment before the first request goes through
  for _ in $(seq 8); do
    out=$(mgmt "nomad alloc exec -task client $alloc wget -qO- -T 5 http://127.0.0.1:9001/" 2>&1)
    printf '%s' "$out" | grep -q count && break
    sleep 4
  done
  if printf '%s' "$out" | grep -q count; then echo "ok    client reached count-api through the mesh: $(printf '%s' "$out" | cut -c1-60)"; else echo "FAIL  mesh request: $out"; fail=1; fi
  mgmt "consul intention create -replace -deny count-client count-api >/dev/null 2>&1 || consul intention delete count-client count-api >/dev/null 2>&1; true"
  sleep 2
  out=$(mgmt "nomad alloc exec -task client $alloc wget -qO- -T 5 http://127.0.0.1:9001/" 2>&1)
  if printf '%s' "$out" | grep -q count; then echo "FAIL  denied intention still lets traffic through"; fail=1; else echo "ok    deny intention blocks the request"; fi
  mgmt "nomad job stop -purge connect-test >/dev/null; consul intention delete count-client count-api >/dev/null 2>&1; rm -f /tmp/connect.nomad.hcl; true"
fi
exit $fail
