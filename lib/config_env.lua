-- config_env.lua
-- Per-deployment overrides of lib/metrics_config.lua's simple values from one
-- environment variable, METRICS_CONFIG, so a Deployment can flip a switch
-- without mounting a full copy of the config file:
--
--   METRICS_CONFIG="http.metric_latency_hist=false;http.expiry_window=30"
--
-- Entries are `path=value`, separated by `;` or newlines; the path is the
-- dotted location in the config table. Applied on top of whichever
-- metrics_config.lua is loaded (the baked one or a mounted copy), so the two
-- combine. The env var always wins.
--
-- Only settings that already exist and hold a boolean, number or string can
-- be set, and the value must parse as that same type ("true"/"false" for a
-- boolean). Tables (histogram buckets, static_ranges, sanitize as a whole,
-- ptr_ignore_services) still need a mounted metrics_config.lua. The one
-- exception is apps.stream.<destination>.metrics_enabled, which may name a
-- destination that has no entry yet, since an entry is how a destination is
-- switched off (lib/app_toggle.lua).
--
-- A bad entry (unknown path, wrong type, malformed) is logged at error level
-- and skipped; the rest still apply. It never stops nginx: this sidecar also
-- carries the app's traffic, so a typo in a metrics setting must not take it
-- down.
--
-- nginx only passes an env var to its workers when it's declared at the main
-- level -- the image does that in docker/main.d/metrics-config-env.conf.
--
-- parse() and apply() are pure (no ngx.*); load() is what the orchestration
-- modules call instead of require("metrics_config").

local _M = {}

local ENV_NAME = "METRICS_CONFIG"
_M.ENV_NAME = ENV_NAME

local function trim(s)
    return (s:match("^%s*(.-)%s*$"))
end

local function split_path(path)
    local segs = {}
    for seg in path:gmatch("[^.]+") do segs[#segs + 1] = seg end
    return segs
end

-- Returns a list of { path = "a.b", segs = {"a","b"}, value = "raw" } and a
-- list of error strings for entries that couldn't be parsed.
function _M.parse(str)
    local entries, errs = {}, {}
    if type(str) ~= "string" then return entries, errs end
    for item in str:gmatch("[^;\r\n]+") do
        item = trim(item)
        if item ~= "" then
            local path, value = item:match("^([^=]*)=(.*)$")
            path = path and trim(path)
            if not path or path == "" then
                errs[#errs + 1] = ("%q: expected path=value"):format(item)
            elseif not path:match("^[%w_%-]+%.[%w_%-%.]+$") or path:find("%.%.") or path:sub(-1) == "." then
                errs[#errs + 1] = ("%q: path must look like section.key, e.g. http.metric_latency_hist"):format(path)
            else
                entries[#entries + 1] = { path = path, segs = split_path(path), value = trim(value) }
            end
        end
    end
    return entries, errs
end

-- apps.stream.<destination>.metrics_enabled: the only path allowed to create
-- its parent table.
local function is_stream_toggle(segs)
    return #segs == 4 and segs[1] == "apps" and segs[2] == "stream" and segs[4] == "metrics_enabled"
end

local function convert(current, raw)
    local t = type(current)
    if t == "boolean" then
        if raw == "true" then return true end
        if raw == "false" then return false end
        return nil, "expects true or false"
    elseif t == "number" then
        local n = tonumber(raw)
        if not n or n ~= n or n == math.huge or n == -math.huge then
            return nil, "expects a number"
        end
        return n
    elseif t == "string" then
        if raw == "" then return nil, "expects a non-empty value" end
        return raw
    end
    return nil, "is a " .. t .. ", which can't be set from " .. ENV_NAME .. "; mount a metrics_config.lua for it"
end

local function apply_one(cfg, e)
    local segs = e.segs
    local node = cfg
    local create
    for i = 1, #segs - 1 do
        local nxt = node[segs[i]]
        if nxt == nil and i == 3 and is_stream_toggle(segs) then
            create = { parent = node, key = segs[i] }
            nxt = {}
        end
        if type(nxt) ~= "table" then
            return "unknown setting"
        end
        node = nxt
    end

    local key = segs[#segs]
    local current = node[key]
    if current == nil then
        if not is_stream_toggle(segs) then return "unknown setting" end
        current = true   -- no entry reads as enabled
    end

    local v, err = convert(current, e.value)
    if v == nil then return err end
    if create then create.parent[create.key] = node end
    node[key] = v
end

-- Applies `str` (the METRICS_CONFIG value) to `cfg` in place. Returns cfg and
-- a list of error strings (one per skipped entry); each is also passed to
-- `log` when given. A nil or blank `str` changes nothing.
function _M.apply(cfg, str, log)
    local entries, errs = _M.parse(str)
    for _, e in ipairs(entries) do
        local err = apply_one(cfg, e)
        if err then errs[#errs + 1] = ("%q: %s"):format(e.path, err) end
    end
    if log then
        for _, err in ipairs(errs) do log(ENV_NAME .. ": skipped " .. err) end
    end
    return cfg, errs
end

local function default_log(msg)
    local n = rawget(_G, "ngx")
    if n and n.log then
        n.log(n.ERR, msg)
    else
        io.stderr:write(msg, "\n")
    end
end

-- The effective config: require("metrics_config") with METRICS_CONFIG applied,
-- once per Lua VM (each nginx worker, and the stream subsystem separately).
local loaded
function _M.load()
    if loaded then return loaded end
    local cfg = require("metrics_config")
    _M.apply(cfg, os.getenv(ENV_NAME), default_log)
    loaded = cfg
    return cfg
end

return _M
