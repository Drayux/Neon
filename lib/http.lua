-- >>> http.lua: Client/server implementations for the HTTP socket protocol

local cqueues = require("cqueues")
local http = {
	socket = require("cqueues.socket"),
	server = nil
}

function http:get(addr)
	local conn = self.socket.connect(addr, 443)
	conn:starttls()

	conn:write("GET / HTTP/1.0\n")
	conn:write("Host: " .. addr .. ":443\n\n")

	for ln in conn:lines() do
		print(ln)
	end
end

function http:serve()
	local server = self.socket.listen("127.0.0.1", 8000)
	local conn = server:clients()()

	for line in conn:lines("*L") do
		if line == "\n" then
			goto exit
		end
		conn:write(line)
	end
	::exit::
	conn:shutdown("w")
	server:close()
end

return http 

