# Quickstart: see it working in a minute

A self-contained demo on plain Docker: the exporter runs as a sidecar beside a
demo app, two small loops generate inbound and outbound traffic, and
Prometheus + Grafana come up with the dashboard already loaded.

```bash
git clone https://github.com/hatam-abolghasemi/openresty-prometheus-exporter.git
cd openresty-prometheus-exporter/examples/quickstart
docker compose up -d
```

| What | Where |
|---|---|
| Grafana dashboard (no login) | <http://localhost:3000> → Dashboards |
| Raw metrics | <http://localhost:9145/metrics> |
| Prometheus | <http://localhost:9090> |
| The app, through the sidecar | <http://localhost:8000> |

Give it ~30 seconds for traffic to build up, then:

```bash
curl -s localhost:9145/metrics | grep '^nginx_http_requests_total' | head -20
```

Things to look for:

- **Sanitized routes.** The traffic hits `/anything/orders/1`, `/anything/orders/2`, …
  and a fresh UUID under `/anything/users/` every time. On `/metrics` they are
  just `route="/anything/orders/$param"` and `route="/anything/users/$param"`:
  a few time series instead of one per id.
- **Real status codes.** `/status/404` and `/status/500` share
  `route="/status/$param"`, but `status="404"` and `status="500"` are kept apart.
- **Outbound.** Series with `mode="1"` are the app's own calls to `upstream`,
  seen through the sidecar's forward proxy. No change to the app beyond `HTTP_PROXY`.

Stop and clean up:

```bash
docker compose down
```

## How it maps to Kubernetes

| Here | In Kubernetes |
|---|---|
| `sidecar` with `network_mode: service:app` | a second container in the app's pod |
| `traffic-outbound` using `-x http://127.0.0.1:3128` | the app with `HTTP_PROXY` / `HTTPS_PROXY` set to `http://127.0.0.1:3128` |
| `namespace` / `pod` labels in `prometheus.yml` | added by the ServiceMonitor |

What you don't get on plain Docker: `source_service` / `source_namespace`
(caller identity needs Kubernetes reverse DNS). For the real setup, see
[`examples/openresty-sidecar/`](../openresty-sidecar/) and the
[docs index](../../docs/README.md).
