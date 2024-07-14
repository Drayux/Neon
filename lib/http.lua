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
local function newState()
	return {
		protocol = nil,
		version = nil,
		path = nil,
		message = nil,
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

	-- Serve the requested file
	-- TODO: This could be moved to a coroutine
	-- Something like wrap a new function, at the end of file IO, run a trigger for which the outside routine polls
	-- local path = 
	-- local file = io.open()
	state.response.status = 200
	state.response.body = "<!DOCTYPE html>" ..
		"<html>" ..
			"<body>" ..
				"<h1>" ..
					"hello world" ..
				"</h1>" ..
			"</body>" ..
		"</html>"
	
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
	local headertbl = state.response.headers
	headertbl["Content-Type"] = "text/html"
	headertbl["Content-Length"] = tostring(#state.response.body)

	local headers = ""
	for k, v in pairs(state.response.headers) do
		headers = headers .. k .. ": " .. v .. newline
	end
	conn:send(headers .. newline)

	-- Send body (if present)
	if state.response.body and (#state.response.body > 0) then 
		conn:send(state.response.body .. newline)
	end
	
	-- Send final empty line
	conn:send(newline)
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
	state = newState,
}
return module

