-- source_attribution.lua
-- Identifies the calling service/namespace behind an inbound request, so
-- "who is calling this" is a queryable Prometheus label instead of
-- something you cross-reference from access logs by hand.
--
-- Resolution order:
--   1. classify_static() -- cheap, no-DNS classification for known static
--      ranges (e.g. a fixed internal VLAN), and a fast "public" bucket for
--      anything clearly external.
--   2. For addresses in a configured dynamic range (e.g. a Kubernetes pod
--      CIDR, too fast-churning for a static table), a reverse-DNS (PTR)
--      lookup against your cluster DNS, cached in a shared dict. A cached
--      answer is kept until a new answer replaces it; a background timer
--      re-resolves every known IP each refresh_interval, so a reassigned
--      IP is relabelled within one interval. A never-seen IP is resolved
--      inline (sync_timeout_ms) or, failing that, in the background.
--   3. apply_waypoint_override() -- if the resolved caller turns out to BE
--      a known service-mesh waypoint, recovers the real original caller's
--      identity from a verified X-Forwarded-Client-Cert (XFCC) header
--      instead of attributing the request to the waypoint itself.
--
-- classify_static, parse_ptr, and parse_xfcc are pure functions with no
-- ngx.* dependency and are fully unit-tested. The stateful Resolver (DNS
-- query, shared-dict caching, in-flight locking) takes its shared dict and
-- DNS resolver library as injectable dependencies specifically so it can
-- be exercised in tests with fakes, without needing a real nginx worker
-- or real DNS traffic.
--
-- Usage (inside init_worker_by_lua_block):
--   local source_attribution = require("source_attribution")
--   local resolver = source_attribution.new_resolver{
--     dict = ngx.shared.ptr_cache,
--     refresh_interval = 15,
--     sync_timeout_ms = 100,
--     dns = { nameservers = {{"10.233.0.3", 53}}, timeout_ms = 200 },
--     static_ranges = {
--       { prefix = {192, 168}, label = "internal", zone_map = {[10] = "zone_a"} },
--     },
--     dynamic_prefix = {10, 233},
--     default_service = "unknown-caller",
--     default_namespace = "unknown",
--   }
--   resolver:start()
--
-- ...and per-request (e.g. in access_by_lua_block):
--   local service, namespace = resolver:resolve(ngx.var.remote_addr)
--   service, namespace = source_attribution.apply_waypoint_override(
--     service, namespace, ngx.var.http_x_forwarded_client_cert, "waypoint")

local _M = {}

-- ---------------------------------------------------------------------
-- Pure functions
-- ---------------------------------------------------------------------

-- Classifies an IPv4 address using only static configuration -- no DNS.
-- Returns service, namespace when a static classification applies.
-- Returns nil when the address falls in `cfg.dynamic_prefix` and should be
-- resolved via PTR instead (see Resolver:resolve below).
--
-- cfg = {
--   dynamic_prefix = {a, b},      -- e.g. {10, 233}: defer these to PTR
--   static_ranges = {             -- checked in order, first match wins
--     { prefix = {a, b}, label = "internal", zone_map = {[c] = "zone_name"}, default_zone = "unknown" },
--   },
--   default_label = "public",
--   default_namespace = "unknown",
-- }
function _M.classify_static(ip, cfg)
  cfg = cfg or {}
  local a, b, c = ip:match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
  if not a then
    return cfg.default_label or "public", cfg.default_namespace or "unknown"
  end
  a, b, c = tonumber(a), tonumber(b), tonumber(c)

  if cfg.dynamic_prefix and a == cfg.dynamic_prefix[1] and b == cfg.dynamic_prefix[2] then
    return nil -- caller should resolve this one via PTR
  end

  for _, range in ipairs(cfg.static_ranges or {}) do
    if a == range.prefix[1] and b == range.prefix[2] then
      local zone = (range.zone_map and range.zone_map[c]) or range.default_zone or "unknown"
      return range.label, zone
    end
  end

  return cfg.default_label or "public", cfg.default_namespace or "unknown"
end

-- Parses a PTR record's target name into service, namespace.
-- Recognizes two Kubernetes cluster-DNS shapes:
--   <pod>.<service>.<namespace>.svc.cluster.local.  -> service, namespace
--   <pod>.<namespace>.pod.cluster.local.             -> nil, namespace
-- Returns nil, nil if the name matches neither shape.
function _M.parse_ptr(ptrdname)
  if not ptrdname then return nil, nil end
  local svc, ns = ptrdname:match("^[%d%-]+%.([^%.]+)%.([^%.]+)%.svc%.cluster%.local%.?$")
  if svc then return svc, ns end
  local pod_ns = ptrdname:match("^[%d%-]+%.([^%.]+)%.pod%.cluster%.local%.?$")
  if pod_ns then return nil, pod_ns end
  return nil, nil
end

-- Parses the SPIFFE URI out of an X-Forwarded-Client-Cert header value.
-- Returns namespace, service_account, or nil, nil if not present/malformed.
-- Expected shape: URI=spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
function _M.parse_xfcc(header)
  if not header then return nil, nil end
  local ns, sa = header:match("URI=spiffe://[^/]+/ns/([^/]+)/sa/([^;,]+)")
  return ns, sa
end

-- If `service` is the known mesh waypoint, recovers the real caller's
-- identity from the XFCC header instead. Otherwise returns service,
-- namespace unchanged.
--
-- Security note: only call this after `service` has already been derived
-- from an independently verified source (e.g. Resolver:resolve, which is
-- PTR-based). Trusting an XFCC header without first confirming the direct
-- peer really is the waypoint would let any caller spoof their reported
-- identity by setting that header themselves.
function _M.apply_waypoint_override(service, namespace, xfcc_header, waypoint_service_name)
  if service ~= waypoint_service_name then
    return service, namespace
  end
  local ns, sa = _M.parse_xfcc(xfcc_header)
  if ns and sa then
    return sa, ns
  end
  return service, namespace
end

-- Picks one Service out of a PTR answer set. A pod behind several Services
-- gets one PTR record per Service, in no guaranteed order, so taking the
-- first answer would flip the label between them. Names matching any of
-- `ignore` (Lua patterns, e.g. "%-metrics$") are skipped unless nothing else
-- is left; ties are broken alphabetically.
-- Returns service, namespace; service is nil when only the pod shape
-- (<ip>.<ns>.pod.cluster.local) was present; nil, nil when nothing parsed.
function _M.pick_ptr(answers, ignore)
  local kept, ignored, pod_ns = {}, {}, nil
  for _, ans in ipairs(answers or {}) do
    local svc, ns = _M.parse_ptr(ans.ptrdname)
    if svc then
      local skip = false
      for _, pat in ipairs(ignore or {}) do
        if svc:match(pat) then skip = true; break end
      end
      table.insert(skip and ignored or kept, { svc, ns })
    elseif ns and not pod_ns then
      pod_ns = ns
    end
  end
  local pool = #kept > 0 and kept or ignored
  if #pool == 0 then return nil, pod_ns end
  table.sort(pool, function(x, y)
    if x[1] ~= y[1] then return x[1] < y[1] end
    return x[2] < y[2]
  end)
  return pool[1][1], pool[1][2]
end

-- ---------------------------------------------------------------------
-- Stateful resolver (DNS + cache). Dependencies are injectable for testing.
--
-- Cache semantics: an answer is kept until a NEW answer replaces it -- time
-- alone never drops it back to the defaults. A background refresher
-- (start(), one worker) re-resolves every known IP every refresh_interval
-- seconds, so when Kubernetes hands an IP to a different pod the label
-- follows within one interval. Set refresh_interval <= the Prometheus scrape
-- interval and at most one scrape carries the old name.
--
-- Each lookup ends in one of three outcomes:
--   found  -- PTR named a Service          -> store it
--   none   -- NXDOMAIN / no usable record   -> store the defaults (a real
--             "unknown": nothing in the cluster owns this IP right now)
--   error  -- timeout, SERVFAIL, no socket  -> keep whatever is stored
-- IPs no request has come from for forget_after seconds are dropped.
-- ---------------------------------------------------------------------

local Resolver = {}
Resolver.__index = Resolver

local INFLIGHT = "inflight:"
local TOUCH_EVERY = 60

-- opts = {
--   dict             = <shared dict for PTR results>,
--   refresh_interval = seconds between background re-resolutions of every
--                      known IP (default 15; `cache_ttl` is accepted as an
--                      alias for older configs),
--   forget_after     = seconds without a request before an IP is dropped
--                      (default 300),
--   sync_timeout_ms  = when set, an IP never seen before is resolved inline
--                      (access/preread phase) with this timeout instead of
--                      being labelled with the defaults; off when nil,
--   ignore_services  = Lua patterns of Service names to pass over when an IP
--                      has several PTR records (see pick_ptr),
--   scan_limit       = max keys read per refresh (default 10000),
--   dns              = { nameservers = {{ip, port}}, timeout_ms, retrans },
--   static_ranges / dynamic_prefix / default_label / default_namespace
--                    = passed through to classify_static,
--   default_service  = label for IPs nothing resolves,
--   resolver_lib     = resty.dns.resolver or a test double,
--   spawn            = function(delay, fn) -> ok; default ngx.timer.at,
--   every            = function(interval, fn) -> ok; default ngx.timer.every,
--   now              = function() -> seconds; default ngx.now,
--   can_block        = function() -> bool; default: phase allows cosockets,
--   is_leader        = function() -> bool; default: worker 0 runs refreshes,
-- }
function _M.new_resolver(opts)
  assert(opts and opts.dict, "source_attribution.new_resolver requires opts.dict")
  local self = setmetatable({}, Resolver)
  self.dict = opts.dict
  self.refresh_interval = opts.refresh_interval or opts.cache_ttl or 15
  self.forget_after = opts.forget_after or 300
  self.sync_timeout_ms = opts.sync_timeout_ms
  self.ignore_services = opts.ignore_services or {}
  self.scan_limit = opts.scan_limit or 10000
  self.dns = opts.dns or {}
  self.static_cfg = {
    dynamic_prefix    = opts.dynamic_prefix,
    static_ranges     = opts.static_ranges,
    default_label     = opts.default_label,
    default_namespace = opts.default_namespace,
  }
  self.default_service = opts.default_service or "unknown-caller"
  self.default_namespace = opts.default_namespace or "unknown"
  self.resolver_lib = opts.resolver_lib
  self.spawn = opts.spawn or function(delay, fn) return ngx.timer.at(delay, fn) end
  self.every = opts.every or function(interval, fn) return ngx.timer.every(interval, fn) end
  self.now = opts.now or function() return ngx.now() end
  self.can_block = opts.can_block or function()
    local phase = ngx.get_phase()
    return phase == "access" or phase == "preread" or phase == "rewrite" or phase == "content"
  end
  self.is_leader = opts.is_leader or function() return ngx.worker.id() == 0 end
  return self
end

local function ptr_query_name(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return d .. "." .. c .. "." .. b .. "." .. a .. ".in-addr.arpa"
end

local function decode(v)
  local svc, ns, seen = v:match("^([^|]*)|([^|]*)|([%d%.]+)$")
  if not svc then return nil end
  return svc, ns, tonumber(seen)
end

-- One PTR query. Returns "found", svc, ns | "none" | "error".
function Resolver:lookup(ip, timeout_ms)
  local query_name = ptr_query_name(ip)
  if not query_name then return "none" end
  local resolver_lib = self.resolver_lib or require("resty.dns.resolver")
  local r = resolver_lib:new{
    nameservers = self.dns.nameservers,
    retrans     = self.dns.retrans or 1,
    timeout     = timeout_ms or self.dns.timeout_ms or 200,
  }
  if not r then return "error" end
  -- :query() returns (answers, err); answers.errcode is set for DNS-level
  -- failures (3 = NXDOMAIN, anything else e.g. 2 = SERVFAIL is transient)
  local ok, answers = pcall(r.query, r, query_name, { qtype = resolver_lib.TYPE_PTR })
  if not ok or not answers then return "error" end
  if answers.errcode then
    return answers.errcode == 3 and "none" or "error"
  end
  local svc, ns = _M.pick_ptr(answers, self.ignore_services)
  if svc or ns then
    return "found", svc or self.default_service, ns or self.default_namespace
  end
  return "none"
end

function Resolver:store(ip, svc, ns, seen)
  local now = self.now()
  local ttl = math.max(1, self.forget_after - (now - seen))
  self.dict:set(ip, svc .. "|" .. ns .. "|" .. seen, ttl)
end

-- Applies a lookup outcome for `ip`; returns the service/namespace now stored
-- (or nil when an error left nothing stored).
function Resolver:apply(ip, outcome, svc, ns, seen)
  if outcome == "found" then
    self:store(ip, svc, ns, seen)
    return svc, ns
  elseif outcome == "none" then
    self:store(ip, self.default_service, self.default_namespace, seen)
    return self.default_service, self.default_namespace
  end
  return nil
end

-- Resolves an IP to service, namespace. A known IP is answered from the
-- cache, never touching DNS. An unknown IP is resolved inline when
-- sync_timeout_ms is set and the phase allows it; otherwise (or if that
-- lookup errors) it gets the defaults and a background lookup is queued.
function Resolver:resolve(ip)
  if not ip then
    return self.default_service, self.default_namespace
  end

  local static_svc, static_ns = _M.classify_static(ip, self.static_cfg)
  if static_svc then
    return static_svc, static_ns
  end

  local cached = self.dict:get(ip)
  if cached then
    local svc, ns, seen = decode(cached)
    if svc then
      if self.now() - seen >= TOUCH_EVERY then
        self:store(ip, svc, ns, self.now())
      end
      return svc, ns
    end
  end

  local inflight_key = INFLIGHT .. ip
  -- add() is atomic across workers: only the first miss looks the IP up. The
  -- lock is released on an answer and left to expire on an error, which
  -- caps retries for an unanswerable IP at one per lock TTL.
  local lock_ttl = (self.dns.timeout_ms or 200) / 1000 + 1
  if not self.dict:add(inflight_key, true, lock_ttl) then
    return self.default_service, self.default_namespace
  end

  if self.sync_timeout_ms and self.can_block() then
    local outcome, svc, ns = self:lookup(ip, self.sync_timeout_ms)
    local got_svc, got_ns = self:apply(ip, outcome, svc, ns, self.now())
    if got_svc then
      self.dict:delete(inflight_key)
      return got_svc, got_ns
    end
  end

  local ok = self.spawn(0, function(premature)
    if premature then return end
    local outcome, svc, ns = self:lookup(ip)
    if self:apply(ip, outcome, svc, ns, self.now()) then
      self.dict:delete(inflight_key)
    end
  end)
  if not ok then
    self.dict:delete(inflight_key)
  end

  return self.default_service, self.default_namespace
end

-- Re-resolves every known IP once. Stops early if a pass outlives one
-- interval (DNS down), so passes never pile up. Returns the number of IPs
-- whose stored answer changed.
function Resolver:refresh_all()
  local started = self.now()
  local changed = 0
  for _, key in ipairs(self.dict:get_keys(self.scan_limit)) do
    if self.now() - started >= self.refresh_interval then break end
    if key:sub(1, #INFLIGHT) ~= INFLIGHT then
      local cached = self.dict:get(key)
      local old_svc, old_ns, seen
      if cached then old_svc, old_ns, seen = decode(cached) end
      if old_svc then
        if self.now() - seen >= self.forget_after then
          self.dict:delete(key)
        else
          local outcome, svc, ns = self:lookup(key)
          local new_svc, new_ns = self:apply(key, outcome, svc, ns, seen)
          if new_svc and (new_svc ~= old_svc or new_ns ~= old_ns) then
            changed = changed + 1
          end
        end
      end
    end
  end
  return changed
end

-- Starts the background refresher on one worker. Call from init_worker.
function Resolver:start()
  if not self.is_leader() then return true end
  local running = false
  return self.every(self.refresh_interval, function(premature)
    if premature or running then return end
    running = true
    local ok, err = pcall(self.refresh_all, self)
    running = false
    if not ok then ngx.log(ngx.ERR, "source_attribution: refresh failed: ", err) end
  end)
end

-- PTR-only lookup: no static classification, no shared-dict cache or
-- in-flight lock. Returns service, namespace when the PTR record names a
-- Service (<pod>.<service>.<namespace>.svc.cluster.local.), otherwise nil --
-- i.e. it never substitutes defaults, so a caller can tell "resolved" from
-- "didn't resolve". Used by self_identity.lua to discover this pod's own
-- Service; the per-request path stays on Resolver:resolve above.
function Resolver:resolve_ptr(ip)
  local query_name = ip and ptr_query_name(ip)
  if not query_name then return nil end

  local resolver_lib = self.resolver_lib or require("resty.dns.resolver")
  local r = resolver_lib:new{
    nameservers = self.dns.nameservers,
    retrans     = self.dns.retrans or 1,
    timeout     = self.dns.timeout_ms or 200,
  }
  if not r then return nil end

  local pcall_ok, answers = pcall(r.query, r, query_name, { qtype = resolver_lib.TYPE_PTR })
  if not pcall_ok or not answers or answers.errcode then return nil end

  local svc, ns = _M.pick_ptr(answers, self.ignore_services)
  if svc and ns then return svc, ns end
  return nil
end

return _M
