-- >>> options.lua - Interface for managing Neon client/server settings

-- TODO: Global options
-- > A couple ideas come to mind:
-- > - As the option is globally available, let it be accessed by a options.client
-- > or an options.server...should it also be accessable via options.global?
-- > - options.global is the global version, and this will be used by the server
-- > and client unless overridden with options.server/options.client
-- > - options.global merely works like an "abstract class" where options.server
-- > and options.client must still be set individually
-- ~ An exemplar global option would be one that toggles logging output ~

-- Internal option storage and metadata (client-specific)
local _CLIENT = {
	_data = {},
	name = function() return "CLIENT" end,
	opts = {
		-- None currently
	}
}

-- Internal option storage and metadata (server-specific)
local _SERVER = {
	_data = {},
	name = function() return "SERVER" end,
	opts = { -- Metadata table of available settings
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
	}
}

-- Private options API, used as a metatable
local methods = {}
setmetatable(_CLIENT, { __index = methods })
setmetatable(_SERVER, { __index = methods })

-- List the available options (intended for debugging use)
function methods:help()
	print("Available options for " .. self.name())
	for k, v in pairs(self.opts) do
		print("\t" .. k .. "\t  -  " .. v.description)
	end
end

-- Get a value from the args table, throws an error on bad key name
function methods:get(key)
	local option = self.opts[key]
	assert(option, "Unrecognized option for " .. self.name()
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
function methods:set(key, value)
	-- Check if the option is defined
	local option = self.opts[key]
	assert(option, "Unrecognized option for " .. self.name()
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
			.. "` is invalid for the setting " .. self.name() .. "." .. key)
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

-- Public options table, track insertions (proxy table to the internal storage)
local options = {
	server = {},
	client = {},
}

-- Connect server opts access table to internal table
setmetatable(options.server, {
	__index = function(tbl, key) return _SERVER:get(key) end,
	__newindex = function(tbl, key, value) _SERVER:set(key, value) end,
})
-- Connect client opts access table to internal table
setmetatable(options.client, {
	__index = function(tbl, key) return _CLIENT:get(key) end,
	__newindex = function(tbl, key, value) _CLIENT:set(key, value) end,
})
-- Force the proxy table to be read-only
setmetatable(options, {
	__newindex = function() assert(false, "Attempt to modify global options (read-only table)") end
})

return options
