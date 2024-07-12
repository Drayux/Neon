local cqcore = require("cqueues")
local cqcond = require("cqueues.condition")
local cqsock = require("cqueues.socket")

local connection = require("lib.connection")
local http = require("lib.http")

-- local teststr1 = "Hello"
-- local teststr2 = "Content-Type "
-- print(teststr1:match(".-[^ ]$"))
-- print(teststr2:match(".-[^ ]$"))
-- assert(false)

local controller = cqcore.new()
local server = {
	socket = cqsock.listen("127.0.0.1", 1085),
	trigger = cqcond.new(),
	running = false,
	connections = 0,		-- TODO: Change me to the list of connections
}

function server:loop()
	self.running = true
	while self.running do

		local sock = self.socket:accept(0)
		if sock == nil then
			print("Nothing to accept")
			local ret = cqcore.poll(self.socket, self.trigger)
			-- print("Socket: " .. tostring(ret == self.socket))
			-- print("Trigger: " .. tostring(ret == self.trigger))
		
		else
			self.connections = self.connections + 1
			print("New connection: " .. self.connections)

			local conn = connection.new(sock, controller)

			-- Add an HTTP state machine to the connection
			conn.transitions = http.transitions()
			-- conn.commands = ...

			-- TODO: Add serve directory as a parameter to http.state()
			conn:run(http.state())

		end
	end
end

print("Starting queue controller")
controller:wrap(server.loop, server)
-- controller:wrap(function()
-- 	cqcore.poll(5)
-- 	server.trigger:signal()
-- end)
assert(controller:loop())

