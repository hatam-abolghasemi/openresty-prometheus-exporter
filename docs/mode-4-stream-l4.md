# Mode 4 — L4 (TCP/UDP) stream metrics

Observe the connections your app makes to a TCP/UDP dependency — Redis, a
database, a message broker — from the app's own point of view: connection
counts, bytes in/out, session duration, and how long upstream takes to connect
and send its first byte.

This is the `stream` (L4) counterpart to the HTTP modes. It's independent of
Modes 1–3: a **separate** registry on a **separate** port (`:9254`), because
nginx cannot share a shared dict between the `http` and `stream` modules.

Prerequisite: the image (or your own OpenResty with `ngx_stream_lua_module`,
which is stock).

---

## How it works

Your app connects to a local listener instead of straight to the dependency; the
sidecar proxies that TCP/UDP through its stream module and records it.

```
app ──▶ 127.0.0.1:16379 (stream proxy) ──▶ redis.prod:6379
                 │
          nginx_stream_* metrics on :9254/metrics
```

One `server{}` block per destination, each tagged with
`set $destination_name "redis"`, which feeds both the `destination` label and
the per-destination on/off switch. Logic lives in
[`stream_metrics`](modules.md#stream_metricslua); the wiring is in
[`stream.conf`](../examples/openresty-sidecar/stream.conf).

---

## Step by step

### 1. Turn the `stream {}` block on

Stream is **off** in the image by default. Enable it by dropping a main-level
include and your stream config in:

- `/etc/nginx/main.d/stream.conf` containing:
  ```nginx
  stream { include /etc/nginx/stream.d/*.conf; }
  ```
- `/etc/nginx/stream.d/stream.conf` — your destinations (next step).

In Kubernetes, both come from ConfigMaps mounted at those paths.

### 2. Define a destination

A minimal stream config for one Redis upstream (adapted from
[`examples/openresty-sidecar/stream.conf`](../examples/openresty-sidecar/stream.conf)):

```nginx
lua_shared_dict stream_metrics        3M;
lua_shared_dict stream_custom_metrics 1M;
lua_package_path "/opt/prometheus/?.lua;/opt/prometheus/lib/?.lua;;";

init_worker_by_lua_block { require("stream_metrics").init() }

# one server{} per destination
server {
    listen 127.0.0.1:16379;                # the app connects here instead of redis directly
    set    $destination_name "redis";       # -> destination label + apps.stream.redis toggle
    resolver local=on ipv6=off valid=10s;

    preread_by_lua_block { require("stream_metrics").connection_open() }   # see note below
    log_by_lua_block     { require("stream_metrics").record() }

    proxy_pass redis.prod.svc.cluster.local:6379;
}

# metrics exposition, its own port (never carries app traffic)
server {
    listen 9254;
    content_by_lua_block { require("stream_metrics").collect() }
}
```

> **The `preread_by_lua_block` hook is required** for
> `nginx_stream_connections_active` to be accurate — it's the `+1`; `record()`
> is the `-1`. A `server{}` without the preread hook simply isn't counted as
> active. See the stream notes in [`stream_metrics`](modules.md#stream_metricslua).

### 3. Point the app at the local listener

Change the app's Redis host from `redis.prod:6379` to `127.0.0.1:16379`. The app
is unaware anything changed; the sidecar proxies it through and records it.

### 4. Scrape `:9254`

Stream metrics are on their **own** endpoint — add a second scrape target:

```yaml
- job_name: my-app-stream
  metrics_path: /metrics
  static_configs:
    - targets: ["my-app:9254"]
```

With the Operator, the example
[`ServiceMonitor`](../examples/openresty-sidecar/k8s/service-and-servicemonitor.yaml)
already defines both the `app` (`:9145`) and `stream-metrics` (`:9254`)
endpoints.

### 5. Verify

```bash
curl -s localhost:9254/metrics | grep nginx_stream_connections_total
```

---

## What you get

`nginx_stream_*` series labelled with `destination`, `upstream_addr`, `status`,
and (on K8s) `source_service`/`source_namespace`. Full list and types in the
[metrics reference](metrics-reference.md#stream-l4-metrics). Highlights:

- `nginx_stream_connections_total` / `_active` — how many, how many now
- `nginx_stream_bytes_sent_total` / `_received_total` — throughput
- `nginx_stream_session_duration_seconds` — how long sessions last
- `nginx_stream_upstream_connect_time_seconds` /
  `nginx_stream_upstream_first_byte_time_seconds` — **how fast the dependency
  answers your app** (the "is Redis slow for me?" question)

---

## Turning one destination off

Opt-out, per destination, without touching the traffic — in
[`metrics_config.lua`](modules.md#metrics_configlua):

```lua
apps = {
  stream = {
    redis = { metrics_enabled = false },   -- keyed by $destination_name
  },
}
```

No entry = enabled (opt-out, not opt-in), so a new destination gets metrics by
default. See [`app_toggle`](modules.md#app_togglelua).

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| No stream metrics at all | `stream {}` not enabled — the `main.d` include is missing, or `stream.d/*.conf` isn't mounted |
| `nginx_stream_connections_active` always 0 | Missing `preread_by_lua_block { ... connection_open() }` in the destination's `server{}` |
| A phantom `destination` with no real traffic | A `log_by_lua_block` placed at the top of the stream file instead of per-`server{}` — the exposition server triggers it. Keep `record()` per destination block |
| `source_service="unknown"` | Same as HTTP: needs K8s pod PTR; expected on plain Docker |
| Metrics on `:9145` instead of `:9254` | You reused the HTTP registry — stream must have its own `lua_shared_dict` and its own exposition server; they can't share |

Back to the [docs index](README.md) · deep dive: [Modules](modules.md).
