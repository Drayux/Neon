-- >>> util.lua: Connection utility functions

local osslctx = require("openssl.ssl.context")

-- TODO: Add paramater for client/server differentiation
local function tlscontext()
	local context = osslctx.new("TLS", true)
end

local module = {
	-- Add functions here
}

return module

