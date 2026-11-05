#!/bin/sh
gw=$(ip route show default | awk '/^default/ {print $3; exit}')
for c in {{ env "WG_BYPASS" }} {{ env "NOMAD_HOST_IP_https" }}/32 $(awk '/^nameserver/ {print $2 "/32"}' /etc/resolv.conf); do
  ip route replace "$c" via "$gw" || exit 1
done
ip route show
{{- if ne (env "TPL_METRICS_PORT") "0" }}
# the metrics port is for the cluster: nothing that arrives through the tunnel may reach it.
# One transaction that replaces the table: a restart of this script never stacks rules.
nft -f - <<'NFT'
table inet guard
delete table inet guard
table inet guard {
  chain input {
    type filter hook input priority 0; policy accept;
    iifname "wg0" tcp dport {{ env "TPL_METRICS_PORT" }} drop
  }
}
NFT
{{- end }}
