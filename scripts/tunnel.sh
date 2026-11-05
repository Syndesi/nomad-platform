#!/usr/bin/env bash
# Local tcp tunnel so the tools container can reach an api that only the node can reach.
# The incus bridge is not routable from here, and consul's https api listens on 127.0.0.1 of
# the node anyway. socat accepts connections on 127.0.0.1:<local> and runs <command> for each of
# them, with the connection on its stdin/stdout - e.g. `incus exec remote:vm -- nc 127.0.0.1 8501`.
# For a real host the same works with `ssh ansible@node nc 127.0.0.1 8501`.
#   tunnel.sh up <local port> '<command>'    start (no-op if it already listens)
#   tunnel.sh down <local port>
set -euo pipefail
action=${1:?up|down} port=${2:?local port}
pidfile=/tmp/tunnel-$port.pid

alive() { [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }

case $action in
  up)
    cmd=${3:?command}
    if alive; then exit 0; fi
    # socat splits address options at ':' - escape the colons of the command (incus remote:instance)
    setsid socat "TCP-LISTEN:$port,bind=127.0.0.1,reuseaddr,fork" "EXEC:${cmd//:/\\:}" </dev/null >"/tmp/tunnel-$port.log" 2>&1 &
    echo $! > "$pidfile"
    for _ in $(seq 50); do
      (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && exit 0
      sleep 0.1
    done
    echo "tunnel on $port did not come up, see /tmp/tunnel-$port.log" >&2
    exit 1
    ;;
  down)
    if alive; then kill "$(cat "$pidfile")" 2>/dev/null || true; fi
    rm -f "$pidfile"
    ;;
  *) echo "usage: $0 up <port> <command> | down <port>" >&2; exit 2 ;;
esac
