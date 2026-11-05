{{- /* where consul and nomad answer: loopback on the host network, the node's cluster address from the bridge network */ -}}
{{- $host := "127.0.0.1" }}{{ if eq (env "TPL_WIREGUARD") "true" }}{{ $host = env "NOMAD_HOST_IP_https" }}{{ end }}
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
    transport:
      respondingTimeouts:
        readTimeout: 600s
        writeTimeout: 600s
{{- if ne (env "TPL_METRICS_PORT") "0" }}
  metrics:
    # bridge network: all addresses of the allocation (the published port is on the node's cluster address only, and the sidecar
    # drops what comes in through the tunnel); host network: the node's cluster address
    address: "{{ if eq (env "TPL_WIREGUARD") "true" }}:{{ env "TPL_METRICS_PORT" }}{{ else }}{{ env "NOMAD_IP_metrics" }}:{{ env "TPL_METRICS_PORT" }}{{ end }}"
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
{{- if ne (env "TPL_TLS_RESOLVER") "" }}
certificatesResolvers:
  {{ env "TPL_TLS_RESOLVER" }}:
    acme:
      caServer: {{ env "TPL_ACME_SERVER" }}
      email: {{ env "TPL_ACME_EMAIL" }}
      storage: /acme/acme.json
      tlsChallenge: {}
{{- end }}
