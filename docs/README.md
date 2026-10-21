# Documentation

Step-by-step guides for each feature, a maintainer's reference for the
modules, and the metrics catalog. New here? Start with the
[project README](../README.md); come here when you're ready to turn a specific
feature on or understand the internals.

## Features and how they depend on each other

```
the image (or your own OpenResty)
├── inbound               on as soon as the image runs
├── outbound              on in the image; the app opts in with HTTP(S)_PROXY
│   └── https interception    needs outbound + INTERCEPT_TLS=on + a CA
└── stream                off; mount a stream.conf to turn it on
```

Inbound, outbound and stream don't depend on each other — use any subset.
**https interception is the one dependent feature**: it upgrades outbound's
`CONNECT host:port` lines, so it does nothing unless the app's egress already
goes through outbound.

| Guide | What it gives you | Turn on with |
|---|---|---|
| [inbound](inbound.md) | Request metrics for traffic **into** your app (method, route, status, timing, caller) | Run the image |
| [outbound](outbound.md) | Metrics for calls **out** of your app (HTTP in full, HTTPS as `CONNECT host:port`) | `HTTP(S)_PROXY` on the app |
| [https interception](https-interception.md) | Real method/route/status **inside** outbound HTTPS | outbound + `INTERCEPT_TLS=on` + a CA |
| [stream](stream.md) | TCP/UDP metrics (Redis, DB…) from the app's point of view | A `stream.conf` |
| [Running on your own nginx](standalone-nginx.md) | The same features on an existing OpenResty / nginx-with-`lua-nginx-module`, no image | Config only |

## Reference

| Doc | Contents |
|---|---|
| [Modules](modules.md) | Every `lib/` module: purpose, why it's shaped that way, config keys, invariants, how to change/extend/test it safely |
| [Metrics reference](metrics-reference.md) | Every metric and label, cardinality notes, example PromQL |
| [Architecture & internals](../ARCHITECTURE.md) | The design narrative — trust boundaries, identity discovery, cardinality strategy, the image |

## How the pieces fit

```
                     ┌──────────────────── pod / host ─────────────────────┐
   clients ──▶ :80 ──┤ inbound ──▶ your app                                │
                     │                │                                    │
                     │   app egress ──▶ :3128 outbound ──▶ internet        │
                     │                       └─▶ :3129 https interception  │
                     │                                                     │
                     │   app ──▶ :16379 etc ──▶ stream ──▶ redis, db, ...  │
                     │                                                     │
   Prometheus ◀── :9145/metrics (http)   :9254/metrics (stream) ◀─────────┤
                     └─────────────────────────────────────────────────────┘
```

inbound, outbound and https interception share one pipeline and one
`/metrics` (`:9145`), told apart by the `mode` label (`"0"` inbound, `"1"`
outbound — intercepted calls are outbound too). stream is a separate registry
on its own port (`:9254`) — nginx can't share a shared dict between the `http`
and `stream` modules.

## Conventions used in these docs

- **"the sidecar"** / **"the nginx container"** — the OpenResty container
  running this project's config. It needn't literally be a Kubernetes sidecar;
  it's any OpenResty in front of or beside your app.
- **"the app"** — whatever you're observing: PHP-FPM, a Go binary, etc.
- Ports: `:80` inbound · `:3128` outbound · `:3129` https interception
  (internal) · `:9145` HTTP `/metrics` · `:9254` stream `/metrics`.
- Config you edit lives in `lib/metrics_config.lua` (data only). Code you
  don't normally touch is the rest of `lib/`.
