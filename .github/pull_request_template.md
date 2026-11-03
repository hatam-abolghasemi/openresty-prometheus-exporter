## What and why

<!-- What does this change, and what problem does it solve? Link the issue: Fixes #123 -->

## Area

- [ ] inbound / outbound
- [ ] https interception
- [ ] stream (L4)
- [ ] route sanitizer / host classifier / caller identity
- [ ] image / docker
- [ ] Grafana dashboard
- [ ] docs only

## Checklist

- [ ] `luajit tests/lib_test.lua` passes (new pure logic has test cases)
- [ ] No new per-request cost on the hot path, or it's justified above
- [ ] New labels have a bounded set of values; new costly metrics/labels default to off
- [ ] `nginx_metric_errors_total` stays 0 with the change running
- [ ] Docs updated (feature guide, `docs/metrics-reference.md` for metrics/labels)
- [ ] `CHANGELOG.md` entry added
