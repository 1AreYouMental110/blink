return [[local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- SPLIT --
if not RunService:IsClient() then
    error("Client network module can only be required from the client.")
end

local Reliable: RemoteEvent = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_RELIABLE_REMOTE") :: RemoteEvent
local Unreliable: UnreliableRemoteEvent = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE") :: UnreliableRemoteEvent

local function StepReplication()
    ProfileBegin("Blink.Flush.Client")
    FlushBits()
    if SendCursor <= 0 then
        ProfileEnd()
        return
    end
    if not RuntimeSupport.ShouldFlush("Server", "Reliable", SendCursor, "Gameplay") then
        ProfileEnd()
        return
    end

    local Buffer = buffer.create(SendCursor)
    buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)
    if RuntimeConfig.MaxReliablePacketBytes > 0 and SendCursor > RuntimeConfig.MaxReliablePacketBytes then
        DropPacket("Client", "Reliable", "MaxPacketBytes", SendCursor)
    else
        for _, Fragment in RuntimeSupport.FragmentReliablePacket("Server", Buffer, InstancePayload(SendInstances)) do
            Reliable:FireServer(Fragment.Buffer, Fragment.Instances)
            TrackSend("Reliable", buffer.len(Fragment.Buffer), nil)
        end
        RuntimeSupport.RecordFlush("Server", "Reliable", SendCursor)
    end

    SendSize = 64
    SendCursor = 0
    SendOffset = 0
    SendBuffer = AcquireBuffer(64)
    table.clear(SendInstances)
    SendBitByte = 0
    SendBitCount = 0
    SendStringIds = {}
    NextSendStringId = 1
    ProfileEnd()
end
]]
