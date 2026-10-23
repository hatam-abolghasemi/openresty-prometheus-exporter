# One Dockerfile for every docker-openresty flavor. OPENRESTY_TAG is the full
# upstream tag, flavor included, e.g. <release>-alpine or <release>-bookworm.
ARG BASE_IMAGE=openresty/openresty
ARG OPENRESTY_TAG

# The :3129 interception server needs a certificate on disk to start and to
# pass `nginx -t`; real handshakes get a minted one (lib/tls_intercept.lua).
# Generated once on the build host, so no flavor needs an openssl binary.
FROM --platform=$BUILDPLATFORM alpine AS fallback-cert
RUN apk add --no-cache openssl \
 && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout /fallback.key -out /fallback.crt \
        -subj "/CN=openresty-intercept-fallback"

FROM ${BASE_IMAGE}:${OPENRESTY_TAG}

COPY vendor/nginx-lua-prometheus/prometheus.lua \
     vendor/nginx-lua-prometheus/prometheus_keys.lua \
     vendor/nginx-lua-prometheus/prometheus_resty_counter.lua \
     /opt/prometheus/
COPY lib/ /opt/prometheus/lib/
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/main.d/ /etc/nginx/main.d/
COPY docker/conf.d/ /etc/nginx/conf.d/
COPY --from=fallback-cert /fallback.crt /fallback.key /etc/nginx/intercept/
COPY docker/setup.sh /tmp/setup.sh

RUN sh /tmp/setup.sh && rm /tmp/setup.sh

ENV APP_PORT=8080

EXPOSE 80 9145
