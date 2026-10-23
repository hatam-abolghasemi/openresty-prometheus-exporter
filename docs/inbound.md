# inbound — request metrics into your app

Metrics for traffic **coming into** your app: request count, duration, request
and response size, and connection stats — each labelled with `method`, a
cardinality-safe `route`, `status`, `host`, and (on Kubernetes) which service
called you.

On as soon as the image runs. No other feature depends on it, and it
depends on none.

---

## What you get

Scraping `:9145/metrics` returns series like:

```
nginx_http_requests_total{method="GET",route="/orders/$param",status="200",host="api.internal",mode="0",source_service="checkout",source_namespace="shop"} 42
nginx_http_request_duration_seconds{...} 0.031
```

`mode="0"` marks inbound traffic. The full list of metrics and labels is in the
[metrics reference](metrics-reference.md).

The thing that makes this usable at scale is the `route` label: raw paths like
`/orders/8231/items/9f8a…` are collapsed to `/orders/$param/items/$param` by
[`route_sanitizer`](modules.md#route_sanitizerlua), so you get one series per
*route shape*, not one per order ID. See
[cardinality](metrics-reference.md#cardinality) for why that matters.

---

## Step by step (prebuilt image)

### 1. Run the image in front of your app

The image is a transparent reverse proxy on `:80` that forwards to your app and
records every request. Point it at your app's port with `APP_PORT`.

**Kubernetes** — add it as a second container in your pod:

```yaml
- name: nginx
  image: ghcr.io/hatam-abolghasemi/openresty-prometheus-exporter:alpine  # pin a tag from docs/images.md
  env:
    - name: APP_PORT
      value: "8080"          # the port your app listens on
  ports:
    - { name: http,    containerPort: 80 }
    - { name: metrics, containerPort: 9145 }
```

Then send client traffic to the nginx container's `:80` instead of straight to
the app. A full runnable example (Deployment + Service + ServiceMonitor) is in
[`examples/openresty-sidecar/`](../examples/openresty-sidecar/).

**Plain Docker** — share one network namespace so `127.0.0.1:$APP_PORT` reaches
the app:

```bash
docker run -d --name app -p 8080:8080 your-app:latest
docker run -d --name nginx --network container:app \
  -e APP_PORT=8080 \
  ghcr.io/hatam-abolghasemi/openresty-prometheus-exporter:alpine
```

> Under plain Docker everything here works **except** `source_service` /
> `source_namespace`, which need Kubernetes pod DNS to resolve the caller — they
> fall back to `unknown`. See [caller identity](#caller-identity-source_-labels).

### 2. Scrape it

Point Prometheus at `:9145`, path `/metrics`. With the Prometheus Operator, the
example [`ServiceMonitor`](../examples/openresty-sidecar/service.yaml)
already wires the `metrics` port. Manually:

```yaml
scrape_configs:
  - job_name: my-app-nginx
    metrics_path: /metrics
    static_configs:
      - targets: ["my-app:9145"]
```

### 3. Verify

```bash
curl -s localhost:9145/healthz          # -> ok
curl -s localhost:9145/metrics | grep nginx_http_requests_total
```

You should see `mode="0"` series appear as requests flow through `:80`.

---

## How it's wired (if you're curious or customizing)

Inside the image, `docker/conf.d/default.conf` has the `:80` server with three
Lua hooks:

```nginx
server {
    listen 80 default_server;
    set $request_mode 0;
    access_by_lua_block { require("http_metrics").classify_source() }   # who called us
    log_by_lua_block    { require("http_metrics").record() }            # record the request
    location / { proxy_pass http://app; ... }                          # app = 127.0.0.1:$APP_PORT
}

server {                       # the sidecar's own endpoints, on a separate port
    listen 9145;
    location = /metrics  { content_by_lua_block { require("http_metrics").collect() } }
    location = /healthz  { return 200 "ok\n"; }
}
```

`/metrics` lives on `:9145`, **not** `:80`, on purpose: scrapes must never be
recorded as app traffic, and the sidecar's own endpoints must never shadow your
app's routes. See [`http_metrics`](modules.md#http_metricslua) for what each
hook does.

---

## Caller identity (`source_*` labels)

`source_service` / `source_namespace` tell you *who* called each endpoint. They
are resolved by [`source_attribution`](modules.md#source_attributionlua) in
this order:

1. A static table of known internal subnets (`static_ranges` in
   `metrics_config.lua`).
2. Reverse-DNS (PTR) of the caller's pod IP against CoreDNS.
3. A configured fallback (`default_label`) if nothing resolves.

This needs a Kubernetes cluster whose CoreDNS serves PTR records for pod IPs. On
plain Docker, or a cluster without pod PTR, callers show as `unknown` /
`public` and everything else still works. If you run a service mesh with
waypoints (Istio ambient), read the **trust boundary** note in
[`source_attribution`](modules.md#source_attributionlua) before relying on the
XFCC override — it's a spoofing vector if XFCC can reach the sidecar unverified.

---

## Tuning

Everything is in [`lib/metrics_config.lua`](modules.md#metrics_configlua); mount
your own copy over the baked one to change it without rebuilding. Common knobs:

| Want to… | Change |
|---|---|
| Add/drop a label | `label_method`, `label_route`, `label_host`, `label_source_service`, … |
| Turn a metric off | `metric_requests`, `metric_latency`, `metric_latency_hist`, … |
| Fix caller resolution | `static_ranges`, `cluster_ip_prefix`, `ptr_dns_server` |
| Tune route collapsing | the `sanitize` table — see [`route_sanitizer`](modules.md#route_sanitizerlua) |
| Change histogram buckets | `histogram_buckets` (seconds), `histogram_buckets_*` |

> **One shared config, many Deployments.** With `discover_identity = true`
> (default) each pod discovers its own service/namespace via PTR, so the same
> `metrics_config.lua` can be mounted into every app. See
> [`self_identity`](modules.md#self_identitylua).

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `/metrics` empty of `mode="0"` series | No traffic has hit `:80` yet, or clients still bypass the proxy and hit the app directly |
| `source_service="unknown"` everywhere | No pod PTR records (plain Docker, or CoreDNS without PTR) — expected; use `static_ranges` for known subnets |
| `route` has high cardinality | An ID convention `route_sanitizer` doesn't catch — add a check, don't disable sanitization ([how](modules.md#adding-a-sanitizer-check)) |
| `host` label noisy | `cluster_ip_prefix` wrong, so internal IPs fall into the generic `$ip` bucket — set it to your pod/service CIDR prefix |
| 400/404 recorded as `source_service="unknown"` | Expected: nginx rejected the request before the access phase ran |

Next: [outbound](outbound.md).
