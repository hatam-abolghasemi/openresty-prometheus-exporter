-- caller_identity.lua
-- Builds the caller-attribution resolver (lib/source_attribution.lua) and,
-- when enabled, this pod's own-identity discovery (lib/self_identity.lua) from
-- the `http` table of lib/metrics_config.lua. http_metrics.lua and
-- stream_metrics.lua both call this, each with its own shared dict (the HTTP
-- and stream subsystems can't share one), so the two can't drift apart in how
-- they read the config.
--
-- Usage (inside init_worker_by_lua_block):
--   local resolver, ident = require("caller_identity").build(cfg, ngx.shared.ptr_cache, {
--       on_change = function(old_svc, old_ns, new_svc, new_ns) ... end,  -- optional
--   })
--   -- ident is nil when cfg.discover_identity is off

local source_attribution = require("source_attribution")
local self_identity      = require("self_identity")

local _M = {}

-- cfg  = metrics_config.http
-- dict = shared dict for PTR results
-- opts = { on_change = optional self_identity on_change callback }
-- Returns resolver, ident (ident is nil when cfg.discover_identity is off).
-- Both are started.
function _M.build(cfg, dict, opts)
    opts = opts or {}

    local resolver = source_attribution.new_resolver{
        dict               = dict,
        refresh_interval   = cfg.ptr_refresh_interval or cfg.ptr_cache_ttl,
        forget_after       = cfg.ptr_forget_after,
        sync_timeout_ms    = cfg.ptr_sync_timeout,
        ignore_services    = cfg.ptr_ignore_services,
        dns                = { nameservers = {{ cfg.ptr_dns_server, 53 }}, timeout_ms = cfg.ptr_dns_timeout },
        dynamic_prefix     = cfg.dynamic_prefix,
        static_ranges      = cfg.static_ranges,
        default_label      = cfg.default_label,
        default_namespace  = cfg.default_namespace,
        default_service    = cfg.probe_default_service,
        default_service_namespace = cfg.probe_default_namespace,
    }
    resolver:start()

    local ident
    if cfg.discover_identity then
        ident = self_identity.new{
            resolver           = resolver,
            fallback_service   = cfg.app,
            fallback_namespace = cfg.namespace,
            on_change          = opts.on_change,
        }
        ident:start()
    end

    return resolver, ident
end

return _M
