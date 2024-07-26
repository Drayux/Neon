-- >>> websocket.lua: Websocket server state machine for connection objects

local util = require("lib.util")
local opcodes = {
	CONTINUE = 0x00,

	-- Data frames
	TEXT = 0x01,
	BINARY = 0x02,

	-- Control frames
	CLOSE = 0x08,
	PING = 0x09,
	PONG = 0x0A,
}

-- >> STATE OBJECT <<
local function _newInstance(args)
	if not args then args = {} end
	local inst = {
		_pending = false,
		_frame = nil,

		client = args.client, -- Is this a websocket client or server
	}

	return inst
end


-- >> UTILITY <<

-- Apply the websocket masking/unmasking algorithm
-- https://www.rfc-editor.org/rfc/rfc6455#section-5.3
function _applyMask(key, payload)
	-- Client/server symmetry
	if not key then return payload end

	local transformed = {}
	for idx, byte in util.bytes(payload) do
		local j = (idx - 2) % 4
		local mask = key >> ((3 - j) * 8)
		table.insert(transformed, string.char(byte ~ mask & 0xFF))
	end
	return table.concat(transformed)
end

-- Parse the header of a websocket frame
-- Returns the number of bytes remaining for the header to be valid and nil
-- or the length of the header (in bytes) and a table that represents it
-- https://www.rfc-editor.org/rfc/rfc6455#section-5.2
function _readHeader(data)
	local valid = 2

	-- Minimum valid frame size is 2 bytes
	if not type(data) == "string" then return valid, nil end
	if #data < valid then return valid - #data, nil end

	local len = 0
	local byte = nil
	local next = util.bytes(data)

	-- Read the first two bytes
	_, byte = next()
	local final = (byte & 0x80) > 0
	local rsv = { (byte & 0x40) > 0, (byte & 0x20) > 0, (byte & 0x10) > 0 }
	local opcode = byte & 0x0F

	len, byte = next()
	local maskbit = (byte & 0x80) > 0
	local payloadlen = byte & 0x7F

	-- Check variable header length components
	if payloadlen == 126 then valid = valid + 2
	elseif payloadlen == 127 then valid = valid + 8 end
	if maskbit then valid = valid + 4 end

	-- Header may or may not have enough data to be valid at this point
	if #data < valid then return valid - #data, nil end

	-- Check for extended payload length
	-- Network byte order is big-endian
	local extlen = nil
	if payloadlen == 126 then
		_, msb = next()
		len, lsb = next()

		extlen = (msb << 8) | lsb
	elseif payloadlen == 127 then
		extlen = 0
		for i = 1, 8 do
			len, byte = next()
			extlen = (extlen << 8) | byte
		end
	end

	-- Check for payload mask
	local mask = nil
	if maskbit then
		mask = 0
		for i = 1, 4 do
			len, byte = next()
			mask = (mask << 8) | byte
		end
	end
	
	-- Build the header table
	local header = {
		final = final,
		rsv = rsv,
		opcode = opcode,
		length = extlen or payloadlen,
		mask = mask,
	}

	return len - 1, header
end

-- Construct a basic websocket frame
-- mask -> Boolean if the payload should be masked or not
-- TODO: Could stand to receive extra functionality regarding fragmentation or extensions
function _formatFrame(opcode, mask, payload)
	-- Compute the payload length
	local len = payload and #payload or 0
	local ext = nil

	if len >= 126 and len < 0x10000 then
		local range = 2
		if len < 0x10000 then len = 126
		else
			len = 127
			range = 8
		end

		-- Ensure ext takes up the full byte length
		ext = { }
		for i = 1, 8 do table.insert(ext, (len >> (8 * 8 - i)) & 0xFF) end
		ext = table.concat(ext)
	end

	-- TODO: Generate a masking key
	local key = nil
	if mask and len > 0 then
		print("todo generate mask")
		key = 0x1234
	end
	payload = _applyMask(key, payload)

	-- Construct the frame string
	local _b1 = (opcode & 0x0F) | 0x80 -- No fragmentation and no RSV options
	local _b2 = (mask and 1 or 0) | len
	
	local frame = string.char(_b1, _b2)
	if ext then frame = frame .. ext end
	if key then frame = frame .. key end
	if len > 0 then frame = frame .. payload end

	return frame
end

-- Wrapper function for outside routines to communicate with the socket
-- Returns true on socket timeout
local function sendFrame(conn, inst, payload, opcode)
	local code = opcode
	if type(code) == "string" then code = opcodes[code] end
	code = code or 0x01 -- Text frame by default

	local frame = _formatFrame(code, inst.client, payload)
	return conn:send(frame)
end


-- >> TRANSITIONS <<

-- Send the client an initial opening frame
local function initFrame(conn, inst)
	local timeout = sendFrame(conn, inst, "Hey, you. You're finally awake.")
	if timeout then return nil end

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
		len, header = _readHeader(buf)
	end

	-- TODO: Validate the newly received frame
	
	-- Calculate the number of bytes left to read
	buf = buf:sub(len + 1)
	len = header.length - #buf

	timeout = conn:read(tostring(len), "n")
	if timeout then return nil end

	buf = buf .. conn.buffer
	payload = _applyMask(header.mask, buf)

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
	local timeout = sendFrame(conn, inst, "And then there was only darkness.", "CLOSE")
	if timeout then return nil end
	
	return "END"
end


-- >> INTERRUPTS <<

-- Websocket is due to hear from the connected client
local function handleTimeout(conn, inst)
	conn.message = "Websocket timeout"
	conn.interrupt = "END"
end

-- Close the websocket gracefully (with the proper handshake)
local function handleClose(conn, inst)
	conn.message = "Websocket close"

	local running = conn.state == "READY" or conn.state == "FRAME" or conn.state == "RES"

	if running then conn.interrupt = "CLOSE"
	else conn.interrupt = "END"
	end
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

	-- Protocol routines
	_DATA = sendFrame,
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

