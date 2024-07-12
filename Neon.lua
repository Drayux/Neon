local cqcore = require("cqueues")
local cqcond = require("cqueues.condition")
local cqsock = require("cqueues.socket")
local connection = require("lib.connection")

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
			cqcore.poll(self.socket, self.trigger)
		
		else
			self.connections = self.connections + 1
			print("New connection: " .. self.connections)

			local conn = connection.new(sock, controller)
			conn:serve()

		end
	end
end

print("Starting queue controller")
controller:wrap(server.loop, server)
assert(controller:loop())

