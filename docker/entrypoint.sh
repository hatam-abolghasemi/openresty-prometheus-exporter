#!/bin/sh
# Container entrypoint: decides, once per container start, which optional
# configs nginx loads, then hands over to the command (the image's CMD, or
# whatever `args:` a Deployment sets).
#
#   INTERCEPT_TLS=on   link /etc/nginx/optional/intercept.conf into conf.d/,
#                      so the :3129 https-interception terminator exists.
#                      Off (the default): the file is not loaded at all.
#
# Nothing here runs on `nginx -s reload`; changing INTERCEPT_TLS needs a
# container restart. A Deployment that sets `command:` bypasses this script;
# set `args:` instead (see docs/https-interception.md).
set -eu

src=/etc/nginx/optional/intercept.conf
link=/etc/nginx/conf.d/intercept.conf

if [ "${INTERCEPT_TLS:-}" = "on" ]; then
    if [ ! -e "$link" ]; then
        if ! ln -s "$src" "$link" 2>/dev/null; then
            echo "entrypoint: INTERCEPT_TLS=on but $link can't be created (read-only conf.d?); refusing to start without interception" >&2
            exit 1
        fi
    fi
elif [ -L "$link" ] && [ "$(readlink "$link")" = "$src" ]; then
    # left over from an earlier start of this same container with it on
    rm -f "$link"
fi

exec "$@"
