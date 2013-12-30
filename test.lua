local ldebug = require "ldebug"

ldebug.start { ip = "127.0.0.1", port = 6789 }
print("telnet 127.0.0.1 6789 to login")

local a = {1,2,3,p={x=1,y=2}}
local b = 1

local function test()
	b = b + 1
end

function f(a,...)
	local i = 0
	while true do
		ldebug.probe()
		i = i + 1
		ldebug.probe()
		test()
	end
end

f(1,2,3)



