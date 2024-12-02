-- >>> json.lua: JSON <-> Table parser/encoder

---------------  DECODE  ---------------
-- Token definitions for lexing
local tokens = {
	objstart = "^{",
	objend = "^}",
	arrstart = "^%[",
	arrend = "^%]",
	quote = "^\"",
	colon = "^:",
	comma = "^,",
	negative = "^-",
	decimal = "^%.",

	_true = "^true",
	_false = "^false",
	null = "^null",

	whitespace = "^[ \n\r\t]*",
	letter = "^[^\\\"%c]*", -- anything except control chars, \, or "
	escape = "^\\[\"\\bfnrt/]",
	uescape = "^\\u%x%x%x%x",
	zero = "^0",
	digits = "^%d+",
	exponent = "^[eE][%+%-]?",
}

-- Grammar definition for parsing
-- > https://www.json.org/json-en.html
local grammar = {}
function grammar.json(data, pos)
	assert(pos == 1, "JSON token must be the top-level match")

	local parsed = nil
	local nextpos = nil
	parsed, nextpos = grammar.element(data, pos)

	-- TODO: Check for parse errors
	if not parsed then
		print("parsing error probably")
		return nil, pos
	else
		pos = nextpos
	end

	-- TODO: Check for extra characters
	-- > This will require an extra whitespace token
	if pos <= #data then
		print("looks like not all of the object was parsed")
	end

	return parsed, pos
end

function grammar.array(data, pos)
	local parsed = nil
	local nextpos = nil

	_, nextpos = string.find(data, tokens.arrstart, pos)
	pos = (nextpos or pos) + 1
	if not nextpos then
		return nil, pos
	end

	-- Pass an empty table through (for output) to save resouces
	-- TODO: Consider how to handle when the array is empty
	local _array = {}
	parsed, nextpos = grammar.elements(data, pos, _array)
	if not parsed then
		-- An error might have occurred
		if #_array > 0 then
			return nil, pos
		end

		-- Otherwise match any whitespace
		_, nextpos = string.find(data, tokens.whitespace, pos)
		pos = (nextpos < pos) and pos
			or nextpos + 1
	else
		pos = nextpos
	end

	_, nextpos = string.find(data, tokens.arrend, pos)
	pos = (nextpos or pos) + 1
	if not nextpos then
		return nil, pos
	end

	return parsed or _array, pos
end

function grammar.elements(data, pos, parsed)
	local _element = nil
	local nextpos = nil
	local fail = false

	_element, nextpos, fail = grammar.element(data, pos)
	pos = nextpos or pos
	if fail then
		return nil, pos
	end

	-- Insert the parsed value into the array
	table.insert(parsed, _element)
	-- parsed[#parsed + 1] = _element -- Alternative insertion approach

	_, nextpos = string.find(data, tokens.comma, pos)
	if nextpos then
		-- Additional array elements are (should be) present
		parsed, nextpos = grammar.elements(data, nextpos + 1, parsed)
		pos = nextpos or pos
		if not parsed then
			-- Propigate the parsing error up
			return nil, pos
		end
	end

	return parsed, pos
end

function grammar.element(data, pos)
	local parsed = nil
	local nextpos = nilu
	local fail = false

	_, nextpos = string.find(data, tokens.whitespace, pos)
	pos = (nextpos < pos) and pos
		or nextpos + 1

	parsed, pos, fail = grammar.value(data, pos)
	if fail then
		return nil, pos, true
	end

	_, nextpos = string.find(data, tokens.whitespace, pos)
	pos = (nextpos < pos) and pos
		or nextpos + 1

	return parsed, pos, false
end

function grammar.object(data, pos)
	local parsed = nil
	local nextpos = nil

	_, nextpos = string.find(data, tokens.objstart, pos)
	pos = (nextpos or pos) + 1
	if not nextpos then
		return nil, pos
	end

	-- Pass an empty table through (for output) to save resouces
	-- TODO: Consider how to handle when the array is empty
	local _obj = {}
	parsed, nextpos = grammar.members(data, pos, _obj)
	if not parsed then
		-- An error occurred if the table is not empty
		if next(_obj) ~= nil then
			return nil, pos
		end

		-- Otherwise match any whitespace
		_, nextpos = string.find(data, tokens.whitespace, pos)
		pos = (nextpos < pos) and pos
			or nextpos + 1
	else
		pos = nextpos
	end

	_, nextpos = string.find(data, tokens.objend, pos)
	pos = (nextpos or pos) + 1
	if not nextpos then
		return nil, pos
	end

	return parsed or _obj, pos
end

function grammar.members(data, pos, parsed)
	local key = nil
	local value = nil
	local nextpos = nil
	local fail = false

	key, value, nextpos = grammar.member(data, pos)
	pos = nextpos or pos
	if not key then
		return nil, pos
	end

	-- Insert the parsed value into the array
	parsed[key] = value

	_, nextpos = string.find(data, tokens.comma, pos)
	if nextpos then
		-- Additional array elements are (should be) present
		parsed, nextpos = grammar.members(data, nextpos + 1, parsed)
		pos = nextpos or pos
		if not parsed then
			-- Propigate the parsing error up
			return nil, pos
		end
	end

	return parsed, pos
end

-- Member breaks the usual form by returning a key and a value instead of a parsed type
-- > Further, fail is not used as the key will never be nil upon success
function grammar.member(data, pos)
	local key = nil
	local value = nil
	local nextpos = nil
	local fail = false

	_, nextpos = string.find(data, tokens.whitespace, pos)
	pos = (nextpos < pos) and pos
		or nextpos + 1

	key, pos = grammar.string(data, pos)
	if not key then
		return nil, nil, pos
	end

	_, nextpos = string.find(data, tokens.whitespace, pos)
	pos = (nextpos < pos) and pos
		or nextpos + 1

	_, nextpos = string.find(data, tokens.colon, pos)
	if not nextpos then
		return nil, nil, pos
	end
	pos = nextpos + 1

	value, nextpos, fail = grammar.element(data, pos)
	pos = nextpos or pos
	if fail then
		return nil, nil, pos
	end

	return key, value, pos 
end

function grammar.value(data, pos)
	local parsed = nil
	local nextpos = nil

	-- Elements are ordered by least complexity
	-- Value: true
	_, nextpos = string.find(data, tokens._true, pos)
	if nextpos then
		return true, nextpos + 1, false
	end

	-- Value: false
	_, nextpos = string.find(data, tokens._false, pos)
	if nextpos then
		return false, nextpos + 1, false
	end

	-- Value: null
	-- > TODO: This may cause issues as nil values are skipped when building a table
	_, nextpos = string.find(data, tokens.null, pos)
	if nextpos then
		return nil, nextpos + 1, false
	end

	-- Value: string
	parsed, nextpos = grammar.string(data, pos)
	if parsed then
		return parsed, nextpos, false
	end

	-- Value: number
	parsed, nextpos = grammar.number(data, pos)
	if parsed then
		return parsed, nextpos, false
	end

	-- Value: array
	parsed, nextpos = grammar.array(data, pos)
	if parsed then
		return parsed, nextpos, false
	end

	-- Value: object
	parsed, nextpos = grammar.object(data, pos)
	if parsed then
		return parsed, nextpos, false
	end

	-- Values can be nil/false in lua terms
	-- > Thus an extra value is returned to indicate if parsing has failed
	return nil, pos, true
end

function grammar.string(data, pos)
	local parsed = nil
	local nextpos = nil

	_, nextpos = string.find(data, tokens.quote, pos)
	pos = (nextpos or pos) + 1
	if not nextpos then
		return nil, pos
	end

	-- Pass an empty table through (for output) to save resouces
	local _str = {}
	parsed, nextpos = grammar.characters(data, pos, _str)
	pos = nextpos or pos -- characters (should) always return non-nil

	_, nextpos = string.find(data, tokens.quote, pos)
	pos = (nextpos or pos) + 1
	if not nextpos then
		return nil, pos
	end

	return table.concat(parsed or _str), pos
end

function grammar.characters(data, pos, parsed)
	local char = nil
	local nextpos = nil

	char, nextpos = grammar.character(data, pos)
	pos = nextpos or pos
	if not char then
		return parsed, pos
	end

	-- Insert the parsed value into the array
	table.insert(parsed, char)

	parsed, nextpos = grammar.characters(data, pos, parsed)
	return parsed, nextpos
end

-- This differs from the official grammar slightly by
-- > matching groups of letters at a time in chunks
function grammar.character(data, pos)
	-- print("character", string.sub(data, pos))
	local parsed = nil
	local nextpos = nil

	-- Standard fare letter (anything except " or ')
	_, nextpos = string.find(data, tokens.letter, pos)
	if nextpos >= pos then
		local chunk = string.sub(data, pos, nextpos)
		return chunk, nextpos + 1
	end

	-- Escape sequences: \n \r \t \b \f \" \\ \/
	_, nextpos = string.find(data, tokens.escape, pos)
	if nextpos then
		-- nextpos is currently pointing at the escape character
		local esc = string.byte(data, nextpos)
		local char = nil

		-- 34 -> \"
		if esc == 34 then
			char = [["]]

		-- 47 -> \/
		elseif esc == 47 then
			char = [[/]]

		-- 92 -> \\
		elseif esc == 92 then
			char = [[\]]

		-- 98 -> \b (ASCII backspace)
		elseif esc == 98 then
			char = string.char(8)

		-- 102 -> \f (ASCII form feed)
		elseif esc == 102 then
			char = string.char(12)

		-- 110 -> \n (ASCII new line)
		elseif esc == 110 then
			char = string.char(10)

		-- 114 -> \r (ASCII carrage return)
		elseif esc == 114 then
			char = string.char(13)

		-- 116 -> \t (ASCII horizontal tab)
		elseif esc == 116 then
			char = string.char(9)
		end

		return char, nextpos + 1
	end

	-- Unicode char escape sequence
	_, nextpos = string.find(data, tokens.uescape, pos)
	if nextpos then
		-- TODO: This is a bit lazy and can probably be optimized
		local ucode = tonumber("0x" .. string.sub(data, pos + 2, nextpos))
		return string.char(ucode), nextpos + 1
	end

	return nil, pos
end

-- Akin to strings, number deviates from the official grammar somewhat
-- > by opting for chunks to reduce the number of recursive calls
function grammar.number(data, pos)
	local nextpos = nil

	local negative = false
	local number = "0"
	local fraction = nil
	local exponent = nil
	local expnegative = false

	-- A minus sign may exist optionally
	_, nextpos = string.find(data, tokens.negative, pos)
	if nextpos then
		negative = true
		pos = nextpos + 1
	end

	-- Number cannot start with a zero unless the zero is by itself
	_, nextpos = string.find(data, tokens.zero, pos)
	if not nextpos then
		-- Check for a series of digits instead
		_, nextpos = string.find(data, tokens.digits, pos)
		if not nextpos then
			-- Still no matches, fail
			return nil, pos
		end
		number = string.sub(data, pos, nextpos)
	end
	pos = nextpos + 1

	-- Fraction component
	_, nextpos = string.find(data, tokens.decimal, pos)
	if nextpos then
		-- Fraction exists, digit must be matched
		pos = nextpos + 1
		_, nextpos = string.find(data, tokens.digits, pos)
		if not nextpos then
			return nil, pos
		end

		fraction = string.sub(data, pos, nextpos)
		pos = nextpos + 1
	end

	-- Exponent component
	_, nextpos = string.find(data, tokens.exponent, pos)
	if nextpos then
		-- Exponent exists, digit must be matched
		if string.byte(data, nextpos) == 45 then
			expnegative = true
		end

		pos = nextpos + 1
		_, nextpos = string.find(data, tokens.digits, pos)
		if not nextpos then
			return nil, pos
		end

		exponent = string.sub(data, pos, nextpos)
		pos = nextpos + 1
	end

	-- NOTE: It may be prudent to check for out of place number things here
	-- > Except that number-related tokens are not present elsewhere in the grammar

	-- TODO: This is (also) sorta lazy (see strings \u escapes) so it can probably be improved
	local value = tonumber(number
		.. (fraction and ("." .. fraction) or ""))
	
	if exponent then
		local exp = tonumber(exponent)
		if expnegative then
			exp = -exp
		end

		value = value * (10 ^ exp)
	end

	if negative then
		value = -value
	end
	
	return value, pos
end

-- Top-level parser routine
-- > Lexes tokens and builds a lua table according to a simple grammar
local function _decode(str)
end

---------------  ENCODE  ---------------
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
----------------------------------------

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

local function _test2()
	-- local data = "\"hello\\nworld\""
	-- local data = "69.9e-9"
	-- local data = "[[true, null, false], [], [true, false]]"
	local data = "{\"toes\": \"titties\", \"balls\": [69420e-3, \"pussy\", false ], \"ass\"  :{}}"
	local parsed = grammar.json(data, 1, {})
	print("-----")
	print(parsed)
	-- print("big" .. parsed .. "toes")
	for i, v in pairs(parsed) do
		print("\t" .. tostring(i), v)
		if type(v) == "table" then
			for i2, v2 in ipairs(v) do
				print("\t\t" .. tostring(v2))
			end
		end
	end
end

local module = {
	decode = _decode,
	encode = _encode,
}
return module

