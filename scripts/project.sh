#!/usr/bin/env bash
# Projects: scoped access for CI and third party apps (docs/projects.md). A project is an entry of cluster_projects in the cluster repo; tofu-nomad
# (and tofu-consul, with consul_rules) mint its tokens, the VPN device is made here. Inside the tools container, via `task project:*`.
#   project.sh list                       the projects, their token and VPN device
#   project.sh token <name> [--consul]    print the nomad (or consul) token on stdout
#   project.sh vpn <name>                 the VPN device `project-<name>` (project half of the subnet); then task deploy:ansible
#   project.sh export <name> --age <recipient> [--age ...] [--out FILE] [--armor] [--stdout]
#   project.sh export <name> --plain      the same bundle as base64 on stdout, NOT encrypted: for pasting into the secret store of a CI
#                                         (the store encrypts it; `--age` is for sending it through a channel you do not trust)
#                                         bundle = tar: nomad.token [consul.token], the device files (wireguard, wstunnel certificate, connect.sh / disconnect.sh), README
#   project.sh rotate <name>              mark the tokens for replacement (the next deploy makes new ones; export again and update the CI)
#   project.sh revoke <name>              remove the VPN device (the tokens go when the project is removed from cluster_projects and deployed)
set -euo pipefail
CLUSTER_DIR=${CLUSTER_DIR:-/work}
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "$CLUSTER_DIR"
cd "$CLUSTER_DIR"
BASE=$CLUSTER_DIR/base

die() { echo "project: $*" >&2; exit 1; }
valid_name() { [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,21}$ ]] || die "project names: lowercase letters, digits, - (at most 22 characters)"; }

# cluster_projects as json ({} when there is none)
projects_json() {
  ANSIBLE_LOAD_CALLBACK_PLUGINS=1 ANSIBLE_STDOUT_CALLBACK=ansible.builtin.json ansible localhost -m ansible.builtin.debug -a "var=cluster_projects" 2>/dev/null \
    | sed -n '/^{$/,/^}$/p' | jq -c '.plays[0].tasks[0].hosts.localhost.cluster_projects // {}'
}
need_project() { projects_json | jq -e --arg n "$1" 'has($n)' >/dev/null || die "no project $1 in cluster_projects (inventory/group_vars/all/projects.yml); add it and run task deploy:ansible"; }
# token <root> <output> <name>: the secret id out of the encrypted state, empty if none
token_of() { "$BASE/scripts/tofu-enc.sh" "$1" output -json "$2" 2>/dev/null | jq -r --arg n "$3" '.[$n] // empty'; }

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  list)
    projects=$(projects_json)
    [ "$(jq 'length' <<<"$projects")" -gt 0 ] || { echo "no projects (cluster_projects is empty)"; exit 0; }
    nt=$("$BASE/scripts/tofu-enc.sh" tofu-nomad output -json project_tokens 2>/dev/null || echo '{}')
    ct=$("$BASE/scripts/tofu-enc.sh" tofu-consul output -json project_tokens 2>/dev/null || echo '{}')
    devs=$("$BASE/scripts/vpn.sh" list 2>/dev/null || true)
    { printf 'PROJECT\tNAMESPACE\tNOMAD TOKEN\tCONSUL TOKEN\tVPN DEVICE\n'
    jq -r 'to_entries[] | [.key, (.value.namespace // .key)] | @tsv' <<<"$projects" | while IFS=$'\t' read -r n ns; do
      printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$ns" \
        "$(jq -r --arg n "$n" 'if has($n) then "yes" else "no (deploy)" end' <<<"$nt")" \
        "$(jq -r --arg n "$n" 'if has($n) then "yes" else "-" end' <<<"$ct")" \
        "$(awk -v d="project-$n" '$1 == d { print $2 }' <<<"$devs" | grep . || echo "- (task project:vpn -- $n)")"
    done; } | { column -t -s "$(printf '\t')" 2>/dev/null || cat; }
    ;;

  token)
    name=${1:?project name}; valid_name "$name"; shift
    if [ "${1:-}" = "--consul" ]; then t=$(token_of tofu-consul project_tokens "$name"); else t=$(token_of tofu-nomad project_tokens "$name"); fi
    [ -n "$t" ] || die "no token for $name yet (is it in cluster_projects, and was it deployed? consul tokens need consul_rules)"
    echo "project: the secret of $name goes to stdout, keep it out of logs" >&2
    printf '%s\n' "$t"
    ;;

  vpn)
    name=${1:?project name}; valid_name "$name"; need_project "$name"
    exec "$BASE/scripts/vpn.sh" client "project-$name" --project
    ;;

  revoke)
    name=${1:?project name}; valid_name "$name"
    "$BASE/scripts/vpn.sh" revoke "project-$name"
    echo "the tokens of $name stay valid until the project is removed from cluster_projects and the next deploy (or: task project:rotate)"
    ;;

  rotate)
    name=${1:?project name}; valid_name "$name"; need_project "$name"
    "$BASE/scripts/tofu-enc.sh" tofu-nomad taint "nomad_acl_token.project[\"$name\"]"
    if [ -n "$(token_of tofu-consul project_tokens "$name")" ]; then "$BASE/scripts/tofu-enc.sh" tofu-consul taint "consul_acl_token.project[\"$name\"]"; fi
    echo "marked: task deploy:ansible makes new tokens for $name, then task project:export -- $name ... and update every place that holds them"
    ;;

  export)
    name=${1:?project name}; valid_name "$name"; need_project "$name"; shift
    recipients=(); out=""; armor=""; stdout=""; plain=""
    while [ $# -gt 0 ]; do
      case $1 in
        --age) recipients+=(-r "${2:?--age needs a recipient (age1... or an ssh public key)}"); shift 2 ;;
        --out) out=${2:?--out needs a file}; shift 2 ;;
        --armor) armor=-a; shift ;;
        --stdout) stdout=1; shift ;;
        --plain) plain=1; shift ;;
        *) die "unknown option $1" ;;
      esac
    done
    [ -n "$plain" ] || [ ${#recipients[@]} -gt 0 ] || die "give --age <recipient> (encrypted, the way to send it to someone) or --plain (base64 for the secret store of a CI)"
    [ -z "$plain" ] || [ ${#recipients[@]} -eq 0 ] || die "--age and --plain exclude each other"
    dev=secrets/vpn/project-$name
    [ -d "$dev" ] || die "no VPN device yet: task project:vpn -- $name"
    nt=$(token_of tofu-nomad project_tokens "$name"); [ -n "$nt" ] || die "no nomad token for $name yet (task deploy:ansible)"
    ct=$(token_of tofu-consul project_tokens "$name")
    cluster=$(cvar cluster_name); zone=$(cvar cluster_internal_zone)
    umask 077
    work=$(mktemp -d /dev/shm/project.XXXXXX); trap 'rm -rf "$work"' EXIT
    top=$work/$name-$cluster; mkdir -p "$top"
    cp -a "$dev"/. "$top"/
    printf '%s\n' "$nt" > "$top/nomad.token"
    [ -z "$ct" ] || printf '%s\n' "$ct" > "$top/consul.token"
    cat > "$top/README.txt" <<EOF
Access of project $name to the cluster $cluster (made $(date -u +%FT%TZ)).

  bash connect.sh      VPN up, no installation: wstunnel + wireguard (root or sudo, wireguard-tools, wstunnel or docker). Sets NOMAD_ADDR, NOMAD_CACERT,
                       NOMAD_TOKEN$([ -z "$ct" ] || echo ", CONSUL_HTTP_ADDR, CONSUL_HTTP_TOKEN") (on GitHub / Forgejo Actions into the environment of the next steps)
  nomad job run ...    https://nomad-api.$zone , the token only reaches the namespace $(projects_json | jq -r --arg n "$name" '.[$n].namespace // $n')
  bash disconnect.sh   VPN down, processes stopped, key files and tokens deleted. Put it in an "always" step.

On a machine you keep: sudo sh install.sh (systemd; see the files). The token and the keys are secrets: keep them in the secret store of your CI.
Documentation: docs/projects.md of the platform.
EOF
    find "$top" -type f -exec chmod 600 {} +; chmod 755 "$top"/*.sh
    if [ -n "$plain" ]; then
      tar -C "$work" -cf - "$name-$cluster" | base64 -w0; echo
      echo "project: that was the bundle as base64 (unencrypted). Unpack: base64 -d | tar -x" >&2
    else
      [ -n "$out" ] || out=secrets/projects/$name-$cluster.tar.age$([ -n "$armor" ] && echo .txt)
      if [ -n "$stdout" ]; then
        tar -C "$work" -cf - "$name-$cluster" | age "${recipients[@]}" $armor
      else
        mkdir -p "$(dirname "$out")"
        tar -C "$work" -cf - "$name-$cluster" | age "${recipients[@]}" $armor > "$out"
        echo "written $out (age encrypted). Decrypt: age -d -i <identity> $(basename "$out") | tar -x" >&2
      fi
    fi
    ;;

  *) echo "usage: $0 list | token <name> [--consul] | vpn <name> | export <name> (--age <recipient> | --plain) | rotate <name> | revoke <name>" >&2; exit 2 ;;
esac
