-- app_peer.lua
-- Balancer for the inbound leg's `upstream app` (docker/conf.d/default.conf):
-- points every request at the app container on 127.0.0.1:$APP_PORT.
--
-- APP_PORT is read once per worker at module load (env is fixed for the
-- process) instead of an os.getenv() + tonumber() on every request.
-- Wired as:
--   balancer_by_lua_block { require("app_peer").balance() }

local balancer = require("ngx.balancer")

local PORT = tonumber(os.getenv("APP_PORT")) or 8080

local _M = {}

function _M.balance()
    local ok, err = balancer.set_current_peer("127.0.0.1", PORT)
    if not ok then
        ngx.log(ngx.ERR, "failed to set app peer: ", err)
        return ngx.exit(502)
    end
end

return _M
