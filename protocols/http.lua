-- >>> http.lua: HTTP server state machine for connection objects

local http = require("lib.http")
local json = require("lib.json")
local util = require("lib.util")


-- >> STATE OBJECT <<
local function _newInstance(args)
	if args == nil then args = {} end
	assert(type(args) == "table")

	-- Clients will start with their request populated
	-- TODO: Consider using args.host as the client condition instead
	local _server = not args.method

	local inst = {
		-- Client arguments
		host = args.host,
		wskey = nil, -- Stores a generated websocket key for verification

		-- Server arguments
		path = args.path,
		api = args.commands, -- Table of functions to define the API - BE CAREFUL!

		-- Behavior
		server = _server, -- Assume server unless a request is populated
		version = nil, -- Might be unnecessary? (unless we want to support 2.0)
		encryption = args.encryption, -- TLS context object or nil
		persistent = false, -- Keep the connection alive
		
		-- Connection state
		status = 0,
		length = 0, -- Content length
		request = nil, -- Content buffer (TODO: When sending a response, only send a string, not a table)
		action = nil, -- Requested operation
		pending = false, -- Host is expecting a response (reset request state once true)

		-- Request state
		method = args.method,
		endpoint = args.endpoint,
		headers = args.headers,
		body = args.body,
	}

	return inst
end


-- >> TRANSITIONS <<

	-- TODO: "Wait" state
	-- Role of this state would be to hold an uninitalized client until a request is populated
	-- This could allow for persistent client connections or would keep the connection alive for
	-- multiple requests to the same host
	-- This would require an endpoint (perhaps alternatives) be set, but the request otherwise be
	-- incomplete ; Such states are dropped in the *current* design
	-- This will require a small tweak to the population/verification of the inst.request component

local function initialize(conn, inst)
	-- Verify client/server operation
	if inst.server then
		-- New request, reset state
		inst.method = nil
		inst.endpoint = nil
		inst.headers = nil
		inst.body = nil

		inst.status = 400
		inst.action = nil
		inst.pending = true
	else
		-- Connected as a client
		-- Always default as a client for security (a bad actor could respond to our request with a request of its own, such that we respond with our OAuth token, even though we initalized the connection)

		---- TODO: TRANSITION TO WAIT STATE ----
		-- The previous response has not yet been cleared
		if inst.pending then
			conn.message = "Request was not reset"
			return "END"
		end

		-- Skeleton for client keep-alive
		if not inst.method then
			conn.message = "No request method specified"
			return "END"
		end

		-- Verify request
		if not inst.endpoint then
			conn.message = "No endpoint for request"
			return "END"
		end
		--------------------------

		-- TODO: Verify host (might not be necessary technically)

		-- Verify method
		if inst.method == "GET"
			or inst.method == "POST"
			or inst.method == "HEAD"
			or inst.method == "PUT"
		then -- NOP
		else
			conn.message = "Unsupported request method: `" .. tostring(inst.method) .. "`"
			return "END"
		end

		-- Specify action type (for making API requests)
		-- > TODO: This check could be improved by being moved elsewhere
		if type(inst.body) == "table" then
			-- Assume we want to convert the body into JSON
			inst.action = "command"
		end
	end

	-- Reset shared state components
	inst.request = nil
	inst.wskey = nil -- Client only so this could be moved
	inst.status = inst.server and 400 or 0
	inst.persistent = false

	-- TODO: Drop the read buffer on the chance we didn't read it before
	-- (Probably needs to move to right before a reply with keep-alive: true)
	
	-- Check traffic encryption
	-- TODO: Handle HTTP upgrade redirects
	-- TODO: Server-side does not check for a client hello
	-- > It only matches "<method> <endpoint> <version>" so the connection hangs
	if inst.encryption == nil then
		local context = nil
		if inst.server then
			-- TODO: Server - Obtain an SSL context (read/generate certificate)
			-- > Currently server connections must be upgraded "manually" before starting the state machine

		else
			-- Try to upgrade
			local status, errmsg = pcall(conn.socket.starttls, conn.socket, context)
			if not status then
				conn.message = "Failed to upgrade to TLS"
				return "END"

				-- Alternatively, respawn the connection
				-- > There might be a way to reset the TLS context without completely
				-- > resetting it, but this fallback is not currently in place

				-- conn.sock = cqsock.connect(conn.host, _port)

				-- Further note that enabling the above and then also obeying
				-- HTTP redirects could lead into a two-state recursion condition
				-- when the server redirects to use HTTPS but then the upgrade
				-- to TLS fails.

				-- Yet another potential option is to first "peek" the socket
				-- ourselves, and then pushing back up if we don't see the client
				-- hello byte sequence, see:
				-- https://github.com/daurnimator/lua-http/blob/ee3cf4b4992479b8ebfb39b530694af3bbd1d1eb/http/h1_connection.lua#L214
				-- https://github.com/daurnimator/lua-http/blob/ee3cf4b4992479b8ebfb39b530694af3bbd1d1eb/http/server.lua#L26
			end

			inst.encryption = conn.socket:checktls()
			if not inst.encryption then
				conn.message = "Failed to upgrade to TLS"
				return "END"
			end

			-- TODO: Verify the authenticity of the certificate
			print("TODO: Verify client TLS certificate!")
			-- https://github.com/daurnimator/lua-http/discussions/218
			-- https://github.com/daurnimator/lua-http/blob/ee3cf4b4992479b8ebfb39b530694af3bbd1d1eb/http/tls.lua#L754
		end
	end

	-- Direct state machine according to client/server behavior
	return inst.server and "RECV" or "SEND"
end

-- TODO: Support for HTTP/2
-- ^^State: inst.length was made in consideration of this, but it may be insufficient
local function receive(conn, inst)
	local timeout = false
	local _read = 0

	inst.request = inst.request or {}
	if not inst.pending then
		inst.length = 0

		-- TODO: We might not want to reset method and endpoint
		inst.method = nil
		inst.endpoint = nil
		inst.headers = nil
		inst.body = nil

		-- The connection is now receiving data
		inst.pending = true
	end

	if inst.length ~= 0 then
		-- len > 0: Remaining content has known length
		-- len < 0: Read data until connection completes (HTTP/1.0 thing?)
		local mode = (inst.length < 0) and "*a"
			or ("-" .. tostring(inst.length))

		timeout = conn:read(mode)
		if timeout then return nil end

		if inst.length < 0 then
			inst.length = 0
		else
			_read = #(conn.buffer or "")
			inst.length = inst.length - _read -- Adjust remaining length
		end

		-- TODO: We might want to append to a previous body instance
		inst.body = conn.buffer
		return "PROC"
	end

	-- "Main" HTTP request, read until empty line
	-- NOTE: Match only '\n' as xread is set to CRLF -> LF conversion mode
	repeat
		timeout = conn:read("*l")
		if timeout then return nil end

		_read = #(conn.buffer or "")
		if _read > 0 then
			table.insert(inst.request, conn.buffer)
		end

	until _read == 0
	return "PROC"
end

local function process(conn, inst)
	-- TODO: Should we assume that this was called from a valid state?
	-- AKA: inst.request needs to be a table or this will fail
	
	-- We use inst.endpoint to differentiate the state of the transmission
	-- > TODO: For my state machine refactor, different "states" of the HTTP transmission
	-- > should warrant unique states for the state machine itself
	if (inst.server and inst.endpoint)
		or (not inst.server and inst.status > 0)
	then
		-- TODO: Handle the body (stored in inst.body not inst.request, see receive())
		-- ^^(TODO consider moving that to inst.request since the inst.body should be used for "parsed" data?)
		-- print(inst.body)

		-- <call body handler; passed in as server argument akin to the api>
		return inst.server and "CMD" or "FIN"
	end

	-- The first line of an HTTP request may be empty
	-- TODO: Verify if a request should be considered invalid if more than one empty line preceeds it
	local _req = inst.request[1]
	if not _req then return "RECV" end

	local matchstr =
		inst.server and "^(%w+) (%S+) HTTP/(1%.[01])$"	-- Matches: GET /index.html HTTP/1.0
		or "^HTTP/(1%.[01]) (%d+)%s*(%a*)"				-- Matches: HTTP/1.0 200 OK
	local a, b, c = _req:match(matchstr)
	if not (a and b and c) then
		conn.message = "Invalid request/status line"
		return inst.server and "SEND" or "END"
	end

	if inst.server then
		inst.method = a
		inst.endpoint = b
		inst.version = c

	else
		-- inst.version = a

		-- Status is guaranteed a number from the above match
		inst.status = tonumber(b)
	end

	-- Process request/response headers
	-- We pass in the old value so that we can expand upon a request (for future development)
	inst.headers = http.headerTable(inst.headers)

	local currentField = nil
	local iter, state = ipairs(inst.request)
	for _, line in iter, state, 1 do -- Line 1 is the request line so skip it
		-- TODO: Consider how to handle if headers.split would return nil, nil but
		-- > not indicate an error (would this situation even ever exist?)

		-- Break up the header line
		local field, content = http.splitHeader(line)
		if not content then
			-- Malformed header - Refuse the connection
			-- > Status defaults to 400: BAD REQUEST
			conn.message = "Invalid header `" .. line .. "`"
			return inst.server and "SEND" or "END"
		end

		currentField = field or currentField
		inst.headers:insert(currentField, content)
	end

	-- Check for a body
	local length = nil
	if inst.headers:search("content-length") then
		length = inst.headers:get("content-length")
	end

	-- HTTP server
	if inst.server then
		-- TODO: Consider adding a check for the method
		inst.length = length or 0

	-- HTTP client
	-- > 1XX, 204, and 304 all indicate no content from the server
	elseif (inst.status < 200)
		or (inst.status == 204)
		or (inst.status == 304)
	then
		inst.length = 0

	else
		inst.length = length or -1
	end
	
	if inst.length ~= 0 then return "RECV" end
	return inst.server and "CMD" or "FIN"
end

local function command(conn, inst)
	inst.pending = false
	if not inst.server then
		-- > HTTP client should never reach here
		conn.message = "Invalid transition to command state"
		return "END"
	end

	-- TODO: Ensure that we reset inst.body

	-- Handle server/OBS-frontend commands
	local method = inst.method
	if method == "POST" then
		local params = inst.body
		local error = nil

		inst.body = {}
		inst.action = "command" -- Response will be JSON (expect inst.body to be a table)

		-- Verify the requested endpoint
		-- > Request must be alphabet characters (i.e. no number, no symbols)
		-- TODO: Highly consider creating unique namespaces, divided with a . in the endpoint
		local command = inst.endpoint:match("^/(%a+)/?$")
		if not command then
			inst.status = 400
			error = "Invalid command format: '" 
				.. tostring(inst.endpoint) .. "'"
			conn.message = error
			inst.body["error"] = error
			return "SEND"
		end

		-- Verify that the server has an API
		if not inst.api then
			inst.status = 501
			error = "Server API not configured"
			conn.message = error
			inst.body["error"] = error
			return "SEND"
		end

		-- Get parameters from the client
		if params then
			local contentType = inst.headers:get("content-type")
			if not contentType or contentType["_value"] == "application/json" then
				params, error = json.decode(params)
			end

			if error then
				inst.status = 400
				conn.message = error
				inst.body["error"] = error
				return "SEND"
			end
		end

		-- Core command execution
		local status, message = pcall(inst.api[command:lower()], params, inst.body)
		if status then
			if message then
				inst.status = 400
				inst.body["error"] = message
			else
				inst.status = 200
			end
		else
			inst.status = 501
			error = "Command not supported"
			conn.message = error
			inst.body["error"] = error
		end

		return "SEND"
	end
	
	if method == "GET" then
		local connection = inst.headers:get("connection")
		local upgrade = inst.headers:get("upgrade")
		local wskey = inst.headers:get("sec-websocket-key")
		local shouldUpgrade = false

		-- Check for websocket upgrade
		-- > TODO: Refactor control flow with added header functionality
		if not (connection and upgrade and wskey) then
			goto no_upgrade

		elseif not inst.headers:search("connection", "upgrade") then
			-- `Connection: Upgrade` was not in the headers
			goto no_upgrade
		end

		if inst.headers:search("upgrade", "websocket") then
			inst.status = 101
			inst.action = "upgrade"
			return "SEND"
		end
	elseif method == "HEAD"
	then -- NOP
	else
		-- Only HEAD, GET, and POST are supported
		inst.status = 405
		conn.message = "Request method unsupported"
		return "SEND"
	end 

	::no_upgrade::

	-- Serve requested endpoint as a file
	-- No content if server does not have a serve directory
	if not inst.path then
		inst.status = 204
		conn.message = "No directory to serve"
		return "SEND"
	end

	-- TODO: HTML escape code processing
	local endpoint = inst.endpoint
	endpoint = endpoint:gsub("/+", "/") -- Cleanup duplicated '/'
	endpoint = endpoint:match("^(/[%S]-)/?$") -- Requests may have trailing '/'

	-- Don't serve malformed or parent paths: bad request
	if not endpoint or (endpoint .. "/"):match("/../") then
		conn.message = "Malformed request path"
		return "SEND"
	end

	-- Determine the extension of the requested file
	-- (Otherwise we assume it's .html)
	local filename = endpoint:match("^.*/(.-)$")
	local name, extension = filename:match("(.+)%.(.-)$")
	if extension and #extension > 0 then
		filename = name
	else extension = nil end
	
	-- Filter for known extensions
	-- extension = extension and (
	-- 	extension:match("html") or
	-- 	extension:match("js") or
	-- 	extension:match("css") or
	-- 	extension:match("png")
	-- )

	-- Open the requested file
	local file, type = http.openFile(inst.path .. endpoint, ext or "html")
	if not file then
		if type == "DIR" then
			-- Path exists, but there is no content available
			-- TODO: This is where to implement directory indexing
			inst.status = 204
		else
			-- Requested file does not exist
			-- TODO: This is where to implement fancy error pages
			inst.status = 404
			conn.message = "Requested file does not exist in serve directory"
		end
		return "SEND"
	end

	inst.status = 200 -- The file exists

	-- A HEAD request would now be complete
	if method == "HEAD" then
		file:close()
		return "SEND"
	end

	-- Read the file and deliver it to the client
	-- TODO: Body chunking
	-- local content = "<!DOCTYPE html><html><body><h1>hello world</h1></body></html>"
	local content = file:read("*a")
	file:close()

	if not content then
		inst.status = 500
		conn.message = "Attemped to serve nil body"
		return "SEND"
	end

	inst.action = "file" -- Response body will (should) be HTML format
	inst.body = content
	return "SEND"
end

local function resolve(conn, inst)
	local newline = "\r\n"
	local payload = {
		status = nil,	-- Status line / Request line
		headers = nil,
		content = nil,
	}

	-- Verify state transition
	local valid = true
	repeat -- Use a block for early escape
		if inst.pending then
			valid = false
			break
		end

		if inst.server then
			-- Headers should be initialized
			if not inst.headers then
				valid = false
				break
			end

			local _, htype = pcall(inst.headers.type)
			if htype ~= "headers" then
				valid = false
				break
			end
		end

	until true
	if not valid then
		conn.message = "Invalid transition to resolve state"
		return "END"
	end

	-- Prepare the payload buffer
	local protocol = "HTTP/" .. tostring(inst.version or 1.0)
	if inst.server then
		-- Server-side operation
		local code = tostring(inst.status or 400)
		payload.status = protocol .. " "
			.. code .. " "
			.. http.statusCode(code)
		payload.headers = http.headerTable()

		-- Add relevant headers
		if inst.action == "command" then
			-- TODO: Consider command header expected operation
			-- payload.headers:insert("command", inst.headers:get("command"))

		elseif inst.action == "upgrade" then

		-- elseif inst.action == "file" then
			-- TODO: Body headers
		end
	else
		-- Client-side operation
		payload.status = inst.method .. " "
			.. inst.endpoint .. " "
			.. protocol
		payload.headers = http.headerTable(inst.headers)

		-- Populate common client headers
		if not payload.headers:search("host") then
			payload.headers:insert("host", inst.host)
		end
		if not payload.headers:search("accept") then
			-- TODO: Consider pulling */* from the header-specific API - default()
			payload.headers:insert("accept", "*/*")
		end
		
		-- Websocket upgrade
		-- > TODO: Consider moving this to a client-specific state that
		-- > preceedes SEND and handles client-specific processing like this
		if payload.headers:search("upgrade", "websocket") then
			local wskey = http.websocketKey()
			payload.headers:insert("sec-websocket-key", wskey)

			inst.wskey = wskey -- Save the key for verification later
			inst.action = "upgrade"
		end
	end

	-- Check for protocol upgrade request
	if inst.action == "upgrade" then
		-- TODO: Consider moving Upgrade: websocket since it is implied in the client
		local wsaccept = inst.server
			-- NOTE: Specifically use inst.headers here
			and http.websocketAccept(inst.headers:get("sec-websocket-key"))
			or nil
		payload.headers:insert("sec-websocket-accept", wsaccept)
		payload.headers:insert("connection", "upgrade")
		payload.headers:insert("upgrade", "websocket")

	-- Check if a body should be attached
	-- > Websocket upgrade should not send a body
	elseif inst.body then
		local contentType = "text/plain"
		payload.content = inst.body

		if inst.action == "command" then
			-- Body should be a table
			contentType = "application/json"
			payload.content = json.encode(inst.body)

		elseif inst.action == "file" then
			-- TODO: This may need to be something else for a client
			-- > OR....if the server is sending javascript files
			contentType = "text/html"
		end

		-- Verify that the body is ready to go
		assert(type(payload.content) == "string", "Attempt to send non-string payload")

		-- Insert content type header
		if not payload.headers:search("content-type") then
			payload.headers:insert("content-type", contentType)
			payload.headers:insert("content-type", "charset=utf-8")
		end

		-- Insert content length header
		if not payload.headers:search("content-length") then
			payload.headers:insert("content-length", #payload.content)
		end
	end

	local date = os.date("!%a, %d %b %Y %H:%M:%S GMT", time)
	payload.headers:insert("date", date)
	
	-- Send the payload
	local data = payload.status
		.. newline
		.. payload.headers:dump(newline)
		.. newline
	if payload.content then
		-- Append the body
		data = data
			.. payload.content
			-- .. newline -- TODO: Verify if/when this is needed
	end

	-- Debugging: Print the prepared payload
	-- print("--------")
	-- print(data)
	-- print("--------")

	local timeout = conn:send(data)
	if timeout then return nil end

	return inst.server and "FIN" or "RECV"
end

local function finalize(conn, inst)
	-- Fulfill the connection promise
	-- TODO: For server-side websocket upgrades, the server should set the promise
	--- data to be the "websocket send" closure, else set nothing
	if not inst.server then
		-- TODO: Consider how to handle keep-alive connections
		--- Should the promise data be set as an array? Should we use an array of promises?
		--- Should we wipe the promise and create a new promise on the assumption that
		--- the connection would be continued only after pulling the data from the original
		--- promise?
		conn.promise:set(true, {
			status = inst.status,
			headers = inst.headers,
			body = inst.body
		})
	end

	-- Websocket upgrade
	if inst.action == "upgrade" then
		if not inst.server then
			-- Verify the key received from the server
			-- TODO: This is a candidate for relocation (prior to setting inst.action = upgrade, which would also move)
			local acceptRecv = inst.headers:get("sec-websocket-accept")
			local acceptComp = http.websocketAccept(inst.wskey)
			if not acceptRecv
				or not acceptComp
				or acceptRecv ~= acceptComp
			then
				-- Expected values do not match, terminate the connection
				conn.message = "Failed websocket upgrade: mismatched Sec-WebSocket-Accpet"
				return "END"
			end
		end

		conn:swap("websocket", inst.server and "S_INIT" or "C_INIT")
		return nil -- Swap will set the new start as an interrupt state
	end

	-- Connection "keep-alive"
	-- TODO: Consider adding option if this should be respected
	-- TODO: Check 'keep-alive' header for requested expiration time
	inst.persistent = inst.persistent
		or inst.headers:search("Connection", "keep-alive")
	if (inst.status < 300) and inst.persistent and conn.expiration then
		conn.expiration = util.time() + conn.lifetime
		return "INIT"
	end

	return "END"
end

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
	INIT = initialize, -- Client/server disambiguation (+TLS negotiation)
	RECV = receive,	-- Read data on the socket until term sequence
	PROC = process, -- Parse data received (we might be waiting for more if http 2...hypothetically)
	SEND = resolve,	-- Build request and send to the socket
	FIN = finalize, -- Handle connection lifetime

	-- Server-specific
	CMD = command,	-- Process server command (if needed) (was processRequest before)

	-- Client-specific
	-- REQ = prepare, -- Build client request

	-- Interrupt routines
	-- _DATA = <poll for response buffer (needs to be state-aware)>
	_TIMEOUT = handleTimeout,
	_CLOSE = handleClose,
}

-- Define start/end states for the transition table
setmetatable(http, { __index = function(tbl, key)
	if not key then return nil end

	if key == "START" then
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

