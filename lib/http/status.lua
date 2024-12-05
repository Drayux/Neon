-- >>> status.lua: Table of HTTP status codes
local _codes = {
	-- Information
	_100 = "CONTINUE",
	_101 = "SWITCHING PROTOCOL",
	_102 = "PROCESSING",
	_103 = "EARLY HINTS",

	-- Success
	_200 = "OK",
	_201 = "CREATED",
	_202 = "ACCEPTED",
	_204 = "NO CONTENT",

	-- Redirection
	_301 = "MOVED PERMANENTLY",
	_304 = "NOT MODIFIED",
	
	-- Request Error
	_400 = "BAD REQUEST",
	_401 = "UNAUTHORIZED",
	_403 = "FORBIDDEN",
	_404 = "NOT FOUND",
	_405 = "METHOD NOT ALLOWED",
	_408 = "REQUEST TIMEOUT",
	_426 = "UPGRADE REQUIRED",
	_429 = "TOO MANY REQUESTS",

	-- Server Error
	_500 = "INTERNAL SERVER ERROR",
	_501 = "NOT IMPLEMENTED",
	_505 = "HTTP VERSION NOT SUPPORTED",
}

setmetatable(_codes, { __newindex = nil })

return function(code)
	local idx = "_" .. tostring(code)
	return _codes[idx]
end
