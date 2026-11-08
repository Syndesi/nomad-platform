# Contract between the platform and a cluster repo

The platform (this repo) is mounted in the cluster repo as the git submodule `base/`. It contains no cluster name,
no secret, no personal data. A cluster repo is **data plus extension files**; there is no logic in it.
`cluster-template/` is a bare cluster repo: copy it, add this repo as the submodule `base/`, fill in the values (its README is the guide).
Inside the tools container the cluster repo is `/work`, the platform `/work/base`, the shared binary cache `/artifacts`.

## What the cluster repo must provide

| Path in the cluster repo | Content |
|---|---|
| `Taskfile.yml` | `dotenv: [.env]`, `includes: base: {taskfile: base/tasks/Taskfile.yml, flatten: true, dir: .}` |
| `.env` | `CLUSTER_NAME`, `COMPOSE_FILE=base/tools/compose.yml[:compose.override.yml]`, `NOMAD_VERSION`, `CONSUL_VERSION`, `TOFU_VERSION`, `ALPINE_VERSION`; optional `CLUSTER_EXEC`, `AGE_KEY_DIR`, `SSH_KEY_DIR`. Do not use `${HOME}` in it (the Taskfile's dotenv does not expand it) |
| `inventory/` | any ansible inventory sources (static files, tofu inventory plugin, ...). Hosts must be in the groups below |
| `inventory/group_vars/all/*.yml` | the cluster variables (next section) |
| `inventory/group_vars/all/{secrets,ca}.sops.yml` | made by `task secrets:init` / `task pki:ca`, sops/age encrypted, committed |
| `.sops.yaml` | made by `task age:init` (public age recipients) |
| `pki/{ca,intermediate-ansible,intermediate-stepca}.pem` | the offline root and the two intermediates (public), made by `task pki:ca`; the keys are in `ca.sops.yml` (ansible intermediate), `stepca.sops.yml` (step-ca intermediate) and `pki/root.sops.yml` (root; not read by any deploy, keep it offline) |
| `inventory/group_vars/all/{vpn,stepca-material}.sops.yml` | made by `task vpn:init` (server key, devices) and `task stepca:init` (password, provisioner keys), sops/age encrypted, committed |
| `secrets/vpn/` | client files of the VPN devices (gitignored: private keys), made by `task vpn:client` |
| `secrets/projects/` | bundles of `task project:export` (age encrypted to the receiver; gitignored) |
| `inventory/group_vars/all/projects.yml` | optional: `cluster_projects`, see `docs/projects.md` |
| `state/` | state and plugin dir of the two tofu roots; the states are client side encrypted, so they may be committed |
| `secrets/age/` | the age private key (gitignored; keep a copy in a password manager and offline) |
| `secrets/ssh/` | the ssh key ansible and the scripts log in with, made by `task ssh:init` or your own (`task ssh:init -- <key>`; no passphrase; its type must be in `cluster_ssh_pubkey_algorithms`) (gitignored) |
| `inventory/group_vars/all/wireguard.sops.yml` | only with `cluster_traefik_wireguard`: the wg-quick config, made by `task wireguard:conf` |
| `maintenance/*.yml` | optional: your own maintenance playbooks, run by `task maintenance` after the platform's (name order) |
| `inventory/group_vars/all/become.sops.yml` | optional: the sudo/doas password, made by `task become:password` |
| `backups/` | made by `task backup`: age-encrypted nomad / consul snapshots (gitignored) |
| `ssh/known_hosts` | the nodes' ssh host keys (public), filled on first contact; `task ssh:forget` removes one |
| `inventory/group_vars/all/authelia.sops.yml` | password hashes of the authelia users, made by `task authelia:user` |

### Inventory groups

| Group | Meaning |
|---|---|
| `alpine` / `ubuntu` | OS family of the node (selects the binary build, package manager, init system) |
| `cluster_servers` | consul + nomad server (and, if also in `cluster_clients`, client) |
| `cluster_clients` | nomad client: docker, cni, dns forwarder |
| `cluster_ingress` | exactly one node: runs traefik (nomad client meta `traefik=true`), public 80/443; Authelia runs there by default |

The platform does not create machines. How they come to be (incus VMs by tofu, bare metal, a VPS) is the cluster repo's
business. It must only make them reachable over ssh and run `scripts/node-bootstrap.sh` on them once (by hand, or from
cloud-init): that creates the unprivileged `cluster_ansible_user` (key login, `sudo` on ubuntu, `doas` on alpine). The nodes run
Ubuntu 26.04 LTS or later or the latest Alpine (the controller's ssh client offers `mlkem768x25519-sha256` only) and, for a node without a private network, a dummy or
private interface that `cluster_interface` names (the platform does not create it, see the cluster guide).
Ansible and the scripts log in with the key from `task ssh:init`; root cannot log in over ssh.
A cluster whose nodes are not routable can add lines to the controller's ssh config with `cluster_ssh_config_extra`
(e.g. a `ProxyCommand`); `CLUSTER_EXEC` (`%HOST%` = inventory hostname) replaces the scripts' remote shell entirely.

### Required variables

| Variable | Meaning |
|---|---|
| `cluster_name` | short name, used in the CA subject and to derive the consul node ids |
| `cluster_domain` | base domain of the published UIs: `auth.`, `nomad.`, `consul.`, `traefik.` |
| `cluster_acme_email` | contact for ACME (also required for `internal`, it is passed to traefik) |
| `authelia_users`, `authelia_access_rules` | users (name, mail, groups; passwords via `task authelia:user`) and rules of the login portal |

### Optional variables (defaults: `ansible/inventory/group_vars/all/defaults.yml`)

`cluster_datacenter`, `cluster_region`, `cluster_acme_ca`, `cluster_ca_valid_days`, `cluster_leaf_valid_days` (leaf certs
are renewed once half of this is over), `cluster_nomad_http_port`, `cluster_consul_https_port`, `cluster_traefik_image`,
`cluster_authelia_image`, `cluster_dns_upstreams_override`, `cluster_node_domain` (default `cluster_domain`; names the nodes in their certificates), `cluster_host_volumes` (per node: `[{name, path, read_only}]`),
`cluster_ansible_user`, `cluster_ssh_authorized_keys`, `cluster_interface` (per node: the cluster network's interface, default the default route's),
`cluster_docker_volumes_enabled` (default false), `cluster_docker_daemon_extra`, `cluster_docker_nofile` (1048576), `cluster_log_retention_days` (7), `cluster_consul_task_kv_prefixes` (none),
`cluster_traefik_wireguard` / `cluster_wireguard_image` (see the README), `cluster_ssh_key_file`, `cluster_ssh_kex`, `cluster_ssh_ciphers`,
`cluster_ssh_host_key_algorithms`, `cluster_ssh_pubkey_algorithms`, `cluster_ssh_config_extra`, `cluster_reboot_allowed`,
`authelia_internal_extra_rules` (rules of your own internal apps behind the VPN), `cluster_internal_zone` (default `<cluster_name>.internal`),
`cluster_vpn_subnet` (a `x.y.z.0/24`, distinct per cluster), `cluster_vpn_*` (host, ports, MTU, client certificate lifetime, `cluster_vpn_project_first`), `cluster_projects` (`docs/projects.md`), `cluster_stepca_enabled` (default true) and
`cluster_stepca_*`, `authelia_internal_totp_seeds`, and the role defaults (`nomad_*`, `consul_*`). Inventory sources are merged in order (`ansible.cfg`: base first, cluster
second), so the cluster wins. Paths follow a fixed layout below `cluster_dir` (the cluster repo as the tools container
sees it); there is no path variable to set.

## Extension points (the cluster's own things stay out of the platform)

| Cluster repo | Effect |
|---|---|
| `nomad.d/[6-9]N-*.hcl.j2` | templated into `/etc/nomad.d` on every node (jinja, e.g. `{% if inventory_hostname in groups[...] %}`) before the single validate + restart. Host volumes, devices, plugins, per-node meta. Removing the file removes the fragment from the nodes |
| `consul.d/[6-9]N-*.hcl.j2` | same for `/etc/consul.d` |
| `playbooks/*.yml` | run in name order after `site.yml` by `task deploy:ansible`, and, limited to the one node, by `task node -- <host>`. Own roles can be added in `roles/` (on the roles path), own jobs can be run with `include_role: {name: cluster_jobs, tasks_from: job}` |
| `compose.override.yml` | extra mounts / environment for the tools container (the incus demo mounts the incus client config) |
| `Taskfile.yml` | cluster specific tasks next to the included ones |
| group_vars | any variable of any role |

Numbers 00-50 are reserved for the platform's fragments.

## What the platform promises

* The four services nomad, consul, traefik, authelia, wired together: tls from the cluster CA (or ACME), ACLs, workload
  identity, consul connect, dns, ingress login. Nothing else is deployed.
* Same entry points for every cluster: `task age:init pki:ca secrets:init`, `task build`, `task deploy:ansible`,
  `task node -- <host>`, `task smoke`, `task maintenance`, `task backup`, `task cluster`, `task tokens`.
* Idempotent: a second `deploy:ansible` changes nothing. A node can be (re)configured on its own.
* No secret in the platform; secrets live encrypted in the cluster repo, node keys never leave their node.
* Versioned by git tag; `CHANGELOG.md` lists what a bump changes. The cluster picks the version with the submodule pointer.

## What the cluster must not do

* Edit files below `base/`. Changes to the platform are commits in the platform repo, then `git -C base pull` /
  checkout of a tag, and a commit of the new pointer in the cluster repo.
* Depend on role internals (names of tasks, files in `/etc/cluster`) beyond what is written above.
