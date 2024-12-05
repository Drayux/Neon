-- >>> headers.lua: Encoding/Decoding utilties for HTTP headers

local api = {}
local function _new(init)
	-- Headers can be initialized from a basic table
	if init then
		local _, argtype = pcall(init.type)
		if argtype == "headers" then
			-- Argument QOL - Return early if we already have a headers type
			return init
		end
		
		assert(type(init) == "table")
	end

	local data = {}
	local proxy = {}
	-- TODO: Ensure that there is no risk of arbitrary code execution here!!!
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

	-- data - Houses all field->value pairs within the header
	-- proxy - Links to data to translate accesses (to implement case-insensitivity)
	-- inst - Exposes an API that applies header-specific closures to the data returned by proxy
	local inst = { _data = proxy }
	setmetatable(inst, { __index = api })

	-- Populate the headers object with the init table
	if init then
		for field, datastr in pairs(init) do
			-- Idiot-proof on the chance one uses headers:new() instead of headers.new()
			assert(not datastr or type(datastr) == "string")
			inst:insert(field, datastr)
		end
	end

	return inst
end


-- >> PARSING FUNCTIONS <<
-- These functions are called at init to construct a paramaterized closure
-- string -> <parsed type>

-- Single string value
--- default: On an empty string, use this value instead
--- match: Lua 'regex' to compare the string with
local function _strParser(default, match)
	-- Paramter validation
	assert((default == nil) or (type(default) == "string"))
	assert((match == nil) or (type(match) == "string"))

	-- Parsed type: String (trivial)
	return function(_datastr)
		-- Stored data must be a non-empty string
		if type(_datastr) ~= "string"
			or (#_datastr == 0)
		then
			return nil
		end

		if match then
			_datastr = _datastr:match(match)
		end
		return _datastr
	end
end

-- Single numerical value
--- rangeMin: Smallest allowable value (inclusive)
--- rangeMax: Largest allowable value (inclusive)
--- default: When data is invalid, use this value instead
local function _numParser(rangeMin, rangeMax, default)
	-- Paramter validation
	assert((rangeMin == nil) or (type(rangeMin) == "number"))
	assert((rangeMax == nil) or (type(rangeMax) == "number"))
	assert((default == nil) or (type(default) == "number"))

	-- Parsed type: Number
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
		return val
	end
end

-- List of values
--- delimiter: String to determine the next element (lua match)
--- validation: Closure to transform the parsed value (string -> string/nil)
--- > Returns the transformed item or nil
local function _listParser(delimiters, validation)
	-- Paramter validation/defaulting
	assert((validation == nil) or (type(validation) == "function"))

	-- Default to commas, semicolons, or whitespace
	delimiters = delimiters or "[,;%s]"
	if type(delimiters) == "string" then
		delimiters = { delimiters }
	end
	assert((type(delimiters) == "table") and (#delimiters > 0))
	for _, _delim in ipairs(delimiters) do
		assert((type(_delim) == "string") and (#_delim > 0))
	end

	-- Parsed type: List
	return function(_data)
		-- Check for the parsed type
		if type(_data) == "table" then
			-- Verify that the table contains a "list" portion
			-- > If the iterator from ipairs() called at the initial
			-- > value returns nil, then the "list portion" is empty
			local iter, tbl, idx = ipairs(_data)
			return iter(tbl, idx) and _data

		-- Else data must be a non-empty string
		elseif type(_data) ~= "string"
			or (#_data == 0)
		then
			return nil
		end

		-- Match every delimiter sequence and replace it with a known but non-standard
		-- character that serves as a substitution marker (0x1A)
		local marker = string.char(0x1A)
		local transform = _data .. marker
		for _, delimiter in ipairs(delimiters) do
			transform = transform:gsub("(" .. delimiter .. ")", marker)
		end

		-- Match a sequence of characters as short as possible, leaving the
		-- capture as soon as the substitute character (0x1A) is found
		-- > Also skip leading and trailing spaces
		local list = {}
		for item in transform:gmatch("%s*(.-)[" .. marker .. "]+%s*") do
			if validation then
				item = validation(item)
			end

			if item ~= nil then
				table.insert(list, item)
			end
		end

		return (#list > 0) and list
			or nil
	end
end

-- Key/Value parameter string
-- TODO: Refactor this according to the needs of HTTP
--- header: String representing the type of the header (for validation)
--- init: Table of default values
--- parse: Iterator for the data string that returns key-value pairs
local function _tableParser(header, init, parse)
	-- Paramter validation/defaulting
	assert(type(header) == "string") -- Cannot be nil
	assert((init == nil) or (type(init) == "table"))
	if parse then assert(type(parse) == "function")
	else
		parse = function(s)
			local iter = s:gmatch("%s*([^;]+);*")

			-- gmatch iterator stores the state in its closure so it ignores arguments
			return function()
				local _match = iter()
				if not _match then return nil end

				local key, value = _match:match("(%S+)=(%S+)")
				if not key then
					key = "_value"
					value = _match
				end
				return key, value
			end
		end
	end

	-- Parsed type: Table
	return function(_datastr)
		-- Check for the parsed type
		if type(_datastr) == "table" then
			local valid = (_datastr["_header"] == header)
			-- TODO: Consider checking all keys in init
			return valid and _datastr
				or nil

		elseif type(_datastr) ~= "string"
			or (#_datastr == 0)
		then
			return nil
		end

		-- Prepare the table that will be returned
		local data = {
			_header = header,
			_error = nil, -- Currently unused, placeholder for validation routine
			_value = nil, -- Key for the non-parameter component of the data
		}
		if init then
			-- Copy initialization data into the new data table
			for k, v in pairs(init) do
				data[k] = v
			end

			-- TODO: Disallow any other entries into the table
			setmetatable(data, { __newindex = nil })
		end

		for key, value in parse(_datastr) do
			data[key] = value
			-- TODO: If adding validation, consider putting that functionality here
		end

		return data
	end
end


-- >> BUILDER FUNCTIONS <<
-- Used by api:create() functionality
-- <parsed type>, <parsed type> -> <parsed type>

-- Header builder that replaces the current value
-- Not restricted to strings
--- accept: Closure to determine if the original value should be replaced
--- > Returns the chosen value (parsed type, parsed type -> parsed type)
local function _replaceBuilder(accept)
	if accept then assert(type(accept) == "function")
	else
		accept = function(c, n) return n end
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
			or _current
	end
end

-- Header builder that extends the current string value
-- Example: An 'Accept' header that spans multiple lines
--- join: Specifies a string used to join the old and new values
local function _appendBuilder(join)
	join = join or " "
	return function(_current, _new)
		-- _new = _new and tostring(_new)
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
--- insert: Closure that builds a list from a key table (table -> table)
local function _listBuilder(insert)
	if insert then assert(type(insert) == "function")
	else
		insert = function(_set)
			local list = {}
			-- Default to inserting everything that is true
			for key, value in pairs(_set) do
				if value then
					table.insert(list, key)
				end
			end
			return list
		end
	end

	-- List join is performed by setting the values of each list as the key of a table
	-- > This omits adding duplicate entries to the assembled list
	-- TODO: Consider adding string case-sensitivity (maybe better suited for an overridden insert closure)
	return function(_current, _new)
		if type(_current) == "table"
			and (#_current > 0)
		then
			-- A populated table already exists
			-- Base case?
			if not _new then
				-- return table.concat(_current, join)
				return _current
			end
		else
			-- _new is the initial value
			return _new or _current -- Reuse the empty table if it already exists
			-- return _new and table.concat(_new, join)
			--	or _current
		end

		-- Both tables exist, perform the join
		-- Set all list values as keys of a table...
		local set = {}
		for _, val in ipairs(_current) do
			set[val] = true -- Arbitrary temp value
		end
		for _, val in ipairs(_new) do
			set[val] = true -- Arbitrary temp value
		end

		-- and then pull the keys into a new list
		-- > This avoids duplicate entries
		local list = insert(set)
		return list
	end
end

-- Header builder for complex headers with key->value pairs
--- merge: Closure that performs the table join (table, table -> nil)
local function _tableBuilder(merge)
	if merge then assert(type(merge) == "function")
	else
		-- Use a trivial table join operation
		merge = function(base, update)
			-- Assume that current is newindex-restricted to the appropriate form
			for key, val in pairs(update) do
				-- Do not copy over meta values (begins with _)
				if val and not key:match("^_") then
					base[key] = val
				end
			end
		end
	end

	return function(_current, _new)
		if type(_current) == "table" then
			-- A populated table already exists
			-- Base case?
			if not _new then
				return _current
			end
		else
			-- _new is the initial value
			return _new
		end

		-- Both tables exist, perform the join
		merge(_current, _new)
		return _current
	end
end


-- >> ENCODER FUNCTIONS <<
-- Used by api:create() functionality
-- <parsed type> -> string

-- Basic table.concat wrapper
--- join: Specifies a string used to join the table
local function _listEncoder(join)
	join = join or ""
	assert(type(join) == "string")

	return function(_data)
		if type(_data) ~= "table" then
			assert(false) -- TODO: Not sure if I should have this here or not
			return nil
		end

		return table.concat(_data, join .. " ")
	end
end

-- Parameter table encoder
-- TODO: Consider parsed type validation
--- default: Default value for the non-parameter component
local function _tableEncoder(default)
	if default then assert(type(default) == "string")
	else
		default = ""
	end

	return function(_parsed)
		if type(_parsed) ~= "table" then
			assert(false) -- TODO: Not sure if I should have this here or not
			return nil
		end
		local value = _parsed["_value"] or default
		-- if type(value) ~= "string"
		--	or (#value == 0)
		-- then
		--	return nil
		-- end

		for k, v in pairs(_parsed) do
			if v and not k:match("^_") then
				value = value .. "; " .. k .. "=" .. v
			end
		end

		-- Remove leading '; ' if no non-parameter component
		value = value:match("^;%s(.*)") or value
		return value
	end
end

-- >> VERIFICATION FUNCTIONS <<

-- Ensure that the field data is non-nil
local function _nilVerify()
	return function(_data)
		if _data == nil then return false end
		return true
	end
end

-- Check for any header parsing-related failures
local function _parseVerify()
	return function(_datastr)
		-- TODO
		-- get the parser function
		-- run the parser function
		-- check the _error flag in the parsed type
	end
end

-- >> HEADER TABLE <<
-- Function table that maps header fields to their respective parsing rules
local _headers = {
	-- ["example"] = {
	-- 	name = function() return "Example" end,
	-- 	default = nil -- Default value
	-- 	parse = function(_str) end, -- Data string -> Parsed type
	-- 	create = function(_parsedType) end, -- Parsed type -> Data string
	--  insert = function(_curPT, _newPT) end, -- Update field data
	-- 	validate = nil -- Skip if nil
	-- },
	["accept"] = {
		name = function() return "Accept" end,
		default = function() return "*/*" end,

		-- TODO: Accept-specific validation
		-- https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Accept#syntax
		parse = _listParser(","),
		create = _listEncoder(","),
		insert = _listBuilder(),
	},
	["connection"] = {
		name = function() return "Connection" end,
		default = function() return "keep-alive" end,
		parse = _listParser(","),
		create = _listEncoder(","),
		insert = _listBuilder(),
	},
	["content-length"] = {
		name = function() return "Content-Length" end,
		parse = _numParser(0, nil, 0),
	},
	["content-type"] = {
		name = function() return "Content-Type" end,
		parse = _tableParser("content-type", {
				-- type = nil,
				-- subtype = nil,
				charset = nil,
				boundary = nil,
			}),

		create = _tableEncoder(),
		-- function(_data)
		--	local mtype = _data["type"]
		--	if type(mtype) ~= "string"
		--		or (#mtype == 0)
		--	then
		--		return nil
		--	end
		--	local subtype = _data["subtype"]
		--	local charset = _data["charset"]
		--	local boundary = _data["boundary"]
		--	local ret = mtype
		--		.. (subtype and ("/" .. subtype) or "")
		--		.. (charset and ("; charset=" .. charset) or "")
		--		.. (boundary and ("; boundary=" .. boundary) or "")
		--	return ret end,

		insert = _tableBuilder(),
		-- function(base, update)
		--	if update["type"] then
		--		base["type"] = update["type"]
		--		base["subtype"] = update["subtype"]
		--	end
		--	base["charset"] = update["charset"]
		--		or base["charset"]
		--	base["boundary"] = update["boundary"]
		--		or base["boundary"]
		--	end),
	},
	["host"] = {
		name = function() return "Host" end,
		parse = _strParser(nil, "^%a%S-%.%a+$"),
	},
	["keep-alive"] = {
		name = function() return "Keep-Alive" end,
		parse = _tableParser("keep-alive", {
				timeout = nil,
				max = nil,
			}),
		create = _tableEncoder(),
		insert = _tableBuilder(),
	},
	["sec-websocket-accept"] = {
		name = function() return "Sec-WebSocket-Accept" end,
		parse = _strParser(nil, "^" .. string.rep("[%w%+%-/]", 27) .. "=$"),
	},
	["sec-websocket-key"] = {
		name = function() return "Sec-WebSocket-Key" end,
		parse = _strParser(nil, "^" .. string.rep("[%w%+%-/]", 22) .. "==$"),
	},
	["upgrade"] = {
		name = function() return "Upgrade" end,
		-- TODO: Upgrade-specific parsing
		-- https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Upgrade
		parse = _listParser(","),
		create = _listEncoder(","),
		insert = _listBuilder(),
	},
	
	--- NEON HEADERS ---
	["command"] = {
		name = function() return "Command" end,
		parse = _listParser(","),
		create = _listEncoder(","),
		insert = _listBuilder(),
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

	-- Attempt to get the default value
	if props and not data then
		_, data = pcall(props.default)
	end

	-- Nothing left to do if data is still nil
	if not data then
		return nil
	end

	-- Call the defined parsing function
	local func = props.parse
		or function(_data) return _data end

	return func(data)
end

-- Check if a value exists in a header
-- Shared for all parsed types
--- field: Target header field
--- value: Value to search for (or nil to check the field for a non-nil value)
--- case: Enable case-sensitivity for string values
function api:search(field, value, case)
	-- Run the header parser on the target field
	-- Avoid self:get() as this will include any default values
	local data = self._data[field]
	local props = _headers[field]

	if data and props and props.parse then
		data = props.parse(data)
	end

	if not data then
		return false
	elseif not value then
		-- Target field exists
		return true
	end

	-- Normalize the type of value
	if type(value) == "string" then
		value = case and value or value:lower()

	elseif type(value) == "number" then
		-- Acceptable - Nothing to do
	
	else
		-- No comparison for table or function types (yet)
		assert(false, "Cannot search for value of type `" .. type(value) .. "`")
		return nil
	end

	-- Begin comparison
	if type(data) == "string" then
		data = case and data or data:lower()
	end

	-- Additional `if` here to include numbers
	if type(data) ~= "table" then
		return (data == value)
	end

	-- Otherwise the parsed type is a list/table
	-- Check if the value exists as a key
	if data[value] ~= nil then
		return true
	end
	
	-- The value may exist within an array
	for _, entry in ipairs(data) do
		if not case and (type(entry) == "string") then
			entry = entry:lower()
		end

		if entry == value then
			return true
		end
	end

	return false
end

-- Insert data into the respective header field
-- Accepts parsed or string types
-- Returns an updated value of the parsed type
--- field: Target field for the data
--- ...: Parameters to pass to the header-specific create function
local _fallbackInsert = _replaceBuilder()
function api:insert(field, ...)
	assert(field ~= nil, "Cannot create header with nil field")

	local props = _headers[field] -- Header-specific closures from the global lookup table
	local parse = nil
	local create = nil
	local insert = nil

	-- Prepare the header-specific functions
	if props then
		parse = props.parse
		create = props.create
		insert = props.insert
	end
	if not parse then
		-- No parser defined: Assume inputs are the expected parsed type
		parse = function(_data) return _data end
	end
	if not create then
		-- Fallback to trivial type conversion
		create = tostring
	end
	if not insert then
		-- Fallback to list of strings
		insert = _fallbackInsert
	end

	-- Recursive function to pop arguments off the call stack
	local builder; builder = function(_current, _new, _next, ...)
		local c = parse(_current)
		local n = parse(_new)

		local _data = insert(c, n)
		if _next == nil then
			-- Base condition
			return _data
		end

		return builder(_data, _next, ...)
	end

	-- Retrieve the current data for this header field to init the operation
	local current = self._data[field]
	local new = builder(current, ...)
	if not new then
		return nil
	end

	-- Call header create to convert the parsed type into a data string
	-- TODO: The dev may wish to know that this conversion failed
	local _, data = pcall(create, new)
	if not data then
		return nil
	end

	-- Set the updated field data
	self._data[field] = data
	return new
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

-- Single function API
return _new

