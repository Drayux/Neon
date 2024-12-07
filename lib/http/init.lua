-- >>> (lib.init.lua) lib/http: HTTP server subroutines
local crypto = require("lib.crypto")

-- >> UTILITY MODULE <<
local module = {
	headerTable = require("lib.http.headers"), -- API forward for HTTP module
	statusCode = require("lib.http.status"), -- API forward for HTTP module
}

-- Top-level header parsing
-- > Takes the raw string from the socket and splits the field
-- > from its content
--- linestr: Unprocessed line of the headers block
--- returns the field and content, or nil if the header is invalid
function module.splitHeader(linestr)
	local field = nil

	-- Headers can extend multiple lines if preceeded with a space or tab
	local content = linestr:match("^%s+(.+)$")
	if not content then
		-- New field, first break at the colon
		-- TODO: Determine if we need to handle special characters
		field, content = linestr:match("^(.-):(.*)$")
		if not field
			or field:match("%s")
		then
			-- Invalid header format
			return nil, nil
		end
	end

	-- Trim whitespace from content
	content = content and content:match("^%s*(.-)%s*$")
	return field, content
end

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

-- Generates a client websocket key to request a protocol upgrade
function module.websocketKey()
	local bytearr = {}
	for i = 1, 16 do
		-- TODO: This might be faster if we generate a 16 byte random
		-- > and then iterate the bytes instead
		bytearr[i] = math.random(0x00, 0xFF)
	end

	-- local key = "9RiU0WXT14zl6FTsNlPFXA=="
	local key = crypto.encode(bytearr)
	return key
end

-- Process server-side API commands
--

return module

