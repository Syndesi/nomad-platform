#!/usr/bin/env bash
# Brings the VPN of a cluster up WITHOUT installing anything: wstunnel (the disguise over tcp/443) in the background, then the wireguard interface,
# then the names nomad-api. / consul-api.<zone> in /etc/hosts. Made for CI runners and scripts; tear down with disconnect.sh (put it in an `always` step).
# Written by scripts/vpn.sh into secrets/vpn/<device>/ (or the bundle of `task project:export`); it reads connect.env and the key files next to it.
#   bash connect.sh          up; prints what it set. On GitHub / Forgejo Actions (GITHUB_ENV is set) the variables below go into the environment of the next steps
#   Needs: root or sudo, wireguard-tools (wg-quick) and the wireguard kernel module, a wstunnel binary OR docker (see WSTUNNEL_BIN), curl for the check.
#   Environment (all optional): WSTUNNEL_BIN (path of a binary), WSTUNNEL_SHA256 (checked when the binary is downloaded), CONNECT_DIR (state dir; default $RUNNER_TEMP, else $XDG_RUNTIME_DIR, else /dev/shm)
# Sets: NOMAD_ADDR, NOMAD_CACERT, CONSUL_HTTP_ADDR, CONSUL_CACERT, and NOMAD_TOKEN / CONSUL_HTTP_TOKEN when nomad.token / consul.token sit next to this file.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091
. "$here/connect.env"
# a tmpfs the user keeps while logged in; not /dev/shm first: logind (RemoveIPC) deletes a user's files there when the last session ends
state=${CONNECT_DIR:-${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-/dev/shm}}/cluster-vpn-$CLUSTER}
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
die() { echo "connect: $*" >&2; exit 1; }
for f in client.pem client.key ca.pem "ci/$IFACE.conf"; do [ -s "$here/$f" ] || die "missing $f next to connect.sh"; done
command -v wg-quick >/dev/null || die "wg-quick not found (apt install wireguard-tools)"
# a second call while it is up: nothing to do
if [ -e "$state/up" ]; then echo "connect: already up ($state)"; exit 0; fi
umask 077; mkdir -p "$state"
# everything below is undone by disconnect.sh; if connect fails half way, undo it here as well
trap 'rc=$?; if [ $rc -ne 0 ]; then echo "connect: failed, undoing" >&2; bash "$here/disconnect.sh" --keep-files || true; fi' EXIT
echo "$here" > "$state/dir"

# ---- wstunnel: a binary on the PATH, WSTUNNEL_BIN, else docker with the pinned image, else the pinned release
wst_args=(client -L "udp://127.0.0.1:$LOCAL_PORT:127.0.0.1:$WG_PORT?timeout_sec=0"
  --tls-certificate "$here/client.pem" --tls-private-key "$here/client.key" --tls-verify-certificate "wss://$WSTUNNEL_SERVER:443")
export SSL_CERT_FILE="$here/ca.pem"   # wstunnel trusts the cluster root for the server's certificate
bin=${WSTUNNEL_BIN:-$(command -v wstunnel || true)}
if [ -z "$bin" ] && ! command -v docker >/dev/null; then
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die "no wstunnel binary for $(uname -m): set WSTUNNEL_BIN" ;; esac
  url="https://github.com/erebe/wstunnel/releases/download/$WSTUNNEL_VERSION/wstunnel_${WSTUNNEL_VERSION#v}_linux_$arch.tar.gz"
  echo "connect: downloading $url"
  curl -fsSL "$url" -o "$state/wstunnel.tgz"
  [ -z "${WSTUNNEL_SHA256:-}" ] || echo "$WSTUNNEL_SHA256  $state/wstunnel.tgz" | sha256sum -c - >/dev/null || die "wstunnel download: checksum differs"
  tar -xzf "$state/wstunnel.tgz" -C "$state" wstunnel && rm -f "$state/wstunnel.tgz"; bin=$state/wstunnel
fi
if [ -n "$bin" ]; then
  nohup "$bin" "${wst_args[@]}" > "$state/wstunnel.log" 2>&1 & echo $! > "$state/wstunnel.pid"
else
  # --network host: the container's 127.0.0.1 is the runner's; --user: the key files are 0600 and owned by the runner's user
  $SUDO docker run -d --rm --name "wstunnel-$IFACE" --network host --user "$(id -u):$(id -g)" -v "$here:/c:ro" -e SSL_CERT_FILE=/c/ca.pem \
    --entrypoint /home/app/wstunnel "$WSTUNNEL_IMAGE" client -L "udp://127.0.0.1:$LOCAL_PORT:127.0.0.1:$WG_PORT?timeout_sec=0" \
    --tls-certificate /c/client.pem --tls-private-key /c/client.key --tls-verify-certificate "wss://$WSTUNNEL_SERVER:443" > "$state/wstunnel.docker"
fi
sleep 2
if [ -e "$state/wstunnel.pid" ] && ! kill -0 "$(cat "$state/wstunnel.pid")" 2>/dev/null; then cat "$state/wstunnel.log" >&2; die "wstunnel exited (certificate expired? $WSTUNNEL_SERVER:443 unreachable?)"; fi

# ---- wireguard: the interface comes up, the route is the server address only (/32). The config goes to /etc/wireguard (root only, removed again by
# disconnect.sh): a confined wg-quick (Ubuntu's apparmor profile) reads nothing from elsewhere
$SUDO install -d -m 700 /etc/wireguard
$SUDO install -m 600 "$here/ci/$IFACE.conf" "/etc/wireguard/$IFACE.conf"
touch "$state/wgconf"
$SUDO wg-quick up "$IFACE" >"$state/wg-quick.log" 2>&1 || { cat "$state/wg-quick.log" >&2; die "wg-quick up failed (wireguard kernel module? NET_ADMIN in the container?)"; }
touch "$state/wg"

# ---- names: no resolver changes, the two API names go to /etc/hosts
for h in $HOSTS; do printf '%s %s # cluster-vpn-%s\n' "$SERVER_IP" "$h" "$CLUSTER" | $SUDO tee -a /etc/hosts >/dev/null; done
touch "$state/hosts"

# ---- the check: the whole way through, wireguard handshake included (status/leader needs no token)
if command -v curl >/dev/null; then
  ok=""
  for _ in $(seq 1 15); do
    if curl -fsS --max-time 3 --cacert "$here/ca.pem" "https://nomad-api.$ZONE/v1/status/leader" >/dev/null 2>"$state/check.err"; then ok=1; break; fi
    sleep 1
  done
  [ -n "$ok" ] || { cat "$state/check.err" >&2; tail -5 "$state/wstunnel.log" 2>/dev/null >&2 || true; die "nomad-api.$ZONE does not answer through the tunnel"; }
fi

# ---- environment
{
  echo "NOMAD_ADDR=https://nomad-api.$ZONE"
  echo "NOMAD_CACERT=$here/ca.pem"
  echo "CONSUL_HTTP_ADDR=https://consul-api.$ZONE"
  echo "CONSUL_CACERT=$here/ca.pem"
} > "$state/env"
if [ -s "$here/nomad.token" ]; then echo "NOMAD_TOKEN=$(tr -d '\n' < "$here/nomad.token")" >> "$state/env"; fi
if [ -s "$here/consul.token" ]; then echo "CONSUL_HTTP_TOKEN=$(tr -d '\n' < "$here/consul.token")" >> "$state/env"; fi
touch "$state/up"
if [ -n "${GITHUB_ENV:-}" ]; then
  # mask the secrets in the log of the run, then hand the variables to the next steps
  while IFS='=' read -r k v; do case $k in *TOKEN) echo "::add-mask::$v" ;; esac; done < "$state/env"
  cat "$state/env" >> "$GITHUB_ENV"
fi
echo "connect: up. NOMAD_ADDR=https://nomad-api.$ZONE   CONSUL_HTTP_ADDR=https://consul-api.$ZONE"
echo "connect: variables in $state/env (source it, or they are in the environment of the next steps); end with: bash $here/disconnect.sh"
trap - EXIT
