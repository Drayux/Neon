-- >>> util.lua: Connection utility functions

local module = {}

-- Attempt to find the working directory of the script 
function module.getcwd()
	-- TODO: if obslua, then this should be easy?
	
	-- Definitely a hack, but the script shouldn't run unless
	-- we're in the correct working directory to begin with
	local path = io.popen("pwd"):read()
	if path:match("Neon$") then return path end

	return nil
end

return module

