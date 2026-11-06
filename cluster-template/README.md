# Cluster repo (template)

This folder is a bare cluster repo of [nomad-platform](../README.md): data and extension files only, no logic. The platform
(roles, playbooks, scripts, tasks) is the git submodule `base/`, and the version it points to is the version this cluster runs.
Delete this paragraph and describe your cluster here.

## 0. Create it

```sh
cp -r nomad-platform/cluster-template ~/clusters/my-cluster && cd ~/clusters/my-cluster
git init -b main
git submodule add <url or path of nomad-platform> base     # pin a release: git -C base checkout <tag>
```

Or: `nomad-platform/scripts/init-cluster.sh ~/clusters/my-cluster my-cluster example.org` (copies the template, replaces the
placeholders, creates the repo and the submodule). A local path as submodule url needs
`git -c protocol.file.allow=always submodule add ...`.

You need `docker`, `git`, [`task`](https://taskfile.dev) and [`gum`](https://github.com/charmbracelet/gum) (asks for passwords and TOTP codes) on this machine. Do not edit anything below `base/`.

## 1. Describe the cluster

| File | What to change |
|---|---|
| `.env` | `CLUSTER_NAME` and `COMPOSE_PROJECT_NAME` (same value, lower case). Binary cache: `ARTIFACTS_DIR` (default `~/.cache/nomad-platform/artifacts`, shared by all clusters). No `${HOME}` in this file |
| `inventory/group_vars/all/cluster.yml` | `cluster_name`, `cluster_domain`, `cluster_acme_email`, `cluster_acme_ca`, `cluster_ssh_authorized_keys` (your own public ssh keys) |
| `inventory/group_vars/all/authelia.yml` | users (name, mail, groups) and which group may open which domain; every rule must be `two_factor`, `deny` or an explicit `bypass` (public route) |
| `inventory/20-static.yml` | the nodes: `ansible_host`, OS group (`alpine` / `ubuntu`), roles (`cluster_servers`, `cluster_clients`, `cluster_ingress`) |
| `inventory/host_vars/<node>.yml` | per node: `cluster_interface`, `cluster_host_volumes`, ... |

`cluster_acme_ca`: `internal` (the cluster CA signs the ingress certificate; browsers warn), `letsencrypt-staging` (first real
test: needs DNS and ports 80/443 reachable), `letsencrypt`. Use staging until everything works, production has rate limits.

**A single VPS** (all roles on one node), `inventory/20-static.yml`:

```yaml
all:
  children:
    alpine: {hosts: {}}
    ubuntu:
      hosts:
        vps1: {ansible_host: 203.0.113.10}
    cluster_servers: {hosts: {vps1: {}}}
    cluster_clients: {hosts: {vps1: {}}}
    cluster_ingress: {hosts: {vps1: {}}}
```

`inventory/host_vars/vps1.yml`: `cluster_interface: cluster0` (created in step 3).

**DNS records** (at your DNS provider, pointing at the ingress node): `auth.<cluster_domain>`, `nomad.`, `consul.`, `traefik.`. A wildcard
`*.<cluster_domain>` covers all of them and your own services. The nodes' own names need no records.

## 2. Create the secrets (once)

```sh
task up                              # builds the tools image, starts this cluster's container
task age:init pki:ca secrets:init    # age key, cluster CA, generated tokens and keys (sops-encrypted, committed)
task ssh:init                        # the key ansible logs in with (secrets/ssh/); or your own: task ssh:init -- ~/.ssh/key
task authelia:user -- admin          # per user: asks for a password twice, stores its argon2id hash and a TOTP seed
```

* **Back up `secrets/age/keys.txt` now** (password manager and an offline copy). Everything encrypted, backups included, is lost with it.
* `task ssh:init -- <key>` takes your own private key: ed25519, no passphrase (CI could not type one), copied to `secrets/ssh/`.
  Without an argument a new key is generated. Your personal login keys belong in `cluster_ssh_authorized_keys`.
* `task authelia:user` reads the password from stdin when it is not a terminal.
* Commit: `git add -A && git commit`. The private keys and `secrets/authelia/` are git-ignored; the rest is encrypted.

## 3. Prepare every node (once, as root)

The nodes run **Ubuntu 26.04 LTS or later** or the **latest Alpine Linux**, and you need a console or rescue mode of the provider for the
day ssh is broken.

**a) The ansible user.** `task ssh:bootstrap-cmd` prints the line to run. Copy `base/scripts/node-bootstrap.sh` to the node and run it
as root:

```sh
scp base/scripts/node-bootstrap.sh root@203.0.113.10:
ssh root@203.0.113.10 "sh node-bootstrap.sh ansible 'ssh-ed25519 AAAA... ansible@my-cluster'"     # the line `task ssh:bootstrap-cmd` printed
```

It installs sshd, python3 and sudo (Ubuntu) or doas (Alpine), creates the unprivileged `ansible` user (random password nobody knows,
key login only, passwordless escalation) and authorizes the automation key. Safe to run again. From the first deploy on, root and
passwords are refused by sshd; the root password stays untouched (the console still works with it).
Check: `ssh -i secrets/ssh/ansible_ed25519 ansible@203.0.113.10 sudo id` (use `doas id` on Alpine).

**b) The cluster interface (single node, or any node without a private network).** By default Nomad and Consul use the interface of
the default route, which on a VPS is the public one, and the firewall would open their ports to its whole subnet. Give the node a dummy
interface with a private address and set `cluster_interface` to it. The platform does not create it; do it once per node. Pick an
address that nothing else uses: any private range (here `10.200.0.1/24`), or, on a LAN, an unused address of the LAN's subnet that
neither the router's DHCP nor DNS knows (the other machines of the LAN still reach it, ARP finds it). **Without a connected route**
(`AddPrefixRoute=false` / `ip route del`): the dummy's /24 would otherwise add a second route for the same subnet that wins over the
real interface, and the node loses all traffic in that subnet. Several nodes need to reach each other's cluster addresses, so on
several nodes use addresses of one shared subnet.

Ubuntu (systemd-networkd; tested on 26.04; independent of netplan/cloud-init):

```sh
cat > /etc/systemd/network/10-cluster0.netdev <<'EOF'
[NetDev]
Name=cluster0
Kind=dummy
EOF
cat > /etc/systemd/network/10-cluster0.network <<'EOF'
[Match]
Name=cluster0
[Network]
ConfigureWithoutCarrier=yes
[Address]
Address=10.200.0.1/24
AddPrefixRoute=false
EOF
systemctl restart systemd-networkd; ip -br a show cluster0
```

Alpine (`/etc/network/interfaces`; tested on 3.24): append

```
auto cluster0
iface cluster0 inet static
	address 10.200.0.1/24
	pre-up ip link add cluster0 type dummy
	post-up ip route del 10.200.0.0/24 dev cluster0
	post-down ip link del cluster0
```

and run `rc-service networking restart` (busybox `ip` has no `-br`). Both variants survive a reboot (tested).
Several nodes need a real private network between them (provider VLAN, WireGuard) and its interface name instead.

## 4. Deploy

```sh
task build                # nomad + consul from source, once (slow), cached in ARTIFACTS_DIR
task deploy:ansible       # configures the nodes: about 2 minutes for one node, 5 for three
task smoke                # checks everything from the outside: cluster, ingress and login, tls, dns, firewall, ssh
git add -A && git commit  # states and encrypted secrets
```

What `deploy:ansible` does on a fresh node: ssh hardening, packages, docker, firewall, certificates from the cluster CA, Consul, Nomad,
ACLs and workload identity (OpenTofu), then the jobs Traefik and Authelia, then the TOTP registration of the users.

Afterwards:

* Add `secrets/authelia/totp-<user>.txt` (an `otpauth://` URI, also usable as QR code) to your authenticator app.
* Open `https://nomad.<cluster_domain>`: Authelia asks for password and TOTP. `task proxy:up` + `task proxy:login` gives the `nomad` and
  `consul` CLIs the same login; `task tokens` prints the management tokens, `task cluster` the state.
* The deployment is idempotent: a second run changes nothing. Re-running after an error continues where it stopped.

## 5. Operate

| What | How |
|---|---|
| Package updates, new node certificates | `task maintenance` regularly (monthly, from CI). Nodes are **not** rebooted (`cluster_reboot_allowed: false`): it lists the nodes that want one, you reboot them. Certificates are renewed only by this and by `deploy:ansible`: do it at least once a year |
| Add or change a node | edit `inventory/`, bootstrap a new node (step 3), `task node -- <name>` |
| Add a user | `authelia_users` in `authelia.yml`, `task authelia:user -- <name>`, `task deploy:ansible` |
| Backup | `task backup`, then copy `backups/<dir>` and the age key off the machine. Restore: `task restore -- <dir>` ([reference](../docs/reference.md)) |
| Update the platform | `task upgrade -- <tag>` shows the changelog and stages the pointer; test, commit |
| Own jobs, packages, daemon config | `playbooks/`, `nomad.d/`, `consul.d/`, `maintenance/` ([reference](../docs/reference.md)) |
| After reinstalling a node | `task ssh:forget -- <node>`, bootstrap again, `task node -- <node>` |
| All tasks | `task --list` |

## If something goes wrong

* **Locked out of ssh**: the provider's console (log in as root there) or rescue mode, or restore a provider snapshot. Take a snapshot
  of the VPS before the first deploy.
* **A node is unreachable right after step 3b**: the dummy interface's subnet route hijacked the real one, see 3b (`ip route`).
* **`deploy:ansible` stops at "cluster interface ... missing"**: step 3b was skipped or the name in `host_vars` is wrong.
* **Smoke test: ingress/ACME**: DNS not pointing at the node yet, ports 80/443 blocked at the provider, or `cluster_acme_ca` still `internal`.
