-- >>> json.lua: JSON <-> Table parser/encoder

-- Top-level parser routine
-- > Lexes tokens and builds a lua table according to a simple grammar
local function _decode(str)
end

local function encodeValue(value)
	local _type = type(value)
	if value == nil then
		return "null"

	elseif _type == "boolean" then
		return value and "true" or "false"

	elseif _type == "number" then
		return tostring(value)

	elseif _type == "string" then
		-- TODO: String data conversion
		-- > ex. \u0065 = A
		return "\"" .. value .. "\""
	end

	assert(false, "Could not encode value " .. tostring(value)
		.. "with type of " .. _type)
end

-- Object/Array/Value disambiguation
--- buf: Output (buffer) table
--- tbl: Lua table/value to convert to JSON
local encodeTable; encodeTable = function(buf, tbl, depth)
	-- Base case
	if type(tbl) ~= "table" then
		table.insert(buf, encodeValue(tbl))
		return
	end

	-- Disambiguate object from array
	local array = false
	local iterf = pairs
	if #tbl > 0 then
		array = true
		iterf = ipairs
		table.insert(buf, "[")
	else
		table.insert(buf, "{")
	end

	-- Insert elements
	local tab = string.rep("\t", depth + 1)
	local first = true
	for k, v in iterf(tbl) do
		if first then
			first = false

			-- Insert a newline for bracket beautification
			table.insert(buf, "\n")
		else
			-- Insert the comma for the previous element
			-- > The final element must not have a comma following it
			table.insert(buf, ",\n")
		end

		local prepend = array and tab
			or tab .. "\"" .. k .. "\": "

		-- Value insert is called inside of the next recursive frame
		table.insert(buf, prepend)
		encodeTable(buf, v, depth + 1)
	end

	-- First is used to determine if the object was empty
	local nl = first and "" or "\n"
	local tail = string.rep("\t", (first and 0) or depth)
		.. (array and "]" or "}")

	table.insert(buf, nl .. tail)
end

-- Top-level encoder routine
local function _encode(tbl)
	local buf = {}
	encodeTable(buf, tbl, 0)
	
	return table.concat(buf)
end

local function _test1()
	local inner = {}
	-- inner["x"] = 37
	-- inner["y"] = 48
	-- inner["z"] = 69

	local outer = { "a", "b", "c", inner }

	-- print("ordered")
	-- for i, v in ipairs(tbl) do
	-- 	print(v)
	-- end
	-- print("key/value")
	-- for k, v in pairs(tbl) do
	-- 	print(v)
	-- end
	-- print(#tbl)

	print(_encode(outer))
end

local module = {
	decode = _decode,
	encode = _encode,
	test = _test1,
}
return module

