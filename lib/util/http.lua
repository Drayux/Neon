-- >>> (lib.util) http.lua: HTTP server subroutines
local shared = require("lib.util")
local crypto = require("lib.util.crypto")

-- >> UTILITY MODULE <<
local module = {}

-- Opens a file via Lua's IO API
-- If the path doesn't exist, then attempt the provided extension
-- If the path is a directory, open the index instead
-- Returns the file object or nil, and the type
local _openFile ; _openFile = function(path, ext)
	local file = nil
	local status = nil
	local content = nil

	-- NOTE: This will recursively check directories whose children are named "index.html"
	while true do
		-- Check that the file exists
		file = io.open(path, "rb")
		if not file then
			if type(ext) == "string" then
				file = _openFile(path .. "." .. ext, nil)
				return file, status
			end
			return nil, status or "NONE"
		end

		-- Content is nil if file is a directory
		local content = file:read(0)
		if content then
			return file, status or "FILE"
		end

		file:close()
		path = path .. "/index.html"
		ext = nil
		status = "DIR"
	end
end
module.openFile = _openFile

-- Computes the base64-encoded websocket accept key from the input key of a client
function module.websocketAccept(key)
	if not key or key == "" then return nil end

	-- Pre-hash key
	local accept = key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	local hashed = crypto.hash(accept)
	return crypto.encode(hashed)
end

-- TODO: Generates a client websocket key to request a protocol upgrade
function module.websocketKey()
	return "9RiU0WXT14zl6FTsNlPFXA=="
end

return module

