-- intercept.lua
-- Interception switch for the outbound proxy (:3128). With interception on,
-- every CONNECT is classified by the first bytes the client sends once its
-- tunnel is up -- the protocol announces itself, so nothing is configured per
-- port or per host:
--
--   TLS ClientHello (0x16 0x03 ..)      -> :3129, TLS terminator: decrypts
--                                          HTTPS, and gRPC over TLS, on any port
--   HTTP/2 preface ("PRI * HTTP/2.0..") -> :3130, h2c terminator: decodes
--                                          plaintext gRPC
--   anything else                       -> the real target, unchanged
--
-- The classification and the byte relay live in lib/connect_tunnel.lua; this
-- module holds the switch and the pure decisions.
--
-- Switches (declared for workers in /etc/nginx/main.d/intercept-env.conf):
--   INTERCEPT_TLS     "on" to enable; anything else (or unset) = off.
--   INTERCEPT_BYPASS  comma list of hosts to never intercept (mTLS/pinning).
--
-- Off by default: CONNECTs then use nginx's native `tunnel_pass`, exactly as
-- without this module. Values are read once per worker (env is fixed for the
-- process).
--
-- The terminators (docker/optional/intercept.conf) are only loaded when the
-- image entrypoint saw INTERCEPT_TLS=on at container start. If the env var is
-- on but that config isn't loaded (entrypoint bypassed by a `command:`
-- override, or a hand-written nginx.conf), interception stays off and one error
-- is logged. `ssl_mint_cache` is the marker: it is declared only in
-- intercept.conf.

local _M = {}

local conf  -- memoised { enabled=bool, bypass={host=true} }

local function parse_set(csv)
    local out = {}
    if csv then
        for item in csv:gmatch("[^,%s]+") do out[item:lower()] = true end
    end
    return out
end

-- True when intercept.conf is part of the running config. Pure apart from
-- reading ngx.shared, which is fixed once nginx has started.
local function terminator_loaded()
    return ngx ~= nil and ngx.shared ~= nil and ngx.shared.ssl_mint_cache ~= nil
end

local function config()
    if conf then return conf end
    local wanted = (os.getenv("INTERCEPT_TLS") == "on")
    local enabled = wanted and terminator_loaded()
    if wanted and not enabled then
        ngx.log(ngx.ERR, "intercept: INTERCEPT_TLS=on but intercept.conf isn't loaded ",
                "(container started without the image entrypoint?); tunnelling CONNECTs unchanged")
    end
    conf = {
        enabled = enabled,
        bypass  = parse_set(os.getenv("INTERCEPT_BYPASS")),
    }
    return conf
end

-- How :3128 handles this request (default.conf branches on it; the values
-- are exclusive because when several nginx `if`s match, the last one wins):
--   "detect"  a CONNECT relayed by lib/connect_tunnel.lua (interception on,
--             host not bypassed)
--   "tunnel"  a CONNECT relayed by nginx's own `tunnel_pass`
--   "proxy"   not a CONNECT: plain HTTP, proxy_pass
-- Reads only vars that exist for a CONNECT, so it is safe in any phase.
function _M.connect_mode()
    if ngx.var.request_method ~= "CONNECT" then return "proxy" end
    local c = config()
    if not c.enabled then return "tunnel" end
    if c.bypass[(ngx.var.host or ""):lower()] then return "tunnel" end
    return "detect"
end

-- The real CONNECT target, as nginx's bare `tunnel_pass;` would use it.
function _M.upstream()
    return (ngx.var.host or "") .. ":" .. (ngx.var.request_port or "443")
end

local H2_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

-- Classifies the first bytes a client sent into its tunnel:
--   "tls"   a TLS handshake record (ClientHello): content type 0x16, major
--           version 0x03 (SSL 3.0 .. TLS 1.3 all use 3.x on the record layer)
--   "h2c"   the HTTP/2 connection preface (prior knowledge, what gRPC sends)
--   "more"  still a prefix of one of the above: read more bytes first
--   nil     anything else (HTTP/1.x, unknown) -> tunnel unchanged
function _M.classify(data)
    if not data or data == "" then return "more" end
    local b1 = data:byte(1)
    if b1 == 0x16 then
        if #data < 2 then return "more" end
        if data:byte(2) == 0x03 then return "tls" end
        return nil
    end
    local n = math.min(#data, #H2_PREFACE)
    if data:sub(1, n) == H2_PREFACE:sub(1, n) then
        if n == #H2_PREFACE then return "h2c" end
        return "more"
    end
    return nil
end

_M.TERMINATOR = { tls = "127.0.0.1:3129", h2c = "127.0.0.1:3130" }

-- True when lib/connect_tunnel.lua handed this CONNECT to a terminator, which
-- records the decoded call in full; the opaque outer CONNECT is then skipped
-- by http_metrics.record() so each call is counted exactly once.
function _M.should()
    return ngx.ctx ~= nil and ngx.ctx.intercepted == true
end

-- Status label for a gRPC call. gRPC carries its result in the grpc-status
-- trailer (or in the headers, for a trailers-only error); the HTTP status is
-- 200 for every call that reached the server. So: a non-200 HTTP status means
-- nginx or the transport failed and is kept as is; otherwise the gRPC code
-- becomes "grpc_<code>". No code at all (a stream cut before its trailers)
-- keeps the HTTP status.
function _M.grpc_status(http_status, trailer_code, header_code)
    if http_status ~= "200" then return http_status end
    local code = trailer_code
    if code == nil or code == "" then code = header_code end
    if code == nil or code == "" then return http_status end
    return "grpc_" .. code
end

-- True for a gRPC request: content type application/grpc, optionally with a
-- +proto / +json suffix or parameters. gRPC-Web (application/grpc-web...) is
-- plain HTTP/1.1-compatible and stays on proxy_pass.
function _M.is_grpc(content_type)
    if not content_type then return false end
    local ct = content_type:lower()
    return ct == "application/grpc" or ct:find("^application/grpc[+;%s]") ~= nil
end

return _M
