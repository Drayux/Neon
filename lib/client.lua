-- >>> client.lua - Top-level client-side connection manager

-- >> OBJECT METHODS <<
local methods = {}
local function _new(controller, serverObj)
	local _data = serverObj and function(data)
		serverObj.message(serverObj, data) -- TODO: Stub
		-- Message is the WIP function call to iterate through the living OBS connection(s)
		--- and forward the parsed application data to them
	end

	local _api = serverObj and function(commands)
		-- TODO: (stub)
		local k, v = commands[1] -- this won't work as expected right now
		serverObj.api[k] = v
	end

	local obj = {
		cbData = _data,
		cbAPI = _api,

		-- TODO: Figure out how the controller should be passed in
		-- controller = serverObj.controller,
		controller = controller,

		modules = {},
		integrations = {}, -- Instances of client connections
		serverapi = {}, -- TODO (dummy): Track loaded server commands so that they can be unloaded
	}

	-- Module loading operation (simliar operation to that of protocol.lua)
	setmetatable(obj.modules, { __index = function(tbl, key)
		if not key or (type(key) ~= "string") then return nil end

		local status, mod = pcall(require, "modules." .. key:lower())
		if type(mod) ~= "table" then
			print(mod)
			return nil
		end

		-- Check name format
		local _, namespace = pcall(mod.module)
		-- if name ~= key:upper() then
		-- 	return nil
		-- end

		-- Module loaded successfully
		-- TODO: Consider adding module namespace here!
		tbl[namespace] = mod
		return mod
	end })

	setmetatable(obj, { __index = methods })
	return obj
end

-- Load a top-level module
function methods:load(module)
	local moduleObj = self.modules[module]
	-- todo add integrations to self.integrations
	self.integrations["test"] = moduleObj.integrations["httpbin"]
	-- todo add server api to self.serverapi
	return moduleObj
end

-- Unload a top-level module
-- > Remove server API calls, etc. (TODO documentation)
function methods:unload(module)
end

-- Submit a request (list) to an endpoint, synchronous return
-- > As we expect a return, connections are not preserved outside of this scope
-- > (Function is likely an overall design helper)
function methods:get(integration)
	-- Prepare the request
	-- Init the connection
	-- Run the state machine
	-- Poll for a response
end

function methods:depend(application, integration)
	-- Stub of a new version of methods:get()
	-- Will return a promise (initialized at function start)
	-- Application will need data from an host API, so it calls this function
	-- This function will check the status of cached data for that integration
	-- From there, it will populate the promise or set a fulfiller routine (to be processed later)
	-- Then we return the promise
	-- [This allows the module to kick off multiple depends before it yields]
	-- [Said routine is likely to follow in processing, which runs the (existing) client connection state machine]
end

-- Run a module-provided API integration
--- application: The name of the submodule (aka API integration) to run
function methods:app(application)
	-- local status, conn = pcall(self.integrations["test"])
	local conn = self.integrations["test"](self.controller)
	print(type(conn))
	print("before wait")
	-- conn:wait(function(data) print(data) end)
	local data = conn:wait()
	print("after wait")
	for k, v in pairs(data) do
		print(k, v)
	end
end


-- >> MODULE API <<
local module = {
	new = _new,
}

return module
