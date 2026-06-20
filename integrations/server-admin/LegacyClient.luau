--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BlinkFolder = ReplicatedStorage:WaitForChild("BlinkV2")
local Manifest = require(BlinkFolder:WaitForChild("LegacyManifest"))
local Network = require(BlinkFolder:WaitForChild("Client"))

local LegacyClient = {}
local listeners: { [string]: { (...any) -> () } } = {}

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

local function infoFor(path: string)
	local info = Manifest.Remotes[path]
	if not info then
		warn("[BlinkV2LegacyClient] unknown legacy remote", path)
	end
	return info
end

local function send(path: string, payload: any, predicted: boolean?)
	local info = infoFor(path)
	local risk = info and info.Risk or "ServerState"
	if risk == "Marketplace" then
		return Network.ClientPurchaseEnvelope.Fire(path, payload)
	elseif risk == "Inventory" then
		return Network.ClientBuildEnvelope.Fire(path, payload)
	elseif risk == "Moderation" then
		return Network.ClientModerationEnvelope.Fire(path, payload)
	elseif risk == "Cosmetic" then
		return Network.ClientCosmeticEnvelope.Fire(path, payload)
	else
		if predicted and Network.ClientAdminEnvelope.FirePredict then
			return Network.ClientAdminEnvelope.FirePredict(path, payload)
		end
		return Network.ClientAdminEnvelope.Fire(path, payload)
	end
end

local function connect(path: string, callback: (...any) -> ())
	listeners[path] = listeners[path] or {}
	table.insert(listeners[path], callback)
	return {
		Disconnect = function()
			local bucket = listeners[path]
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

if Network.ServerAdminEnvelope then
	Network.ServerAdminEnvelope.On(function(path: string, payload: any)
		local bucket = listeners[path]
		if not bucket then
			return
		end
		for _, callback in bucket do
			callback(unpackPayload(payload))
		end
	end)
end

if Network.ServerCosmeticEnvelope then
	Network.ServerCosmeticEnvelope.On(function(path: string, payload: any)
		local bucket = listeners[path]
		if not bucket then
			return
		end
		for _, callback in bucket do
			callback(unpackPayload(payload))
		end
	end)
end

function LegacyClient.Fire(path: string, ...: any)
	return send(path, pack(...), false)
end

function LegacyClient.Invoke(path: string, ...: any): ...any
	local result = Network.ServerAdminRequest.Invoke(path, pack(...))
	return unpackPayload(result)
end

function LegacyClient.On(path: string, callback: (...any) -> ())
	return connect(path, callback)
end

function LegacyClient.RemoteEvent(path: string)
	return {
		Name = string.match(path, "[^%.]+$") or path,
		ClassName = "RemoteEvent",
		IsA = function(_self, className: string)
			return className == "RemoteEvent" or className == "Instance"
		end,
		FireServer = function(_self, ...)
			return LegacyClient.Fire(path, ...)
		end,
		OnClientEvent = {
			Connect = function(_self, callback)
				return LegacyClient.On(path, callback)
			end,
		},
	}
end

function LegacyClient.RemoteFunction(path: string)
	return {
		Name = string.match(path, "[^%.]+$") or path,
		ClassName = "RemoteFunction",
		IsA = function(_self, className: string)
			return className == "RemoteFunction" or className == "Instance"
		end,
		InvokeServer = function(_self, ...)
			return LegacyClient.Invoke(path, ...)
		end,
		OnClientInvoke = nil,
	}
end

function LegacyClient.Tree(prefix: string)
	local function node(path: string)
		local proxy = {}
		local function child(key: any)
			local childPath = path .. "." .. tostring(key)
			local info = Manifest.Remotes[childPath]
			if info then
				if info.ClassName == "RemoteFunction" then
					return LegacyClient.RemoteFunction(childPath)
				end
				return LegacyClient.RemoteEvent(childPath)
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

return LegacyClient
