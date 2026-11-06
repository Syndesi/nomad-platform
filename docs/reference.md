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
proxy that logs in through Authelia (`task proxy:up|login|status|env|down`). `task tokens` prints the management tokens.

Consul's bootstrap token (`cluster_consul_management_token` in the sops secrets, `acl.tokens.initial_management`) exists only while a cluster is
built. The same deploy lets tofu-consul mint the **ops token** (policy `global-management`, `service_tokens.ops` in the encrypted state), writes the
server configs without `initial_management` and deletes the bootstrap token from the cluster; tofu, `task backup`, `task smoke` and the restore use
the ops token from then on (`consul_ops_token` in `scripts/lib.sh`). It is the same power as the bootstrap token (creating policies and tokens is
`acl = write`, which cannot be scoped down); what changes is that no config file of any node holds it and that it can be rotated. If the state of
tofu-consul does not belong to the cluster any more (rebuilt cluster, old state), the deploy stops with a message; the bootstrap secret in the sops
file is valid only for a cluster that was built with it and not handed over yet.

## Authelia: second factor

Traefik asks Authelia about **every** request on `websecure` (a default middleware of the entry point): a job that forgets the middleware
is not public, a domain without an access rule is denied. A job that really is public gets an access rule with `policy: bypass` for its
domain in `authelia_access_rules` (first match wins: put it after the rules of the infrastructure). Every other rule must be `two_factor`
(or `deny`); the deploy refuses anything else and users without a TOTP seed. `task authelia:user
-- <name>` asks for a password (twice, or from stdin) and stores its argon2id hash and a generated TOTP seed sops-encrypted. The deploy
registers the seeds in Authelia and writes the otpauth URI to `secrets/authelia/totp-<name>.txt` (git-ignored): put it into an
authenticator app. The seed is the truth, so a lost database is repaired by the next deploy. The sqlite database lives in the host volume
`authelia` (`/srv/authelia` on the nodes in `cluster_authelia_hosts`, the first ingress node by default) and is part of `task backup`. The job has
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

## Docker, volumes, logs

* Jobs cannot bind-mount arbitrary host paths (`cluster_docker_volumes_enabled: false`). Declare per node
  `cluster_host_volumes: [{name, path, read_only}]` in `host_vars` and use `volume` + `volume_mount`. A read-only mount of the docker
  socket still allows the whole docker API.
* `cluster_docker_daemon_extra` is merged into `/etc/docker/daemon.json` (e.g. the `nvidia` runtime).
* Logs: the agents keep seven days, one file per day (`cluster_log_retention_days`). Container logs are rotated by size, docker cannot do days:
  seven files of 50 MB per container (`cluster_docker_log_max_files`, `cluster_docker_log_max_size`). Metrics are not handled.
* `no-new-privileges` is set as the daemon default; a job opts out with `security_opt = ["no-new-privileges=false"]`.

## Traefik behind wireguard (optional, for nodes without a public address)

`cluster_traefik_wireguard: true` runs traefik with a wireguard client sidecar in one allocation. `task wireguard:conf -- ./wg0.conf`
stores the wg-quick config (no `DNS=`/`PostUp`/`PostDown`; keep `AllowedIPs` to the tunnel's subnets; set `PersistentKeepalive`). Set
`cluster_wireguard_image`. Not run on a cluster yet; not needed on a VPS with a public address.

## Backup and restore

`task backup` writes `backups/<cluster>-<time>/`: Nomad and Consul snapshots, the tofu states, the authelia database of each node that has
one (an SQL dump made by `sqlite3` in a throwaway container on the node, image `cluster_sqlite_image`, replayed by `task restore`) and traefik's `acme.json` (public ACME CAs), all age-encrypted to the recipients of `.sops.yaml` (newest `BACKUP_KEEP`, default 10).
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

## Open ideas (not implemented)

* An always-online intermediate CA (root offline, intermediate on a server, e.g. step-ca; nodes renew with their still-valid certificate). Leaf
  certificates are valid for a year (`cluster_leaf_valid_days`) and renewed by `site.yml` / `task maintenance`; nothing alerts before they expire.
