# Metrics reference

Every metric this exporter produces, its type, labels, and what it's for. Which
metrics and labels are active is controlled by the `metric_*` / `label_*` flags
in [`metrics_config.lua`](modules.md#metrics_configlua) — the lists below are the
full set at default config.

- **HTTP** metrics are on `:9145/metrics` ([Modes 1–3](mode-1-inbound-l7.md)).
- **Stream** metrics are on `:9254/metrics` ([Mode 4](mode-4-stream-l4.md)).

---

## HTTP request labels

Every HTTP request/response series carries this shared label set (each label
individually toggleable):

| Label | Example | Source | Default |
|---|---|---|---|
| `method` | `GET`, `POST`, `CONNECT` | request method | on |
| `route` | `/orders/$param` | request URI, [sanitized](modules.md#route_sanitizerlua) | on |
| `status` | `200`, `404`, `503` | response status | on |
| `host` | `api.internal`, `kubernetes`, `$ip` | `Host`, [classified](modules.md#host_classifierlua) | on |
| `mode` | `0` inbound · `1` outbound | which leg (`$request_mode`) | on |
| `source_service` | `checkout` | [caller identity](modules.md#source_attributionlua) | on |
| `source_namespace` | `shop` | caller identity | on |
| `client_subnet` | `10.233.4.0` | [masked client IP](modules.md#client_subnetlua) | **off** |
| `app` / `namespace` | the sidecar's own identity | [self identity](modules.md#self_identitylua) | off |

> For an **intercepted** HTTPS call ([Mode 3](mode-3-outbound-https-interception.md))
> these are the *real* decrypted values. Without interception, an HTTPS egress
> call shows `method="CONNECT"`, `route="host:port"`, `status="200"` (tunnel
> established) — see [Mode 2](mode-2-outbound-l7.md).

## HTTP request/response metrics

| Metric | Type | Notes |
|---|---|---|
| `nginx_http_requests_total` | counter | Request count. The workhorse — rate() this |
| `nginx_http_request_duration_seconds` | gauge | Last request duration (expired by [`gauge_expiry`](modules.md#gauge_expirylua)) |
| `nginx_http_request_duration_seconds_histogram` | histogram | Duration distribution; buckets = `histogram_buckets` |
| `nginx_http_request_size_bytes` | gauge | Last request size |
| `nginx_http_request_size_bytes_histogram` | histogram | off by default |
| `nginx_http_response_size_bytes` | gauge | Last response size |
| `nginx_http_response_size_bytes_histogram` | histogram | off by default |

## HTTP connection metrics

These carry `{app, namespace}` (and `nginx_http_connections` adds `state`), not
the request label set — a connection can carry many requests, so route/method/
status don't apply.

| Metric | Type | Labels | Notes |
|---|---|---|---|
| `nginx_http_connections` | gauge | `state` (`active`/`reading`/`writing`/`waiting`), `app`, `namespace` | From stub_status |
| `nginx_connection_requests` | gauge | `app`, `namespace` | Requests on the current connection |
| `nginx_connection_requests_histogram` | histogram | `app`, `namespace` | off by default |
| `nginx_connection_time_seconds` | gauge | `app`, `namespace` | Current connection age |
| `nginx_connection_time_seconds_histogram` | histogram | `app`, `namespace` | off by default |

## Health / internal

| Metric | Type | Notes |
|---|---|---|
| `nginx_metric_errors_total` | counter | From the vendored library — label-count mismatches etc. **Should stay 0**; non-zero means a schema bug (the smoke test asserts 0) |

---

## Stream (L4) metrics

On `:9254/metrics`. Labels: `destination` (your `$destination_name`),
`upstream_addr`, `status`, and (on K8s) `source_service` / `source_namespace`.

| Metric | Type | Notes |
|---|---|---|
| `nginx_stream_connections_total` | counter | Connections to this destination |
| `nginx_stream_connections_active` | gauge | Currently open (needs the `preread` hook — see [Mode 4](mode-4-stream-l4.md)) |
| `nginx_stream_bytes_sent_total` | counter | Bytes app→upstream |
| `nginx_stream_bytes_received_total` | counter | Bytes upstream→app |
| `nginx_stream_upstream_bytes_sent_total` | counter | Bytes to the upstream leg |
| `nginx_stream_upstream_bytes_received_total` | counter | Bytes from the upstream leg |
| `nginx_stream_session_duration_seconds` | gauge | Last session length |
| `nginx_stream_session_duration_seconds_histogram` | histogram | Session length distribution |
| `nginx_stream_upstream_connect_time_seconds` | gauge | How fast the dependency accepts the connection |
| `nginx_stream_upstream_connect_time_seconds_histogram` | histogram | …distribution |
| `nginx_stream_upstream_first_byte_time_seconds` | gauge | Time to first byte from the dependency |

The two "how fast does my dependency answer" gauges
(`upstream_connect_time`, `session_duration`) are expired by `gauge_expiry` so a
quiet destination doesn't report a frozen value.

---

## Cardinality

Cardinality (distinct label combinations) is what makes or breaks a Prometheus.
This exporter keeps it bounded **at the source**, before values become labels:

- **`route`** is the big one. Raw paths carry IDs; [`route_sanitizer`](modules.md#route_sanitizerlua)
  collapses them to `$param` so you get one series per *route shape*. If you see
  `route` cardinality climbing, an ID convention is leaking through — **add a
  sanitizer check** ([how](modules.md#adding-a-sanitizer-check)), don't drop the
  label.
- **`host`** is client-controlled; [`host_classifier`](modules.md#host_classifierlua)
  buckets it. Set `cluster_ip_prefix` correctly or internal IPs scatter into
  `$ip`.
- **`source_service`/`source_namespace`** are bounded by how many services call
  you — naturally low. Unresolved callers collapse to `unknown`/`public`.
- **`status` × `method` × `mode`** are all small fixed sets.
- **`client_subnet`** is off by default; masked to `/24`–`/16` when on.

Rough series estimate per sidecar: `routes × statuses × methods × callers × 2
(modes)`. Keep `routes` bounded (sanitizer) and this stays in the hundreds, not
the millions.

---

## Example PromQL

```promql
# inbound request rate by route
sum by (route) (rate(nginx_http_requests_total{mode="0"}[5m]))

# inbound error ratio
sum(rate(nginx_http_requests_total{mode="0",status=~"5.."}[5m]))
  / sum(rate(nginx_http_requests_total{mode="0"}[5m]))

# p95 inbound latency (histogram)
histogram_quantile(0.95,
  sum by (le) (rate(nginx_http_request_duration_seconds_histogram_bucket{mode="0"}[5m])))

# who is calling a given service
sum by (source_service, source_namespace) (
  rate(nginx_http_requests_total{mode="0"}[5m]))

# outbound calls by destination host (incl. decrypted HTTPS in Mode 3)
sum by (host, status) (rate(nginx_http_requests_total{mode="1"}[5m]))

# how fast is my Redis answering (Mode 4)
histogram_quantile(0.99,
  sum by (le, destination) (rate(nginx_stream_upstream_connect_time_seconds_histogram_bucket[5m])))

# sanity: exporter health (must be flat zero)
nginx_metric_errors_total
```

See the [modules guide](modules.md) to add a metric or label, and the
[architecture doc](../ARCHITECTURE.md) for why the pipeline is shaped this way.
