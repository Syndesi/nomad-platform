{{- $resolver := env "TPL_TLS_RESOLVER" }}
{{- $host := "127.0.0.1" }}{{ if eq (env "TPL_WIREGUARD") "true" }}{{ $host = env "NOMAD_HOST_IP_https" }}{{ end }}
http:
  routers:
    # The ops names (nomad, consul, traefik, and authelia's portal) accept the hybrid post-quantum key exchange and nothing else (tls option pq-only);
    # a client without it (an old browser) cannot open them. Apps keep the default option.
    # Nomad: everything goes through authelia (the default middleware of the websecure entry point, static.yml.tpl). A request that brings a nomad token of its own (X-Nomad-Token header) is passed on as it is;
    # one without gets the read-only token of the "ui" policy (nodes and jobs) added, so the web ui can look without a nomad login.
    # authelia's portal. The router, the forward-auth middleware and the service are here and not in authelia's consul tags: tags are
    # written by whoever submits a job (a second router for auth. or a second "authelia" middleware would take over the logins).
    authelia:
      entryPoints: [websecure]
      middlewares: [admin-headers]
      service: authelia
      rule: Host(`auth.{{ env "TPL_DOMAIN" }}`)
      tls: { options: pq-only{{ with $resolver }}, certResolver: {{ . }}{{ end }} }
    nomad:
      entryPoints: [websecure]
      middlewares: [admin-headers]
      service: nomad
      rule: Host(`nomad.{{ env "TPL_DOMAIN" }}`) && HeaderRegexp(`X-Nomad-Token`, `.+`)
      priority: 200
      tls: { options: pq-only{{ with $resolver }}, certResolver: {{ . }}{{ end }} }
    nomad-ui:
      entryPoints: [websecure]
      middlewares: [admin-headers, nomad-ui-token]
      service: nomad
      rule: Host(`nomad.{{ env "TPL_DOMAIN" }}`)
      priority: 100
      tls: { options: pq-only{{ with $resolver }}, certResolver: {{ . }}{{ end }} }
    consul:
      entryPoints: [websecure]
      middlewares: [admin-headers]
      service: consul
      rule: Host(`consul.{{ env "TPL_DOMAIN" }}`)
      tls: { options: pq-only{{ with $resolver }}, certResolver: {{ . }}{{ end }} }
    traefik:
      entryPoints: [websecure]
      middlewares: [admin-headers]
      service: api@internal
      rule: Host(`traefik.{{ env "TPL_DOMAIN" }}`)
      tls: { options: pq-only{{ with $resolver }}, certResolver: {{ . }}{{ end }} }
  middlewares:
    # The default middleware of the websecure entry point (static.yml.tpl). Authelia runs on the node TPL_AUTHELIA_ADDR (cluster address and
    # port, https with its node certificate that the cluster CA signed).
    authelia:
      forwardAuth:
        address: https://{{ env "TPL_AUTHELIA_ADDR" }}/api/authz/forward-auth
        tls:
          ca: /secrets/ca.pem
        trustForwardHeader: true
        # only what authelia needs: the session cookie, the forwarding headers and Accept / X-Requested-With (without them authelia answers 401
        # instead of a redirect). By default traefik copies ALL request headers, i.e. also X-Nomad-Token / X-Consul-Token of command line tools.
        authRequestHeaders: [Cookie, Accept, X-Requested-With, X-Forwarded-For, X-Forwarded-Proto, X-Forwarded-Host, X-Forwarded-Uri, X-Forwarded-Method]
        authResponseHeaders: [Remote-User, Remote-Groups, Remote-Name, Remote-Email]
    # the ops names: HSTS and the usual browser headers (the apps set their own)
    admin-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        forceSTSHeader: true
        contentTypeNosniff: true
        frameDeny: true
        referrerPolicy: no-referrer
    nomad-ui-token:
      headers:
        customRequestHeaders:
          X-Nomad-Token: "{{ with nomadVar "nomad/jobs/traefik" }}{{ .nomad_ui_token }}{{ end }}"
  serversTransports:
    cluster-ca:
      rootCAs: [/secrets/ca.pem]
  services:
    authelia:
      loadBalancer:
        passHostHeader: true
        serversTransport: cluster-ca
        servers:
          - url: https://{{ env "TPL_AUTHELIA_ADDR" }}
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
    # the ops names: only the hybrid post-quantum key exchange (X25519 + ML-KEM-768); a client without it cannot connect
    pq-only:
      minVersion: VersionTLS13
      curvePreferences:
        - X25519MLKEM768
{{- if not $resolver }}
  stores:
    default:
      defaultCertificate:
        certFile: /tls/ingress.pem
        keyFile: /tls/ingress.key
{{- end }}
