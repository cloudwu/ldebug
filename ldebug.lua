local csock = require "ldebug.socket"
local tconcat = table.concat
local tinsert = table.insert
local srep = string.rep
local type = type
local pairs = pairs
local tostring = tostring
local next = next

local ldebug = {}

local socks_fd = nil
local socks_buffer = ""
local socks_prompt = "debug>"
local debug_env = {}
local debug_cmd = {}
local im_cmd = {}
local stack_frame_base
local enter_im = false
local in_hook = false

setmetatable(debug_env , { __index = _ENV })

local function short_value(root)
	if type(root) ~= "table" then
		if type(root) == "string" then
			return string.format("'%s'", root)
		end
		return tostring(root)
	end
	local cache = {  [root] = "." }
	local function _dump(t, name, depth)
		local temp = {}
		for k, v in ipairs(t) do
			if type(v) == "table" then
				local new_key = string.format("[%d].%s", k,key)
				tinsert(temp,_dump(v,new_key))
			else
				tinsert(temp,tostring(v))
			end
		end
		for k,v in pairs(t) do
			local key
			if type(k) ~= "number" then
				key = tostring(k)
				k = 0
			else
				key = "[" .. k .. "]"
			end
			if  not(k>0 and k<=#t) then
				if cache[v] then
					tinsert(temp,string.format("%s = @%s", key, cache[v]))
				elseif type(v) == "table" and depth < 3 then
					local new_key = name .. "." .. key
					cache[v] = new_key
					tinsert(temp,string.format("%s = { %s }", key, _dump(v,new_key, depth+1)))
				else
					if type(v) == "string" then
						v = string.format("'%s'",v)
					end
					tinsert(temp, string.format("%s = %s", key , tostring(v)))
				end
			end
		end
		return tconcat(temp,", ")
	end
	local v = _dump(root, "", 0)
	if #v > 512 then
		return string.format("{ %s ...}", string.sub(v,1,256))
	else
		return string.format("{ %s }", v)
	end
end

local function tostring_r(root)
	if type(root) ~= "table" then
		return tostring(root)
	end
	local cache = {  [root] = "." }
	local function _dump(t,space,name)
		local temp = {}
		for k,v in pairs(t) do
			local key = tostring(k)
			if cache[v] then
				tinsert(temp,"+" .. key .. " {" .. cache[v].."}")
			elseif type(v) == "table" then
				local new_key = name .. "." .. key
				cache[v] = new_key
				tinsert(temp,"+" .. key .. _dump(v,space .. (next(t,k) and "|" or " " ).. srep(" ",#key),new_key))
			else
				tinsert(temp,"+" .. key .. " [" .. tostring(v).."]")
			end
		end
		return tconcat(temp,"\n"..space)
	end
	return _dump(root, "","")
end

local function reply(r)
	csock.write(socks_fd, tostring_r(r) .. "\n")
	csock.write(socks_fd, socks_prompt)
end

function debug_env.print(...)
	for _,v in ipairs {...} do
		csock.write(socks_fd, tostring_r(v) .. "\t")
	end
end

function debug_cmd.help()
	reply[[
You can enter any valid lua code or enter command below:
	help : show this help messages
	stop : stop the program at one of probe and then enter interactive mode.]]
end
debug_cmd["?"] = debug_cmd.help

function debug_cmd.stop()
	enter_im = true
end

function ldebug.start(host)
	local ip = (host and host.ip) or "127.0.0.1"
	local port = (host and host.port) or 6789
	socks_fd = csock.start(ip , port)
end

local function split()
	local b,e = string.find(socks_buffer, "\n", 1, true)
	if b then
		local b = string.find(socks_buffer, "\r", -b, true) or b
		local ret = string.sub(socks_buffer,1,b-1)
		socks_buffer = string.sub(socks_buffer, e+1)
		return ret
	end
end

function readline()
	local ret = split()
	if ret then
		return ret
	end
	local data = csock.read(socks_fd, socks_prompt)
	if data then
		socks_buffer = socks_buffer .. data
		return split()
	end

	return data
end

local function do_cmd(cmd)
	if debug_cmd[cmd] then
		debug_cmd[cmd]()
	elseif string.byte(cmd) == 61 then
		-- 61 means '='
		local f,err = load("return " .. string.sub(cmd,2), "=console", "t", debug_env)
		if not f then
			reply(err)
		else
			local _, r = pcall(f)
			reply(r)
		end
	else
		local f,err = load(cmd, "=console", "t", debug_env)
		if not f then
			reply(err)
		else
			local ok , r = pcall(f)
			if ok then
				csock.write(socks_fd, socks_prompt)
			else
				reply(r)
			end
		end
	end
end

function im_cmd.h()
	reply [[
s : run step
n : run next
r : run until return
l (level) : show locals at level
p var : print var
c : continue to next probe
h : help message
f : show stack frame
q : quit interactive mode]]
end
im_cmd["?"] = im_cmd.h

function im_cmd.f()
	local index = 1
	local tmp = {}
	while true do
		local info = debug.getinfo(stack_frame_base + index, "Sl")
		if info == nil then
			break
		end
		local source = string.format("[%d] %s:%d",index, info.short_src,info.currentline)
		tinsert(tmp, source)
		index = index + 1
	end
	reply(table.concat(tmp, "\n"))
end

function im_cmd.q()
	return true
end

function im_cmd.c()
	enter_im = true
	return true
end

function im_cmd.l(cmd)
	local level = tonumber(cmd[2]) or 1
	local s = stack_frame_base + level
	local info = debug.getinfo(s, "uf")
	local tmp = {}
	for i = 1, info.nparams do
		local name , value = debug.getlocal(s,i)
		tinsert(tmp, string.format("P %s : %s", name, short_value(value)))
	end
	if info.isvararg then
		local index = -1
		while true do
			local name ,value = debug.getlocal(s,index)
			if name == nil then
				break
			end
			tinsert(tmp, string.format("P [%d] : %s", -index, short_value(value)))
			index = index - 1
		end
	end
	local index = info.nparams + 1
	while true do
		local name ,value = debug.getlocal(s,index)
		if name == nil then
			break
		end
		tinsert(tmp, string.format("L %s : %s", name, short_value(value)))
		index = index + 1
	end
	for i = 1, info.nups do
		local name , value = debug.getupvalue(info.func,i)
		tinsert(tmp, string.format("U %s : %s", name, short_value(value)))
	end

	reply(table.concat(tmp, "\n"))
end

local function find_local(s, key)
	local index = 1
	while true do
		local name ,value = debug.getlocal(s,index)
		if name == nil then
			break
		end
		if name == key then
			return value
		end
		index = index + 1
	end
end

local function find_upvalue(s, key)
	local info = debug.getinfo(s, "f")
	local index = 1
	while true do
		local name ,value = debug.getupvalue(info.func,index)
		if name == nil then
			break
		end
		if name == key then
			return value
		end
		index = index + 1
	end
end

function im_cmd.p(cmd)
	local name = cmd[2]
	local level = tonumber(cmd[3]) or 1
	if name == nil then
		reply("need a var name")
		return
	end
	local base = stack_frame_base + level - 1
	if name == "..." then
		local tmp = {}
		local index = -1
		local s = base + 1
		while true do
			local name ,value = debug.getlocal(s,index)
			if name == nil then
				break
			end
			tinsert(tmp, string.format("[%d] : %s", -index, tostring_r(value)))
			index = index - 1
		end
		reply(table.concat(tmp,"\n"))
		return
	end
	local v = find_local(base + 2, name)
	if v then
		reply(tostring_r(v))
		return
	end
	v = find_upvalue(base + 2, name)
	if v then
		reply(tostring_r(v))
		return
	end
	reply(tostring_r(_ENV[name]))
end

local function dispatch_im()
	local cmd = {}
	while true do
		local line = readline()
		if line then
			local i = 1
			for v in string.gmatch(line, "[^ \t]+") do
				cmd[i] = v
				i = i + 1
			end
			for j = i, #cmd do
				cmd[j] = nil
			end
			local c = cmd[1]
			if c == nil then
				csock.write(socks_fd, socks_prompt)
			elseif im_cmd[c] == nil then
				reply("Invalid command, type ? for help")
			else
				local ok ,err = pcall(im_cmd[c], cmd)
				if not ok then
					reply("Invalid command : " .. err)
				else
					if err then
						break
					end
				end
			end
		else
			csock.yield()
		end
	end
end

function ldebug.probe()
	if enter_im == true then
		debug.sethook()
		enter_im = false
		local info = debug.getinfo(2, "Sl")
		stack_frame_base = 4
		socks_prompt = string.format("%s:%d>",info.short_src,info.currentline)
		csock.write(socks_fd, socks_prompt)
		in_hook = false
		dispatch_im()
		if not enter_im then
			socks_prompt = "debug>"
			reply "The program continue running"
		end
	else
		local line = readline()
		if line then
			do_cmd(line)
		end
	end
end

local stack_depth
local function _hook(mode)
	if stack_depth then
		if mode == "call" or mode == "tail call" then
			stack_depth = stack_depth + 1
		elseif mode == "return" then
			stack_depth = stack_depth - 1
		end
		if stack_depth > 0 then
			return
		end
		stack_depth = nil
	end
	local info = debug.getinfo(2, "Sl")
	stack_frame_base = 4
	socks_prompt = string.format("%s:%d>",info.short_src,info.currentline)
	csock.write(socks_fd, socks_prompt)
	in_hook = true
	dispatch_im()
	if not enter_im then
		debug.sethook()
		enter_im = false
		socks_prompt = "debug>"
		reply "The program continue running"
	end
end

local function debug_hook_step(level)
	debug.sethook(function(mode)
		if mode == "call" then
			level = level+1
		elseif mode == "return" then
			level = level-1
		end
		if level == 0 then
			debug.sethook(_hook, "l")
		end
	end, "cr")
end

function im_cmd.s()
	enter_im = "hook"
	if in_hook then
		debug.sethook(_hook,"l")
	else
		debug_hook_step(6)
	end
	return true
end

local function debug_hook_next(level)
	debug.sethook(function(mode)
		if mode == "call" then
			level = level+1
		elseif mode == "return" then
			level = level-1
		end
		if level == 0 then
			stack_depth = 0
			debug.sethook(_hook, "lcr")
		end
	end, "cr")
end

function im_cmd.n()
	enter_im = "hook"
	if in_hook then
		debug_hook_next(0)
	else
		debug_hook_next(6)
	end
	return true
end

function im_cmd.r()
	enter_im = "hook"
	if in_hook then
		debug_hook_step(1)
	else
		debug_hook_step(7)
	end
	return true
end

return ldebug
