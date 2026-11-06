# Changelog

Notable changes per version. Older history is in git.

## 0.3.0 (unreleased)

- Traefik: the router, the forward-auth middleware and the service of Authelia are in the file provider (`authelia@file`); Authelia's service has no
  traefik tags any more. A job's tags can no longer redefine the middleware (which took the whole ingress down). The admin routers send HSTS and the
  usual browser headers. New job variable `authelia_addr` (set by the deploy).
- Consul: the bootstrap token (`initial_management`) is no longer in the server configs after the deploy. tofu-consul mints an ops token
  (`global-management`) that tofu, `task backup`, `task smoke` and `task restore` use; the deploy deletes the bootstrap token from the cluster.
  Existing clusters are migrated by the next `task deploy:ansible`. New: role `consul` tasks `token` / `handover`, `cluster_consul_ops_token`.
- Authelia sessions: 18h inactivity, 24h lifetime (were 7 days).
- Docker: container logs rotate (7 files of 50 MB, `cluster_docker_log_*`), `no-new-privileges` is the daemon default.
- Nomad ACL: the deployer policy can neither read nor change `nomad/jobs/authelia` and `nomad/jobs/traefik` (secrets); only tofu-nomad writes them.
- Backup: Authelia's sqlite is saved as an SQL dump by `sqlite3` in a throwaway container (`cluster_sqlite_image`, default `keinos/sqlite3:3.54.1`; nothing is installed on the nodes), not as a tar of the live files. `task restore` reads both.
- Containers have no internet access by default: the firewall rejects new connections from the container bridges to anything outside the
  cluster and the container networks, and containers are given a restricted resolver (docker0): `*.consul` and the node's own names only, no
  public dns. A job that needs the internet uses `network { mode = "cni/egress" }` (a second bridge, `br-egress`; Connect sidecars work there too),
  whose containers get the full resolver. Traefik behind WireGuard uses it; jobs with `mode = "host"` are not restricted. New: `cluster_egress_*`,
  `cluster_nomad_bridge_subnet`, `cluster_docker_bridge_subnet`, `cluster_firewall_container_destinations`; Ubuntu nodes need `dnsmasq-base`. `task smoke` deploys a test container of each kind (`tests/network.nomad.hcl`) on every client and checks dns, internet and IPv6.
- Alpine: dhcpcd leaves the container interfaces (`veth*`, `docker*`, `br-*`, `nomad*`) alone.
- Authelia runs on the first ingress node (next to traefik) by default instead of on every server; `cluster_authelia_hosts` changes it. The deploy fails if it is empty or not a client.
- Firewall: the forward chain drops all published (nat'ed) job ports for sources outside the cluster, except 80/443 on ingress nodes.
  Authelia's port 9091 was reachable from anywhere that could route to the node.
- Firewall: containers on the bridges reach only dns and the Nomad and Consul api on the host instead of every port. Consul's https api
  now also listens on the cluster address of every node (was: loopback, and the ingress node with traefik behind wireguard); `cluster_firewall_bridge_tcp_ports` / `_udp_ports` add more.
- Firewall: new connections routed straight to a container's ip (no nat) are dropped unless they come from the cluster or a bridge;
  a host on the same layer-2 segment could reach bridge-mode allocations (nomad's bridge has no protection of its own).
- Traefik: authelia is the default middleware of the `websecure` entry point; a job that forgets it is no longer public, and a domain
  without an access rule is denied. A public job needs an access rule with `policy: bypass` (now accepted). The platform adds the bypass
  for `auth.<domain>` itself.
- Traefik: the ops names (`nomad.`, `consul.`, `traefik.`, `auth.`) accept only the hybrid post-quantum key exchange (X25519MLKEM768); a client without it
  cannot open them. The separate `*-cli` names are gone: `task proxy:up` uses the normal names. Apps keep the TLS 1.3 default.
- Deploy: with `cluster_interface` unset, the interface of the default route is only accepted if its address is private (RFC 1918 or
  CGNAT); a public address stops the deploy (the firewall would trust the provider's whole subnet). Set `cluster_interface` to decide.
- Certificates: the controller checks every CSR before signing it and refuses anything but the node's exact names, key usage and subject
  (no `CA:TRUE`, no other extension). A compromised client could ask for a server's or the ingress' names.
- Authelia is https now: forward-auth between traefik and authelia (session cookies, the login api) is encrypted. Authelia serves a
  certificate of its own (`tls-authelia/` on the node, names: node, cluster address), mounted read-only; traefik verifies it with the
  cluster CA, the `authelia` router talks https to it, and the health check is https.
- The ingress wildcard key stays on the ingress node (`/etc/cluster/tls-ingress`, a read-only host volume `ingress-tls` of the traefik job):
  it is no longer copied into a Nomad variable (Raft, snapshots, deployer token); the old variable is purged by the next deploy.
  Authelia and traefik read their certificates at start, so a renewed one restarts the job (a fingerprint job variable `tls_fingerprint`).
- Tools container: `/etc/passwd` is no longer world-writable in the image; compose mounts a read-only one with the host user's entry.
- Consul runs as the unprivileged user `consul` (`cluster_consul_user`) with its own key and certificate (`consul.key` / `consul.pem`,
  only consul's names); `node.key` stays root-only and carries the Nomad names. Existing nodes migrate on the next deploy (the data
  directory is chowned, consul restarts once, a new certificate is issued).
- Firewall: sshd is not reachable from the container bridges.
- DNS: `host.internal`, `nomad.host.internal` and `consul.host.internal` resolve to the node itself, on every node (`cluster_host_names`),
  also inside containers and mesh services; they are names in the node certificate (it is re-issued once).
- `authelia-user.sh` validates the user name before it is used in a command, and authelia asks for the password itself on a terminal
  (`docker run -t`) instead of getting it as `--password`; `gum` is no longer used there.
- The TOTP seeds are registered with `authelia storage user totp import` on stdin (was: `--secret <seed>` on the command line of
  `nomad alloc exec`); the `totp-<user>.txt` files now hold just the otpauth URI.
- Authelia: forward-auth sends only the cookie, `Accept`, `X-Requested-With` and the `X-Forwarded-*` headers to authelia (no more `X-Nomad-Token` / `X-Consul-Token`);
  configuration and users are rendered to `secrets/` (0600) instead of `local/`.
