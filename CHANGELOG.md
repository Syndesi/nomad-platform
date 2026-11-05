# Changelog

The history of the earlier experiments (v0.1.0 - v0.3.0 and what followed) is not carried over: this is the current state, version 0.1.0.
Entries start with the next change.

## Unreleased

- Firewall: the forward chain drops all published (nat'ed) job ports for sources outside the cluster, except 80/443 on ingress nodes.
  Authelia's port 9091 was reachable from anywhere that could route to the node.
- Firewall: containers on the bridges reach only dns and the Nomad and Consul api on the host instead of every port. Consul's https api
  now also listens on the cluster address of every node (was: loopback, and the ingress node with traefik behind wireguard); `cluster_firewall_bridge_tcp_ports` / `_udp_ports` add more.
- Firewall: sshd is not reachable from the container bridges.
- DNS: `host.internal`, `nomad.host.internal` and `consul.host.internal` resolve to the node itself, on every node (`cluster_host_names`),
  also inside containers and mesh services; they are names in the node certificate (it is re-issued once).
- `authelia-user.sh` validates the user name before it is used in a command.
- Authelia: forward-auth sends only the cookie, `Accept`, `X-Requested-With` and the `X-Forwarded-*` headers to authelia (no more `X-Nomad-Token` / `X-Consul-Token`);
  configuration and users are rendered to `secrets/` (0600) instead of `local/`.
