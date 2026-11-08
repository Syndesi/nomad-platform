#!/usr/bin/env bash
# Undoes connect.sh: wireguard down, wstunnel stopped, the /etc/hosts lines removed, and the secrets of the run deleted (the key files next to
# this script, the tokens, the state directory). Safe to run twice and when connect.sh failed half way: put it in an `if: always()` step.
#   bash disconnect.sh               everything, secrets included
#   bash disconnect.sh --keep-files    leave the files next to this script (a device you use again; connect.sh calls it like this when it fails)
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091
. "$here/connect.env"
# a tmpfs the user keeps while logged in; not /dev/shm first: logind (RemoveIPC) deletes a user's files there when the last session ends
state=${CONNECT_DIR:-${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-/dev/shm}}/cluster-vpn-$CLUSTER}
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
keep=""; [ "${1:-}" = "--keep-files" ] && keep=1

$SUDO wg-quick down "$IFACE" >/dev/null 2>&1 || true
$SUDO rm -f "/etc/wireguard/$IFACE.conf"
if [ -s "$state/wstunnel.pid" ]; then kill "$(cat "$state/wstunnel.pid")" 2>/dev/null || true; fi
if command -v docker >/dev/null; then $SUDO docker rm -f "wstunnel-$IFACE" >/dev/null 2>&1 || true; fi
if grep -q "# cluster-vpn-$CLUSTER\$" /etc/hosts 2>/dev/null; then
  grep -v "# cluster-vpn-$CLUSTER\$" /etc/hosts > "$state.hosts" 2>/dev/null && $SUDO tee /etc/hosts < "$state.hosts" >/dev/null; rm -f "$state.hosts"
fi
rm -rf "$state"
if [ -z "$keep" ]; then
  for f in client.key client.pem nomad.token consul.token "ci/$IFACE.conf"; do
    [ -e "$here/$f" ] && { shred -u "$here/$f" 2>/dev/null || rm -f "$here/$f"; }
  done
fi
echo "disconnect: down${keep:+ (files kept)}"
exit 0
