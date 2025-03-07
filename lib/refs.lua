-- >>> refs.lua - Single-instance (static) global state

local cqcore = require("cqueues")

-- Initialize a new args table (settings object)
local _initopts = function()
	-- Internal argument storage and metadata (server options)
	_SERVER = {
		_name = function() return "SERVER" end,
		_opts = { -- Metadata table of available settings
			-- TODO: Consider making this read-only (it should already be treated as such)
			port = {
				type = "number",
				optional = false,
				default = 1085,
				description = "Specifies a port on which the server component listens",
				validation = function(value)
						return (value > 0 and value < 65535)
					end,
			},
			timeout = {
				type = "number",
				optional = true,
				default = 10,
				description = "Number of seconds to wait before giving up on a connection",
				validation = function(value)
						return (value >= 0)
					end,
			},
			directory = {
				type = "string",
				optional = false,
				default = "overlay",
				description = "Name of the server component's root directory: (i.e. http://server:port/<directory>)",
				-- validation = nil,
			},
			logging = {
				type = "boolean",
				optional = false,
				default = false,
				description = "Output verbose logging information (applies to terminal usage)",
				-- validation = nil,
			},
		},
		_data = {},
	}
	-- Internal argument storage and metadata (client options)
	_CLIENT = {
		_name = function() return "CLIENT" end,
		_opts = {
			-- None currently
		},
		_data = {},
	}

	-- Internal arguments API, used as a metatable
	local _methods = {}
	setmetatable(_SERVER, { __index = _methods })
	setmetatable(_CLIENT, { __index = _methods })

	-- List the available options (intended for debugging use)
	function _methods:help()
		print("Available options for " .. self._name())
		for k, v in pairs(self._opts) do
			print("\t" .. k .. "\t  -  " .. v.description)
		end
	end

	-- Get a value from the args table, throws an error on bad key name
	function _methods:get(key)
		local option = self._opts[key]
		assert(option, "Unrecognized option for " .. self._name()
			.. ": `" .. key .. "`")

		local value = self._data[key] -- Value is a table to track metadata
		if not value then
			-- Argument value has not been initialized yet, do so now
			value = {
				_data = option.default,
				_changed = false,
			}
			self._data[key] = value
		end

		return value._data
	end

	-- Put a value into the table with all the necessary validation checks
	-- > Sets a "changed" flag if the value actually changed
	function _methods:set(key, value)
		-- Check if the option is defined
		local option = self._opts[key]
		assert(option, "Unrecognized option for " .. self._name()
			.. ": `" .. key .. "`")

		-- Validate the provided value
		converted = nil
		if value == nil then
			-- Nil type
			assert(option.optional, "Option `" .. key .. "` cannot be nil")
		elseif option.type == "string" then
			-- Do not implicitly cast string settings; could be misleading
			assert(type(value) == "string", "The value `" .. tostring(value)
				.. "` must be a string")
			converted = value
		elseif option.type == "number" then
			local status
			status, converted = pcall(tonumber, value)
			assert(status, "The value `" .. tostring(value)
				.. "` could not be converted to a number")
		elseif option.type == "boolean" then
			converted = not not value
		else
			assert(false, "Unsupported type `" .. tostring(option.type)
				.. "` for key `" .. key .. "`")
		end

		-- Range check the provided argument, if applicable
		if converted and option.validation then
			assert(option.validation(converted), "The value `" .. tostring(value)
				.. "` is invalid for the setting " .. self._name() .. "." .. key)
		end

		-- Check if the supplied value actually changes anything
		-- NOTE: As the values are each stored as a table, we need only update
		-- > the contents of the table since the reference is shared
		-- > Hence, self:get() performs the necessary "creation" operation
		local current = self:get(key)
		if converted ~= current then
			local valref = self._data[key] -- Get the enclosing table
			valref._data = converted

			-- NOTE: The _changed value is not used elsewhere as of writing this
			-- > It is merely a placeholder for a OBS script interface QOL feature
			valref._changed = true
		end
	end

	-- Arguments access table, tracks insertions
	local settings = {
		server = {},
		client = {},
	}
	-- Connect server opts access table to internal table
	setmetatable(settings.server, {
		__index = function(tbl, key) return _SERVER:get(key) end,
		__newindex = function(tbl, key, value) _SERVER:set(key, value) end,
	})
	-- Connect client opts access table to internal table
	setmetatable(settings.client, {
		__index = function(tbl, key) return _CLIENT:get(key) end,
		__newindex = function(tbl, key, value) _CLIENT:set(key, value) end,
	})
	-- Force the proxy table to be read-only
	setmetatable(settings, {
		__newindex = function() assert(false, "Attempt to modify read-only table (refs.settings)") end
	})
	
	return settings
end

local module = nil -- Singleton module
local _initrefs = function()
	-- Init should never be called more than once
	assert(module == nil, "Function _initrefs() called more than once")

	-- TODO: Consider whether the members should be initialized all at once instead
	-- Likely answer: Add a system where objects can be recreated, by means of passing
	-- > through the existing one. Whatever is returned will be set into _data, which
	-- > could be a new object, or it could be the original with a "cleaned" state

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
					create = _initopts

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

return module or _initrefs()
