-- >>> http.lua: HTTP server state machine for connection objects

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
local function _newState(args)
	if not args then args = {} end
	local state = {
		protocol = nil,
		version = nil,
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
		message = nil,
	}

	return state
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

-- Reads a file in to the body and sets the appropriate headers
-- TODO: (consider) this could be its own coroutine, relevant for large files
-- Alternatively, only read in so many bytes before sending
-- Note that doing so would also require resource sharing from the OS
local function _serveFile(file, state)
end


-- >> TRANSITIONS <<

local function handleTLS(conn, state)
	print("TODO: upgrade/downgrade TLS")
	return "NEW"
end

local function parseRequest(conn, state)
	-- Parse start line
	-- Assume TLS is accounted for (TODO: for now client should only request HTTP unsecure)
	-- NOTE: Match only '\n' as xread is set to CRLF -> LF conversion mode
	local timeout = conn:receive("*L")
	if timeout then return nil end
	local m, e, v = conn.buffer:match("^(%w+) (%S+) HTTP/(1%.[01])\n$")

	-- Clients can begin a request with an empty line
	if not m then return "NEW" end

	-- TODO: Additional request validation checks

	state.request.method = m
	state.request.endpoint = e
	state.version = v

	-- Parse request headers
	state.request.headers = {}
	local header, value = nil, nil
	repeat 
		timeout = conn:receive("*l")
		if timeout then return nil end
		header, value = conn.buffer:match("^([^:]+):[ \t]*(.-)[ \t]*$")

		if header then
			-- Error bad request if nil value or header has whitespace before colon
			if not value or header:match(".-[%s]$") then
				state.message = "Invalid header: '" .. tostring(header) .. "' -> '" .. tostring(value) .. "'"
				return "RES"
			end
			state.request.headers[header] = value
		end
	until (header == nil)

	return "CMD"
end

-- Upgrade connection, process command, or send file
-- GET -> Send the requested file
-- HEAD -> Stat the requested file
-- POST -> Process a command
local function processRequest(conn, state)
	local timeout = nil

	-- Handle server/OBS-frontend commands
	if state.request.method == "POST" then
		if not conn.commands then
			-- Server is not accepting POST
			state.message = "Server commands not implemented"
			return "RES"
		end

		-- We may expect a body
		local length = tonumber(state.request.headers["Content-Length"] or 0)
		if length < 0 then
			state.message = "Invalid content length"
			return "RES"

		elseif length == 0 then state.request.body = ""
		else
			timeout = conn:receive("-" .. length)
			if timeout then return nil end
			state.request.body = conn.buffer
		end

		-- TODO: Process the body (if necessary)

		-- Process the command
		local command = state.request.headers["Command"]
		if not command then
			state.message = "Request absent 'Command' header"
			return "RES" 
		end
		
		-- TODO: processCommand() returns success message/body

		return "RES"
	end 

	-- Check for websocket upgrade
	local upgrade = state.request.headers["Connection"] == "upgrade"
	local protocols = state.request.headers["Upgrade"]
	
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
		if version then
			print("try to upgrade websocket")

			return "APP"
		end
	end

	-- No content if server does not have a serve directory
	if not state.path then
		state.response.status = 204
		state.message = "No serve directory specified"
		return "RES"
	end

	-- TODO: HTML escape code processing
	local endpoint = state.request.endpoint
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
	local file, type = _openFile(state.path .. endpoint, not ext and "html" or nil)
	if file then
		-- File exists
		state.response.status = 200
	else
		if type == "DIR" then
			-- Path exists, but there is no content available
			-- TODO: This is where to implement directory indexing
			state.response.status = 204
		else
			-- Requested file does not exist
			-- TODO: This is where to implement fancy error pages
			state.response.status = 404
		end
		return "RES"
	end

	-- No need to read the file if we just want the head
	if state.request.method == "HEAD" then
		file:close()
		return "RES"
	end

	-- Read the file and deliver it to the client
	-- TODO: Body chunking
	-- state.response.body = "<!DOCTYPE html><html><body><h1>hello world</h1></body></html>"
	state.response.body = file:read("*a")
	file:close()

	if not state.response.body then
		state.response.status = 500
		state.message = "Attemped to serve nil body"
		return "RES"
	end

	local headertbl = state.response.headers
	headertbl["Content-Type"] = "text/html"
	headertbl["Content-Length"] = tostring(#state.response.body)

	-- TODO: Check for other method types and set status to 501 or 400
	return "RES"
end

-- Sends response data to the client
-- TODO: Make sure this coroutine shuts down properly
-- TODO: HTTP respect keep-alive request
local function resolveRequest(conn, state)
	local newline = "\r\n"

	-- Send the status line
	local protocol = "HTTP/" .. tostring(state.version or 1.0)
	local code = tostring(state.response.status or 400)
	conn:send(protocol .. " " .. code .. " " .. codes["_" .. code] .. newline)

	-- Send headers
	local headers = ""
	for k, v in pairs(state.response.headers) do
		headers = headers .. k .. ": " .. v .. newline
	end
	conn:send(headers .. newline)

	-- Send body (if present)
	if state.response.body and (#state.response.body > 0) then 
		conn:send(state.response.body .. newline)
	end
	
	conn.socket:flush()
	return "END"
end

local function closeConnection(conn, state)
	if not state.message then
		state.message = "Completed without errors"
	end

	conn:shutdown()
	return nil
end


-- >> INTERRUPTS <<

-- Checks for connection state and sets a new target
local function handleTimeout(conn, state)
	state.message = "Connection timed out"
	conn.interrupt = "END"
end

-- Close the connection gracefully
local function handleClose(conn, state)
	state.message = "Connection shutdown"
	conn.interrupt = "END"
end


-- >> TRANSITION TABLE <<
local http = {
	INIT = handleTLS,		-- TLS step
	NEW = parseRequest,		-- Request parsing
	CMD = processRequest,	-- Server-side processing
	RES = resolveRequest,	-- Send server response
	END = closeConnection,

	-- Interrupt routines
	_TIMEOUT = handleTimeout,
	_CLOSE = handleClose,
}

-- Define start/end states for the transition table
setmetatable(http, { __index = function(tbl, key)
	if not key then return nil end

	if key == "START" then
		-- Overrides "INIT" pending TLS support
		return tbl["NEW"]
	end
	
	return tbl["END"]
end })


-- >> MODULE API <<
local module = {
	transitions = function() return http end,
	state = _newState,
}
return module

