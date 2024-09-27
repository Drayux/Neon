-- >>> connection.lua: Server/client connection handler

local cqcore = require("cqueues")
local cqcond = require("cqueues.condition")
local cqsock = require("cqueues.socket")
local cqerno = require("cqueues.errno")

local protocol = require("lib.protocol")

local api = {}
local function _new(s, c, t)
	-- Type checks
	assert(cqsock.type(s) == "socket")
	assert(cqcore.type(c) == "controller")
	local exp = (t > 0) and (cqcore.monotime() + t) or nil

	local obj = {
		_args = nil,

		-- Logging
		num = nil,
		status = "NEW",
		message = nil,			-- Reason for exit (logging)

		-- Socket
		socket = s,
		buffer = nil,

		-- Coroutine management
		controller = c,
		trigger = cqcond.new(),
		lifetime = t or 0,		-- Duration of a timeout event
		expiration = exp,		-- Absolute timeout time (used in handler)

		-- Functionality (state machine)
		state = nil,			-- Current state transition
		interrupt = nil,		-- Target state after an interrupt
		transitions = nil,		-- Transition table
		instance = nil,			-- State storage (connection instance)
	}

	setmetatable(obj, {__index = api})
	return obj
end


-- >> OBJECT API <<

-- Retrieve any pending data (HTTP CRLF standard)
-- Usage of this function should always check for timeouts
-- NOTE: The current mode translates CRLF -> LF
-- TODO: (consider fixing) If the connection dies, then this "hangs" at the poll
function api:read(fmt, mode)
	self.buffer = nil
	local data, status = self.socket:recv(fmt, mode)
	while not data do
		-- Connection was closed early (no trigger)
		if status == cqerno.EPIPE then return true end

		-- https://github.com/wahern/cqueues/blob/master/src/socket.lua#L544
		local timeout = self.trigger:wait(self.socket)
		if timeout then return true end

		data, status = self.socket:recv(fmt, mode)

	end
	self.buffer = data
	return false
end

-- Send data via the connection
-- Usage of this function should always check for timeouts
function api:send(data)
	if not data then data = self.buffer end
	if not type(data) == "string" then return end

	-- self.buffer = nil

	local sent = 1
	while sent <= #data do
		local idx, status = self.socket:send(data, 1, #data, "fb")
		if status == cqerno.EPIPE then return true end

		sent = sent + idx
		if sent <= #data then
			local timeout = self.trigger:wait(self.socket)
			if timeout then return true end
		end
	end

	local flushed, status = self.socket:flush("n", 0)
	while not flushed do
		if status == cqerno.EPIPE then return true end

		local timeout = self.trigger:wait(self.socket)
		if timeout then return true end

		flushed, status = self.socket:flush("n", 0)
	end
	return false
end

-- Swap state machines, intended for protocol handling
-- TODO: Consider storing a stack of instances alongside `_args`
-- TODO: Consider allowing this to be called as an interrupt (w/ parameter?)
function api:swap(name, interrupt)
	local module = protocol.protocols[name]
	if not module then return false end

	local _, inst = pcall(module.instance, self._args[name])
	local _, ttbl = pcall(module.transitions)

	-- Don't swap if module is invalid/doesn't exist
	if not inst or not ttbl then return false end
	
	self.instance = inst
	self.transitions = ttbl
	self.status = string.upper(name)

	-- There should never be a pending interrupt as this is not one itself
	self.interrupt = interrupt -- or self.interrupt
	
	return true
end

-- Run the connection state machine
-- Machine is the name of the protocol (state machine) that should be used
-- Args should be a table of optional state machine-specific parameters
-- Notify is an optional cqueues.condition that will be signaled when the state machine exits
function api:run(machine, args, notify)
	-- A state machine won't work without a state and transitions
	self._args = args
	self.instance = protocol.instance(args)
	self.transitions = protocol.transitions()
	self.state = "START"

	-- TODO: Try to detect protocol if no module specified (assume server)
	if machine and type(machine) == "string" then
		self.instance["init"] = machine
	end

	-- (Soft) timeout routine
	self.controller:wrap(function()
		while self.socket do
			if not self:timeout() then return end
		end
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
		while self.socket do

			self:log()

			local func = self.transitions[self.state]
			if not func then
				func = function(conn, inst) conn:shutdown() end
			end

			-- Step to the next state transition
			local state = func(self, self.instance)
			self.state = self.interrupt or state

			cqcore.poll()
			self.interrupt = nil -- Resolve interrupts

			-- Alternative idea (skeleton)
			-- This considers the situation where we don't wish to always override
			-- a state transition with an interrupt
				-- -- Only change state if we interrupted I/O
				-- -- (might be unintuitive because we could move directly into I/O again)
				-- self.state = self.state or self.interrupt
				-- -- "Resolve the the interrupt"
				-- if self.state == self.interrupt then self.interrupt = nil end

		end
		
		self:log()
		self.trigger:signal() -- Notify pending interrupt routines
		if cqcond.type(notify) == "condition" then
			notify:signal()
		end
	end)
end

-- Run the connection DATA routine (if available)
function api:data(...)
	if not self.socket then return end

	-- TODO: We may wish to wait until interrupts are resolved
	-- (use cqcore.poll(0) so we can resume right away)

	local routine = self.transitions["_DATA"]
	local status, ret = pcall(routine, self, self.instance, ...)

	return ret
end

-- Check for connection timeout
-- Returns true if routine should be called again (later)
function api:timeout()
	-- Connection has infinite lifetime
	if not self.expiration then return false end

	-- The connection lifetime may have been extended
	local timeout = self.expiration - cqcore.monotime() + 0.01 -- +10ms
	if timeout > 0 then
		self:log(true)
		goto alive
	end

	-- Run the timeout handler (unless another interrupt is pending)
	-- Handler is responsible for setting a new expiration
	timeout = 0
	if not self.interrupt then
		local handler = self.transitions["_TIMEOUT"]
		local status, ret = pcall(handler, self, self.instance)
		if not status then
			-- No handler, close the connection
			self.message = "Connection timed out"
			self:shutdown()
			return false

		elseif self.interrupt then
			-- Only signal timeout to I/O if normal flow should break
			self.trigger:signal()
		end
	end

	-- The connection should be restored or killed
	-- Handler should call self.trigger:notify() if necessary
	::alive::
	cqcore.poll(self.trigger, timeout)
	return true
end

-- Close the connection, respecting its state
function api:close(timeout)
	-- Connection already closed
	if not self.socket then return end

	-- Handle this as a state machine interrupt if one exists
	if self.instance and self.transitions then
		timeout = timeout or self.lifetime

		-- Run the handler, overriding any existing interrupts
		local handler = self.transitions["_CLOSE"]
		local status, ret = pcall(handler, self, self.instance)
		if not status then
			self.message = "Manual shutdown"
			self:shutdown()
			return
		end

		self.interrupt = self.interrupt or "END"
		self.trigger:signal() -- Changed transition, notify I/O

		-- Loop the state machine until socket closed or timeout
		local expiration = cqcore.monotime() + timeout + 0.01
		while cqcore.monotime() < expiration do
			cqcore.poll()
			if not self.socket then return end
		end
	end

	self:shutdown()
end

-- Close the socket immediately
function api:shutdown()
	if not self.socket then return end
	if not self.message then
		self.message = "Completed without errors"
	end

	self.trigger:signal() -- Exit I/O wait
	self.socket:shutdown("w")

	self.status = "CLOSED"
	self.socket = nil
end

-- Helpful debug output
function api:log(timeout)
	-- Disable logging by leaving self.num unset
	if not self.num then return end

	print("CONNECTION // " .. self.num)
	if timeout then
		print(" > Timeout in " .. string.format("%.1f", self.expiration - cqcore.monotime()) .. "s")
		print()
		return
	end

	print(" | Status: " .. self.status)
	
	if self.status == "CLOSED" then print(" > " .. self.message)
	else print(" | State: " .. (self.state or "NONE"))
	end

	print()
end

-- >> MODULE API <<
local module = {
	new = _new,
}

return module

