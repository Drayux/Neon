-- >>> connection.lua: Server/client connection handler

local cqcore = require("cqueues")
local cqcond = require("cqueues.condition")
local cqsock = require("cqueues.socket")

local api = {}
local function _new(s, c, t)
	-- Type checks
	assert(cqsock.type(s) == "socket")
	assert(cqcore.type(c) == "controller")
	local deadline = t or 5

	local obj = {
		-- Coroutine management
		socket = s,
		controller = c,
		trigger = cqcond.new(),
		expiration = cqcore.monotime() + deadline,
		interrupt = nil,		-- Target state after an interrupt routine

		-- Functionality
		buffer = nil,
		transitions = nil,
		commands = nil,
	}

	setmetatable(obj, {__index = api})
	return obj
end


-- >> OBJECT API <<

-- Retrieve any pending data (HTTP CRLF standard)
-- TODO: This may need error/timeout handling (use the status!)
-- NOTE: The current mode translates CRLF -> LF
function api:receive(fmt, mode)
	self.buffer = nil
	local data, status = self.socket:recv(fmt, mode)
	while not data do

		-- https://github.com/wahern/cqueues/blob/master/src/socket.lua#L544
		local timeout = self.trigger:wait(self.socket)
		if timeout then return self.interrupt end

		data, status = self.socket:recv(fmt, mode)

	end
	self.buffer = data
	return nil
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
	local transition = "START"

	-- Keep-alive/timeout routine
	self.controller:wrap(function()
		while true do

			-- Connection is closed, stop the coroutine
			if not transition then
				print("Stopping timeout routine")
				return
			end

			-- The connection life may have been extended
			local timeout = self.expiration - cqcore.monotime()
			if timeout > 0 then
				print("waiting for " .. timeout .. " seconds")
				cqcore.poll(timeout + 0.01) -- +10ms
				goto alive
			end

			-- Connection has timed out
			state.message = "Connection timed out"
			local op = self.transitions["_TIMEOUT"]
			pcall(op, self, state)

			if self.interrupt then transition = self.interrupt end
			self.trigger:signal()
			cqcore.poll()

		::alive:: end
	end)

	-- Test connection timeout during state transition
	-- Use: `cqcore.poll(dummy)` instead of the empty poll
		-- local dummy = cqcond.new()
		-- self.controller:wrap(function()
		-- 	cqcore.poll(8)
		-- 	dummy:signal()
		-- end)

	-- State machine routine
	self.controller:wrap(function()
		while transition do
			print("Conn state: " .. tostring(transition))

			local op = self.transitions[transition]
			if not op then return end

			-- Consider adding some form of check: if tr (before) is "END" and tr (after) is not nil then leave tr as "END"
			transition = op(self, state)
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

