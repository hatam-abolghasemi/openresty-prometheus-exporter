# openresty-prometheus-exporter

**The metrics you'd expect nginx to expose on `/metrics` — but it doesn't.**
Inbound and outbound L7 with sanitized routes and real status codes, decrypted
HTTPS details, L4 (TCP/UDP) from the app's own point of view, and caller
identity — all cardinality-safe, scrape-ready, with no access-log shipping and
no service mesh.

Built on [OpenResty](https://openresty.org/) (nginx + Lua). It runs as a
reverse proxy, a forward proxy, and an L4 stream proxy; the metrics come from a
set of OpenResty Lua modules, exposed on a Prometheus endpoint.

> Requires OpenResty, or nginx built with `lua-nginx-module` — not stock nginx.
> The easiest path is the prebuilt image below. Caller identity
> (`source_service` / `source_namespace`) resolves on **Kubernetes**; under
> plain Docker everything else works, you just don't get those two labels.

---

## What you get

A Prometheus `/metrics` endpoint with low-cardinality, well-labelled series —
`method`, sanitized `route` (IDs/UUIDs/hashes collapsed to `$param` so you don't
get a time series per order id), `status`, `host`, `mode` (`0` inbound / `1`
outbound), and `source_service` / `source_namespace` — across inbound L7,
outbound L7 (including decrypted HTTPS), and L4. The usual alternative is
shipping access logs somewhere and deriving metrics from them (more storage,
more I/O, more delay, rarely cardinality-safe) or reaching for Istio/OpenTelemetry
to get one slice of this. This gives you the whole picture from the proxy itself.

## Enable what you need — one tier at a time

**1 — Inbound L7 (request metrics).** Use the prebuilt image as your nginx (it's
OpenResty — programmable nginx, same config model), or add `lua-nginx-module` to
your own nginx and drop in `lib/` + a few config lines. The image is the
recommended path: easier to set up, easier to maintain, and smoke-tested on
every build.

```
ghcr.io/hatam-abolghasemi/openresty-prometheus-exporter:<openresty-tag>
```

**2 — Outbound L7 (egress metrics).** Point your app's `HTTP_PROXY` /
`HTTPS_PROXY` at the sidecar's loopback forward proxy and its outbound calls get
the same treatment:

```
HTTP_PROXY=http://127.0.0.1:3128
HTTPS_PROXY=http://127.0.0.1:3128
```

Most libcurl-based clients honor these automatically (curl, Go, .NET); a few
need a nudge — PHP-FPM needs `clear_env=no` (or `env[...]`) so workers see them,
and Python `requests` / Java often need to be told explicitly.

**3 — Real routes & status for outbound HTTPS.** By default HTTPS egress is
recorded as `CONNECT host:port` (safe, and enough for many apps). To get the
real method/route/status, enable interception: set `INTERCEPT_TLS=on`, mount a
CA the sidecar signs with, and make your app trust that CA (for PHP that's one
`curl.cainfo` line). The sidecar decrypts, records, and re-originates over
**verified** TLS. See [ARCHITECTURE.md](ARCHITECTURE.md),
"Seeing outgoing HTTPS details", for the per-language trust step (PHP and .NET
samples included).

**4 — L4 (TCP/UDP) observability.** Route a dependency (Redis, a database, …)
through the sidecar's stream proxy and get connection counts, bytes in/out,
session duration, and connect / first-byte timing — from your app's side —
on a separate scrape target (`:9254`). Opt-in, per destination; append a small
`stream.conf` block.

## Quick start

Run it as a sidecar next to your app (K8s) or in front of it (any OpenResty
deployment). A complete, mock-data Kubernetes example — ConfigMaps for
`nginx.conf` / `default.conf` / `stream.conf`, a Deployment showing the
app + nginx pair, and a Service/ServiceMonitor — is in
[`examples/openresty-sidecar/`](examples/openresty-sidecar/). Replace every mock
name/image/label, then scrape `:9145/metrics` (HTTP) and `:9254/metrics` (stream).

Prefer to use just the Lua modules on your own OpenResty? Add `lib/` (and the
vendored library at `vendor/nginx-lua-prometheus/`) to `lua_package_path`, pull
in the modules you want from your own `log_by_lua_block`, and edit
`lib/metrics_config.lua` for your environment. See
[ARCHITECTURE.md](ARCHITECTURE.md) for what each module does.

## Images & versioning

Images are built automatically on top of each
[docker-openresty](https://github.com/openresty/docker-openresty) release,
smoke-tested, and published to GHCR. **The image tag mirrors the OpenResty base**
so you pick your OpenResty version directly:

- `:<openresty-tag>` — latest exporter build for that base (e.g. `1.31.1.1-4`)
- `:<openresty-tag>-<short-sha>` — immutable; pin this in production
- `:<resty-version>` — newest revision of an OpenResty version
- `:latest` — newest base + newest exporter

GitHub **Releases** (`vX.Y.Z`) are separate — they mark this project's own
milestones (features, docs), independent of the OpenResty version. The image tag
answers "which OpenResty am I on?"; the release answers "which version of the
exporter's capabilities is this?".

## Built on

The Prometheus client internals (counter/gauge/histogram storage and the
exposition-format serializer) are vendored **unmodified** from
[knyar/nginx-lua-prometheus](https://github.com/knyar/nginx-lua-prometheus)
(MIT, © Anton Tolchanov), under
[`vendor/nginx-lua-prometheus/`](vendor/nginx-lua-prometheus/). This project adds
the observability layer — route sanitization, source attribution, the
forward/stream proxies, and TLS interception — on top of that library's public
API. Full credit for the library is upstream's.

## License

This project is MIT licensed (see [`LICENSE`](LICENSE)). Vendored third-party
code under `vendor/` is kept under its own license
([`vendor/nginx-lua-prometheus/LICENSE`](vendor/nginx-lua-prometheus/LICENSE)).
