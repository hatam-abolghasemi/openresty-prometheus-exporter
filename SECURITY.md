# Security policy

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub:
[**Report a vulnerability**](https://github.com/hatam-abolghasemi/openresty-prometheus-exporter/security/advisories/new).

Include what you found, how to reproduce it, the image tag or digest (or the
commit if you run the Lua modules on your own nginx), and the impact you see.
You'll get an acknowledgement within 7 days. Once a fix is out, the advisory is
published with credit to you, unless you'd rather stay anonymous.

## Supported versions

Fixes land on `main` and ship in the next image build. The image is rebuilt on
every change, for every docker-openresty release and flavor, so **the latest
image of your flavor is the supported one**. Older digests are not patched.

The vendored Prometheus client library is tracked from
[knyar/nginx-lua-prometheus](https://github.com/knyar/nginx-lua-prometheus);
issues in it are reported upstream and picked up here. Issues in nginx or
OpenResty itself belong to the [OpenResty project](https://openresty.org/).

## Areas that deserve extra care

- **HTTPS interception.** With `INTERCEPT_TLS=on` the sidecar terminates TLS for
  outbound calls with a CA you provide and mints per-host certificates. Anyone
  who holds that CA's private key can impersonate any host to pods that trust
  it. Keep the key in a Secret, scope trust to the pods that need it, and keep
  mTLS or pinned hosts on the skip list. See
  [docs/https-interception.md](docs/https-interception.md).
- **The forward proxy** listens on `127.0.0.1:3128` only. Exposing it beyond the
  pod turns it into an open proxy.
- **The metrics port (`:9145`, `:9254`)** exposes route shapes, hostnames and
  caller service names. Treat it as internal.
