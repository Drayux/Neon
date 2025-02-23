-- >>> websocket.lua: Websocket server state machine for connection objects

local util = require("lib.util")
local opcodes = {
	CONTINUE = 0x0,

	-- Data frames
	TEXT = 0x1,
	BINARY = 0x2,

	-- Control frames
	CLOSE = 0x8,
	PING = 0x9,
	PONG = 0xA,
}

-- >> STATE OBJECT <<
local function _newInstance(args)
	if not args then args = {} end
	local inst = {
		_pending = false,
		_frame = nil,

		pong = true, -- Server has sent an unresolved ping (true if resolved/false if pending)
		client = false, -- Is this a websocket client or server
		interval = args.interval, -- Interval between ping events to the client
		callback = args.callback,
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
	local opcode = byte & 0xF

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

	if len >= 126 then
		local range = 2
		if len < 0x10000 then len = 126
		else
			len = 127
			range = 8
		end

		-- Ensures that ext takes up the full length within the frame
		ext = { }
		for i = 1, range do
			local _byte = (#payload >> (8 * (range - i))) & 0xFF
			table.insert(ext, _byte)
		end
		ext = table.concat(ext)
	end

	-- TODO: No mask should be generated for control frames (Verify this??)
	local key = nil
	if mask and (len > 0) then
		local _k1 = math.random(0, 255) -- MSB
		local _k2 = math.random(0, 255)
		local _k3 = math.random(0, 255)
		local _k4 = math.random(0, 255)

		local intkey = (_k1 << 24)
			| (_k2 << 16)
			| (_k3 << 8)
			|  _k4

		payload = _applyMask(intkey, payload)
		key = string.char(_k1, _k2, _k3, _k4)
	end

	-- Construct the frame string
	local _b1 = 0x80 | opcode -- No fragmentation and no RSV options
	local _b2 = (key and 0x80 or 0) | len
	
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

-- Set up the websocket as a client and begin listening
local function clientInit(conn, inst)
	inst.client = true
	inst.interval = inst.interval or 120

	local timeout = sendFrame(conn, inst, "big booty bitches")
	if timeout then return nil end

	return "READY"
end

-- Send the client an initial opening frame
local function serverInit(conn, inst)
	local timeout = sendFrame(conn, inst, "Hey, you. You're finally awake.")
	if timeout then return nil end

	return "READY"
end

-- Listen for frames on the socket
local function listenFrame(conn, inst)
	-- Check if we are in the middle of a frame or not
	if inst._pending then return "FRAME" end
	if inst._frame then return "RES" end

	-- Begin a new frame
	inst._pending = true
	inst._frame = {
		header = nil,
		payload = "",
	}

	return "FRAME"
end

-- Retrieve a single frame from the socket
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
	-- ...
	inst._frame.header = header
	
	-- Calculate the number of bytes left to read
	buf = buf:sub(len + 1)
	len = header.length - #buf

	timeout = conn:read(tostring(len), "n")
	if timeout then return nil end

	buf = buf .. conn.buffer
	payload = _applyMask(header.mask, buf)

	-- TODO: Consider how to handle binary frames (potentially do this in RES state)
	inst._frame.payload = inst._frame.payload .. payload
	if header.final then
		inst._pending = false
		return "RES"
	end

	return "READY"
end

-- Send a pong frame to the client
local function pingClient(conn, inst)
	-- print("debug: sending ping (264)")
	local timeout = sendFrame(conn, inst, nil, "PING")
	if timeout then return nil end

	inst.pong = false
	conn.expiration = util.time() + conn.lifetime
	return "FRAME"
end

-- Perform operation depending on frame data
local function resolveFrame(conn, inst)
	local opcode = inst._frame.header["opcode"]
	if opcode == opcodes["CLOSE"] then
		-- print("debug: close received (277)")
		conn.expiration = util.time() + conn.lifetime
		return (inst.client and "END") or "CLOSE"

	elseif opcode == opcodes["PING"] then
		-- print("debug: ping received (282)")
		local timeout = sendFrame(conn, inst, nil, "PONG")
		if timeout then return nil end

	elseif opcode == opcodes["PONG"] then
		-- print("debug: pong received (287)")
		conn.expiration = util.time() + (inst.interval or conn.lifetime)
		inst.pong = true

	else
		local callback = inst.callback
			-- or print
		pcall(callback, inst._frame.payload)
	end

	inst._frame = nil
	return "READY"
end

-- Send the client a final closing frame
local function finalFrame(conn, inst)
	conn.expiration = util.time() + conn.lifetime

	local message = nil
	if not inst.client then 
		message = conn.message or "~ And then there was only darkness. ~"
	end

	local timeout = sendFrame(conn, inst, message, "CLOSE")
	if timeout then return nil end
	
	return "END"
end


-- >> INTERRUPTS <<

-- Websocket is due to hear from the connected endpoint
local function handleTimeout(conn, inst)
	-- Just received a frame, delay timeout routine
	if conn.state == "RES" then return end

	-- Ping operation (when the endpoint should send ping frames)
	local running = (conn.state == "READY") or (conn.state == "FRAME")
	if running then
		-- If no pong, then client has probably disconnected
		if not inst.pong then
			conn.message = "Ping not acknowledged"
			conn.interrupt = "CLOSE"
			
		else conn.interrupt = "PING"
		end

		return
	end

	conn.message = "Timeout"

	-- Something hung at the init/close step
	if conn.state == "CLOSE"
		or conn.state == "C_INIT"
		or conn.state == "S_INIT"
	then conn.interrupt = "END"
	else conn.interrupt = "CLOSE"
	end
end

-- Close the websocket gracefully (with the proper handshake)
local function handleClose(conn, inst)
	print("should be closing uwu")
	conn.message = "Websocket closed by " .. (inst.client and "client" or "server")

	local running = (conn.state == "READY")
		or (conn.state == "FRAME")
		or (conn.state == "RES")
	if running then conn.interrupt = "CLOSE"
	else conn.interrupt = "END"
	end
end


-- >> TRANSITION TABLE <<
local websocket = {
	-- Initialization
	C_INIT = clientInit,
	S_INIT = serverInit,

	READY = listenFrame,
	FRAME = readFrame,
	PING = pingClient,
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

	if key == "START" then return tbl["C_INIT"] end
	return nil
end })


-- >> MODULE API <<
local module = {
	instance = _newInstance,
	transitions = function() return websocket end,
}
return module

