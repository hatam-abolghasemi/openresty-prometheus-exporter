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
outbound), and `source_service` / `source_namespace` — across inbound,
outbound (including decrypted HTTPS via https interception), and stream (L4). The usual alternative is
shipping access logs somewhere and deriving metrics from them (more storage,
more I/O, more delay, rarely cardinality-safe) or reaching for Istio/OpenTelemetry
to get one slice of this. This gives you the whole picture from the proxy itself.

Full catalog in the [metrics reference](docs/metrics-reference.md).

## Features

Turn on only what you need. Click through for the step-by-step guide.

| Feature | What it gives you | Turn on with | Depends on |
|---|---|---|---|
| [**inbound**](docs/inbound.md) | Request metrics for traffic into your app | run the image | — |
| [**outbound**](docs/outbound.md) | Egress metrics (HTTPS as `CONNECT host:port`) | `HTTP(S)_PROXY=127.0.0.1:3128` on the app | — |
| [**https interception**](docs/https-interception.md) | Real route/status inside outbound HTTPS | `INTERCEPT_TLS=on` + a CA | outbound |
| [**stream**](docs/stream.md) | TCP/UDP (Redis, DB…) from the app's side | a `stream.conf` | — |

```
ghcr.io/hatam-abolghasemi/openresty-prometheus-exporter:<openresty-tag>-<flavor>
```

**Already run OpenResty, or nginx with `lua-nginx-module`?** You don't need the
image — drop the Lua modules into your existing server: [running on your own
nginx](docs/standalone-nginx.md).

## Quick start

Run it as a sidecar beside your app (K8s) or in front of it (any OpenResty), set
`APP_PORT` to your app's port, and scrape `:9145/metrics` (plus `:9254/metrics`
once stream is on). A complete Kubernetes example — the app + sidecar
Deployment with inbound, outbound and stream on, a Service/ServiceMonitor, and
a kustomization — is in [`examples/openresty-sidecar/`](examples/openresty-sidecar/).
The [docs index](docs/README.md) walks each feature from there.

Then import the [Grafana dashboard](grafana/): inbound, outbound, connections
and L4 streams, one tab each.

## Documentation

- **[Documentation index](docs/README.md)** — all guides, start here
- **Features** — [inbound](docs/inbound.md) · [outbound](docs/outbound.md) · [https interception](docs/https-interception.md) · [stream](docs/stream.md) · [own nginx](docs/standalone-nginx.md)
- **[Metrics reference](docs/metrics-reference.md)** — every metric and label, with PromQL
- **[Grafana dashboard](grafana/)** — ready to import, one tab per area
- **[Modules](docs/modules.md)** — maintainer's guide: what each `lib/` module does, why, how to change it
- **[Architecture & internals](ARCHITECTURE.md)** — the design narrative
- **[Changelog](CHANGELOG.md)**

## Images & versioning

Every [docker-openresty](https://github.com/openresty/docker-openresty) release
is rebuilt with this project baked in, **in every flavor upstream publishes**
(alpine, alpine-slim, bookworm, noble, rocky, …) and on the same platforms,
smoke-tested, and pushed to GHCR. **The tags are docker-openresty's own** — swap
the image name and keep the tag:

| `openresty/openresty:` | `ghcr.io/hatam-abolghasemi/openresty-prometheus-exporter:` | Meaning |
|---|---|---|
| `1.31.1.1-4-alpine` | `1.31.1.1-4-alpine` | that release, that flavor |
| `1.31.1.1-alpine` | `1.31.1.1-alpine` | newest revision of OpenResty 1.31.1.1 |
| `1.31-alpine` | `1.31-alpine` | newest release in the 1.31 series |
| `alpine` | `alpine` | newest release |
| `latest` | `latest` | newest release, `bookworm` flavor |

A tag is rebuilt when this repo's code changes, so for an immutable reference
pin the digest (`…@sha256:…`); the image's `org.opencontainers.image.revision`
label names the commit it was built from.

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
inbound/outbound/stream proxies, and https interception — on top of that
library's public API. Full credit for the library is upstream's.

## License

This project is MIT licensed (see [`LICENSE`](LICENSE)). Vendored third-party
code under `vendor/` is kept under its own license
([`vendor/nginx-lua-prometheus/LICENSE`](vendor/nginx-lua-prometheus/LICENSE)).
