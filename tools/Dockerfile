# The tool image (Alpine based), built from the base repo (build context = its root) and SHARED by all clusters:
# same software version everywhere, the cluster repo is mounted at /work when the container starts.
#  - tofu          pinned binary copied from the official image. That image must not be used
#                  as a FROM stage (its ONBUILD trigger fails since 1.10), so compose passes it
#                  in as the named build context "tofu".
#  - incus CLI     only used by clusters that live on incus (their compose.override.yml mounts the config)
#  - ansible-core  + pinned collections from ansible/requirements.yml (baked in, no runtime downloads)
#  - openssh-client  ansible and the scripts reach the nodes over ssh
#  - openssl + py3-cryptography  cluster CA / leaf certs (scripts/pki.sh, community.crypto)
#  - socat         tcp tunnel to the consul/nomad api of a node (scripts/tunnel.sh) for the tofu-consul / tofu-nomad stages
#  - sops + age    secrets at rest (ansible reads them through community.sops, tofu state encryption gets its passphrase from them)
#  - ansible-lint, yamllint, shellcheck   `task lint` (nomad fmt runs the built nomad binary from /artifacts)
#  - bash, jq, curl for ad-hoc work inside `task shell`
# no default: compose passes it from the cluster's .env
ARG ALPINE_VERSION
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache ansible-core bash ca-certificates curl incus-client jq openssl py3-cryptography socat \
    sops age ansible-lint yamllint shellcheck openssh-client
COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu

ENV ANSIBLE_COLLECTIONS_PATH=/opt/ansible/collections
COPY ansible/requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -p /opt/ansible/collections -r /tmp/requirements.yml \
 && ansible-galaxy role install -p /opt/ansible/roles -r /tmp/requirements.yml \
 && rm /tmp/requirements.yml

# The container runs as the host user (compose `user:`), whose uid has no passwd entry; ssh refuses to run without one.
# compose mounts a read-only /etc/passwd with that entry (the `passwd` config in compose.yml): the file stays root-owned and 644 here.
COPY tools/entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# The compose service keeps this shell alive with tty + stdin_open (the `docker run -it` idiom); `docker compose exec` is used for the work.
CMD ["bash"]

WORKDIR /work
