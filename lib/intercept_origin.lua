-- intercept_origin.lua
-- Re-origination for the https interception server (127.0.0.1:3129 in
-- docker/conf.d/intercept.conf): sends each decrypted request on to its real
-- destination over a pooled, verified TLS connection instead of a fresh one.
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

local ok_cfg, config = pcall(require, "metrics_config")
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

local function split_host_port(hh)
    local host, port = hh:match("^([^:]+):(%d+)$")
    if not host then host = hh end
    return host:lower(), tonumber(port) or 443
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

    local answers, qerr = r:query(host, { qtype = r.TYPE_A })
    if not answers then return nil, "query: " .. tostring(qerr) end
    if answers.errcode then
        return nil, "query: " .. tostring(answers.errcode) .. " " .. tostring(answers.errstr)
    end
    for _, ans in ipairs(answers) do
        if ans.type == r.TYPE_A and ans.address then
            dns_cache:set(host, ans.address, DNS_CACHE_TTL)
            return ans.address
        end
    end
    return nil, "no A record"
end

-- Access phase: pick and resolve the destination, stash it for balance().
function _M.resolve()
    local hh = ngx.var.http_host
    if not hh or hh == "" then
        ngx.log(ngx.ERR, "intercept_origin: request without Host header")
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    local host, port = split_host_port(hh)

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

return _M
