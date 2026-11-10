# nomad-platform

A small, opinionated way to run a [Nomad](https://www.nomadproject.io) cluster on a handful of machines (VMs, bare metal, a
VPS) with a login in front of everything. This repo is the shared part (roles, playbooks, OpenTofu roots, scripts, tasks).
Every cluster has its own repo with only its data, and includes this one as the git submodule `base/`.

> Provided as is, without warranty or support. Written for and tested on the author's own infrastructure: read the code and try it on
> a throw-away cluster before it manages machines that matter.

## What you get

Four services on every cluster:

- **Nomad** runs the workloads (docker containers). **Consul** is service catalogue, DNS and service mesh.
- **Traefik** is the ingress (https, your services). The ops UIs (`nomad.`, `consul.`, `traefik.`, `auth.<cluster_name>.internal`) are only
  reachable through a **WireGuard VPN** (over tcp/443 with wstunnel) behind a second **Authelia** (password and TOTP); certificates of the
  internal names come from **step-ca** (7 days, renewed automatically). See `docs/reference.md`.
- One cluster CA, ACLs everywhere (no anonymous access), workload identity instead of static tokens, a nftables firewall, hardened
  sshd (key only, no root), secrets encrypted with sops/age, backups of the cluster state.

Everything that touches a node is Ansible over ssh; the objects inside the cluster (ACL policies, identity) are OpenTofu with an
encrypted state. All tooling runs in one container per cluster, so the machine you work from needs only `docker`, `git` and
[`task`](https://taskfile.dev). Nomad, Consul and gVisor's `runsc` are built from source once (`task build`) into a cache shared by all clusters. Docker containers run in a gVisor sandbox unless a job opts out (`runtime = "runc"`, `docs/reference.md`).

## The repos

```
nomad-platform/          this repo, versioned by tags. No cluster data.
  cluster-template/      a bare cluster repo: copy it to start a new cluster
my-cluster/              a cluster repo (yours, private): inventory, variables, encrypted secrets and states
  base/                  -> nomad-platform as a git submodule; the pointer IS the version the cluster runs
```

## Create a cluster (overview)

```sh
cp -r nomad-platform/cluster-template ~/clusters/my-cluster && cd ~/clusters/my-cluster
git init -b main && git submodule add <url of nomad-platform> base     # or a local path
```

(`base/scripts/init-cluster.sh <dir> <name> <domain>` does the same and fills in the name and domain.) Then everything happens in the
cluster repo, and **its README is the guide**: [cluster-template/README.md](cluster-template/README.md). In short:

1. **Describe the cluster:** name and domain, nodes and their roles, who may sign in (`inventory/`, `.env`).
2. **Create the secrets, once:** `task up`, `task age:init pki:ca secrets:init ssh:init`, `task authelia:user -- <name>`.
3. **Prepare every node, once, as root:** run `base/scripts/node-bootstrap.sh` (creates the unprivileged `ansible` user, sshd,
   python, sudo or doas). On a single VPS add the dummy network interface for the cluster network (see the guide: it keeps Nomad
   and Consul off the public interface).
4. **Deploy:** `task build`, `task deploy:ansible`, `task smoke`.
5. Add the TOTP registration (`secrets/authelia/totp-<name>.txt`) to your authenticator app, point DNS at the ingress node, sign in.

Updating the platform later: `task upgrade -- <tag>` (shows the changelog, stages the new submodule pointer).

## What your machine needs

`docker` (with compose and buildx), `git` and [`task`](https://taskfile.dev); [`gum`](https://github.com/charmbracelet/gum) for the
interactive questions (`task authelia:user`, `task proxy:login`).

## What the nodes need

- **Ubuntu 26.04 LTS or later**, or the **latest Alpine Linux** (3.24 tested). Nothing
  older is supported: the controller's ssh client offers only `mlkem768x25519-sha256`, which needs the OpenSSH 10 of these releases.
- Nodes reach each other by the address of their `cluster_interface`; no DNS records for node names are needed.
- Root on the node for the bootstrap, and a way in when ssh is broken (the provider's console or rescue mode). After the bootstrap
  and deploy root cannot log in over ssh, and ssh is the only remote way in; the firewall leaves port 22 open to everyone.

## Where to read more

| | |
|---|---|
| [cluster-template/README.md](cluster-template/README.md) | step by step: configure, bootstrap nodes, deploy, operate (the guide) |
| [docs/reference.md](docs/reference.md) | network, tokens, firewall, privilege escalation, docker volumes, logs, wireguard, backup and restore, extending |
| [docs/projects.md](docs/projects.md) | scoped Nomad / Consul tokens and VPN devices for CI and third party apps: define, export, use |
| [docs/contract.md](docs/contract.md) | what a cluster repo must contain, every variable, inventory groups, extension points |
| [CHANGELOG.md](CHANGELOG.md) | what changed per version |
| [CLAUDE.md](CLAUDE.md) | working on this repo against a test cluster (also for humans): the loop, `dev/` tools, failure modes, shell pitfalls |

## Known issues and open items

- No secret rotation and no node removal task: operator work. A leaked secret means new secrets and a redeploy.
- The age key is a single point of failure: keep copies outside the machine (a second recipient in `.sops.yaml` is possible, there is no task).
- Certificates are renewed only by `task maintenance` / `task deploy:ansible`, not in the background. Run one at least once a year.
- `ssh-mldsa44-ed25519` as soon as the distributions ship OpenSSH 10.6.
