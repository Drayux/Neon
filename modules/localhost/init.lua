-- >>> localhost.lua - Dummy module for debugging

local cqsock = require("cqueues.socket")
local connection = require("lib.connection")

local function _toes()
	print("toes")
end

local function _httpbin(controller)
	print("running httpbin")

	local _host = "httpbin.org"
	local _port = 443
	local sock = cqsock.connect(_host, _port)

	local conn = connection.new(sock, controller, 10)
	-- table.insert(self.connections, conn)
	-- conn.num = self.logging and #self.connections or nil

	local args = {
		http = {
			method = "GET",
			endpoint = "/json",
			host = _host,
			-- encryption = {},
			headers = {
				-- connection = "Upgrade",
				-- upgrade = "websocket",
			},
		},
		websocket = {
			callback = function(data)
					print("data:", data)
				end,
		},
	}

	-- conn:run("http", args, self.trigger)
	conn:run("http", args)
	-- cqcore.poll()

	return conn
end

local module = {
	module = function() return "DEBUG" end,
	integrations = {
		-- Table of submodules
		toes = _toes,
		httpbin = _httpbin,
	},
	server = {
		-- Module-specific server API
		hamburger = function(params, output)
				output["ingredients"] = {
					"top bun (with sesame seeds)",
					"tomato",
					"beef (not-vegan)",
					"lettuce",
					"bottom bun (no sesame seeds)",
				}
				output["consumed"] = tonumber(params["consumed"]) or 40
			end,
	},
}

return module

