local cqcore = require("cqueues")
local cqsgnl = require("cqueues.signal")

local server = require("lib.server")
local client = require("lib.client")

-- Blocks and handles CTRL-C interrupt signal (for graceful shutdown)
local _catchSIGINT = function(callback, ...)
	-- TODO: If parameter, then use the signal handler else stop immediately
	-- ....maybe? standalone vs OBS shutdown sequences look quite different
	cqsgnl.block(cqsgnl.SIGINT)

	local signal = cqsgnl.listen(cqsgnl.SIGINT)
	signal:wait()
	cqsgnl.unblock(cqsgnl.SIGINT)
	
	print("\nBegin manual server shutdown")
	if type(callback) == "function" then
		callback(...)
	end
end

-- TODO: *Actual* arg parsing
local clientMode = (arg[1] == "client")
local controller = cqcore.new()
if clientMode then
	local cargs = nil -- serverObj
	local clientObj = client.new(controller, cargs)

	clientObj:load("localhost")
	-- TODO: This will need to become the client handler logic
	controller:wrap(clientObj.app, clientObj, "test")

	-- controller:wrap(clientObj.app, server, nil)
else 
	local sargs = {
		timeout = 10,
		directory = "overlay",
		logging = true,
	}
	local serverObj = server.new(controller, sargs)
	
	controller:wrap(serverObj.loop, serverObj)
	controller:wrap(_catchSIGINT, serverObj.stop, serverObj)
end

assert(controller:loop())
print("Server shutdown successful")

