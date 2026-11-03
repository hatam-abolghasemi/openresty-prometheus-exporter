-- connection_slots.lua
-- Works out this nginx's connection-slot limit: worker_connections x the
-- number of workers. That is the ceiling nginx's own "worker_connections are
-- not enough" error is about, and what the dashboard compares slots in use
-- (accepted client connections + the upstream leg of in-flight requests)
-- against. http_metrics exports it as nginx_connection_slots_limit.
--
-- nginx exposes the worker count to Lua (ngx.worker.count()) but not
-- worker_connections, so that comes from, in order:
--   1. cfg.worker_connections, when > 0 (set it in metrics_config.lua or
--      METRICS_CONFIG="http.worker_connections=8192")
--   2. the `worker_connections N;` directive in cfg.nginx_conf_path
--      (default /etc/nginx/nginx.conf, the image's main config), read once
--      per worker at init
--   3. nothing: the limit is unknown and the metric is not exported, so the
--      dashboard shows "No data" rather than a made-up number
--
-- A directive inside an `include`d file isn't followed; set
-- cfg.worker_connections in that case.
--
-- parse_worker_connections() and limit() are pure; the file reader and the
-- worker count are injected so they're testable without nginx.

local _M = {}

-- Returns the first `worker_connections N;` value in an nginx config, or nil.
-- Comments are ignored. Pure.
function _M.parse_worker_connections(content)
    if type(content) ~= "string" then return nil end
    for raw in content:gmatch("[^\r\n]+") do
        local line = raw:gsub("#.*$", "")
        local n = line:match("^%s*worker_connections%s+(%d+)%s*;")
        if n then return tonumber(n) end
    end
    return nil
end

local function default_read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- Returns limit, source ("config" | "nginx.conf") or nil, reason. Pure given
-- its injected dependencies:
--   cfg          the http config table (worker_connections, nginx_conf_path)
--   worker_count number of nginx workers (ngx.worker.count())
--   read_file    optional, function(path) -> content or nil
function _M.limit(cfg, worker_count, read_file)
    worker_count = tonumber(worker_count)
    if not worker_count or worker_count < 1 then
        return nil, "unknown worker count"
    end

    local wc = tonumber(cfg.worker_connections)
    if wc and wc > 0 then
        return wc * worker_count, "config"
    end

    local path = cfg.nginx_conf_path
    if type(path) ~= "string" or path == "" then
        return nil, "worker_connections not set and no nginx_conf_path"
    end
    local content = (read_file or default_read_file)(path)
    if not content then
        return nil, "cannot read " .. path
    end
    wc = _M.parse_worker_connections(content)
    if not wc or wc < 1 then
        return nil, "no worker_connections directive in " .. path
    end
    return wc * worker_count, "nginx.conf"
end

return _M
