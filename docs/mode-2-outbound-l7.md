# Mode 2 — Outbound L7 (egress metrics)

Metrics for calls your app makes **out** to other services and the internet.
Same pipeline and same `/metrics` as [Mode 1](mode-1-inbound-l7.md), tagged
`mode="1"`.

- **Plain HTTP** egress → full method, route, status, timing.
- **HTTPS** egress → recorded as `CONNECT host:port` (the TLS stays end-to-end;
  you see *which host* and *when*, not the route/status inside). That's the safe
  default and enough for many apps. To see inside HTTPS, add
  [Mode 3](mode-3-outbound-https-interception.md).

Prerequisite: [Mode 1](mode-1-inbound-l7.md) (you're already running the image).

---

## How it works

The image runs a **loopback-only forward proxy** on `127.0.0.1:3128`. Anything
your app sends through it is proxied out and recorded. You opt in simply by
telling the app to use the proxy.

```
app ──HTTP_PROXY/HTTPS_PROXY=127.0.0.1:3128──▶ :3128 forward proxy ──▶ internet
                                                      │
                                               same metrics pipeline, mode="1"
```

CONNECT (HTTPS tunnelling) uses nginx's **native** `ngx_http_tunnel_module`
(`tunnel_pass`), present in the OpenResty base — no third-party module, no
custom build.

---

## Step by step

### 1. Point the app at the proxy

Set standard proxy environment variables on the **app** container (not nginx):

```bash
HTTP_PROXY=http://127.0.0.1:3128
HTTPS_PROXY=http://127.0.0.1:3128
NO_PROXY=127.0.0.1,localhost        # don't proxy loopback / in-pod calls
```

Set the lowercase forms too (`http_proxy`, `https_proxy`) — libcurl reads those;
many other libraries read the uppercase ones. Setting both covers everything.

> The app and the sidecar must share a network namespace for `127.0.0.1:3128`
> to reach the proxy. In a Kubernetes pod they always do; under Docker use
> `--network container:<app>`.

### 2. Make sure the app actually honors the proxy vars

This is the step that varies by language. Most libcurl-based clients pick the
vars up automatically; some runtimes need a nudge:

| Runtime / client | Honors `HTTP(S)_PROXY` automatically? | Note |
|---|---|---|
| curl / libcurl | Yes | Reads the lowercase forms |
| Go (`net/http`) | Yes | `http.ProxyFromEnvironment` is the default transport |
| .NET `HttpClient` | Yes (Linux, .NET Core 3.1+) | Reads `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` |
| Node.js | Depends on the client | Core `http` ignores env proxy; `undici`/`got`/`axios` need a proxy agent or `global-agent` |
| Python `requests` | Yes | Honors env vars unless `trust_env=False` |
| Java | Partial | Reads `-Dhttp.proxyHost`/`https.proxyHost`, not the env vars by default |
| **PHP-FPM** | Only if the worker sees the env | See below |

**PHP-FPM gotcha.** PHP-FPM clears the worker environment by default, so
container-level `HTTPS_PROXY` never reaches your code. Fix it in `www.conf`:

```ini
; inherit the container environment (which carries HTTPS_PROXY)
clear_env = no
```

…or declare the vars explicitly:

```ini
env[HTTP_PROXY]  = http://127.0.0.1:3128
env[HTTPS_PROXY] = http://127.0.0.1:3128
env[NO_PROXY]    = 127.0.0.1,localhost
```

Only libcurl-based PHP egress (ext-curl, Guzzle with the curl handler) follows
the proxy. PHP stream wrappers (`file_get_contents`, `fopen` on a URL) ignore
`HTTPS_PROXY` unless you pass a stream context — if your app uses those, they
won't be captured without a code change.

### 3. Verify

Make an outbound call from the app and look for `mode="1"`:

```bash
# from inside the app container
curl -s https://example.com/ -o /dev/null
curl -s http://example.com/  -o /dev/null

# then, scraping the sidecar
curl -s localhost:9145/metrics | grep 'mode="1"'
```

You'll see something like:

```
# plain HTTP: full detail
nginx_http_requests_total{method="GET",route="/",status="301",host="example.com",mode="1",...} 1
# HTTPS: CONNECT host:port, route is the host:port, status 200 = tunnel established
nginx_http_requests_total{method="CONNECT",route="example.com:443",status="200",host="example.com",mode="1",...} 1
```

That `method="CONNECT"` line is the expected HTTPS shape in Mode 2. The `200` is
"tunnel opened", not the real HTTP status inside. To turn that into
`method="GET" route="/" status="301"`, enable
[Mode 3](mode-3-outbound-https-interception.md).

---

## What the `:3128` server looks like (image default)

In `docker/conf.d/default.conf`:

```nginx
server {
    listen 127.0.0.1:3128;
    set $request_mode 1;
    access_by_lua_block { require("http_metrics").classify_source() }
    log_by_lua_block    { require("http_metrics").record() }

    location / {
        set_by_lua_block $connect_upstream { return require("intercept").upstream() }
        if ($request_method = CONNECT) { tunnel_pass $connect_upstream; }  # HTTPS tunnel
        proxy_pass http://$http_host$request_uri;                          # plain HTTP
    }
}
```

The `$connect_upstream` indirection is the *only* hook interception needs — with
Mode 3 off, [`intercept.upstream()`](modules.md#interceptlua) returns the real
`host:port`, so this behaves exactly like a bare `tunnel_pass;`.

---

## Turning egress metrics off without stopping egress

The forward proxy keeps proxying even if you don't want its metrics. Set, in
[`metrics_config.lua`](modules.md#metrics_configlua):

```lua
apps = { forward_proxy = { metrics_enabled = false } }
```

Traffic still flows; only recording for the `mode="1"` leg stops. See
[`app_toggle`](modules.md#app_togglelua).

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| No `mode="1"` series at all | App isn't using the proxy — env vars not set, not inherited (PHP-FPM `clear_env`), or client ignores them (Node core, Java) |
| `CONNECT tunnel failed, response 500` | Usually a sidecar config/Lua error, not the tunnel — check `kubectl logs <pod> -c nginx`; see [Mode 3 troubleshooting](mode-3-outbound-https-interception.md#troubleshooting) |
| `504` on an external host | Egress to that host is blocked/slow from your network, not a proxy bug (other hosts return normally) |
| In-cluster calls unexpectedly proxied | No `NO_PROXY` set — add `127.0.0.1,localhost` and any in-cluster suffixes you don't want tunnelled |
| Want HTTPS route/status | That's [Mode 3](mode-3-outbound-https-interception.md), not Mode 2 |

Next: [Mode 3 — Outbound HTTPS details](mode-3-outbound-https-interception.md).
