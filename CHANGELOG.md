# Changelog

Dated entries for this project's own code. The vendored library under
`vendor/nginx-lua-prometheus/` has its own `CHANGELOG.md`.

### 2026-10-28

- **`probe_default_namespace` is now used.** The resolver paired
  `probe_default_service` with `default_namespace` (the namespace for public
  IPs), so unresolved pod-range callers showed as `unknown.health-probe`
  instead of `default.health-probe`. New resolver option
  `default_service_namespace` carries `probe_default_namespace`; public IPs
  keep `default_namespace`.
- **Intercepted HTTPS no longer reconnects to the destination per request.**
  `:3129` re-originated with `proxy_pass https://$host…`, which keeps no
  connection pool, so every decrypted request paid a new TCP + TLS handshake to
  the real destination: about two round trips added to each call (+45 ms p50
  against a destination 20 ms away). New `lib/intercept_origin.lua` resolves the
  destination and pools connections per hostname; the `upstream
  intercept_origin` block in `intercept.conf` sets `keepalive 0` so nginx's
  implicit IP-keyed pool can't hand one host's verified connection to another.
  New `intercept.*` keys: `dns_server`, `dns_timeout`, `dns_cache_ttl`,
  `pool_idle_timeout`, `pool_max_requests`.
- **Intercepted non-443 ports are re-originated on their own port.** `$host`
  drops the port, so a port added to `INTERCEPT_TLS_PORTS` was re-sent to 443.
  The port now comes from the `Host` header.
- **Gauge expiry window raised from 10s to 15s** (`http.expiry_window`,
  `stream.expiry_window`, and the `gauge_expiry` default). With a 15s scrape
  interval and the 5s sweep, about 1 in 6 isolated writes to a quiet series
  was zeroed before any scrape saw it. At 15s every write is scraped at least
  once, and about 1 in 6 is scraped twice. Keep `expiry_window` equal to the
  scrape interval.

### 2026-10-27

- **Caller identity no longer expires.** The PTR cache dropped every answer
  after 15s and labelled the next request with the fallback, so any caller
  slower than one request per 15s per peer IP (e.g. traffic through two
  ingress replicas once a minute) always showed as `unknown.health-probe`.
  Answers are now kept until a new answer replaces them; one worker
  re-resolves every known IP each `ptr_refresh_interval` (15s, keep it at or
  below the scrape interval), so a reassigned IP is relabelled within one
  scrape. NXDOMAIN resets an IP to the fallback; timeouts and SERVFAIL keep
  the previous answer. Only IPs that sent a request in the last `ptr_forget_after` (5 min) are refreshed; idle ones are dropped.
- **New IPs resolve inline** (`ptr_sync_timeout`, 100ms) in the access/preread
  phase instead of the first request always getting the fallback.
- **Stable name when an IP has several PTR records** (one per Service selecting
  the pod): the alphabetically first name not matching `ptr_ignore_services`
  (default `-metrics`, `-headless`) is used, instead of whichever answer DNS
  listed first.
- `ptr_cache_ttl` is replaced by `ptr_refresh_interval` and still read as a
  fallback.

### 2026-10-23

- **`latest` is now Alpine** (was bookworm, as upstream). The flavor is one
  variable in the image workflow, `LATEST_FLAVOR`.
- **[`docs/images.md`](docs/images.md)** lists the newest release, every
  flavor's tags and platforms, and pull commands by tag and by digest. The
  image workflow's new `catalog` job regenerates it from GHCR and commits it
  when it changes (it never committed before, so a new release such as
  1.31.1.1-5 left the docs behind). Hand-written docs and examples no longer
  name a release.
- **Failed image runs are retried**: `retry.yml` re-runs the failed jobs up to
  2 times.

### 2026-10-21

- **Grafana dashboard** in [`grafana/`](grafana/): a v2-schema dashboard
  (Grafana 12+) with one tab per area — Summary, Request breakdown, Latency
  percentiles, Last observed latency, Payload sizes, Connections, L4 streams.
  Dashboard-wide filters are only data source and namespace; host, route and
  status live on the tabs that use them (L4 streams lists stream status codes).
  Linked from the README and the docs index.
- **Every docker-openresty flavor, same tags.** The image workflow no longer
  builds only Alpine: for each release it reads the flavors and platforms
  upstream published on Docker Hub (alpine, alpine-slim, alpine-apk,
  alpine-fat, bookworm, bookworm-fat, noble, jammy, rocky, alma, fedora, …)
  and builds each one on the same platforms (amd64, arm64, s390x where
  upstream has it), one matrix job per flavor with its own smoke test. Tags
  are upstream's: `<release>-<flavor>`, `<version>-<flavor>`,
  `<series>-<flavor>`, `<flavor>`, and `latest` (= bookworm, as upstream).
  The old flavorless tags (`:1.31.1.1-4`, `:1.31.1.1`) and the `-<sha>` tags
  are no longer published; pin by digest instead.
- `docker/Dockerfile` is flavor-neutral: `OPENRESTY_TAG` now includes the
  flavor; `docker/setup.sh` finds the flavor's config path from `nginx -V`
  (covers `-debug`/`-valgrind` prefixes) and links the distro CA bundle to
  `/etc/nginx/intercept/trusted-ca.crt`; the fallback certificate is made in a
  build stage, so no flavor needs openssl. `nginx.conf` includes `mime.types`
  relative to the config dir. Leftover `/etc/nginx/intercept/{ports,bypass}`
  dirs removed.
- **Features are named, not numbered**: inbound, outbound, https interception
  (depends on outbound), stream. Guides renamed to `docs/inbound.md`,
  `docs/outbound.md`, `docs/https-interception.md`, `docs/stream.md`.
  `metrics_config.apps.forward_proxy` is now `apps.outbound` — rename it in a
  mounted config (an old key is ignored, i.e. outbound metrics stay on).
- Fixed `lib/http_metrics.lua` filing label values under the wrong names when
  `label_app`/`label_namespace` were on (schema and values were built in
  different orders). Both now come from one ordered list.
- Fixed the stream exposition server answering scrapes with bare text instead
  of an HTTP response: `stream_metrics.collect()` now speaks HTTP;
  `metric_data()` still returns the raw text. Added the
  `stream.label_source_*` flags to `metrics_config.lua` (off).
- `examples/openresty-sidecar/` rebuilt around the image: a kustomization that
  mounts only `stream.conf` (+ optional `metrics_config.lua`), the
  ServiceMonitor scraping `:9145` instead of `:80`. The example `nginx.conf` /
  `default.conf` copies (which had drifted, and used `--` comments nginx can't
  parse) are gone — `docker/` is the reference config.
- The image smoke test now also covers https interception (throwaway CA,
  `INTERCEPT_TLS=on`, a decrypted `GET` recorded once, no `CONNECT` line); it
  previously only proved the CA-less default starts.
- Added `tests/lib_test.lua` (pure modules + HTTP label pairing) and a `lib` job
  in `Run Tests`; refreshed the vendored-suite jobs' action versions.
- The changelog moved here from `ARCHITECTURE.md`.

### 2026-10-20

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
