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

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
