# Projects: scoped access for CI and third party apps

A **project** is a name in `cluster_projects` (cluster repo, `inventory/group_vars/all/projects.yml`) that stands for "something that deploys to this
cluster without being the cluster's admin": a CI pipeline, an app that redeploys itself, a webhook listener that restarts jobs. A project gets

| What | Made by | Reaches |
|---|---|---|
| a Nomad **namespace** | tofu-nomad | - |
| a Nomad **token** with a policy limited to that namespace | tofu-nomad | jobs and the variables of its jobs in its namespace, read of nodes; nothing else |
| optionally a Consul token (`consul_rules`) | tofu-consul | what the policy you write allows |
| a **VPN device** `project-<name>` (once, by hand) | `task project:vpn` | `nomad-api.<zone>` and `consul-api.<zone>`, nothing else |

The global tokens (`deployer`, `readonly`, `ui`, the ops token) are not touched. `deployer` still has `namespace "*"` and is what the first deploy, manual
deployments and the like use. Projects are an addition for everything that should hold less than that.

```yaml
# inventory/group_vars/all/projects.yml
cluster_projects:
  nextcloud:
    namespace: nextcloud            # default: the name
    host_volumes: [nextcloud-data]  # host volumes its jobs may mount; none by default (names from cluster_host_volumes)
    extra_capabilities: []          # on top of the default set below
  outline: {}
  hooks:                            # a webhook listener that redeploys other projects: it holds THEIR tokens, see below
    consul_rules: |                 # optional: a Consul ACL policy; with it the project also gets a Consul token
      service_prefix "" { policy = "read" }
```

`task deploy:ansible` creates the namespaces, policies and tokens. `task projects` lists them.

## What the token allows

In the project's namespace: `submit-job`, `read-job`, `list-jobs`, `dispatch-job`, `read-logs`, `read-job-scaling`, `scale-job`, `alloc-lifecycle`,
`csi-mount-volume`, plus the Nomad variables below `nomad/jobs/*` (read, write, list, destroy). Globally: read of nodes. Not allowed: `alloc-exec` (a shell
in a container; add it in `extra_capabilities` if you want it), other namespaces, ACL objects, host volumes that are not listed, the agent, operator.

**A project token with `submit-job` is, for practical purposes, root on the nodes its jobs run on.** Do not give one to anyone you would not give a shell to.
The ACL decides what a token may do to Nomad; what a *container* may do is decided by its task config, and Nomad's open source docker driver
refuses only some of the dangerous options. Tried against this platform with a project token:

| In the job's `docker` config | Result |
|---|---|
| `privileged = true` | refused (plugin default) |
| `cap_add = ["sys_admin"]` | refused (`allow_caps`) |
| `pid_mode = "host"` | refused |
| `network_mode = "host"` | **runs**: the container firewall does not apply, the node's own services (sshd, the agents' ports) are reachable |
| `devices = [{host_path = ...}]` | **runs**: any host device, e.g. a raw disk |
| `security_opt = ["seccomp=unconfined"]` | **runs** |

Host volumes are the one mount the ACL does decide (hence `host_volumes` in the project; `volumes.enabled = false` refuses other bind mounts). The ways to
contain the rest are structural and not part of the platform: project jobs on their own node pool (`node_pool_config` of the namespace, nodes you can lose), or a
Docker authorization plugin that refuses these options. Clusters here are run by one admin, so projects are meant for your own CI and apps.

Variables are namespaced in Nomad, so the variables of a project's jobs are separate from those of every other project without a rule for it.

## Tokens do not change by themselves

A token is created once and stays. It is replaced only when the project is removed from `cluster_projects`, when the tofu state is lost (a rebuilt
cluster restored with `task restore` brings the old tokens back with the snapshot; a rebuild *without* the matching state mints new ones), or on purpose:

```
task project:rotate -- nextcloud     # marks the tokens; the old ones stop working with the next deploy
task deploy:ansible
task project:export -- nextcloud ... # and update every place that holds them
```

## Getting the access to the project

The tokens live in the encrypted tofu state (`state/tofu-nomad`, `state/tofu-consul`) and nowhere else. Three commands read them:

| Command | For | Output |
|---|---|---|
| `task project:token -- <name>` (`--consul`) | a person who needs to look at it | the secret on stdout, nothing else |
| `task project:export -- <name> --age <recipient>` | sending the access to someone through a channel you do not trust | `secrets/projects/<name>-<cluster>.tar.age` (git-ignored); `--armor` for text, `--stdout`, `--out FILE`; `--age` can be repeated |
| `task project:export -- <name> --plain` | pasting into the secret store of a CI | the same bundle, base64, on stdout, **not encrypted** |

The **bundle** is a tar with one directory, `<name>-<cluster>/`:

```
nomad.token  [consul.token]        the secrets
connect.sh  disconnect.sh          VPN up / down without installing anything (below)
connect.env  ca.pem                parameters, the cluster root CA
client.pem  client.key             the wstunnel client certificate (CN = project-<name>)
ci/wg-<cluster>.conf               the wireguard config for connect.sh
wg-<cluster>.conf  wstunnel@.service  wstunnel-wg-<cluster>.env  install.sh  nm-install.sh   the persistent variant (systemd / NetworkManager)
README.txt
```

The recipient is an age public key (`age-keygen`, `age1...`) or an SSH public key. The receiver unpacks with `age -d -i key.txt file.tar.age | tar -x`.
`--age` is about the **way** the bundle travels (email, chat, a ticket): it is not a storage format for a CI. A CI has to decrypt it with a private
key, and that key would sit in the CI's secret store: the same exposure as the token itself, one step further away. For a CI put the bundle (`--plain`) or
the single files into its secret store directly; the store encrypts it and masks it in the logs.

## The VPN device: the way in from outside

Anything outside the cluster (a GitHub or Forgejo runner, a server of a third party) reaches the Nomad and Consul API through the same VPN as the admin
devices: WireGuard over wstunnel on tcp/443 (`docs/reference.md`, "Internal services behind a VPN"). A project gets its own device:

```
task project:vpn -- nextcloud      # key pair, preshared key, address in the project half, certificate (1 year), files in secrets/vpn/project-nextcloud/
task deploy:ansible                # the server learns the peer
task project:export -- nextcloud --age age1...
```

**Two halves of the address space.** The VPN subnet (a `/24`) is split: people's devices (`task vpn:client`) get `.2` to `.127`, project devices
(`task project:vpn`) `.128` to `.254` (`cluster_vpn_project_first`). The address is the scope of the ops UIs, and it is enforced twice. People use the two API names for the command line as well (`NOMAD_ADDR=https://nomad-api.<zone>` with a token of theirs); `task proxy:*` remains the way to use the web UI's login:

| | people's half | project half |
|---|---|---|
| `nomad.<zone>`, `consul.<zone>`, `traefik.<zone>` | yes, behind authelia-internal (2FA) | **no** (traefik `ipAllowList` `admin-net`) |
| `nomad-api.<zone>`, `consul-api.<zone>` | yes, **no second factor** (for the command line) | yes, **no second factor** |

`nomad-api.` and `consul-api.` have no login in front of them: the gate is the WireGuard key of the device (plus its client certificate for the
disguise), and then the ACL token, which Nomad and Consul check on every request. Authelia-internal lets these two names pass for both halves
(`authelia_internal_access_rules`, rule with `networks`), Traefik additionally allows only VPN addresses to reach them (`api-net`). A request
without a token gets nothing from Nomad or Consul. These two names use the default TLS option (TLS 1.3, any key exchange), the ops UIs `pq-only`:
runners have a curl that is older than OpenSSL 3.5, and the traffic is inside WireGuard (with a preshared key) anyway.

The order matters when you test it: Authelia-internal runs first on every name of the VPN entry point, so a project device that asks for `nomad.<zone>`
gets Authelia's redirect to the login (302), not a 403; the allow-list would answer only after a successful login. It cannot get that far without
a second factor of a person.

**People on the command line.** A people's device (`task vpn:client -- <device>`, which also writes `connect.sh` / `disconnect.sh`, or `install.sh` for a
machine you keep) reaches the same two names: `export NOMAD_ADDR=https://nomad-api.<zone> NOMAD_CACERT=ca.pem NOMAD_TOKEN=...`. Which token is yours to
choose: `deployer` / `readonly` / `ui` from `task tofu:enc -- tofu-nomad output -json nomad_tokens`, or a project's. The web UI and `task proxy:*` keep
the login with the second factor.

Revoking is removing the WireGuard peer: `task project:revoke -- <name>` then `task deploy:ansible`. The tokens stay valid until you remove the project
or rotate them, so do both when a project is gone for good. The device certificate lives a year (`cluster_vpn_client_valid_days`); `task smoke`
warns before it expires. `task project:vpn -- <name>` again gives a new one (key pair and address stay); export again.

## Using it: `connect.sh` / `disconnect.sh`

No installation, no systemd, no resolver changes. `connect.sh` starts wstunnel in the background, brings up the WireGuard interface (`wg-<cluster>`, route
to the VPN server address only), writes `nomad-api.<zone>` and `consul-api.<zone>` into `/etc/hosts`, checks the whole way (`/v1/status/leader` through
the tunnel) and sets

```
NOMAD_ADDR=https://nomad-api.<zone>      NOMAD_CACERT=<dir>/ca.pem      NOMAD_TOKEN=...
CONSUL_HTTP_ADDR=https://consul-api.<zone>   CONSUL_CACERT=...         CONSUL_HTTP_TOKEN=...   (only with a consul token)
```

`disconnect.sh` undoes all of it (wireguard down, wstunnel stopped, `/etc/hosts` lines removed, state removed) and **deletes the key files and the
tokens next to it**; `--keep-files` leaves them (a machine you use again). It can be run twice and after a failed `connect.sh`, which also cleans up after itself.

`connect.sh` keeps its state (the environment file, the process id) in `$RUNNER_TEMP`, else `$XDG_RUNTIME_DIR`, else `/dev/shm` (override: `CONNECT_DIR`).
`/dev/shm` is last because systemd-logind (`RemoveIPC`, the Ubuntu default) deletes the files of a user there when the last login session ends; a runner
service keeps its session, an `ssh host 'bash connect.sh'` followed by another `ssh` does not. WireGuard's configuration is copied to
`/etc/wireguard/<interface>.conf` for the time the VPN is up (a confined `wg-quick`, as on Ubuntu 26.04, cannot read it from elsewhere); `disconnect.sh` removes it.

What the runner needs: root or `sudo`, `wireguard-tools` and the WireGuard kernel module (in a container: `--cap-add NET_ADMIN` and the module of the host),
and either a `wstunnel` binary (`WSTUNNEL_BIN`, or in `PATH`), or `docker` (the pinned image is used with `--network host`; run through `sudo` when you are not root), or `curl` (the pinned release is
downloaded; set `WSTUNNEL_SHA256` to have it checked). `curl` is used for the check.

### GitHub Actions

The secret `CLUSTER_ACCESS` holds the output of `task project:export -- <name> --plain`.

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production              # secrets of an environment: only this job can read them
    steps:
      - uses: actions/checkout@v4
      - name: Cluster access
        run: |
          sudo apt-get install -y wireguard-tools
          d=$RUNNER_TEMP/cluster; mkdir -p "$d"
          printf '%s' "${{ secrets.CLUSTER_ACCESS }}" | base64 -d | tar -x -C "$d" --strip-components=1
          bash "$d/connect.sh"           # NOMAD_ADDR / NOMAD_TOKEN ... are in the environment of the next steps, the token is masked
      - run: nomad job run -namespace=nextcloud nextcloud.nomad.hcl
      - name: Cluster access down
        if: always()
        run: bash "$RUNNER_TEMP/cluster/disconnect.sh"
```

Forgejo Actions is the same (it understands `GITHUB_ENV` and `::add-mask::`); the runner must be able to bring up a WireGuard interface, i.e. a VM or
privileged container runner, not an unprivileged container.

### A job inside the cluster

A webhook listener or a redeploy script that **runs in the cluster needs no VPN**: it talks to Nomad directly and only needs a token. Put the token(s) into
a Nomad variable that only that job reads; the platform does not know about it and does not need to:

```
nomad var put -namespace=hooks nomad/jobs/webhook \
    nextcloud="$(task project:token -- nextcloud)" outline="$(task project:token -- outline)"
```

A job can read `nomad/jobs/<its own name>` (`template { ... {{ with nomadVar "nomad/jobs/webhook" }} ... }`) and, in its own task group, give each task
only the tokens it needs. One listener may hold many projects' tokens; the token of a project is the most it can do to that project. If the listener
is itself a project (`hooks` above), its own token does not need to reach the others, it only holds theirs.

## Commands

| Command | What |
|---|---|
| `task projects` | name, namespace, whether the tokens exist, the VPN device |
| `task project:vpn -- <name>` | the VPN device (then `task deploy:ansible`) |
| `task project:token -- <name> [--consul]` | the secret on stdout |
| `task project:export -- <name> --age <r> [--armor\|--stdout\|--out F]` or `--plain` | the bundle |
| `task project:rotate -- <name>` | replace the tokens with the next deploy |
| `task project:revoke -- <name>` | remove the VPN device |
| `task vpn:list` | all devices; column `project` / `people` |

## Variables

`cluster_projects` (above), `cluster_vpn_project_first` (128), `cluster_vpn_admin_net` / `cluster_vpn_project_net` (derived from `cluster_vpn_subnet`,
which must be a `/24`). Nothing else: the names are `nomad-api.<cluster_internal_zone>` and `consul-api.<cluster_internal_zone>`.

## Not done (ideas)

* A device per CI *and* a token per pipeline: today a project is one namespace, one token, one device. Several pipelines of a project share them.
* No exchange of a CI's OIDC token for a short-lived Nomad token (a Nomad `JWT` auth method with a binding rule per repository): it would remove the
  stored token altogether, but the runner needs the VPN anyway and Forgejo's OIDC support depends on its version.
* `task smoke` does not test the two API names yet.
