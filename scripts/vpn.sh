#!/usr/bin/env bash
# The VPN of the internal services (zone <cluster_name>.internal): keys, devices, client files. Runs inside the tools container, via `task vpn:*`.
#   vpn.sh init              the server's wireguard key pair (ONCE; inventory/group_vars/all/vpn.sops.yml, sops/age)
#   vpn.sh client <device> [--project]   a new device: wireguard key pair + preshared key + address, a client certificate for the wstunnel gate (CN = device),
#                            all files under secrets/vpn/<device>/ (git-ignored). An existing device gets a new certificate only (the cert
#                            lives cluster_vpn_client_valid_days; run it again before it expires). The peer reaches the server with the next deploy.
#                            --project: the device of a project (CI, third party app): an address of the project half of the subnet (cluster_vpn_project_first
#                            and up), which reaches nomad-api. / consul-api.<zone> with an ACL token and not the ops UIs. `task project:vpn` calls it.
#                            Every device also gets connect.sh / disconnect.sh (up and down without installing anything: CI runners).
#   vpn.sh revoke <device>   remove the peer. This is the revocation: the wireguard key is the real gate, the certificate only gets through the disguise
#   vpn.sh list              devices, addresses, certificate expiry
#   vpn.sh check             print a warning for every client certificate that expires within cluster_vpn_client_warn_days (exit 0 either way)
# The device name is the CN of the certificate (wstunnel uses it as the HTTP path), the name of the wireguard peer and what the access log of
# traefik shows as the client address: one name for all three.
set -euo pipefail
CLUSTER_DIR=${CLUSTER_DIR:-/work}
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "$CLUSTER_DIR"
cd "$CLUSTER_DIR"
FILE=inventory/group_vars/all/vpn.sops.yml
INT_CERT=pki/intermediate-ansible.pem
INT_KEY_FILE=inventory/group_vars/all/ca.sops.yml

die() { echo "vpn: $*" >&2; exit 1; }
valid_name() { [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "device names: lowercase letters, digits, - (at most 31 characters)"; }
need_file() { [ -e "$FILE" ] || die "no VPN keys yet: task vpn:init"; }

# the yaml of the file, decrypted, on stdout / replaced from stdin
read_state() { sops decrypt "$FILE"; }
write_state() {
  [ -e .sops.yaml ] || die "no .sops.yaml: run 'task age:init' first"
  sops --config .sops.yaml --encrypt --input-type yaml --output-type yaml --filename-override "$PWD/$FILE" /dev/stdin > "$FILE.new" && mv "$FILE.new" "$FILE"
}

# peers as json lines: name ip public_key psk cert_expires
peers_json() { read_state | python3 -c 'import sys, yaml, json; print(json.dumps(yaml.safe_load(sys.stdin).get("cluster_vpn_peers") or []))'; }

case "${1:-}" in
  init)
    [ -e "$FILE" ] && die "$FILE exists - refusing to overwrite (a new server key means every device needs a new config)"
    umask 077
    priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey)
    printf -- '---\n# VPN server key and the peers (devices). Made by scripts/vpn.sh, sops/age encrypted.\ncluster_vpn_server_private_key: "%s"\ncluster_vpn_server_public_key: "%s"\ncluster_vpn_peers: []\n' "$priv" "$pub" | write_state
    echo "written $FILE (encrypted); server public key $pub"
    ;;

  client)
    dev=${2:?device name}; valid_name "$dev"; need_file
    project=false; [ "${3:-}" = "--project" ] && project=true
    name=$(cvar cluster_name); zone=$(cvar cluster_internal_zone); host=$(cvar cluster_vpn_host); subnet=$(cvar cluster_vpn_subnet)
    server_ip=$(cvar cluster_vpn_server_ip); mtu=$(cvar cluster_vpn_mtu); days=$(cvar cluster_vpn_client_valid_days)
    base=${subnet%.*}   # a /24: a.b.c
    out=secrets/vpn/$dev; mkdir -p "$out"; chmod 700 secrets/vpn "$out"
    umask 077
    work=$(mktemp -d /dev/shm/vpn.XXXXXX); trap 'rm -rf "$work"' EXIT
    state=$(peers_json)
    existing=$(jq -c --arg d "$dev" '.[] | select(.name == $d)' <<<"$state")
    # --- wireguard: a new device gets a key pair, a preshared key and the next free address; the private key only goes into the client file
    if [ -z "$existing" ]; then
      used=$(jq -r '.[].ip' <<<"$state")
      pfirst=$(cvar cluster_vpn_project_first)
      if [ "$project" = true ]; then lo=$pfirst; hi=254; else lo=2; hi=$((pfirst - 1)); fi
      ip=""; for n in $(seq "$lo" "$hi"); do grep -qx "$base.$n" <<<"$used" || { ip="$base.$n"; break; }; done
      [ -n "$ip" ] || die "the $([ "$project" = true ] && echo project || echo people) half of the subnet $subnet is full"
      priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey); psk=$(wg genpsk)
      new=true
    else
      ip=$(jq -r .ip <<<"$existing"); pub=$(jq -r .public_key <<<"$existing"); psk=$(jq -r .psk <<<"$existing"); priv=""; new=false
    fi
    # --- the client certificate for the wstunnel gate: CN = device, client auth only, no names.
    # With step-ca (default): issued INSIDE its allocation (`nomad alloc exec` on a server, over ssh like the deploy: no network path to step-ca, works
    # with the device's VPN down), provisioner "clients", valid cluster_vpn_client_valid_days. Without: signed here by the ansible intermediate.
    if [ "$(cvar cluster_stepca_enabled)" = True ] || [ "$(cvar cluster_stepca_enabled)" = true ]; then
      nm=$(nomad_ops_token); srv=$(inventory_group cluster_servers | head -1)
      nport=$(cvar cluster_nomad_http_port); tdir=$(cvar cluster_tls_dir)
      resp=$(printf '%s\n' "$nm" | cluster_exec "$srv" sh -c "read -r t; export NOMAD_TOKEN=\$t NOMAD_ADDR=https://127.0.0.1:$nport NOMAD_CACERT=$tdir/ca.pem
        a=\$(nomad job allocs -json step-ca | jq -r '[.[] | select(.ClientStatus == \"running\")] | sort_by(.CreateTime) | last | .ID // empty')
        [ -n \"\$a\" ] || { echo 'step-ca is not running' >&2; exit 1; }
        nomad alloc exec -i=false -t=false -task step-ca \$a sh -c 'set -e; export STEPPATH=/tmp/step; umask 077
          step ca certificate --force --provisioner clients --provisioner-password-file /secrets/password --ca-url https://127.0.0.1:9000 \\
            --root /secrets/root.pem --kty EC --crv P-256 --not-after $((days * 24))h $dev /tmp/c.pem /tmp/c.key >/dev/null
          cat /tmp/c.pem; echo =====KEY=====; cat /tmp/c.key; rm -rf /tmp/c.pem /tmp/c.key /tmp/step'") \
        || die "step-ca did not issue the certificate (is the job running? task deploy:ansible)"
      printf '%s\n' "${resp%%=====KEY=====*}" > "$out/client.pem"; printf '%s\n' "${resp##*=====KEY=====}" | sed '/^$/d' > "$out/client.key"
      cp "$out/client.pem" "$work/client.crt"; cp pki/ca.pem "$out/ca.pem"
      openssl verify -CAfile pki/ca.pem -untrusted pki/intermediate-stepca.pem "$work/client.crt" >/dev/null || die "the new certificate does not verify"
    else
      openssl ecparam -name prime256v1 -genkey -noout -out "$work/client.key"
      openssl req -new -key "$work/client.key" -subj "/O=$name cluster/CN=$dev" -out "$work/client.csr"
      sops decrypt --extract '["cluster_intermediate_key"]' "$INT_KEY_FILE" > "$work/int.key"
      printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" "extendedKeyUsage=clientAuth" \
        "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid" > "$work/client.ext"
      openssl x509 -req -in "$work/client.csr" -CA "$INT_CERT" -CAkey "$work/int.key" -CAcreateserial -CAserial "$work/int.srl" \
        -days "$days" -sha256 -extfile "$work/client.ext" -out "$work/client.crt" 2>/dev/null
      cat "$work/client.crt" "$INT_CERT" > "$out/client.pem"; cp "$work/client.key" "$out/client.key"; cp pki/ca.pem "$out/ca.pem"
      openssl verify -CAfile pki/ca.pem -untrusted "$INT_CERT" "$work/client.crt" >/dev/null || die "the new certificate does not verify"
    fi
    expires=$(openssl x509 -noout -enddate -in "$work/client.crt" | cut -d= -f2)
    # --- record the device (the preshared key is a secret: it stays in the sops file)
    read_state | DEV="$dev" IP="$ip" PUB="$pub" PSK="$psk" EXP="$expires" python3 -c '
import sys, os, yaml
d = yaml.safe_load(sys.stdin)
peers = [p for p in (d.get("cluster_vpn_peers") or []) if p["name"] != os.environ["DEV"]]
peers.append({"name": os.environ["DEV"], "ip": os.environ["IP"], "public_key": os.environ["PUB"], "psk": os.environ["PSK"], "cert_expires": os.environ["EXP"]})
d["cluster_vpn_peers"] = sorted(peers, key=lambda p: p["name"])
sys.stdout.write("---\n" + yaml.safe_dump(d, default_flow_style=False))' | write_state
    # --- the files of the device
    server_pub=$(read_state | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["cluster_vpn_server_public_key"])')
    iface="wg-$name"
    # a local udp port per cluster (several clusters can be up at once): stable, derived from the name
    lport=$(( 51000 + $(printf '%s' "$name" | cksum | cut -d' ' -f1) % 900 ))
    if [ "$new" = true ]; then
      cat > "$out/$iface.conf" <<EOF
# wg-quick config of the VPN of cluster $name (device $dev). Use: sudo install -m 600 $iface.conf /etc/wireguard/ ; sudo wg-quick up $iface
# wstunnel (the disguise) is started and stopped by the hooks, see wstunnel@.service and wstunnel-$iface.env. No DNS= on purpose: only the zone
# $zone is resolved through the VPN (systemd-resolved), the rest of the client's dns is untouched.
[Interface]
PrivateKey = $priv
Address = $ip/32
MTU = $mtu
PreUp    = systemctl start wstunnel@%i
PostUp   = resolvectl dns %i $server_ip; resolvectl domain %i ~$zone; resolvectl default-route %i false
PostDown = systemctl stop wstunnel@%i

[Peer]
PublicKey = $server_pub
PresharedKey = $psk
Endpoint = 127.0.0.1:$lport
AllowedIPs = $server_ip/32
PersistentKeepalive = 25
EOF
    fi
    cat > "$out/wstunnel@.service" <<'EOF'
# systemd template: wstunnel for one VPN (instance = the wireguard interface, e.g. wg-mycluster). Install: /etc/systemd/system/wstunnel@.service
[Unit]
Description=wstunnel for the VPN %i (wireguard over tcp/443)
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/wstunnel/%i.env
ExecStart=/usr/local/bin/wstunnel client -L 'udp://127.0.0.1:${LOCAL_PORT}:127.0.0.1:${WG_PORT}?timeout_sec=0' --tls-certificate ${CERT} --tls-private-key ${KEY} --tls-verify-certificate wss://${SERVER}:443
Restart=on-failure
RestartSec=3
# the certificate and key are root-owned files in /etc/wstunnel
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=true
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
    cat > "$out/wstunnel-$iface.env" <<EOF
# /etc/wstunnel/$iface.env (mode 600). The certificate chain and key are the files next to this one, the CA is the cluster root.
SERVER=$host
LOCAL_PORT=$lport
WG_PORT=$(cvar cluster_vpn_wg_port)
CERT=/etc/wstunnel/$iface.pem
KEY=/etc/wstunnel/$iface.key
# wstunnel verifies the server with the system roots or, with this, the cluster root only (rustls: SSL_CERT_FILE)
SSL_CERT_FILE=/etc/wstunnel/$iface-ca.pem
EOF
    cat > "$out/install.sh" <<EOF
#!/bin/sh
# Installs the files of device $dev on THIS machine (needs root, wireguard-tools, systemd, a wstunnel binary in /usr/local/bin): sudo sh install.sh
set -eu
cd "\$(dirname "\$0")"
command -v wstunnel >/dev/null || [ -x /usr/local/bin/wstunnel ] || { echo "install wstunnel (https://github.com/erebe/wstunnel/releases) to /usr/local/bin first" >&2; exit 1; }
install -d -m 700 /etc/wstunnel
install -m 600 client.pem /etc/wstunnel/$iface.pem
install -m 600 client.key /etc/wstunnel/$iface.key
install -m 644 ca.pem /etc/wstunnel/$iface-ca.pem
install -m 600 wstunnel-$iface.env /etc/wstunnel/$iface.env
install -m 644 wstunnel@.service /etc/systemd/system/wstunnel@.service
systemctl daemon-reload
if [ -e $iface.conf ]; then install -m 600 $iface.conf /etc/wireguard/$iface.conf; fi
echo "up: wg-quick up $iface    down: wg-quick down $iface"
echo "NetworkManager (GNOME Quick Settings toggle): sh nm-install.sh"
EOF
    cat > "$out/nm-install.sh" <<EOF
#!/bin/sh
# NetworkManager variant (gives the VPN toggle in the GNOME Quick Settings): sudo sh nm-install.sh  (after install.sh)
# NM ignores wg-quick's PreUp / PostUp, so a dispatcher script starts and stops wstunnel, and dns is set per connection.
set -eu
cd "\$(dirname "\$0")"
nmcli connection import type wireguard file /etc/wireguard/$iface.conf
nmcli connection modify $iface ipv4.dns $server_ip ipv4.dns-search '~$zone' ipv4.never-default yes ipv6.method disabled
install -d /etc/NetworkManager/dispatcher.d/pre-up.d /etc/NetworkManager/dispatcher.d/pre-down.d
cat > /etc/NetworkManager/dispatcher.d/pre-up.d/50-wstunnel-$iface <<'HOOK'
#!/bin/sh
[ "\$CONNECTION_ID" = "$iface" ] && systemctl start wstunnel@$iface
exit 0
HOOK
cat > /etc/NetworkManager/dispatcher.d/pre-down.d/50-wstunnel-$iface <<'HOOK'
#!/bin/sh
[ "\$CONNECTION_ID" = "$iface" ] && systemctl stop wstunnel@$iface
exit 0
HOOK
chmod 755 /etc/NetworkManager/dispatcher.d/pre-up.d/50-wstunnel-$iface /etc/NetworkManager/dispatcher.d/pre-down.d/50-wstunnel-$iface
echo "connection $iface imported: nmcli connection up $iface"
EOF
    # --- start / teardown without installing anything (CI): a wg config without hooks and dns, the two scripts, their parameters
    [ "${#iface}" -le 15 ] || die "the interface name $iface is longer than 15 characters: shorten cluster_name"
    mkdir -p "$out/ci"; chmod 700 "$out/ci"
    if [ "$new" = true ]; then
      cat > "$out/ci/$iface.conf" <<EOF
# wg-quick config for connect.sh (CI): no hooks (connect.sh starts wstunnel itself) and no DNS (it writes the API names to /etc/hosts).
[Interface]
PrivateKey = $priv
Address = $ip/32
MTU = $mtu

[Peer]
PublicKey = $server_pub
PresharedKey = $psk
Endpoint = 127.0.0.1:$lport
AllowedIPs = $server_ip/32
PersistentKeepalive = 25
EOF
    fi
    wst_image=$(cvar cluster_wstunnel_image)
    cat > "$out/connect.env" <<EOF
# parameters of connect.sh / disconnect.sh (device $dev)
CLUSTER=$name
ZONE=$zone
IFACE=$iface
SERVER_IP=$server_ip
WSTUNNEL_SERVER=$host
LOCAL_PORT=$lport
WG_PORT=$(cvar cluster_vpn_wg_port)
WSTUNNEL_IMAGE=$wst_image
WSTUNNEL_VERSION=${wst_image##*:}
HOSTS="nomad-api.$zone consul-api.$zone"
EOF
    cp "$(dirname "$0")/vpn-client/connect.sh" "$(dirname "$0")/vpn-client/disconnect.sh" "$out/"
    find "$out" -type f -exec chmod 600 {} +; chmod 700 "$out" "$out/ci"; chmod 755 "$out/install.sh" "$out/nm-install.sh" "$out/connect.sh" "$out/disconnect.sh"
    if [ "$new" = true ]; then echo "device $dev: address $ip, files in $out/ (private keys inside: keep them off shared disks)"; else echo "device $dev: certificate renewed, files in $out/ (the wireguard config of the device stays as it is)"; fi
    echo "certificate valid until $expires"
    echo "next: task deploy:ansible (the server learns the peer), then on the device: sudo sh install.sh  (CI: bash connect.sh ... bash disconnect.sh, no install)"
    ;;

  revoke)
    dev=${2:?device name}; valid_name "$dev"; need_file
    peers_json | jq -e --arg d "$dev" 'any(.[]; .name == $d)' >/dev/null || die "no device $dev"
    read_state | DEV="$dev" python3 -c '
import sys, os, yaml
d = yaml.safe_load(sys.stdin)
d["cluster_vpn_peers"] = [p for p in (d.get("cluster_vpn_peers") or []) if p["name"] != os.environ["DEV"]]
sys.stdout.write("---\n" + yaml.safe_dump(d, default_flow_style=False))' | write_state
    rm -rf "secrets/vpn/$dev"
    echo "device $dev removed; task deploy:ansible takes the peer off the server"
    ;;

  list)
    need_file
    pfirst=$(cvar cluster_vpn_project_first)
    peers_json | jq -r --argjson pf "$pfirst" '.[] | [.name, .ip, (if ((.ip | split(".") | last | tonumber) >= $pf) then "project" else "people" end), .cert_expires] | @tsv' | { column -t -s "$(printf '\t')" 2>/dev/null || cat; }
    ;;

  check)
    [ -e "$FILE" ] || exit 0
    warn=$(cvar cluster_vpn_client_warn_days); now=$(date +%s)
    peers_json | jq -r '.[] | [.name, .cert_expires] | @tsv' | while IFS=$'\t' read -r n e; do
      end=$(date -u -D '%b %e %H:%M:%S %Y' -d "${e% GMT}" +%s 2>/dev/null) || continue
      left=$(( (end - now) / 86400 ))
      if [ "$left" -lt 0 ]; then echo "client cert for $n EXPIRED $(( -left )) days ago: task vpn:client -- $n"
      elif [ "$left" -le "$warn" ]; then echo "client cert for $n expires in $left days: task vpn:client -- $n"; fi
    done
    ;;

  *) echo "usage: $0 init | client <device> [--project] | revoke <device> | list | check" >&2; exit 2 ;;
esac
