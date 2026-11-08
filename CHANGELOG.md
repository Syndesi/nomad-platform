# Changelog

Notable changes per version. Older history is in git.

## 0.3.0 (unreleased)

- **OpenID Connect for your own apps**: both authelias can be the provider (`authelia_oidc_clients` public, `authelia_internal_oidc_clients` behind the VPN;
  client options `require_pkce`, `token_auth_method`). An app with a client gets a Consul mesh sidecar to `auth.<domain>` / `auth.<zone>` on port 443 (`mesh_service`;
  intentions by tofu-consul, the name resolves to the allocation's loopback via the node's restricted dnsmasq, the certificates carry the names), so the token
  and userinfo calls need neither `extra_hosts` nor skipped verification. Grafana now verifies the certificate. `cluster_internal_apps` adds internal routers.
  New secrets `cluster_authelia_oidc_hmac_secret` / `cluster_authelia_oidc_jwks_key` (`task secrets:ensure`).
- **Projects** (`cluster_projects`, `docs/projects.md`): scoped access for CI and third party apps. Each project gets a Nomad namespace, a policy limited to it
  and a token (tofu-nomad, output `project_tokens`), optionally a Consul token (`consul_rules`, tofu-consul), and a VPN device. The global tokens are unchanged.
  New: `task projects`, `task project:vpn|token|export|rotate|revoke`, `scripts/project.sh`. `project:export` writes a tar, age encrypted to a recipient
  (or `--plain` base64 for a CI secret store) with the tokens, the VPN files and `connect.sh` / `disconnect.sh`.
- **`nomad-api.<zone>` and `consul-api.<zone>`** on the VPN entry point: the same backends as `nomad.` / `consul.`, token only (no second factor), for every
  VPN device (`api-net`; the ops names accept people's half only, `admin-net`; people's half `.2` - `.127`, projects' `.128` and up, `cluster_vpn_project_first`). authelia-internal rules
  can now have `networks`. `task vpn:client` makes devices in the people's half (`.2` - `.127`, was `.2` - `.254`: existing devices keep their addresses).
- **Traefik is not root again** (`cluster_traefik_uid` 65532; it was 0 since the namespace change): the namespace did not get the host's
  `ip_unprivileged_port_start`, so the task `vpn` sets it (80) in the shared namespace, and the host-wide setting of older versions is removed
  (`/etc/sysctl.d/90-cluster-ingress.conf`; the value stays until a reboot). The data volume and the ingress key change owner with the next deploy.
- **No calls home:** Nomad and Consul `disable_update_check` + `disable_anonymous_signature`, Traefik `checkNewVersion: false` / `sendAnonymousUsage: false`.
- **Docker `live-restore`** in `/etc/docker/daemon.json`: a Docker update no longer restarts the containers (limits in `docs/reference.md`).
- **Docker settings:** `default-cgroupns-mode: private`, `userland-proxy: false`, `default-ulimits` nofile 1048576 (`cluster_docker_nofile`). Nomad's
  `allow_caps` is set on every client now (before: only where extra capabilities were configured) and lacks `mknod`, `audit_write` and `setfcap`; privileged mode and
  `pid_mode = "host"` stay refused, runtimes are not restricted (nvidia works).
- **Tetragon** (role `tetragon`, `docs/reference.md` "Runtime security"): eBPF runtime security on every node, from the pinned static release (same files on Alpine and
  Ubuntu). Json event log, Prometheus metrics on the node's cluster address (port 2112, firewall: cluster subnets), shipped policy presets
  (`cluster_tetragon_presets`: `network-connect`, `block-metadata-service` which enforces); quiet filters on by default (`cluster_tetragon_quiet_runtime|quiet_deploys|slim_events`: container plumbing, the ansible user's deploys except sudo, capability/namespace fields), no `binary` metric label and the cluster repo's `tetragon.d/*.yaml`. Off with `cluster_tetragon_enabled: false`.
- **Hardening:** the docker socket of the monitoring agent is behind a filtering proxy (task `docker-proxy`, GET of containers / events only; vector has no socket);
  the monitoring server's tasks run with `cap_drop ALL` and a read-only root filesystem; `block-metadata-service` also blocks `fd00:ec2::254` (IPv6); the Consul
  token of the Nomad agents has `intentions = "read"` (a leaked token could not allow itself into a service). Apply with `task deploy:tofu` / `deploy:ansible`.
- **Monitoring** (`docs/monitoring.md`, `cluster_monitoring_enabled`, on by default): Vector on every client (docker logs, Tetragon events, cluster events polled from Nomad and
  Consul, metrics of Nomad / Consul / Tetragon and of every Consul service tagged `metrics`), and on one node (`cluster_monitoring_node`) Loki, Prometheus
  (remote write sink), Alertmanager, Grafana with its own PostgreSQL, Gatus (status page, replaces uptime kuma) in one allocation, plus ntfy (`ntfy.<domain>`, public) as the
  notification target. Internal only: `grafana.<zone>` and `status.<zone>` behind the VPN; Loki and Prometheus only through the mesh (intentions). No dashboards.
  Retention: node logs `cluster_log_retention_days` (7), Loki / Prometheus `cluster_monitoring_retention_days` (45). New secrets: `task secrets:ensure`. Grafana's database is in `task backup`.
  The system logs of the nodes (`/var/log`: Nomad, Consul, Docker, sshd, syslog) are shipped too. Grafana logs in with authelia-internal (OpenID Connect):
  authelia-internal becomes a mesh service (bridge network, Connect sidecar, same published port) and Grafana reaches it as `auth.<zone>:443` inside its own allocation.
  Nomad now publishes allocation metrics (`nomad_publish_workload_metrics`, readable without a token by any container).
- **Fix: secrets in containers on systemd nodes.** Nomad's unit had `ProtectKernelModules`, `ProtectKernelLogs` and `ProtectClock`: they put the service in a private mount
  namespace, so the tmpfs of every task's `secrets/` directory was invisible to Docker (empty `/secrets`: templates in `secrets/`, the Envoy bootstrap of Connect sidecars). Removed.
- The tofu stages share one ssh connection to the node (ControlMaster) and apply four objects at a time (`tofu_stage_parallelism`): a state with many objects ran into
  the nodes' ssh rate limit (EOF from the APIs). `block-metadata-service` is on by default.
- Tools image: `util-linux-misc` (`column`), used by `task projects` and `task vpn:list`.
- `scripts/vpn.sh client` also writes `connect.sh` / `disconnect.sh` (VPN up and down without installing: wstunnel + wireguard + /etc/hosts, for CI runners).
- Docs: `task tokens` lists accessor ids (the reference said it printed the tokens).

- **Internal services behind a VPN** (zone `<cluster_name>.internal`, `cluster_internal_zone`): `auth.`, `nomad.`, `consul.`, `traefik.` are no longer on the
  public `websecure` entry point (their routers moved to Traefik's file provider on a new entry point `vpn`, bound to the WireGuard address inside the
  allocation; `websecure.asDefault: true`). New in Traefik's allocation: a WireGuard server (`wg1`, MTU 1280, preshared key per peer, nft guard: only
  tcp/443 and 53 reach it), wstunnel (disguise over tcp/443, TCP router with TLS passthrough, mTLS, `--restrict-to 127.0.0.1:51820`) and a dnsmasq for
  the zone. Traefik always runs in its own namespace now (`cni/egress`, `ip_forward=0`; not root, see below). New: `task vpn:init|client|revoke|list`,
  `scripts/vpn.sh`, `cluster_vpn_*`; client files (wg-quick, systemd and NetworkManager variants) in `secrets/vpn/<device>/`. `task proxy:*`
  goes through the VPN. `cluster_wireguard_image`, `cluster_wstunnel_image`, `cluster_dnsmasq_image` are pinned by version tag.
- **Second Authelia (`authelia-internal`)**, job `authelia` run twice (`cluster_jobs_authelia_instances`): own cookie domain, secrets
  (`cluster_authelia_internal_*`, `task secrets:ensure` adds them to an existing file), sqlite and host volume (`/srv/authelia-internal`), TOTP seeds
  (`authelia_internal_totp_seeds`, always separate), bans, port 9092, access rules `authelia_internal_access_rules`. Backup, restore, `authelia_totp` and
  `authelia-users.sh` handle both. `authelia_access_rules` now only holds the rules of public apps (the ops rules moved).
- **PKI: offline root plus two intermediates**, all name-constrained (the zone is permitted): `ansible` (the controller: agent, node, ingress certificates)
  and `step-ca`. New `task pki:ca` (a new CA: full redeploy), `task pki:intermediate -- ansible|stepca`; leaf certificates carry the chain, peers trust
  only the root. The root key is not read by any deploy.
- **step-ca** (job `step-ca`, `cluster_stepca_*`, `task stepca:init`): reachable only through the Consul mesh (default-deny intentions, only
  `traefik-acme`), Traefik's resolver `stepca` issues the certificates of the internal names (tls-alpn-01, 7 days), wstunnel's certificate is issued by the
  deploy and renewed by a sidecar, device certificates (1 year) come from `task vpn:client` via `nomad alloc exec`. In the backup (`step-ca-db.tar.age`).
- Consul's gRPC listener has its own certificate without IP addresses (`consul-grpc`): Envoy (BoringSSL) rejects chains with IP name constraints and an
  IP in the leaf, which broke every Connect sidecar with the name-constrained CA.
- Firewall fixes found with the VPN: the forward rule `ct status != dnat drop` matched every DNAT'ed connection (a flag set compared as a value), so no
  new connection from outside reached a published port of a CNI network; it is now `ct status & dnat == 0`. Docker's own FORWARD chain (policy drop)
  does not know the network `egress`: the public ports are accepted in `DOCKER-USER` (`docker-forward.sh`).
- `task smoke` checks the new layout (ops names not published, internal jobs, VPN gate, step-ca certificates, client certificate expiry); `task secrets:ensure`.
- Images: Authelia in the default image is 4.39.28 or newer where the internal cookie domain `<cluster_name>.internal` is needed.
- Automatic updates (role `cluster_updates`): every 12 hours (`cluster_updates_interval_hours`), never a reboot. Ubuntu: `unattended-upgrades` with the security pockets only; Alpine: a cron job with `apk upgrade`. `cluster_updates_enabled: false` turns it off.
- Nomad: the bootstrap token is handed over like consul's. tofu-nomad mints an ops token (`management`), the deploy deletes the bootstrap token from the cluster; tofu, `task backup`, `task smoke` and the TOTP registration use the ops token (`cluster_nomad_ops_token`, `nomad_ops_token` in `scripts/lib.sh`). Existing clusters are migrated by the next `task deploy:ansible`. New: role `nomad_acl` tasks `token` / `handover`.
- Authelia is hardened like traefik: it runs as `cluster_authelia_uid` (8000, was root), all capabilities dropped, read-only root filesystem (small tmpfs on /tmp). Its folder and key belong to that user (changed in place on the next deploy). The health check verifies the certificate (no `tls_skip_verify`).
- `site.yml` stops early when `cluster_servers` does not have exactly one node (the platform is built for a single server).
- Alpine: consul is hardened under OpenRC as far as `supervise-daemon` allows: no new privileges, empty capability bounding set, umask 077, no core dumps (new `hashi_agent_openrc_*` settings). Mount namespaces and a read-only filesystem do not exist there.

- Traefik: the router, the forward-auth middleware and the service of Authelia are in the file provider (`authelia@file`); Authelia's service has no
  traefik tags any more. A job's tags can no longer redefine the middleware (which took the whole ingress down). The admin routers send HSTS and the
  usual browser headers. New job variable `authelia_addr` (set by the deploy).
- Consul: the bootstrap token (`initial_management`) is no longer in the server configs after the deploy. tofu-consul mints an ops token
  (`global-management`) that tofu, `task backup`, `task smoke` and `task restore` use; the deploy deletes the bootstrap token from the cluster.
  Existing clusters are migrated by the next `task deploy:ansible`. New: role `consul` tasks `token` / `handover`, `cluster_consul_ops_token`.
- Authelia sessions: 18h inactivity, 24h lifetime, "remember me" off (`authelia_session_remember_me: -1`; were 7 days).
- The cluster CA is name-constrained (critical `nameConstraints`: `cluster_domain`, `cluster_node_domain`, `.consul`, `.nomad`, `host.internal`, `localhost`, loopback + private IPv4 ranges; `cluster_ca_permitted_*`). Existing CAs are not changed: to get the constraint make a new CA (`pki/ca.pem` and `ca.sops.yml` deleted, `task pki:ca`) and redeploy; the nodes' short hostnames are no longer certificate names (the FQDN is).
- Traefik no longer runs as root with the default capabilities: user `cluster_traefik_uid` (65532; root with wireguard), all capabilities dropped (`NET_BIND_SERVICE` only), read-only root filesystem. The ingress node sets `net.ipv4.ip_unprivileged_port_start=80`; its data volume and the ingress key belong to that user.
- systemd units: consul gets a sandbox (no privileges or capabilities, read-only filesystem except its data directory, private /tmp and /dev, kernel protections), nomad a subset (`NoNewPrivileges`, kernel modules / logs / clock, realtime, personality).
- Nomad clients deny the task drivers exec, java and qemu as well as mock_driver (`nomad_driver_denylist`): they run on the host network, outside the container firewall.
- Traefik: rate limit on the Authelia portal (`auth.`) per source address, stricter on the login endpoints (10 per minute, burst 5), because Authelia only counts failures per username.
- `cluster_ingress` must have exactly one node (checked by site.yml): traefik is a single instance and DNS points at one node. `cluster_authelia_hosts` defaults to that node.
- Nomad: `/v1/metrics` needs no token and every container reaches the api port, so allocation and node metrics are no longer published (`nomad_publish_workload_metrics`, default false).
- Firewall: the forward chain has policy drop, accepts established / related traffic first and ends in an explicit drop (no reliance on docker's FORWARD chain). The ssh rate limit of IPv6 sources counts per /64.
- Authelia templates: every interpolated value is `to_json` (a `'` in a display name no longer breaks the YAML).
- Jobs (`cluster_jobs`) are run with the deployer token from tofu-nomad (`cluster_jobs_token`), not the management token (bootstrap, tofu-nomad, backup, restore, TOTP).
- Firewall: new ssh connections are rate limited per source address (`cluster_firewall_ssh_rate`, default 10/minute, burst 10, `''` = off); the cluster's subnets are exempt.
- tofu: the clear text variables file (tokens, secrets) is deleted from tmpfs right after each apply.
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
