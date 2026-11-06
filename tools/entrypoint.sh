#!/bin/sh
# Entrypoint of the tools image. The container runs as the host user (compose `user:`), whose uid has no passwd entry in the image; ssh
# refuses to run without one. compose.yml mounts a read-only /etc/passwd that has it, so there is nothing to write here: only say so when
# the container was started some other way (a different uid). It is an entrypoint so that `docker compose run` and exec-started shells of
# a fresh container get the same environment.
set -eu
uid=$(id -u)
grep -q "^[^:]*:[^:]*:$uid:" /etc/passwd || echo "warning: no passwd entry for uid $uid (ssh will refuse to run): start the container through compose" >&2
exec "$@"
