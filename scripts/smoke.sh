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
check "nomad: authelia-internal running"      "nomad job status authelia-internal | grep -c 'running'" 2
check "nomad: traefik running"                "nomad job status traefik | grep -c 'running'" 2
check "consul: workload identity registered the services" "consul catalog services | grep -cx -e authelia -e authelia-internal -e traefik" 3
stepca=$(cvar cluster_stepca_enabled)
if [ "$stepca" = True ] || [ "$stepca" = true ]; then
  check "nomad: step-ca running"                "nomad job status step-ca | grep -c 'running'" 2
  check "consul: step-ca and its sidecar are passing" "consul catalog services | grep -cx -e step-ca -e step-ca-sidecar-proxy" 2
fi
mon=$(cvar cluster_monitoring_enabled)
if [ "$mon" = True ] || [ "$mon" = true ]; then
  check "nomad: monitoring-server running (one allocation)" "nomad job status monitoring-server | grep -c ' run  *running'" 1
  check "nomad: monitoring-agent on every client"  "[ \$(nomad job status monitoring-agent | grep -c ' run  *running') -ge $clients ] && echo yes" yes
  check "nomad: ntfy running"                      "nomad job status ntfy | grep -c ' run  *running'" 1
  check "consul: grafana, gatus, loki, prometheus registered" "consul catalog services | grep -cx -e monitoring-grafana -e monitoring-gatus -e monitoring-loki -e monitoring-prometheus" 4
  check "consul: no monitoring check is critical" "curl -s -H \"X-Consul-Token: \$CONSUL_HTTP_TOKEN\" --cacert $(cvar cluster_tls_dir)/ca.pem https://127.0.0.1:$(cvar cluster_consul_https_port)/v1/health/state/critical | grep -c monitoring" 0
fi
# the ops UIs are not on the public entry point any more (they live in the zone behind the VPN)
for h in nomad consul traefik; do
  check "ingress: $h.$domain is not published (404)" "curl -sk -o /dev/null -w '%{http_code}' --resolve $h.$domain:443:127.0.0.1 https://$h.$domain/" 404
done
# the portal accepts the hybrid post-quantum key exchange and nothing else
check "ingress: auth.$domain takes X25519MLKEM768"  "echo | openssl s_client -connect 127.0.0.1:443 -servername auth.$domain -tls1_3 -groups X25519MLKEM768 >/dev/null 2>&1 && echo accepted || echo refused" accepted
check "ingress: auth.$domain refuses X25519 alone"  "echo | openssl s_client -connect 127.0.0.1:443 -servername auth.$domain -tls1_3 -groups X25519 >/dev/null 2>&1 && echo accepted || echo refused" refused
check "ingress: auth.$domain answers"         "curl -sk -o /dev/null -w '%{http_code}' --resolve auth.$domain:443:127.0.0.1 https://auth.$domain/" 200
if [ "$(cvar cluster_acme_ca)" = internal ]; then
  check "ingress cert is from the cluster CA"   "echo | openssl s_client -connect 127.0.0.1:443 -servername auth.$domain 2>/dev/null | openssl x509 -noout -issuer | grep -c 'CN *= *.* ansible intermediate'" 1
else
  check "ingress cert is from the ACME CA ($(cvar cluster_acme_ca))" "echo | openssl s_client -connect 127.0.0.1:443 -servername auth.$domain 2>/dev/null | openssl x509 -noout -issuer | grep -c -E \"Let's Encrypt|STAGING\"" 1
fi
# the VPN: the gate (wstunnel) answers on the public 443 for its name and wants a client certificate; nothing of the VPN is on any other port
vpnhost=$(cvar cluster_vpn_host)
check "vpn: $vpnhost refuses a client without certificate" "curl -sk -o /dev/null --max-time 8 --resolve $vpnhost:443:127.0.0.1 https://$vpnhost/ >/dev/null 2>&1 && echo accepted || echo refused" refused
for p in 8443 8444 51820 9000; do
  check "vpn: port $p is not open on the node" "(echo | timeout 2 nc 127.0.0.1 $p >/dev/null 2>&1 && echo open) || echo closed" closed
done
check "dns: authelia.service.consul resolves" "getent hosts authelia.service.consul | wc -l" 1
# the scripts run unprivileged; what needs root (docker, chronyc, nft) goes through ansible (cluster_root: become, with the password)
root_check() { # <description> <node> <command as root> <expected stdout (grep -x)>
  local out
  out=$(cluster_root "$2" "$3" 2>&1)
  if printf '%s\n' "$out" | grep -qx -- "$4"; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s (got: %s)\n' "$1" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"; fail=1; fi
}
root_check "ntp: clock is synchronized on $server" "$server" "{ chronyc tracking 2>/dev/null | grep -q '^Leap status *: Normal' || timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; } && echo yes" yes

if [ "$stepca" = True ] || [ "$stepca" = true ]; then
  ing=$(inventory_group cluster_ingress | head -1)
  root_check "step-ca: wstunnel's certificate is from step-ca, valid for another day" "$ing" "{ openssl x509 -in $(cvar cluster_vpn_tls_dir)/vpn.pem -noout -issuer | grep -q 'stepca intermediate' && openssl x509 -in $(cvar cluster_vpn_tls_dir)/vpn.pem -noout -checkend 86400 >/dev/null && echo yes; } || echo no" yes
  root_check "step-ca: traefik holds a certificate for every internal name" "$ing" "[ \$(jq '[.stepca.Certificates[]?.domain.main] | length' /var/lib/nomad/volumes/traefik/acme-stepca.json 2>/dev/null || echo 0) -ge 4 ] && echo yes || echo no" yes
fi
# client certificates of the VPN devices that expire soon
warn=$("$BASE/scripts/vpn.sh" check 2>/dev/null || true)
if [ -n "$warn" ]; then printf 'WARN  %s\n' "$warn"; else echo "ok    vpn: no client certificate expires within $(cvar cluster_vpn_client_warn_days) days"; fi

# dns is what everything else hangs on: check it on EVERY node, as the node itself and (clients) from a container
for n in $( { inventory_group cluster_servers; inventory_group cluster_clients; } | sort -u); do
  nd() { cluster_exec "$n" sh -c "$1" 2>&1; }
  res=$(nd 'getent hosts authelia.service.consul >/dev/null && echo consul-ok; grep -qE "^nameserver 127[.]" /etc/resolv.conf && echo local-resolver')
  if [ "$(printf '%s\n' "$res" | sort | tr '\n' ' ')" = "consul-ok local-resolver " ]; then printf 'ok    dns on %s: consul name, local resolver\n' "$n"; else printf 'FAIL  dns on %s (got: %s)\n' "$n" "$(printf '%s' "$res" | tr '\n' ' ' | cut -c1-100)"; fail=1; fi
  # exactly one dns server per node: one nameserver line in resolv.conf (a dhcp client that rewrites it adds the provider's), and on alpine one
  # dhcpcd manager (the network stack starts the first one at boot; a second one with an older config rewrites resolv.conf at the next lease renewal)
  ns=$(nd 'grep -c ^nameserver /etc/resolv.conf' | tail -1)
  dh=$(nd 'pgrep -f "dhcpcd: .[m]anager" | wc -l' | tail -1)
  if [ "$ns" = 1 ] && [ "${dh:-0}" -le 1 ] 2>/dev/null; then printf 'ok    one dns server on %s (resolv.conf: 1 nameserver, dhcpcd managers: %s)\n' "$n" "$dh"; else printf 'FAIL  one dns server on %s (nameserver lines: %s, dhcpcd managers: %s)\n' "$n" "$ns" "$dh"; fail=1; fi
  if [ -n "$(nd 'command -v docker')" ]; then
    c=$(cluster_root "$n" "docker run --rm busybox:1.37 nslookup authelia.service.consul 2>&1 | grep -c '^Address: '")
    if [ "${c:-0}" -ge 1 ] 2>/dev/null; then printf 'ok    dns in a container on %s\n' "$n"; else printf 'FAIL  dns in a container on %s (got: %s)\n' "$n" "$c"; fail=1; fi
    cn=$(cluster_root "$n" "docker run --rm busybox:1.37 grep -c ^nameserver /etc/resolv.conf")
    if [ "$cn" = 1 ]; then printf 'ok    one dns server in a container on %s\n' "$n"; else printf 'FAIL  one dns server in a container on %s (nameserver lines: %s)\n' "$n" "$cn"; fail=1; fi
  fi
done

# firewall: the table is loaded, the input chain drops by default, and the cluster ports are limited to the subnet
if [ "$(cvar cluster_firewall_enabled)" = True ] || [ "$(cvar cluster_firewall_enabled)" = true ]; then
  # with the ssh rate limit on, the cluster's exemption rule (ip saddr ... tcp dport 22 accept) matches two of the patterns: 4 lines, not 3
  fw_lines=3; [ -n "$(cvar "cluster_firewall_ssh_rate | trim")" ] && fw_lines=4
  for n in $( { inventory_group cluster_servers; inventory_group cluster_clients; } | sort -u); do
    root_check "firewall on $n: table loaded, input policy drop, ssh open (rate limited), cluster ports limited" "$n" "nft list chain inet cluster input | grep -c -e 'policy drop' -e 'tcp dport 22 accept' -e 'ip saddr .* tcp dport' | tr -d ' '" "$fw_lines"
  done
fi

# containers' network rules and resolvers on the clients: the forward chain rejects new connections from the bridges (not the egress bridge),
# the nat chain redirects the egress bridge's queries, the restricted resolver runs
if [ "$(cvar cluster_firewall_enabled)" = True ] || [ "$(cvar cluster_firewall_enabled)" = true ]; then
  for n in $(inventory_group cluster_clients | sort -u); do
    root_check "egress rules on $n: bridges rejected, egress bridge open, dns redirect" "$n" "{ nft list chain inet cluster forward | grep -q 'reject with icmp admin-prohibited' && nft list chain inet cluster forward | grep -q 'iifname \"br-egress\" accept' && [ \$(nft list chain inet cluster container_dns | grep -c dnat) = 2 ]; } && echo ok" ok
    root_check "restricted resolver on $n: running, forwards only .consul" "$n" "{ pgrep -f '[d]ns-restricted.conf' >/dev/null && [ \$(grep -c '^server=' /etc/cluster/dns-restricted.conf) = 1 ] && grep -q '^local=/#/' /etc/cluster/dns-restricted.conf; } && echo ok" ok
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

# containers: no internet and no public dns by default (*.consul and the node's names work); the network egress (cni/egress) has both.
# One container of each kind on every client node.
mt=$(consul_ops_token)
nm=$(nomad_ops_token)
mgmt() { cluster_exec "$server" env "NOMAD_TOKEN=$nm" "CONSUL_HTTP_TOKEN=$mt" sh -lc "$1"; }
echo "-- container networks (bridge: closed, cni/egress: open) and their dns"
mgmt "cat > /tmp/network.nomad.hcl" < "$BASE/tests/network.nomad.hcl"
if mgmt "nomad job run -var datacenter=$(cvar cluster_datacenter) -var clients=$clients /tmp/network.nomad.hcl" >/tmp/network-run.log 2>&1; then
  echo "ok    network-test deployed: a container of each kind on every client"
  in_alloc() { mgmt "nomad alloc exec -task t $1 sh -c \"$2 >/dev/null 2>&1 && echo yes || echo no\"" 2>&1 | tail -1; }
  check_alloc() { # <description> <alloc> <command in the container> <expected: yes|no>
    local got; got=$(in_alloc "$2" "$3")
    if [ "$got" = "$4" ]; then echo "ok    $1"; else echo "FAIL  $1 (got: $got, wanted: $4)"; fail=1; fi
  }
  online=$(mgmt "curl -s -m 5 -o /dev/null -w '%{http_code}' http://1.1.1.1 || true")
  for g in bridge egress; do
    ids=$(mgmt "nomad job allocs -json network-test | jq -r '.[]|select(.TaskGroup==\"$g\" and .ClientStatus==\"running\")|.ID'")
    [ "$(printf '%s\n' "$ids" | grep -c .)" = "$clients" ] || { echo "FAIL  network-test: $g runs on $(printf '%s\n' "$ids" | grep -c .) of $clients clients"; fail=1; }
    for id in $ids; do
      node=$(mgmt "nomad alloc status -json $id | jq -r .NodeName")
      p="container ($g) on $node"
      check_alloc "$p: resolves authelia.service.consul"   "$id" "nslookup authelia.service.consul"   yes
      check_alloc "$p: resolves host.internal"                       "$id" "nslookup host.internal"           yes
      check_alloc "$p: has no global ipv6 address"                   "$id" "! ip -6 addr show scope global | grep -q inet6" yes
      if [ "$g" = bridge ]; then
        check_alloc "$p: public dns is refused"                      "$id" "nslookup example.com"             no
        check_alloc "$p: no internet"                                "$id" "wget -q -T 3 -O /dev/null http://1.1.1.1" no
      elif [ "$online" != 000 ]; then
        check_alloc "$p: public dns works"                           "$id" "nslookup example.com"             yes
        check_alloc "$p: internet works"                             "$id" "wget -q -T 5 -O /dev/null http://1.1.1.1" yes
      else
        echo "skip  $p: the node is offline, no internet checks"
      fi
    done
  done
else
  echo "FAIL  network-test deploy"; tail -15 /tmp/network-run.log; fail=1
fi
mgmt "nomad job stop -purge network-test >/dev/null; rm -f /tmp/network.nomad.hcl; true"

if [ "${1:-}" = connect ]; then
  echo "-- consul connect (envoy sidecars through the cni bridge)"
  mt=$(consul_ops_token)
  nm=$(nomad_ops_token)
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
  stepca=$(cvar cluster_stepca_enabled)
  if [ "$stepca" = True ] || [ "$stepca" = true ]; then
    # a workload without an intention to step-ca must not get an answer from it (default deny)
    mgmt "cat > /tmp/stepca-probe.nomad.hcl" < "$BASE/tests/stepca-probe.nomad.hcl"
    mgmt "nomad job run -detach -var datacenter=$(cvar cluster_datacenter) /tmp/stepca-probe.nomad.hcl >/dev/null 2>&1; true"
    pa=""; out=""
    for _ in $(seq 30); do
      pa=$(mgmt "nomad job allocs -json stepca-probe | jq -r 'sort_by(.CreateTime) | last | .ID // empty'")
      out=$(mgmt "nomad alloc logs -task curl $pa 2>/dev/null" 2>/dev/null)
      printf '%s' "$out" | grep -q DONE && break
      sleep 5
    done
    if ! printf '%s' "$out" | grep -q DONE; then echo "FAIL  step-ca probe did not finish"; fail=1
    elif printf '%s' "$out" | grep -q -E 'HTTP/|"newNonce"'; then echo "FAIL  a workload without an intention reached step-ca: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-100)"; fail=1
    else echo "ok    a workload without an intention gets no answer from step-ca"; fi
    mgmt "nomad job stop -purge stepca-probe >/dev/null 2>&1; rm -f /tmp/stepca-probe.nomad.hcl; true"
  fi
fi
exit $fail
