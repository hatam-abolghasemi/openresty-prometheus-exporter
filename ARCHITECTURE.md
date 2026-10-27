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

- **`lib/`** — twelve small Lua modules. Six are pure logic with no
  environment-specific values (`route_sanitizer`, `host_classifier`,
  `client_subnet`, `gauge_expiry`, `source_attribution`, `app_toggle`),
  tested without a running nginx worker (`tests/`). `http_metrics.lua` and
  `stream_metrics.lua` wire all of that into the `prometheus` API;
  `self_identity.lua`, `intercept.lua` and `tls_intercept.lua` cover own
  identity and https interception. `metrics_config.lua` is plain data — the
  one file here you're meant to edit per deployment.
- **`docker/`** — the image: `nginx.conf`, `conf.d/default.conf` (the inbound
  and outbound servers, `/metrics`), `conf.d/intercept.conf` (https
  interception) — the reference config for every feature.
- **`examples/openresty-sidecar/`** — a runnable, mock-data Kubernetes
  example: the app + sidecar Deployment with inbound, outbound and stream on,
  `stream.conf`, Service/ServiceMonitor, kustomization.

The six pure modules are unit-testable without a running nginx worker (they take
values and return values); the orchestration modules are covered by the image's
build-time smoke test. See [docs/modules.md](docs/modules.md#testing) for how to
test each kind, and [docs/](docs/README.md) for the step-by-step feature
guides: inbound, outbound, https interception (builds on outbound), stream.

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
| inbound + outbound metrics | `http_metrics.lua` + `docker/conf.d/default.conf` | Yes |
| https interception | `intercept.lua` + `tls_intercept.lua` + `docker/conf.d/intercept.conf` | Yes |
| stream (TCP/UDP) metrics | `stream_metrics.lua` + `stream.conf` | Yes |
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
against CoreDNS for the dynamic pod range, then a configured fallback if
nothing resolves.

PTR answers live in a shared dict and are **kept until a new answer replaces
them** -- age alone never drops a caller back to the fallback, so a caller
that shows up once every few minutes keeps its name. One worker re-resolves
every known IP each `ptr_refresh_interval` (15s). Keep that at or below the
Prometheus scrape interval: when Kubernetes hands an IP to a pod in another
namespace, at most one scrape carries the old name. Each lookup ends as
*found* (store it), *none* -- NXDOMAIN, nothing in the cluster owns the IP --
(store the fallback, a real "unknown"), or *error* -- timeout, SERVFAIL --
(keep what's stored). A never-seen IP is resolved inline in the access/preread
phase with a `ptr_sync_timeout` (100ms) budget, falling back to a background
lookup on error; an in-flight lock keeps a burst from one new IP to one query.
IPs no request has come from for `ptr_forget_after` (5 min) are dropped, so only active callers are refreshed; a caller that returns later is resolved inline again. When a
pod sits behind several Services it has one PTR record per Service; the
alphabetically first name not matching `ptr_ignore_services` wins, so the
label doesn't flip between them. Staleness is also bounded by the DNS
server's own cache: point `ptr_dns_server` at CoreDNS rather than a node-local
cache if that cache holds PTR answers longer than the scrape interval.
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
the Service name and namespace it gets back for outbound's
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

### outbound (egress visibility)

A second, loopback-only `server{}` block (`127.0.0.1:3128`) turns the sidecar
into an HTTP/HTTPS forward proxy for the app container's *outbound* traffic,
sharing the same metrics pipeline via the `mode` label (`"0"` = inbound, `"1"`
= outbound). Point `HTTP_PROXY`/`HTTPS_PROXY` at it and any compliant HTTP
client routes through automatically. Plain HTTP gets full
method/route/status/timing. HTTPS arrives as `CONNECT host:port`; by default
TLS stays end-to-end and only the `host:port` is recorded — enough for many
apps, and the safe default.

`CONNECT` is handled by nginx's native `ngx_http_tunnel_module` (`tunnel_pass`,
nginx 1.31+, built by default), so no third-party module or core patch is
needed — this replaces `ngx_http_proxy_connect_module`, whose upstream patch
stops at nginx 1.27. `tunnel_pass` handles only CONNECT and a location takes
one handler, so an `if` lets one listener serve both; the tunnel target comes
from `lib/intercept.lua`, which is the only hook https interception needs:

```
set_by_lua_block $connect_upstream { return require("intercept").upstream() }
if ($request_method = CONNECT) { tunnel_pass $connect_upstream; }
```

With interception off, `upstream()` returns the real `host:port` — identical to
a bare `tunnel_pass;`.

### https interception (depends on outbound)

When `CONNECT host:port` isn't enough, the sidecar can decrypt outbound HTTPS:
`:3128` hands an intercepted CONNECT to a loopback terminator
(`127.0.0.1:3129`, `docker/conf.d/intercept.conf`), which mints a per-SNI leaf
cert signed by a CA you mount (`lib/tls_intercept.lua`), records the decrypted
request with the same `record()`, and re-originates to the real destination
over **verified** TLS (`proxy_ssl_verify on` against
`/etc/nginx/intercept/trusted-ca.crt`, the distro bundle). Because it only ever
sees CONNECTs that reached `:3128`, it does nothing without outbound.

Off unless `INTERCEPT_TLS=on` and a CA keypair is mounted at
`/etc/nginx/intercept/ca.crt` + `ca.key` (nginx only — the app gets the cert,
never the key). `INTERCEPT_TLS_PORTS` (default `443`) and `INTERCEPT_BYPASS`
(mTLS / cert-pinned hosts) narrow it. `intercept.should()` is the single
decision for both routing and counting, so an intercepted call is recorded once
(decrypted), never also as its outer CONNECT.

The CA is a trust anchor — whoever holds its key can impersonate any site to
every pod that trusts it. The per-runtime trust setup (PHP, .NET, Node, Go,
Java), the replace-vs-append caveat, and the security model are in
[docs/https-interception.md](docs/https-interception.md).

### stream (TCP/UDP)

`stream.conf` / `stream_metrics.lua` is the stream-module counterpart, for
anything proxied at L4 (Redis in the example): connection counts, bytes,
session duration, upstream connect and first-byte time. It keeps its own
Prometheus registry on its own port (`:9254`) rather than sharing `:9145`,
because nginx can't share a shared dict between the http and stream modules.
Each destination gets its own `server{}` with `set $destination_name "..."`,
feeding both the `destination` label and the per-destination toggle below. A
stream server speaks raw TCP, so the exposition server's `collect()` parses
the scraper's HTTP request and writes the HTTP response itself. Independent of
the HTTP features; off in the image until a `stream {}` include is mounted.

### Per-leg metrics toggle

`app_toggle.enabled(apps, key)` turns off metrics for one leg of traffic —
outbound (`apps.outbound`) or one stream destination (`apps.stream.<name>`) —
without touching the traffic itself. No entry, or an entry without
`metrics_enabled = false`, means enabled: opt-out, not opt-in, so a new
destination gets metrics by default.

---

## The image

`.github/workflows/openresty-image.yml` follows
[openresty/docker-openresty](https://github.com/openresty/docker-openresty)
every 6 hours. For the newest `<openresty-version>-<revision>` release it reads,
from Docker Hub, every flavor upstream published (`<release>-<flavor>` tags,
minus the per-arch ones) and the platforms each flavor has, then runs one
matrix job per flavor: layer this repo onto
`openresty/openresty:<release>-<flavor>` (`docker/Dockerfile`), smoke-test the
amd64 build (inbound, outbound, and https interception with a throwaway CA),
and push all platforms. Nothing is compiled. Flavors that aren't
on Docker Hub yet are picked up by a later run; on a schedule, flavors whose
image already exists are skipped. Pushes to `main` that touch `lib/`,
`vendor/` or `docker/` rebuild every flavor of the newest release;
`workflow_dispatch` takes any release (OpenResty 1.31+, for native CONNECT) and
an optional flavor list.

Tags are docker-openresty's, under `ghcr.io/<owner>/openresty-prometheus-exporter`:

| Tag | Meaning |
|---|---|
| `<release>-<flavor>` | that release and flavor, rebuilt when this repo changes |
| `<version>-<flavor>` | newest revision of that OpenResty version |
| `<series>-<flavor>` | newest release in that series |
| `<flavor>` | newest release |
| `latest` | newest release, `alpine` (`LATEST_FLAVOR`; upstream's own `latest` is bookworm) |

Pin by digest for an immutable reference; `org.opencontainers.image.revision`
names the commit.

After the builds, a `catalog` job reads the newest release's images back from
GHCR and rewrites `docs/images.md` (flavors, tags, platforms, pull commands,
digests), committing only when it changed. It runs on every scheduled run too,
so the file catches up with flavors that appear later. No release number is
written by hand anywhere else in the docs. `retry.yml` re-runs the failed jobs
of a failed image run, up to 2 times.

One `docker/Dockerfile` serves every flavor. `docker/setup.sh` adapts what
differs between them: it asks `nginx -V` for the config path (so
`/usr/local/openresty-debug/...` works too) and links it to
`/etc/nginx/nginx.conf`; it installs `ca-certificates` where the flavor lacks
it (Alpine) and links whichever bundle the distro has to
`/etc/nginx/intercept/trusted-ca.crt`. The fallback certificate `:3129` needs
to start is made in a build stage, so no flavor needs openssl.

Inside the image:

- `/opt/prometheus/` holds `prometheus*.lua` and `lib/`; mount your own
  `lib/metrics_config.lua` over the baked one.
- `/etc/nginx/nginx.conf` and `/etc/nginx/conf.d/default.conf` are a
  transparent default: inbound on `:80` reverse-proxies to
  `127.0.0.1:$APP_PORT` (default `8080`) without touching the request,
  outbound listens on `127.0.0.1:3128`, and `:9145` serves `/metrics`,
  `/nginx_status` and `/healthz`. https interception is baked in and off.
- stream is off. Drop a file containing
  `stream { include /etc/nginx/stream.d/*.conf; }` into `/etc/nginx/main.d/`
  and your `stream.conf` into `/etc/nginx/stream.d/` to turn it on.

Local build (any flavor):

```
docker buildx build --build-arg OPENRESTY_TAG=alpine \
  -f docker/Dockerfile -t openresty-prometheus:local .
```

Changes are listed in [CHANGELOG.md](CHANGELOG.md).
