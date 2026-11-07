#!/usr/bin/env bash
# The key material of the step-ca job (the always-online intermediate CA behind the VPN's certificates). Runs in the tools container, via `task stepca:*`.
#   stepca.sh init     the password, the keys of the two JWK provisioners (services, clients) and the intermediate key encrypted with the password;
#                      inventory/group_vars/all/stepca-material.sops.yml (sops/age). Safe to repeat: existing passwords and provisioner keys stay,
#                      the encrypted key is made again from the current intermediate (pki.sh intermediate stepca calls this after a replacement).
#   stepca.sh check    exit 0 when the material exists
# The intermediate itself (certificate, plain key) comes from `task pki:ca` / `pki.sh intermediate stepca`; the root key never leaves the offline place.
set -euo pipefail
CLUSTER_DIR=${CLUSTER_DIR:-/work}
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_cluster_repo "$CLUSTER_DIR"
cd "$CLUSTER_DIR"
FILE=inventory/group_vars/all/stepca-material.sops.yml
KEY_FILE=inventory/group_vars/all/stepca.sops.yml
die() { echo "stepca: $*" >&2; exit 1; }

case "${1:-}" in
  check) [ -e "$FILE" ] ;;
  init)
    [ -e "$KEY_FILE" ] || die "no step-ca intermediate yet: task pki:ca (or pki:intermediate -- stepca)"
    command -v step >/dev/null || die "the step cli is missing in the tools image (rebuild: task up)"
    work=$(mktemp -d /dev/shm/stepca.XXXXXX); trap 'rm -rf "$work"' EXIT; umask 077
    if [ -e "$FILE" ]; then sops decrypt "$FILE" > "$work/old.yml"; else echo '{}' > "$work/old.yml"; fi
    # --- the intermediate key, encrypted (PKCS#8, AES-256, PBKDF2-SHA256)
    sops decrypt --extract '["cluster_stepca_intermediate_key"]' "$KEY_FILE" > "$work/int.key"
    python3 - "$work" <<'PY'
import sys, yaml, secrets, os
w = sys.argv[1]
old = yaml.safe_load(open(f"{w}/old.yml")) or {}
pw = old.get("cluster_stepca_password") or secrets.token_hex(24)
open(f"{w}/pw", "w").write(pw)
PY
    openssl pkcs8 -topk8 -v2 aes-256-cbc -v2prf hmacWithSHA256 -iter 200000 -in "$work/int.key" -passout "file:$work/pw" -out "$work/int.enc"
    # --- the provisioner keys: JWK pair per provisioner, the private half encrypted with the password (compact JWE, as ca.json wants it)
    for p in services clients; do
      if ! python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])) or {}; sys.exit(0 if (d.get("cluster_stepca_provisioners") or {}).get(sys.argv[2]) else 1)' "$work/old.yml" "$p"; then
        step crypto jwk create "$work/$p.pub.json" "$work/$p.priv.json" --kty EC --crv P-256 --use sig --password-file "$work/pw" --force >/dev/null 2>&1
      fi
    done
    python3 - "$work" <<'PY'
import sys, yaml, json, os
w = sys.argv[1]
old = yaml.safe_load(open(f"{w}/old.yml")) or {}
prov = dict(old.get("cluster_stepca_provisioners") or {})
for p in ("services", "clients"):
    if p in prov:
        continue
    pub = json.load(open(f"{w}/{p}.pub.json"))
    j = json.load(open(f"{w}/{p}.priv.json"))
    compact = ".".join([j["protected"], j.get("encrypted_key", ""), j["iv"], j["ciphertext"], j["tag"]])
    prov[p] = {"public": json.dumps(pub, separators=(",", ":")), "encrypted": compact}
out = {
    "cluster_stepca_password": open(f"{w}/pw").read(),
    "cluster_stepca_intermediate_key_enc": open(f"{w}/int.enc").read(),
    "cluster_stepca_provisioners": prov,
}
open(f"{w}/new.yml", "w").write("---\n# Key material of the step-ca job. Made by scripts/stepca.sh, sops/age encrypted.\n" + yaml.safe_dump(out, default_flow_style=False))
PY
    [ -e .sops.yaml ] || die "no .sops.yaml: run 'task age:init' first"
    sops --config .sops.yaml --encrypt --input-type yaml --output-type yaml --filename-override "$PWD/$FILE" "$work/new.yml" > "$FILE.new" && mv "$FILE.new" "$FILE"
    echo "written $FILE (encrypted)"
    ;;
  *) echo "usage: $0 init | check" >&2; exit 2 ;;
esac
