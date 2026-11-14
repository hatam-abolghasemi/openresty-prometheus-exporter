# https interception — see inside outbound HTTPS and gRPC

Turn every outbound `CONNECT` tunnel that carries HTTP into the **real**
method, route, and status — `GET /v2/orders → 404` instead of just
`CONNECT api.internal:443 → 200`, and `/orders.v1.Orders/Get → grpc_5` instead
of `CONNECT orders:9000 → 200`. Outbound then reads like inbound.

What is decoded, with nothing configured per port or per host:

| Inside the tunnel | Recorded as |
|---|---|
| HTTPS, on **any** port | method, route, status |
| gRPC over TLS, on any port | `POST /package.Service/Method`, `grpc_<code>` |
| plaintext gRPC (h2c) | `POST /package.Service/Method`, `grpc_<code>` |
| anything else | `CONNECT host:port`, unchanged |

This is **TLS interception** (a MITM of your app's own egress, inside your own
trust domain). It is off by default and enabled per deployment. Read the
[security model](#security-model) before enabling it in production.

**Depends on [outbound](outbound.md)**: it only acts on CONNECTs that already
arrive at `:3128`, so the app's egress must go through outbound first.
Independent of [inbound](inbound.md) and [stream](stream.md).

---

## How it works

```
app ──CONNECT api:443──▶ :3128 ──first bytes?──┬─ TLS ────▶ :3129 TLS terminator
                                               │              │ mints a leaf cert for "api"
                                               │              │ signed by YOUR CA (per-SNI)
                                               │              │ decrypts, records the request
                                               │              └─▶ re-originates to api:443 over
                                               │                  VERIFIED TLS
                                               ├─ HTTP/2 ─▶ :3130 h2c terminator (plaintext gRPC)
                                               │              └─▶ records each call, forwards it
                                               └─ other ──▶ real target, unchanged
```

1. The app opens `CONNECT api:443` as usual (outbound).
2. `:3128` answers `200 Connection Established` and reads the first bytes the
   app sends into the tunnel ([`connect_tunnel`](modules.md#connect_tunnellua)).
   The protocol announces itself there: a TLS ClientHello starts `0x16 0x03`,
   HTTP/2 starts with its fixed preface. Those bytes are already on the wire
   when they are read — TLS and HTTP clients speak first — so the decision adds
   no wait. TLS goes to `127.0.0.1:3129`, HTTP/2 to `127.0.0.1:3130`, anything
   else to the real target, as `tunnel_pass` would.
3. `:3129` ([`optional/intercept.conf`](../docker/optional/intercept.conf) +
   [`tls_intercept`](modules.md#tls_interceptlua)) terminates the TLS using a
   leaf certificate **minted on the fly for the requested SNI**, signed by a CA
   you provide. It reads the now-decrypted request and records it with the same
   `http_metrics.record()` as everything else.
4. It then re-originates to the real destination over a **verified** TLS
   connection (`proxy_ssl_verify on` against the system trust store) — so the
   app's end-to-end TLS guarantee is preserved, not dropped. Those connections
   are kept alive and pooled **per hostname**
   ([`intercept_origin`](modules.md#intercept_originlua)), so an intercepted
   request costs no extra round trips to the destination once a connection to
   it is warm. `:3129` speaks HTTP/2 or HTTP/1.1, as the app's client offers;
   gRPC calls (`content-type: application/grpc`) are forwarded with
   `grpc_pass` over verified TLS, everything else with `proxy_pass`.
5. `:3130` does the same for **plaintext gRPC**: it speaks HTTP/2 with prior
   knowledge (what a gRPC client sends once its tunnel is up), records each
   call and forwards it with `grpc_pass`. No CA is involved — there is nothing
   to decrypt.
6. Every decoded call is recorded once, on its terminator; the outer `CONNECT`
   is not recorded again. The `protocol` label says what it was — `https`,
   `grpcs` (gRPC over TLS), `grpc` (plaintext) — and `tunnel` marks a CONNECT
   that wasn't decoded, so `sum by (protocol)` on outbound shows how much egress
   is still opaque. For gRPC, `route` is the method path, kept as is,
   and `status` is `grpc_<code>` from `grpc-status` (`grpc_0` OK, `grpc_14`
   UNAVAILABLE, …); a non-200 HTTP status (nginx or transport failure) is kept
   as is.

The whole machinery ships in the image. A deployment enables it with
one env var plus a mounted CA — no config file changes.

With interception off (the default) none of it is loaded: the image's
entrypoint links `intercept.conf` into `conf.d/` only when the container
starts with `INTERCEPT_TLS=on`. So a sidecar that doesn't intercept has no
`:3129` listener, no OpenSSL context and no system CA bundle in memory.

---

## Step by step

### 1. Create a CA (one per namespace)

The sidecar signs its per-SNI leaf certs with this CA; the app must trust it.
Keep the **key** in a Secret, never in git.

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout ca.key -out ca.crt -subj "/CN=<namespace>-intercept-ca"

kubectl -n <namespace> create secret generic intercept-ca \
  --from-file=ca.crt=ca.crt --from-file=ca.key=ca.key
```

### 2. Enable on the sidecar (nginx container)

Set the switch and mount the CA **keypair** — nginx only:

```yaml
- name: nginx
  image: ghcr.io/hatam-abolghasemi/openresty-prometheus-exporter:alpine
  env:
    - name: APP_PORT
      value: "8080"
    - name: INTERCEPT_TLS           # the whole on-switch
      value: "on"
  volumeMounts:
    - { name: intercept-ca, mountPath: /etc/nginx/intercept/ca.crt, subPath: ca.crt, readOnly: true }
    - { name: intercept-ca, mountPath: /etc/nginx/intercept/ca.key, subPath: ca.key, readOnly: true }
# ...
volumes:
  - name: intercept-ca
    secret: { secretName: intercept-ca }
```

Optional env:

| Env | Default | Meaning |
|---|---|---|
| `INTERCEPT_TLS` | unset (off) | `on` enables interception: every CONNECT is classified and decoded as above |
| `INTERCEPT_BYPASS` | (none) | Comma list of hosts to **never** intercept (mTLS / cert-pinned destinations); their CONNECTs use nginx's native tunnel |

`INTERCEPT_TLS` is read once, when the container starts, and decides whether
the `:3129` terminator is loaded at all; the others are read once per worker.
Changing any of them needs a container restart, not a reload (a Deployment
env change restarts the pod anyway).

The decision is made by the image's entrypoint. If your Deployment sets
`command:` for the nginx container, the entrypoint is skipped and interception
stays off (the sidecar logs `INTERCEPT_TLS=on but intercept.conf isn't loaded`
and tunnels HTTPS unchanged). Set `args:` instead of `command:`, or keep the
entrypoint first:
`command: ["/usr/local/bin/openresty-exporter-entrypoint", "openresty", "-g", "daemon off;"]`.

### 3. Make the app trust the CA — mount `ca.crt` (cert only)

Mount **only** `ca.crt` into the app, then tell the app's HTTP client to trust
it. The key never goes near the app.

```yaml
- name: app
  volumeMounts:
    - { name: intercept-ca, mountPath: /etc/intercept/ca.crt, subPath: ca.crt, readOnly: true }
```

How you trust it differs per runtime — this is the only language-specific step:

| Runtime | Trust the CA via | Replaces or appends the trust store? |
|---|---|---|
| libcurl / curl | `CURL_CA_BUNDLE=/etc/intercept/ca.crt`, or PHP `curl.cainfo` | **Replaces** |
| Python `requests` | `REQUESTS_CA_BUNDLE=/etc/intercept/ca.crt` | **Replaces** |
| Go | `SSL_CERT_FILE` / `SSL_CERT_DIR` | **Replaces** |
| Node.js | `NODE_EXTRA_CA_CERTS=/etc/intercept/ca.crt` | **Appends** |
| .NET | OS store via `update-ca-certificates`, or `SSL_CERT_FILE` | Appends (OS store) |
| Java | `keytool -import` into the JVM truststore | Appends |
| generic OpenSSL | `SSL_CERT_FILE` / `SSL_CERT_DIR` | **Replaces** |

> **Replace vs append matters.** The "replace" mechanisms make the client trust
> **only** your CA. That's complete *as long as every TLS destination the client
> reaches is intercepted* (proxy-only egress, nothing bypassed). If the same
> client also reaches TLS you *don't* intercept (a bypassed host, or TLS that
> doesn't go through the proxy), give it a **combined** bundle (system
> CAs + your CA) or use an appending mechanism — otherwise those calls fail
> verification.

### 4. Verify

From inside the app, call an HTTPS URL and look for real route/status:

```bash
curl -s "https://example.com/some/path" -o /dev/null -w '%{http_code}\n'
curl -s localhost:9145/metrics | grep 'host="example.com"'
```

Success looks like a decrypted line — `method="GET"`, a real `route`, a real
`status` — **not** `method="CONNECT"`:

```
nginx_http_requests_total{method="GET",route="/some/path",status="404",host="example.com",mode="1",...} 1
```

---

## PHP (php-fpm) end-to-end example

PHP is the most common first integration, and the one with the most moving
parts. All four pieces:

**1. Trust the CA** — `php.ini`:

```ini
[curl]
curl.cainfo = /etc/intercept/ca.crt
```

(`curl.cainfo` only affects libcurl, so PDO/MySQL TLS is untouched.)

**2. Route egress** — `www.conf` (so workers see the proxy vars):

```ini
clear_env = no
```

**3. Mount** `ca.crt` into the app at `/etc/intercept/ca.crt` (cert only, as in
step 3 above).

**4. Enable** on the nginx container (`INTERCEPT_TLS=on` + CA keypair mounted).

---

## .NET notes

`HttpClient` reads `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` from the environment
automatically on Linux (.NET Core 3.1+), so egress routing needs no code. For
trust, .NET validates against the OS store via OpenSSL — add your CA to it:

```dockerfile
COPY ca.crt /usr/local/share/ca-certificates/intercept-ca.crt
RUN update-ca-certificates        # appends -> public TLS keeps working
```

Do **not** reach for a per-call `ServerCertificateCustomValidationCallback`
that returns `true`. That *disables* verification instead of trusting your CA,
and silently accepts any cert from anyone — the opposite of what interception
is for.

---

## Security model

Interception is a man-in-the-middle of your own egress. It is safe only inside a
trust domain you control, and only if you respect these:

- **The CA is a trust anchor.** Whoever holds `ca.key` can impersonate *any*
  site to *every* pod that trusts the CA. Scope it to one namespace, keep the
  key in a Secret with tight RBAC, and mount the **key into the nginx container
  only** — never the app.
- **Rotate** by recreating the Secret and restarting the pods.
- **The destination is still verified.** `:3129` re-originates with
  `proxy_ssl_verify on` against the system bundle, so a destination with a bad
  or expired real certificate still fails — it just fails *at the sidecar*
  (surfacing as `502`/`504`) instead of in the app. This is a feature: you are
  not downgrading the app's TLS, you're relocating the verification.
- **Can't-intercept destinations exist.** A service your app reaches with its
  own client certificate (outbound mTLS), or one it pins certificates for,
  cannot be intercepted without breaking it. Put those in `INTERCEPT_BYPASS` —
  they fall back to plain `CONNECT host:port` (outbound visibility), which is the
  physical limit: you can't read inside a tunnel you didn't terminate.

See also the **trust boundary** note on the XFCC override in
[`source_attribution`](modules.md#source_attributionlua) — unrelated mechanism,
same discipline.

---

## Scope & limits

- TLS is intercepted on whatever port it uses; `:3129` re-originates on the
  port the app addressed (taken from its `Host` header, `443` when absent).
  Plaintext gRPC is re-originated on its `:authority` port (`80` when absent).
- Bypassed hosts, and tunnels that carry neither TLS nor HTTP/2, always show the
  CONNECT-style line — that's intended, not a failure.
- With interception on, CONNECTs are relayed by a Lua copy loop
  ([`connect_tunnel`](modules.md#connect_tunnellua)) instead of nginx's native
  tunnel; bypassed hosts and interception off keep the native one.
- h2c through `:3130` is forwarded with `grpc_pass`: a non-gRPC HTTP/2-cleartext
  client behind the proxy (rare) should be listed in `INTERCEPT_BYPASS`.
- `:3128` answers `200` before it connects to the destination (it must read the
  tunnel's first bytes to choose it). An unreachable destination then closes the
  tunnel instead of answering `502`; the CONNECT metric still shows `502` (the
  access log shows the `200` that was sent).
- A TLS tunnel that doesn't carry HTTP — a database or broker over TLS reached
  through the proxy — goes to `:3129` too and fails there. Such clients rarely
  use an HTTP proxy; if one does, list its host in `INTERCEPT_BYPASS`.
- Minted leaf certs are cached per SNI in `ssl_shared_dict ssl_mint_cache`
  (`cert_ttl` seconds, default 1 day). One leaf key is shared across hosts (as
  mitmproxy does); see [`tls_intercept`](modules.md#tls_interceptlua).
- Destinations are resolved with the cluster DNS from `/etc/resolv.conf` and
  the answer is reused for `dns_cache_ttl` seconds (default 10). Pooled
  connections idle out after `pool_idle_timeout` (default 60s).

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| App: `SSL certificate problem: unable to get local issuer certificate` | The app doesn't trust your CA — the trust step (3) isn't applied, or applied to a client that reads a different bundle. For curl test manually: `curl --cacert /etc/intercept/ca.crt https://host/` |
| Metrics still show `method="CONNECT"` | Interception didn't fire: `INTERCEPT_TLS` not `on`, CA not mounted, host is in `INTERCEPT_BYPASS`, the tunnel carries neither TLS nor HTTP/2, or the container's `command:` skipped the entrypoint (log line `intercept.conf isn't loaded`; see step 2) |
| Container exits with `INTERCEPT_TLS=on but /etc/nginx/conf.d/intercept.conf can't be created` | `conf.d/` is read-only (a whole-directory ConfigMap mount, or `readOnlyRootFilesystem`). Mount your `default.conf` with `subPath` so `conf.d/` stays writable |
| `502`/`504` on a specific host after enabling | Re-origination's `proxy_ssl_verify` rejected the real cert (good — bad/expired upstream cert), **or** egress to that host is blocked. Check `kubectl logs <pod> -c nginx` for `certificate verify failed` vs a connect timeout |
| `CONNECT tunnel failed, response 500` right after enabling | A Lua error on the `:3129` leg — almost always a CA read/parse problem. `kubectl logs <pod> -c nginx` will have a `tls_intercept:` line naming it (can't read CA, parse failure). `Permission denied` on `ca.key` means the file isn't readable by the nginx workers (they don't run as root): keep the Secret's default `0644`, or set `defaultMode` accordingly |
| Works for curl, not for the app's own calls | The app uses a client that reads a different trust store than the one you configured (e.g. PHP streams, not libcurl; or Python without `REQUESTS_CA_BUNDLE`) |
| `nginx -t` fails after a config change | The `:3129` server needs the baked `fallback.crt`/`fallback.key` and `ssl_mint_cache` — don't remove `optional/intercept.conf` or `main.d/intercept-env.conf` from the image |

Next: [stream](stream.md).
