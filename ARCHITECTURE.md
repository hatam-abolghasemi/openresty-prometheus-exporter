# Architecture & internals

This is the technical breakdown of **openresty-prometheus-exporter**: what each
piece does, why it exists, its requirements, how to verify it, and the
assumptions it makes. For the product overview and quick start, see
[`README.md`](README.md).

The Prometheus client library underneath — `prometheus.lua`,
`prometheus_keys.lua`, `prometheus_resty_counter.lua`, the
counter/gauge/histogram API — is vendored **unmodified** from
[knyar/nginx-lua-prometheus](https://github.com/knyar/nginx-lua-prometheus)
(MIT) under [`vendor/`](vendor/nginx-lua-prometheus/); credit for it is
entirely upstream's. Everything below is this project's own work on top of that
library:

- **`lib/`** — nine small Lua modules. Six are pure logic with no
  environment-specific values (`route_sanitizer`, `host_classifier`,
  `client_subnet`, `gauge_expiry`, `source_attribution`, `app_toggle`),
  kept unit-testable without a running nginx worker. `http_metrics.lua` and
  `stream_metrics.lua` wire all of that into the `prometheus` API. And
  `metrics_config.lua` is plain data — the one file here you're meant to
  edit per deployment.
- **`examples/openresty-sidecar/`** — `default.conf` (HTTP) and
  `stream.conf` (TCP/UDP) show it all wired up; `nginx.conf` ties them
  together; `k8s/` has a runnable, mock-data ConfigMaps + Deployment +
  Service/ServiceMonitor example.

The six pure modules are unit-testable without a running nginx worker (they take
values and return values); the orchestration modules are covered by the image's
build-time smoke test. See [docs/modules.md](docs/modules.md#testing) for how to
test each kind, and [docs/](docs/README.md) for the step-by-step mode guides.

## What each piece does

| Piece | Module | Needs a running nginx worker? |
|---|---|---|
| Route sanitization | `route_sanitizer.lua` | No |
| Client subnet masking | `client_subnet.lua` | No |
| Host classification | `host_classifier.lua` | No |
| Caller identification (`source_service`/`source_namespace`) | `source_attribution.lua` | Only the DNS-resolving part |
| Waypoint / XFCC override | `source_attribution.lua` | No |
| Gauge expiry | `gauge_expiry.lua` | Only `:start()` |
| Per-app metrics toggle | `app_toggle.lua` | No |
| HTTP metrics + forward proxy | `http_metrics.lua` + `default.conf` | Yes |
| Stream (TCP/UDP) metrics | `stream_metrics.lua` + `stream.conf` | Yes |
| Everything's config | `metrics_config.lua` | No — just data |

### Keeping request/response labels low-cardinality

Three small modules exist purely to stop labels from exploding into one
time series per request:

- **`route_sanitizer.sanitize()`** collapses path segments that look like
  IDs — pure numbers, UUIDs, hex tokens, slugs with a trailing digit, long
  alphanumeric tokens, file extensions — into `$param`, so
  `/orders/8231/items/9f8a3c2e-...` becomes `/orders/$param/items/$param`.
  Each check is independently toggleable in `metrics_config.lua`. If a new
  ID convention shows up that none of the checks catch, add a check rather
  than turning sanitization off.
- **`client_subnet.mask()`** truncates an IPv4 address to a `/24` (private
  ranges) or `/16` (public) before it's used as a label — e.g. `10.233.4.17`
  → `10.233.4.0`. IPv6 and unparseable input return `"unknown"`. Off by
  default (`label_client_subnet = false`); the caller-identification labels
  below are usually more useful.
- **`host_classifier.classify()`** turns the `Host` header — fully
  client-controlled — into `"localhost"`, `"kubernetes"` (matched against
  `cluster_ip_prefix`), a generic `"$ip"`, or the real hostname unchanged.
  Get `cluster_ip_prefix` wrong and internal IPs just fall into the generic
  `"$ip"` bucket — harmless, just less informative.

### Caller identification

**`source_attribution.lua`** labels every inbound request with *who called
it*, not just what happened — resolved in order: a hand-maintained
`static_ranges` table for known internal subnets, then reverse-DNS (PTR)
against CoreDNS for the dynamic pod range (cached in a shared dict, with an
in-flight lock so a burst of requests from one uncached IP doesn't fire a
PTR query per request), then a configured fallback if nothing resolves.
Needs CoreDNS to actually have PTR records for pod IPs (not on by default in
every cluster) and `resty.dns.resolver` on `LUA_PATH`.

**Waypoint override.** If you run a service mesh with per-namespace
waypoints (the example assumes Istio ambient mode), a waypoint terminates
and re-originates the connection, so PTR alone only ever resolves to *the
waypoint*, not the real caller. When the resolved caller is the waypoint,
`apply_waypoint_override()` recovers the real identity from the SPIFFE URI
in the mTLS-verified `X-Forwarded-Client-Cert` header instead.

> ⚠️ **This is a trust boundary.** The override only fires once PTR has
> independently confirmed the direct peer really *is* the waypoint —
> trusting an XFCC header from an unverified peer would let any caller
> spoof its reported identity just by setting that header itself. If your
> mesh can let XFCC reach this sidecar from anywhere other than verified
> mTLS termination at the waypoint, this becomes a spoofing vector.

**Own identity (`self_identity.lua`).** The same PTR mechanism also answers
"who am I": at startup each pod finds its own IP (kubelet writes
`<pod-ip> <pod-hostname>` into `/etc/hosts`), reverse-resolves it, and uses
the Service name and namespace it gets back for the outbound leg's
`source_service` and for every `app`/`namespace` label. That's what makes one
shared config safe for several Deployments -- without it, a `metrics_config.lua`
mounted into (say) both `app` and `consumers` pods can hold only one `app`
value, so *every* pod reports itself as that one service. It's on by default
(`http.discover_identity = true`); `http.app` / `http.namespace` become the
fallback used until discovery succeeds. A pod only has a PTR record once it is
a Ready endpoint of a Service, so discovery retries with backoff (5s doubling to
60s) in a timer rather than once at boot, and a pod that never resolves (no PTR
records, `hostNetwork`, no Service) simply keeps the fallback. When the identity
changes from fallback to discovered, the `nginx_http_connections` series
recorded under the fallback are deleted rather than left frozen. Counter
series recorded under the fallback before discovery keep their history.

### Gauges that don't go stale

Prometheus gauges don't self-expire — a gauge set once and never touched
again reports that value forever, which is actively misleading for a
low-traffic route. **`gauge_expiry.lua`** pairs every gauge write with a
timestamp in a shared dict; a 5-second timer sweeps for label combinations
untouched for `expiry_window` seconds and zeroes their gauges. It's used for
request-level gauges (latency, request/response size), connection-level
gauges (`nginx_connection_requests`, `nginx_connection_time_seconds`), and
— on the stream side — the two "last observed value" gauges
(`upstream_connect_time`, `session_duration`). Same module, three call
sites, each with its own shared dict.

If cardinality grows a lot, raise `expiry_scan_limit` so the 5-second sweep
still completes one full pass — but treat that as a symptom, not a fix; the
sanitization modules above are what should be keeping cardinality bounded
in the first place.

### Forward proxy (egress visibility)

A second, loopback-only `server{}` block (`127.0.0.1:3128`) turns this
sidecar into an HTTP/HTTPS forward proxy for the app container's *outbound*
traffic, sharing the same metrics pipeline via the `mode` label (`0` =
inbound, `1` = outbound). Point `HTTP_PROXY`/`HTTPS_PROXY` at it and any
compliant HTTP client routes through automatically. Plain HTTP gets full
method/route/status/timing. HTTPS arrives as `CONNECT host:port`; by default
TLS stays end-to-end and only the `host:port` is recorded — enough for many
apps, and the safe default. When you need the real method/route/status of
outbound HTTPS, enable interception (below).

`CONNECT` is handled by nginx's native `ngx_http_tunnel_module` (`tunnel_pass`),
present in the OpenResty base this image builds on — no third-party module and
no custom build. The `:3128` server's only app-visible knob is its tunnel
target, read from `lib/intercept.lua`:

```
set_by_lua_block $connect_upstream { return require("intercept").upstream() }
if ($request_method = CONNECT) { tunnel_pass $connect_upstream; }
```

With interception off, `upstream()` returns the real `host:port` — identical to
a bare `tunnel_pass;`.

### Seeing outgoing HTTPS details (optional interception)

When `CONNECT host:port` isn't enough and you need the real method, route and
status of outbound HTTPS, the sidecar can intercept it: a loopback terminator
(`127.0.0.1:3129`, baked into the image via `conf.d/intercept.conf` +
`lib/tls_intercept.lua`) mints a per-SNI leaf cert signed by a CA you provide,
records the decrypted request, and re-originates to the real destination over a
**verified** TLS connection (`proxy_ssl_verify on`). Off unless turned on, per
app. All the machinery is baked in; a deployment enables it with one env var and
a mounted CA.

**On the sidecar** (nginx container): set `INTERCEPT_TLS=on` and mount a CA
keypair at `/etc/nginx/intercept/ca.crt` + `ca.key` (nginx only — the app never
gets the key). Optional: `INTERCEPT_TLS_PORTS` (comma list, default `443`) and
`INTERCEPT_BYPASS` (hosts to leave as plain CONNECT — outbound-mTLS or
cert-pinned destinations). The switches are declared for workers in the baked
`main.d/intercept-env.conf`, so `nginx.conf` needs no change.

**On the app** — two things, and only the second differs per language:

1. *Route egress through the proxy.* Set `HTTP_PROXY`/`HTTPS_PROXY` (and the
   lowercase forms) to `http://127.0.0.1:3128`. If you already use the forward
   proxy in CONNECT mode, this is done.
2. *Trust the CA*, or the client rejects the minted cert:

   | runtime | trust the CA via |
   |---|---|
   | libcurl / curl | `CURL_CA_BUNDLE`, or PHP `curl.cainfo` |
   | Python `requests` | `REQUESTS_CA_BUNDLE` |
   | Node.js | `NODE_EXTRA_CA_CERTS` *(appends)* |
   | Go | `SSL_CERT_FILE` / `SSL_CERT_DIR` |
   | .NET | OS trust store (`update-ca-certificates`), or `SSL_CERT_FILE` / `SSL_CERT_DIR` |
   | Java | `keytool -import` into the JVM truststore |
   | generic OpenSSL | `SSL_CERT_FILE` / `SSL_CERT_DIR` |

> **Replace vs append.** Most of these (`curl.cainfo`, `REQUESTS_CA_BUNDLE`,
> `SSL_CERT_FILE`) *replace* the trust store, so the client then trusts **only**
> your CA — complete when every TLS destination it reaches is intercepted
> (proxy-only egress, all on an intercepted port, nothing bypassed). If the same
> client also reaches TLS you don't intercept, give it a combined bundle (system
> CAs + your CA) or use an appending mechanism (`NODE_EXTRA_CA_CERTS`, or the OS
> trust store via `update-ca-certificates`).

**PHP (php-fpm).** Trust the CA in `php.ini`, mount `ca.crt` (cert only) into the
app at `/etc/intercept/ca.crt`, and make sure the proxy vars reach the workers
(`clear_env = no` in `www.conf`, inheriting the container env, or
`env[HTTPS_PROXY] = ...` explicitly):

```ini
[curl]
curl.cainfo = /etc/intercept/ca.crt
```

`curl.cainfo` only affects libcurl, so PDO/MySQL TLS and the like are untouched.

**.NET.** `HttpClient` reads `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` from the
environment automatically (Linux, .NET Core 3.1+), so egress routing needs no
code. For trust, .NET validates against the OS store via OpenSSL: add your CA to
it — copy `ca.crt` into `/usr/local/share/ca-certificates/` and run
`update-ca-certificates` in the app image (this *appends*, so public TLS keeps
working) — or point `SSL_CERT_FILE` at a bundle that includes your CA (replace
caveat above). Don't reach for a per-call
`ServerCertificateCustomValidationCallback` that returns `true`: that disables
verification instead of trusting your CA.

**The CA.** One per namespace, key in a Secret, never in git:

```
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout ca.key -out ca.crt -subj "/CN=<namespace>-intercept-ca"
kubectl -n <namespace> create secret generic intercept-ca \
  --from-file=ca.crt=ca.crt --from-file=ca.key=ca.key
```

Mount that Secret into nginx (`ca.crt`+`ca.key`) and, with `subPath: ca.crt`,
into the app (cert only). Rotate by recreating the Secret and restarting the
pod. The CA is a trust anchor — whoever holds the key can impersonate any site
to every pod that trusts it — so scope it to one namespace with tight RBAC.

### Stream (TCP/UDP) proxy metrics

`stream.conf` / `stream_metrics.lua` is the stream-module counterpart to
the above, for anything proxied at the TCP/UDP layer (Redis in the
example): connection counts, bytes sent/received, session duration, and
upstream connect-time/first-byte-time. It keeps its own Prometheus registry
on its own port (`:9254`) rather than sharing the HTTP side's `/metrics`,
because nginx can't share a shared dict between the http and stream modules
(see upstream's own [Usage in stream
module](README.md#usage-in-stream-module) note). Each destination gets its
own `server{}` block with `set $destination_name "..."`, feeding both the
`destination` label and the per-app toggle below; needs
`ngx_stream_lua_module` (stock in OpenResty) and its own Prometheus scrape
job.

### Per-app metrics toggle

`app_toggle.enabled(apps, key)` lets you turn off metrics for one leg of
traffic — the forward-proxy leg (`apps.forward_proxy`) or one stream
destination (`apps.stream.<name>`) — without touching the traffic itself.
No entry, or an entry without `metrics_enabled = false`, means enabled: this
is opt-out, not opt-in, so a new destination gets metrics by default.

---

## Known issue corrected in this project

Upstream's version of this config hardcoded the `/metrics` endpoint's own
connection-metric labels as string literals that had drifted from the
`app`/`namespace` values used everywhere else — silently splitting one
time series into two. This project reads them from `metrics_config.lua`
consistently instead. If you maintain copies of this config elsewhere,
check for the same drift.

---

## Using this project

**Just the library, no additions** — this project behaves exactly like
upstream; point `lua_package_path` at the repo root and use `prometheus.lua`
directly. See the upstream `README.md` above for the full API.

**The full sidecar example** — add `lib/` to `lua_package_path` alongside
the repo root, then either pull in one module you want (they're all
independent — e.g. `require("route_sanitizer").sanitize(ngx.var.request_uri)`
in your own `log_by_lua_block`), or copy `default.conf`/`stream.conf`
as-is and edit `lib/metrics_config.lua` for your environment (app/namespace
names, `static_ranges`, `ptr_dns_server`, `cluster_ip_prefix`). The
forward-proxy leg works out of the box — CONNECT uses nginx's native tunnel
module, no patched build; to decrypt outbound HTTPS see "Seeing outgoing HTTPS
details".

**As a Kubernetes sidecar** — `examples/openresty-sidecar/k8s/` has a
complete, mock-data example: ConfigMaps for `nginx.conf`/`default.conf`/
`stream.conf`/`metrics_config.lua`, a Deployment showing the app+nginx
container pair, and a Service/ServiceMonitor exposing both metrics
endpoints. Replace every mock name, image, and label before applying.

Either way, `/metrics` starts returning labeled series immediately — nginx
loads `.lua` files from `lua_package_path` at request time, no build step
needed for the Lua side.

---

## Prebuilt image

`.github/workflows/openresty-image.yml` watches
[openresty/docker-openresty](https://github.com/openresty/docker-openresty/tags)
every 6 hours. When a new `<openresty-version>-<revision>` tag appears and its
official `openresty/openresty:<tag>-alpine` image is on Docker Hub, it layers
this repo on top of that image (`docker/Dockerfile`), smoke-tests the result,
and pushes. Nothing is compiled. If the tag is not on Docker Hub yet, the run
skips and the next one checks again.

| Tag | Meaning |
|---|---|
| `ghcr.io/hatam-abolghasemi/openresty-prometheus-exporter:<openresty-version>` | e.g. `1.31.1.1`: newest build for that OpenResty version |
| `ghcr.io/hatam-abolghasemi/openresty-prometheus-exporter:<upstream-tag>` | e.g. `1.31.1.1-4`: that docker-openresty release, rebuilt when this repo changes |
| `ghcr.io/hatam-abolghasemi/openresty-prometheus-exporter:<upstream-tag>-<sha7>` | immutable: that release + this commit |
| `ghcr.io/hatam-abolghasemi/openresty-prometheus-exporter:latest` | newest upstream release |

Pushes to `main` that touch the Lua or `docker/` rebuild the newest upstream
release; `workflow_dispatch` builds any tag (OpenResty 1.31+, for native
CONNECT support).

Inside the image:

- `/opt/prometheus/` holds `prometheus*.lua` and `lib/`; mount your own
  `lib/metrics_config.lua` over the baked one, as before.
- `/etc/nginx/nginx.conf` (`/usr/local/openresty/nginx/conf/nginx.conf` is a
  symlink to it) and `/etc/nginx/conf.d/default.conf` are a transparent
  default: `:80` reverse-proxies to `127.0.0.1:$APP_PORT` (default `8080`)
  without touching the request, `127.0.0.1:3128` is the forward proxy, and
  `:9145` serves `/metrics`, `/nginx_status` and `/healthz`.
- Stream is off. Drop a file containing
  `stream { include /etc/nginx/stream.d/*.conf; }` into `/etc/nginx/main.d/`
  and your `stream.conf` into `/etc/nginx/stream.d/` to turn it on.

The forward proxy uses nginx's native CONNECT support
(`ngx_http_tunnel_module`, nginx 1.31+, built by default), so no third-party
module or core patch is needed. CONNECT goes to `tunnel_pass`, everything else
to `proxy_pass`:

```
location / {
    if ($request_method = CONNECT) {
        tunnel_pass;
    }
    proxy_pass http://$http_host$request_uri;
}
```

`tunnel_pass` handles only CONNECT (405 otherwise) and a location takes one
handler, so the `if` is what lets one listener serve both. This replaces
`ngx_http_proxy_connect_module`, whose upstream patch stops at nginx 1.27.

Local build:

```
docker buildx build --build-arg OPENRESTY_TAG=1.31.1.1-4 \
  -f docker/Dockerfile -t openresty-prometheus:local .
```

---

## Changelog

Dated entries for this project's own additions. Upstream's `CHANGELOG.md` is
unaffected — none of its files are touched here.

>### 2026-10-20

- **Optional HTTPS interception** for the forward proxy — record the real
  method/route/status of outbound HTTPS instead of only `CONNECT host:port`.
  The machinery is baked into the image: `lib/intercept.lua` (the per-CONNECT
  decision), `conf.d/intercept.conf` (the `ssl_mint_cache` dict and the
  `127.0.0.1:3129` TLS terminator, which mints per-SNI leaf certs via
  `lib/tls_intercept.lua` and re-originates over verified TLS), and
  `main.d/intercept-env.conf` (declares the env switches for workers). An app's
  `default.conf` opts in with one line in its `:3128` block —
  `tunnel_pass $connect_upstream;` fed by `require("intercept").upstream()` —
  so no maps, dict or `:3129` server live in `default.conf`. Off by default:
  with `INTERCEPT_TLS` unset the proxy passes CONNECT through unchanged and
  `:3129` stays idle. Enable per deployment with `INTERCEPT_TLS=on` plus a
  mounted CA (nginx gets `ca.crt`+`ca.key`; the app trusts `ca.crt`); ports
  default to 443 (`INTERCEPT_TLS_PORTS`), mTLS/pinned hosts go in
  `INTERCEPT_BYPASS`. `record()` counts each call once via `intercept.should()`,
  so routing and metrics share one decision. See "Seeing outgoing HTTPS
  details".

### 2026-10-19

- The image is now `FROM openresty/openresty:<tag>-alpine` (official, current
  Alpine) instead of compiling docker-openresty's `alpine/Dockerfile`:
  `docker-bake.hcl` is gone, builds take seconds, and a release is built once
  its official image is on Docker Hub. The forward proxy stays on nginx's
  native CONNECT support, with no third-party module.
- `lib/http_metrics.lua`: requests nginx rejects before the access phase (400,
  405, 413, `deny`) are recorded with `source_service="unknown"` instead of
  failing with "incorrect label count".

### 2026-10-17

- Added `.github/workflows/openresty-image.yml`, `docker-bake.hcl` and
  `docker/`: an image built from each new docker-openresty release with this
  repo baked in (see "Prebuilt image" above).
- `lib/metrics_config.lua`: restored the `own_namespace` lookup (lost in
  `4da5d7e`, which left `http.namespace` as `nil` and made every
  connection metric fail with "incorrect label count"), and
  `ptr_dns_server` now defaults to the first nameserver in
  `/etc/resolv.conf` instead of a hardcoded IP.

### 2026-09-20

- Fixed `nginx_stream_connections_active` always reporting 0. It was read
  from `$connections_active` and friends, which come from
  `ngx_http_stub_status_module` and don't exist in the stream module (the
  `or 0` fallback hid that). The gauge is now maintained by hand: `+1` from
  the new `stream_metrics.connection_open()` (call it from
  `preread_by_lua_block` in every stream `server{}`), `-1` from `record()`.
  Only `state="active"` is exported now; `reading`/`writing`/`waiting` have
  no stream equivalent and were removed. A `server{}` without the preread
  hook is simply not counted.
- Added `lib/self_identity.lua` and `Resolver:resolve_ptr()`: the pod's own
  service/namespace is now discovered via PTR instead of read from
  `metrics_config.lua`'s `http.app`/`http.namespace` (kept as fallback; turn off
  with `http.discover_identity = false`). Fixes every pod sharing a config
  reporting itself as one hard-coded service. `http_metrics.lua` now reads
  identity through `own()` for the outbound `source_service`, the `app` and
  `namespace` labels, and the connection gauges.

### 2026-09-18

- Added `lib/app_toggle.lua`, wired into `default.conf` (forward-proxy leg)
  and `stream.conf` (per-destination).
- Added `examples/openresty-sidecar/stream.conf`: full TCP/UDP proxy
  metrics, reusing `lib/gauge_expiry.lua`.
- Added `examples/openresty-sidecar/nginx.conf` and
  `examples/openresty-sidecar/k8s/` (mock-data ConfigMaps, a sample sidecar
  Deployment, a Service/ServiceMonitor pair) so the example deploys
  end-to-end instead of just being read.
- Restructured `default.conf`/`stream.conf` down to wiring + `server{}`
  blocks only (397 → 91 and 231 → 60 lines). Added `lib/metrics_config.lua`
  (all environment-specific values) and `lib/http_metrics.lua`/
  `lib/stream_metrics.lua` (the orchestration that used to be inline,
  now proper modules built on the existing pure `lib/` modules).
