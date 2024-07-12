-- >>> connection.lua: Server/client connection handler

local cqcore = require("cqueues")
local cqcond = require("cqueues.condition")
local cqsock = require("cqueues.socket")

local api = {}
local function _new(s, c, t)
	-- Type checks
	assert(cqcore.type(c) == "controller")
	assert(cqsock.type(s) == "socket")
	local timeout = t or 5

	local obj = {
		-- Coroutine management
		controller = c,
		trigger = cqcond.new(),
		-- TODO: Rough idea for the timeout/keep-alive mechanism
		expiration = cqcore.monotime() + timeout,

		-- State
		type = "server",		-- Alternatively "client"
		protocol = nil,			-- HTTP/HTTPS/WS/WSS
		version = nil,

		-- Request
		method = nil,			-- HEAD, GET, POST
		endpoint = nil,			-- Requested file aka target
		headers = nil,			-- Request headers (table)
		body = nil,				-- Receive/send buffer
		status = 200,			-- HTTP status code
		message = "",			-- POST response/error message

		-- Internals
		socket = s,
		path = nil,
		commands = nil,
		state = 0,
	}

	setmetatable(obj, {__index = api})
	return obj
end


-- >> OBJECT API <<

-- Retrieve any pending data (HTTP CRLF standard)
-- TODO: This may need error/timeout handling
-- NOTE: The current mode translates CRLF -> LF
function api:receive(fmt, mode)
	local data, status = self.socket:recv(fmt, mode)
	while not data do

		-- https://github.com/wahern/cqueues/blob/master/src/socket.lua#L544
		cqcore.poll(self.socket, self.trigger)
		data, status = self.socket:recv(fmt, mode)

	end
	return data
end

-- Send data via the connection
-- TODO: Unsure of how to specify protocol just yet
function api:send(data)
	assert(type(data) == "string")
	self.socket:xwrite(data, "b")
	-- self.socket:send(data, 1, #data, "b")
end

-- Close the connection, respecting its state
function api:close()
	assert(false, "TODO: connection:close()")
end

-- Serve HTTP requests on the connection
-- TODO: Socket readiness check?
function api:serve(p, c)
	if self.type ~= "server" then return end
	self.path = p
	self.commands = c

	-- Create a cqueues-managed coroutine
	self.controller:wrap(function()
		-- Parse the data based upon the connection state
		while true do

			-- New connection
			if self.state == 0 then
				-- TODO
				-- print(self.socket:starttls())
				self.state = 1
			
			elseif self.state == 1 then
				-- TODO: Detect protocol (SSL/not SSL)
				-- self.protocol = "HTTP"

				-- Parse start line
				-- NOTE: Match only '\n' as xread is set to CRLF -> LF conversion mode
				local line = self:receive("*L")
				local m, e, v = line:match("^(%w+) (%S+) HTTP/(1%.[01])\n$")
				
				-- Check that the request is not malformed
				-- Clients can begin the request with an empty line
				if not m then goto continue end
				-- TODO: Additional validation may move to the actual implementation step

				self.method = m
				self.endpoint = e
				self.version = v
				self.headers = {}

				-- Read all headers from the request
				local header, value = nil, nil
				repeat
					line = self:receive("*l") or ""
					header, value = line:match("^([^%s:]+):[ \t]*(.-)[ \t]*$")
					-- TODO: Bad request if header has whitespace between key and colon

					if header then
						self.headers[header] = value
					end
				until (header == nil)
				self.state = 2

			-- Request received, perform server-side processing
			elseif self.state == 2 then
				-- A response will almost always immediately follow
				self.state = 4

				-- NOTE: Server handles limited methods and with restricted functionality
				-- GET -> Retrieve a file
				-- HEAD -> Stat the requested file
				-- POST -> Process a command
				if self.method == "POST" then
					if not self.commands then
						-- Server is not accepting POST
						self.status = 400
						self.message = "Server commands not implemented"
						goto continue
					end

					-- We may expect a body
					local length = tonumber(self.headers["Content-Length"] or 0)
					if length < 0 then
						self.status = 400
						self.message = "Invalid content length"
						goto continue

					elseif length == 0 then self.body = ""
					else self.body = self:receive("-" .. length)
					end

					-- Process the body (if necessary)
					-- TODO: ...

					-- Process the command
					local command = self.headers["Command"]
					if not command then
						self.status = 400
						self.message = "Request absent 'Command' header"
						goto continue
					end
					
					-- TODO: processCommand() returns success message/body

					self.state = 4
					goto continue
				end 

				-- Serve the requested file
				-- TODO: This could be moved to a coroutine
				-- Something like wrap a new function, at the end of file IO, run a trigger for which the outside routine polls
				-- local path = 
				-- local file = io.open()
				self.body = "<!DOCTYPE html>" ..
					"<html>" ..
						"<body>" ..
							"hello world" ..
						"</body>" ..
					"</html>"

			-- Send an HTTP response to the client
			elseif self.state == 4 then
				-- Build the status line
				local code = self.status or 200
				local status = "HTTP/" .. self.version .. " " .. self.status .. " OK" .. "\r\n"
				local headers = "Content-Type: text/html\r\n" ..
					"Content-Length: " .. tostring(#self.body) .. "\r\n"

				print(status .. headers .. "\r\n" .. self.body)
				self:send(status .. headers .. "\r\n" .. self.body)
				
				self.state = 5

			-- Transaction is complete, close connection
			elseif self.state == 5 then
				self.socket:flush()
				self.socket:shutdown("w")

			else return end

			-- Begin next state transition
			::continue::
			cqcore.poll()
		end
	end)
end

-- >> MODULE API <<
local module = {
	new = _new,
}

return module

