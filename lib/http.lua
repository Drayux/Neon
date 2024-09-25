-- >>> http.lua: HTTP server state machine for connection objects

local util = require("lib.util")

-- HTTP status codes
local _codes = {
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

-- Header-specific parsing
local _headers = {
	-- Standardized Common
	["accept"] = nil,
	["connection"] = nil,
	["content-length"] = function(data, content)
		-- Single value only
		if data then return false, data end
		local _, length = pcall(tonumber, content)

		if not length or length < 0 then return false, nil end
		return true, length end,
	["content-type"] = nil,
	["host"] = nil,
	["keep-alive"] = nil,
	["sec-websocket-accept"] = function(data, content)
		-- Single value only
		if data then return false, data end
		if #content == 0 then return false, nil end
		return true, content end,
	["sec-websocket-key"] = function(data, content)
		-- Single value only
		if data then return false, data end
		if #content == 0 then return false, nil end
		return true, content end,
	["upgrade"] = nil,

	-- Standardized Extra (TODO: Unimplemented!)
	-- ["accept-charset"] = function(fields) end,
	-- ["accept-encoding"] = function(fields) end,
	-- ["accept-language"] = function(fields) end,
	-- ["access-control-allow-origin"] = function(fields) end,
	-- ["access-control-request-headers"] = function(fields) end,
	-- ["access-control-request-method"] = function(fields) end,
	-- ["authorization"] = function(fields) end,
	-- ["cache-control"] = function(fields) end,
	-- ["content-encoding"] = function(fields) end,
	-- ["content-language"] = function(fields) end,
	-- ["cookie"] = function(fields) end,
	-- ["date"] = function(fields) end,
	-- ["last-modified"] = function(fields) end,
	-- ["origin"] = function(fields) end,
	-- ["priority"] = function(fields) end,
	-- ["referrer"] = function(fields) end,
	-- ["sec-websocket-extensions"] = function(fields) end,
	-- ["sec-websocket-protocol"] = function(fields) end,
	-- ["sec-websocket-version"] = function(fields) end,
	-- ["transfer-encoding"] = function(fields) end,
	-- ["user-agent"] = function(fields) end,
	-- ["www-authenticate"] = function(fields) end,

	-- Neon-specific
	["command"] = function(fields) end,
}

-- >> STATE OBJECT <<
local function _newInstance(args)
	if not args then args = {} end

	-- Clients will start with their request populated
	-- TODO: Lowercase all request headers!
	local _request = nil
	if args.method then
		_request = {
			endpoint = args.endpoint,
			headers = args.headers or {},
			body = args.body,
			-- status = 400 (server only)
		}
	end
	local _server = not _request

	local inst = {
		-- Behavior
		server = _server, -- Assume server unless a request is populated
		version = nil, -- Might be unnecessary? (unless we want to support 2.0)
		encryption = nil, -- "TLS" otherwise

		-- Client arguments
		method = args.method,

		-- Server arguments
		path = args.path,
		api = args.commands, -- Table of functions to define the API - BE CAREFUL!
		
		-- Connection state
		persistent = false, -- Keep the connection alive
		content = nil, -- Content buffer (TODO: When sending a response, only send a string, not a table)
		length = 0, -- Content length
		action = nil, -- Requested operation
		request = _request,
	}

	return inst
end


-- >> UTILITY <<

-- Splits and validates the fields of a header
-- TODO: Refers to the header table for specific header rules
-- Returns a boolean if header is valid
local function _parseHeader(headers, field, content)
	if not field then return false end

	-- Bad request if a header has a space before the colon
	if field:match("%s$") then return false
	else field = field:lower() end

	local valid = false
	local data = headers[field]
	local rule = _headers[field] or function(d, c)
		-- "Default" operation is to assume a list of comma and/or space-seperated entries
		local _data = d or {}

		-- No change does not invalidate header
		if not c then return true, d end

		-- TODO: Better default; perhaps specify delimiter (comma, semicolon, etc) and/or datatype
		for directive in (c .. "\n"):gmatch("([^%s]-)[,;%s]+") do
			-- TODO: Ensure duplicates are not being added
			table.insert(_data, directive)
		end
		return true, _data
	end

	valid, data = rule(data, content)
	headers[field] = data

	return valid
end

-- Check if a field exists in a header
-- Optionally enable case-sensitivity
local function _searchHeader(headers, key, value, case)
	if type(headers) ~= "table" then return false end
	
	local _header = headers[key:lower()]
	if not _header then return false end

	value = case and value or value:lower()

	for _, field in ipairs(_header) do
		field = case and field or field:lower()
		if field == value then return true end
	end

	return false
end

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
		inst.request = {
			endpoint = nil,
			headers = {},
			body = nil,
			status = 400,
		}

		-- Requested server operation
		-- Serve a file, upgrade to websocket, run a command/commands
		inst.action = {}

	else
		-- Connected as a client
		-- Always default as a client for security (a bad actor could respond to our request with a request of its own, such that we respond with our OAuth token, even though we initalized the connection)

		-- Verify request
		if not inst.request or not inst.request.endpoint then
			-- TODO: Instead transition to the WAIT state
			conn.message = "No endpoint for request"
			return "END"
		end

		-- Verify method
		if inst.method == "GET" or
			inst.method == "POST" or
			inst.method == "HEAD" or
			inst.method == "PUT"
		then -- NOP
		else
			conn.message = "Invalid request method: `" .. tostring(inst.method) .. "`"
			return "END"
		end

		-- Populate common headers
		local headers = inst.request.headers
		if not headers["accept"] then
			headers["accept"] = "*/*"
		end
		-- TODO...
	end

	-- Reset shared state components
	inst.content = {}
	inst.length = #(inst.request.body or "")
	inst.persistent = false

	-- TODO: Flush the buffer on the chance we don't read it all
	-- (Probably needs to move to right before we reply with a keep-alive: true)
	
	-- Check traffic encryption
	if inst.encryption == nil then
		print("TODO: upgrade/downgrade TLS")
	end

	-- Direct state machine according to client/server behavior
	return inst.server and "RECV" or "SEND"
end

-- TODO: Support for HTTP/2
-- ^^State: inst.length was made in consideration of this, but it may be insufficient
local function receive(conn, inst)
	local timeout = false
	inst.content = inst.content or {}

	-- Remaining content has known length
	if inst.length > 0 then
		timeout = conn:read("-" .. tostring(inst.length), "n")
		if timeout then return nil end

		-- if conn.buffer then table.insert(inst.content, conn.buffer) end
		inst.request.body = conn.buffer
		return "PROC"
	end

	-- "Main" HTTP request, read until empty line
	-- NOTE: Match only '\n' as xread is set to CRLF -> LF conversion mode
	local bytes = 0
	repeat
		timeout = conn:read("*l")
		if timeout then return nil end

		bytes = #(conn.buffer or "")
		if bytes > 0 then
			table.insert(inst.content, conn.buffer)
		end

	-- conn.buffer will be nil when the line is empty
	-- until (#inst.content > 0) and (not conn.buffer)
	until bytes == 0
	inst.length = 0 -- Done reading, reset length
	return "PROC"
end

-- local function receiveRequest(conn, inst) -- old implementation
-- 	-- Parse start line
-- 	-- Assume TLS is accounted for (TODO: for now client should only request HTTP unsecure)
-- 	-- NOTE: Match only '\n' as xread is set to CRLF -> LF conversion mode
-- 	local timeout = conn:read("*L")
-- 	if timeout then return nil end
-- 	-- print("buffer: '" .. tostring(conn.buffer) .. "'")
--
-- 	local m, e, v = conn.buffer:match("^(%w+) (%S+) HTTP/(1%.[01])\n$")
--
-- 	-- Clients can begin a request with an empty line
-- 	if not m then return "RECV" end
--
-- 	-- TODO: Additional request validation checks
--
-- 	inst.request.method = m
-- 	inst.request.endpoint = e
-- 	inst.version = v
--
-- 	-- Parse request headers
-- 	-- TODO: Better header handling (some can/cannot have multiple lines, various formats, etc)
-- 	-- ^^Each header should probably be matched to a rule (function) which validates that header specifically
-- 	inst.request.headers = {}
-- 	local header, value = nil, nil
-- 	repeat 
-- 		timeout = conn:read("*l")
-- 		if timeout then return nil end
-- 		header, value = conn.buffer:match("^([^:]+):[ \t]*(.-)[ \t]*$")
--
-- 		if header then
-- 			-- Error bad request if nil value or header has whitespace before colon
-- 			if not value or header:match(".-[%s]$") then
-- 				conn.message = "Invalid header: '" .. tostring(header) .. "' -> '" .. tostring(value) .. "'"
-- 				return "SEND"
-- 			end
-- 			inst.request.headers[header] = value
-- 		end
-- 	until (header == nil)
--
-- 	return "CMD"
-- end

local function process(conn, inst)
	-- TODO: Should we assume that this was called from a valid state?
	-- AKA: inst.content needs to be a table or this will fail
	
	-- Request line
	-- If none, then we are in the "top" of an HTTP request
	-- TODO: Reset this after submitting a request as a client
	if not inst.request.endpoint then
		local _req = inst.content[1]

		-- The first line of an HTTP request may be empty
		-- TODO: Verify if a request should be considered invalid if more than one empty line preceeds it
		if not _req then return "RECV" end

		local matchstr =
			inst.server and "^(%w+) (%S+) HTTP/(1%.[01])$"
			or "^HTTP/(1%.[01]) (%d+)%s*(%a*)"
		local a, b, c = _req:match(matchstr)
		if not (a and b and c) then
			conn.message = "Invalid request/status line"
			return inst.server and "SEND" or "END"
		end

		if inst.server then
			inst.method = a
			inst.request.endpoint = b
			inst.version = c

		else
			-- inst.version = a
			inst.request.status = b

		end

		local field = nil
		local iter, state = ipairs(inst.content)
		for _, line in iter, state, 1 do
			-- Break up the header line
			local _field, content = line:match("^([^:]+):%s*(.-)%s*$")

			-- Header fields may be split across lines
			if _field then field = _field
			else content = line end

			-- Verify and insert the header field data
			local valid = _parseHeader(inst.request.headers, field, content)
			if not valid then
				-- Status defaults to 400: BAD REQUEST
				conn.message = "Invalid header `" .. line .. "`"
				return inst.server and "SEND" or "END"
			end
		end

		-- Check if the request has a body
		-- TODO: This depends on the completion of header-specific validation!
		local length = inst.request.headers["content-length"]
		_, length = pcall(tonumber, length)
		inst.length = length or 0
		
		if inst.length > 0 then return "RECV" end
	end

	-- TODO: Handle the body
	-- else
	--	<call body handler; passed in as server argument akin to the api>
	-- end

	return inst.server and "CMD" or "FIN"
end

local function command(conn, inst)
	local method = inst.method

	-- Handle server/OBS-frontend commands
	if method == "POST" then
		inst.action = "command" -- Response body will be JSON format

		local commands = inst.request.headers["command"]
		local output = {}
		-- inst.content = "{ \"error\": \"" .. message .. "\" }"

		-- Verify server has an API
		if not inst.api then
			output["error"] = "Server commands not implemented"
			conn.message = output["error"]
			goto command_send
		end

		-- Process the command(s)
		if not commands or #commands == 0 then
			output["error"] = "Received POST with no command(s) specified"
			conn.message = output["error"]
			goto command_send
		end
		
		for cmd in commands do
			-- TODO: Command handling
			output[cmd] = "boobies"
		end

		::command_send::
		inst.content = "TODO command output" -- TODO: Table -> JSON
		return "SEND"
	end
	
	-- Check for websocket upgrade
	local headers = inst.request.headers
	if method == "GET" then
		local connection = headers["connection"]
		local upgrade = headers["upgrade"]
		local wskey = headers["sec-websocket-key"]
		local shouldUpgrade = false

		-- Ensure all conditions are met
		if not (connection and upgrade and wskey) then
			goto no_upgrade
		end

		for _, option in ipairs(connection) do
			-- TODO: Consider adding a break, but possibly at the cost of readability
			if option:lower() == "upgrade" then
				shouldUpgrade = true
			end
		end

		-- `Connection: Upgrade` was not in the headers
		if not shouldUpgrade then
			goto no_upgrade
		end

		for _, protocol in ipairs(upgrade) do
			if protocol:lower() == "websocket" then
				inst.action = "upgrade"
				inst.request.status = 101
				return "SEND"
			end
		end
	elseif method == "HEAD"
	then -- NOP
	else
		-- Only HEAD, GET, and POST are supported
		inst.request.status = 405
		conn.message = "Request method unsupported"
		return "SEND"
	end 

	::no_upgrade::

	-- Serve requested endpoint as a file
	-- No content if server does not have a serve directory
	if not inst.path then
		inst.request.status = 204
		conn.message = "No directory to serve"
		return "SEND"
	end

	-- TODO: HTML escape code processing
	local endpoint = inst.request.endpoint
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
	local file, type = _openFile(inst.path .. endpoint, ext or "html")
	if not file then
		if type == "DIR" then
			-- Path exists, but there is no content available
			-- TODO: This is where to implement directory indexing
			inst.request.status = 204
		else
			-- Requested file does not exist
			-- TODO: This is where to implement fancy error pages
			inst.request.status = 404
			conn.message = "Requested file does not exist in serve directory"
		end
		return "SEND"
	end

	inst.request.status = 200 -- The file exists

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
		inst.request.status = 500
		conn.message = "Attemped to serve nil body"
		return "SEND"
	end

	inst.action = "file" -- Response body will (should) be HTML format
	inst.content = content
	inst.length = #content
	return "SEND"
end

-- Upgrade connection, process command, or send file
-- GET -> Send the requested file
-- HEAD -> Stat the requested file
-- POST -> Process a command
-- local function processRequest(conn, inst)
-- 	local timeout = nil
--
-- 	-- Handle server/OBS-frontend commands
-- 	if inst.request.method == "POST" then
-- 		if not conn.commands then
-- 			-- Server is not accepting POST
-- 			conn.message = "Server commands not implemented"
-- 			return "SEND"
-- 		end
--
-- 		-- We may expect a body
-- 		local length = tonumber(inst.request.headers["Content-Length"] or 0)
-- 		if length < 0 then
-- 			conn.message = "Invalid content length"
-- 			return "SEND"
--
-- 		elseif length == 0 then inst.request.body = ""
-- 		else
-- 			timeout = conn:read("-" .. length)
-- 			if timeout then return nil end
-- 			inst.request.body = conn.buffer
-- 		end
--
-- 		-- TODO: Process the body (if necessary)
--
-- 		-- Process the command
-- 		local command = inst.request.headers["Command"]
-- 		if not command then
-- 			conn.message = "Request absent 'Command' header"
-- 			return "SEND" 
-- 		end
--
-- 		-- TODO: processCommand() returns success message/body
--
-- 		return "SEND"
-- 	end 
--
-- 	-- Upgrade connection only with GET requests
-- 	if inst.request.method == "GET" then
-- 		-- Parse request connection headers
-- 		local connection = inst.request.headers["Connection"]
-- 		local protocols = inst.request.headers["Upgrade"]
--
-- 		local upgrade = false
-- 		if connection then
-- 			for option in (connection .. ","):gmatch("([^,]-)%s*,%s*") do
-- 				if option == "Upgrade" then upgrade = true
-- 				elseif option == "keep-alive" then inst.persistent = true
-- 				end
-- 			end
-- 		end
--
-- 		if upgrade and protocols then
-- 			-- Right now we are checking only for websocket
-- 			local version = nil
-- 			for entry in protocols:gmatch("([^/%s]%S+)%s?") do
-- 				local p, v = entry:match("^([^/]+)/*(.-)$")
-- 				if p == "websocket" then
-- 					version = v
-- 					goto breakupgrade
-- 				end
-- 			end ::breakupgrade::
--
-- 			-- Server should continue normal operation on the old protocol if absent
-- 			local wsaccept = _wsGenerateAccept(inst.request.headers["Sec-WebSocket-Key"])
-- 			if wsaccept and version then
-- 				inst.upgrade = "websocket"
-- 				inst.response.status = 101
--
-- 				inst.response.headers["Connection"] = "Upgrade"
-- 				inst.response.headers["Upgrade"] = "websocket"
-- 				inst.response.headers["Sec-WebSocket-Accept"] = wsaccept
--
-- 				return "SEND"
-- 			end
-- 		end
-- 	end
--
-- 	-- TODO: Check for other method types and set status to 501 or 400
-- 	-- The following is for GET requests (TODO: below also checks for HEAD)
--
-- 	-- No content if server does not have a serve directory
-- 	if not inst.path then
-- 		inst.response.status = 204
-- 		conn.message = "No directory to serve"
-- 		return "SEND"
-- 	end
--
-- 	-- TODO: HTML escape code processing
-- 	local endpoint = inst.request.endpoint
-- 	endpoint = endpoint:gsub("/+", "/") -- Fixup duplicated '/'
-- 	endpoint = endpoint:match("^(/[%S]-)/?$") -- Requests may have trailing '/'
-- 	if not endpoint or (endpoint .. "/"):match("/../") then
-- 		-- Don't serve malformed or parent paths: bad request
-- 		return "SEND"
-- 	end
--
-- 	local name = endpoint:match("^.*/(.-)$")
-- 	local n, ext = name:match("(.+)%.(.-)$")
-- 	name = n or name
--
-- 	-- Filter for known extensions
-- 	ext = ext and (
-- 		ext:match("html") or
-- 		ext:match("js") or
-- 		ext:match("css") or
-- 		ext:match("png")
-- 	)
--
-- 	-- Open requested file
-- 	local file, type = _openFile(inst.path .. endpoint, not ext and "html" or nil)
-- 	if file then
-- 		-- File exists
-- 		inst.response.status = 200
-- 	else
-- 		if type == "DIR" then
-- 			-- Path exists, but there is no content available
-- 			-- TODO: This is where to implement directory indexing
-- 			inst.response.status = 204
-- 		else
-- 			-- Requested file does not exist
-- 			-- TODO: This is where to implement fancy error pages
-- 			inst.response.status = 404
-- 		end
-- 		return "SEND"
-- 	end
--
-- 	-- No need to read the file if we just want the head
-- 	if inst.request.method == "HEAD" then
-- 		file:close()
-- 		return "SEND"
-- 	end
--
-- 	-- Read the file and deliver it to the client
-- 	-- TODO: Body chunking
-- 	-- inst.response.body = "<!DOCTYPE html><html><body><h1>hello world</h1></body></html>"
-- 	inst.response.body = file:read("*a")
-- 	file:close()
--
-- 	if not inst.response.body then
-- 		inst.response.status = 500
-- 		conn.message = "Attemped to serve nil body"
-- 		return "SEND"
-- 	end
--
-- 	local headertbl = inst.response.headers
-- 	headertbl["Content-Type"] = "text/html"
-- 	headertbl["Content-Length"] = tostring(#inst.response.body)
--
-- 	return "SEND"
-- end

local function resolve(conn, inst)
	local newline = "\r\n"
	local payload = {}
	local headers = inst.server and {} or inst.request.headers

	local protocol = "HTTP/" .. tostring(inst.version or 1.0)
	if inst.server then
		-- Build the status line
		local code = tostring(inst.request.status or 400)
		table.insert(payload, protocol .. " "
			.. code .. " "
			.. _codes["_" .. code]
			.. newline )

		-- Add relevant headers
		if inst.action == "command" then
			headers["command"] = table.concat(headers["command"], ", ")
		elseif inst.action == "upgrade" then
			-- NOTE: Specifically use inst.request.headers here
			local wsaccept = _wsGenerateAccept(inst.request.headers["sec-websocket-key"])
			headers["connection"] = "Upgrade"
			headers["upgrade"] = "websocket"
			headers["sec-websocket-accept"] = wsaccept
		-- elseif inst.action == "file" then
		end
	else
		-- Build the request line
		table.insert(payload, inst.method .. " "
			.. inst.request.endpoint .. " "
			.. protocol
			.. newline )
	end

	-- Check if a body should be sent
	-- TODO: The check for "string" may now be extraneous
	if (inst.length > 0) and (type(inst.content) == "string") then
		if not headers["content-length"] then
			headers["content-length"] = tostring(inst.length)
		end
		if not headers["content-type"] then
			headers["content-type"] =
				(inst.action == "file") and "text/html" or
				"application/json"
		end
	end
	
	-- Attach headers to payload
	for k, v in pairs(headers) do
		table.insert(payload, k .. ": " .. v .. newline)
	end

	-- Addtional newline to seperate the request and body/end
	table.insert(payload, newline)

	-- Attach body to payload
	if headers["content-type"] then
		table.insert(payload, inst.content .. newline)
	end

	-- Send the payload
	local timeout = conn:send(table.concat(payload))
	if timeout then return nil end

	return inst.server and "FIN" or "RECV"
end

-- Sends response data to the client
-- TODO: Make sure this coroutine shuts down properly
-- TODO: HTTP respect keep-alive request
-- local function resolveRequest(conn, inst)
-- 	local newline = "\r\n"
--
-- 	-- Populate status line on the return buffer
-- 	local protocol = "HTTP/" .. tostring(inst.version or 1.0)
-- 	local code = tostring(inst.response.status or 400)
-- 	conn.buffer = protocol .. " " .. code .. " " .. _codes["_" .. code] .. newline
--
-- 	-- Build response headers
-- 	local headers = ""
-- 	for k, v in pairs(inst.response.headers) do
-- 		headers = headers .. k .. ": " .. v .. newline
-- 	end
-- 	conn.buffer = conn.buffer .. headers .. newline
--
-- 	-- Content body (if present)
-- 	if inst.response.body and (#inst.response.body > 0) then 
-- 		conn.buffer = conn.buffer .. inst.response.body .. newline
-- 	end
--
-- 	local timeout = conn:send() -- Send the buffer all at once
-- 	if timeout then return nil end
--
-- 	-- Websocket upgrade
-- 	if inst.upgrade == "websocket" then
-- 		conn:swap("websocket", "START")
-- 	end
--
-- 	-- Connection "keep-alive"
-- 	-- TODO: Consider adding option if this should be respected
-- 	if inst.persistent and conn.expiration then
-- 		conn.expiration = util.time() + conn.lifetime
-- 		inst.persistent = false
-- 		return "RECV"
-- 	end
--
-- 	return "END"
-- end

local function finalize(conn, inst)
	-- Websocket upgrade
	if inst.action == "upgrade" then
		conn:swap("websocket", "START")
		return nil
	end

	-- Connection "keep-alive"
	-- TODO: Consider adding option if this should be respected
	inst.persistent = inst.persistent or
		(not inst.server) and _searchHeader(inst.request.headers, "connection", "keep-alive")
	if inst.persistent and conn.expiration then
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

