-- >>> protocol.lua: "Base" state machine to swap between others

local function load(name)
	local status, ret = pcall(require, "protocols." .. name)

	if type(ret) == "string" then
		print(ret)
		return nil
	end

	if ret and (not ret.instance or not ret.transitions) then return nil end
	return ret
end

-- Table will attempt to lazy-load the protocol state machine if key not present
local _protocols = { }
setmetatable(_protocols, { __index = function(tbl, key)
	if not key or (type(key) ~= "string") then return nil end

	local module = load(key)
	if module then tbl[key] = module end

	return module
end })

-- >> STATE MACHINE: Protcol checker state machine operations <<

-- Swap to a given protocol by name (if provided)
local function initProtocol(conn, inst)
	conn:swap(inst["init"], "START")
	return "CHECK"
end

-- Attempt to detect the protcol from the initial bytes
local function checkProtocol(conn, inst)
	print("todo check protocol")
	return "END"
end

-- Protocol checker state instance
-- Args currently unused for this machine
local function _protocolInstance(args)
	local inst = {
		init = nil,
		bytes = nil,
		offset = 0,
		protocol = nil,
	}

	return inst
end

-- Protocol checker transition table
local function _protocolTransitions()
	local pctt = {
		START = initProtocol,
		CHECK = checkProtocol,
	}

	-- setmetatable(pctt, { __index = function(tbl, key)
	-- 		if not key then return nil end
	-- 		return tbl["END"] end })
		
	return pctt
end


local module = {
	protocols = _protocols,
	instance = _protocolInstance,
	transitions = _protocolTransitions,
}
return module

