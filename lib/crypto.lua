-- >>> crypto.lua: Cryptography functions

-- >> BITWISE OPERATIONS <<
-- Left bitshift with wrap-around
local function brol(a, x)
	return ((a << x) & 0xFFFFFFFF) | (a >> (32 - x))
end

-- Variable-length bitwise OR
local bor; bor = function(a, b, ...)
	if not b then return a end
	return bor(a | b, ...)
end

-- Variable-length bitwise AND
local band; band = function(a, b, ...)
	if not b then return a end
	return band(a & b, ...)
end

-- Variable-length bitwise XOR
local bxor; bxor = function(a, b, ...)
	if not b then return a end
	return bxor(a ~ b, ...)
end

-- Bitwise ternary condition
local function bternary(a, b, c)
	return c ~ (a & (b ~ c))
end

-- Bitwise majority (more 1s vs 0s)
local function bmajority(a, b, c)
	return (a & (b | c)) | (b & c)
end


-- >> DATATYPE MANIPULATION <<
-- Splits a uint32 into four bytes (big endian output)
-- Taken directly from: https://github.com/mpeterv/sha1/blob/master/src/sha1/common.lua
local function splitU32(num)
	-- LSB -> MSB
	local d = num % 256
	num = (num - d) / 256

	local c = (num & 0xFF) % 256
	num = (num - c) / 256

	local b = (num & 0xFF) % 256
	num = (num - b) / 256

	local a = (num & 0xFF) % 256

	return a, b, c, d
end

-- Splits a uint32 into four bytes (big endian input)
-- Taken directly from: https://github.com/mpeterv/sha1/blob/master/src/sha1/common.lua
local function toU32(a, b, c, d)
	return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
end


-- >> CRYPTOGRAPHY MODULE <<
local module = {}

-- Seed the RNG from /dev/random
function module.seed()
	local rand = io.open("/dev/random", "rb")
	local seed = 0

	for i = 1, 8 do
		seed = (seed << 8) | string.byte(rand:read(1))
	end

	rand:close()
	math.randomseed(seed)
end

-- Generate a SHA-1 hash of a provided string
-- Taken directly from: https://github.com/mpeterv/sha1/tree/master
-- TODO: It may be prudent to support multiple hashing algorithms as an option
function module.hash(input)
	-- Debug output
	-- print("input: " .. input)
	
	-- Input preprocessing
	local a1 = string.char(0x80)
	local a2 = string.rep(string.char(0), -(#input + 1 + 8) % 64)
	local a3 = string.char(0, 0, 0, 0, splitU32(#input * 8))
	
	input = input .. a1 .. a2 .. a3
	assert(#input % 64 == 0)

	-- Initalize hash
	local h0 = 0x67452301
	local h1 = 0xEFCDAB89
	local h2 = 0x98BADCFE
	local h3 = 0x10325476
	local h4 = 0xC3D2E1F0
	local buf = {}

	-- Process chunks of 64 bytes
	for idx = 1, #input, 64 do
		-- Split chunk into 16x 32-bit numbers (store results in buffer)
		local start = idx
		for i = 0, 15 do
			buf[i] = toU32(string.byte(input, start, start + 3))
			start = start + 4
		end

		-- Use bit manipulation to extend the input to an array of 80x 4-byte values
		for i = 16, 79 do
			local ext = bxor(buf[i - 3], buf[i - 8], buf[i - 14], buf[i - 16])
			buf[i] = brol(ext, 1)
		end

		-- Init chunk hash
		local _h0 = h0
		local _h1 = h1
		local _h2 = h2
		local _h3 = h3
		local _h4 = h4

		-- Begin chunk manipulation
		for i = 0, 79 do
			local fun = bxor
			local offset = 0xCA62C1D6

			if i <= 19 then
				fun = bternary
				offset = 0x5A827999

			elseif i <= 39 then
				offset = 0x6ED9EBA1

			elseif i <= 59 then
				fun = bmajority
				offset = 0x8F1BBCDC

			end

			local tmp = _h4
			offset = offset + fun(_h1, _h2, _h3)
			
			_h4 = _h3
			_h3 = _h2
			_h2 = brol(_h1, 30)
			_h1 = _h0
			_h0 = (buf[i] + brol(_h0, 5) + tmp + offset) % 4294967296
		end
		
		-- Update final hash with chunk hash
		h0 = (h0 + _h0) % 4294967296
		h1 = (h1 + _h1) % 4294967296
		h2 = (h2 + _h2) % 4294967296
		h3 = (h3 + _h3) % 4294967296
		h4 = (h4 + _h4) % 4294967296
	end

	local output = {}
	for i, val in ipairs({ h0, h1, h2, h3, h4 }) do
		for j, byte in ipairs({ splitU32(val) }) do
			output[(i - 1) * 4 + j] = byte
		end
	end

	-- Debug output
	-- local bytes = {}
	-- for _, byte in ipairs(output) do
	-- 	table.insert(bytes, string.format("%02x", byte))
	-- end
	-- print(table.concat(bytes))
	-- print(string.format("%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4))

	-- Output is an array of 20 bytes
	return output
end

-- Base64 encode an array of bytes
function module.encode(bytearr)
	local idx = 0		-- Position within byte array
	local offset = 0	-- Bit offset within target byte
	local mask = 0x3F
	local output = {}

	local base64 = {
		"A", "B", "C", "D", "E", "F", "G", "H",
		"I", "J", "K", "L", "M", "N", "O", "P",
		"Q", "R", "S", "T", "U", "V", "W", "X",
		"Y", "Z", "a", "b", "c", "d", "e", "f",
		"g", "h", "i", "j", "k", "l", "m", "n",
		"o", "p", "q", "r", "s", "t", "u", "v",
		"w", "x", "y", "z", "0", "1", "2", "3",
		"4", "5", "6", "7", "8", "9", "+", "/",
	}

	local iter = ipairs(bytearr)
	while idx < #bytearr do
		local lmask = mask << (2 - offset)
		local rmask = (mask << (10 - offset)) & 0xFF
		local _, left = iter(bytearr, idx)
		local _, right = iter(bytearr, idx + 1)
		right = right or 0
		
		local chunk = (left & lmask) >> (2 - offset)
		if offset > 2 then
			chunk = chunk | ((right & rmask) >> (10 - offset))
		end
		
		table.insert(output, base64[chunk + 1])

		offset = offset + 6
		if offset >= 8 then
			offset = offset % 8
			idx = idx + 1
		end
	end
	
	local extra = #bytearr % 3
	table.insert(output, string.rep("=", (3 - extra) % 3))

	return table.concat(output)
end

return module
