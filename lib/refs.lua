-- >>> refs.lua - Single-instance (static) global state

-- NOTE: The existence of this module at all is....uncertain.
-- > I designed much of the script with the idea of providing "classes" that
-- > could be instantiated before I'd later realized that some would be aided
-- > by remaining as singletons, since there is no point hosting two instances
-- > of the same server that can multiplex its clients anyway.
-- The curse of this is that what this module provides may be best provided by
-- > removing it entirely and instead refactoring the client/server objects.
-- ~ This is still to be officially determined. ~

-- TODO: Consider whether the members should be initialized all at once instead
-- > Answer: Keep it modular such that there is never a cyclic require issue

-- TODO: Add a system where objects can be recreated by means of passing through
-- > the existing one. Whatever is returned will be set into _data, which could
-- > be a new object, or it could be the original with a "cleaned" state

-- Internal reference storage and metadata
local _REFS = {
	controller = {
		_inst = nil,
		description = "Global coroutines controller",
		create = require("cqueues").new,
		-- reset = nil,
	},
	client = {
		_inst = nil,
		description = "Client manager instance which implements functionality for public web applications",
		create = require("lib.client").new
		-- reset = nil,
	},
	server = {
		_inst = nil,
		description = "Server instance that listens for local incoming connections",
		create = require("lib.server").new
		-- reset = nil,
	},
}

-- Create a proxy table to track accesses
-- > Allows the module to be "read-only/self-initializing"
local access = {}
setmetatable(access, {
	__newindex = function(tbl, key, value)
			assert(false, "Invalid write to static data (read-only table)")
		end,

	__index = function(tbl, key)
			local ref = _REFS[key]
			assert(ref ~= nil, "Invalid index for static data:" .. tostring(key))

			if not ref._inst then
				local status, instance = pcall(create)
				if status then
					ref._inst = instance
				else
					-- Currently redundant, placeholder for fallback
				end
			end

			-- Nil may be okay here....but right now it means that I fucked up
			assert(ref._inst, "Could not create singleton instance for " .. key)
			return ref._inst
		end,

	__pairs = function(tbl)
			-- Iterating the refs metadata table has dubious implications
			-- Allow the user to see the available values and nothing more

			-- Create a unique instance of next with a closure around _REFS
			local _next = function(_pxt, _prev)
				local val
				_prev, val = next(_REFS, _prev)

				-- Return just the description instead of the entire entry
				return _prev, val.description
			end

			-- Every 'for-loop' iteration will call: _next(tbl, <previous_key>)
			-- > `nil` is fed as the starting point for an iteration
			return _next, tbl, nil
		end,

	__len = function(tbl)
		return #_REFS end,
})

return access
