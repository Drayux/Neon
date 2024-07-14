-- >>> connection.lua: Server/client connection handler

local cqcore = require("cqueues")
local cqcond = require("cqueues.condition")
local cqsock = require("cqueues.socket")

local api = {}
local function _new(s, c, t)
	-- Type checks
	assert(cqsock.type(s) == "socket")
	assert(cqcore.type(c) == "controller")
	local exp = t and (cqcore.monotime() + t) or nil

	local obj = {
		-- Coroutine management
		socket = s,
		controller = c,
		trigger = cqcond.new(),
		expiration = exp,
		interrupt = nil,		-- Target state after an interrupt routine

		-- Functionality
		state = nil,
		transitions = nil,
		buffer = nil,
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
		if timeout then return true end

		data, status = self.socket:recv(fmt, mode)

	end
	self.buffer = data
	return false
end

-- Send data via the connection
-- TODO: Unsure of how to specify protocol just yet
function api:send(data)
	assert(type(data) == "string")
	self.socket:xwrite(data, "b")
	-- self.socket:send(data, 1, #data, "b")
end

-- Run the connection state machine
function api:run(state, transitions)
	self.state = state or self.state
	self.transitions = transitions or self.transitions
	if not self.state or not self.transitions then return end

	-- Keep-alive/timeout routine
	local transition = "START"
	self.controller:wrap(function()
		while self.expiration do

			-- Connection is closed, stop this routine
			if not transition then return end

			-- The connection lifetime may have been extended
			local timeout = self.expiration - cqcore.monotime()
			if timeout > 0 then
				print("waiting for " .. timeout .. " seconds")
				cqcore.poll(self.trigger, timeout + 0.01) -- +10ms
				goto alive
			end

			-- Run the timeout handler (unless another interrupt is pending)
			if not self.interrupt then
				local handler = self.transitions["_TIMEOUT"]
				pcall(handler, self, self.state)
				self.trigger:signal() -- Stop wating for I/O
			end

			cqcore.poll(self.trigger)

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
			if self.interrupt then
				self.interrupt = nil
				self.trigger:signal() -- Allow interrupts to resume at next poll 
			end

			print("Connection state: " .. tostring(transition))
			local func = self.transitions[transition]
			if not func then return end

			transition = func(self, self.state)
			cqcore.poll()
			
			transition = transition or self.interrupt
		end
		
		print("Connection closed: " .. tostring(self.state.message))
	end)
end

-- Close the connection, respecting its state
-- TODO: Add this possibly as a coroutine, this should check if the socket, state, and/or transitions exist, and then signal to the state machine that the connection should be closed
function api:close(timeout)
	-- Connection already closed
	if not self.socket then return end

	-- Handle this as a state machine interrupt if one exists
	if self.state and self.transitions then
		timeout = timeout or 0

		local handler = self.transitions["_CLOSE"]
		local status, ret = pcall(handler, self, self.state)
		local expiration = cqcore.monotime() + timeout + 0.01

		-- Override the timeout interrupt
		self.state.interrupt = status and ret or self.state.interrupt
		self.expiration = nil

		self.trigger:signal()
		while cqcore.monotime() < expiration do
			-- Run the state machine until we run out of time 
			cqcore.poll()
			if not self.socket then return end
		end
	end

	self:shutdown()
end

-- Close the socket immediately (wrapper for the internal API)
function api:shutdown()
	if not self.socket then return end

	self.socket:shutdown("w")
	self.socket = nil
end


-- >> PROTCOL CHECKER: Optional "base" state machine <<
local function _pcState()
	return {
		buffer = nil,
		offset = 0,
		protocol = nil,
	}
end

local function _pcHandshake(conn, state)
	print("todo check handshake")
end

local function _pcClose(conn, state)
	print("todo close connection (during protocol check)")
end


-- >> MODULE API <<
local module = {
	new = _new,
	server = {
		transitions = function()
			-- Protocol checker transition table 
			local pctt = {
				START = _pcHandshake,
				END = _pcClose,
			}

			setmetatable(pctt, { __index = function(tbl, key)
				if not key then return nil end
				return tbl["END"]
			end })
				
			return pctt end,
		state = _pcState,
	},
}

return module

