#!/usr/bin/env bash
# The local proxy for command line tools that cannot do a web login (nomad, consul): a Caddy on 127.0.0.1 that sends their requests to
# traefik's internal names (zone <cluster_name>.internal, through the VPN: the VPN must be up, `wg-quick up wg-<cluster>`) with the authelia-internal session cookie you got by logging in (password + TOTP, asked with gum). On the HOST, in the cluster
# repo, via `task proxy:up|login|down|status|env`. State (Caddyfile, session cookie) lives in .proxy/ (git-ignored).
#   proxy.sh up      render the config, start caddy
#   proxy.sh login   ask for user, password and the TOTP code, log in through the proxy, give caddy the session, check it
#   proxy.sh down    stop caddy and forget the session
#   proxy.sh status  is caddy up, does the session work
#   proxy.sh env     the environment for the cli tools (eval "$(task proxy:env)")
# The uplink to traefik is TLS 1.3 with the hybrid post-quantum key exchange X25519MLKEM768 and nothing else (tls_curves; traefik's pq-only
# option pq-only accepts nothing else either): there is no downgrade in either direction.
# Environment (all optional): PROXY_DOMAIN (default cluster_internal_zone), PROXY_UPSTREAM (host:port to connect to instead of the names; default
# <VPN server address>:443, the names stay in SNI and Host), PROXY_CA_FILE (CA of traefik's certificates; default the cluster root, which signs the
# internal certificates), PROXY_NOMAD_PORT=4646, PROXY_CONSUL_PORT=8500, PROXY_AUTH_PORT=9091, PROXY_IMAGE.
# Non-interactive login (tests): PROXY_USER, PROXY_PASSWORD, PROXY_TOTP.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "${CLUSTER_DIR_HOST:-$PWD}"
cd "${CLUSTER_DIR_HOST:-$PWD}"
dir=.proxy
nomad_port=${PROXY_NOMAD_PORT:-4646}
consul_port=${PROXY_CONSUL_PORT:-8500}
auth_port=${PROXY_AUTH_PORT:-9091}
image=${PROXY_IMAGE:-caddy:2.11.7}
die() { echo "proxy: $*" >&2; exit 1; }
tools() { docker compose exec -T tools bash -c ". /work/base/scripts/lib.sh; $1"; }
dc() { docker compose -f "$dir/compose.yml" -p "$(basename "$PWD")-proxy" "$@"; }

domain() { echo "${PROXY_DOMAIN:-$(tools 'cvar cluster_internal_zone')}"; }
upstream() { echo "${PROXY_UPSTREAM:-$(tools 'cvar cluster_vpn_server_ip'):443}"; }

render() {
  local d up up_n up_c up_a ca=""
  d=$(domain); [ -n "$d" ] || die "cannot find cluster_internal_zone (is the tools container up? task up)"
  up=$(upstream)
  mkdir -p "$dir/session"; chmod 700 "$dir" "$dir/session"
  [ -e "$dir/session/authelia_session" ] || { : > "$dir/session/authelia_session"; chmod 600 "$dir/session/authelia_session"; }
  # the internal names always have certificates of the cluster's own CA
  if [ -n "${PROXY_CA_FILE:-}" ]; then cp "$PROXY_CA_FILE" "$dir/ca.pem"; else cp pki/ca.pem "$dir/ca.pem"; fi
  ca=1
  up_n=$up; up_c=$up; up_a=$up
  trust=""; [ -n "$ca" ] && trust="tls_trusted_ca_certs /ca.pem"
  cat > "$dir/Caddyfile" <<CADDY
{
	# the admin api on a socket inside the container only: nothing on the host can reconfigure the proxy
	admin unix//tmp/caddy-admin.sock
	auto_https off
}

# the session cookie is read from the file when the config is (re)loaded: \`proxy.sh login\` writes it and reloads
http://127.0.0.1:$nomad_port {
	bind 127.0.0.1
	reverse_proxy https://$up_n {
		header_up Host nomad.$d
		header_up Cookie "authelia_session={file./session/authelia_session}"
		transport http {
			tls_curves x25519mlkem768
			tls_server_name nomad.$d
			$trust
		}
	}
}

http://127.0.0.1:$consul_port {
	bind 127.0.0.1
	reverse_proxy https://$up_c {
		header_up Host consul.$d
		header_up Cookie "authelia_session={file./session/authelia_session}"
		transport http {
			tls_curves x25519mlkem768
			tls_server_name consul.$d
			$trust
		}
	}
}

# the login only: authelia's portal api, without a cookie from the file
http://127.0.0.1:$auth_port {
	bind 127.0.0.1
	reverse_proxy https://$up_a {
		header_up Host auth.$d
		transport http {
			tls_curves x25519mlkem768
			tls_server_name auth.$d
			$trust
		}
	}
}
CADDY
  cat > "$dir/compose.yml" <<YAML
services:
  caddy:
    image: $image
    network_mode: host
    user: "$(id -u):$(id -g)" # the session file is mode 600 of this user; without CAP_DAC_OVERRIDE root could not read it
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE] # the caddy binary carries this file capability: without it in the bounding set the container cannot exec it
    security_opt: ["no-new-privileges:true"]
    read_only: true
    tmpfs: [/tmp, /data, /config]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./session:/session:ro
      - ./ca.pem:/ca.pem:ro
YAML
}

reload() { dc exec -T caddy caddy reload --config /etc/caddy/Caddyfile --address unix//tmp/caddy-admin.sock >/dev/null 2>&1; }

login() {
  local d user pw code target auth hdr cookie fresh body
  for t in jq curl; do command -v "$t" >/dev/null || die "$t is needed"; done
  d=$(domain); target="https://nomad.$d/"; auth=http://127.0.0.1:$auth_port
  if [ -n "${PROXY_USER:-}" ]; then user=$PROXY_USER; else command -v gum >/dev/null || die "gum is needed (or set PROXY_USER, PROXY_PASSWORD, PROXY_TOTP)"; user=$(gum input --placeholder "user"); fi
  if [ -n "${PROXY_PASSWORD:-}" ]; then pw=$PROXY_PASSWORD; else pw=$(gum input --password --placeholder "password"); fi
  [ -n "$user" ] && [ -n "$pw" ] || die "user and password are needed"
  hdr=$(mktemp); trap 'rm -f "$hdr"' RETURN
  # first factor. The password goes through the environment into jq and through stdin into curl, never into an argument list.
  body=$(U="$user" P="$pw" T="$target" jq -n '{username: env.U, password: env.P, keepMeLoggedIn: false, targetURL: env.T, requestMethod: "GET"}' \
    | curl -sS -D "$hdr" -H 'Content-Type: application/json' -d @- "$auth/api/firstfactor") || die "no answer from the proxy ($auth): task proxy:up"
  unset pw
  [ "$(jq -r .status <<<"$body" 2>/dev/null)" = OK ] || die "first factor refused: $(jq -r '.message // .' <<<"$body" 2>/dev/null | head -c 200)"
  cookie=$(sed -nE 's/^[Ss]et-[Cc]ookie: authelia_session=([^;]+);.*/\1/p' "$hdr" | tail -1)
  [ -n "$cookie" ] || die "authelia sent no session cookie"
  if [ -n "${PROXY_TOTP:-}" ]; then code=$PROXY_TOTP; else code=$(gum input --placeholder "TOTP code" --char-limit 8); fi
  : > "$hdr"
  body=$(C="$code" T="$target" jq -n '{token: env.C, targetURL: env.T}' \
    | curl -sS -D "$hdr" -H 'Content-Type: application/json' -H "Cookie: authelia_session=$cookie" -d @- "$auth/api/secondfactor/totp") || die "no answer from the proxy"
  [ "$(jq -r .status <<<"$body" 2>/dev/null)" = OK ] || die "second factor refused: $(jq -r '.message // .' <<<"$body" 2>/dev/null | head -c 200)"
  # authelia may hand out a new session id once the second factor is in
  fresh=$(sed -nE 's/^[Ss]et-[Cc]ookie: authelia_session=([^;]+);.*/\1/p' "$hdr" | tail -1)
  [ -z "$fresh" ] || cookie=$fresh
  umask 077; printf '%s' "$cookie" > "$dir/session/authelia_session"
  reload || die "caddy did not reload (task proxy:up)"
  status
}

status() {
  local code
  dc ps --status running 2>/dev/null | grep -q caddy || die "caddy is not running (task proxy:up)"
  tools 'CLUSTER_DIR=/work /work/base/scripts/vpn.sh check' 2>/dev/null || true
  # a request through the proxy that needs no nomad token: 200 = logged in, 302/401 = no (valid) session
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$nomad_port/v1/status/leader" || echo 000)
  case "$code" in
    200) echo "proxy: logged in (nomad on http://127.0.0.1:$nomad_port, consul on http://127.0.0.1:$consul_port)";;
    302|401|403) echo "proxy: running, but no valid session: task proxy:login" >&2; return 1;;
    *) echo "proxy: nomad answered $code through the proxy" >&2; return 1;;
  esac
}

case "${1:-}" in
  up) render; dc up -d --force-recreate >/dev/null; echo "proxy up: nomad http://127.0.0.1:$nomad_port, consul http://127.0.0.1:$consul_port; now: task proxy:login";;
  login) login;;
  down) [ -e "$dir/compose.yml" ] && dc down >/dev/null 2>&1 || true; rm -rf "$dir/session"; echo "proxy down, session forgotten";;
  status) status;;
  env) echo "export NOMAD_ADDR=http://127.0.0.1:$nomad_port CONSUL_HTTP_ADDR=http://127.0.0.1:$consul_port";;
  *) echo "usage: $0 up | login | down | status | env" >&2; exit 2;;
esac
