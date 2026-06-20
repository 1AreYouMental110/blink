--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local LegacyServer = require(script.Parent:WaitForChild("LegacyServer"))
local Manifest = require(ReplicatedStorage:WaitForChild("BlinkV2"):WaitForChild("LegacyManifest"))

local quarantine = ServerStorage:FindFirstChild("BlinkV2LegacyQuarantine") or Instance.new("Folder")
quarantine.Name = "BlinkV2LegacyQuarantine"
quarantine.Parent = ServerStorage

local function split(path: string): { string }
	local parts = {}
	for part in string.gmatch(path, "[^%.]+") do
		table.insert(parts, part)
	end
	return parts
end

local function resolve(path: string): Instance?
	local parts = split(path)
	local current: Instance? = nil
	if parts[1] == "ReplicatedStorage" then
		current = ReplicatedStorage
	elseif parts[1] == "ServerStorage" then
		current = ServerStorage
	else
		current = game:FindFirstChild(parts[1])
	end
	for i = 2, #parts do
		if not current then
			return nil
		end
		current = current:FindFirstChild(parts[i])
	end
	return current
end

local function audit(player: Player?, path: string, action: string, reason: string)
	local folder = script.Parent:FindFirstChild("LegacyAudit") or Instance.new("Folder")
	folder.Name = "LegacyAudit"
	folder.Parent = script.Parent
	local value = Instance.new("StringValue")
	value.Name = tostring(os.time()) .. "_" .. string.gsub(path, "[^%w_]", "_")
	value.Value = string.format("%s|%s|%s|%s", action, reason, player and player.UserId or 0, path)
	value:SetAttribute("Action", action)
	value:SetAttribute("Reason", reason)
	value:SetAttribute("Path", path)
	value:SetAttribute("PlayerUserId", player and player.UserId or 0)
	value.Parent = folder
	while #folder:GetChildren() > 500 do
		folder:GetChildren()[1]:Destroy()
	end
	warn("[BlinkV2LegacyFirewall]", action, reason, player, path)
end

local function annotate(remote: Instance, path: string, info)
	remote:SetAttribute("BlinkV2LegacyPath", path)
	remote:SetAttribute("BlinkV2WireId", info.WireId)
	remote:SetAttribute("BlinkV2Risk", info.Risk)
	remote:SetAttribute("BlinkV2Policy", info.Policy)
	remote:SetAttribute("BlinkV2MaxPacketBytes", info.MaxPacketBytes)
	remote:SetAttribute("BlinkV2Mode", info.Mode)
	remote:SetAttribute("BlinkV2Protocol", 2)
end

local function makeStub(path: string, info, parent: Instance)
	local stub = Instance.new(info.ClassName)
	stub.Name = info.Name
	annotate(stub, path, info)
	stub:SetAttribute("BlinkV2Stub", true)
	stub.Parent = parent
	if stub:IsA("RemoteEvent") then
		stub.OnServerEvent:Connect(function(player: Player, ...)
			audit(player, path, "deny", "legacy-remote-honeypot")
		end)
	elseif stub:IsA("RemoteFunction") then
		stub.OnServerInvoke = function(player: Player, ...)
			audit(player, path, "deny", "legacy-function-honeypot")
			return nil
		end
	end
	return stub
end

local quarantined = 0
local observed = 0
for path, info in Manifest.Remotes do
	local remote = resolve(path)
	if remote then
		annotate(remote, path, info)
		if info.ClientOrigin then
			local parent = remote.Parent
			if parent and not remote:GetAttribute("BlinkV2Stub") then
				remote.Name = info.Name .. "__BlinkV2Quarantined_" .. tostring(info.WireId)
				remote.Parent = quarantine
				makeStub(path, info, parent)
				quarantined += 1
			end
		else
			observed += 1
		end
	end
end

LegacyServer.Start()
script:SetAttribute("BlinkV2LegacyQuarantined", quarantined)
script:SetAttribute("BlinkV2LegacyObserved", observed)
script:SetAttribute("BlinkV2LegacyManifestCount", Manifest.LegacyRemoteCount)
script:SetAttribute("BlinkV2Protocol", 2)
print("[BlinkV2LegacyFirewall] active", quarantined, "quarantined", observed, "observed")
