# Running on your own nginx / OpenResty

The prebuilt image is the easy path, but nothing here requires it. The metrics
are produced by the Lua modules in [`lib/`](../lib/) plus a handful of config
lines — you can drop them into an **existing OpenResty**, or into **stock nginx
compiled with `lua-nginx-module`**, and get the same `/metrics`.

This is a deployment shape, not a feature. Once wired,
[inbound](inbound.md), [outbound](outbound.md),
[https interception](https-interception.md) and [stream](stream.md) work
exactly as documented.

---

## Requirement: nginx **with** the Lua module

This project is OpenResty code. It will **not** run on stock nginx as shipped —
it needs `ngx_http_lua_module` (and, for [stream](stream.md),
`ngx_stream_lua_module`). You have two ways to satisfy that:

1. **OpenResty** — nginx with the Lua modules, LuaJIT, and the `lua-resty-*`
   libraries already built in. This is what the image uses and the only
   combination that's smoke-tested. Recommended.
2. **Stock nginx + the module** — build nginx with
   [`lua-nginx-module`](https://github.com/openresty/lua-nginx-module) (and
   `lua-resty-core`, `lua-resty-lrucache`, and for https interception
   `lua-resty-openssl`), or install a distro package that bundles it (e.g.
   Debian's `libnginx-mod-http-lua`). You are then responsible for matching
   module and core versions. Several capabilities also need specific pieces:

   | Capability | Needs |
   |---|---|
   | [inbound](inbound.md), [outbound](outbound.md) | `ngx_http_lua_module` |
   | outbound CONNECT | nginx ≥ 1.31 native `ngx_http_tunnel_module` (`tunnel_pass`) |
   | [https interception](https-interception.md) | `lua-resty-openssl`, `ngx.ssl` |
   | Caller identity PTR ([source attribution](modules.md#source_attributionlua)) | `lua-resty-dns` (`resty.dns.resolver`) |
   | [stream](stream.md) | `ngx_stream_lua_module` |

> If any of that sounds like more than you want to own, use the image — it's the
> whole point of publishing it, and it tracks OpenResty releases for you.

---

## Wiring the Lua side

nginx loads `.lua` from `lua_package_path` at request time — **no build step**
for the Lua side. Put the files where the path points:

```
/opt/prometheus/prometheus.lua              (vendored library)
/opt/prometheus/prometheus_keys.lua
/opt/prometheus/prometheus_resty_counter.lua
/opt/prometheus/lib/*.lua                    (this project's modules)
/opt/prometheus/lib/metrics_config.lua       <- edit this one for your environment
```

Then in your `http {}` config (or a `conf.d/*.conf` it includes):

```nginx
lua_shared_dict ptr_cache           1M;
lua_shared_dict prometheus_metrics  4M;
lua_shared_dict custom_metrics      1M;
lua_package_path "/opt/prometheus/?.lua;/opt/prometheus/lib/?.lua;;";

init_worker_by_lua_block { require("http_metrics").init() }
```

and on each server you want measured:

```nginx
set $request_mode 0;                                               # 0 inbound, 1 outbound
access_by_lua_block { require("http_metrics").classify_source() }
log_by_lua_block    { require("http_metrics").record() }

location = /metrics { content_by_lua_block { require("http_metrics").collect() } }
```

The image's [`docker/conf.d/default.conf`](../docker/conf.d/default.conf) is a
complete, working reference for all of this (reverse proxy + forward proxy +
exposition). The
[`examples/openresty-sidecar/`](../examples/openresty-sidecar/) tree is the same
thing broken into `nginx.conf` / `default.conf` / `stream.conf` for a
mounted-config deployment.

---

## Use just one module

The modules are independent — you don't have to adopt the whole pipeline. For
example, to reuse only route sanitization inside your own logging:

```nginx
log_by_lua_block {
    local route = require("route_sanitizer").sanitize(ngx.var.request_uri)
    -- ... feed `route` into your own counter
}
```

Each pure module (`route_sanitizer`, `host_classifier`, `client_subnet`,
`gauge_expiry`, `app_toggle`, and the non-DNS parts of `source_attribution`)
works without the rest. See [Modules](modules.md).

---

## What you give up off-image

Everything works, but you own the plumbing the image otherwise handles:

- **Interception machinery** — the image bakes in `conf.d/intercept.conf` (the
  `:3129` terminator + `ssl_mint_cache`), `main.d/intercept-env.conf` (the
  `env INTERCEPT_TLS …` declarations so workers can read them), and a
  `fallback.crt`/`fallback.key`. For https interception off-image you must reproduce those
  yourself.
- **Env-var switches** — `INTERCEPT_TLS` et al. only reach Lua if declared with
  `env` at the main level (that's what `main.d/intercept-env.conf` does).
- **System trust store** — https interception re-originates with verification
  against `/etc/nginx/intercept/trusted-ca.crt`, which the image links to the
  distro's CA bundle; off-image, point `proxy_ssl_trusted_certificate` in
  `intercept.conf` at your bundle.
- **The update pipeline** — the image rebuilds on every OpenResty release and
  smoke-tests itself; off-image you track versions by hand.

For most people the image is simply less to maintain. This path exists for when
you already run OpenResty and want to add observability without changing your
base image.
