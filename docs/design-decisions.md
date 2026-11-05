# Design decisions and trade-offs

The reasoning behind the [FAQ](faq.md): what this project chose, what it gave
up, and when another tool is the better fit. Mechanics are in
[ARCHITECTURE.md](../ARCHITECTURE.md) and [modules](modules.md).

---

## Scope

The goal is L7 RED metrics (rate, errors, duration) per route for each app,
including who called it and whom it called, plus a few L4 dependencies. It
stays a sniffer: it doesn't retry, rewrite, rate-limit or route traffic.

Out of scope on purpose: traces, traffic management, mTLS, enforcement of
egress policy.

---

## Alternatives

### Service mesh (Istio, sidecar or ambient)

| | Mesh | This project |
|---|---|---|
| Rollout | Namespace label or injection | Manifest change per Deployment |
| Control plane | Yes (istiod) | None |
| Route in request metrics | Not by default (`istio_requests_total` has no path label; can be added via Telemetry API) | Yes, sanitized |
| L7 in ambient | Needs a waypoint (Envoy) per namespace or service: an extra hop | In the pod |
| Caller identity | From mTLS certificates: exact, cheap | From IP + PTR: no mTLS needed, has gaps (see below) |
| Egress coverage | Enforced by traffic redirection | Opt-in via `HTTP(S)_PROXY` |
| Also gives | mTLS, retries, traffic shifting, policy | Nothing beyond metrics |

**Choose the mesh** when you need what it also gives. Then its metrics come
for free and this project mostly duplicates them. **Choose this** when
metrics are the only goal and a control plane isn't justified. The two can
coexist: behind an Istio waypoint this project reads the real caller from
`X-Forwarded-Client-Cert` ([caller identity](#caller-identity)).

### OpenTelemetry SDKs and auto-instrumentation

In-process instrumentation knows the framework's matched route template
(`http.route`), sees DB and cache calls without a proxy, sees outbound HTTPS
before encryption, and produces traces. Its cost is per language: SDK or agent
setup, build or image changes, and for some runtimes (PHP) extensions and
packages in the app image. Zero-code agents for Java and .NET make this cheap
for those runtimes.

This project needs no app change and treats every runtime the same, but knows
routes only by pattern and produces no traces. They don't conflict; running
both is reasonable.

### eBPF agents

OpenTelemetry eBPF Instrumentation (OBI, formerly Grafana Beyla) and similar
agents run as one privileged DaemonSet per node, instrument every process on
it without manifest changes, read TLS traffic by hooking TLS libraries (no CA),
add Kubernetes metadata to both ends, and can emit traces.

Costs: privileged pods with kernel access (a security review item), a recent
kernel with BTF, routes derived by heuristics unless configured, and a node-wide
agent as the failure domain. **Choose eBPF** for zero per-app work across a
fleet. **Choose this** when privileged agents aren't allowed, kernels are old,
or you want a proxy in the path you fully control and can read.

### Access logs and ingress metrics

Ingress-controller metrics see only north-south traffic. Deriving metrics from
access logs works for any traffic but costs a write per request, shipping and
storage, and the numbers arrive after the pipeline's delay. This project
counts in the proxy and keeps the access log off by default.

`stub_status`-based exporters only report connection counts. nginx's VTS
module needs a custom build and its own key design to get per-route data.

### Why OpenResty

PHP-FPM speaks FastCGI, so those pods already run a web server, usually nginx.
Replacing it with OpenResty adds Lua, not a hop. Lua runs in the nginx worker,
so there's no separate exporter process.

For apps that serve HTTP themselves (.NET, Go, Node), the sidecar is an
additional proxy, and the comparison with any other sidecar (Envoy included)
is on footprint and configuration model: this one needs no xDS or control
plane, Envoy has richer L7 features.

### Why OpenResty and not stock nginx

The vendored [nginx-lua-prometheus](https://github.com/knyar/nginx-lua-prometheus)
works on any nginx with `lua-nginx-module`. This project depends on more than
that library, and that's what makes stock nginx the harder path:

- **Matched versions.** `lua-nginx-module` needs `lua-resty-core` and
  `lua-resty-lrucache` at matching versions, and LuaJIT (OpenResty maintains
  its own branch). A dynamic module must be built against the exact nginx
  version it loads into, so every nginx upgrade is a rebuild. The module's
  own README discourages building it into nginx yourself.
- **More libraries.** Caller identity uses `resty.dns.resolver`; https
  interception uses `lua-resty-openssl` and `ngx.ssl`; stream needs
  `ngx_stream_lua_module`. OpenResty bundles all of them.
- **Distro packages lag.** Packages like Debian's `libnginx-mod-http-lua`
  follow the distro's nginx and Lua module versions, not the ones this code is
  tested against.
- **njs isn't a substitute.** Stock nginx's JavaScript module has shared
  dictionaries and timers, but no per-handshake TLS hook, no per-request
  upstream balancer and no certificate generation, so https interception and
  pooled re-origination can't be built on it.
- **One tested artifact.** The image is rebuilt and smoke-tested for every
  docker-openresty release; a self-built nginx + module is tested by you.

The trade-off: OpenResty releases follow nginx mainline with a delay, so new
nginx features arrive late. Native CONNECT (`tunnel_pass`) was only usable once
OpenResty moved to nginx 1.31. Running on your own nginx stays possible
([standalone nginx](standalone-nginx.md)); it's just not the supported path.

---

## Sidecar vs gateway vs DaemonSet

| | Sidecar (this) | Central gateway | Per-node DaemonSet |
|---|---|---|---|
| Blast radius of a bad config or crash | One pod | Every app behind it | Every pod on the node |
| Sees the real caller IP | Yes | Only if forwarded | Only if traffic is redirected |
| Runs the app's own nginx config | Yes | No, shared | No, shared |
| Memory | Per pod × pods | One instance | Per node |
| Rollout | Manifest change per Deployment | Routing change | Traffic redirection (iptables/eBPF) |
| Upgrade | Rolls with the app | One rollout, all apps at once | Per node |

The sidecar costs more memory in total and needs per-Deployment changes (no
injection webhook exists yet). It was chosen for isolation and the real caller
IP. GitOps keeps the per-app manifests manageable, but it is real work at scale.

---

## Transparency

Inbound forwards the request as received: original `Host`, raw URI, headers
with underscores, any body size, WebSocket upgrades. It adds no
`X-Forwarded-*` and doesn't retry (`proxy_next_upstream off`), so app behaviour
doesn't change.

The trade-off is that the app sees `127.0.0.1` as the client. If the app needs
the client IP, add `X-Forwarded-For` in your own `default.conf`; that's a
deliberate request change, made per app.

---

## Failure modes

- **Sidecar down:** it's in the data path, so the pod stops serving. Point the
  readiness probe at the sidecar's port (as the example does) so the pod leaves
  the Service when that happens.
- **Lua error during logging** (`log_by_lua`): the response is already sent;
  only that request's metrics are lost.
- **Lua error during caller lookup** (`access_by_lua`, before proxying): it
  would fail that request. The DNS calls there are wrapped in `pcall`, and the
  image smoke test fails the build on any Lua runtime error in the logs.
- **Shared dict full:** new series are dropped and `nginx_metric_errors_total`
  rises. Traffic is unaffected. Fix cardinality, or raise the dict size.
- **CoreDNS slow or down:** new callers get the fallback label; known callers
  keep their last answer. Traffic is unaffected beyond the first-request wait
  below.
- **`INTERCEPT_TLS=on` but interception not loaded** (container `command:`
  skipped the entrypoint): interception stays off, CONNECTs tunnel unchanged,
  one error is logged per worker.

---

## Latency

Per request: one loopback proxy hop, plus the access-phase caller lookup and
the log-phase recording. Known callers are a shared-dict read.

A caller IP the sidecar has never seen is resolved inline with a
`ptr_sync_timeout` budget (100 ms), so that one request can wait up to 100 ms.
Other requests from the same IP arriving meanwhile don't wait: they get the
fallback label while the one lookup runs.
Set it to `nil` to resolve only in the background, at the cost of the first
requests from a new IP being labelled with the fallback.

---

## Caller identity

**How:** static subnet table → PTR against CoreDNS → fallback. Answers are
kept until replaced and every active IP is re-resolved every
`ptr_refresh_interval` (15 s). IPs idle for `ptr_forget_after` (5 min) are
dropped.

**Why PTR and not mTLS:** no certificates, no control plane, works for callers
outside any mesh. **Why not a Kubernetes API watcher:** PTR needs no extra
component and no RBAC. A node-local agent mapping IPs to pods from the API
would be more exact; it isn't built.

**Gaps:**
- Pods that aren't an endpoint of a Service usually have no PTR record, so
  workers, consumers and CronJobs get the fallback label.
- A pod behind several Services has several PTR records; the alphabetically
  first name not matching `ptr_ignore_services` wins.
- `hostNetwork` pods and kubelet share the node IP. Kubelet probes are
  recognised by `User-Agent: kube-probe/…` instead.
- IPv4 only.
- When Kubernetes reuses a pod IP, the old name can last until the next
  refresh, at most one 15 s interval.

**Load:** each sidecar re-resolves its active callers every 15 s, so CoreDNS
sees roughly `sidecars × active callers per sidecar / 15` queries per second,
mostly cache hits.

**Behind an Istio waypoint**, PTR resolves to the waypoint. The real caller is
then read from the SPIFFE ID in `X-Forwarded-Client-Cert`, and only after PTR
has confirmed the peer *is* the waypoint. Trusting XFCC from any other peer
would let callers spoof their identity; keep that ordering if you change it.

---

## Route sanitizing

Paths become routes by collapsing segments that look like IDs into `$param`
(numbers, UUIDs, hex, `-123` suffixes, long tokens with digits, file names).

Compared with a framework's route template (`http.route`), this is a
heuristic, and it errs both ways: an ID made of letters only (a slug) stays and
can raise cardinality; a meaningful segment with a digit and longer than
`min_len` (say `oauth2`) is collapsed. Getting the exact template would need
the app's router, which means code in the app, which this project avoids.

When an ID convention leaks through, add a sanitizer rule rather than dropping
the `route` label. The dashboard's Exporter health tab shows distinct routes
per pod over time, which is where a leak shows up first.

---

## No traces

Metrics on every hop (inbound per route, outbound per host) locate the slow
service and route. They can't explain one slow request across several hops,
because percentiles don't add up across calls. That takes traces, and traces
need each app to propagate `traceparent` from its inbound request to its
outbound calls, which a proxy can't do on the app's behalf.

So request-level causality is left to app instrumentation (OpenTelemetry). If
call chains are shallow, per-edge metrics are usually enough; deep fan-out is
where traces start to matter.

---

## Histograms

A histogram stores (buckets + 3) series per label combination: with the
default 16 latency buckets, 19 series for each method × route × status × host ×
caller combination. That dominates the `prometheus_metrics` shared dict and the
scrape. So every histogram is off by default.

What you lose without them: percentiles and mean latency. What remains:
counters (rate, errors) and last-value gauges, which sample one request per
series per scrape and are expired when idle. Turn on the histograms you query,
on the services where latency matters, and consider fewer buckets in a mounted
config.

---

## L4 (stream)

L4 is for dependencies that don't speak HTTP: Redis, databases, brokers. Each
destination is an explicit `server {}` the app connects to instead of the real
address; nothing is captured implicitly. Between services that already talk
HTTP through the sidecar, connect errors and connect time are already visible
at L7, so L4 there would repeat them. Packet loss and retransmits are a node
concern (node exporter), not something either layer here measures.

---

## Egress coverage

Outbound works only for traffic the app sends to `127.0.0.1:3128`. It is
opt-in, not enforcement:

- Clients that ignore `HTTP(S)_PROXY` bypass it: PHP stream wrappers, Node's
  core `http`, Java without `-Dhttps.proxyHost`. PHP-FPM also needs
  `clear_env = no` to pass the variables to workers.
- Hosts in `NO_PROXY` bypass it by design.
- HTTPS is seen as `CONNECT host:port` (which host, how long, tunnel status),
  not method, route or status, unless https interception is on.

If you need every egress connection counted regardless of the client, that
takes traffic redirection (a mesh or eBPF), not a forward proxy.

---

## Resource cost

Measured in production pods running this sidecar: about 15–25 MB working set,
almost all anonymous memory (the nginx worker's Lua state, shared dicts and
connection structures), and well under 0.05 CPU on average.

Where memory goes, in order of what to tune:

1. **Label combinations.** Every series is stored in the shared dict and
   indexed per worker. Routes × statuses × callers is the driver.
2. **Histograms.** (buckets + 3) series each; off by default.
3. **Preallocated connections.** `worker_connections` (1024 in the image) are
   allocated at start, a few hundred bytes each.
4. **https interception.** When on, OpenSSL and the system CA bundle are
   loaded; when off, none of it is.

One worker process means one CPU core is the ceiling per sidecar; raise
`worker_processes` in a mounted `nginx.conf` for very busy pods. Each proxied
request uses two connection slots; `nginx_connection_slots_limit` against
slots in use shows the headroom.

Compiled-in nginx modules and unused bundled Lua libraries cost next to
nothing (shared code pages; Lua libraries load only when required), so a
custom stripped build isn't worth it.

---

## Configuration

- **`METRICS_CONFIG`** env var: switches, numbers and strings, no file to
  maintain. Read at start.
- **Mounted `metrics_config.lua`:** needed for tables (subnet ranges, buckets,
  sanitizer set). It replaces the whole file, so it must be re-copied from the
  image version you run, or new settings will be missing. This is also how
  site data (internal subnets, zone names) stays out of this repository.
- **Mounted `nginx.conf` / `default.conf`:** take full control, and with it
  the image's defaults no longer apply (access log, `worker_connections`).
