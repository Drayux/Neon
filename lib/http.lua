-- >>> http.lua: HTTP server state machine for connection objects

local util = require("lib.util")
local codes = {
	-- Information
	_100 = "CONTINUE",
	_101 = "SWITCHING PROTOCOL",
	_102 = "PROCESSING",
	_103 = "EARLY HINTS",

	-- Success
	_200 = "OK",
	_201 = "CREATED",
	_202 = "ACCEPTED",
	_204 = "NO CONTENT",

	-- Redirection
	_301 = "MOVED PERMANENTLY",
	_304 = "NOT MODIFIED",
	
	-- Request Error
	_400 = "BAD REQUEST",
	_401 = "UNAUTHORIZED",
	_403 = "FORBIDDEN",
	_404 = "NOT FOUND",
	_405 = "METHOD NOT ALLOWED",
	_408 = "REQUEST TIMEOUT",
	_426 = "UPGRADE REQUIRED",
	_429 = "TOO MANY REQUESTS",

	-- Server Error
	_500 = "INTERNAL SERVER ERROR",
	_501 = "NOT IMPLEMENTED",
	_505 = "HTTP VERSION NOT SUPPORTED",
}

-- >> STATE OBJECT <<
local function _newInstance(args)
	if not args then args = {} end
	local inst = {
		protocol = nil,
		version = nil,
		persistent = false,
		upgrade = nil,
		path = args.path,
		commands = args.commands,
		request = {
			method = nil,
			endpoint = nil,
			headers = nil,
			body = nil,
		},
		response = {
			status = 400,
			headers = {},
			body = "",
		},
	}

	return inst
end


-- >> UTILITY <<

-- Opens a file via Lua's IO API
-- If the path doesn't exist, then attempt the provided extension
-- If the path is a directory, open the index instead
-- Returns the file object or nil, and the type
local function _openFile(path, ext)
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

-- Generates the key necessary for Sec-WebSocket-Accept in the server response handshake
local function _wsGenerateAccept(key)
	if not key or key == "" then return nil end

	-- Pre-hash key
	-- TODO: Ensure that the input key has all padding spaces removed
	local accept = key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	local hashed = util.hash(accept)
	return util.encode(hashed)
end

-- >> TRANSITIONS <<

local function initProtocol(conn, inst)
	print("TODO: upgrade/downgrade TLS")
	return "READ"
end

local function parseMessage(conn, inst)
	-- Parse start line
	-- Assume TLS is accounted for (TODO: for now client should only request HTTP unsecure)
	-- NOTE: Match only '\n' as xread is set to CRLF -> LF conversion mode
	local timeout = conn:read("*L")
	if timeout then return nil end
	-- print("buffer: '" .. tostring(conn.buffer) .. "'")
	
	local m, e, v = conn.buffer:match("^(%w+) (%S+) HTTP/(1%.[01])\n$")

	-- Clients can begin a request with an empty line
	if not m then return "READ" end

	-- TODO: Additional request validation checks

	inst.request.method = m
	inst.request.endpoint = e
	inst.version = v

	-- Parse request headers
	-- TODO: Better header handling (some can/cannot have multiple lines, various formats, etc)
	-- ^^Each header should probably be matched to a rule (function) which validates that header specifically
	inst.request.headers = {}
	local header, value = nil, nil
	repeat 
		timeout = conn:read("*l")
		if timeout then return nil end
		header, value = conn.buffer:match("^([^:]+):[ \t]*(.-)[ \t]*$")

		if header then
			-- Error bad request if nil value or header has whitespace before colon
			if not value or header:match(".-[%s]$") then
				conn.message = "Invalid header: '" .. tostring(header) .. "' -> '" .. tostring(value) .. "'"
				return "RES"
			end
			inst.request.headers[header] = value
		end
	until (header == nil)

	return "CMD"
end

-- Upgrade connection, process command, or send file
-- GET -> Send the requested file
-- HEAD -> Stat the requested file
-- POST -> Process a command
local function processRequest(conn, inst)
	local timeout = nil

	-- Handle server/OBS-frontend commands
	if inst.request.method == "POST" then
		if not conn.commands then
			-- Server is not accepting POST
			conn.message = "Server commands not implemented"
			return "RES"
		end

		-- We may expect a body
		local length = tonumber(inst.request.headers["Content-Length"] or 0)
		if length < 0 then
			conn.message = "Invalid content length"
			return "RES"

		elseif length == 0 then inst.request.body = ""
		else
			timeout = conn:read("-" .. length)
			if timeout then return nil end
			inst.request.body = conn.buffer
		end

		-- TODO: Process the body (if necessary)

		-- Process the command
		local command = inst.request.headers["Command"]
		if not command then
			conn.message = "Request absent 'Command' header"
			return "RES" 
		end
		
		-- TODO: processCommand() returns success message/body

		return "RES"
	end 

	-- Upgrade connection only with GET requests
	if inst.request.method == "GET" then
		-- Parse request connection headers
		local connection = inst.request.headers["Connection"]
		local protocols = inst.request.headers["Upgrade"]
		
		local upgrade = false
		if connection then
			for option in (connection .. ","):gmatch("([^,]-)%s*,%s*") do
				if option == "Upgrade" then upgrade = true
				elseif option == "keep-alive" then inst.persistent = true
				end
			end
		end
		
		if upgrade and protocols then
			-- Right now we are checking only for websocket
			local version = nil
			for entry in protocols:gmatch("([^/%s]%S+)%s?") do
				local p, v = entry:match("^([^/]+)/*(.-)$")
				if p == "websocket" then
					version = v
					goto breakupgrade
				end
			end ::breakupgrade::

			-- Server should continue normal operation on the old protocol if absent
			local wsaccept = _wsGenerateAccept(inst.request.headers["Sec-WebSocket-Key"])
			if wsaccept and version then
				inst.upgrade = "websocket"
				inst.response.status = 101

				inst.response.headers["Connection"] = "Upgrade"
				inst.response.headers["Upgrade"] = "websocket"
				inst.response.headers["Sec-WebSocket-Accept"] = wsaccept

				return "RES"
			end
		end
	end

	-- TODO: Check for other method types and set status to 501 or 400
	-- The following is for GET requests (TODO: below also checks for HEAD)

	-- No content if server does not have a serve directory
	if not inst.path then
		inst.response.status = 204
		conn.message = "No serve directory specified"
		return "RES"
	end

	-- TODO: HTML escape code processing
	local endpoint = inst.request.endpoint
	endpoint = endpoint:gsub("/+", "/") -- Fixup duplicated '/'
	endpoint = endpoint:match("^(/[%S]-)/?$") -- Requests may have trailing '/'
	if not endpoint or (endpoint .. "/"):match("/../") then
		-- Don't serve malformed or parent paths: bad request
		return "RES"
	end

	local name = endpoint:match("^.*/(.-)$")
	local n, ext = name:match("(.+)%.(.-)$")
	name = n or name
	
	-- Filter for known extensions
	ext = ext and (
		ext:match("html") or
		ext:match("js") or
		ext:match("css") or
		ext:match("png")
	)

	-- Open requested file
	local file, type = _openFile(inst.path .. endpoint, not ext and "html" or nil)
	if file then
		-- File exists
		inst.response.status = 200
	else
		if type == "DIR" then
			-- Path exists, but there is no content available
			-- TODO: This is where to implement directory indexing
			inst.response.status = 204
		else
			-- Requested file does not exist
			-- TODO: This is where to implement fancy error pages
			inst.response.status = 404
		end
		return "RES"
	end

	-- No need to read the file if we just want the head
	if inst.request.method == "HEAD" then
		file:close()
		return "RES"
	end

	-- Read the file and deliver it to the client
	-- TODO: Body chunking
	-- inst.response.body = "<!DOCTYPE html><html><body><h1>hello world</h1></body></html>"
	inst.response.body = file:read("*a")
	file:close()

	if not inst.response.body then
		inst.response.status = 500
		conn.message = "Attemped to serve nil body"
		return "RES"
	end

	local headertbl = inst.response.headers
	headertbl["Content-Type"] = "text/html"
	headertbl["Content-Length"] = tostring(#inst.response.body)

	return "RES"
end

-- Sends response data to the client
-- TODO: Make sure this coroutine shuts down properly
-- TODO: HTTP respect keep-alive request
local function resolveRequest(conn, inst)
	local newline = "\r\n"

	-- Send the status line
	local protocol = "HTTP/" .. tostring(inst.version or 1.0)
	local code = tostring(inst.response.status or 400)
	conn.buffer = protocol .. " " .. code .. " " .. codes["_" .. code] .. newline

	-- Send headers
	local headers = ""
	for k, v in pairs(inst.response.headers) do
		headers = headers .. k .. ": " .. v .. newline
	end
	conn.buffer = conn.buffer .. headers .. newline

	-- Send body (if present)
	if inst.response.body and (#inst.response.body > 0) then 
		conn.buffer = conn.buffer .. inst.response.body .. newline
	end

	local timeout = conn:send() -- Send the buffer all at once
	if timeout then return nil end
	
	-- Websocket upgrade
	if inst.upgrade == "websocket" then
		conn:swap("websocket", "START")
	end

	-- Connection "keep-alive"
	-- TODO: Consider adding option if this should be respected
	if inst.persistent and conn.expiration then
		conn.expiration = util.time() + conn.lifetime
		inst.persistent = false
		return "READ"
	end

	return "END"
end

-- local function closeConnection(conn, inst)
-- 	conn:shutdown()
-- 	return nil
-- end


-- >> INTERRUPTS <<

-- Checks for connection state and sets a new target
local function handleTimeout(conn, inst)
	conn.message = "Connection timed out (handler)"
	conn.interrupt = "END"
end

-- Close the connection gracefully
local function handleClose(conn, inst)
	conn.message = "Manual shutdown (handler)"
	conn.interrupt = "END"
end


-- >> TRANSITION TABLE <<
local http = {
	INIT = initProtocol,	-- Client/server disambiguation (+TLS negotiation)
	READ = parseMessage,	-- Request parsing
	CMD = processRequest,	-- Server-side processing
	RES = resolveRequest,	-- Send server response
	-- END = closeConnection, -- This can override the end transition

	-- Interrupt routines
	_TIMEOUT = handleTimeout,
	_CLOSE = handleClose,
}

-- Define start/end states for the transition table
setmetatable(http, { __index = function(tbl, key)
	if not key then return nil end

	if key == "START" then
		-- Overrides "INIT" pending TLS support
		return tbl["INIT"]
	end
	
	-- return tbl["END"]
	return nil
end })


-- >> MODULE API <<
local module = {
	instance = _newInstance,
	transitions = function() return http end,
}
return module

