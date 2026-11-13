# Working on nomad-platform (notes for Claude Code)

Distilled from the sessions of 2026-11-05 to 2026-11-10 (what worked, what cost hours). Read this first; `README.md` and `docs/` describe the
product, this file describes how to work on it without wasting time.

## The setup in one minute

- **This repo has no Taskfile, no inventory, no tools container.** It is the shared code (roles, jobs, scripts). Nothing runs from here.
  `task ...` here fails with `No Taskfile found`.
- **Everything runs from the test cluster: `cd ../incusos-test-cluster`** (author's setup; two incus VMs `itc-alpine` = server+ingress+client+
  monitoring, `itc-debian` = client; domain `itc.test`; its README has the test-only credentials). Its `base/` is a **copy** of this working tree.
- **Tools live in the cluster's tools container** (`itc-tools`): ansible, tofu, sops, yamllint, shellcheck, step. They are NOT on the host. "command not found:
  yamllint/tofu/ansible" means "use the container": `task lint`, `task shell`, `docker compose exec -T tools ...`, or `dev:x` (below). On the host
  you have `task`, `docker`, `incus`, `nomad` (only for `nomad fmt` / `job validate`), `jq`, `rsync`, `gum`.
- **No proxy needed.** `task proxy:up|login` (Caddy + VPN + Authelia login with a TOTP prompt) is for a human's own `nomad`/`consul` CLI. You talk to the
  cluster over ssh through the tools container, with the ops tokens (`task dev:x`). Do not try to start the proxy.

## Start of every session (30 seconds)

```sh
cd ../incusos-test-cluster
task dev:doctor            # sandbox in order? read-only.   task dev:doctor -- --fix   repairs the safe parts
```

The doctor (`dev/doctor.sh` + the cluster's `scripts/dev-doctor.sh`) checks the things that went wrong in earlier sessions: incus host
reachable (it was down for hours once), VMs running, VM memory limit applied (incus applies `limits.*` only after a VM restart), **ssh forwards
really listening** (the pid files say "up" after they died: after a reboot or at midnight), tools container up, **`base/` equal to this working
tree** (a smoke on a stale `base/` tests old code), secrets present, ssh to every node, and whether the cluster has **settled**. It exits 1 on FAIL.

## The loop

1. Edit here (`nomad-platform`). `git status` here is where your changes are; `base/` in the cluster repo shows as modified: expected, never commit it.
2. `task base:sync` (in the cluster repo). **Forgetting this is the #1 mistake**: the deploy and the smoke then run the old copy and "pass".
3. `task lint` (ansible-lint, yamllint, shellcheck, tofu fmt/validate, nomad fmt). It also checks `dev/`.
4. **Change in ONE job file? Do not run a full deploy.** `task dev:job -- <job>` puts the job file and its template dir on the server and runs it with
   the last deploy's variables; ~25 s instead of 10-30 min, stops at the first failed allocation and prints task events, stderr, placement
   failures and critical Consul checks. `--restart` if the spec is unchanged, `--file authelia` for `authelia-internal`, `--patient` to keep waiting.
   Variables from the inventory (`defaults.yml`, `cluster_jobs_list`), roles and tofu only change through a deploy.
5. Everything else: `task deploy:ansible` (10-30 min, **run in the background**, see below), then `task dev:wait`, then `task smoke -- connect`.
6. Before reporting "done": lint clean, one full deploy that exits 0, `task smoke -- connect` without FAIL, and the changed behaviour checked
   *on the node* (smoke does not know your new feature). Add checks for new behaviour to `scripts/smoke.sh` (that is the product's smoke; the
   dev tooling stays in `dev/`). Say plainly what you did not run.

Other useful tasks: `task cluster` (members, nodes, jobs, read-only), `task status`, `task backup`, `task node -- itc-debian` (one node),
`task deploy:ansible -- --limit itc-alpine,localhost` (**localhost must stay in the limit**, the token and tofu plays run there),
`task teardown` + `task deploy` = fresh install (about 7-20 min; worth it once per bigger change: it finds bugs an upgrade hides).

## Talking to the cluster: `dev:x` instead of improvising

```sh
task dev:x -- 'nomad job status; consul members'           # on the server, ansible user, ops tokens in the env (nomad, consul, curl work)
task dev:x -- -n itc-debian 'docker ps'                     # another node
task dev:x -- -r 'nft list ruleset | head'                  # root (ansible become), no tokens
../incusos-test-cluster/base/dev/x.sh <<'EOF'              # a longer script: stdin is passed as is, no quoting layer touches it
nomad job status -json authelia | jq '.LatestDeployment'
EOF
incus exec itc-alpine -- sh -c '...'                        # also fine for host level debugging (doas/openrc on alpine)
```

The ops (management) token is needed for logs and variables: the read-only token that `task cluster`/`smoke` use gets `403` on `nomad alloc logs`.
`dev:x` fetches the tokens from the encrypted tofu state each time (a few seconds). They travel on stdin, never in an argv: keep it that way (argv
shows up in `/proc`, in Tetragon's events and so in Loki).

## Waiting without wasting the session

- **A full deploy takes 10-30 min** (timing log: `.deploy-timing.log` in the cluster repo; `ansible:site` 450-1800 s). The Bash tool times out at 10 min and
  moves the command to the background; do it deliberately: `run_in_background: true`, output to a log, last line `echo EXIT $?`. Never start a second
  deploy while one runs.
- `sleep N` followed by something is **blocked** by the harness. Wait with a background command, or `Monitor` with an until-loop
  (`until grep -q '^EXIT' $log; do sleep 5; done`). `Monitor` is a deferred tool: load it with `ToolSearch select:Monitor` first, it needs a `description`.
- The completion notification of a wrapped command can fire when the *wrapper* exits, not when the deploy is done: look for your `EXIT` marker.
- `task dev:wait -- 600` blocks until the cluster has settled (prints what is still wrong whenever it changes). Run it in the background.
- `nomad job run` waits for the deployment up to `progress_deadline` (10 min) per job. A deploy that sits on one job for 10 min is a failing job, not
  a slow one: look at it (`dev:x 'nomad job status <job>'`, alloc events and logs) after 2-3 min instead of waiting for the timeout.
- `Nomad api answers (89 retries left)` lines in the deploy output are normal while nomad restarts.

## Failure modes seen, and what to do

| Symptom | Cause | Do |
|---|---|---|
| `ssh: connect to host 127.0.0.1 port 2241: Connection refused`, ansible unreachable | the `incus port-forward` processes died (reboot, new day); pid files still say up | `task ssh:forward` or `dev:doctor -- --fix` |
| `Could not resolve hostname`, `no route to host 192.168.96.16` | the incus host itself is down | nothing to repair here; tell the user. Do not loop on retries |
| smoke passes/fails "for the old code", or checks that you removed still appear | `base/` not synced | `task base:sync` |
| smoke FAILs right after a VM restart/reboot (traefik not running, `host.internal` unresolved...) | services still starting, or one-shot jobs (traefik) died while their dependencies were down | `task dev:wait`, rerun smoke; only investigate what still fails |
| FAILs in a smoke log from a *previous* run | you read an old log file | check timestamps, rerun |
| job deploy hangs 10 min then fails; re-running changes nothing | failed deployment; an unchanged spec creates no new version, no retry (`auto_revert` also hides it: the running version is the old one) | `dev:job -- <job> --restart`; `nomad job history <job>` |
| `Failed to read stdout file ... 403` | read-only token | use `dev:x` (ops token) |
| VM shows old memory/cpu after `deploy:tofu` | incus applies limits at restart | `incus restart itc-alpine`, then `dev:wait` |
| `tofu`/`ansible` ... `EOF`, connection dropped during `deploy:*` | nodes rate-limit ssh (10/min, burst 10) when the tofu state tunnel opens many connections | rerun; do not run two deploys or loops of ssh in parallel |
| `--limit` run fails with connection refused / missing tokens | `localhost` missing from the limit | `--limit <node>,localhost` |
| `task: No Taskfile found` | you are in `nomad-platform` | `cd ../incusos-test-cluster` |
| a hand edit on a node broke the service (consul down) | `sed -i` recreates the file with the editing user's owner/mode | edit with `cp -p backup`, `cat > file`, or `sed -i` then `chown --reference`; always keep a backup and restore it after the experiment |
| `sqlite3`/`jq`/`nslookup` "not found" on a node or in a container | not installed on that OS / busybox variant (alpine vs debian differ) | check both nodes; smoke checks must work on both |
| `ansible ... -a '... {{.Names}} ...'` fails with templating errors | ansible parses `{{ }}` in `-a` strings | use `dev:x` (no ansible in the path) or `docker ... --format` via a script on stdin |
| change to a test job file: `nomad job run` says unchanged | same spec | add something real, or `--restart` |

## Shells: zsh on the host, bash in the container, busybox sh on alpine

The host shell is **zsh** (the Bash tool starts it), the tools container has **bash**, alpine nodes have **busybox ash** with **`doas`** (debian: `sudo`,
GNU tools). One command often crosses all three: that is where the quoting accidents came from.

- zsh does **not word-split** `$var`: `cmd="incus exec x --"; $cmd ls` fails with `command not found: incus exec x --`. Use arrays (`cmd=(incus exec x --); $cmd[@]`), `eval`, or a
  bash script. For loops over a list in a variable use `${=var}` or run it in `bash -c`.
- zsh treats an unmatched glob as an error (`no matches found: --include=*`) and expands a word starting with `=` (`echo =====` fails). Quote globs and separators.
- zsh's `$(...)`/arrays/`[[ ]]` behave differently in small ways; anything longer than a one-liner goes into a script with `#!/usr/bin/env bash` (the repo's scripts do).
- Quoting through `docker compose exec ... bash -c '...'` + `ssh` + `sh -c` is three layers. Do not hand-quote: pipe the script on stdin (`dev:x` heredoc form),
  or put it in a file. Inside single quotes there is no way to write a `'`.
- Nested quoting on the node: busybox `ash` has no `[[`, no arrays, no `<(...)`, `date -d`/`sed -i`/`grep -P`/`ps` flags differ. Write POSIX `sh` for anything that runs on a node
  (`dev/remote/*.sh` are examples) and test on both nodes.
- Privileged on a node: `dev:x -r '...'` (ansible become), or `incus exec <vm> -- ...` (root) from the host; alpine needs `doas`, never `sudo`. Scripts in `scripts/` run
  unprivileged on the node via `cluster_exec`, and use `cluster_root` only where root is unavoidable.
- `sleep`, `watch` and polling loops in the Bash tool: see "Waiting".
- Heredocs with `'EOF'` stay literal; unquoted `EOF` lets the *local* shell expand `$vars` and backticks first (usually not what you want when the script is for the node).

## Things about this platform that cost time (read before touching these areas)

**Nomad / jobs**
- Job files are plain HCL2. `file("${var.templates_dir}/...")` runs on the machine running `nomad job run` (and the directory `/etc/cluster/jobs` is `0700`
  root); the `template` sandbox of a task only allows paths inside the allocation dir (a host path or `/alloc/...` in `file()` fails).
- Nomad renders templates as root, mode 0600: for a non-root task set `uid`/`gid` on the `template`, and mind that `secrets/` is created root-owned.
- HCL: `parseint(x, 10)`, not `tonumber`. Heredoc `${var}` is interpolated by HCL; `[[ ]]` is the delimiter for consul-template inside Vector/Gatus templates.
- A group in `bridge` mode with Connect: pause + app + Envoy share one netns. Envoy sidecars (`sidecar_task` with `runtime = "runc"`) always run on runc.
- Jobs of the platform are idempotent by design (`cluster_jobs` compares the version before and after): do not add `uuidv4()` meta tricks.
- `/etc/hosts` of a group network is written once from the first task's `extra_hosts`.

**gVisor (default docker runtime `runsc-host`)**: slow first starts (Grafana ~10 min on a busy 3-vCPU node at `cpu=300`, Outline restart ~2 min): give it time
before declaring a failure, but check the node's load first. dnsmasq needs rtnetlink and WireGuard needs real netlink: those stay on `runc`. Tetragon does not
see into sandboxes. `/proc/net/*` is empty in host-net mode; the runtime default only changes with a docker restart.

**Consul / TLS**: `tls_min_version = TLSv1_3` must NOT be on Consul's `grpc` listener (Envoy xDS breaks); the mesh `proxy-defaults` TLS entry needs **both**
min and max `TLSv1_3`, or the curves are dropped silently and sidecars die with `unexpected EOF`. BoringSSL/Envoy reject chains whose leaf has IP SANs under a CA
with IP name constraints (openssl and Go accept them): test with a real Envoy, not only openssl. `pq-only` TLS (X25519MLKEM768) needs OpenSSL 3.5 clients
(Debian 13 has OpenSSL 3.5 and OpenSSH 10.0, so it can; Ubuntu 24.04's 3.0 could not).

**Authelia**: OIDC issuer derives from the Host header (no port); ID-token claims need a `claims_policies` entry; 4.39 `storage user totp import` is an
upsert. **Do not change the `secrets/authelia/totp-*.txt` handling** (the user decided: operator risk).

**Alpine**: `dhcpcd` can rewrite `/etc/resolv.conf` and run twice (smoke checks "one dns server"); OpenRC `supervise-daemon` has `no_new_privs`; a changed nft ruleset is not
reloaded by the deploy when the file is unchanged (reload by hand when testing prototypes). Debian 13: AppArmor active (docker.io 26.1.5 from the distribution), trixie has no `systemd-resolved`, `systemd-timesyncd` or rsyslog by default (the deploy installs them), the sshd role
writes the main `/etc/ssh/sshd_config` (not a drop-in). The `Protect*` options on the Nomad unit hiding its secrets tmpfs from dockerd were found on Ubuntu 26.04 and are not re-checked on Debian.
**Reboots**: `/usr/local/sbin/cluster-reboot --check` (role `cluster_reboot`) says whether a newer kernel is installed; running it without `--check` REBOOTS the node. Debian names kernel files
`/boot/vmlinuz-<release>`, Alpine `/boot/vmlinuz-<flavor>` (no release in the name): the script only trusts names starting with a digit. `dev:x -r` goes through ansible: `{{ }}` (docker `--format`) is eaten, use `jq`.
A replaced node leaves a stale member behind (`consul force-leave -prune <old>`, `nomad system gc`) and a stale `incus port-forward` on its ssh port (`task ssh:forward` stops those now).

**Images**: tags only, no digests, no `latest` (see the memory note). Verify a tag exists on the registry before writing it down.

## Working agreements with this user

- Plans and "should I do X or Y" questions: give a recommendation with the trade-off, short. Flag any deviation from what was asked **before** implementing it.
- Do not commit unless asked. Several sessions ended with everything uncommitted in the working tree: that is expected here.
- Every behaviour change gets: docs (`docs/*.md`, cluster-template README if operators are affected), a `CHANGELOG.md` entry under the unreleased version, lint, deploy and
  smoke on the test cluster. Documentation matters to the user as much as the code.
- Security hardening is the theme of this repo; but "operator risk" decisions by the user (no secret rotation task, TOTP files, single Authelia instance, deployer token) are
  settled: do not reopen them, do not "fix" them on the side.
- Say what is verified and what is not ("parse-checked only", "not deployed"). Reports in the sessions that did this were appreciated; claims that turned out wrong were not.

## The dev tooling (`dev/`)

Not part of any deployment (no role, playbook or product task uses it); the test cluster includes `dev/Taskfile.yml` as namespace `dev:` (`optional: true`, so a stale
`base/` cannot break `task base:sync`). New dev tooling goes here, new product checks go to `scripts/smoke.sh`. After editing `dev/`, `task base:sync`.

| | |
|---|---|
| `dev/doctor.sh` | sandbox smoke test (above); calls the cluster's own `scripts/dev-doctor.sh` for its machine layer (the test cluster: incus host, VMs, memory limits, ssh forwards) |
| `dev/wait.sh`, `dev/remote/state.sh` | wait until consul/nomad/jobs have settled; state.sh prints one line per problem |
| `dev/job.sh`, `dev/remote/job-run.sh` | single-job fast loop with early failure diagnosis |
| `dev/x.sh`, `dev/remote.sh`, `dev/lib.sh` | run anything on a node with the ops tokens, no quoting layers |

Found a new time sink? Add the check to `doctor.sh` (cheap, deterministic) and a row to the table above, not just a sentence.
