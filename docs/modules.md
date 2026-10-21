# Modules — maintainer's guide

The observability lives in [`lib/`](../lib/): twelve small Lua modules built on
the vendored `prometheus` library's public API. This page is the **maintainer's
reference** — what each module is, why it's shaped that way, its public
functions, the invariants you must not break, and how to change, extend, and
test it safely. For the conceptual narrative (trust boundaries, identity
discovery, the pipeline), read [`ARCHITECTURE.md`](../ARCHITECTURE.md); this doc
is the practical companion to it.

---

## Design philosophy

Four rules explain almost every decision in `lib/`. When you change something,
keep them true.

1. **Pure logic separates from nginx.** Six modules (`route_sanitizer`,
   `host_classifier`, `client_subnet`, `gauge_expiry`, `app_toggle`, and the
   non-DNS parts of `source_attribution`) take plain values and return plain
   values. They never read `ngx.var` or touch global state, so they're unit
   testable without a running worker and reusable on their own. The modules that
   *must* touch nginx (`http_metrics`, `stream_metrics`, `tls_intercept`,
   `self_identity`) are thin orchestration over those pure pieces.

2. **One data file, no logic in it.** Everything environment-specific —
   app/namespace names, which metrics and labels are on, histogram buckets,
   IP ranges, resolver IP — lives in `metrics_config.lua`, a plain table.
   Every other module is generic code with no site values baked in. This is why
   one image serves every deployment: you mount your own `metrics_config.lua`,
   nothing else changes.

3. **Cardinality is bounded at the source.** Labels that could explode (route,
   client subnet, host) pass through a sanitizer *before* they become labels.
   The fix for a new high-cardinality pattern is to teach the sanitizer, never
   to drop the label.

4. **Off is the default for anything invasive.** outbound records but doesn't
   alter traffic; https interception is off until an env var + CA turn it on;
   per-app metrics are opt-out but the *traffic* is never gated by the toggle.

---

## Map

| Module | Role | Pure? | Public API |
|---|---|---|---|
| [`metrics_config`](#metrics_configlua) | All site-specific data | data | *(table)* |
| [`route_sanitizer`](#route_sanitizerlua) | Collapse ID-like path segments | ✅ | `sanitize`, `is_param_segment` |
| [`host_classifier`](#host_classifierlua) | Bucket the `Host` header | ✅ | `classify` |
| [`client_subnet`](#client_subnetlua) | Mask client IP to a subnet | ✅ | `mask` |
| [`gauge_expiry`](#gauge_expirylua) | Zero gauges that go stale | ✅ | `new`, `touch`, `sweep`, `start` |
| [`app_toggle`](#app_togglelua) | Per-leg metrics on/off | ✅ | `enabled` |
| [`source_attribution`](#source_attributionlua) | Who called us (static/PTR/mesh) | mostly | `new_resolver`, `classify_static`, `apply_waypoint_override`, `parse_ptr`, `parse_xfcc` |
| [`self_identity`](#self_identitylua) | Who am I (own service/ns via PTR) | needs ngx | `new`, `get`, `is_resolved`, `start` |
| [`http_metrics`](#http_metricslua) | HTTP pipeline orchestration | needs ngx | `init`, `classify_source`, `record`, `collect` |
| [`stream_metrics`](#stream_metricslua) | L4 pipeline orchestration | needs ngx | `init`, `connection_open`, `record`, `collect` |
| [`intercept`](#interceptlua) | Per-CONNECT intercept decision | reads env/ngx | `should`, `upstream` |
| [`tls_intercept`](#tls_interceptlua) | Per-SNI leaf-cert minting | needs ngx | `mint` |

---

## `metrics_config.lua`

The one file you edit per deployment. A plain table with four top-level keys:
`apps` (per-leg toggles), `http` (everything for the HTTP pipeline), `intercept`
(CA paths, cert TTL), `stream` (the L4 pipeline). It reads a couple of values
from the pod at startup (`namespace` from the ServiceAccount file, resolver IP
from `/etc/resolv.conf`) so there's nothing hardcoded.

**Why a data file and not function arguments:** so it can ship as its own
ConfigMap and change without rebuilding the image, and so the code modules stay
generic. **Invariant:** keep it pure data — no `ngx.*` calls, no side effects at
module load beyond the two file reads already there. If you need logic, put it
in the consuming module and add a data knob here.

Key groups (see inline comments in the file for the full set):

- `http.metric_*` / `http.label_*` — turn individual metrics and labels on/off.
- `http.sanitize` — the `route_sanitizer` checks (each independently toggleable).
- `http.static_ranges` / `dynamic_prefix` / `cluster_ip_prefix` / `ptr_*` —
  caller identity resolution.
- `http.discover_identity` / `app` / `namespace` — own-identity discovery and
  its fallback.
- `http.histogram_buckets*` — bucket boundaries (seconds / bytes / counts).
- `intercept.*` — CA cert/key paths, leaf cert TTL and key size.
- `stream.*` + `apps.stream.*` — the L4 counterparts.

---

## `route_sanitizer.lua`

**Why:** a `route` label with raw IDs would create one time series per request —
the fastest way to melt a Prometheus. This collapses ID-like path segments to
`$param`.

**API**
- `sanitize(path, opts) → string` — e.g. `/orders/8231/items/9f8a…` →
  `/orders/$param/items/$param`.
- `is_param_segment(seg, opts) → bool` — the per-segment test, exposed for
  reuse/testing.

**How it decides:** each segment is checked against independently toggleable
rules — `pure_numeric`, `uuid`, `hex`, `slug_suffix_digit`, `long_with_digit`,
`file_extension`, plus length guards `min_len` / `max_segment_len`. All live in
`metrics_config.http.sanitize`.

**Changing it safely:** if a new ID convention leaks through (you'll see
cardinality climb on `route`), **add a check** rather than turning sanitization
off. See [Adding a sanitizer check](#adding-a-sanitizer-check). Don't make a
check so broad it collapses real, low-cardinality routes into `$param` — you'd
lose the signal you wanted.

---

## `host_classifier.lua`

**Why:** the `Host` header is fully client-controlled, so using it raw is a
cardinality and spoofing risk.

**API:** `classify(host, cluster_ip_prefix) → string` — returns `"localhost"`,
`"kubernetes"` (when the host is an IP under `cluster_ip_prefix`), a generic
`"$ip"`, or the real hostname unchanged.

**Changing it safely:** `cluster_ip_prefix` must end in `.` and match your pod/
service CIDR (e.g. `"10.233."`). Get it wrong and internal IPs fall into the
generic `$ip` bucket — harmless, just less informative, never an error.

---

## `client_subnet.lua`

**Why:** record a client's *subnet* (not its full IP) when you want coarse
origin info without per-IP cardinality.

**API:** `mask(addr) → string` — IPv4 truncated to `/24` (private ranges) or
`/16` (public); IPv6 and unparseable input return `"unknown"`.

**Note:** off by default (`label_client_subnet = false`) — the `source_service`
/ `source_namespace` labels are usually more useful. Turn it on only if you
specifically want subnet-level grouping.

---

## `gauge_expiry.lua`

**Why:** Prometheus gauges don't self-expire. A gauge set once for a rarely-hit
route keeps reporting that stale value forever, which is actively misleading.
This zeroes gauges whose label-set hasn't been touched within a window.

**API**
- `new{dict=, window=, scan_limit=} → tracker`
- `tracker:touch(scope, label_values[, now])` — call on every gauge write.
- `tracker:sweep(now, on_expire)` — one pass; usually you don't call this
  directly.
- `tracker:start(interval, on_expire)` — timer that sweeps every `interval`s.

**Design:** one module, three call sites (request-level gauges, connection-level
gauges, stream gauges), **each with its own shared dict**. `scope` keeps those
namespaces apart inside a tracker. `scan_limit` bounds `get_keys()` so a sweep
can't block all workers under high cardinality — if a sweep can't finish a pass,
raise it, but treat that as a symptom: the sanitizers should be keeping
cardinality bounded in the first place.

---

## `app_toggle.lua`

**Why:** turn metrics off for one leg of traffic (the outbound leg, or one
stream destination) without touching the traffic itself.

**API:** `enabled(apps, key) → bool`. No entry, or an entry without
`metrics_enabled = false`, means **enabled** — opt-out, not opt-in, so a new
destination gets metrics by default. **Invariant:** this gates *recording* only;
never let it gate the proxying.

---

## `source_attribution.lua`

**Why:** label each inbound request with *who called it*, not just what
happened. This is the single most operationally valuable label and the most
subtle module.

**API**
- `new_resolver{...} → Resolver` with `Resolver:resolve(ip) → service, namespace`.
- `classify_static(ip, cfg)` — the static-table lookup (pure).
- `apply_waypoint_override(service, namespace, xfcc_header, waypoint_name)` —
  the mesh override (pure).
- `parse_ptr`, `parse_xfcc` — pure parsers, exposed for testing.

**Resolution order** (in `resolve`): static `static_ranges` table → reverse-DNS
(PTR) against CoreDNS for the dynamic pod range (cached in `ptr_cache` with an
in-flight lock so a burst from one uncached IP fires one query, not one per
request) → configured fallback (`default_label`).

> ⚠️ **Trust boundary — the waypoint/XFCC override.** With an Istio-style
> ambient mesh, a waypoint terminates and re-originates the connection, so PTR
> only ever resolves to *the waypoint*. `apply_waypoint_override` recovers the
> real caller from the SPIFFE URI in the `X-Forwarded-Client-Cert` header —
> **but only after PTR has independently confirmed the direct peer really is the
> waypoint.** If your network lets XFCC reach this sidecar from anywhere other
> than verified mTLS termination at the waypoint, any caller could spoof its
> identity by setting that header. Don't weaken that ordering when editing this
> module.

**Changing it safely:** needs CoreDNS to actually serve PTR for pod IPs (not on
by default everywhere) and `resty.dns.resolver` on `LUA_PATH`. Keep the pure
parsers pure (they're your test surface). If you add a resolution source, slot
it in `resolve` with the same cache-and-lock discipline so you don't turn a
traffic spike into a DNS storm.

---

## `self_identity.lua`

**Why:** so one shared `metrics_config.lua` can serve many Deployments. Without
it, a mounted config holds one `app` value, so every pod mislabels itself as
that one service.

**API:** `new{resolver=, fallback_service=, fallback_namespace=, on_change=}`,
then `:start()`; read with `:get() → service, namespace` and `:is_resolved()`.

**How:** at startup the pod finds its own IP (kubelet writes
`<pod-ip> <pod-hostname>` into `/etc/hosts`), reverse-resolves it via the same
PTR path, and adopts the Service name/namespace it gets back. A pod only has a
PTR record once it's a Ready endpoint of a Service, so discovery **retries with
backoff** (5s doubling to 60s) in a timer, not once at boot. On
fallback→discovered change, `on_change` deletes the `nginx_http_connections`
series recorded under the fallback (they'd otherwise freeze); counter history is
kept. A pod that never resolves (no PTR, `hostNetwork`, no Service) just keeps
the fallback. On by default via `http.discover_identity`.

---

## `http_metrics.lua`

**Why:** the orchestration that turns everything above into Prometheus series.
No site-specific values — it's driven entirely by `metrics_config.lua`.

**API (the nginx hooks):**
- `init()` — `init_worker_by_lua_block`: build the metric objects, start the
  expiry and identity timers.
- `classify_source()` — `access_by_lua_block`: resolve `source_*` into
  `ngx.ctx`.
- `record()` — `log_by_lua_block`: read request vars, sanitize, build the label
  set, increment/observe.
- `collect()` — `content_by_lua_block` on `:9145/metrics`: expose.

**Invariants:** the label *schema* built in `init()` must match the label
*values* built in `record()` name-for-name. Both are built from one ordered
list, `REQUEST_LABELS`, each entry switched by its `label_<name>` flag, so add
or move labels there only — never build either side by hand.
Requests nginx rejects before the access phase (400/405/413/`deny`) never ran
`classify_source()`, so `record()` falls back to `source_service="unknown"` —
keep that fallback when editing.

---

## `stream_metrics.lua`

**Why:** the L4 counterpart to `http_metrics`, on its own registry and port
(`:9254`). nginx can't share a shared dict between the `http` and `stream`
modules, so this is deliberately separate, not a reuse.

**API:** `init()`, `connection_open()` (`preread_by_lua_block`, the `+1` for
active connections), `record()` (`log_by_lua_block`, the `-1` and the rest),
`collect()` (the `:9254` exposition server — a stream server speaks raw TCP, so
it reads the scraper's HTTP request and writes the HTTP response itself), and
`metric_data()` (the bare exposition text, no HTTP).

**Invariants:** every destination `server{}` needs the `preread` hook or
`nginx_stream_connections_active` under-counts. Keep `record()` **per
destination block**, never hoisted to the top of the stream file, or the
exposition server records itself as a phantom destination. `$destination_name`
drives both the `destination` label and the `apps.stream.<name>` toggle.

---

## `intercept.lua`

**Why:** the per-CONNECT decision for https interception on the outbound proxy — intercept or tunnel
straight through — kept out of nginx config so the only thing an app's
`default.conf` carries is a one-line hook.

**API**
- `should() → bool` — true when the current CONNECT is on an intercepted port
  and a non-bypassed host and `INTERCEPT_TLS=on`. Reads only vars that exist for
  a CONNECT, so it's safe in any phase (including `log_by_lua`, where `record()`
  uses it to count the intercepted call exactly once).
- `upstream() → "host:port"` — the `tunnel_pass` target: `127.0.0.1:3129` when
  intercepting, else the real `host:port` (identical to a bare `tunnel_pass;`).

**Config source:** env vars `INTERCEPT_TLS` / `INTERCEPT_TLS_PORTS` (default
`443`) / `INTERCEPT_BYPASS`, read **once per worker** and memoised — so a change
needs a worker (pod) restart. Those vars only reach Lua because
`docker/main.d/intercept-env.conf` declares them with `env`; off-image you must
declare them yourself.

**Invariant:** `should()` is the single source of truth for both routing (in
`upstream()`) and counting (in `http_metrics.record()`). Don't fork that
decision into two places or the intercepted call gets double- or un-counted.

---

## `tls_intercept.lua`

**Why:** mint a leaf certificate for the requested SNI on the fly, signed by the
mounted CA, so `:3129` can terminate the app's TLS and read the real request.

**API:** `mint()` — called from `ssl_certificate_by_lua_block` on `:3129`.

**How:** loads the CA (`intercept.ca_cert_path` / `ca_key_path`) once per worker;
generates one leaf key shared across hosts (as mitmproxy does — a per-host key
buys nothing here); mints and caches a leaf per SNI in `ssl_mint_cache` for
`cert_ttl` seconds. Needs `lua-resty-openssl` (bundled in OpenResty) and
`ngx.ssl`. **Invariant:** never log or expose the CA key; it's a trust anchor.
If the CA can't be read, fail the handshake loudly — don't silently fall back to
the baked `fallback.crt`, which exists only so `nginx -t` and no-SNI
handshakes don't crash.

---

## Adding a metric

1. Add a `metric_<name>` flag to `metrics_config.http` (or `.stream`).
2. In the module's `init()`, create the metric object guarded by that flag,
   with the shared label schema.
3. In `record()`, write it guarded by the same flag.
4. If it's a **gauge**, wire it into the `gauge_expiry` tracker's `touch` and
   the `on_expire` callback so it doesn't go stale.
5. Document it in [metrics reference](metrics-reference.md).

## Adding a label

Add a `label_<name>` flag to `metrics_config.http`, the name to
`REQUEST_LABELS` in `http_metrics.lua`, and its value to the table `record()`
passes to `build_labels`. Schema and values both come from `REQUEST_LABELS`, so
they can't drift apart. Weigh cardinality before
adding — a label with unbounded values is a Prometheus hazard; sanitize it first
(see `route_sanitizer`/`host_classifier` for the pattern).

## Adding a sanitizer check

1. Add a boolean to `metrics_config.http.sanitize` (default it sensibly).
2. In `route_sanitizer.is_param_segment`, add the test, guarded by that flag,
   returning `true` when the segment should become `$param`.
3. Add a unit test (both a positive and a negative case — make sure it doesn't
   eat a real route).

---

## Testing

The pure modules are tested without nginx — they take values and return
values. [`tests/lib_test.lua`](../tests/lib_test.lua) is plain Lua with no
framework; run it from the repo root, and CI's `Run Tests` does the same:

```bash
luajit tests/lib_test.lua      # or lua5.1
```

Add a case there whenever you change a pure module (a positive and a negative
one for sanitizer checks). It also checks that the HTTP label schema and values
line up name-for-name with every label switched on.

The modules that touch nginx (`http_metrics`, `stream_metrics`,
`tls_intercept`, `self_identity`) are covered by the image's **smoke test**
(`.github/workflows/openresty-image.yml`), which runs real requests through a
real container of every flavor and asserts the expected series — see
[the image](../ARCHITECTURE.md#the-image). When you change an orchestration
module or the config wiring, make sure the smoke test still asserts the
behaviour you changed.

---

## Updating the vendored library

The `prometheus` client under `vendor/nginx-lua-prometheus/` is **unmodified
upstream**. To pull a fix: copy the three files (`prometheus.lua`,
`prometheus_keys.lua`, `prometheus_resty_counter.lua`) from the upstream commit
you want, update the **pinned commit** line in
[`vendor/nginx-lua-prometheus/README.md`](../vendor/nginx-lua-prometheus/README.md),
and let CI's `Run Tests` (which runs upstream's own suite from `vendor/`)
confirm the copy is intact. Never edit those files in place — keeping them
verbatim is what makes the vendor honest and the next sync clean.
