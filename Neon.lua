local cqcore = require("cqueues")
local cqcond = require("cqueues.condition")
local cqsock = require("cqueues.socket")
local cqsgnl = require("cqueues.signal")

local connection = require("lib.connection")
local http = require("lib.http")

-- local protocols = "websocket ws/1 http3 /3 https/2.4"
-- for p in protocols:gmatch("([^/%s]%S+)%s?") do
-- 	local a, b = p:match("^([^/]+)/*(.-)$")
-- 	print(tostring(a) .. " " .. tostring(b))
-- end
-- if true then return end

local controller = cqcore.new()
local server = {
	socket = cqsock.listen("127.0.0.1", 1085),
	trigger = cqcond.new(),
	running = false,
	timeout = 10,
	connections = {},
}

function server:loop()
	self.running = true
	while self.running do

		local sock = self.socket:accept(0)
		if sock == nil then
			print("Nothing to accept")
			cqcore.poll(self.socket, self.trigger)
		
		else
			local conn = connection.new(sock, controller, self.timeout)

			-- TODO: Add connection limit and remove completed instances
			table.insert(self.connections, conn)
			print("New connection: " .. #self.connections)

			-- Add an HTTP state machine to the connection
			-- TODO: Add serve directory as a parameter to http.state()
			conn.transitions = http.transitions()
			conn.state = http.state()
			-- conn.commands = ...

			conn:run()
		end

	end
end

function server:stop()
	if not self.running then return end
	for idx, conn in ipairs(self.connections) do
		conn:close(self.timeout)
	end

	self.running = false
	self.trigger:signal()
end

controller:wrap(server.loop, server)
controller:wrap(function()
	-- TODO: If parameter, then use the signal handler else stop immediately
	-- ....maybe? standalone vs OBS shutdown sequences look quite different
	cqsgnl.block(cqsgnl.SIGINT)

	local signal = cqsgnl.listen(cqsgnl.SIGINT)
	signal:wait()
	cqsgnl.unblock(cqsgnl.SIGINT)
	
	print("\nBegin manual server shutdown")
	server:stop()
end)

print("Starting queue controller")
assert(controller:loop())
print("Server shutdown successful")

