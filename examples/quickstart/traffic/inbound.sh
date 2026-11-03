#!/bin/sh
# Demo traffic INTO the app, through the sidecar on app:80.
#
# The paths are picked to show route sanitization: every order id, user UUID
# and status code below would otherwise be its own time series. On /metrics
# they collapse to /anything/orders/$param, /anything/users/$param and
# /status/$param -- while the `status` label keeps the real response code.

target="http://app:80"
i=0

sleep 3
while true; do
  i=$((i + 1))
  uuid=$(cat /proc/sys/kernel/random/uuid)

  curl -s -o /dev/null "$target/anything/orders/$i"
  curl -s -o /dev/null "$target/anything/users/$uuid"
  curl -s -o /dev/null -X POST -d '{"item":"pizza"}' "$target/post"

  case $((i % 10)) in
    3) curl -s -o /dev/null "$target/status/404" ;;
    6) curl -s -o /dev/null "$target/status/500" ;;
    9) curl -s -o /dev/null "$target/delay/1" ;;
  esac

  sleep 0.5
done
