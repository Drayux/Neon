-- >>> server.lua: Skeleton server interface

local cqcore = require("cqueues")
local cqcond = require("cqueues.condition")
local cqsock = require("cqueues.socket")

local server = {
	controller = nil,
	socket = nil,
	running = false,

	monitor = cqcond.new(),
}

-- Prepare the server and create a coroutine
function server:init(ctrl)
	if self.socket ~= nil then return end

	assert(cqcore.type(ctrl) == "controller")
	self.controller = ctrl
	self.socket = cqsock.listen("127.0.0.1", 8000)

	ctrl:wrap(function() self:_serve() end)
end

-- Gracefully stops the server loop if active
function server:stop()
	self.running = false
	return self.monitor:signal()
end

-- Wait for ready or shutdown
-- Returns the ready objects (wrapper for cqueues.poll(...))
function server:_yield()
end

-- Core server operation loop
function server:_serve()
	-- print("aboutta wait")
	-- controller.poll(self.stop)
	-- print("done waiting")
	-- if true then return end
	
	self.running = true
	while self.running do

		local conn = self.socket:accept(0)
		if conn == nil then
			cqcore.poll(self.socket, self.monitor)
			goto continue
		end

		print("connection established")
		conn:write("connected!\n")
		
		local buf = conn:read("*L")
		conn:write("closing!\n")
		print(buf)
		print("done")

		self.running = false

		-- for line in conn:lines("*L") do
		-- 	if line == "\n" then
		-- 		goto close
		-- 	end
		-- 	conn:write(line)
		-- end

		::close::
		conn:flush()
		print("connection terminated")
		conn:shutdown("w")

		::continue::
	end

	print("server closing")

	-- From: https://github.com/daurnimator/lua-http/blob/master/http/websocket.lua#L368
	self.socket:shutdown("w")
	cqcore.poll()
	cqcore.poll()
	self.socket:close()

	self.socket = nil
end

return server

