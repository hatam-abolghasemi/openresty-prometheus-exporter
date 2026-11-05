# FAQ

Short answers to the questions people ask before running this in production.
Each links to the longer argument, with its trade-offs, in
[Design decisions](design-decisions.md).

---

## Positioning

### What is this, in one sentence?

An OpenResty sidecar that sits in front of (and optionally behind) one app and
turns its HTTP and TCP traffic into low-cardinality Prometheus metrics: rate,
status, latency and size per route, plus who called and whom it called.

### Why not Istio?

If you already run a mesh for mTLS and traffic control, use its metrics.
Taking on a mesh *only* for metrics means operating a control plane, and
Istio's standard request metrics carry no route label by default; in ambient
mode L7 metrics also need a waypoint (an extra Envoy hop). This project gives
per-route metrics with no control plane, at the price of a manifest change per
Deployment and no traffic management.
[More](design-decisions.md#service-mesh-istio-sidecar-or-ambient)

### Why not OpenTelemetry SDKs?

SDKs see more (exact route templates, spans, in-process DB calls), but each
language needs its own instrumentation, build or runtime change. This needs
none. If you need traces, use OpenTelemetry; the two can run side by side.
[More](design-decisions.md#opentelemetry-sdks-and-auto-instrumentation)

### Why not eBPF (OpenTelemetry eBPF Instrumentation / Beyla)?

eBPF agents cover every pod on a node without touching manifests, read TLS
without a CA, and emit traces. They need a privileged DaemonSet and a recent
kernel with BTF, and derive routes heuristically unless configured. Pick eBPF
when you can run privileged agents and want fleet-wide coverage with zero
per-app work; pick this when you can't, or when you want an in-path proxy you
fully control. [More](design-decisions.md#ebpf-agents)

### Why not ingress-controller metrics or access logs?

Ingress metrics only see traffic entering the cluster, not service-to-service
calls or egress. Access logs can be turned into the same numbers, but you pay
for shipping and storing every line and the metrics arrive late. Here the
proxy counts requests itself and the access log is off by default.
[More](design-decisions.md#access-logs-and-ingress-metrics)

### Why OpenResty and Lua?

A PHP-FPM app already needs a web server, usually nginx, in front of it for FastCGI, so swapping that
nginx for OpenResty adds observability without adding a hop. For apps with no
nginx, this is one more proxy, like any other sidecar.
[More](design-decisions.md#why-openresty)

### Why OpenResty and not stock nginx with the Lua module?

The vendored Prometheus library runs on stock nginx with `lua-nginx-module`,
but this project needs more than that library: `lua-resty-core`, the DNS
resolver, `lua-resty-openssl` and `ngx.ssl` for interception, the stream Lua
module, all at versions that match each other and the nginx core. OpenResty
ships that set released and tested together; building it yourself means
redoing the pairing on every nginx upgrade, and the Lua module's own
maintainers discourage it. Stock nginx's built-in scripting (njs) lacks the
TLS and balancer hooks interception depends on. The cost: OpenResty's releases
trail nginx mainline. [More](design-decisions.md#why-openresty-and-not-stock-nginx)

---

## Architecture

### Why a sidecar per pod and not a shared gateway or DaemonSet?

Blast radius: a broken sidecar takes down one pod, not a node or every app.
It also sees the real caller's IP and runs the app's own nginx config. The
costs are memory per pod (multiplied by pod count) and a manifest change per
Deployment; there is no injection webhook.
[More](design-decisions.md#sidecar-vs-gateway-vs-daemonset)

### Does it change my requests?

Inbound: no. The request reaches the app as the client sent it; nothing is
added, no retries. One consequence: the app sees `127.0.0.1` as the peer and
gets no `X-Forwarded-For` unless you add it in your own `default.conf`.
Outbound: plain HTTP and CONNECT are forwarded as-is; with https interception
TLS is terminated and re-originated (see below).
[More](design-decisions.md#transparency)

### What happens if the sidecar fails?

It's in the data path, so that pod stops serving, and its readiness probe
takes it out of the Service. Errors inside the metrics code during logging
never affect a response; the caller lookup runs before the request is proxied,
its DNS calls are guarded, and the image smoke test fails the build on any Lua
runtime error. [More](design-decisions.md#failure-modes)

### What does it add to latency?

One loopback hop and two small Lua phases per request. The exception: the
first request from a never-seen caller IP waits up to `ptr_sync_timeout`
(100 ms) for a reverse-DNS answer; later requests use the cached answer, which
is refreshed in the background. Set `ptr_sync_timeout = nil` in a mounted
config to never wait (the first requests from that IP then get the fallback
label).
[More](design-decisions.md#latency)

---

## Metrics and labels

### How does it know who called?

By IP: a static subnet table first, then reverse DNS (PTR) against CoreDNS for
pod IPs, refreshed every 15 s. Behind an Istio waypoint it reads the caller from
the waypoint's verified `X-Forwarded-Client-Cert`. No mTLS required.
[More](design-decisions.md#caller-identity)

### Which callers can't it name?

Pods that aren't an endpoint of any Service (workers, consumers, CronJobs)
usually have no PTR record and get the fallback label (`probe_default_service`,
`health-probe` by default). A pod behind several Services is named
after one of them. `hostNetwork` pods share the node's IP. Caller identity is
IPv4-only. [More](design-decisions.md#caller-identity)

### Why do kubelet probes show as `health-probe`?

Probes connect from the node's own IP, which says nothing about the caller.
Requests with `User-Agent: kube-probe/…` are labelled `health-probe` /
`default` instead, whatever their IP. No path is assumed. The header is
client-set, so this only affects a label, never access.

### How are routes kept from exploding cardinality?

Path segments that look like IDs (numbers, UUIDs, hex, long tokens with
digits, file names) collapse to `$param`. It's a heuristic: a slug like
`/restaurants/pizza-house` stays as-is, and a real word with digits can be
collapsed. When an ID leaks through, add a rule; the dashboard's Exporter
health tab shows route cardinality over time.
[More](design-decisions.md#route-sanitizing)

### Why no traces?

Per-route metrics on each hop answer *which* service and route is slow.
*Why one request* was slow across several hops needs traces, and those need
the app to forward `traceparent`, which a proxy can't do for it. That belongs
with app instrumentation, so it's out of scope here.
[More](design-decisions.md#no-traces)

### Why are histograms off by default?

Each histogram is (buckets + 3) series per label combination, the largest
share of memory and scrape size. Without one you get rates, errors and a
last-value latency gauge, but no percentiles. Turn on the ones you query, e.g.
`METRICS_CONFIG="http.metric_latency_hist=true"`, and trim the buckets in a
mounted config if needed. [More](design-decisions.md#histograms)

### Why only some L4 destinations?

L4 is for dependencies that don't speak HTTP: Redis, databases, brokers. Each
is an explicit `server {}` you add, because L4 data between services that
already talk HTTP repeats what L7 shows.
[More](design-decisions.md#l4-stream)

---

## Coverage limits

### Will it see all my egress?

Only what the app sends through `HTTP(S)_PROXY`. It's opt-in, not
enforcement: clients that ignore the proxy variables (PHP stream wrappers, Node
core `http`, Java without system properties) and hosts in `NO_PROXY` bypass it.
HTTPS shows as `CONNECT host:port` unless https interception is on.
[More](design-decisions.md#egress-coverage)

### HTTP/2, gRPC, WebSocket?

WebSocket upgrades pass through. The default inbound server speaks HTTP/1.1
only, so h2c and gRPC aren't covered without your own config.

---

## Operating it

### How much does it cost per pod?

In the production pods we measured: about 15–25 MB working set, almost all
anonymous memory, and well under 0.05 CPU on average. Memory grows mostly with
label combinations (routes × statuses × callers), so cardinality is the lever,
then histograms, then preallocated connections (`worker_connections`, 1024).
One worker process means one core is the ceiling per sidecar.
[More](design-decisions.md#resource-cost)

### What's on by default, what's off?

| On | Off |
|---|---|
| inbound, outbound proxy, counters, last-value gauges, caller labels, probe labelling | histograms, access log, https interception, stream, `client_subnet` |

### How do I turn on https interception?

Set `INTERCEPT_TLS=on` on the nginx container, mount a CA keypair at
`/etc/nginx/intercept/ca.crt` and `ca.key`, and make the app trust `ca.crt`.
It's decided at container start, so it needs a restart, and the container must
not override `command:` (use `args:`). See
[https interception](https-interception.md).

### Is https interception safe?

It's a man-in-the-middle of your own egress. Whoever holds the CA key can
impersonate any site to every pod that trusts it, so scope the CA narrowly and
mount the key only into the nginx container. The real destination is still
verified (`proxy_ssl_verify on`). Hosts the app reaches with its own client
certificate or pins must be bypassed; you see only `host:port` for those.
[More](https-interception.md#security-model)

### How do I keep my company's subnets and zone names out of git?

Keep the image's `metrics_config.lua` generic and mount your own copy from your
internal config repo. It's a full copy, so re-copy it when you upgrade the
image, or new settings will be missing.

### How do I know the exporter itself is healthy?

`nginx_metric_errors_total` must stay at zero; it rises when a shared dict is
full (series are being dropped) or a metric call fails. The dashboard's
Exporter health tab also tracks series per pod and route, host and caller
cardinality.

### Is `/metrics` protected?

No. `:9145` and `:9254` serve metrics without auth, on their own ports so they
never mix with app traffic. Restrict them with a NetworkPolicy if routes or
caller names are sensitive.

### Which version should I run?

Image tags follow docker-openresty (`<openresty-tag>-<flavor>`); pin by digest
in production ([images](images.md)). Project releases (`vX.Y.Z`) mark
capability milestones, and each one's notes list what to check when upgrading
([changelog](../CHANGELOG.md)).
