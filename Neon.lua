local cqcore = require("cqueues")
local cqcond = require("cqueues.condition")
local cqsock = require("cqueues.socket")
local cqsgnl = require("cqueues.signal")

local connection = require("lib.connection")
local http = require("lib.http")
local util = require("lib.util")


local controller = cqcore.new()
local server = {
	socket = cqsock.listen("127.0.0.1", 1085),
	trigger = cqcond.new(),
	running = false,
	connections = {},

	-- These will become script arguments (also the port and various integrations)
	timeout = 10,
	rootdir = util.getcwd() .. "/pages",
}

function server:loop()
	self.running = true
	while self.running do

		-- TODO: If max connections, wait for one to close (go to next loop)

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
			local args = {
				path = self.rootdir,
				commands = nil,
			}

			conn:run(http, args, self.trigger)
			cqcore.poll() -- Init the connection before accepting another
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

