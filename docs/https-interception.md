# https interception — see inside outbound HTTPS

Turn outbound HTTPS from an opaque `CONNECT host:port` line into the **real**
method, route, and status — `GET /v2/orders → 404` instead of just
`CONNECT api.internal:443 → 200`.

This is **TLS interception** (a MITM of your app's own egress, inside your own
trust domain). It is off by default and enabled per deployment. Read the
[security model](#security-model) before enabling it in production.

**Depends on [outbound](outbound.md)**: it only acts on CONNECTs that already
arrive at `:3128`, so the app's egress must go through outbound first.
Independent of [inbound](inbound.md) and [stream](stream.md).

---

## How it works

```
app ──CONNECT api:443──▶ :3128 ──(intercepted port?)──▶ :3129 TLS terminator
                                                           │ mints a leaf cert for "api"
                                                           │ signed by YOUR CA (per-SNI)
                                                           │ decrypts, records the request
                                                           └─▶ re-originates to api:443 over
                                                               VERIFIED TLS (proxy_ssl_verify on)
```

1. The app opens `CONNECT api:443` as usual (outbound).
2. [`intercept.should()`](modules.md#interceptlua) decides, per CONNECT, whether
   this is an intercepted port on a non-bypassed host. If yes, `:3128` tunnels
   it to the local terminator `127.0.0.1:3129` instead of the real host.
3. `:3129` ([`conf.d/intercept.conf`](../docker/conf.d/intercept.conf) +
   [`tls_intercept`](modules.md#tls_interceptlua)) terminates the TLS using a
   leaf certificate **minted on the fly for the requested SNI**, signed by a CA
   you provide. It reads the now-decrypted request and records it with the same
   `http_metrics.record()` as everything else.
4. It then re-originates to the real destination over a **verified** TLS
   connection (`proxy_ssl_verify on` against the system trust store) — so the
   app's end-to-end TLS guarantee is preserved, not dropped.

The whole machinery is **baked into the image**. A deployment enables it with
one env var plus a mounted CA — no config file changes.

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
| `INTERCEPT_TLS` | unset (off) | `on` enables interception |
| `INTERCEPT_TLS_PORTS` | `443` | Comma list of TLS ports to intercept |
| `INTERCEPT_BYPASS` | (none) | Comma list of hosts to **never** intercept (mTLS / cert-pinned destinations) |

These are read once per worker, so changing them needs a pod restart (a
Deployment env change does that anyway).

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
> reaches is intercepted* (proxy-only egress, all on an intercepted port,
> nothing bypassed). If the same client also reaches TLS you *don't* intercept
> (a bypassed host, a non-443 TLS port), give it a **combined** bundle (system
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

- Only ports in `INTERCEPT_TLS_PORTS` (default `443`) are intercepted; every
  other TLS port falls through to outbound's `CONNECT host:port` view. To
  intercept another port it must also be re-originated correctly — the baked
  `:3129` re-originates on the destination's own port via `$host$request_uri`,
  so standard HTTPS ports work; exotic setups may need a dedicated terminator.
- Bypassed hosts and non-intercepted ports always show the CONNECT-style line —
  that's intended, not a failure.
- Minted leaf certs are cached per SNI in `ssl_shared_dict ssl_mint_cache`
  (`cert_ttl` seconds, default 1 day). One leaf key is shared across hosts (as
  mitmproxy does); see [`tls_intercept`](modules.md#tls_interceptlua).

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| App: `SSL certificate problem: unable to get local issuer certificate` | The app doesn't trust your CA — the trust step (3) isn't applied, or applied to a client that reads a different bundle. For curl test manually: `curl --cacert /etc/intercept/ca.crt https://host/` |
| Metrics still show `method="CONNECT"` | Interception didn't fire: `INTERCEPT_TLS` not `on`, CA not mounted, port not in `INTERCEPT_TLS_PORTS`, or host is in `INTERCEPT_BYPASS` |
| `502`/`504` on a specific host after enabling | Re-origination's `proxy_ssl_verify` rejected the real cert (good — bad/expired upstream cert), **or** egress to that host is blocked. Check `kubectl logs <pod> -c nginx` for `certificate verify failed` vs a connect timeout |
| `CONNECT tunnel failed, response 500` right after enabling | A Lua error on the `:3129` leg — almost always a CA read/parse problem. `kubectl logs <pod> -c nginx` will have a `tls_intercept:` line naming it (can't read CA, parse failure). `Permission denied` on `ca.key` means the file isn't readable by the nginx workers (they don't run as root): keep the Secret's default `0644`, or set `defaultMode` accordingly |
| Works for curl, not for the app's own calls | The app uses a client that reads a different trust store than the one you configured (e.g. PHP streams, not libcurl; or Python without `REQUESTS_CA_BUNDLE`) |
| `nginx -t` fails after a config change | The `:3129` server needs the baked `fallback.crt`/`fallback.key` and `ssl_mint_cache` — don't remove `conf.d/intercept.conf` or `main.d/intercept-env.conf` from the image |

Next: [stream](stream.md).
