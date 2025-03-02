-- >>> refs.lua - Single-instance (static) global state

local cqcore = require("cqueues")

-- Initialize a new args table (settings object)
local _argtable = function()
	-- 
	_ = {

	}
	
	args = {
		server = {},
		client = {},
	}
	return args
end

local module = nil -- Singleton module
local _init = function()
	-- Init should never be called more than once
	assert(module == nil, "Singleton _init() called more than once")

	-- TODO: Consider whether the members should be initialized all at once instead

	-- Create a proxy table to track accesses
	-- > Allows the module to be "read-only/self-initializing"
	local _data = {}
	local _proxy = {}

	setmetatable(_proxy, {
		__newindex = function(tbl, key, value)
				assert(false, "Invalid access to static data (read only)")
			end,

		__index = function(tbl, key)
				local index = nil
				local create = nil
				if key == "settings" then
					index = "_SETTINGS"
					create = _argtable

				elseif key == "controller" then
					index = "_CONTROLLER"
					create = cqcore.new

				elseif key == "server" then
					index = "_SERVEROBJ"


				elseif key == "client" then
					index = "_CLIENTOBJ"
					-- object = <new client object - closure, accepts arguments>
					create = nil
				end

				assert(index ~= nil, "Invalid index for static data:" .. tostring(key))

				local object = _data[index]
				if not object then
					object = create()
					_data[index] = object
				end
				return object
			end,

		__pairs = function(tbl)
			return pairs(_data) end,

		__len = function(tbl)
			return #_data end,
	})

	module = _proxy
	return module
end

return module or _init()
