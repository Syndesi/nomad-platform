#!/usr/bin/env bash
# Host side, via `task become:password [-- remove]`: sudo (debian) and doas (alpine) ask the ansible user for a password.
# The password is stored sops-encrypted as ansible_become_password in inventory/group_vars/all/become.sops.yml, so every
# ansible run and every script that needs root (through ansible) supplies it by itself. `task deploy:ansible` applies it to the
# nodes (the first run still works passwordless: the bootstrap script made the node passwordless). `remove` only deletes the
# stored password: nodes already in password mode stay in it (see the README).
set -euo pipefail
exec_tools() { docker compose exec -T tools "$@"; }
FILE=inventory/group_vars/all/become.sops.yml
case "${1:-set}" in
  set)
    read -rsp "password for sudo/doas of the ansible user: " pw; echo
    read -rsp "again: " pw2; echo
    [ -n "$pw" ] && [ "$pw" = "$pw2" ] || { echo "empty or different passwords" >&2; exit 1; }
    case $pw in *[\"\\$\`]*|*$'\n'*) echo "please avoid the characters \" \\ \$ \` and line breaks in this password" >&2; exit 1 ;; esac
    printf -- '---\nansible_become_password: "%s"\n' "$pw" | exec_tools sh -c "cd \"\$CLUSTER_DIR\" && [ -e .sops.yaml ] && sops --config .sops.yaml --encrypt --input-type yaml --output-type yaml --filename-override \"\$PWD/$FILE\" /dev/stdin > $FILE.new && mv $FILE.new $FILE"
    unset pw pw2
    echo "stored in $FILE (encrypted). Apply it with: task deploy:ansible"
    ;;
  remove)
    rm -f "$FILE"
    echo "removed $FILE. Nodes that are in password mode stay in it: bring them back with node-bootstrap.sh on the node."
    ;;
  *) echo "usage: $0 [set|remove]" >&2; exit 2 ;;
esac
