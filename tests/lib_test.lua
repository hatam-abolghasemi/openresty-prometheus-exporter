-- Unit tests for the pure lib/ modules, plus the HTTP label schema/value
-- pairing. Plain Lua 5.1 / LuaJIT, no test framework, no nginx:
--
--   luajit tests/lib_test.lua        (from the repo root)

package.path = "./lib/?.lua;./vendor/nginx-lua-prometheus/?.lua;" .. package.path

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end
local function eq(got, want)
    if got ~= want then
        error(("expected %q, got %q"):format(tostring(want), tostring(got)), 2)
    end
end
local function same(got, want)
    eq(table.concat(got, ","), table.concat(want, ","))
end

local route_sanitizer = require("route_sanitizer")
test("route: numeric id", function() eq(route_sanitizer.sanitize("/orders/8231"), "/orders/$param") end)
test("route: uuid + nested", function()
    eq(route_sanitizer.sanitize("/orders/8231/items/550e8400-e29b-41d4-a716-446655440000"),
       "/orders/$param/items/$param")
end)
test("route: keeps real words", function() eq(route_sanitizer.sanitize("/orders/new"), "/orders/new") end)
test("route: strips query, collapses slashes", function() eq(route_sanitizer.sanitize("//a//b?x=1"), "/a/b") end)
test("route: memoised opts stay per-table", function()
    local uuid = "/u/550e8400-e29b-41d4-a716-446655440000"
    local off, on = { uuid = false, long_with_digit = false, hex = false, slug_suffix_digit = false }, { uuid = true }
    for _ = 1, 2 do  -- second pass hits the cache
        eq(route_sanitizer.sanitize(uuid, off), uuid)
        eq(route_sanitizer.sanitize(uuid, on), "/u/$param")
        eq(route_sanitizer.sanitize(uuid), "/u/$param")
    end
end)
test("route: adjacent params collapse", function() eq(route_sanitizer.sanitize("/1/2/3"), "/$param") end)
test("route: nil is root", function() eq(route_sanitizer.sanitize(nil), "/") end)
test("route: check can be turned off", function()
    eq(route_sanitizer.sanitize("/users/123", { pure_numeric = false, long_with_digit = false }), "/users/123")
end)

local host_classifier = require("host_classifier")
test("host: cluster ip", function() eq(host_classifier.classify("10.233.4.12", "10.233."), "kubernetes") end)
test("host: other ip", function() eq(host_classifier.classify("8.8.8.8:443", "10.233."), "$ip") end)
test("host: localhost", function() eq(host_classifier.classify("localhost:80", "10.233."), "localhost") end)
test("host: ipv6", function() eq(host_classifier.classify("::1", "10.233."), "$ip") end)
test("host: name passes", function() eq(host_classifier.classify("api.example.com", "10.233."), "api.example.com") end)

local client_subnet = require("client_subnet")
test("subnet: private /24", function() eq(client_subnet.mask("10.233.4.17"), "10.233.4.0") end)
test("subnet: public /16", function() eq(client_subnet.mask("8.8.8.8"), "8.8.0.0") end)
test("subnet: xff first", function() eq(client_subnet.mask("10.1.2.3, 8.8.8.8"), "10.1.2.0") end)
test("subnet: ipv6 unknown", function() eq(client_subnet.mask("::1"), "unknown") end)

local app_toggle = require("app_toggle")
test("toggle: no entry = on", function() eq(app_toggle.enabled({}, "outbound"), true) end)
test("toggle: off", function() eq(app_toggle.enabled({ outbound = { metrics_enabled = false } }, "outbound"), false) end)
test("toggle: nil key = on", function() eq(app_toggle.enabled({}, nil), true) end)

local gauge_expiry = require("gauge_expiry")
test("expiry: key round trip keeps empty values", function()
    local scope, labels = gauge_expiry.decode_key(gauge_expiry.encode_key("req", { "GET", "", "200" }))
    eq(scope, "req"); same(labels, { "GET", "", "200" })
end)
test("expiry: sweep expires only stale keys", function()
    local store = {}
    local dict = {
        get = function(_, k) return store[k] end,
        set = function(_, k, v) store[k] = v end,
        delete = function(_, k) store[k] = nil end,
        get_keys = function() local ks = {} for k in pairs(store) do ks[#ks + 1] = k end return ks end,
    }
    local t = gauge_expiry.new{ dict = dict, window = 10 }
    t:touch("req", { "old" }, 100)
    t:touch("req", { "new" }, 195)
    local expired = {}
    eq(t:sweep(200, function(_, labels) expired[#expired + 1] = labels[1] end), 1)
    eq(expired[1], "old")
end)

local sa = require("source_attribution")
test("ptr: service shape", function()
    local svc, ns = sa.parse_ptr("10-233-1-2.checkout.shop.svc.cluster.local.")
    eq(svc, "checkout"); eq(ns, "shop")
end)
test("ptr: pod shape", function()
    local svc, ns = sa.parse_ptr("10-233-1-2.shop.pod.cluster.local.")
    eq(svc, nil); eq(ns, "shop")
end)
test("xfcc: spiffe", function()
    local ns, sa_name = sa.parse_xfcc('By=x;URI=spiffe://cluster.local/ns/shop/sa/checkout;Hash=y')
    eq(ns, "shop"); eq(sa_name, "checkout")
end)
test("waypoint: overrides only the waypoint", function()
    local xfcc = "URI=spiffe://cluster.local/ns/shop/sa/checkout"
    eq((sa.apply_waypoint_override("waypoint", "mesh", xfcc, "waypoint")), "checkout")
    eq((sa.apply_waypoint_override("billing", "shop", xfcc, "waypoint")), "billing")
end)
test("static: dynamic prefix defers to PTR", function()
    eq(sa.classify_static("10.233.1.2", { dynamic_prefix = { 10, 233 } }), nil)
end)
test("static: zone map", function()
    local svc, zone = sa.classify_static("192.168.104.9", {
        static_ranges = { { prefix = { 192, 168 }, label = "internal", zone_map = { [104] = "zone_a" } } } })
    eq(svc, "internal"); eq(zone, "zone_a")
end)

local self_identity = require("self_identity")
test("identity: pod ip from /etc/hosts", function()
    local hosts = "127.0.0.1 localhost\n10.233.5.6\tapp-7d9f-abc\n"
    eq(self_identity.pod_ip_from_hosts(hosts, "app-7d9f-abc"), "10.233.5.6")
    eq(self_identity.pod_ip_from_hosts(hosts, "other"), nil)
end)

local slots = require("connection_slots")
test("slots: parse worker_connections", function()
    eq(slots.parse_worker_connections("events {\n    worker_connections  4096;\n}\n"), 4096)
    eq(slots.parse_worker_connections("events { # worker_connections 1;\n  worker_connections 512 ;\n}"), 512)
    eq(slots.parse_worker_connections("# worker_connections 1024;\nevents {}\n"), nil)
    eq(slots.parse_worker_connections("events {}\n"), nil)
    eq(slots.parse_worker_connections(nil), nil)
end)
test("slots: limit from config, nginx.conf, or nothing", function()
    local conf = "worker_processes 2;\nevents {\n    worker_connections 4096;\n}\n"
    local reads = 0
    local reader = function(path) reads = reads + 1; if path == "/n.conf" then return conf end end
    -- explicit setting wins and skips the file
    local limit, src = slots.limit({ worker_connections = 1000, nginx_conf_path = "/n.conf" }, 2, reader)
    eq(limit, 2000); eq(src, "config"); eq(reads, 0)
    -- 0 = read nginx.conf
    limit, src = slots.limit({ worker_connections = 0, nginx_conf_path = "/n.conf" }, 2, reader)
    eq(limit, 8192); eq(src, "nginx.conf")
    -- unreadable file, missing directive, bad worker count: unknown, never a guess
    eq(slots.limit({ worker_connections = 0, nginx_conf_path = "/missing" }, 2, reader), nil)
    eq(slots.limit({ worker_connections = 0, nginx_conf_path = "/n.conf" }, 2, function() return "events {}" end), nil)
    eq(slots.limit({ worker_connections = 0, nginx_conf_path = "" }, 2, reader), nil)
    eq(slots.limit({ worker_connections = 1000 }, 0, reader), nil)
    eq(slots.limit({ worker_connections = 1000 }, nil, reader), nil)
end)
test("slots: the image's nginx.conf parses", function()
    local f = assert(io.open("docker/nginx.conf", "r"))
    local content = f:read("*a"); f:close()
    eq(slots.parse_worker_connections(content), 4096)
end)

-- Schema and values must line up name-for-name with every label on, not just
-- in count (a count-only match files values under the wrong label names).
local cfg = require("metrics_config").http
local http_metrics = require("http_metrics")
test("http labels: values follow schema order", function()
    for k in pairs(cfg) do
        if k:match("^label_") then cfg[k] = true end
    end
    local schema = http_metrics._build_label_schema()
    local values = {}
    for _, name in ipairs(schema) do values[name] = "v_" .. name end
    values.app, values.namespace = nil, nil
    local got = http_metrics._build_labels(values)
    eq(#got, #schema)
    for i, name in ipairs(schema) do
        if name ~= "app" and name ~= "namespace" then eq(got[i], "v_" .. name) end
    end
end)

-- resolver: keeps the last answer until a new one replaces it; background
-- refresh relabels reassigned IPs within one interval
do
    local sa = require("source_attribution")
    local function fake_dict()
        local d = {}
        return {
            get = function(_, k) return d[k] end,
            set = function(_, k, v) d[k] = v; return true end,
            add = function(_, k, v) if d[k] ~= nil then return false end d[k] = v; return true end,
            delete = function(_, k) d[k] = nil end,
            get_keys = function()
                local keys = {}
                for k in pairs(d) do keys[#keys + 1] = k end
                table.sort(keys)
                return keys
            end,
            raw = d,
        }
    end
    local function ptr(...)
        local answers = {}
        for i, name in ipairs({...}) do answers[i] = { ptrdname = name } end
        return answers
    end
    local ORDERS = "10-233-1-2.orders.shop.svc.cluster.local."
    local BILLING = "10-233-1-2.billing.pay.svc.cluster.local."
    local NXDOMAIN = { errcode = 3, errstr = "name error" }

    -- answer: what DNS returns now (mutable via st.answer); opts merged in
    local function make(answer, opts)
        local st = { answer = answer, queued = {}, queries = 0, clock = 1000, timers = {} }
        local lib = { TYPE_PTR = 12 }
        function lib:new()
            return { query = function() st.queries = st.queries + 1; return st.answer end }
        end
        st.dict = fake_dict()
        local o = {
            dict = st.dict, resolver_lib = lib, dynamic_prefix = {10, 233},
            default_service = "health-probe", default_namespace = "default",
            refresh_interval = 15, forget_after = 3600, sync_timeout_ms = 100,
            spawn = function(_, fn) st.queued[#st.queued + 1] = fn; return true end,
            every = function(interval, fn) st.timers[#st.timers + 1] = { interval, fn }; return true end,
            now = function() return st.clock end,
            can_block = function() return true end,
            is_leader = function() return true end,
        }
        for k, v in pairs(opts or {}) do o[k] = v end
        st.r = sa.new_resolver(o)
        return st
    end
    local ip = "10.233.77.216"

    test("pick_ptr: deterministic across answer order", function()
        local a = "10-233-69-143.my-service.ingress-nginx.svc.cluster.local."
        local b = "10-233-69-143.sahand-stg-ingress-nginx-controller.ingress-nginx.svc.cluster.local."
        local m = "10-233-69-143.sahand-stg-ingress-nginx-controller-metrics.ingress-nginx.svc.cluster.local."
        eq((sa.pick_ptr(ptr(b, m, a), { "%-metrics$" })), "my-service")
        eq((sa.pick_ptr(ptr(m, a, b), { "%-metrics$" })), "my-service")
        eq((sa.pick_ptr(ptr(m, a, b), { "%-metrics$", "^my%-service$" })), "sahand-stg-ingress-nginx-controller")
    end)
    test("pick_ptr: ignored names still used when nothing else is left", function()
        local svc, ns = sa.pick_ptr(ptr("10-233-1-2.app-metrics.shop.svc.cluster.local."), { "%-metrics$" })
        eq(svc, "app-metrics"); eq(ns, "shop")
    end)

    test("resolver: probe fallback namespace is separate from public-IP namespace", function()
        local st = make(ptr(ORDERS), { sync_timeout_ms = false,
            default_namespace = "unknown", default_service_namespace = "default" })
        local svc, ns = st.r:resolve(ip)
        eq(svc, "health-probe"); eq(ns, "default")
        svc, ns = st.r:resolve("8.8.8.8")
        eq(svc, "public"); eq(ns, "unknown")
    end)

    test("resolver: miss without sync returns defaults and queues one lookup", function()
        local st = make(ptr(ORDERS), { sync_timeout_ms = false })
        local svc, ns = st.r:resolve(ip)
        eq(svc, "health-probe"); eq(ns, "default")
        eq(st.queries, 0); eq(#st.queued, 1)
        st.queued[1](false)
        eq(st.dict.raw["inflight:" .. ip], nil)
        eq((st.r:resolve(ip)), "orders")
    end)
    test("resolver: miss in a blocking phase resolves inline", function()
        local st = make(ptr(ORDERS), { sync_timeout_ms = 100 })
        local svc, ns = st.r:resolve(ip)
        eq(svc, "orders"); eq(ns, "shop"); eq(#st.queued, 0)
        eq(st.dict.raw["inflight:" .. ip], nil)
    end)
    test("resolver: inline lookup error falls back to background", function()
        local st = make(nil, { sync_timeout_ms = 100 })
        eq((st.r:resolve(ip)), "health-probe")
        eq(#st.queued, 1)
    end)
    test("resolver: inline not attempted outside blocking phases", function()
        local st = make(ptr(ORDERS), { sync_timeout_ms = 100, can_block = function() return false end })
        eq((st.r:resolve(ip)), "health-probe")
        eq(st.queries, 0)
    end)
    test("resolver: concurrent misses look up once", function()
        local st = make(nil)
        st.r:resolve(ip); st.r:resolve(ip); st.r:resolve(ip)
        eq(st.queries, 1); eq(#st.queued, 1)
    end)
    test("resolver: failed lookup keeps the lock so DNS is not hammered", function()
        local st = make(nil)
        st.r:resolve(ip); st.queued[1](false)
        eq(st.dict.raw["inflight:" .. ip], true)
        eq((st.r:resolve(ip)), "health-probe")
        eq(#st.queued, 1)
    end)
    test("resolver: spawn failure releases lock", function()
        local st = make(nil, { sync_timeout_ms = false, spawn = function() return nil, "too many" end })
        st.r:resolve(ip)
        eq(st.dict.raw["inflight:" .. ip], nil)
    end)

    test("resolver: sparse caller keeps its label (no expiry by age)", function()
        local st = make(ptr(ORDERS))
        st.r:resolve(ip)
        st.answer = nil
        for _ = 1, 10 do
            st.clock = st.clock + 90
            eq((st.r:resolve(ip)), "orders")
        end
        eq(st.queries, 1)
    end)
    test("refresh: DNS error keeps the previous answer", function()
        local st = make(ptr(ORDERS))
        st.r:resolve(ip)
        st.answer = nil
        st.r:refresh_all()
        eq((st.r:resolve(ip)), "orders")
        st.answer = { errcode = 2, errstr = "server failure" }
        st.r:refresh_all()
        eq((st.r:resolve(ip)), "orders")
    end)
    test("refresh: reassigned IP takes the new owner's name", function()
        local st = make(ptr(ORDERS))
        st.r:resolve(ip)
        st.answer = ptr(BILLING)
        eq(st.r:refresh_all(), 1)
        local svc, ns = st.r:resolve(ip)
        eq(svc, "billing"); eq(ns, "pay")
    end)
    test("refresh: NXDOMAIN means nobody owns it -> defaults", function()
        local st = make(ptr(ORDERS))
        st.r:resolve(ip)
        st.answer = NXDOMAIN
        st.r:refresh_all()
        eq((st.r:resolve(ip)), "health-probe")
    end)
    test("refresh: IPs idle past forget_after are dropped", function()
        local st = make(ptr(ORDERS))
        st.r:resolve(ip)
        st.clock = st.clock + 3600
        st.r:refresh_all()
        eq(st.dict.raw[ip], nil)
    end)
    test("refresh: requests keep an IP alive", function()
        local st = make(ptr(ORDERS))
        st.r:resolve(ip)
        for _ = 1, 70 do
            st.clock = st.clock + 60
            st.r:resolve(ip)
        end
        st.r:refresh_all()
        eq((st.r:resolve(ip)), "orders")
    end)
    test("refresh: skips in-flight locks", function()
        local st = make(nil)
        st.r:resolve(ip)
        local before = st.queries
        st.r:refresh_all()
        eq(st.queries, before)
    end)
    test("start: only the leader schedules, at refresh_interval", function()
        local st = make(nil)
        st.r:start()
        eq(#st.timers, 1); eq(st.timers[1][1], 15)
        local follower = make(nil, { is_leader = function() return false end })
        follower.r:start()
        eq(#follower.timers, 0)
    end)
end

-- caller_identity: builds the resolver from metrics_config.http, starts it,
-- and only builds/starts self_identity when discover_identity is on.
do
    local saved = rawget(_G, "ngx")
    local timers = {}
    _G.ngx = {
        worker = { id = function() return 0 end },
        timer  = {
            every = function(i) timers[#timers + 1] = { "every", i }; return true end,
            at    = function(d) timers[#timers + 1] = { "at", d };    return true end,
        },
        now = function() return 0 end, log = function() end,
    }
    local caller_identity = require("caller_identity")
    local cfg = {
        ptr_refresh_interval = 30, ptr_forget_after = 120, ptr_sync_timeout = 50,
        ptr_dns_server = "10.0.0.10", ptr_dns_timeout = 500,
        dynamic_prefix = {10, 233}, default_label = "public", default_namespace = "unknown",
        probe_default_service = "health-probe", probe_default_namespace = "default",
        app = "fallback-app", namespace = "fallback-ns",
    }
    local dict = {}

    test("caller_identity: resolver from config, started", function()
        timers = {}
        cfg.discover_identity = false
        local r, ident = caller_identity.build(cfg, dict)
        eq(ident, nil)
        eq(r.dict, dict); eq(r.refresh_interval, 30); eq(r.forget_after, 120)
        eq(r.sync_timeout_ms, 50); eq(r.dns.nameservers[1][1], "10.0.0.10")
        eq(r.default_service, "health-probe"); eq(r.default_namespace, "default")
        eq(#timers, 1); eq(timers[1][1], "every"); eq(timers[1][2], 30)
    end)

    test("caller_identity: own identity with fallback + on_change, started", function()
        timers = {}
        cfg.discover_identity = true
        local cb = function() end
        local r, ident = caller_identity.build(cfg, dict, { on_change = cb })
        eq(ident.resolver, r); eq(ident.on_change, cb)
        local svc, ns = ident:get()
        eq(svc, "fallback-app"); eq(ns, "fallback-ns")
        eq(#timers, 2); eq(timers[2][1], "at")
    end)

    _G.ngx = saved
end

-- config_env: METRICS_CONFIG overrides on top of metrics_config.lua
do
    local config_env = require("config_env")
    local function fresh() return dofile("./lib/metrics_config.lua") end
    local function snapshot(t, prefix, out)
        out = out or {}
        for k, v in pairs(t) do
            local p = (prefix and prefix .. "." or "") .. tostring(k)
            if type(v) == "table" then snapshot(v, p, out) else out[p] = v end
        end
        return out
    end
    local function changed(before, cfg)
        local after, diff = snapshot(cfg), {}
        for k, v in pairs(after) do if before[k] ~= v then diff[#diff + 1] = k end end
        for k in pairs(before) do if after[k] == nil then diff[#diff + 1] = k end end
        table.sort(diff)
        return table.concat(diff, ",")
    end

    test("config_env: unset or blank changes nothing", function()
        for _, s in ipairs({ false, "", "  ", ";;\n" }) do
            local cfg = fresh()
            local before = snapshot(cfg)
            local _, errs = config_env.apply(cfg, s or nil)
            eq(#errs, 0); eq(changed(before, cfg), "")
        end
    end)
    test("config_env: boolean switch, only that key changes", function()
        local cfg = fresh()
        local before = snapshot(cfg)
        local _, errs = config_env.apply(cfg, "http.metric_latency_hist=false")
        eq(#errs, 0); eq(cfg.http.metric_latency_hist, false)
        eq(changed(before, cfg), "http.metric_latency_hist")
        config_env.apply(cfg, "http.metric_latency_hist=true")
        eq(cfg.http.metric_latency_hist, true)
    end)
    test("config_env: numbers, strings, nested, separators, last wins", function()
        local cfg = fresh()
        local _, errs = config_env.apply(cfg,
            " http.expiry_window = 30 ;stream.expiry_window=45\n" ..
            "http.sanitize.min_len=6\r\nhttp.app=a=b\nintercept.cert_ttl=3600;http.expiry_window=60")
        eq(#errs, 0)
        eq(cfg.http.expiry_window, 60); eq(type(cfg.http.expiry_window), "number")
        eq(cfg.stream.expiry_window, 45); eq(cfg.http.sanitize.min_len, 6)
        eq(cfg.http.app, "a=b"); eq(cfg.intercept.cert_ttl, 3600)
    end)
    test("config_env: unknown key is reported, the rest still applies", function()
        local cfg = fresh()
        local logged = {}
        local _, errs = config_env.apply(cfg,
            "http.metric_latency_histogram=false;http.metric_requests=false",
            function(m) logged[#logged + 1] = m end)
        eq(#errs, 1); eq(#logged, 1)
        assert(logged[1]:find("METRICS_CONFIG", 1, true) and logged[1]:find("http.metric_latency_histogram", 1, true))
        eq(cfg.http.metric_latency_histogram, nil)
        eq(cfg.http.metric_latency_hist, true)
        eq(cfg.http.metric_requests, false)
    end)
    test("config_env: wrong type, tables and malformed entries leave config untouched", function()
        local bad = {
            "http.metric_latency_hist=no", "http.metric_latency_hist=0", "http.metric_latency_hist=",
            "http.expiry_window=abc", "http.expiry_window=", "http.expiry_window=1e999", "http.expiry_window=nan",
            "http.app=", "http.histogram_buckets=1,2", "http.histogram_buckets.1=5", "http.sanitize=false",
            "http=false", "nosuch.key=1", "http.=1", "http..app=x", ".http.app=x", "justtext", "=x",
            "apps.stream.metrics_enabled=false", "apps.stream.redis.metrics_enabled=off",
            "apps.inbound.metrics_enabled=false",
        }
        for _, s in ipairs(bad) do
            local cfg = fresh()
            local before = snapshot(cfg)
            local _, errs = config_env.apply(cfg, s)
            if #errs ~= 1 then error(("%q: expected 1 error, got %d"):format(s, #errs)) end
            if changed(before, cfg) ~= "" then error(("%q changed %s"):format(s, changed(before, cfg))) end
        end
    end)
    test("config_env: per-leg toggles", function()
        local cfg = fresh()
        local _, errs = config_env.apply(cfg,
            "apps.outbound.metrics_enabled=false;apps.stream.redis.metrics_enabled=false;" ..
            "apps.stream.postgres-main.metrics_enabled=false;apps.stream.mysql.metrics_enabled=true")
        eq(#errs, 0)
        eq(app_toggle.enabled(cfg.apps, "outbound"), false)
        eq(app_toggle.enabled(cfg.apps.stream, "redis"), false)
        eq(app_toggle.enabled(cfg.apps.stream, "postgres-main"), false)
        eq(app_toggle.enabled(cfg.apps.stream, "mysql"), true)
        eq(app_toggle.enabled(cfg.apps.stream, "other"), true)
    end)
    test("config_env: new stream destination with a bad value adds no entry", function()
        local cfg = fresh()
        config_env.apply(cfg, "apps.stream.pg.metrics_enabled=nope")
        eq(cfg.apps.stream.pg, nil)
    end)
    test("config_env: load() applies the env var once to metrics_config", function()
        local saved_getenv = os.getenv
        local saved_cfg, saved_env = package.loaded["metrics_config"], package.loaded["config_env"]
        package.loaded["metrics_config"], package.loaded["config_env"] = nil, nil
        local reads = 0
        os.getenv = function(name)
            if name == "METRICS_CONFIG" then reads = reads + 1; return "http.metric_latency_hist=false;bad.key=1" end
            return saved_getenv(name)
        end
        local saved_stderr = io.stderr
        local errout = {}
        io.stderr = { write = function(_, ...) errout[#errout + 1] = table.concat({ ... }) end }
        local ok, err = pcall(function()
            local ce = require("config_env")
            local cfg = ce.load()
            eq(cfg, require("metrics_config"))
            eq(cfg.http.metric_latency_hist, false)
            eq(ce.load(), cfg); eq(reads, 1)
            assert(table.concat(errout):find("bad.key", 1, true))
        end)
        io.stderr = saved_stderr
        os.getenv = saved_getenv
        package.loaded["metrics_config"], package.loaded["config_env"] = saved_cfg, saved_env
        if not ok then error(err, 0) end
    end)
    test("config_env: defaults untouched without the env var", function()
        eq(require("config_env").load().http.metric_latency_hist, true)
    end)
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
