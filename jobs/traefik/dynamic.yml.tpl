{{- $resolver := env "TPL_TLS_RESOLVER" }}
{{- $host := env "NOMAD_HOST_IP_https" }}
{{- $zone := env "TPL_ZONE" }}
{{- $stepca := env "TPL_STEPCA_ACME_URL" }}
http:
  routers:
    # The ops names (the internal ones below, and authelia's public portal) accept the hybrid post-quantum key exchange and nothing else (tls option pq-only);
    # a client without it (an old browser) cannot open them. Apps keep the default option.
    # authelia's portal. The router, the forward-auth middleware and the service are here and not in authelia's consul tags: tags are
    # written by whoever submits a job (a second router for auth. or a second "authelia" middleware would take over the logins).
    authelia:
      entryPoints: [websecure]
      middlewares: [auth-ratelimit, admin-headers]
      service: authelia
      rule: Host(`auth.{{ env "TPL_DOMAIN" }}`)
      tls: { options: pq-only{{ with $resolver }}, certResolver: {{ . }}{{ end }} }
    # the login itself: authelia counts failures per USERNAME only, so one address trying one password on many users is not stopped there.
    # Here it is limited per source address, across all names.
    authelia-login:
      entryPoints: [websecure]
      middlewares: [login-ratelimit, admin-headers]
      service: authelia
      rule: Host(`auth.{{ env "TPL_DOMAIN" }}`) && (PathPrefix(`/api/firstfactor`) || PathPrefix(`/api/secondfactor`))
      priority: 200
      tls: { options: pq-only{{ with $resolver }}, certResolver: {{ . }}{{ end }} }
    # ---- the internal services: entry point vpn only (reached through the VPN), zone {{ $zone }}, in front of them authelia-internal (default middleware of the
    # entry point). Their certificate: the wildcard of the zone (tls.certificates below). Never on websecure: Host / SNI routing hides nothing.
    # authelia-internal's portal: same construction as the public one
    authelia-internal:
      entryPoints: [vpn]
      middlewares: [auth-ratelimit, admin-headers]
      service: authelia-internal
      rule: Host(`auth.{{ $zone }}`)
      tls: { options: pq-only{{ with $stepca }}, certResolver: stepca{{ end }} }
    authelia-internal-login:
      entryPoints: [vpn]
      middlewares: [login-ratelimit, admin-headers]
      service: authelia-internal
      rule: Host(`auth.{{ $zone }}`) && (PathPrefix(`/api/firstfactor`) || PathPrefix(`/api/secondfactor`))
      priority: 200
      tls: { options: pq-only{{ with $stepca }}, certResolver: stepca{{ end }} }
    # Nomad: a request that brings a nomad token of its own (X-Nomad-Token header) is passed on as it is; one without gets the read-only token of the "ui"
    # policy (nodes and jobs) added, so the web ui can look without a nomad login.
    nomad:
      entryPoints: [vpn]
      middlewares: [admin-net, admin-headers]
      service: nomad
      rule: Host(`nomad.{{ $zone }}`) && HeaderRegexp(`X-Nomad-Token`, `.+`)
      priority: 200
      tls: { options: pq-only{{ with $stepca }}, certResolver: stepca{{ end }} }
    nomad-ui:
      entryPoints: [vpn]
      middlewares: [admin-net, admin-headers, nomad-ui-token]
      service: nomad
      rule: Host(`nomad.{{ $zone }}`)
      priority: 100
      tls: { options: pq-only{{ with $stepca }}, certResolver: stepca{{ end }} }
    consul:
      entryPoints: [vpn]
      middlewares: [admin-net, admin-headers]
      service: consul
      rule: Host(`consul.{{ $zone }}`)
      tls: { options: pq-only{{ with $stepca }}, certResolver: stepca{{ end }} }
    # The APIs for the command line and for projects (CI, third party apps; docs/projects.md): the same backends, reached from every VPN device (people's
    # and projects' half) with an ACL token and nothing else: authelia-internal lets these two names through without a second factor for the VPN
    # (authelia_internal_access_rules), the ipAllowList is the second lock. No ui token is added here: a request without a token gets nothing.
    # The TLS option is the default one (TLS 1.3, any key exchange): the clients are curl / go / python on a runner, not browsers.
    nomad-api:
      entryPoints: [vpn]
      middlewares: [api-net, admin-headers]
      service: nomad
      rule: Host(`nomad-api.{{ $zone }}`)
      tls: { options: default{{ with $stepca }}, certResolver: stepca{{ end }} }
    consul-api:
      entryPoints: [vpn]
      middlewares: [api-net, admin-headers]
      service: consul
      rule: Host(`consul-api.{{ $zone }}`)
      tls: { options: default{{ with $stepca }}, certResolver: stepca{{ end }} }
    traefik:
      entryPoints: [vpn]
      middlewares: [admin-net, admin-headers]
      service: api@internal
      rule: Host(`traefik.{{ $zone }}`)
      tls: { options: pq-only{{ with $stepca }}, certResolver: stepca{{ end }} }
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
    # The default middleware of the entry point vpn (static.yml.tpl): authelia-internal on the node TPL_AUTHELIA_INTERNAL_ADDR, own cookie, own second factors.
    authelia-internal:
      forwardAuth:
        address: https://{{ env "TPL_AUTHELIA_INTERNAL_ADDR" }}/api/authz/forward-auth
        tls:
          ca: /secrets/ca.pem
        trustForwardHeader: true
        authRequestHeaders: [Cookie, Accept, X-Requested-With, X-Forwarded-For, X-Forwarded-Proto, X-Forwarded-Host, X-Forwarded-Uri, X-Forwarded-Method]
        authResponseHeaders: [Remote-User, Remote-Groups, Remote-Name, Remote-Email]
    # per source address (the client address traefik sees: behind a proxy or load balancer that is the proxy, see ipStrategy)
    # the whole portal: generous, a page load is a dozen requests
    auth-ratelimit:
      rateLimit:
        average: 120
        period: 1m
        burst: 60
    # first and second factor: 10 attempts a minute, a burst of 5 (a person typing a wrong password a few times is not affected)
    login-ratelimit:
      rateLimit:
        average: 10
        period: 1m
        burst: 5
    # the ops names: HSTS and the usual browser headers (the apps set their own)
    admin-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        forceSTSHeader: true
        contentTypeNosniff: true
        frameDeny: true
        referrerPolicy: no-referrer
    # the two halves of the VPN addresses (cluster_vpn_admin_net / cluster_vpn_project_net): people's devices and projects' devices. The source address is the
    # device's own (the namespace redirects the port, it does not rewrite the source).
    admin-net:
      ipAllowList:
        sourceRange: ["{{ env "TPL_VPN_ADMIN_NET" }}"]
    api-net:
      ipAllowList:
        sourceRange: ["{{ env "TPL_VPN_ADMIN_NET" }}", "{{ env "TPL_VPN_PROJECT_NET" }}"]
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
    authelia-internal:
      loadBalancer:
        passHostHeader: true
        serversTransport: cluster-ca
        servers:
          - url: https://{{ env "TPL_AUTHELIA_INTERNAL_ADDR" }}
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
# The VPN's way in: tcp/443 with the SNI {{ env "TPL_VPN_HOST" }} goes to wstunnel in this namespace, TLS passed through (wstunnel terminates it and asks
# for the client certificate). Defined here and not by tags: whoever submits a job writes tags.
tcp:
  routers:
    wstunnel:
      entryPoints: [websecure]
      rule: HostSNI(`{{ env "TPL_VPN_HOST" }}`)
      service: wstunnel
      tls:
        passthrough: true
  services:
    wstunnel:
      loadBalancer:
        servers:
          - address: "127.0.0.1:{{ env "TPL_WSTUNNEL_PORT" }}"
tls:
{{- if not $stepca }}
  # the wildcard certificate of the internal zone, for the routers of the entry point vpn (picked by SNI); with step-ca each name gets its own (resolver stepca)
  certificates:
    - certFile: /tls-internal/internal.pem
      keyFile: /tls-internal/internal.key
{{- end }}
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
