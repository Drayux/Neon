-- >>> debug.lua - Development module with trivial components

local module = {
	name = function() return "DEBUG" end,
	state = function() return {
		-- TODO: Define module state
		-- TODO: Determine how to init stored values
		authentication = nil,
	} end

	-- Integrations are one-shot instances that have no network dependencies
	-- > EX: `POST https://twitch.tv/kraken/users HTTP/1.1`
	--- TODO: Should an intergration be able to upgrade into an application??
	integrations = {
		foot = { -- Hypothetcial integration example
			host = "drayux.com",
			endpoint = "feet-pics",
			cache = 100, -- Number of seconds to store a previous result before refetching
			args = { -- Array of parameter/header specificiations
				number_of_toes = {
					type = "number",
					optional = false, -- Can the value be nil
					default = 7,
					stateful = false, -- Should the value be pulled from the module state table
					header = false, -- Should the value be included as a header (or a param)
				},
				clipped_toe_nails = {
					type = "bool",
					optional = true,
					default = false,
					stateful = false,
					header = false,
				},
			},
			payload = function(input, state)
					-- Function to generate a request payload (if necessary)
					-- TODO: This one definitely needs the most re-evaluation
					return nil
				end,
			parse = function(output)
					-- Transform the output string into a useful data structure
					return tonumber(output.sub(3, 7))
				end,
			process = function(parsed, state) -- Can be nil
					-- Take the parsed output and reformats the relevant values (if necessary)
					-- Alternatively this is a good place to update the module state
					return parsed
				end,
		},
	},

	-- Extensions extend the server-side functionality by means of adding new
	--- POST request commands to the local API that call a module-specific
	--- routine, such as an authenticated request (like updating state after a
	--- successful Twitch OAuth login); it may depend upon any number of
	--- integrations
	extensions = {
		-- Module-specific server API
		--- params: Table of parsed parameters that were sent in the request
		--- output: Table of output information (values is unique to the command)
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

	-- Applications are (generally) persistent connections meant to implement
	--- a live *application* presented by the host's API; it may depend upon
	--- any number of integrations
	-- > EX: Twitch IRC chat client
	applications = {
		bare = {
			host = "camjam.com",
			endpoint = "bare-my-cheeks-live",
			protocol = "websocket", -- Target/application protocol
			-- > might need something for init protocol (such as http/https)
			receive = function(data)
					-- Closure for whenever the connection receives data
					-- Return non-nil if foward should be called afterward
				end,
			forward = function(parsed)
					-- If receive is non-nil, call this function to determine if the
					--- data should be sent to the (local) server-side for forwarding
					-- > Returns true/false
					return true
				end,
		},
	},
}

return module
