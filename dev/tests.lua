-- Some "unit tests" for http headers
-- local headers = require("lib.http.headers")
-- local _h = headers.new()
-- _h:insert("keep-alive", "application/soap+xml; charset=utf-8; action=\"urn:CreateCredential\"")
-- _h:insert("sec-websocket-key", "dGhlIHNhbXBsZSBub2o5jZQ==")
-- local ret = _h:insert("upgrade", "a_protocol/1, example, another_protocol/2.2")
-- print("items in list: " .. #ret)
-- print(_h:dump()) 
-- local field, content
-- field, content = headers.split("Accept: */*")
-- print(tostring(field), tostring(content))

-- local json = require("lib.json")
-- json.test()
-- local data = [[{"hello": "world"}]]
-- local data = [[{
--   "toes": true,
--   "booger": [
--     "app\nle\ns",
--     "carrots",
--     "vegan lea\u0006ther"]
-- }]]
-- local parsed, err = json.decode(data)
-- if err then
-- 	print(err)
-- end
-- if parsed then
-- 	print(json.encode(parsed))
-- end

-- repeat return until true

require("dev/static-data")
require("dev/static-data2")
local _data = require("lib/static")
print(_data["a"])
print(_data["b"])
