#!/bin/sh
# Entrypoint of the tools image. The container runs as the host user (compose `user:`), whose uid has no passwd entry; ssh refuses
# to run without one. Add the entry, then run the command. It is an entrypoint (not part of the compose command) so that
# `docker compose run` and `exec`-started shells of a fresh container get the same environment.
set -eu
uid=$(id -u)
grep -q "^[^:]*:[^:]*:$uid:" /etc/passwd || echo "tools:x:$uid:$(id -g)::/tmp:/bin/bash" >> /etc/passwd
exec "$@"
