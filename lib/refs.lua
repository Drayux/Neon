-- >>> refs.lua - Single-instance (static) global state

local module = nil -- Singleton module

local _init = function()
	-- Create a proxy table to track accesses
	-- > Allows the module to be "read-only/self-initializing"
	local _data = {}
	local _proxy = {}

	setmetatable(proxy, {
		__newindex = function(tbl, key, value)
				assert(false, "Invalid access to static data (read only)")
			end,

		__index = function(tbl, key)
				local index = nil
				local object = nil
				if key == "controller" then
					index = "_CONTROLLER"
					-- object = <new cqueues controller>

				elseif key == "server" then
					index = "_SERVEROBJ"
					-- object = <new server object - closure, accepts arguments>

				elseif key == "client" then
					index = "_CLIENTOBJ"
					-- object = <new client olbject - closure, accepts arguments>
				end

				assert(index ~= nil, "Invalid index for static data:" .. tostring(key))

				_data[index] = object
				return object
			end,

		__pairs = function(tbl)
			return pairs(data) end,

		__len = function(tbl)
			return #data end,
	})
end

return module or _init()
