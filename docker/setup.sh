#!/bin/sh
# Build-time setup, run once by docker/Dockerfile on top of any
# docker-openresty flavor (Alpine, Debian/Ubuntu, RHEL-family; package-built
# or source-built; -debug/-valgrind). It only adapts paths that differ between
# flavors -- nothing here is version-specific.
set -eu

# 1. Make the stock config path point at /etc/nginx/nginx.conf, so the base
#    image's own CMD (openresty, openresty-debug, ...) and a bare `nginx -t`
#    both load it. The path is asked from the binary: it differs per flavor
#    (/usr/local/openresty/nginx/conf, /usr/local/openresty-debug/nginx/conf).
info=$(nginx -V 2>&1)
conf=$(printf '%s\n' "$info" | sed -n 's/.*--conf-path=\([^ ]*\).*/\1/p')
if [ -z "$conf" ]; then
    prefix=$(printf '%s\n' "$info" | sed -n 's/.*--prefix=\([^ ]*\).*/\1/p')
    conf="${prefix%/}/conf/nginx.conf"
fi
[ -f "$(dirname "$conf")/mime.types" ] || { echo "setup: no mime.types next to $conf" >&2; exit 1; }
ln -sf /etc/nginx/nginx.conf "$conf"

# 2. The interception leg verifies real upstreams against the system CA
#    bundle. Its location differs per distro family, and Alpine flavors don't
#    ship one at all, so install it where missing and expose it at one fixed
#    path that intercept.conf reads (mount your own bundle there to override).
find_bundle() {
    for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
        [ -s "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}
if ! find_bundle > /dev/null; then
    if command -v apk > /dev/null; then
        apk add --no-cache ca-certificates
    elif command -v apt-get > /dev/null; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates
        rm -rf /var/lib/apt/lists/*
    elif command -v microdnf > /dev/null; then
        microdnf install -y ca-certificates && microdnf clean all
    elif command -v dnf > /dev/null; then
        dnf install -y ca-certificates && dnf clean all
    elif command -v yum > /dev/null; then
        yum install -y ca-certificates && yum clean all
    fi
fi
bundle=$(find_bundle) || { echo "setup: no CA bundle found or installable" >&2; exit 1; }
ln -sf "$bundle" /etc/nginx/intercept/trusted-ca.crt

# 3. Directories that are empty in the image and filled by mounts.
mkdir -p /etc/nginx/main.d /etc/nginx/conf.d /etc/nginx/stream.d
chmod -R a+rX /opt/prometheus
