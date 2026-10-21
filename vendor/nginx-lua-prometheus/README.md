# Vendored: nginx-lua-prometheus

Unmodified upstream code from
[knyar/nginx-lua-prometheus](https://github.com/knyar/nginx-lua-prometheus)
(MIT, © Anton Tolchanov) — the Prometheus client library this project builds
on: the counter / gauge / histogram storage in shared dicts and the
exposition-format serializer (`prometheus.lua`, `prometheus_keys.lua`,
`prometheus_resty_counter.lua`).

These files are kept here **verbatim** so the library stays drop-in and any
upstream fix can be pulled by copying the file over. `LICENSE` is upstream's;
`prometheus_test.lua`, `dist.ini`, the rockspec and `integration/` are
upstream's packaging and tests, kept alongside for reference.

- Upstream: https://github.com/knyar/nginx-lua-prometheus
- Pinned at: <fill in the upstream commit/tag you vendored, e.g. v0.20240525>

Do not edit these files. This project's own code lives in `../../lib/` and
`../../docker/`.
