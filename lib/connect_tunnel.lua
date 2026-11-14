-- connect_tunnel.lua
-- CONNECT handling on the outbound proxy (:3128) when interception is on.
-- Replaces nginx's `tunnel_pass` for those CONNECTs so the tunnel's first bytes
-- can pick its destination (lib/intercept.lua classify()):
--
--   TLS           -> 127.0.0.1:3129  (decrypted, recorded, re-originated)
--   HTTP/2 (h2c)  -> 127.0.0.1:3130  (decoded, recorded, re-originated)
--   anything else -> the real CONNECT target, unchanged
--
-- Wired from default.conf as:
--   set_by_lua_block $connect_mode     { return require("intercept").connect_mode() }
--   set_by_lua_block $connect_upstream { return require("intercept").upstream() }
--   if ($connect_mode = detect) { content_by_lua_block { require("connect_tunnel").run() } }
--   if ($connect_mode = tunnel) { tunnel_pass $connect_upstream; }
--
-- No added wait: every protocol this is for (TLS, HTTP/1, HTTP/2) has the
-- client speak first, right after "200 Connection Established", so its first
-- bytes are already there when they are read. The relay itself is a plain
-- copy loop between two cosockets.
--
-- The real target is connected with the server's `resolver`, as tunnel_pass
-- would. Timeouts follow intercept.tunnel_* in metrics_config.lua.

local intercept = require("intercept")

local ok_cfg, config = pcall(function() return require("config_env").load() end)
local ic = (ok_cfg and config and config.intercept) or {}

local CONNECT_TIMEOUT = (tonumber(ic.tunnel_connect_timeout) or 10) * 1000
local IDLE_TIMEOUT    = (tonumber(ic.tunnel_idle_timeout) or 300) * 1000
local CHUNK           = 65536

local _M = {}

local function split_target(t)
    local host, port = t:match("^(.*):(%d+)$")
    return host, tonumber(port)
end

-- Copies src -> dst until either side closes or errors. receiveany() returns
-- as soon as any bytes arrive, so nothing is held back.
local function pipe(src, dst)
    while true do
        local data, err = src:receiveany(CHUNK)
        if not data then return err end
        local ok, serr = dst:send(data)
        if not ok then return serr end
    end
end

-- Status recorded for the outer CONNECT: once the raw socket is taken, nginx
-- considers the response headers sent and $status can't change, so a tunnel
-- that ends badly reports through ngx.ctx (http_metrics.record reads it).
local function fail(status)
    ngx.ctx.tunnel_status = status
end

function _M.run()
    -- Answered before the destination is known, as every forward proxy that
    -- inspects the tunnel must. A destination that turns out unreachable then
    -- closes the tunnel instead of answering 502; the CONNECT metric still
    -- shows 502.
    ngx.status = 200
    local down, err = ngx.req.socket(true)
    if not down then
        ngx.log(ngx.ERR, "connect_tunnel: no raw client socket: ", err)
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    down:settimeouts(CONNECT_TIMEOUT, IDLE_TIMEOUT, IDLE_TIMEOUT)

    local ok, serr = down:send("HTTP/1.1 200 Connection Established\r\n\r\n")
    if not ok then
        fail("499")
        return ngx.log(ngx.INFO, "connect_tunnel: client gone before 200: ", serr)
    end

    -- First bytes: enough to classify (2 for TLS, up to 24 for the h2 preface).
    local first = ""
    local kind = "more"
    while kind == "more" do
        local data = down:receiveany(CHUNK)
        if not data then
            fail("499")
            return  -- client closed or idled out before sending anything
        end
        first = first .. data
        kind = intercept.classify(first)
    end

    local target = kind and intercept.TERMINATOR[kind] or intercept.upstream()
    local host, port = split_target(target)

    local up = ngx.socket.tcp()
    up:settimeouts(CONNECT_TIMEOUT, IDLE_TIMEOUT, IDLE_TIMEOUT)
    local cok, cerr = up:connect(host, port)
    if not cok then
        fail("502")
        ngx.log(ngx.ERR, "connect_tunnel: connect ", target, ": ", cerr)
        return
    end

    -- Decoded by a terminator: that leg records the real call, so this outer
    -- CONNECT is not recorded again (http_metrics.record -> intercept.should).
    if kind then ngx.ctx.intercepted = true end

    local sok = up:send(first)
    if not sok then
        up:close()
        return
    end

    -- Both directions at once; the tunnel ends as soon as either side closes
    -- (or idles out), like tunnel_pass. TLS and HTTP clients don't half-close
    -- a tunnel, so nothing in flight is cut.
    local to_client   = ngx.thread.spawn(pipe, up, down)
    local to_upstream = ngx.thread.spawn(pipe, down, up)
    ngx.thread.wait(to_client, to_upstream)
    ngx.thread.kill(to_client)
    ngx.thread.kill(to_upstream)
    up:close()
end

-- Pure helper, exposed for tests/lib_test.lua.
_M._split_target = split_target

return _M
