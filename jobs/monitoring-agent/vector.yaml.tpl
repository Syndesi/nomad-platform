[[- /*
  (The addresses of the scrape endpoints are filled in here from the task's environment: Vector does not expand ${VAR} there. The tokens are filled in the same way, so the rendered file is a secret: it lives in secrets/.)
  Vector's config, a Nomad template with the delimiters [[ ]] ({{ }} is Vector's own: label templates). Vector's ${VAR} are environment variables of the
  task (jobs/monitoring-agent.nomad.hcl). The logs keep their line as it is: only a few labels are added (the rest is parsed when you query: `| json`).
*/ -]]
[[- $node := env "NODE_NAME" ]]
data_dir: /var/lib/vector
api:
  enabled: false

sources:
  # ---- logs ----------------------------------------------------------------------------------------------------------------------------------
  docker:
    type: docker_logs
    # not the socket: the proxy task of this group (GET containers / events only), on the loopback of the group network
    docker_host: tcp://127.0.0.1:2375
    # not this agent's own output (a loop when something is wrong with it)
    exclude_containers: ["vector-"]
[[- if eq (env "TETRAGON_LOG") "true" ]]
  tetragon:
    type: file
    include: ["/tetragon/tetragon.log"]
    # a new file starts at the beginning, a known one where it stopped (checkpoints in the data directory)
    read_from: beginning
[[- end ]]
  # the system logs of the node (/var/log): alpine writes files per service (nomad, consul, docker), ubuntu has rsyslog's files (syslog holds what the services log to
  # the journal, and the kernel messages: kern.log has the same ones again, so it is not read; auth.log is not in syslog); they stay on the node (rotated by cluster_logs, cluster_log_retention_days) and are shipped as well
  system:
    type: file
    include:
      - /var/log-host/nomad.log
      - /var/log-host/consul.log
      - /var/log-host/docker.log
      - /var/log-host/messages
      - /var/log-host/syslog
      - /var/log-host/auth.log
    read_from: end
  vector_metrics:
    type: internal_metrics
    scrape_interval_secs: 30

  # ---- metrics of this node --------------------------------------------------------------------------------------------------------------
  nomad:
    type: prometheus_scrape
    endpoints: ["https://[[ env "NODE_IP" ]]:[[ env "NOMAD_PORT" ]]/v1/metrics"]
    query: {format: [prometheus]}
    auth: {strategy: bearer, token: "[[ with nomadVar "nomad/jobs/monitoring-agent" ]][[ .nomad_token ]][[ end ]]"}
    tls: {ca_file: /secrets/ca.pem}
    scrape_interval_secs: 30
  consul:
    type: prometheus_scrape
    endpoints: ["https://[[ env "NODE_IP" ]]:[[ env "CONSUL_PORT" ]]/v1/agent/metrics"]
    query: {format: [prometheus]}
    auth: {strategy: bearer, token: "[[ with nomadVar "nomad/jobs/monitoring-agent" ]][[ .consul_token ]][[ end ]]"}
    tls: {ca_file: /secrets/ca.pem}
    scrape_interval_secs: 30
[[- if ne (env "TETRAGON_PORT") "0" ]]
  tetragon_metrics:
    type: prometheus_scrape
    endpoints: ["http://[[ env "NODE_IP" ]]:[[ env "TETRAGON_PORT" ]]/metrics"]
    scrape_interval_secs: 30
[[- end ]]

  # ---- metrics of the services on this node: consul services tagged `metrics` (docs/monitoring.md) -----------------------------------------------
  # tags: metrics (on) | metrics.path=/x (default /metrics) | metrics.scheme=https (default http) | metrics.job=name (default: the service's name)
[[- $n := 0 ]]
[[- range services ]][[ $svcname := .Name ]][[ range service .Name ]]
[[- if and (eq .Node $node) (.Tags | contains "metrics") ]]
[[- $path := "/metrics" ]][[ $scheme := "http" ]][[ $job := $svcname ]]
[[- range .Tags ]]
[[- /* tags are written by whoever submits a job and end up in this config: only strict values are taken, anything else keeps the default */ -]]
[[- if . | regexMatch "^metrics\\.path=/[A-Za-z0-9_./-]*$" ]][[ $path = . | regexReplaceAll "^metrics\\.path=" "" ]][[ end ]]
[[- if . | regexMatch "^metrics\\.scheme=(http|https)$" ]][[ $scheme = . | regexReplaceAll "^metrics\\.scheme=" "" ]][[ end ]]
[[- if . | regexMatch "^metrics\\.job=[A-Za-z0-9_.-]+$" ]][[ $job = . | regexReplaceAll "^metrics\\.job=" "" ]][[ end ]]
[[- end ]]
  svc_[[ $n ]]:
    type: prometheus_scrape
    endpoints: [ [[ printf "%s://%s:%d%s" $scheme .Address .Port $path | toJSON ]] ]
    scrape_interval_secs: 30
    tls: {verify_certificate: false}
[[- $n = add $n 1 ]]
[[- end ]]
[[- end ]][[ end ]]

[[- if eq (env "MONITORING_NODE") "true" ]]

  # ---- what happens in the cluster: polled from the APIs, one event per change (this node only: one copy of every event) ------------------------------
  p_nodes:
    type: http_client
    endpoint: "https://[[ env "NODE_IP" ]]:[[ env "NOMAD_PORT" ]]/v1/nodes?resources=false"
    scrape_interval_secs: 30
    auth: {strategy: bearer, token: "[[ with nomadVar "nomad/jobs/monitoring-agent" ]][[ .nomad_token ]][[ end ]]"}
    tls: {ca_file: /secrets/ca.pem}
    decoding: {codec: json}
  p_allocs:
    type: http_client
    endpoint: "https://[[ env "NODE_IP" ]]:[[ env "NOMAD_PORT" ]]/v1/allocations?namespace=*&resources=false&task_states=true"
    scrape_interval_secs: 30
    auth: {strategy: bearer, token: "[[ with nomadVar "nomad/jobs/monitoring-agent" ]][[ .nomad_token ]][[ end ]]"}
    tls: {ca_file: /secrets/ca.pem}
    decoding: {codec: json}
  p_deployments:
    type: http_client
    endpoint: "https://[[ env "NODE_IP" ]]:[[ env "NOMAD_PORT" ]]/v1/deployments?namespace=*"
    scrape_interval_secs: 30
    auth: {strategy: bearer, token: "[[ with nomadVar "nomad/jobs/monitoring-agent" ]][[ .nomad_token ]][[ end ]]"}
    tls: {ca_file: /secrets/ca.pem}
    decoding: {codec: json}
  p_health:
    type: http_client
    endpoint: "https://[[ env "NODE_IP" ]]:[[ env "CONSUL_PORT" ]]/v1/health/state/any"
    scrape_interval_secs: 30
    auth: {strategy: bearer, token: "[[ with nomadVar "nomad/jobs/monitoring-agent" ]][[ .consul_token ]][[ end ]]"}
    tls: {ca_file: /secrets/ca.pem}
    decoding: {codec: json}
[[- end ]]

transforms:
  # ---- containers: labels from the nomad labels of the container, the level from the line ---------------------------------------------------------
  containers:
    type: remap
    inputs: [docker]
    source: |
      .host = get_env_var!("NODE_NAME")
      .source = "docker"
      .job = string(.label."com.hashicorp.nomad.job_name") ?? "docker"
      .task = string(.label."com.hashicorp.nomad.task_name") ?? string!(.container_name)
      .namespace = string(.label."com.hashicorp.nomad.namespace") ?? "none"
      msg = string(.message) ?? ""
      lv = ""
      parsed, err = parse_json(msg)
      if err == null && is_object(parsed) {
        lv = string(parsed.level) ?? string(parsed.severity) ?? string(parsed.lvl) ?? ""
      } else {
        lm = downcase(msg)
        if match(lm, r'\b(fatal|panic|error|err|exception)\b') { lv = "error" }
        else if match(lm, r'\b(warn|warning)\b') { lv = "warn" }
        else if match(lm, r'\bdebug\b') { lv = "debug" }
        else if match(lm, r'\binfo\b') { lv = "info" }
      }
      lv = downcase(lv)
      if lv == "warning" { lv = "warn" }
      if lv == "err" || lv == "fatal" || lv == "critical" || lv == "panic" { lv = "error" }
      if !includes(["debug", "info", "warn", "error"], lv) { lv = "unknown" }
      .level = lv
  system_logs:
    type: remap
    inputs: [system]
    source: |
      .host = get_env_var!("NODE_NAME")
      .source = "system"
      .namespace = "none"
      f = replace(string!(.file), "/var/log-host/", "")
      .task = replace(f, ".log", "")
      .job = if includes(["nomad", "consul", "docker"], .task) { .task } else { "system" }
      lm = downcase(string!(.message))
      .level = "info"
      if match(lm, r'\b(fatal|panic|error|err|failed|failure)\b') { .level = "error" }
      else if match(lm, r'\b(warn|warning)\b') { .level = "warn" }
      else if match(lm, r'\bdebug\b') { .level = "debug" }
[[- if eq (env "TETRAGON_LOG") "true" ]]
  tetragon_logs:
    type: remap
    inputs: [tetragon]
    source: |
      .host = get_env_var!("NODE_NAME")
      .source = "tetragon"
      .job = "tetragon"
      .namespace = "none"
      .level = "info"
      parsed, err = parse_json(string!(.message))
      .task = "other"
      if err == null && is_object(parsed) {
        if exists(parsed.process_exec) { .task = "exec" }
        else if exists(parsed.process_exit) { .task = "exit" }
        else if exists(parsed.process_kprobe) {
          .task = "kprobe"
          if contains(string!(.message), "KPROBE_ACTION_SIGKILL") { .level = "warn" }
        }
      }
[[- end ]]
[[- if eq (env "MONITORING_NODE") "true" ]]
  # ---- cluster events: only when something changed (index of the object), as one json line ---------------------------------------------------------------
  d_nodes:
    type: dedupe
    inputs: [p_nodes]
    fields: {match: [ID, ModifyIndex]}
    cache: {num_events: 2000}
  d_allocs:
    type: dedupe
    inputs: [p_allocs]
    fields: {match: [ID, ModifyIndex]}
    cache: {num_events: 10000}
  d_deployments:
    type: dedupe
    inputs: [p_deployments]
    fields: {match: [ID, ModifyIndex]}
    cache: {num_events: 2000}
  # the output of a check changes all the time: only the status counts
  d_health:
    type: dedupe
    inputs: [p_health]
    fields: {match: [Node, CheckID, Status]}
    cache: {num_events: 5000}
  e_nodes:
    type: remap
    inputs: [d_nodes]
    source: |
      ev = {"event": "node", "name": .Name, "id": .ID, "status": .Status, "eligibility": .SchedulingEligibility, "drain": .Drain, "address": .Address, "class": .NodeClass, "status_description": .StatusDescription}
      lv = "warn"
      if .Status == "ready" { lv = "info" }
      . = {"timestamp": now(), "message": encode_json(ev), "task": "node", "level": lv}
  e_allocs:
    type: remap
    inputs: [d_allocs]
    source: |
      # per task: its state, restarts and the last event only (the history is in the api, and would repeat on every change)
      tasks = map_values(object(.TaskStates) ?? {}) -> |t| {
        evs = array(t.Events) ?? []
        last = get(evs, [length(evs) - 1]) ?? {}
        {"state": t.State, "failed": t.Failed, "restarts": t.Restarts, "type": last.Type, "message": last.DisplayMessage}
      }
      ev = {"event": "allocation", "namespace": .Namespace, "job": .JobID, "group": .TaskGroup, "alloc": .ID, "node": .NodeName, "client_status": .ClientStatus, "desired": .DesiredStatus, "deployment_healthy": .DeploymentStatus.Healthy, "tasks": tasks}
      lv = "info"
      if .ClientStatus == "failed" || .ClientStatus == "lost" { lv = "error" }
      . = {"timestamp": now(), "message": encode_json(ev), "task": "allocation", "level": lv}
  e_deployments:
    type: remap
    inputs: [d_deployments]
    source: |
      ev = {"event": "deployment", "namespace": .Namespace, "job": .JobID, "id": .ID, "version": .JobVersion, "status": .Status, "description": .StatusDescription}
      lv = "info"
      if .Status == "failed" { lv = "error" }
      . = {"timestamp": now(), "message": encode_json(ev), "task": "deployment", "level": lv}
  e_health:
    type: remap
    inputs: [d_health]
    source: |
      ev = {"event": "health", "node": .Node, "check": .CheckID, "name": .Name, "status": .Status, "service": .ServiceName, "output": .Output}
      lv = "info"
      if .Status == "critical" { lv = "error" } else if .Status == "warning" { lv = "warn" }
      . = {"timestamp": now(), "message": encode_json(ev), "task": "health", "level": lv}
  platform:
    type: remap
    inputs: [e_nodes, e_allocs, e_deployments, e_health]
    source: |
      .host = get_env_var!("NODE_NAME")
      .source = "platform"
      .job = "nomad-events"
      .namespace = "none"
[[- end ]]

  # ---- metrics of the tagged services: the job label (same order as the sources svc_N above)
[[- $t := 0 ]]
[[- range services ]][[ $svcname := .Name ]][[ range service .Name ]]
[[- if and (eq .Node $node) (.Tags | contains "metrics") ]]
[[- $job := $svcname ]]
[[- range .Tags ]][[ if . | regexMatch "^metrics\\.job=[A-Za-z0-9_.-]+$" ]][[ $job = . | regexReplaceAll "^metrics\\.job=" "" ]][[ end ]][[ end ]]
  tag_svc_[[ $t ]]:
    type: remap
    inputs: [svc_[[ $t ]]]
    source: |
      .tags.job = [[ $job | toJSON ]]
[[- $t = add $t 1 ]]
[[- end ]]
[[- end ]][[ end ]]

  # ---- metrics: where from (job) and which node (host) ---------------------------------------------------------------------------------------------
  m_nomad:
    type: remap
    inputs: [nomad]
    source: |
      .tags.job = "nomad"
  m_consul:
    type: remap
    inputs: [consul]
    source: |
      .tags.job = "consul"
[[- if ne (env "TETRAGON_PORT") "0" ]]
  m_tetragon:
    type: remap
    inputs: [tetragon_metrics]
    source: |
      .tags.job = "tetragon"
[[- end ]]
  m_vector:
    type: remap
    inputs: [vector_metrics]
    source: |
      .tags.job = "vector"
  m_all:
    type: remap
    inputs: [m_nomad, m_consul, m_vector
[[- if ne (env "TETRAGON_PORT") "0" ]], m_tetragon[[ end ]]
[[- $k := 0 ]][[ range services ]][[ range service .Name ]][[ if and (eq .Node $node) (.Tags | contains "metrics") ]], tag_svc_[[ $k ]][[ $k = add $k 1 ]][[ end ]][[ end ]][[ end ]]]
    source: |
      .tags.host = get_env_var!("NODE_NAME")

sinks:
  loki:
    type: loki
    inputs: [containers, system_logs
[[- if eq (env "TETRAGON_LOG") "true" ]], tetragon_logs[[ end ]]
[[- if eq (env "MONITORING_NODE") "true" ]], platform[[ end ]]]
    endpoint: http://127.0.0.1:3100
    healthcheck: {enabled: false}
    encoding: {codec: text}
    # few labels (every combination is a stream); the rest is in structured metadata and in the line
    labels:
      host: "{{ host }}"
      source: "{{ source }}"
      job: "{{ job }}"
      task: "{{ task }}"
      namespace: "{{ namespace }}"
      level: "{{ level }}"
    out_of_order_action: accept
  prometheus:
    type: prometheus_remote_write
    inputs: [m_all]
    endpoint: http://127.0.0.1:9090/api/v1/write
    healthcheck: {enabled: false}
