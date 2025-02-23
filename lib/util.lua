-- >>> util.lua: Stateless, generic utility functions

-- >> UTILITY MODULE <<
local module = {
	time = require("cqueues").monotime -- API forward
}

-- Byte-wise iterator of an input string
-- Stateless, so this does not return a context
--
-- Iterator can be called directly with:
-- > local iter = bytes("foo"); local _, byte = iter()
-- Or we can jump to a specific index with:
-- > local _, byte = iter(6)
--
-- Finally this works inside of for each loops as well:
-- > local iter = bytes("bar")
-- > iter(2) -- jump to second byte (next call will be third byte)
-- > for i, b in iter do
-- >	-- do something with bytes 3 -> the rest
-- > end
function module.bytes(s)
	-- assert(type(s) == "string", "Bytes iterator requires a string as input")
	if type(s) ~= "string" then return function() return nil, nil end end

	local i = 1
	local f = function(start)
		if start and start > 0 then i = start end

		local b = string.byte(s, i)
		i = i + 1

		if b then return i, b end
	end
	return f, nil, 0
end

-- Attempt to find the working directory of the script 
function module.getcwd()
	-- TODO: if obslua, then this should be easy?
	
	-- Definitely a hack, but the script shouldn't run unless
	-- we're in the correct working directory to begin with
	local path = io.popen("pwd"):read()
	if path:match("Neon$") then return path end

	return nil
end

return module

