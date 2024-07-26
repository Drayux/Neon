-- >>> websocket.lua: Websocket server state machine for connection objects

local util = require("lib.util")

-- >> STATE OBJECT <<
local function _newInstance(args)
	if not args then args = {} end
	local inst = {
		_pending = false,
		_frame = nil,
	}

	return inst
end

-- Send the client an initial opening frame
local function initFrame(conn, inst)
	print("websocket begin!")
	-- cqcore.poll(conn.trigger())
	return "READY"
end

-- Listen for frames from the client
local function listenFrame(conn, inst)
	-- Check if we are in the middle of a frame or not
	if inst._pending then return "FRAME" end
	if inst._frame then return "RES" end

	-- Begin a new frame
	inst._pending = true
	inst._frame = ""

	return "FRAME"
end

-- Retrieve a single frame over the wire
local function readFrame(conn, inst)
	local len = 14
	local header = nil
	local buf = ""
	local payload = nil
	local timeout = nil

	-- Read the frame header, gracefully handling partial reads
	while not header do
		timeout = conn:read("-" .. tostring(len), "n")
		if timeout then return nil end

		if conn.buffer then buf = buf .. conn.buffer end
		len, header = util.wsheader(buf)
	end

	-- Calculate the number of bytes left to read
	buf = buf:sub(len + 1)
	len = header.length - #buf

	timeout = conn:read(tostring(len), "n")
	if timeout then return nil end

	buf = buf .. conn.buffer
	payload = util.wsmask(header.mask, buf)

	inst._frame = inst._frame .. payload
	if header.final then
		inst._pending = false
		return "RES"
	end

	return "READY"
end

-- Perform operation depending on frame data
local function resolveFrame(conn, inst)
	print(inst._frame)
	inst._frame = nil

	return "READY"
end

-- Send the client a final closing frame
local function finalFrame(conn, inst)
	return "END"
end

-- Websocket is due to hear from the connected client
local function handleTimeout(conn, inst)
	conn.message = "Websocket timeout"
	conn.interrupt = "END"
end

-- Close the websocket gracefully (with the proper handshake)
local function handleClose(conn, inst)
	conn.message = "Websocket close"
	conn.interrupt = "END"
end


-- >> TRANSITION TABLE <<
local websocket = {
	INIT = initFrame,
	READY = listenFrame,
	FRAME = readFrame,
	RES = resolveFrame,
	CLOSE = finalFrame,

	-- Interrupt routines
	_TIMEOUT = handleTimeout,
	_CLOSE = handleClose,
}

-- Define transition table start state
setmetatable(websocket, { __index = function(tbl, key)
	if not key then return nil end

	if key == "START" then return tbl["INIT"] end
	return nil
end })


-- >> MODULE API <<
local module = {
	instance = _newInstance,
	transitions = function() return websocket end,
}
return module

