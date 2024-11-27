local cqcore = require("cqueues")
local cqcond = require("cqueues.condition")
local cqsock = require("cqueues.socket")
local cqsgnl = require("cqueues.signal")

local connection = require("lib.connection")
local util = require("lib.util")


-- Some "unit tests" for http headers
-- local headers = require("lib.http.headers")
-- local _h = headers.new()
-- _h:insert("keep-alive", "application/soap+xml; charset=utf-8; action=\"urn:CreateCredential\"")
-- _h:insert("sec-websocket-key", "dGhlIHNhbXBsZSBub2o5jZQ==")
-- local ret = _h:insert("upgrade", "a_protocol/1, example, another_protocol/2.2")
-- print("items in list: " .. #ret)
-- print(_h:dump()) 
-- local field, content
-- field, content = headers.split("Accept: */*")
-- print(tostring(field), tostring(content))
-- repeat return until true


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

local controller = cqcore.new()
local server = {
	socket = cqsock.listen("127.0.0.1", 1085),
	trigger = cqcond.new(),
	running = false,
	connections = {}, -- Only those where the host operates as a server

	-- These will become script arguments (TODO: port and various integrations)
	timeout = 10,
	rootdir = util.getcwd() .. "/pages",
	logging = true,

	--
	seed = util.seed, -- Function to seed the RNG
	-- seed = function() return 69420 end,
}

-- Run an integration module as a client (TODO)
-- (aka a websocket client to twitch's API....usually)
function server:module(mod)
	-- assert(false, "TODO: server:module - modules should have a consistent format"
	-- 	.. " such that regardless of being a one-shot or loop, the parent server"
	-- 	.. " can retrieve the necessary data. (Likely to be a function callback.)")

	-- local _host = "httpbin.org"
	-- local _port = 443
	local _host = "127.0.0.1"
	local _port = 1085 -- 443
	local sock = cqsock.connect(_host, _port)

	local conn = connection.new(sock, controller, self.timeout)
	table.insert(self.connections, conn)
	conn.num = self.logging and #self.connections or nil

	local args = {
		http = {
			method = "GET",
			endpoint = "/headers",
			host = _host,
			encryption = {},
			headers = {
				connection = "Upgrade",
				upgrade = "websocket",

				-- TODO: (Important) Generate a random websocket accept key with the http headers utility
			},
		},
	}

	conn:run("http", args, self.trigger)
	cqcore.poll()
end

function server:loop()
	-- Init the RNG
	if server.seed then server.seed() end

	self.running = true
	while self.running do

		-- TODO: If max connections, wait for one to close (go to next loop)

		local sock = self.socket:accept(0)
		if sock == nil then
			if self.logging then print("~ Nothing to accept ~\n") end
			cqcore.poll(self.socket, self.trigger)
		
		else
			local conn = connection.new(sock, controller, self.timeout)

			-- TODO: Add connection limit and remove completed instances
			table.insert(self.connections, conn)
			conn.num = self.logging and #self.connections or nil

			-- Args specify functionality for 'guest -> host' data
			local args = {
				http = {
					path = self.rootdir,
					commands = nil,
				},
				websocket = {
					interval = 120, -- Two minutes
				},
			}

			conn:run("http", args, self.trigger)
			cqcore.poll() -- Init the connection before accepting another
		end
	end -- [while self.running]
end

function server:stop()
	if not self.running then return end
	for idx, conn in ipairs(self.connections) do
		-- if conn.status == "WEBSOCKET" then conn:data("closing!") end
		conn:close(self.timeout)
	end

	self.running = false
	self.trigger:signal()
end

-- TODO: Actual arg parsing
local clientMode = (arg[1] == "client")
if clientMode then
	controller:wrap(server.module, server, nil)
	server.running = true
else 
	controller:wrap(server.loop, server)
	controller:wrap(_catchSIGINT, server.stop, server)
end

assert(controller:loop())
print("Server shutdown successful")

