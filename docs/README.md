# Documentation

Step-by-step guides for each capability, a maintainer's reference for the
modules, and the metrics catalog. New here? Start with the
[project README](../README.md); come here when you're ready to turn a specific
mode on or understand the internals.

## Pick what you want to expose

Each mode is independent and additive — turn on only what you need. Modes 1–4
run inside OpenResty; the "own nginx" page is a separate deployment shape, not a
fifth capability.

| Guide | What it gives you | Effort |
|---|---|---|
| [Mode 1 — Inbound L7](mode-1-inbound-l7.md) | Request metrics for traffic **into** your app (method, route, status, timing) | Run the image |
| [Mode 2 — Outbound L7](mode-2-outbound-l7.md) | Egress metrics for calls **out** of your app (HTTP, and HTTPS as `CONNECT host:port`) | + proxy env vars |
| [Mode 3 — Outbound HTTPS details](mode-3-outbound-https-interception.md) | Real method/route/status **inside** outbound HTTPS, via opt-in TLS interception | + `INTERCEPT_TLS` + a CA |
| [Mode 4 — L4 stream](mode-4-stream-l4.md) | TCP/UDP metrics (Redis, DB…) from the app's point of view | + a `stream.conf` block |
| [Running on your own nginx](standalone-nginx.md) | Use the Lua modules on an existing OpenResty / nginx-with-`lua-nginx-module`, no image | Config only |

## Reference

| Doc | Contents |
|---|---|
| [Modules](modules.md) | Every `lib/` module: purpose, why it's shaped that way, config keys, invariants, how to change/extend/test it safely |
| [Metrics reference](metrics-reference.md) | Every metric and label, cardinality notes, example PromQL |
| [Architecture & internals](../ARCHITECTURE.md) | The design narrative — trust boundaries, identity discovery, cardinality strategy, the forward-proxy/interception pipeline |

## How the pieces fit

```
                       ┌──────────────────── pod / host ────────────────────┐
   clients ──▶ :80 ────┤ reverse proxy (mode 1) ──▶ your app                 │
                       │                               │                     │
                       │        app egress ──▶ :3128 forward proxy (mode 2)  │
                       │                               │  └─▶ :3129 TLS      │
                       │                               │     terminator      │
                       │                               │     (mode 3)        │
                       │   app ──▶ :16379 etc ──▶ stream proxy (mode 4)      │
                       │                                                     │
   Prometheus ◀── :9145/metrics (http)   :9254/metrics (stream) ◀───────────┤
                       └─────────────────────────────────────────────────────┘
```

All HTTP-side modes share one pipeline and one `/metrics` (`:9145`),
distinguished by the `mode` label (`0` inbound, `1` outbound). The stream side
is a separate registry on its own port (`:9254`) — nginx can't share a shared
dict between the `http` and `stream` modules.

## Conventions used in these docs

- **"the sidecar"** / **"the nginx container"** — the OpenResty container
  running this project's config. It needn't literally be a Kubernetes sidecar;
  it's any OpenResty in front of or beside your app.
- **"the app"** — whatever you're observing: PHP-FPM, a Go binary, etc.
- Ports: `:80` reverse proxy · `:3128` forward proxy · `:3129` TLS terminator
  (internal) · `:9145` HTTP `/metrics` · `:9254` stream `/metrics`.
- Config you edit lives in `lib/metrics_config.lua` (data only). Code you
  don't normally touch is the rest of `lib/`.
