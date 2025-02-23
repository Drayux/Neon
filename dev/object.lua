-- >>> object.lua - Skeleton object API for quick reference

-- >> OBJECT API <<
local api = {}
local function _new()
	local obj = {
	}

	setmetatable(obj, {__index = api})
	return obj
end

-- >> MODULE API <<
local module = {
	new = _new,
}

return module

