--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BlinkFolder = ReplicatedStorage:WaitForChild("BlinkV2")
local Manifest = require(BlinkFolder:WaitForChild("LegacyManifest"))
local Network = require(script.Parent:WaitForChild("Server"))

local LegacyServer = {}
local eventHandlers: { [string]: { (...any) -> () } } = {}
local functionHandlers: { [string]: (Player, ...any) -> ...any } = {}

local function pack(...)
	return { n = select("#", ...), values = { ... } }
end

local function unpackPayload(payload: any)
	if type(payload) == "table" and type(payload.values) == "table" then
		return table.unpack(payload.values, 1, payload.n or #payload.values)
	end
	if type(payload) == "table" then
		return table.unpack(payload, 1, #payload)
	end
	return payload
end

local function audit(player: Player?, path: string, action: string, reason: string, payload: any?)
	local folder = script.Parent:FindFirstChild("LegacyAudit") or Instance.new("Folder")
	folder.Name = "LegacyAudit"
	folder.Parent = script.Parent
	local record = Instance.new("StringValue")
	record.Name = tostring(os.time()) .. "_" .. string.gsub(path, "[^%w_]", "_")
	record.Value = string.format("%s|%s|%s|%s", action, reason, player and player.UserId or 0, path)
	record:SetAttribute("Action", action)
	record:SetAttribute("Reason", reason)
	record:SetAttribute("Path", path)
	record:SetAttribute("PlayerUserId", player and player.UserId or 0)
	record:SetAttribute("Risk", Manifest.Remotes[path] and Manifest.Remotes[path].Risk or "Unknown")
	record.Parent = folder
	while #folder:GetChildren() > 500 do
		folder:GetChildren()[1]:Destroy()
	end
	warn("[BlinkV2Legacy]", action, reason, player, path)
end

local function dispatch(player: Player, path: string, payload: any)
	local bucket = eventHandlers[path]
	if not bucket or #bucket == 0 then
		audit(player, path, "deny", "no-blink-v2-handler", payload)
		return
	end
	for _, callback in bucket do
		task.spawn(callback, player, unpackPayload(payload))
	end
end

local function dispatchInvoke(player: Player, path: string, payload: any): any
	local callback = functionHandlers[path]
	if not callback then
		audit(player, path, "deny", "no-blink-v2-invoke-handler", payload)
		return { n = 0, values = {} }
	end
	return pack(callback(player, unpackPayload(payload)))
end

local started = false
function LegacyServer.Start()
	if started then
		return
	end
	started = true
	Network.ClientAdminEnvelope.On(dispatch)
	Network.ClientPurchaseEnvelope.On(dispatch)
	Network.ClientBuildEnvelope.On(dispatch)
	Network.ClientModerationEnvelope.On(dispatch)
	Network.ClientCosmeticEnvelope.On(dispatch)
	Network.ServerAdminRequest.On(dispatchInvoke)
end

function LegacyServer.On(path: string, callback: (Player, ...any) -> ())
	eventHandlers[path] = eventHandlers[path] or {}
	table.insert(eventHandlers[path], callback)
	return {
		Disconnect = function()
			local bucket = eventHandlers[path]
			if not bucket then
				return
			end
			local index = table.find(bucket, callback)
			if index then
				table.remove(bucket, index)
			end
		end,
	}
end

function LegacyServer.OnInvoke(path: string, callback: (Player, ...any) -> ...any)
	functionHandlers[path] = callback
end

function LegacyServer.Fire(player: Player, path: string, ...: any)
	local info = Manifest.Remotes[path]
	local payload = pack(...)
	if info and info.Risk == "Cosmetic" then
		Network.ServerCosmeticEnvelope.Fire(player, path, payload)
	else
		Network.ServerAdminEnvelope.Fire(player, path, payload)
	end
end

function LegacyServer.FireAll(path: string, ...: any)
	local payload = pack(...)
	Network.ServerAdminEnvelope.FireAll(path, payload)
end

function LegacyServer.RemoteEvent(path: string)
	return {
		Name = string.match(path, "[^%.]+$") or path,
		ClassName = "RemoteEvent",
		IsA = function(_self, className: string)
			return className == "RemoteEvent" or className == "Instance"
		end,
		OnServerEvent = {
			Connect = function(_self, callback)
				return LegacyServer.On(path, callback)
			end,
		},
		FireClient = function(_self, player: Player, ...)
			return LegacyServer.Fire(player, path, ...)
		end,
		FireAllClients = function(_self, ...)
			return LegacyServer.FireAll(path, ...)
		end,
	}
end

function LegacyServer.RemoteFunction(path: string)
	local proxy = {
		Name = string.match(path, "[^%.]+$") or path,
		ClassName = "RemoteFunction",
		IsA = function(_self, className: string)
			return className == "RemoteFunction" or className == "Instance"
		end,
	}
	return setmetatable(proxy, {
		__newindex = function(_, key, value)
			if key == "OnServerInvoke" then
				LegacyServer.OnInvoke(path, value)
			else
				rawset(proxy, key, value)
			end
		end,
		__index = function(_, key)
			if key == "InvokeClient" then
				return function(_self, player: Player, ...)
					LegacyServer.Fire(player, path, ...)
					return nil
				end
			end
			return rawget(proxy, key)
		end,
	})
end

function LegacyServer.Tree(prefix: string)
	local function node(path: string)
		local proxy = {}
		local function child(key: any)
			local childPath = path .. "." .. tostring(key)
			local info = Manifest.Remotes[childPath]
			if info then
				if info.ClassName == "RemoteFunction" then
					return LegacyServer.RemoteFunction(childPath)
				end
				return LegacyServer.RemoteEvent(childPath)
			end
			return node(childPath)
		end
		return setmetatable(proxy, {
			__index = function(_, key)
				if key == "Name" then
					return string.match(path, "[^%.]+$") or path
				elseif key == "ClassName" then
					return "Folder"
				elseif key == "IsA" then
					return function(_self, className: string)
						return className == "Folder" or className == "Instance"
					end
				elseif key == "WaitForChild" or key == "FindFirstChild" then
					return function(_self, childName: string)
						return child(childName)
					end
				elseif key == "GetChildren" then
					return function()
						local children = {}
						local prefixWithDot = path .. "."
						for remotePath in Manifest.Remotes do
							if string.sub(remotePath, 1, #prefixWithDot) == prefixWithDot then
								local rest = string.sub(remotePath, #prefixWithDot + 1)
								if not string.find(rest, ".", 1, true) then
									table.insert(children, child(rest))
								end
							end
						end
						return children
					end
				end
				return child(key)
			end,
		})
	end
	return node(prefix)
end

return LegacyServer
