return [[local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PlayersMap: {[Player]: any} = {}

-- SPLIT --
if not RunService:IsServer() then
    error("Server network module can only be required from the server.")
end

local Reliable: RemoteEvent = ReplicatedStorage:FindFirstChild(BASE_EVENT_NAME .. "_RELIABLE_REMOTE") :: RemoteEvent
if not Reliable then
    local RemoteEvent = Instance.new("RemoteEvent")
    RemoteEvent.Name = BASE_EVENT_NAME .. "_RELIABLE_REMOTE"
    RemoteEvent.Parent = ReplicatedStorage
    Reliable = RemoteEvent
end

local Unreliable: UnreliableRemoteEvent = ReplicatedStorage:FindFirstChild(BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE") :: UnreliableRemoteEvent
if not Unreliable then
    local UnreliableRemoteEvent = Instance.new("UnreliableRemoteEvent")
    UnreliableRemoteEvent.Name = BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE"
    UnreliableRemoteEvent.Parent = ReplicatedStorage
    Unreliable = UnreliableRemoteEvent
end

Players.PlayerRemoving:Connect(function(Player)
    PlayersMap[Player] = nil
    ClearPlayerRuntimeState(Player)
end)

local function StepReplication()
    RunStateFlushers()
    for Player, Send in PlayersMap do
        Load(Send)
        FlushBits()
        PlayersMap[Player] = Save()
        Send = PlayersMap[Player]
        if Send.Cursor <= 0 then
            continue
        end

        local Buffer = buffer.create(Send.Cursor)
        buffer.copy(Buffer, 0, Send.Buffer, 0, Send.Cursor)
        if RuntimeConfig.MaxReliablePacketBytes > 0 and Send.Cursor > RuntimeConfig.MaxReliablePacketBytes then
            DropPacket(Player, "Reliable", "MaxPacketBytes", Send.Cursor)
        elseif IsPlayerActive(Player) then
            Reliable:FireClient(Player, Buffer, InstancePayload(Send.Instances))
            TrackSend("Reliable", Send.Cursor, Player)
        end

        Send.Size = 64
        Send.Cursor = 0
        Send.Buffer = AcquireBuffer(64)
        Send.BitByte = 0
        Send.BitCount = 0
        Send.StringIds = {}
        Send.NextStringId = 1
        table.clear(Send.Instances)
    end
end
]]
