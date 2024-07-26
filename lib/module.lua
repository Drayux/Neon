-- >>> module.lua: Skeleton protocol state machine for connection objects

-- >> STATE OBJECT <<
local function _newInstance(args)
	if not args then args = {} end
	local inst = {
		-- state properties
	}

	return inst
end

local protocol = {
	INIT = nil,

	-- Interrupt routines
	_TIMEOUT = nil,
	_CLOSE = nil,
}

-- Define transition table start state
setmetatable(protocol, { __index = function(tbl, key)
	if not key then return nil end

	if key == "START" then return tbl["INIT"] end
	return nil
end })


-- >> MODULE API <<
local module = {
	instance = _newInstance,
	transitions = function() return protocol end,
}
return module

