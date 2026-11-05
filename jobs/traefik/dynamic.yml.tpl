{{- $resolver := env "TPL_TLS_RESOLVER" }}
{{- $host := "127.0.0.1" }}{{ if eq (env "TPL_WIREGUARD") "true" }}{{ $host = env "NOMAD_HOST_IP_https" }}{{ end }}
http:
  routers:
    # Nomad: everything goes through authelia. A request that brings a nomad token of its own (X-Nomad-Token header) is passed on as it is;
    # one without gets the read-only token of the "ui" policy (nodes and jobs) added, so the web ui can look without a nomad login.
    nomad:
      entryPoints: [websecure]
      middlewares: [authelia@consulcatalog]
      service: nomad
      rule: Host(`nomad.{{ env "TPL_DOMAIN" }}`) && HeaderRegexp(`X-Nomad-Token`, `.+`)
      priority: 200
      tls: { {{ with $resolver }}certResolver: {{ . }}{{ end }} }
    nomad-ui:
      entryPoints: [websecure]
      middlewares: [authelia@consulcatalog, nomad-ui-token]
      service: nomad
      rule: Host(`nomad.{{ env "TPL_DOMAIN" }}`)
      priority: 100
      tls: { {{ with $resolver }}certResolver: {{ . }}{{ end }} }
    consul:
      entryPoints: [websecure]
      middlewares: [authelia@consulcatalog]
      service: consul
      rule: Host(`consul.{{ env "TPL_DOMAIN" }}`)
      tls: { {{ with $resolver }}certResolver: {{ . }}{{ end }} }
    # The names of the local proxy (`task proxy:up`): same services behind the same authelia login, but a hybrid post-quantum key exchange
    # is the ONLY one accepted (tls option pq-only). No web ui token: a cli request brings the token of its own.
    nomad-cli:
      entryPoints: [websecure]
      middlewares: [authelia@consulcatalog]
      service: nomad
      rule: Host(`nomad-cli.{{ env "TPL_DOMAIN" }}`)
      tls: { options: pq-only{{ with $resolver }}, certResolver: {{ . }}{{ end }} }
    consul-cli:
      entryPoints: [websecure]
      middlewares: [authelia@consulcatalog]
      service: consul
      rule: Host(`consul-cli.{{ env "TPL_DOMAIN" }}`)
      tls: { options: pq-only{{ with $resolver }}, certResolver: {{ . }}{{ end }} }
    traefik:
      entryPoints: [websecure]
      middlewares: [authelia@consulcatalog]
      service: api@internal
      rule: Host(`traefik.{{ env "TPL_DOMAIN" }}`)
      tls: { {{ with $resolver }}certResolver: {{ . }}{{ end }} }
  middlewares:
    nomad-ui-token:
      headers:
        customRequestHeaders:
          X-Nomad-Token: "{{ with nomadVar "nomad/jobs/traefik" }}{{ .nomad_ui_token }}{{ end }}"
  serversTransports:
    cluster-ca:
      rootCAs: [/secrets/ca.pem]
  services:
    nomad:
      loadBalancer:
        passHostHeader: false
        serversTransport: cluster-ca
        servers:
          - url: https://{{ $host }}:{{ env "TPL_NOMAD_PORT" }}
    consul:
      loadBalancer:
        passHostHeader: false
        serversTransport: cluster-ca
        servers:
          - url: https://{{ $host }}:{{ env "TPL_CONSUL_PORT" }}
tls:
  # applies to every router without options of its own (the file routers above and authelia's)
  options:
    default:
      # TLS 1.3 only (its cipher suites are fixed, there is nothing to list)
      minVersion: VersionTLS13
    # the local proxy's uplink: only the hybrid post-quantum key exchange (X25519 + ML-KEM-768); a client without it cannot connect
    pq-only:
      minVersion: VersionTLS13
      curvePreferences:
        - X25519MLKEM768
{{- if not $resolver }}
  stores:
    default:
      defaultCertificate:
        certFile: /secrets/ingress.pem
        keyFile: /secrets/ingress.key
{{- end }}
