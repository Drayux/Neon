-- >>> http.lua: HTTP server state machine for connection objects

local codes = {
	_200 = "OK",
	_400 = "BAD REQUEST",
	_404 = "NOT FOUND",
}

local function handleTLS(conn, state)
	print("TODO: upgrade/downgrade TLS")
	return "NEW"
end

local function parseRequest(conn, state)
	-- Parse start line
	-- Assume TLS is accounted for (TODO: for now client should only request HTTP unsecure)
	-- NOTE: Match only '\n' as xread is set to CRLF -> LF conversion mode
	local line = conn:receive("*L")
	local m, e, v = line:match("^(%w+) (%S+) HTTP/(1%.[01])\n$")

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
		line = conn:receive("*l") or ""
		header, value = line:match("^([^:]+):[ \t]*(.-)[ \t]*$")

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
	-- TODO: Check for websocket upgrade
	
	-- No websocket, "complete" the instance
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
		else state.request.body = conn:receive("-" .. length)
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

	return "RES"
end

-- Sends response data to the client
-- TODO: Make sure this coroutine shuts down properly
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

local function close(conn, state)
	if not state.message then
		state.message = "Completed without errors"
	end

	conn:close()
	return nil
end

local http = {
	INIT = handleTLS,		-- TLS step
	NEW = parseRequest,		-- Request parsing
	CMD = processRequest,	-- Server-side processing
	APP = nil,	-- Websocket mode
	RES = resolveRequest,	-- Send server response
	END = close,
}

-- Define start/end states for the transition table
setmetatable(http, { __index = function(tbl, key)
	if key == "START" then
		return tbl["NEW"]
	end
	
	return tbl["END"]
end })

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

local module = {
	transitions = function() return http end,
	state = newState,
}
return module

