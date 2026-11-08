# Reference

Details behind the [README](../README.md) and the [cluster guide](../cluster-template/README.md). Variables and defaults:
[contract.md](contract.md) and `ansible/inventory/group_vars/all/defaults.yml`.

## Network: where the cluster listens

`cluster_interface` names the interface of the cluster-internal network (default: the interface of the default route, accepted only with a private
address (RFC 1918 or CGNAT), otherwise the deploy stops; set it per node
in `inventory/host_vars/<node>.yml`). Nomad (rpc, serf, http), Consul (rpc, serf) and the Nomad client use the address of that
interface; the local http apis also stay on `127.0.0.1`. Nothing of the agents listens on `0.0.0.0`. The node certificates contain
the address, the firewall opens the cluster ports to the interface's subnet. `task deploy:ansible` stops when the interface is missing.

**The platform does not create the interface.** On a node whose only interface is the public one, the default would put Nomad and
Consul on it and open their ports to the provider's subnet (they still need tokens and TLS). A single VPS therefore gets a dummy
interface with a private address, created by hand once: see the cluster guide. Several nodes need a real private network (provider
VLAN, WireGuard `wg0`, ...) and its interface name.

**Nodes find each other by address.** Consul and Nomad join the servers by their cluster address (`cluster_servers_addrs`, the address of
`cluster_interface`), and the workload identity fetches its keys from it. No DNS record and no hosts entry is needed for node names; the
certificates carry the address as an IP SAN (and `<node>.<cluster_node_domain>` as a name). All nodes must reach each other on these
addresses, so the interface of several nodes must be a real shared network. A changed address needs a redeploy (new certificates).

**Talking to the local Nomad / Consul from a job.** `localhost` inside a container is the container, so every node resolves
`host.internal`, `nomad.host.internal` and `consul.host.internal` (`cluster_host_names`) to its own cluster address, for the host and for
containers on any bridge, mesh services included: `https://consul.host.internal:8501`, `https://nomad.host.internal:4646` (the node certificate
carries these names; tokens and the cluster CA are the job's business). Jobs on the host network can use `localhost`.

**DNS upstream.** Everything that is not `*.consul` goes to the node's default gateway (`cluster_dns_upstreams_override` replaces it).
Providers whose gateway does not answer DNS need the override.

Traefik publishes 80 and 443 on all interfaces (host network). Prometheus metrics (`cluster_traefik_metrics`, port 8082) are served on
the cluster address only, registered as the Consul service `traefik-metrics`.

## Tokens: nothing works without one, except the web ui behind authelia

Nomad and Consul deny everything by default and have no anonymous access. The Nomad web ui behind traefik is the one exception, only
for people who passed Authelia: a request without a Nomad token gets traefik's fallback token (policy `ui`: list and read jobs, read
nodes), a request with its own `X-Nomad-Token` is passed on unchanged. The Consul ui needs a Consul token. For the cli there is a local
proxy that logs in through Authelia (`task proxy:up|login|status|env|down`). `task tokens` lists the ACL tokens that tofu minted (accessor ids; the secrets
stay in the encrypted states). CI and third party apps get **project** tokens, limited to a namespace, and a project VPN device: `docs/projects.md`.

Consul's bootstrap token (`cluster_consul_management_token` in the sops secrets, `acl.tokens.initial_management`) exists only while a cluster is
built. The same deploy lets tofu-consul mint the **ops token** (policy `global-management`, `service_tokens.ops` in the encrypted state), writes the
server configs without `initial_management` and deletes the bootstrap token from the cluster; tofu, `task backup`, `task smoke` and the restore use
the ops token from then on (`consul_ops_token` in `scripts/lib.sh`). It is the same power as the bootstrap token (creating policies and tokens is
`acl = write`, which cannot be scoped down); what changes is that no config file of any node holds it and that it can be rotated. If the state of
tofu-consul does not belong to the cluster any more (rebuilt cluster, old state), the deploy stops with a message; the bootstrap secret in the sops
file is valid only for a cluster that was built with it and not handed over yet.

Nomad's bootstrap token (`cluster_nomad_management_token`, the secret given to `nomad acl bootstrap`) is handed over the same way: tofu-nomad mints
an **ops token** (type `management`, `nomad_tokens.ops` in the encrypted state), `task backup`, `task smoke`, tofu-nomad and the second-factor
registration use it (`nomad_ops_token` in `scripts/lib.sh`, `cluster_nomad_ops_token`), and the deploy deletes the bootstrap token from the cluster (role
`nomad_acl`, tasks `token` / `handover`). The one exception is `task restore`: it needs the bootstrap token to restore the snapshot into the fresh cluster
(the snapshot brings the old ops token back).

The scripts hand a token to the node on **stdin**, never in the command line (`cluster_exec_tokens` in `scripts/lib.sh`; `/proc/*/cmdline` and Tetragon's exec
events, and so the node's log and Loki, would show it).

## Automatic updates

Every node installs updates by itself every `cluster_updates_interval_hours` (12, role `cluster_updates`; `cluster_updates_enabled: false` switches it off).
Ubuntu: `unattended-upgrades`, security pockets only (Ubuntu security, ESM). Alpine: a cron job with `apk upgrade` (Alpine has no security-only channel).
Nothing reboots: a kernel or libc update waits for you, and `task maintenance` lists the nodes that want a reboot. Docker images and the nomad / consul
binaries are not packages and are untouched.

## Authelia: second factor

Traefik asks Authelia about **every** request on `websecure` (a default middleware of the entry point): a job that forgets the middleware
is not public, a domain without an access rule is denied. A job that really is public gets an access rule with `policy: bypass` for its
domain in `authelia_access_rules` (first match wins: put it after the rules of the infrastructure). Every other rule must be `two_factor`
(or `deny`); the deploy refuses anything else and users without a TOTP seed. `task authelia:user
-- <name>` asks for a password (twice, or from stdin) and stores its argon2id hash and a generated TOTP seed sops-encrypted. The deploy
registers the seeds in Authelia and writes the otpauth URI to `secrets/authelia/totp-<name>.txt` (git-ignored): put it into an
authenticator app. The seed is the truth, so a lost database is repaired by the next deploy. The sqlite database lives in the host volume
`authelia` (`/srv/authelia` on the nodes in `cluster_authelia_hosts`, the ingress node by default) and is part of `task backup`. The job has
`auto_revert = false` on purpose (a failed upgrade may already have migrated the database). Sessions: 18 hours without a request, 24 hours
at most after the login (`authelia_session_*`).

Known limits (accepted): (1) there is one session cookie for the whole `cluster_domain`, so every app behind Traefik, public ones included, receives
it. Replaying it reaches only the login of Nomad and Consul (both need an ACL token) and the read-only Traefik dashboard. Keep the admin on an own account
(group `admin`, the only one the rules for `nomad.`/`consul.`/`traefik.` accept) and use it in a separate browser profile; apps are used with a normal account.
(2) Traefik's router, forward-auth middleware and service for Authelia are in the file provider, but any job's consul tags can still add a router
for a hostname of its own choice (also `nomad.`, with a high `priority`). Everyone who can submit jobs is an admin.

## Host firewall

Every node gets a nftables table `inet cluster` (`cluster_firewall_enabled`, default true), loaded at boot. Input policy drop except:
loopback, established connections, icmp, dhcp replies, **ssh from anywhere but the container bridges** (no source list: a wrong one would lock you out), Nomad
and Consul ports from the cluster subnet only, 80/443 on ingress nodes, and from the container bridges only dns and the Nomad and Consul api on the node's cluster address (jobs need them; tokens and tls
still apply; `cluster_firewall_bridge_tcp_ports` / `_udp_ports`). A forward chain drops everything that docker/nomad publish (nat) for sources outside the cluster
and the bridges, except the public ports (80/443 on ingress nodes): a port published by a job is cluster-only unless you open it. Own rules:
`cluster_firewall_extra_rules` (raw nft). Rules are checked with `nft -c` first. `task smoke` checks the table.

## Containers and the internet

Containers have **no internet access by default**, and no public dns either. The firewall rejects new connections from the container bridges
(`docker0`, Nomad's `bridge`) to anything outside the cluster and the container networks, and the resolver they are given (docker0, 172.17.0.1)
is a restricted dnsmasq per node: `*.consul` and the node's own names (`host.internal`, ...), every other name gets NXDOMAIN.

A job that needs the internet runs in the second bridge network, `network { mode = "cni/egress" }` (own bridge `br-egress`, own subnet;
Consul Connect sidecars work in it too). Its containers may connect anywhere and are sent to the full resolver (the node's dnsmasq on Alpine, a
second dnsmasq in front of systemd-resolved on Ubuntu; a firewall nat rule redirects their queries). Not affected: jobs with `mode = "host"`
(Traefik without WireGuard, Authelia) have no container network, and Traefik behind WireGuard uses `cni/egress`. Nomad and Consul run on the host.
Names and subnets: `cluster_egress_*`, `cluster_nomad_bridge_subnet`, `cluster_docker_bridge_subnet`; destinations that stay reachable for everyone:
`cluster_firewall_container_destinations`. Everything needs `cluster_firewall_enabled`. IPv6 from containers is rejected as well.

## Access: ssh

Only users with a key in their `authorized_keys` can log in, never root, never with a password; the platform writes the keys of the
`ansible` user only (the automation key + `cluster_ssh_authorized_keys`). sshd accepts one key exchange (`mlkem768x25519-sha256`),
two ciphers and `ssh-ed25519` keys (`cluster_ssh_*`). The automation key is generated by `task ssh:init`, or your own: `task ssh:init --
~/.ssh/key` (ed25519, no passphrase; it is copied to `secrets/ssh/ansible_ed25519`).

By default `sudo` (Ubuntu) / `doas` (Alpine) are passwordless for the `ansible` user. `task become:password` stores a password
(sops) that the next deploy sets and requires; going back needs the bootstrap script or console access.

## The public entry point

`websecure` (tcp/443, every public name and the apps) is the internet edge, and so it is the strictest of the entry points:

* **HSTS on every name** behind Traefik, the public ones (apps, ntfy, `auth.`) and the internal zone: the middleware `hsts` (one year, `includeSubdomains`, no `preload`) is the first of the
  default middlewares of `websecure` and `vpn`, so it also covers a job that sets its own tags and the answers of Authelia (a login redirect). It replaces an HSTS header of the app.
  The port 80 redirect cannot carry it (browsers ignore it over http).
* **Timeouts and a limit of requests in flight**: `cluster_traefik_public_read_timeout` / `_write_timeout` (600s each, like the entry point of the VPN; lower them if no app needs
  long downloads or plain http streams such as ntfy's json stream, which are cut at the write timeout) and `cluster_traefik_public_inflight` (100): at most that many requests in
  flight per source address (`inflight-public`). The VPN's wstunnel traffic is a TCP router with TLS passthrough and not subject to them; websockets neither.

## Internal services behind a VPN (zone `<cluster_name>.internal`)

The ops UIs (`auth.`, `nomad.`, `consul.`, `traefik.<cluster_name>.internal`) and any internal app are **not** on the public entry point. Their
routers live in Traefik's file provider on the entry point `vpn`, which only exists on the WireGuard address inside Traefik's allocation
(`cluster_vpn_subnet`, default `10.99.0.0/24`, the server is `.1`). In front of them is a **second Authelia** (`authelia-internal`): own cookie
domain, secrets, sqlite database, TOTP seeds (`authelia_internal_totp_seeds`, always separate from the public ones, `task authelia:seed` makes both), bans.

```
device --tcp/443 (SNI vpn.<cluster_domain>, mTLS)--> traefik TCP router (TLS passthrough) --> wstunnel --udp 127.0.0.1:51820--> wireguard (wg1)
device --wg--> 10.99.n.1: tcp/443 (redirected to the vpn entry point) and udp+tcp/53 (dnsmasq: *.<zone> -> 10.99.n.1), nothing else
```

* **WireGuard is the gate** (key + preshared key per device); wstunnel is only the disguise over tcp/443 (`--restrict-to 127.0.0.1:51820`, client
  certificate required, CN = device name). The UDP port is not published. `ip_forward=0` in the namespace and an nft table drop everything but 443
  and 53 on `wg1`: no route into the cluster network, consul, nomad, step-ca, sshd or the metrics port. Traefik always runs in its own namespace
  (`cni/egress`). Traefik is **not root** (`cluster_traefik_uid`, 65532): the sidecar `vpn` sets `net.ipv4.ip_unprivileged_port_start=80` in the shared namespace, the
  host's value does not reach it.
* The inner TLS is `pq-only` (TLS 1.3, X25519MLKEM768): a client without it (OpenSSL < 3.5, old browsers) cannot open the internal names. The outer layers
  are not post-quantum (WireGuard has a preshared key as a hedge).
* **Devices:** `task vpn:init` (once: server key), `task vpn:client -- <device>` (key pair, preshared key, address, client certificate; files in
  `secrets/vpn/<device>/`: `wg-<cluster>.conf`, `wstunnel@.service`, the env file, `install.sh`, `nm-install.sh` for NetworkManager), `task deploy:ansible`
  (the server learns the peer), `task vpn:revoke -- <device>` (removes the peer: **revocation is removing the WireGuard peer**), `task vpn:list`.
  The client certificate lives `cluster_vpn_client_valid_days` (365); run `task vpn:client -- <device>` again before it expires (the wireguard
  keys stay); `task smoke` and `task proxy:status` warn `cluster_vpn_client_warn_days` before. No `DNS=` in the client config: only the zone goes
  through the VPN (systemd-resolved), several clusters can be connected at once (distinct subnets, interfaces, zones, local ports).
* **Two halves of the address space:** `.2` - `.127` are people's devices (`task vpn:client`: the ops UIs behind authelia-internal), `.128` and up are
  project devices (`task project:vpn`: only `nomad-api.<zone>` and `consul-api.<zone>`, ACL token instead of a second factor). `docs/projects.md`.
* **Command line tools:** `task proxy:up|login` now goes through the VPN (`PROXY_UPSTREAM` defaults to `10.99.n.1:443`); the VPN must be up.
* Break glass is SSH (public, key only), e.g. `scripts/tunnel.sh` to the node's 127.0.0.1 ports with a token.
* Accepted: `vpn.<cluster_domain>` is visible as SNI on 443 and the gate is reachable from the internet (mTLS); the client's public IP is lost behind
  the TLS passthrough (device identity survives: CN, peer IP); TCP over TCP (fine for admin UIs, not for bulk); the VPN lives in a Nomad job, if
  Nomad / Docker / Traefik is down it is gone, SSH remains. **Do not put the VPN name behind a proxying CDN** (wstunnel issue #481: Cloudflare in front
  corrupts the stream; needs `--tls-sni-override` and still resets connections). The tunnel MTU is 1280 (`cluster_vpn_mtu`).

## step-ca: the always-online intermediate (job `step-ca`)

`task pki:ca` makes the offline root and two intermediates, both name-constrained: **ansible** (the controller: agent, node and ingress certificates)
and **step-ca** (about a year, `task pki:intermediate -- stepca` replaces it, then `task stepca:init` and a deploy). The step-ca job holds the
step-ca intermediate (key encrypted; password and the two JWK provisioner keys in `stepca-material.sops.yml`, from `task stepca:init`).
Nomad and Consul agent certificates **never** come from step-ca (an expired one would break the thing that renews it); Consul Connect keeps its own CA.

* **Reachable through the Consul mesh only:** it binds 127.0.0.1:9000 in its own namespace, no host port. Intentions are default deny
  (tofu-consul): only the service `traefik-acme` (Traefik's group, upstream `step-ca` -> 127.0.0.1:9000) may connect. Operators use
  `nomad alloc exec`. It must not be published, reached from the VPN, or from a workload without an intention (`task smoke` and the tests check).
* **Traefik** has two resolvers: the public one (`cluster_acme_ca`) and `stepca` for the internal routers: tls-alpn-01, per-name certificates,
  7 days (`cluster_stepca_cert_hours`, `certificatesDuration`), the ACME provisioner may only issue `*.<zone>`. step-ca validates against the ingress
  node's cluster address (its own dnsmasq maps the zone there; the challenge only returns a token, the routers stay on `vpn`).
* **wstunnel's certificate** is issued by the deploy (provisioner `services`, only the VPN name) and renewed in place by the sidecar `vpn-renew`
  (`step ca renew --daemon`); `task maintenance` issues a new one if it expired anyway. Authelia-internal's certificate stays on the Ansible path
  (it runs outside a container network).
* **Device certificates** (1 year, CN only, client auth only) are issued by `task vpn:client` through `nomad alloc exec` (provisioner `clients`, a template).
* Backup: `task backup` streams step-ca's database (badger) out of the allocation; restore puts it back before the job starts. Without it step-ca
  starts empty and Traefik asks for the certificates again. An outage of step-ca is survivable for up to 7 days.
* Envoy (BoringSSL) cannot verify a chain with IP name constraints and an IP in the leaf, so Consul's gRPC listener has its own certificate
  without IP addresses (`consul-grpc`). `cluster_stepca_enabled: false` keeps the interim wildcard from the ansible intermediate.

## Nomad's systemd unit: which hardening is NOT used, and why

Nomad (and only Nomad) runs without `ProtectKernelModules`, `ProtectKernelLogs`, `ProtectClock` and every other `Protect*` option, on purpose. They make systemd start the
service in a **private mount namespace**. Nomad mounts a tmpfs for the `secrets/` directory of every task; in the private namespace that mount is invisible to
dockerd, so the container sees an empty `/secrets`. Consequences: templates written to `secrets/` (tokens, certificates) and the Envoy bootstrap of every Consul
Connect sidecar (`secrets/envoy_bootstrap.json`) do not exist, and the task fails to start. Alpine (OpenRC) is not affected, which is why it can go unnoticed. The unit keeps
`NoNewPrivileges`, `RestrictRealtime`, `LockPersonality` and `SystemCallArchitectures`. Consul's unit does not mount anything for others and keeps its `Protect*` options.
Do not add them back (the comment in `ansible/roles/nomad/tasks/main.yml` says the same).

## Docker, volumes, logs

* Jobs cannot bind-mount arbitrary host paths (`cluster_docker_volumes_enabled: false`). Declare per node
  `cluster_host_volumes: [{name, path, read_only}]` in `host_vars` and use `volume` + `volume_mount`. A read-only mount of the docker
  socket still allows the whole docker API.
* `cluster_docker_daemon_extra` is merged into `/etc/docker/daemon.json` (e.g. the `nvidia` runtime).
* **Daemon settings of the platform** (`/etc/docker/daemon.json`; `cluster_docker_daemon_extra` wins): `no-new-privileges`, `default-cgroupns-mode: private`, `userland-proxy: false` (published ports are iptables rules; no `docker-proxy` per port), `default-ulimits`
  `nofile` = `cluster_docker_nofile` (1048576: databases, dev setups; a task can set its own), the `dns` of the restricted resolver and rotated `json-file` logs. **Not `init: true`**: with a daemon-wide init, images that bring their own (s6-overlay, i.e. every linuxserver.io image and the
  wireguard sidecar of Traefik) exit at once ("can only run as pid 1"), and a job cannot opt out; a job that wants tini sets `init = true` in its docker config.
* **What confines a container:** the default seccomp profile on both OS families, AppArmor (`docker-default`) additionally on Ubuntu (Alpine's kernel has no AppArmor
  or SELinux), `no-new-privileges`, a private cgroup namespace on cgroup v2. Nothing here switches them off; a job can (`security_opt`), see `docs/projects.md`.
* **Nomad's docker plugin:** `allow_caps` is always set (`nomad_docker_default_caps` + `nomad_docker_extra_caps`): it limits what `cap_add` may name, not the capabilities
  Docker gives every container. Privileged mode is off (nomad's default), `pid_mode = "host"` is refused with it, runtimes are not restricted (the `nvidia` runtime of
  `cluster_docker_daemon_extra` works as soon as a job asks for it).
* **`live-restore` is on:** the containers keep running while dockerd is stopped or restarted, so a security update of Docker (unattended-upgrades on Ubuntu,
  the `apk upgrade` cron job on Alpine) or a change of `daemon.json` does not restart the jobs. Nomad's docker driver finds the containers again; the node
  may report the driver as unhealthy for a few seconds. Limits: it does not carry across a major version of Docker (the daemon then has to stop the
  containers), a daemon that stays down for long leaves the containers without log collection (the pipe breaks; docker's log driver, not the container, suffers),
  and it cannot be combined with Swarm (not used here). Switch it off with `cluster_docker_daemon_extra: {live-restore: false}`.

## No calls home

Nomad and Consul run with `disable_update_check` (no check for new versions and security bulletins) and `disable_anonymous_signature`; Traefik with
`checkNewVersion: false` and `sendAnonymousUsage: false`. None of them has a telemetry sink configured: Nomad exposes its metrics for pulling
(`/v1/metrics?format=prometheus`, behind the ACL; `nomad_publish_workload_metrics` for the workload ones), Consul has no `telemetry` block, and Traefik's
Prometheus entry point is for the cluster only (`cluster_traefik_metrics`). Authelia and step-ca do not send anything either. What is left outbound
is the packages (the update timers), the image pulls, and ACME with a public CA.
* Logs: the agents keep seven days, one file per day (`cluster_log_retention_days`). Container logs are rotated by size, docker cannot do days:
  seven files of 50 MB per container (`cluster_docker_log_max_files`, `cluster_docker_log_max_size`). Metrics are not handled.
* `no-new-privileges` is set as the daemon default; a job opts out with `security_opt = ["no-new-privileges=false"]`.

## Traefik behind wireguard (optional, for nodes without a public address)

`cluster_traefik_wireguard: true` runs traefik with a wireguard client sidecar in one allocation. `task wireguard:conf -- ./wg0.conf`
stores the wg-quick config (no `DNS=`/`PostUp`/`PostDown`; keep `AllowedIPs` to the tunnel's subnets; set `PersistentKeepalive`). Set
`cluster_wireguard_image`. Not run on a cluster yet; not needed on a VPS with a public address.

## Runtime security: Tetragon

Every node runs [Tetragon](https://tetragon.io) (eBPF) as a host service: systemd on Ubuntu, OpenRC on Alpine. It is the static release tarball of
`cluster_tetragon_version`, checked against `cluster_tetragon_sha256` and unpacked to `/opt/tetragon/<version>`: the same files on both OS families, no
build, no package. A node whose kernel has no BTF (`/sys/kernel/btf/vmlinux`) or no cgroup v2 is skipped with a message. `cluster_tetragon_enabled: false`
stops the service.

| What | Where |
|---|---|
| Events, one json object per line | `cluster_tetragon_log_dir/tetragon.log` (default `/var/log/tetragon`, root only). The agent rotates by size (`cluster_tetragon_log_max_size_mb`) and daily, keeps `cluster_tetragon_log_max_backups` gzipped files. Meant for promtail / Alloy / Loki |
| The agent's own log | json; Ubuntu: journal (`journalctl -u tetragon`), Alpine: `agent.log` in the same directory (logrotate, `cluster_log_retention_days`) |
| Prometheus metrics | `http://<node cluster address>:2112/metrics` (`cluster_tetragon_metrics_port`), reachable from the cluster subnets only (host firewall). Scrape every node; the agent also exposes `tetragon_events_total` per binary and event type. About 2,250 series per node, 1,800 of them two always-on health families (`tetragon_handling_latency_*`, `tetragon_handler_errors_total`, one series per internal opcode and bucket, nearly all zero) that this Tetragon version cannot switch off: the scraper should drop `tetragon_handling_latency*`, `tetragon_handler_errors_total`, `tetragon_msg_op_total`, `tetragon_data_event_size*`, `tetragon_event_cache_*`, `go_*` (about 100 series remain: lost events, ring buffer, exported events, process cache, policies). The label `binary` is switched off (`metrics-label-filter`: one series per executable ever started). Container metrics are Nomad's job |
| Health | `127.0.0.1:6789` (node only) |
| Command line | `tetra` on the node as root (`tetra getevents -o compact`, `tetra tracingpolicy list`); the gRPC socket is `/var/run/tetragon/tetragon.sock` |

By default the agent only **observes**: process_exec / process_exit of everything on the node (host and containers, with uid and the container id).
Left alone that is a lot (the deploy itself starts thousands of processes, every container start four plumbing events, every event 5 KB), so three
filters are on (measured on the test cluster: an idle node writes about a tenth of the bytes):

| Variable | Drops |
|---|---|
| `cluster_tetragon_quiet_runtime` | events of runc, containerd-shim, docker-init (container start plumbing); the container's own first process stays |
| `cluster_tetragon_quiet_deploys` | everything the ansible user starts, except its `sudo` / `doas` calls (the record of what ran as root). **Blind spot:** the account is root equivalent; its processes are not visible, only the command lines it handed to sudo. `false` = log all of it |
| `cluster_tetragon_slim_events` | capability sets and namespace ids in exec / exit events (80 % of an event's size) |

More: `cluster_tetragon_export_denylist` (json filter objects, e.g. `'{"binary_regex":["/healthcheck.sh$"]}'`). What is left on an idle node is mostly
what runs in your containers (health check scripts): filter those by binary there.

**Policies** (TracingPolicy yaml, loaded at start from `/etc/tetragon/tetragon.tp.d`):

- `cluster_tetragon_presets`, shipped with the platform (default: `block-metadata-service`):
  - `network-connect` - observe: tcp connections of container processes.
  - `block-metadata-service` - **enforce**: a container process that connects to 169.254.169.254 or `fd00:ec2::254` (IPv4 / IPv6 metadata address) is killed with SIGKILL before the connection is made.
- the cluster repo's own: `tetragon.d/*.yaml` (jinja allowed; `.yaml.j2` too). Removing a file removes the policy. A policy with `matchActions: Sigkill`
  or `Override` enforces, without it it only reports. Policy reference and examples: tetragon.io/docs/concepts/tracing-policy.

Changing a policy, a setting or the version restarts the agent (a few seconds without events). Other flags: `cluster_tetragon_config` (flag name -> value,
one file each in `/etc/tetragon/tetragon.conf.d`). Standalone mode has no Kubernetes metadata: containers are identified by their cgroup / docker id, not by
Nomad job names (map them with the container labels or `docker ps`).

Limits: the agent runs as root and sees every command line (so the log is root only). Enforcement kills the process, it does not give the container
a clean error. It does not replace the network rules of the host firewall or the Docker settings above, it watches what they let through.

## Backup and restore

`task backup` writes `backups/<cluster>-<time>/`: Nomad and Consul snapshots, the tofu states, the authelia database of each node that has
one (an SQL dump made by `sqlite3` in a throwaway container on the node, image `cluster_sqlite_image`, replayed by `task restore`), the database of Grafana (`pg_dump` in the running postgres of the monitoring stack, replayed by `task restore`; the logs and metrics are not backed up) and traefik's `acme.json` (public ACME CAs), all age-encrypted to the recipients of `.sops.yaml` (newest `BACKUP_KEEP`, default 10).
Application data is not part of it. Copy the folder off the machine, together with the age private key (`secrets/age/keys.txt`): without
the key the backups and every secret are lost.

Disaster recovery (the node is gone; cluster repo, age key and a backup folder are not):

```sh
git clone <cluster repo> && cd <cluster repo> && git submodule update --init
# put secrets/age/keys.txt and backups/<dir> in place; bootstrap the new node(s) again (see the guide)
task ssh:init                      # a new automation key for the new nodes
task restore -- <backup dir name>  # restores the snapshots right after the servers are up, then waits for task smoke
```

The restore refuses a cluster that already has workloads. Drilled on Incus VMs; the authelia folder part is untested.

## Extending without touching the platform

| In the cluster repo | Effect |
|---|---|
| `inventory/host_vars/<node>.yml` | per-node variables (`cluster_interface`, `cluster_host_volumes`, ...) |
| `nomad.d/6x-*.hcl.j2`, `consul.d/6x-*.hcl.j2` | extra daemon config on all or some nodes (jinja) |
| `playbooks/*.yml`, `roles/` | run after the platform by `task deploy:ansible` / `task node`: packages, users, your jobs |
| `maintenance/*.yml` | run after the platform's by `task maintenance` |
| `compose.override.yml`, `Taskfile.yml` | extra mounts for the tools container, extra tasks |

Do not edit anything below `base/`: change the platform in its own repo and move the pointer with `task upgrade`.

## Monitoring

Logs, metrics, alerts and a status page on every cluster by default: `docs/monitoring.md` (architecture, collected data, custom metric endpoints with Consul tags,
retention, a primer on what Alertmanager needs). Variables: `cluster_monitoring_enabled`, `cluster_monitoring_node` (default: the server node, if it is a client),
`cluster_monitoring_retention_days` (45), `cluster_monitoring_dir`, the `*_image` tags, `cluster_monitoring_extra_rules`.

## Open ideas (not implemented)

* Nodes renewing their own agent certificates from step-ca (deliberately not done, see above). Leaf
  certificates are valid for a year (`cluster_leaf_valid_days`) and renewed by `site.yml` / `task maintenance`; nothing alerts before they expire.
