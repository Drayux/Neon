-- >>> json.lua: JSON <-> Table parser/encoder

-- Top-level parser routine
-- > Lexes tokens and builds a lua table according to a simple grammar
local function _decode(str)
end

-- Top-level encoder routine
local function _encode(tbl)
end

local module = {
	decode = _decode,
	encode = _encode,
}
return module

