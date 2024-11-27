-- >>> Simple client connection for testing

local cqueues = require("cqueues")
local socket = require("cqueues.socket")
local connection = require("lib.connection")
local http = require("lib.http")

local url = "self-signed.badssl.com"
local sock = socket.connect(url, 443)
local _, status = pcall(sock.starttls, sock)

local controller = cqueues.new()
local conn = connection.new(sock, controller, 5)

-- Overload the send command to test for failures --
-- conn.send = function(_conn, data)
-- 	_conn.socket:write(data)
-- 	return false
-- end
-- ////////////////////////////////////////////// --

local args = {
	method = "GET",
	endpoint = "/",
	host = url,
}
local instance = http.instance(args)
local transitions = http.transitions()
local state = "START"

local function direct()
	local obj, err = sock:checktls()
	sock:write(args.method .. " "
		.. args.endpoint .. " HTTP/1.1\n")
	sock:write("Host: " .. url .. "\n\n")

	for line in sock:lines() do
		print(line)
	end
end

local function machine()
	while true do
		-- print(state)
		local func = transitions[state]
		if not func then return end

		-- Step to the next state transition
		state = func(conn, instance)
	end
end

controller:wrap(direct)
-- controller:wrap(machine)
assert(controller:loop())

