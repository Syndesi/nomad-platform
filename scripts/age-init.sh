#!/usr/bin/env bash
# Host side, run once by `task age:init`: create the age identity that sops uses and write the public
# recipient into .sops.yaml. The private key stays OUTSIDE the encrypted files: here in
# $AGE_KEY_DIR (default ./secrets/age, gitignored), for real clusters in a password manager plus an
# offline copy. More recipients (a second admin, an offline key) can be added to .sops.yaml by hand;
# then `sops updatekeys` re-encrypts the files for them.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "${CLUSTER_DIR:-.}"
cd "${CLUSTER_DIR:-.}"
dir=${AGE_KEY_DIR:-./secrets/age}
mkdir -p "$dir"
# The service of the tools container mounts the key dir read-only (and a -v of `run` cannot override that), so the key is made by a
# one-off container of the same service (no image guessing, same tools) and only travels through stdout/stdin; the file is written here.
tools() { docker compose run --rm --no-deps -T tools "$@"; }  # COMPOSE_FILE etc. come from the cluster .env
if [ ! -s "$dir/keys.txt" ]; then
  (umask 077; tools age-keygen > "$dir/keys.txt.new") && mv "$dir/keys.txt.new" "$dir/keys.txt"
  echo "created $dir/keys.txt" >&2
fi
pub=$(tools age-keygen -y < "$dir/keys.txt")
if [ -e .sops.yaml ]; then
  echo ".sops.yaml exists, recipient in it: $(grep -o 'age1[a-z0-9]*' .sops.yaml | head -1)"
  [ "$(grep -o 'age1[a-z0-9]*' .sops.yaml | head -1)" = "$pub" ] || { echo "WARNING: it differs from the key in $dir ($pub)" >&2; exit 1; }
  exit 0
fi
cat > .sops.yaml <<YAML
---
# Who can decrypt the *.sops.yml files of this cluster repo: public age recipients (the private keys are not in this repo).
creation_rules:
  - path_regex: \.sops\.ya?ml\$
    age: $pub
YAML
echo "wrote .sops.yaml (recipient $pub)"
