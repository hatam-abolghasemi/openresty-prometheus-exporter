#!/bin/sh
# Demo traffic OUT of the app: runs in the app's network namespace and sends
# requests to the `upstream` service through the sidecar's forward proxy --
# the same thing the app does when HTTP_PROXY=http://127.0.0.1:3128 is set.
# These show up on /metrics with mode="1" and the upstream as `host`.

proxy="http://127.0.0.1:3128"
target="http://upstream:8080"
i=0

sleep 5
while true; do
  i=$((i + 1))

  curl -s -o /dev/null -x "$proxy" "$target/anything/payments/$i"
  curl -s -o /dev/null -x "$proxy" "$target/get"

  case $((i % 8)) in
    2) curl -s -o /dev/null -x "$proxy" "$target/status/503" ;;
    5) curl -s -o /dev/null -x "$proxy" "$target/delay/2" ;;
  esac

  sleep 1
done
