-- >>> connection.lua: Server/client connection handler

local cqcore = require("cqueues")
local cqcond = require("cqueues.condition")
local cqsock = require("cqueues.socket")
local cqerno = require("cqueues.errno")

local api = {}
local function _new(s, c, t)
	-- Type checks
	assert(cqsock.type(s) == "socket")
	assert(cqcore.type(c) == "controller")
	local exp = t and (cqcore.monotime() + t) or nil

	local obj = {
		-- Socket
		socket = s,
		buffer = nil,

		-- Coroutine management
		controller = c,
		trigger = cqcond.new(),
		expiration = exp,

		-- Functionality (state machine)
		state = nil,			-- Current state transition
		interrupt = nil,		-- Target state after an interrupt
		transitions = nil,		-- Transition table
		instance = nil,			-- State storage (connection instance)
		message = nil,			-- Reason for exit (logging)
	}

	setmetatable(obj, {__index = api})
	return obj
end


-- >> OBJECT API <<

-- Retrieve any pending data (HTTP CRLF standard)
-- Usage of this function should always check for timeouts
-- NOTE: The current mode translates CRLF -> LF
-- TODO: (consider fixing) If the connection dies, then this "hangs" at the poll
function api:receive(fmt, mode)
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

	self.buffer = nil

	local sent = 1
	while sent <= #data do
		local idx, status = self.socket:send(data, 1, #data, "b")
		if status == cqerno.EPIPE then return true end

		sent = sent + idx
		if sent <= #data then
			local timeout = self.trigger:wait(self.socket)
			if timeout then return true end
		end
	end

	local flushed = self.socket:flush("n", 0)
	while not flushed do
		local timeout = self.trigger:wait(self.socket)
		if timeout then return true end

		flushed = self.socket:flush("n", 0)
	end
	return false
end

-- Run the connection state machine
-- Args should be a table of optional state machine-specific parameters
-- Notify is an optional cqueues.condition that will be signaled when the state machine exits
function api:run(module, args, notify)
	-- A state machine won't work without a state and transitions
	if not self.instance then
		local status, ret = pcall(module.instance, args)
		if status and ret then self.instance = ret
		else return end
	end
	
	if not self.transitions then
		local status, ret = pcall(module.transitions)
		if status and ret then self.transitions = ret
		else return end
	end

	-- (Soft) timeout routine
	self.state = "START"
	self.controller:wrap(function()
		while self.socket do

			-- Connection has infinite lifetime
			if not self.expiration then return end

			-- The connection lifetime may have been extended
			local timeout = self.expiration - cqcore.monotime() + 0.01 -- +10ms
			if timeout > 0 then
				print(" > Timeout in " .. string.format("%.1f", timeout) .. "s")
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

				elseif self.interrupt then
					-- Only signal timeout to I/O if normal flow should break
					self.trigger:signal()
				end
			end

			-- The connection should be restored or killed
			-- Handler should call self.trigger:notify() if necessary
			::alive::
			cqcore.poll(self.trigger, timeout)

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

			print("Connection state: " .. tostring(self.state))
			local func = self.transitions[self.state]
			if not func then
				func = function(conn, inst) conn:shutdown() end
			end

			-- Step to the next state transition
			self.state = func(self, self.instance)
			cqcore.poll()
			
			-- Alternative solution skeleton
			-- This considers the situation where we don't wish to always override
			-- a state transition with an interrupt
				-- -- Only change state if we interrupted I/O
				-- -- (might be unintuitive because we could move directly into I/O again)
				-- self.state = self.state or self.interrupt
				-- -- "Resolve the the interrupt"
				-- if self.state == self.interrupt then self.interrupt = nil end

			-- Resolve interrupts
			self.state = self.interrupt or self.state
			self.interrupt = nil

		end
		
		print("Connection closed: " .. tostring(self.message))
		self.trigger:signal() -- Notify pending interrupt routines
		if cqcond.type(notify) == "condition" then
			notify:signal()
		end
	end)
end

-- Close the connection, respecting its state
function api:close(timeout)
	-- Connection already closed
	if not self.socket then return end

	-- Handle this as a state machine interrupt if one exists
	if self.instance and self.transitions then
		timeout = timeout or 0

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

-- Close the socket immediately (wrapper for the internal API)
function api:shutdown()
	if not self.socket then return end
	if not self.message then
		self.message = "Completed without errors"
	end

	self.socket:shutdown("w")
	self.socket = nil
end


-- >> PROTCOL CHECKER: Optional "base" state machine <<
function _checkProtocol(conn, inst)
	print("todo check handshake")
	return "END"
end

-- >> MODULE API <<
local module = {
	new = _new,

	server = {
		transitions = function()
			-- Protocol checker transition table 
			local pctt = {
				START = _checkProtocol,
			}

			-- setmetatable(pctt, { __index = function(tbl, key)
			-- 		if not key then return nil end
			-- 		return tbl["END"] end })
				
			return pctt end,

		instance = function()
			return {
				bytes = nil,
				offset = 0,
				protocol = nil,
			} end,
	},
}

return module

