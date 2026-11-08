{{- /* where consul and nomad answer: the node's cluster address (traefik has its own network namespace) */ -}}
{{- $host := env "NOMAD_HOST_IP_https" }}
# no calls home: no check for new versions, no anonymous usage statistics
global:
  checkNewVersion: false
  sendAnonymousUsage: false
log:
  level: INFO
  noColor: true
accessLog:
  format: json
api:
  dashboard: true
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    # routers without entryPoints (consul catalog tags of the apps) attach here and nowhere else, never to the internal entry point vpn
    asDefault: true
    http:
      # Every router on this entry point goes through authelia first (the middleware is in the file provider, dynamic.yml.tpl, so that no job's tags can replace it):
      # a job that forgets the middleware is not open to the internet. Opting out is an access rule with `policy: bypass` for the job's
      # domain in the cluster's authelia_access_rules; domains without any rule are denied. Without authelia running the routes answer
      # with an error and not without login.
      # In front of it: hsts (every name, apps included) and the limit of requests in flight per source address (inflight-public). They come first, so
      # that the answers of authelia carry the header too and the limit protects authelia as well.
      middlewares:
        - hsts@file
        - inflight-public@file
        - authelia@file
    # the public side: short timeouts against slow clients (the request, header and body, must arrive within readTimeout; the answer must be written within
    # writeTimeout). Websockets and the tcp router of the VPN (tls passthrough) are not affected: they are not requests of this kind.
    transport:
      respondingTimeouts:
        readTimeout: {{ env "TPL_PUBLIC_READ_TIMEOUT" }}
        writeTimeout: {{ env "TPL_PUBLIC_WRITE_TIMEOUT" }}
  # The internal services (zone TPL_ZONE): reached through the VPN only. The namespace's firewall redirects tcp/443 from wg1 to this port and drops
  # it from everywhere else. Every router on it goes through authelia-internal first (middleware in the file provider, like authelia above).
  # No routers of the consul catalog get here (asDefault is websecure's): the internal routers are in the file provider.
  vpn:
    address: ":{{ env "TPL_VPN_PORT" }}"
    http:
      middlewares:
        - hsts@file
        - authelia-internal@file
      tls:
        options: pq-only@file
    transport:
      respondingTimeouts:
        readTimeout: 600s
        writeTimeout: 600s
{{- if ne (env "TPL_METRICS_PORT") "0" }}
  metrics:
    # all addresses of the allocation (the published port is on the node's cluster address only, and the sidecars drop what comes in through the tunnels)
    address: ":{{ env "TPL_METRICS_PORT" }}"
metrics:
  prometheus:
    entryPoint: metrics
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true
{{- end }}
providers:
  file:
    directory: /secrets/dynamic
    watch: true
  consulCatalog:
    exposedByDefault: false
    endpoint:
      address: {{ $host }}:{{ env "TPL_CONSUL_PORT" }}
      scheme: https
      token: {{ with nomadVar "nomad/jobs/traefik" }}{{ .consul_token }}{{ end }}
      tls:
        ca: /secrets/ca.pem
{{- if or (ne (env "TPL_TLS_RESOLVER") "") (ne (env "TPL_STEPCA_ACME_URL") "") }}
certificatesResolvers:
{{- if ne (env "TPL_TLS_RESOLVER") "" }}
  {{ env "TPL_TLS_RESOLVER" }}:
    acme:
      caServer: {{ env "TPL_ACME_SERVER" }}
      email: {{ env "TPL_ACME_EMAIL" }}
      storage: /acme/acme.json
      tlsChallenge: {}
{{- end }}
{{- if ne (env "TPL_STEPCA_ACME_URL") "" }}
  # the internal zone: per-name certificates from step-ca (tls-alpn-01; step-ca validates against the ingress node's published 443), 7 days,
  # renewed at about two thirds of their life
  stepca:
    acme:
      caServer: {{ env "TPL_STEPCA_ACME_URL" }}
      email: {{ env "TPL_ACME_EMAIL" }}
      storage: /acme/acme-stepca.json
      certificatesDuration: {{ env "TPL_STEPCA_HOURS" }}
      tlsChallenge: {}
{{- end }}
{{- end }}
