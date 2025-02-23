-- >>> server.lua - Top-level server-side connection manager

local cqcore = require("cqueues")
local cqcond = require("cqueues.condition")
local cqsock = require("cqueues.socket")

local connection = require("lib.connection")
local util = require("lib.util")


-- >> SERVER API <<
local api = {
	["cock"] = function(params, output)
			output["message"] = "nice"
			-- return nil
		end,
	["balls"] = function(params, output)
			return "cannot scratch balls sufficiently, try pinch and twist"
		end,
}


-- >> OBJECT METHODS <<
local methods = {}
local function _new(ctrl, args)
	if args == nil then args = {} end

	assert(type(args) == "table")
	assert(cqcore.type(ctrl) == "controller")
	
	local sock = cqsock.listen("127.0.0.1", args.port or 1085)
	local trig = cqcond.new()
	local obj = {
		controller = ctrl, -- Required by lower-level connection objects
		socket = sock,
		trigger = trig,
		seedfn = util.seed, -- Function to seed the RNG `function() return 69420 end`
		api = api,

		-- Script arguments (TODO)
		timeout = args.timeout,
		rootdir = util.getcwd()
			.. "/"
			.. args.directory or "overlay", -- TODO: Consider an assertion
		logging = args.logging or false,

		-- Server operation state
		running = false,
		connections = {}, -- Only those where the host operates as a server
	}

	setmetatable(obj, {__index = methods})
	return obj
end

-- Stop the server (gracefully)
function methods:stop()
	if not self.running then return end
	for idx, conn in ipairs(self.connections) do
		-- if conn.status == "WEBSOCKET" then conn:data("closing!") end
		conn:close(self.timeout)
	end

	self.running = false
	self.trigger:signal()
end

-- Add a new connection from the server socket
function methods:connect()
	-- TODO: If max connections, wait for one to close (go to next loop)
	-- while self.running do ...
	-- instead of the above: cqcore.poll(self.trigger)

	local sock = self.socket:accept(0)
	if sock == nil then
		if self.logging then print("~ Nothing to accept ~\n") end
		cqcore.poll(self.socket, self.trigger)
	
	else
		local conn = connection.new(sock, self.controller, self.timeout)

		-- TODO: Add connection limit and remove completed instances
		table.insert(self.connections, conn)
		conn.num = self.logging and #self.connections or nil

		return conn
	end
end

-- Core connection handling
-- > This should be called within a cqcore:wrap()
function methods:loop()
	if self.seedfn then
		-- Init the RNG
		self.seedfn()
	end

	local connargs = {
		http = {
			path = self.rootdir,
			commands = self.api,
		},
		websocket = {
			interval = 120, -- Two minutes
			callback = print,
		},
	}

	self.running = true
	while self.running do
		local conn = self:connect()
		if conn then
			conn:run("http", connargs, self.trigger)
			cqcore.poll() -- Init the connection before accepting another
		end
	end -- [while self.running]
end


-- >> MODULE API <<
local module = {
	new = _new,
}

return module

