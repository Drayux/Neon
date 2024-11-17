-- >>> headers.lua: Encoding/Decoding utilties for HTTP headers

local api = {}
local function _new()
	-- TODO: Ensure that there is no risk of arbitrary code execution here!!!
	local data = {}
	local proxy = {}
	setmetatable(proxy, {
		__index = function(tbl, key)
			-- if not key then return nil end
			local index = key:lower()
			return data[index] end,

		__newindex = function(tbl, key, value)
			-- TODO: Consider making this an assertion instead
			if not key or (type(key) ~= "string") then return end
			if (#key == 0) then return end

			local index = key:lower()
			data[index] = value end,

		__pairs = function(tbl)
			return pairs(data) end,

		__len = function(tbl)
			return #data end,
	})

	local obj = { _data = proxy }
	setmetatable(obj, { __index = api })

	return obj
end


-- >> UTILITY FUNCTIONS <<
function split()
	-- TODO
end

-- Splits and validates the fields of a header
-- TODO: Refers to the header table for specific header rules
-- Returns a boolean if header is valid
-- local function _parseHeader(headers, field, content)
-- 	if not field then return false end
--
-- 	-- Bad request if a header has a space before the colon
-- 	if field:match("%s$") then return false
-- 	else field = field:lower() end
--
-- 	local valid = false
-- 	local data = headers[field]
-- 	local rule = _headers[field] or function(d, c)
-- 		-- "Default" operation is to assume a list of comma and/or space-seperated entries
-- 		local _data = d or {}
--
-- 		-- No change does not invalidate header
-- 		if not c then return true, d end
--
-- 		-- TODO: Better default; perhaps specify delimiter (comma, semicolon, etc) and/or datatype
-- 		for directive in (c .. "\n"):gmatch("([^%s]-)[,;%s]+") do
-- 			-- TODO: Ensure duplicates are not being added
-- 			table.insert(_data, directive)
-- 		end
-- 		return true, _data
-- 	end
--
-- 	valid, data = rule(data, content)
-- 	headers[field] = data
--
-- 	return valid
-- end


-- >> PARSING FUNCTIONS <<
-- These functions are called during table creation to return a paramaterized closure

-- Single numerical value
--- rangeMin: Smallest allowable value (inclusive)
--- rangeMax: Largest allowable value (inclusive)
--- default: On invalid value, use this value instead of failing
local function _numParser(rangeMin, rangeMax, default)
	-- Paramter validation
	assert(not rangeMin or (type(rangeMin) == "number"))
	assert(not rangeMax or (type(rangeMax) == "number"))
	assert(not default or (type(default) == "number"))

	return function(_data)
		local _, val = pcall(tonumber, _data)
		
		if not val then
			-- Short circuit - val already nil
			-- (NOTE: not 0 returns false)
		elseif rangeMin and (val < rangeMin) then
			val = nil
		elseif rangeMax and (val > rangeMax) then
			val = nil
		end

		-- Fallback to default if necessary
		val = val or default
		
		-- Convert the number to a string, or return nil
		return val and tostring(val)
	end
end

-- Single string value
--- default: On an empty string, use this value instead
local function _strParser(default)
	return function(_data)
		local val = _data
		if val then
			if type(val) ~= "string" then
				val = tostring(val)
			end

			if #val == 0 then
				val = nil
			end
		end

		return val or default
	end
end

-- List of values
--- delimiter: String to determine the next element (lua match)
--- validation: Closure to transform the parsed value
local function _listParser(delimiter, validation)
	assert(not validation or (type(validation) == "function"))
	if (type(delimiter) ~= "string")
		or (#delimiter == 0)

	-- Default to commas, semicolons, or whitespace
	then delimiter = ",;%s" end

	return function(_data)
		if not _data then
			return nil
		end

		-- Ensure that _data is a string
		-- TODO: Consider using an assert here
		-- TODO: Handle case when _data is already a table
		if type(_data) ~= "string" then
			_data = tostring(_data)
		end

		local list = {}

		-- Match a sequence of characters as short as possible, leaving the
		-- capture as soon as a character from the delimiter set is found
		-- TODO: Consider adding support for delimiters of more than a single character
		-- ^^This would have to be accomplished by doing a substitution to a known value
		--   followed by a second* pass that globs with the known value
		for item in (_data .. "\n"):gmatch("(.-)[" .. delimiter .. "]+[%s]*") do
			if validation then
				item = validation(item)
			end

			if item ~= nil then
				table.insert(list, item)
			end
		end

		if #list == 0 then
			-- if default then
			-- 	table.insert(list, default)
			--
			-- else return nil end
			return nil
		end
		
		return list
	end
end

-- Key/Value parameter string
-- TODO: Refactor this according to the needs of HTTP
--- init: Table to initalize with
local function _paramParser(init)
	assert(false, "TODO: _paramHeader header parser")
	if not init then
		init = {}
	end

	-- TODO
	return function()
		local params = _listParser()
		-- for _ in params ...
		return init
	end
end


-- >> BUILDER FUNCTIONS <<
-- Used by api:create() functionality

-- Header builder that extends the current string value
-- Example: An 'Accept' header that spans multiple lines
-- TODO: We may wish to assert that _current is a string (instead of waiting for a crash)
--- join: Specifies a string used to join the old and new values
local function _appendBuilder(join)
	join = join or " "
	return function(_current, _new)
		_new = _new and tostring(_new)
		if not _new or (#_new == 0) then
			-- No value to append
			return _current
		end

		if not _current then
			-- Nothing to append to
			return _new
		end

		local data = _current
			.. join
			.. _new
		
		return data
	end
end

-- Builder that joins two lists
-- TODO: Use a table instead of a list so that duplicates will not be inserted
--- join: Specifies a string used to join the table
--- insert: Closure that returns a transformation of the value that should be inserted (or nil)
local function _listBuilder(join, insert)
	if insert then assert(type(insert) == "function")
	else
		insert = function(v) return v end
	end

	-- TODO: Refactor such that we build a parent table from both lists
	--	using the values as keys, and then return a "list" from those keys
	--	in order to remove duplicates
	return function(_current, _new)
		if not _new then
			-- No value to insert
			return (_current ~= nil)
				and table.concat(_current, join)
				or nil
		end

		if not _current then
			-- _new will be the initial value
			-- (And we've already asserted that this value is a table)
			return table.concat(_new, join)
		end

		for _, val in ipairs(_new) do
			-- TODO: Consider allowing insertion at a specific index
			-- TODO: insert() may demand more (or different) context than _current
			if insert then
				val = insert(val)
			end
			if val then
				table.insert(_current, val)
			end
		end

		return table.concat(_current, join)
	end
end

-- Header builder that replaces the current value
-- Not restricted to strings
--- accept: Closure to determine if the original value should be replaced
local function _replaceBuilder(accept)
	if accept then assert(type(accept) == "function")
	else
		accept = function() return true end
	end

	return function(_current, _new)
		if not _new then
			-- No value to update
			return _current
		end

		if not _current then
			-- New value guaranteed
			return _new
		end

		return accept(_current, _new)
			and _new
			or _current
	end
end

-- Header builder for complex headers with key->value pairs
-- (TODO)
local function _tableBuilder()
end

-- >> VERIFICATION FUNCTIONS <<

-- Ensure that the field data is non-nil
local function _nilVerify()
	return function(_data)
		if _data == nil then return false end
		return true
	end
end


-- >> HEADER TABLE <<
-- Function table that maps header fields to their respective parsing rules
local _headers = {
	-- ["example"] = {
	-- 	name = function() return "Example" end,
	-- 	parse = function() end,
	-- 	create = function() end,
	-- 	validate = nil -- Can be nil
	-- 	default = nil -- Default value if not present
	-- },
	["accept"] = {
		name = function() return "Accept" end,
		default = function() return "*/*" end,
		parse = _listParser(",%s", function(_data)
			-- TODO: Accept-specific parsing
			-- https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Accept#syntax
			return _data end),
		create = _listBuilder(", "),
	},
	["connection"] = {
		name = function() return "Connection" end,
		parse = _strParser(),
		create = _replaceBuilder(),
	},
	["content-length"] = {
		name = function() return "Content-Length" end,
		parse = _numParser(0, nil, 0),
		create = _replaceBuilder(),
	},
	["content-type"] = {
		name = function() return "Content-Type" end,
		parse = _listParser(),
		create = nil,
	},
	["host"] = {
		name = function() return "Host" end,
		parse = _strParser(), -- TODO (validate host field)
		create = nil,
	},
	["keep-alive"] = {
		name = function() return "Keep-Alive" end,
		parse = _listParser(), -- TODO (parse keep alive)
		create = nil,
	},
	["sec-websocket-accept"] = {
		name = function() return "Sec-WebSocket-Accept" end,
		parse = _strParser(),
		create = nil,
	},
	["sec-websocket-key"] = {
		name = function() return "Sec-WebSocket-Key" end,
		parse = _strParser(),
		create = nil,
	},
	["upgrade"] = {
		name = function() return "Upgrade" end,
		parse = _listParser(",%s", function(_data)
			-- TODO: Upgrade-specific parsing
			-- https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Upgrade
			return _data end),
		create = nil,
	},
}
setmetatable(_headers, {
	__index = function(tbl, key)
		-- TODO: Consider converting this to an assertion
		if type(key) ~= "string" then return nil end

		local index = key:lower()
		if key == index then
			-- Handle recursive lookup
			-- If we make it here, then the lowercase key does not exist in the table
			return nil
		end
		return tbl[index] end,

	__newindex = function(tbl, key, value)
		-- Read-only table, do nothing
		end,
})


-- >> API FUNCTIONS <<

-- For parameter assertions
function api.type() return "headers" end

-- Return a parsed header directive
-- Return base data string by default if header unimplemented
--- htable: Table of headers in 'field -> data (string)' format
--- field: Requested field to parse
function api:get(field)
	local data = self._data[field]
	local props = _headers[field]

	if not data then
		_, data = pcall(props.default)
	end
	if not data or not props then
		-- A default value may not be defined
		return nil
	end

	-- Call the defined parsing function
	local func = props.parse
		or function(_data) return _data end

	return func(data)
end

-- Search a list field for a specific value
--- field: Field to search
--- value: Value to search for
--- case: Enable case-sensitivity for string values
function api:search(field, value, case)
	-- Parse the data at the requested field
	-- We could just use self:get(field) but this will include the default value (if present)
	local data = self._data[field]
	local props = _headers[field]
	if not data or not props then return false
	elseif props.parse then
		data = props.parse(data)
	end

	if case and type(value) == "string" then
		value = value:lower()
	end

	if type(data) == "string" then
		data = case and data or data:lower()
		return (data == value)
	end
		
	if type(data) ~= "list" then
		-- TODO: Consider if non-string values should be cast to strings
		return (data == value)
	end

	-- Field contains a list, check all values
	for _, v in ipairs(data) do
		if not case and (type(v) == "string") then
			v = v:lower()
		end

		-- TODO: Consider if non-string values should be cast to strings
		if v == value then
			return true
		end
	end

	return false
end

-- Insert data into the respective header field
-- Values passed to header create function will be ran through the header parser
--- field: Target field for the data
--- ...: Parameters to pass to the header-specific create function
function api:create(field, ...)
	assert(field ~= nil, "Cannot create header with nil field")

	local props = _headers[field] -- Header-specific closures from the global lookup table
	local parse = nil
	local create = nil

	-- Get the header-specific create/parse functions
	if props then
		parse = props.parse
		create = props.create
	end
	if not create then
		-- Fallback to list of strings
		create = _appendBuilder()
	end
	if not parse then
		-- Fallback to use the raw string data
		parse = function(_data) return _data end
	end

	-- Recursive function to pop arguments off the call stack
	local builder; builder = function(_current, _new, _next, ...)
		local c = parse(_current)
		local n = parse(_new)

		local _data = create(c, n)
		if _next == nil then
			return _data
		end

		return builder(_data, _next, ...)
	end

	-- Retrieve the current data for this header field to init the operation
	local current = self._data[field]
	local new = builder(current, ...)

	-- Set the updated field data
	if new then
		self._data[field] = new
	end
end

-- Dump a header table into a string (generally for HTTP communication)
-- NOTE: In a request, this will not append the necessary additional newline (to begin the body)
--- htable: Table of headers in 'field -> data (string)' format
--- newline: Newline format to use (defaults to \r\n)
function api:dump(newline)
	newline = newline or "\r\n"

	local _str = {}
	local props = nil
	for field, data in pairs(self._data) do
		props = _headers[field]

		-- NOTE: This shouldn't be called in the current state:
		--	Fields will not be created with their data is nil
		-- if not data and props then
		-- 	local _, default = pcall(props.default)
		-- 	data = default
		-- end
		data = data or ""

		if props then
			local _, name = pcall(props.name)
			field = name or field
		end

		assert(type(data) == "string")
		table.insert(_str, field .. ": " .. data .. newline)
	end

	return table.concat(_str)
end

-- Validate headers that need post-parse verification (for example, multiple entries in a field that only accepts one)
--- Returns true if all present headers have passed verification
function api:validate()
	local function _validate(_field, _data)
		local props = _headers[_field]
		if not props then
			return true -- No verify function so we can't invalidate the header
		end

		local func = props.validate
		if type(func) ~= "function" then
			return true -- No verify function so we can't invalidate the header
		end

		return func(_data)
	end

	for field, data in pairs(self._data) do
		local result = _validate(field, data)
		if not result then return false end
	end

	return true
end

local module = {
	new = _new,
}

return module

