#!/bin/sh
# Prepare a node for the platform, ONCE, as root, by hand (or by cloud-init): after this ansible can log in over ssh
# as an unprivileged user and become root through sudo (ubuntu/debian) or doas (alpine). Everything else - hardening
# sshd, packages, the cluster - is done by ansible afterwards.
#
#   sh node-bootstrap.sh <user> '<public ssh key>' ['<public ssh key>' ...]
#
# `task ssh:bootstrap-cmd` prints this command with the right user and key. Safe to run again.
# It installs: openssh (server), python3 (ansible modules), sudo or doas, and creates <user> without a usable
# password (login is by key only) with passwordless privilege escalation.
set -eu

user=${1:?usage: node-bootstrap.sh <user> <public key> [<public key> ...]}
shift
[ $# -ge 1 ] || { echo "at least one public key is required" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

# random password nobody knows: some systems refuse key logins for locked accounts
randpw() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

. /etc/os-release
case "$ID" in
  alpine)
    apk add --no-cache openssh python3 doas >/dev/null
    id "$user" >/dev/null 2>&1 || adduser -D -s /bin/sh "$user"
    echo "$user:$(randpw)" | chpasswd
    # alpine's doas: /etc/doas.d/ when the package ships it, else /etc/doas.conf
    if [ -d /etc/doas.d ]; then rules=/etc/doas.d/10-cluster-$user.conf; else rules=/etc/doas.conf; fi
    grep -qxs "permit nopass $user" "$rules" || echo "permit nopass $user" >> "$rules"
    chmod 0400 "$rules"
    rc-update add sshd default >/dev/null 2>&1 || true
    rc-service sshd start >/dev/null 2>&1 || true
    ;;
  debian | ubuntu)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq openssh-server sudo python3 >/dev/null
    id "$user" >/dev/null 2>&1 || useradd -m -s /bin/bash "$user"
    echo "$user:$(randpw)" | chpasswd
    echo "$user ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/10-cluster-$user"
    chmod 0440 "/etc/sudoers.d/10-cluster-$user"
    visudo -cf "/etc/sudoers.d/10-cluster-$user" >/dev/null
    systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
    ;;
  *)
    echo "unsupported OS '$ID' (alpine, debian, ubuntu)" >&2
    exit 1
    ;;
esac

home=$(getent passwd "$user" | cut -d: -f6)
mkdir -p "$home/.ssh"
: > "$home/.ssh/authorized_keys"
for key in "$@"; do echo "$key" >> "$home/.ssh/authorized_keys"; done
chmod 700 "$home/.ssh"
chmod 600 "$home/.ssh/authorized_keys"
chown -R "$user:$(id -gn "$user")" "$home/.ssh"
echo "node ready: ssh $user@$(hostname)"
