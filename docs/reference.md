# Reference

Details behind the [README](../README.md) and the [cluster guide](../cluster-template/README.md). Variables and defaults:
[contract.md](contract.md) and `ansible/inventory/group_vars/all/defaults.yml`.

## Network: where the cluster listens

`cluster_interface` names the interface of the cluster-internal network (default: the interface of the default route; set it per node
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

## Authelia: second factor

Every access rule must be `two_factor` (or `deny`); the deploy refuses anything else and users without a TOTP seed. `task authelia:user
-- <name>` asks for a password (twice, or from stdin) and stores its argon2id hash and a generated TOTP seed sops-encrypted. The deploy
registers the seeds in Authelia and writes the otpauth URI to `secrets/authelia/totp-<name>.txt` (git-ignored): put it into an
authenticator app. The seed is the truth, so a lost database is repaired by the next deploy. The sqlite database lives in the host volume
`authelia` (`/srv/authelia` on the nodes in `cluster_authelia_hosts`, the servers by default) and is part of `task backup`. The job has
`auto_revert = false` on purpose (a failed upgrade may already have migrated the database). Sessions: 7 days without a request, 7 days
at most after the login (`authelia_session_*`).

## Host firewall

Every node gets a nftables table `inet cluster` (`cluster_firewall_enabled`, default true), loaded at boot. Input policy drop except:
loopback, established connections, icmp, dhcp replies, **ssh from anywhere but the container bridges** (no source list: a wrong one would lock you out), Nomad
and Consul ports from the cluster subnet only, 80/443 on ingress nodes, and from the container bridges only dns and the Nomad and Consul api on the node's cluster address (jobs need them; tokens and tls
still apply; `cluster_firewall_bridge_tcp_ports` / `_udp_ports`). A forward chain drops everything that docker/nomad publish (nat) for sources outside the cluster
and the bridges, except the public ports (80/443 on ingress nodes): a port published by a job is cluster-only unless you open it. Own rules:
`cluster_firewall_extra_rules` (raw nft). Rules are checked with `nft -c` first. `task smoke` checks the table.

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
* Logs: seven days, one file per day (`cluster_log_retention_days`); container logs and metrics are not handled.

## Traefik behind wireguard (optional, for nodes without a public address)

`cluster_traefik_wireguard: true` runs traefik with a wireguard client sidecar in one allocation. `task wireguard:conf -- ./wg0.conf`
stores the wg-quick config (no `DNS=`/`PostUp`/`PostDown`; keep `AllowedIPs` to the tunnel's subnets; set `PersistentKeepalive`). Set
`cluster_wireguard_image`. Not run on a cluster yet; not needed on a VPS with a public address.

## Backup and restore

`task backup` writes `backups/<cluster>-<time>/`: Nomad and Consul snapshots, the tofu states, the authelia folder of each node that has
one and traefik's `acme.json` (public ACME CAs), all age-encrypted to the recipients of `.sops.yaml` (newest `BACKUP_KEEP`, default 10).
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
