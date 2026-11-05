#!/bin/sh
# healthy = wg0 exists and its newest handshake is younger than {{ env "WG_MAX_HANDSHAKE_AGE" }}s (needs PersistentKeepalive in the peer: without
# traffic there is no handshake, see wireguard-conf.sh)
hs=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2; exit}')
[ -n "$hs" ] && [ "$hs" -gt 0 ] || { echo "no handshake yet"; exit 1; }
age=$(( $(date +%s) - hs ))
[ "$age" -lt {{ env "WG_MAX_HANDSHAKE_AGE" }} ] || { echo "last handshake $age s ago"; exit 1; }
echo "last handshake $age s ago"
