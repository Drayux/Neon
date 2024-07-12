-- >>> connection.lua: Server/client connection handler

local cqcore = require("cqueues")
local cqcond = require("cqueues.condition")
local cqsock = require("cqueues.socket")

local api = {}
local function _new(s, c, t)
	-- Type checks
	assert(cqsock.type(s) == "socket")
	assert(cqcore.type(c) == "controller")
	local timeout = t or 5

	local obj = {
		-- Coroutine management
		socket = s,
		controller = c,
		trigger = cqcond.new(),
		-- TODO: Rough idea for the timeout/keep-alive mechanism
		expiration = cqcore.monotime() + timeout,

		-- Functionality
		transitions = nil,
		commands = nil,
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

-- Run the connection state machine
function api:run(state)
	if not state or not self.transitions then return end

	self.controller:wrap(function()
		local tr = "START"
		local op = nil
		while tr do
			print("Conn state: " .. tostring(tr))

			op = self.transitions[tr]
			if not op then return end

			tr = op(self, state)

			::continue::
			cqcore.poll()
		end
		
		print("Connection closed: " .. tostring(state.message))
	end)
end

-- Close the connection, respecting its state
function api:close()
	if not self.socket then return end

	self.socket:shutdown("w")
	self.socket = nil
end


-- >> MODULE API <<
local module = {
	new = _new,
}

return module

