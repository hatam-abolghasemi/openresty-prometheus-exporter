# Contributing

Thanks for taking the time. Bug reports, route shapes the sanitizer misses,
dashboard fixes, docs and code are all welcome.

## Before you start

- **Questions and ideas** go to [Discussions](https://github.com/hatam-abolghasemi/openresty-prometheus-exporter/discussions).
- **Bugs and concrete feature requests** go to [Issues](https://github.com/hatam-abolghasemi/openresty-prometheus-exporter/issues/new/choose); the templates ask for what's needed to reproduce.
- **Security problems** never go in a public issue; see [SECURITY.md](SECURITY.md).
- For anything bigger than a small fix, open an issue or discussion first so we
  agree on the approach before you write the code.

## Where things live

| Path | What |
|---|---|
| `lib/` | The exporter: OpenResty Lua modules. `metrics_config.lua` is data only; the rest is code |
| `vendor/nginx-lua-prometheus/` | Prometheus client library, vendored **unmodified**; don't edit it here |
| `docker/` | Image build: nginx config, entrypoint setup |
| `grafana/` | The dashboard (Grafana v2 schema) |
| `examples/` | Kubernetes sidecar example and the Docker quickstart |
| `tests/` | Unit tests for the pure `lib/` modules |
| `docs/` | Feature guides, metrics reference, maintainer's guide |

[docs/modules.md](docs/modules.md) explains every module, why it's shaped that
way, and step-by-step recipes for
[adding a metric](docs/modules.md#adding-a-metric),
[a label](docs/modules.md#adding-a-label) and
[a sanitizer check](docs/modules.md#adding-a-sanitizer-check).
[ARCHITECTURE.md](ARCHITECTURE.md) has the design narrative.

## Running the tests

The unit tests need only LuaJIT (or Lua 5.1), no nginx:

```bash
luajit tests/lib_test.lua
```

To see your change end to end, build the image and run the quickstart against it:

```bash
docker build -f docker/Dockerfile --build-arg OPENRESTY_TAG=alpine -t ope:dev .
cd examples/quickstart
sed -i 's#ghcr.io/hatam-abolghasemi/openresty-prometheus-exporter:latest#ope:dev#' docker-compose.yml
docker compose up -d
curl -s localhost:9145/metrics | grep -v '^#' | head -40
```

`nginx_metric_errors_total` must stay at 0. Anything else means a label schema
mismatch.

## What a good change looks like

- **The hot path stays cheap.** Everything in `log_by_lua` runs on every request.
  No per-request allocations you can avoid, no blocking I/O.
- **Cardinality stays bounded.** A new label must have a small, fixed set of
  values, or be bucketed at the source like `route` and `host`. If a value can
  carry an ID, it doesn't become a label as-is.
- **Defaults don't change silently.** New metrics and labels that cost series
  start off (`false` in `metrics_config.lua`) unless they're clearly worth it
  for everyone. If a default must change, say so in the changelog.
- **Pure logic gets a test.** Parsers, classifiers and the sanitizer are written
  to be testable without nginx; add cases to `tests/lib_test.lua`.
- **Docs move with the code.** Update the feature guide, `docs/metrics-reference.md`
  for new metrics or labels, and the dashboard if it should show them.
- **One dated entry in [CHANGELOG.md](CHANGELOG.md)**, under **Unreleased**,
  describing what changed and why, in the style of the existing entries. A
  release moves those entries under its `## vX.Y.Z` heading, which becomes the
  GitHub Release notes.

## Pull requests

1. Fork, branch from `main`.
2. Keep the PR to one concern; split unrelated changes.
3. Make sure `luajit tests/lib_test.lua` passes; CI runs it too, plus the
   vendored library's own suite.
4. Fill in the PR template.

By contributing you agree that your work is released under the project's
[MIT license](LICENSE), and to follow the [code of conduct](CODE_OF_CONDUCT.md).
