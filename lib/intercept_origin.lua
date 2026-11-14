-- intercept_origin.lua
-- Re-origination for the interception servers in docker/optional/intercept.conf
-- -- TLS on 127.0.0.1:3129 and plaintext gRPC on 127.0.0.1:3130: sends each
-- decoded request on to its real destination over a pooled connection
-- (verified TLS for :3129) instead of a fresh one.
--
-- Without it, :3129 used `proxy_pass https://$host...`, which keeps no pool:
-- every intercepted request paid a TCP + TLS handshake to the destination
-- (two extra round trips), even when the app itself reuses its connection.
--
-- Wired from intercept.conf as:
--   upstream intercept_origin {
--       server 0.0.0.1;
--       balancer_by_lua_block { require("intercept_origin").balance() }
--       balancer_keepalive 256;
--   }
--   access_by_lua_block { ...; require("intercept_origin").resolve() }
--   proxy_pass https://intercept_origin$request_uri;
--
-- resolve() (access phase, may yield for DNS) picks the destination from the
-- Host header -- host and port, so a non-443 intercepted port is re-originated
-- on its own port -- and resolves it. balance() hands that peer to nginx with
-- the hostname as the keepalive pool key and the TLS SNI, so a connection
-- opened and verified for one host is only ever reused for that same host.
-- Verification itself is unchanged: proxy_ssl_verify still checks every new
-- connection against the trust store.

local resolver = require("resty.dns.resolver")
local balancer = require("ngx.balancer")
local lrucache = require("resty.lrucache")

local ok_cfg, config = pcall(function() return require("config_env").load() end)
local ic = (ok_cfg and config and config.intercept) or {}

local DNS_SERVER        = ic.dns_server or "127.0.0.1"
local DNS_TIMEOUT       = tonumber(ic.dns_timeout) or 2000
local DNS_CACHE_TTL     = tonumber(ic.dns_cache_ttl) or 10
local POOL_IDLE_TIMEOUT = tonumber(ic.pool_idle_timeout) or 60
local POOL_MAX_REQUESTS = tonumber(ic.pool_max_requests) or 10000

local _M = {}

-- Per-worker: host -> IPv4. Fixed lifetime, like nginx's `resolver valid=10s`
-- that the previous config used.
local dns_cache = lrucache.new(1000)

-- The pod's search domains, read once from /etc/resolv.conf.
-- resty.dns.resolver queries names verbatim, but apps (gRPC targets above
-- all) often use short Service names like `orders-grpc.orders` that only
-- resolve through the search list, as they would for the app's own libc.
local function read_search(content)
    local search = {}
    for line in (content or ""):gmatch("[^\r\n]+") do
        local list = line:match("^%s*search%s+(.+)$") or line:match("^%s*domain%s+(%S+)")
        if list then
            search = {}
            for d in list:gmatch("%S+") do search[#search + 1] = d end
        end
    end
    return search
end

-- Names to try for `host`, in order: the name as given first, then with each
-- search domain. Unlike glibc's ndots rule (search domains first for names
-- with fewer than ndots dots, 5 in Kubernetes), a full external name like
-- api.example.com costs one query, not three NXDOMAINs before it; a short
-- Service name costs one NXDOMAIN before its search-domain match. A trailing
-- dot or an IP means exactly that name.
local function candidates(host, search)
    if host:match("^%d+%.%d+%.%d+%.%d+$") then return { host } end
    if host:sub(-1) == "." then return { host:sub(1, -2) } end
    local out = { host }
    for _, d in ipairs(search) do out[#out + 1] = host .. "." .. d end
    return out
end

local SEARCH
do
    local f = io.open("/etc/resolv.conf", "r")
    local content = f and f:read("*a")
    if f then f:close() end
    SEARCH = read_search(content)
end

local function split_host_port(hh, default_port)
    local host, port = hh:match("^([^:]+):(%d+)$")
    if not host then host = hh end
    return host:lower(), tonumber(port) or default_port
end

local function lookup(host)
    if host:match("^%d+%.%d+%.%d+%.%d+$") then return host end

    local ip = dns_cache:get(host)
    if ip then return ip end

    local r, err = resolver:new{
        nameservers = { { DNS_SERVER, 53 } },
        timeout     = DNS_TIMEOUT,
        retrans     = 2,
    }
    if not r then return nil, "resolver: " .. tostring(err) end

    -- Walk the search-list candidates; a name that doesn't exist (or has no
    -- A record) moves on to the next, a transport error stops the walk.
    local last_err = "no A record"
    for _, name in ipairs(candidates(host, SEARCH)) do
        local answers, qerr = r:query(name, { qtype = r.TYPE_A })
        if not answers then return nil, "query " .. name .. ": " .. tostring(qerr) end
        if answers.errcode then
            last_err = "query " .. name .. ": " .. tostring(answers.errcode) .. " " .. tostring(answers.errstr)
        else
            for _, ans in ipairs(answers) do
                if ans.type == r.TYPE_A and ans.address then
                    dns_cache:set(host, ans.address, DNS_CACHE_TTL)
                    return ans.address
                end
            end
        end
    end
    return nil, last_err
end

-- Access phase: pick and resolve the destination, stash it for balance().
-- default_port applies when the Host header (gRPC: :authority) has no port:
-- 443 for https (the default), 80 for plaintext gRPC.
function _M.resolve(default_port)
    local hh = ngx.var.http_host
    if not hh or hh == "" then
        ngx.log(ngx.ERR, "intercept_origin: request without Host header")
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    local host, port = split_host_port(hh, default_port or 443)

    local ip, err = lookup(host)
    if not ip then
        ngx.log(ngx.ERR, "intercept_origin: cannot resolve ", host, ": ", err)
        return ngx.exit(ngx.HTTP_BAD_GATEWAY)
    end
    ngx.ctx.intercept_origin = { ip = ip, port = port, host = host }
end

-- Balancer phase: the resolved peer, pooled per host.
function _M.balance()
    local o = ngx.ctx.intercept_origin
    if not o then
        ngx.log(ngx.ERR, "intercept_origin: no destination resolved for this request")
        return ngx.exit(ngx.HTTP_BAD_GATEWAY)
    end

    -- One retry, as nginx's own upstream keepalive gets: a pooled connection
    -- the destination closed while idle fails on reuse. nginx still never
    -- retries a non-idempotent request that was already sent.
    if not balancer.get_last_failure() then
        balancer.set_more_tries(1)
    end

    local ok, err = balancer.set_current_peer(o.ip, o.port, o.host)
    if not ok then
        ngx.log(ngx.ERR, "intercept_origin: set peer ", o.host, ": ", err)
        return ngx.exit(ngx.HTTP_BAD_GATEWAY)
    end
    balancer.enable_keepalive(POOL_IDLE_TIMEOUT, POOL_MAX_REQUESTS)
end

-- Pure helpers, exposed for tests/lib_test.lua.
_M._read_search      = read_search
_M._candidates       = candidates

return _M
