return [[local Invocations = 0

local SendSize = 64
local SendOffset = 0
local SendCursor = 0
local SendBuffer = buffer.create(64)
local SendInstances = {}
local SendBitByte = 0
local SendBitCount = 0
local SendPredictionId: number? = nil

local RecieveCursor = 0
local RecieveBuffer = buffer.create(64)
local RecieveSize = 64
local RecieveSource: any = nil
local RecieveChannel = "Reliable"
local RecieveBitByte = 0
local RecieveBitCount = 0
local RecieveFrameEnd = 0
local RecieveFrameInstanceEnd = 0
local RecievePredictionId: number? = nil

local RecieveInstances = {}
local RecieveInstanceCursor = 0

local Null = newproxy()
local Tombstone = newproxy()
local PREDICTION_ACK_INDEX = 255

type Entry = {
    value: any,
    next: Entry?
}

type Queue = {
    head: Entry?,
    tail: Entry?,
    size: number
}

type BufferSave = {
    Size: number, 
    Cursor: number, 
    Buffer: buffer, 
    Instances: {Instance},
    BitByte: number,
    BitCount: number,
    StringIds: {[string]: number},
    NextStringId: number
}

type Invocation = {
    Thread: thread,
    Started: number,
    Name: string,
    Timeout: number
}

type MetricBucket = {[string]: number}

local Metrics: {[string]: MetricBucket} = {
    BytesSent = {},
    BytesReceived = {},
    EventBytesSent = {},
    EventBytesReceived = {},
    PacketsSent = {},
    PacketsReceived = {},
    DroppedPackets = {},
    ValidationFailures = {},
    RateLimitHits = {},
    QueueDrops = {},
    InvokeTimeouts = {},
    HookErrors = {},
    MiddlewareRejections = {}
}

local Hooks: {[string]: {(...any) -> any}} = {
    BeforeSend = {},
    AfterSend = {},
    BeforeReceive = {},
    AfterReceive = {},
    Drop = {},
    Error = {},
    Predict = {},
    Ack = {},
    Rollback = {}
}

local function IsPlayerActive(Player: any): boolean
    local Success, Parent = pcall(function()
        return Player.Parent
    end)

    return not Success or Parent ~= nil
end

local AuthRules: {[string]: (any) -> boolean} = {
    AlivePlayer = function(Context)
        local Source = Context.Source
        return typeof(Source) == "Instance" and IsPlayerActive(Source)
    end,
    ServerOnly = function(Context)
        return Context.Source == "Server"
    end
}

local Groups: {[string]: {[Player]: true}} = {}
local InterestZones: {[string]: {[Player]: string}} = {}
local InterestPositions: {[string]: {[Player]: Vector3}} = {}
local RateLimitState: {[any]: {[string]: {Tokens: number, Updated: number}}} = {}
local Calls: {[number]: Invocation} = {}
local PendingInvokes = 0
local PendingInvokesByName: {[string]: number} = {}
local BufferPool: {[number]: {buffer}} = {}
local SendStringIds: {[string]: number} = {}
local RecieveStrings: {[number]: string} = {}
local NextSendStringId = 1
local NextRecieveStringId = 1
local StateFlushers: {() -> ()} = {}

local PredictionState = {
    NextId = 0,
    Pending = {} :: {[number]: {
        Name: string,
        Payload: any,
        Started: number
    }}
}

local StateChannels: {[string]: any} = {}

local function MetricAdd(BucketName: string, Key: string, Amount: number?)
    local Bucket = Metrics[BucketName]
    Bucket[Key] = (Bucket[Key] or 0) + (Amount or 1)
end

local function RunHooks(Name: string, Payload: any): boolean
    if not RuntimeConfig.EnableMiddleware then
        return true
    end

    local List = Hooks[Name]
    if not List or #List == 0 then
        return true
    end

    for _, Hook in List do
        local Success, Result = pcall(Hook, Payload)
        if not Success then
            MetricAdd("HookErrors", Name)
            warn(`[Blink]: {Name} middleware failed: {Result}`)
        elseif Result == false then
            MetricAdd("MiddlewareRejections", Name)
            return false
        end
    end

    return true
end

local function DropPacket(Source: any, Channel: string, Reason: string, Size: number?)
    MetricAdd("DroppedPackets", Reason)
    if Reason == "RateLimit" then
        MetricAdd("RateLimitHits", Channel)
    elseif Reason == "QueueFull" then
        MetricAdd("QueueDrops", Channel)
    elseif Reason == "ValidationFailure" or Reason == "MalformedPacket" then
        MetricAdd("ValidationFailures", Channel)
    elseif Reason == "MiddlewareRejected" then
        MetricAdd("MiddlewareRejections", Channel)
    elseif Reason == "AuthRejected" then
        MetricAdd("ValidationFailures", Channel)
    end

    RunHooks("Drop", {
        Source = Source,
        Channel = Channel,
        Reason = Reason,
        Size = Size or 0
    })
end

local function BeforeSend(Name: string, Channel: string, Target: any?): boolean
    return RunHooks("BeforeSend", {
        Name = Name,
        Channel = Channel,
        Target = Target
    })
end

local function Use(HookName: string, Callback: (...any) -> any): () -> ()
    local List = Hooks[HookName]
    if not List then
        error(`[Blink]: Unknown middleware hook "{HookName}".`)
    end

    table.insert(List, Callback)
    return function()
        local Index = table.find(List, Callback)
        if Index then
            table.remove(List, Index)
        end
    end
end

local function UseAuth(RuleName: string, Callback: (any) -> boolean)
    AuthRules[RuleName] = Callback
end

local function CheckAuth(RuleName: string?, Context: any): boolean
    if RuleName == nil or RuleName == "" then
        return true
    end

    local Rule = AuthRules[RuleName]
    if Rule == nil then
        error(`[Blink]: Unknown auth rule "{RuleName}".`)
    end

    local Success, Result = pcall(Rule, Context)
    if not Success then
        MetricAdd("HookErrors", "Auth")
        warn(`[Blink]: Auth rule "{RuleName}" failed: {Result}`)
        return false
    end

    return Result == true
end

local function Configure(Options: {[string]: any})
    for Key, Value in Options do
        if RuntimeConfig[Key] == nil then
            error(`[Blink]: Unknown runtime option "{Key}".`)
        end

        RuntimeConfig[Key] = Value
    end
end

local function GetMetrics()
    if not RuntimeConfig.ExposeMetrics then
        error("[Blink]: Metrics are disabled by RuntimeConfig.ExposeMetrics.")
    end

    local Copy = {}
    for BucketName, Bucket in Metrics do
        local BucketCopy = {}
        for Key, Value in Bucket do
            BucketCopy[Key] = Value
        end
        Copy[BucketName] = BucketCopy
    end

    Copy.PendingInvokes = PendingInvokes
    Copy.PendingInvokesByName = table.clone(PendingInvokesByName)
    return Copy
end

local function FormatMetricLine(BucketName: string, Bucket: MetricBucket): string
    local Parts = {}
    for Key, Value in Bucket do
        table.insert(Parts, `{Key}={Value}`)
    end

    table.sort(Parts)
    return `{BucketName}: {table.concat(Parts, ", ")}`
end

local function ReportMetrics()
    local Snapshot = GetMetrics()
    local Lines = { "[Blink]: Metrics" }
    for BucketName, Bucket in Snapshot do
        if type(Bucket) == "table" then
            table.insert(Lines, FormatMetricLine(BucketName, Bucket :: MetricBucket))
        else
            table.insert(Lines, `{BucketName}: {Bucket}`)
        end
    end

    print(table.concat(Lines, "\n"))
    return Snapshot
end

local function StartMetricsReporter(IntervalSeconds: number?): () -> ()
    local Running = true
    task.spawn(function()
        while Running do
            task.wait(IntervalSeconds or 5)
            if Running then
                ReportMetrics()
            end
        end
    end)

    return function()
        Running = false
    end
end

local function InstancePayload(Instances: {Instance})
    if not RuntimeConfig.UseEmptyInstanceOptimization then
        return Instances
    end

    if next(Instances) == nil then
        return nil
    end

    return Instances
end

local function UseProtocolV2(): boolean
    return RuntimeConfig.ProtocolVersion >= 2
end

local function UseVarints(): boolean
    return UseProtocolV2() and RuntimeConfig.UseVarints
end

local function UseBitPacking(): boolean
    return UseProtocolV2() and RuntimeConfig.UseBitPacking
end

local function PoolSize(Size: number): number
    local Bucket = 64
    while Bucket < Size do
        Bucket *= 2
    end
    return Bucket
end

local function AcquireBuffer(Size: number): buffer
    if not RuntimeConfig.UseBufferPooling then
        return buffer.create(Size)
    end

    local Bucket = PoolSize(Size)
    local Pool = BufferPool[Bucket]
    if Pool and #Pool > 0 then
        local Buffer = Pool[#Pool]
        Pool[#Pool] = nil
        return Buffer
    end

    return buffer.create(Bucket)
end

local function ReleaseBuffer(Buffer: buffer?)
    if not RuntimeConfig.UseBufferPooling or Buffer == nil then
        return
    end

    local Size = buffer.len(Buffer)
    local Pool = BufferPool[Size]
    if Pool == nil then
        Pool = {}
        BufferPool[Size] = Pool
    end

    if #Pool < RuntimeConfig.BufferPoolLimit then
        table.insert(Pool, Buffer)
    end
end

local function RawAllocate(Bytes: number)
    local InUse = (SendCursor + Bytes)
    local Capacity = buffer.len(SendBuffer)
    if InUse > Capacity then
        local NewSize = math.max(SendSize, Capacity)
        while InUse > NewSize do
            NewSize = math.max(InUse, math.ceil(NewSize * 1.5))
        end

        local Buffer = AcquireBuffer(NewSize)
        if buffer.len(Buffer) < InUse then
            ReleaseBuffer(Buffer)
            Buffer = buffer.create(InUse)
        end
        buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)
        ReleaseBuffer(SendBuffer)
        SendBuffer = Buffer
    end
    SendSize = buffer.len(SendBuffer)

    if InUse > SendSize then
        local Buffer = buffer.create(InUse)
        buffer.copy(Buffer, 0, SendBuffer, 0, math.min(SendCursor, buffer.len(SendBuffer)))
        ReleaseBuffer(SendBuffer)
        SendBuffer = Buffer
        SendSize = buffer.len(SendBuffer)
    end

    if SendCursor + Bytes > buffer.len(SendBuffer) then
        error(`[Blink]: Allocate out of bounds: cursor={SendCursor}, bytes={Bytes}, capacity={buffer.len(SendBuffer)}, logical={SendSize}.`)
    end

    SendOffset = SendCursor
    SendCursor += Bytes

    return SendOffset
end

local function FlushBits()
    if SendBitCount <= 0 then
        return
    end

    local Offset = RawAllocate(1)
    buffer.writeu8(SendBuffer, Offset, SendBitByte)
    SendBitByte = 0
    SendBitCount = 0
end

local function Allocate(Bytes: number)
    FlushBits()
    return RawAllocate(Bytes)
end

local function WriteBit(Value: boolean)
    if not UseBitPacking() then
        local Offset = RawAllocate(1)
        buffer.writeu8(SendBuffer, Offset, Value and 1 or 0)
        return
    end

    if Value then
        SendBitByte += bit32.lshift(1, SendBitCount)
    end

    SendBitCount += 1
    if SendBitCount == 8 then
        FlushBits()
    end
end

local function RawRead(Bytes: number)
    if RecieveCursor + Bytes > RecieveSize then
        DropPacket(RecieveSource, RecieveChannel, "MalformedPacket", RecieveSize)
        error(`[Blink]: Malformed {RecieveChannel} packet tried to read past the packet boundary.`)
    end

    if RecieveFrameEnd > 0 and RecieveCursor + Bytes > RecieveFrameEnd then
        DropPacket(RecieveSource, RecieveChannel, "MalformedPacket", RecieveSize)
        error(`[Blink]: Malformed {RecieveChannel} frame tried to read past the frame boundary.`)
    end

    local Offset = RecieveCursor
    RecieveCursor += Bytes
    return Offset
end

local function AlignReadBits()
    RecieveBitByte = 0
    RecieveBitCount = 0
end

local function TrackSend(Channel: string, Size: number, Target: any?)
    MetricAdd("BytesSent", Channel, Size)
    MetricAdd("PacketsSent", Channel)
    RunHooks("AfterSend", {
        Channel = Channel,
        Size = Size,
        Target = Target
    })
end

local function TrackEventSend(Name: string, Channel: string, Size: number, Target: any?)
    MetricAdd("EventBytesSent", Name, Size)
    RunHooks("AfterSend", {
        Name = Name,
        Channel = Channel,
        Size = Size,
        Target = Target
    })
end

local function TrackEventReceive(Name: string, Channel: string, Size: number, Source: any?)
    MetricAdd("EventBytesReceived", Name, Size)
    RunHooks("AfterReceive", {
        Name = Name,
        Source = Source,
        Channel = Channel,
        Size = Size
    })
end

local function CheckRateLimit(Source: any, Key: string, Rate: number?, Burst: number?): boolean
    local Rate = Rate or RuntimeConfig.RateLimitPerSecond
    if Rate <= 0 then
        return true
    end

    local Burst = Burst or RuntimeConfig.RateLimitBurst
    if Burst <= 0 then
        Burst = Rate
    end

    local SourceState = RateLimitState[Source]
    if SourceState == nil then
        SourceState = {}
        RateLimitState[Source] = SourceState
    end

    local Now = os.clock()
    local State = SourceState[Key]
    if State == nil then
        State = {
            Tokens = Burst,
            Updated = Now
        }
        SourceState[Key] = State
    end

    State.Tokens = math.min(Burst, State.Tokens + ((Now - State.Updated) * Rate))
    State.Updated = Now

    if State.Tokens < 1 then
        DropPacket(Source, Key, "RateLimit")
        return false
    end

    State.Tokens -= 1
    return true
end

local function ValidateIncoming(Source: any, Channel: string, IncomingBuffer: any, Instances: {Instance}?)
    if typeof(IncomingBuffer) ~= "buffer" then
        DropPacket(Source, Channel, "InvalidBuffer")
        return nil
    end

    local Size = buffer.len(IncomingBuffer)
    local Limit = if Channel == "Reliable" then RuntimeConfig.MaxReliablePacketBytes else RuntimeConfig.MaxUnreliablePacketBytes
    if Limit > 0 and Size > Limit then
        DropPacket(Source, Channel, "MaxPacketBytes", Size)
        return nil
    end

    if not CheckRateLimit(Source, Channel, RuntimeConfig.RateLimitPerSecond, RuntimeConfig.RateLimitBurst) then
        return nil
    end

    if Instances ~= nil then
        if typeof(Instances) ~= "table" then
            DropPacket(Source, Channel, "InvalidInstances", Size)
            return nil
        end
    end

    RecieveSource = Source
    RecieveChannel = Channel
    RecieveSize = Size
    RecieveInstances = Instances or {}

    MetricAdd("BytesReceived", Channel, Size)
    MetricAdd("PacketsReceived", Channel)
    if not RunHooks("BeforeReceive", {
        Source = Source,
        Channel = Channel,
        Size = Size
    }) then
        DropPacket(Source, Channel, "MiddlewareRejected", Size)
        return nil
    end

    return Size
end

local function Read(Bytes: number)
    AlignReadBits()
    return RawRead(Bytes)
end

local function ReadBit(): boolean
    if not UseBitPacking() then
        return buffer.readu8(RecieveBuffer, RawRead(1)) == 1
    end

    if RecieveBitCount <= 0 then
        RecieveBitByte = buffer.readu8(RecieveBuffer, RawRead(1))
        RecieveBitCount = 8
    end

    local BitIndex = 8 - RecieveBitCount
    RecieveBitCount -= 1
    return bit32.btest(RecieveBitByte, bit32.lshift(1, BitIndex))
end

local function WriteVarint(Value: number)
    local Remaining = Value
    repeat
        local Byte = Remaining % 128
        Remaining = math.floor(Remaining / 128)
        if Remaining > 0 then
            Byte += 128
        end
        local Offset = Allocate(1)
        buffer.writeu8(SendBuffer, Offset, Byte)
    until Remaining <= 0
end

local function ReadVarint(): number
    local Result = 0
    local Shift = 0
    for _ = 1, 5 do
        local Byte = buffer.readu8(RecieveBuffer, Read(1))
        Result += bit32.lshift(bit32.band(Byte, 0x7F), Shift)
        if bit32.band(Byte, 0x80) == 0 then
            return Result
        end
        Shift += 7
    end

    error("[Blink]: Malformed varint.")
end

local function WriteSignedVarint(Value: number)
    local Encoded = if Value < 0 then ((-Value) * 2) - 1 else Value * 2
    WriteVarint(Encoded)
end

local function ReadSignedVarint(): number
    local Encoded = ReadVarint()
    if Encoded % 2 == 1 then
        return -((Encoded + 1) / 2)
    end

    return Encoded / 2
end

local function WriteLength(Value: number, Bytes: number)
    if UseVarints() then
        WriteVarint(Value)
    elseif Bytes == 1 then
        local Offset = Allocate(1)
        buffer.writeu8(SendBuffer, Offset, Value)
    elseif Bytes == 2 then
        local Offset = Allocate(2)
        buffer.writeu16(SendBuffer, Offset, Value)
    else
        local Offset = Allocate(4)
        buffer.writeu32(SendBuffer, Offset, Value)
    end
end

local function ReadLength(Bytes: number): number
    if UseVarints() then
        return ReadVarint()
    elseif Bytes == 1 then
        return buffer.readu8(RecieveBuffer, Read(1))
    elseif Bytes == 2 then
        return buffer.readu16(RecieveBuffer, Read(2))
    end

    return buffer.readu32(RecieveBuffer, Read(4))
end

local function EncodeVarint(Value: number): {number}
    local Bytes = {}
    local Remaining = Value
    repeat
        local Byte = Remaining % 128
        Remaining = math.floor(Remaining / 128)
        if Remaining > 0 then
            Byte += 128
        end
        table.insert(Bytes, Byte)
    until Remaining <= 0
    return Bytes
end

local function WriteEncodedVarint(Offset: number, Bytes: {number})
    for Index, Byte in Bytes do
        buffer.writeu8(SendBuffer, Offset + Index - 1, Byte)
    end
end

local function BeginMessage(Index: number)
    if not UseProtocolV2() then
        local Offset = Allocate(1)
        buffer.writeu8(SendBuffer, Offset, Index)
        return nil
    end

    FlushBits()
    local Flags = if SendPredictionId ~= nil then 1 else 0
    local IndexOffset = RawAllocate(1)
    buffer.writeu8(SendBuffer, IndexOffset, Index)
    local FlagsOffset = RawAllocate(1)
    buffer.writeu8(SendBuffer, FlagsOffset, Flags)

    local LengthOffset = RawAllocate(5)
    local InstanceOffset = RawAllocate(5)
    local HeaderDataStart = SendCursor
    if SendPredictionId ~= nil then
        WriteVarint(SendPredictionId)
    end

    return {
        LengthOffset = LengthOffset,
        InstanceOffset = InstanceOffset,
        HeaderDataStart = HeaderDataStart,
        PayloadStart = SendCursor,
        InstanceStart = #SendInstances
    }
end

local function EndMessage(Frame: any?)
    if Frame == nil then
        return
    end

    FlushBits()
    local PayloadLength = SendCursor - Frame.PayloadStart
    local InstanceCount = #SendInstances - Frame.InstanceStart
    local LengthBytes = EncodeVarint(PayloadLength)
    local InstanceBytes = EncodeVarint(InstanceCount)
    local ActualHeader = #LengthBytes + #InstanceBytes
    local ReservedHeader = 10
    local Shift = ReservedHeader - ActualHeader

    if Shift > 0 then
        local MoveLength = SendCursor - Frame.HeaderDataStart
        if MoveLength > 0 then
            buffer.copy(SendBuffer, Frame.HeaderDataStart - Shift, SendBuffer, Frame.HeaderDataStart, MoveLength)
        end
        SendCursor -= Shift
    end

    WriteEncodedVarint(Frame.LengthOffset, LengthBytes)
    WriteEncodedVarint(Frame.LengthOffset + #LengthBytes, InstanceBytes)
end

local function BeginReadMessage(PacketSize: number): number?
    AlignReadBits()
    RecieveFrameEnd = 0
    RecieveFrameInstanceEnd = RecieveInstanceCursor
    RecievePredictionId = nil

    if not UseProtocolV2() then
        return buffer.readu8(RecieveBuffer, Read(1))
    end

    local Index = buffer.readu8(RecieveBuffer, Read(1))
    local Flags = buffer.readu8(RecieveBuffer, Read(1))
    local PayloadLength = ReadVarint()
    local InstanceCount = ReadVarint()
    if bit32.btest(Flags, 1) then
        RecievePredictionId = ReadVarint()
    end

    local FrameEnd = RecieveCursor + PayloadLength
    if FrameEnd > PacketSize then
        DropPacket(RecieveSource, RecieveChannel, "MalformedPacket", PacketSize)
        RecieveCursor = PacketSize
        return nil
    end

    RecieveFrameEnd = FrameEnd
    RecieveFrameInstanceEnd = RecieveInstanceCursor + InstanceCount
    return Index
end

local function EndReadMessage()
    if not UseProtocolV2() or RecieveFrameEnd <= 0 then
        return
    end

    AlignReadBits()
    RecieveCursor = RecieveFrameEnd
    RecieveInstanceCursor = RecieveFrameInstanceEnd
    RecieveFrameEnd = 0
    RecieveFrameInstanceEnd = RecieveInstanceCursor
    RecievePredictionId = nil
end

local function RecoverMessage()
    if UseProtocolV2() and RecieveFrameEnd > 0 then
        EndReadMessage()
        return
    end

    AlignReadBits()
    RecieveCursor = RecieveSize
    RecieveFrameEnd = 0
    RecieveFrameInstanceEnd = RecieveInstanceCursor
    RecievePredictionId = nil
end

local function WriteStringValue(Value: string, LengthBytes: number)
    if UseProtocolV2() and RuntimeConfig.UseStringDictionaries then
        local Existing = SendStringIds[Value]
        if Existing then
            WriteVarint(Existing)
            return
        end

        WriteVarint(0)
        SendStringIds[Value] = NextSendStringId
        NextSendStringId += 1
    end

    local Length = #Value
    WriteLength(Length, LengthBytes)
    local Offset = Allocate(Length)
    buffer.writestring(SendBuffer, Offset, Value, Length)
end

local function ReadStringValue(LengthBytes: number): string
    if UseProtocolV2() and RuntimeConfig.UseStringDictionaries then
        local Identifier = ReadVarint()
        if Identifier > 0 then
            local Value = RecieveStrings[Identifier]
            if Value == nil then
                error(`[Blink]: Unknown interned string id {Identifier}.`)
            end

            return Value
        end
    end

    local Length = ReadLength(LengthBytes)
    local Value = buffer.readstring(RecieveBuffer, Read(Length), Length)
    if UseProtocolV2() and RuntimeConfig.UseStringDictionaries then
        RecieveStrings[NextRecieveStringId] = Value
        NextRecieveStringId += 1
    end

    return Value
end

local function Save(): BufferSave
    return {
        Size = SendSize,
        Cursor = SendCursor,
        Buffer = SendBuffer,
        Instances = SendInstances,
        BitByte = SendBitByte,
        BitCount = SendBitCount,
        StringIds = SendStringIds,
        NextStringId = NextSendStringId
    }
end

local function Load(Save: BufferSave?)
    if Save then
        if SendBuffer ~= Save.Buffer then
            ReleaseBuffer(SendBuffer)
        end
        SendSize = Save.Size
        SendCursor = Save.Cursor
        SendOffset = Save.Cursor
        SendBuffer = Save.Buffer
        SendInstances = Save.Instances
        SendBitByte = Save.BitByte
        SendBitCount = Save.BitCount
        SendStringIds = Save.StringIds
        NextSendStringId = Save.NextStringId
        return
    end

    SendSize = 64
    SendCursor = 0
    SendOffset = 0
    SendBuffer = AcquireBuffer(64)
    SendInstances = {}
    SendBitByte = 0
    SendBitCount = 0
    SendStringIds = {}
    NextSendStringId = 1
end

local function Invoke()
    if Invocations == 255 then
        Invocations = 0
    end

    local Invocation = Invocations
    Invocations += 1
    return Invocation
end

local function ExpireInvocations()
    local Now = os.clock()
    for Identifier, Invocation in Calls do
        local Timeout = Invocation.Timeout
        if Timeout <= 0 then
            continue
        end

        if Now - Invocation.Started >= Timeout then
            Calls[Identifier] = nil
            PendingInvokes = math.max(0, PendingInvokes - 1)
            PendingInvokesByName[Invocation.Name] = math.max(0, (PendingInvokesByName[Invocation.Name] or 1) - 1)
            MetricAdd("InvokeTimeouts", Invocation.Name)
            task.spawn(Invocation.Thread, false, `[Blink]: Invoke timed out after {Timeout} seconds.`)
        end
    end
end

local function RegisterInvocation(Identifier: number, Thread: thread, Name: string?, MaxPending: number?, Timeout: number?)
    ExpireInvocations()
    local InvocationName = Name or "Client"
    local GlobalLimit = RuntimeConfig.MaxPendingInvokes
    local NameLimit = MaxPending or GlobalLimit

    if GlobalLimit > 0 and PendingInvokes >= GlobalLimit then
        error(`[Blink]: More than {GlobalLimit} calls are awaiting a response, this packet has been dropped.`)
    end

    if NameLimit > 0 and (PendingInvokesByName[InvocationName] or 0) >= NameLimit then
        error(`[Blink]: More than {NameLimit} calls for "{InvocationName}" are awaiting a response, this packet has been dropped.`)
    end

    if Calls[Identifier] ~= nil then
        error("[Blink]: Invocation id is already awaiting a response, this packet has been dropped.")
    end

    Calls[Identifier] = {
        Thread = Thread,
        Started = os.clock(),
        Name = InvocationName,
        Timeout = Timeout or RuntimeConfig.InvokeTimeoutSeconds
    }
    PendingInvokes += 1
    PendingInvokesByName[InvocationName] = (PendingInvokesByName[InvocationName] or 0) + 1
end

local function ClearInvocation(Identifier: number): Invocation?
    local Invocation = Calls[Identifier]
    if Invocation ~= nil then
        Calls[Identifier] = nil
        PendingInvokes = math.max(0, PendingInvokes - 1)
        PendingInvokesByName[Invocation.Name] = math.max(0, (PendingInvokesByName[Invocation.Name] or 1) - 1)
    end

    return Invocation
end

local function CancelInvocations(Reason: string?)
    for Identifier, Invocation in Calls do
        Calls[Identifier] = nil
        task.spawn(Invocation.Thread, false, Reason or "[Blink]: Invoke was cancelled.")
    end

    table.clear(PendingInvokesByName)
    PendingInvokes = 0
end

local function InvocationErrorMessage(Default: string, ...: any): string
    local First = ...
    if type(First) == "string" then
        return First
    end

    return Default
end

local function CreateQueue(): Queue
    return {
        head = nil,
        tail = nil,
        size = 0
    }
end

local function Pop(queue: Queue): any
    local head = queue.head
    if head == nil then
        return
    end

    queue.head = head.next
    queue.size = math.max(0, queue.size - 1)
    return head.value
end

local function Push(queue: Queue, value: any)
    local entry: Entry = {
        value = value,
        next = nil
    }

    if queue.tail ~= nil then
        queue.tail.next = entry
    end

    queue.tail = entry

    if queue.head == nil then
        queue.head = entry
    end

    queue.size += 1
end

local function SetGroup(Name: string, Players: {Player})
    local Group = {}
    for _, Player in Players do
        Group[Player] = true
    end

    Groups[Name] = Group
end

local function AddToGroup(Name: string, Player: Player)
    local Group = Groups[Name]
    if Group == nil then
        Group = {}
        Groups[Name] = Group
    end

    Group[Player] = true
end

local function RemoveFromGroup(Name: string, Player: Player)
    local Group = Groups[Name]
    if Group then
        Group[Player] = nil
    end
end

local function GetGroupPlayers(Name: string): {Player}
    local Group = Groups[Name]
    if Group == nil then
        return {}
    end

    local Players = {}
    for Player in Group do
        table.insert(Players, Player)
    end

    return Players
end

local function SetInterestZone(ChannelName: string, Player: Player, ZoneName: string?)
    local ChannelZones = InterestZones[ChannelName]
    if ChannelZones == nil then
        ChannelZones = {}
        InterestZones[ChannelName] = ChannelZones
    end

    ChannelZones[Player] = ZoneName
end

local function GetInterestZonePlayers(ChannelName: string, ZoneName: string): {Player}
    local ChannelZones = InterestZones[ChannelName]
    if ChannelZones == nil then
        return {}
    end

    local Players = {}
    for Player, PlayerZone in ChannelZones do
        if PlayerZone == ZoneName and IsPlayerActive(Player) then
            table.insert(Players, Player)
        end
    end

    return Players
end

local function SetInterestPosition(ChannelName: string, Player: Player, Position: Vector3?)
    local ChannelPositions = InterestPositions[ChannelName]
    if ChannelPositions == nil then
        ChannelPositions = {}
        InterestPositions[ChannelName] = ChannelPositions
    end

    ChannelPositions[Player] = Position
end

local function GetInterestDistancePlayers(ChannelName: string, Origin: Vector3, Radius: number): {Player}
    local ChannelPositions = InterestPositions[ChannelName]
    if ChannelPositions == nil then
        return {}
    end

    local RadiusSquared = Radius * Radius
    local Players = {}
    for Player, Position in ChannelPositions do
        if IsPlayerActive(Player) and (Position - Origin).Magnitude ^ 2 <= RadiusSquared then
            table.insert(Players, Player)
        end
    end

    return Players
end

local function ClearPlayerRuntimeState(Player: Player)
    RateLimitState[Player] = nil
    for _, Group in Groups do
        Group[Player] = nil
    end
    for _, ChannelZones in InterestZones do
        ChannelZones[Player] = nil
    end
    for _, ChannelPositions in InterestPositions do
        ChannelPositions[Player] = nil
    end
end

local function BeginPrediction(Name: string, Payload: any): number
    if not RuntimeConfig.EnablePrediction then
        error("[Blink]: Prediction helpers are disabled by RuntimeConfig.EnablePrediction.")
    end

    PredictionState.NextId = (PredictionState.NextId + 1) % 65536
    local Identifier = PredictionState.NextId
    PredictionState.Pending[Identifier] = {
        Name = Name,
        Payload = Payload,
        Started = os.clock()
    }

    RunHooks("Predict", {
        Id = Identifier,
        Name = Name,
        Payload = Payload
    })

    return Identifier
end

local function AckPrediction(Identifier: number)
    local Prediction = PredictionState.Pending[Identifier]
    if Prediction == nil then
        return nil
    end

    PredictionState.Pending[Identifier] = nil
    RunHooks("Ack", {
        Id = Identifier,
        Prediction = Prediction
    })

    return Prediction
end

local function RollbackPrediction(Identifier: number, Reason: string?)
    local Prediction = PredictionState.Pending[Identifier]
    if Prediction == nil then
        return nil
    end

    PredictionState.Pending[Identifier] = nil
    RunHooks("Rollback", {
        Id = Identifier,
        Prediction = Prediction,
        Reason = Reason
    })

    return Prediction
end

local function WritePredictionAckPayload(Name: string, Accepted: boolean, Reason: string?)
    if RecievePredictionId == nil then
        return
    end

    local PreviousPredictionId = SendPredictionId
    SendPredictionId = nil
    local Frame = BeginMessage(PREDICTION_ACK_INDEX)
    WriteVarint(RecievePredictionId)
    WriteBit(Accepted)
    WriteStringValue(Reason or "", 1)
    EndMessage(Frame)
    SendPredictionId = PreviousPredictionId
end

local function ReadPredictionAckPayload()
    local Identifier = ReadVarint()
    local Accepted = ReadBit()
    local Reason = ReadStringValue(1)

    if Accepted then
        AckPrediction(Identifier)
    else
        RollbackPrediction(Identifier, Reason ~= "" and Reason or nil)
    end
end

local function DefineStateChannel(Name: string, Options: {[string]: any}?)
    if not RuntimeConfig.EnableStateChannels then
        error("[Blink]: State channel helpers are disabled by RuntimeConfig.EnableStateChannels.")
    end

    local Channel = {
        Name = Name,
        Options = Options or {},
        Version = 0,
        Snapshot = {},
        Dirty = {}
    }

    function Channel:Set(Key: any, Value: any)
        if self.Snapshot[Key] == Value then
            return
        end

        self.Snapshot[Key] = Value
        self.Dirty[Key] = Value
        self.Version += 1
    end

    function Channel:Get(Key: any)
        return self.Snapshot[Key]
    end

    function Channel:Flush()
        local Dirty = self.Dirty
        self.Dirty = {}
        return Dirty, self.Version
    end

    StateChannels[Name] = Channel
    return Channel
end

local function RegisterStateFlusher(Callback: () -> ())
    table.insert(StateFlushers, Callback)
end

local function RunStateFlushers()
    for _, Callback in StateFlushers do
        local Success, Error = pcall(Callback)
        if not Success then
            MetricAdd("HookErrors", "StateFlusher")
            warn(`[Blink]: State channel flusher failed: {Error}`)
        end
    end
end

local Events: any = {
    Reliable = table.create(256),
    Unreliable = table.create(256)
}

local Queue: any = {
    Reliable = table.create(256),
    Unreliable = table.create(256)
}

]]
