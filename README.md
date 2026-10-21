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
> The easiest path is the prebuilt image. Caller identity (`source_service` /
> `source_namespace`) resolves on **Kubernetes**; under plain Docker everything
> else works, you just don't get those two labels.

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

Full catalog in the [metrics reference](docs/metrics-reference.md).

## Enable what you need — one tier at a time

Each tier is independent and additive. Click through for the step-by-step guide.

| | Capability | Turn on with | Guide |
|---|---|---|---|
| **1** | **Inbound L7** — request metrics into your app | run the image | [Mode 1](docs/mode-1-inbound-l7.md) |
| **2** | **Outbound L7** — egress metrics (HTTPS as `CONNECT host:port`) | `HTTP(S)_PROXY=127.0.0.1:3128` | [Mode 2](docs/mode-2-outbound-l7.md) |
| **3** | **Outbound HTTPS details** — real route/status inside HTTPS | `INTERCEPT_TLS=on` + a CA | [Mode 3](docs/mode-3-outbound-https-interception.md) |
| **4** | **L4 stream** — TCP/UDP (Redis, DB…) from the app's side | a `stream.conf` block | [Mode 4](docs/mode-4-stream-l4.md) |

```
ghcr.io/hatam-abolghasemi/openresty-prometheus-exporter:<openresty-tag>
```

**Already run OpenResty, or nginx with `lua-nginx-module`?** You don't need the
image — drop the Lua modules into your existing server: [running on your own
nginx](docs/standalone-nginx.md).

## Quick start

Run it as a sidecar beside your app (K8s) or in front of it (any OpenResty), set
`APP_PORT` to your app's port, and scrape `:9145/metrics` (HTTP) and
`:9254/metrics` (stream). A complete, mock-data Kubernetes example — ConfigMaps,
a Deployment showing the app + nginx pair, and a Service/ServiceMonitor — is in
[`examples/openresty-sidecar/`](examples/openresty-sidecar/). The
[docs index](docs/README.md) walks each mode from there.

## Documentation

- **[Documentation index](docs/README.md)** — all guides, start here
- **Modes** — [1 Inbound](docs/mode-1-inbound-l7.md) · [2 Outbound](docs/mode-2-outbound-l7.md) · [3 HTTPS details](docs/mode-3-outbound-https-interception.md) · [4 Stream](docs/mode-4-stream-l4.md) · [own nginx](docs/standalone-nginx.md)
- **[Metrics reference](docs/metrics-reference.md)** — every metric and label, with PromQL
- **[Modules](docs/modules.md)** — maintainer's guide: what each `lib/` module does, why, how to change it
- **[Architecture & internals](ARCHITECTURE.md)** — the design narrative

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
milestones, independent of the OpenResty version. The image tag answers "which
OpenResty am I on?"; the release answers "which version of the exporter's
capabilities is this?".

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
