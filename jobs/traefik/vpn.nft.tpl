table inet vpnguard
delete table inet vpnguard
table inet vpnguard {
  # the VPN reaches https on its own address: tcp 443 goes to traefik's entry point vpn
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "wg1" tcp dport 443 redirect to :{{ env "TPL_VPN_PORT" }}
  }
  chain input {
    type filter hook input priority 0; policy accept;
    iifname "wg1" ct state established,related accept
    iifname "wg1" tcp dport {{ env "TPL_VPN_PORT" }} accept
    iifname "wg1" udp dport 53 accept
    iifname "wg1" tcp dport 53 accept
    iifname "wg1" icmp type echo-request accept
    iifname "wg1" drop
    # the entry point, wstunnel and wireguard are for the VPN and for loopback, not for the allocation's address on the cluster network
    iifname != "wg1" tcp dport {{ env "TPL_VPN_PORT" }} drop
    iifname != "lo" tcp dport {{ env "TPL_WSTUNNEL_PORT" }} drop
    iifname != "lo" udp dport {{ env "TPL_WG_PORT" }} drop
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
  }
}
