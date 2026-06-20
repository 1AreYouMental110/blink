local Format = require("../src/Modules/Format")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local Compiler = "init"
local Sources = fs.readDir("./Sources")

local COMPILE_TEST_FILE = "../../test/Sources/Test"
local FORCE_COMPILE = table.find(process.args, "--compile") ~= nil
local SKIP_COMPILE = table.find(process.args, "--no-compile") ~= nil

local function OkPrint(Message: string)
	stdio.write(`\r[{stdio.color("green")}OK{stdio.color("reset")}] {Message}\n`)
end

local function ErrorPrint(Message: string)
	stdio.write(`\r[{stdio.color("red")}ERROR{stdio.color("reset")}] {Message}\n`)
	process.exit(20)
end

local function PrettyPrint(Color: stdio.Color, Message: string, DontReturn: boolean?)
	stdio.write(`{stdio.color(Color)}{Message}{not DontReturn and "\n" or ""}{stdio.color("reset")}`)
end

if FORCE_COMPILE or (not SKIP_COMPILE and stdio.prompt("confirm" :: "confirm", "Compile files?")) then
	PrettyPrint("blue", "Clearing Network folder...")
	if fs.isDir("../Network") then
		fs.removeDir("../Network")
		fs.writeDir("../Network")
		OkPrint(`Cleared Network folder.`)
	end

	PrettyPrint("blue", "Compiling source files...")
	for _, File in Sources do
		local Metadata = fs.metadata(`./Sources/{File}`)
		if Metadata.kind ~= "file" then
			continue
		end

		local Path = `../../test/Sources/{File}`
		PrettyPrint("cyan", `Compiling: {File}...`, true)
		local Result = process.exec("lune", { "run", Compiler, Path, "--", "--yes" }, { cwd = "../src/CLI" })
		if not Result.ok then
			ErrorPrint(`{File} failed to compile!\n{Result.stderr}`)
		else
			OkPrint(`{File} compiled successfully.`)
		end
	end

	PrettyPrint("green", `Successfully compiled {#Sources}/{#Sources} source files!`)
end

local Shared = require("./Shared")
local BaseEnvironment = Shared.GetEnvironment()
local ClientEnvironment = require("./Client")
local ServerEnvironment = require("./Server")

local function MockTypeof(a: any)
	local TypeofA = typeof(a)
	if TypeofA == "table" and a.__typeof then
		return a.__typeof
	end

	return TypeofA
end

local function MockRequire(Path: string, Environment)
	local Source = fs.readFile(Path)
	local Bytecode = luau.compile(Source, {
		optimizationLevel = 1,
		debugLevel = 2,
	})

	Environment._G = {}
	Environment.task = task
	Environment.typeof = MockTypeof
	Environment.require = function()
		error("require is not supported")
	end

	local Execute = luau.load(Bytecode, {
		debugName = Path,
		environment = Environment,
	})

	return Execute()
end

local Client: typeof(require("../Network/Client")) = MockRequire("../Network/Client.luau", {
	game = ClientEnvironment.game,
	Color3 = ClientEnvironment.Color3,
	DateTime = ClientEnvironment.DateTime,
	BrickColor = ClientEnvironment.BrickColor,
})

local Server: typeof(require("../Network/Server")) = MockRequire("../Network/Server.luau", {
	game = ServerEnvironment.game,
	Color3 = ServerEnvironment.Color3,
	DateTime = ServerEnvironment.DateTime,
	BrickColor = ServerEnvironment.BrickColor,
})

--> Helper functions
local function GetFlags(Amount: number): { [string]: boolean }
	local Flags = {}
	for Index = 1, Amount do
		Flags[`F{Index}`] = (math.random(1, 2) == 2)
	end
	return Flags
end

local function Fail(Name: string, Expect: any, Got: any)
	ErrorPrint(`Failed "{Name}"\nExpected: {Format(Expect)}\nGot: {Format(Got)}.`)
end

local function Equals(a: any, b: any)
	local Cyclic = {}
	local function Compare(a: any, b: any)
		local TypeA = type(a)
		local TypeB = type(b)

		if TypeA ~= TypeB then
			return false
		end

		if TypeA == "table" then
			if Cyclic[a] then
				return Cyclic[a] == b
			end

			Cyclic[a] = b

			local KeysB = {}
			local TableKeysB = {}

			for Key in b do
				if type(Key) == "table" then
					table.insert(TableKeysB, Key)
				end

				KeysB[Key] = true
			end

			for KeyA, ValueA in pairs(a) do
				local ValueB = b[KeyA]
				if type(KeyA) == "table" then
					local Match = false
					for Index, Key in TableKeysB do
						if Equals(KeyA, Key) and Compare(ValueA, b[Key]) then
							Match = true
							KeysB[Key] = nil
							table.remove(TableKeysB, Index)
							break
						end
					end

					if Match == false then
						return false
					end
				else
					if ValueB == nil then
						return false
					end

					KeysB[KeyA] = nil

					if not Compare(ValueA, ValueB) then
						return false
					end
				end
			end

			if next(KeysB) then
				return false
			end

			return true
		elseif TypeA == "buffer" then
			return buffer.tostring(a) == buffer.tostring(b)
		end

		return a == b
	end

	return Compare(a, b)
end

local function FireAndFail(Name: string, OutgoingEvent: any, IncomingEvent: any, Data: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	local Disconnect = IncomingEvent.On(function(First, Second)
		Result = if Second ~= nil then Second else First
	end)

	local Success = pcall(function()
		if OutgoingEvent.FireAll then
			OutgoingEvent.FireAll(Data)
		else
			OutgoingEvent.Fire(Data)
		end
	end)

	if not Success then
		OkPrint(`Event "{Name}" passed!`)
		return
	end

	--> Wait for replication
	task.wait(1 / 30)

	if Result ~= nil then
		ErrorPrint(`Failed "{Name}", expected it to fail, got "{Result}" instead.`)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpect(Name: string, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)

	local Disconnect = IncomingEvent.On(function(First, Second)
		if IsServerRecieving then
			if tostring(First) ~= "Player" then
				ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
			end

			Result = Second
		else
			Result = First
		end
	end)

	if IsServerSending then
		OutgoingEvent.FireAll(Expect)
	else
		OutgoingEvent.Fire(Expect)
	end

	--> Wait for replication
	task.wait(1 / 30)

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function InvokeAndExpect(
	Name: string,
	ClientFunction: any,
	ServerFunction: any,
	Data: any,
	Return: boolean?,
	YieldFor: number?
)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local ServerRecieve: unknown
	ServerFunction.On(function(Player, Recieve: any)
		if tostring(Player) ~= "Player" then
			ErrorPrint(`Expected argument #1 to {Name} to be Player, got {Player} instead.`)
		end

		ServerRecieve = Recieve
		if not Return then
			error("Expects fail")
		end

		if YieldFor then
			task.wait(YieldFor)
		end

		return Recieve
	end)

	local Success, Result = pcall(function()
		return ClientFunction.Invoke(Data)
	end)

	if not Return and Success then
		ErrorPrint(`Expected {Name} to encounter an error but it succeeded.`)
	elseif not Success and Return then
		ErrorPrint(`Expected {Name} to succeed but it encountered an error, {Result}.`)
	elseif Success and Return then
		if ServerRecieve ~= Data then
			ErrorPrint(`Expected server {Name} to recieve {Data}, got {ServerRecieve} instead.`)
		end

		if not Equals(Result, Data) then
			ErrorPrint(`Expected client {Name} to recieve {Data}, got {Result} instead.`)
		end
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function QueueAndExpect(Name: string, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	if OutgoingEvent.FireAll then
		OutgoingEvent.FireAll(Expect)
	else
		OutgoingEvent.Fire(Expect)
	end

	--> Let it sit in queue
	task.wait(0.5)

	local Disconnect = IncomingEvent.On(function(First, Second)
		Result = if Second ~= nil then Second else First
	end)

	--> Wait for queue to empty
	task.wait(1 / 30)

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpectAll(Name: string, OutgoingEvent: any, IncomingEvent: any, Values: { any })
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Events = 0
	local Results: { unknown } = {}
	local Disconnect = IncomingEvent.On(function(First, Second)
		local Value = (if Second ~= nil then Second else First)

		Events += 1
		Results[Events] = Value
	end)

	local Method = OutgoingEvent.FireAll or OutgoingEvent.Fire
	for Index = 1, table.maxn(Values) do
		Method(Values[Index])
	end

	--> Wait for replication
	task.wait(1 / 30)

	for Index, Expect in Values do
		local Result = Results[Index]
		if not Equals(Expect, Result) then
			Fail(Name, Expect, Result)
		end
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function FireAllAndExpectAll(
	Name: string,
	Times: number,
	Events: { [string]: { Outgoing: any, Incoming: any, Data: { any } } }
)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Results: { { unknown } } = {}
	local Disconnects: { () -> () } = {}

	--> Connect to events
	for Index, Event in Events do
		local EventResults = {}
		Results[Index] = EventResults
		table.insert(
			Disconnects,
			Event.Incoming.On(function(...)
				table.insert(EventResults, { ... })
			end)
		)
	end

	--> Fire events
	for Index, Event in Events do
		local Outgoing = Event.Outgoing
		local Method = Outgoing.FireAll or Outgoing.Fire
		for Index = 1, Times do
			Method(table.unpack(Event.Data))
		end
	end

	--> Wait for replication
	task.wait(1 / 30)

	for Index, Event in Events do
		local Data = Event.Data
		local EventResults = Results[Index]
		for ResultIndex = 1, Times do
			local Result = EventResults[ResultIndex]
			if not Equals(Data, Result) then
				ErrorPrint(`Failed "{Name}" at {Index}, mismatched value at {ResultIndex}.`)
			end
		end
	end

	for _, Disconnect in Disconnects do
		Disconnect()
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpectTuple(Name: string, OutgoingEvent: any, IncomingEvent: any, ...: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Results: { unknown } = {}
	local Disconnect = IncomingEvent.On(function(...)
		Results = { ... }
	end)

	local Method = OutgoingEvent.FireAll or OutgoingEvent.Fire
	Method(...)

	--> Wait for replication
	task.wait(1 / 30)

	for Index, Expect in { ... } do
		local Result = Results[Index]
		if not Equals(Expect, Result) then
			ErrorPrint(`Failed "{Name}", mismatched value at {Index}. Expected {Expect}, got {Result} instead.`)
		end
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function InvokeAndExpectTuple(
	Name: string,
	ClientFunction: any,
	ServerFunction: any,
	Data: { any },
	Return: { any }
)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local ServerRecieve: { unknown }
	ServerFunction.On(function(Player, ...)
		if tostring(Player) ~= "Player" then
			ErrorPrint(`Expected argument #1 to {Name} to be Player, got {Player} instead.`)
		end

		ServerRecieve = { ... }
		return table.unpack(Return)
	end)

	local ClientRecieve: { unknown }
	local Success, Error = pcall(function()
		ClientRecieve = { ClientFunction.Invoke(table.unpack(Data)) }
	end)

	if not Success then
		ErrorPrint(`Expected {Name} to succeed but it encountered an error, {Error}.`)
	elseif Success and Return then
		if not Equals(ServerRecieve, Data) then
			ErrorPrint(`Expected server {Name} to recieve {Data}, got {ServerRecieve} instead.`)
		end

		if not Equals(ClientRecieve, Return) then
			ErrorPrint(`Expected client {Name} to recieve {Data}, got {ClientRecieve} instead.`)
		end
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireManyAndExpectMany(Name: string, Count: number, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Results: { unknown } = {}
	local Disconnects: { () -> () } = {}

	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)

	for _ = 1, Count do
		table.insert(
			Disconnects,
			IncomingEvent.On(function(First, Second)
				local Value: unknown
				if IsServerRecieving then
					if tostring(First) ~= "Player" then
						ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
					end

					Value = Second
				else
					Value = First
				end

				table.insert(Results, Value)
			end)
		)
	end

	if IsServerSending then
		OutgoingEvent.FireAll(Expect)
	else
		OutgoingEvent.Fire(Expect)
	end

	--> Wait for replication
	task.wait(1 / 30)

	if #Results ~= Count then
		ErrorPrint(`Failed "{Name}", expected to recieve {Count} events, got {#Results} instead.`)
	end

	for _, Result in Results do
		if not Equals(Result, Expect) then
			Fail(Name, Expect, Result)
		end
	end

	for _, Disconnect in Disconnects do
		Disconnect()
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndPollExpect(Name: string, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result = "this is wrong"
	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)
	local FireEvent = IsServerSending and OutgoingEvent.FireAll or OutgoingEvent.Fire

	FireEvent(Expect)

	--> Wait for replication
	task.wait(1 / 30)

	for Index, First, Second in IncomingEvent.Iter() do
		if Index ~= 1 then
			ErrorPrint(`Failed "{Name}", expected only 1 event in the queue.`)
		end

		if IsServerRecieving then
			if tostring(First) ~= "Player" then
				ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
			end

			Result = Second
		else
			Result = First
		end
	end

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpectSeparate(Name: string, OutgoingEvent: any, IncomingEvent: any, Value: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)

	local Disconnect = IncomingEvent.On(function(First, Second)
		if IsServerRecieving then
			if tostring(First) ~= "Player" then
				ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
			end

			Result = Second
		else
			Result = First
		end
	end)

	if IsServerSending then
		OutgoingEvent.FireAll(Value)
	else
		OutgoingEvent.Fire(Value)
	end

	--> Wait for replication
	task.wait(1 / 30)

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function RunClosure(Name: string, Closure: () -> ())
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Trace: string?
	local Success = xpcall(Closure, function(Error)
		Trace = debug.traceback(`Failed "{Name}": {Error}`, 2)
	end)

	if not Success then
		ErrorPrint(Trace or `Failed "{Name}"`)
	end

	OkPrint(`Test "{Name}" passed!`)

	-- cleanup
	if Name == "Fuzz malformed packets" then
		return
	end

	pcall(function()
		Client.StepReplication()
		Server.StepReplication()
	end)
end

local function FireSignalSync(Signal, ...)
	for _, Callback in Signal.Connections do
		local Success, Error = pcall(Callback, ...)
		if not Success then
			ErrorPrint(`Malformed packet handler threw: {Error}`)
		end
	end
end

local function RandomBuffer(Size: number): buffer
	local Buffer = buffer.create(Size)
	for Offset = 0, Size - 1 do
		buffer.writeu8(Buffer, Offset, math.random(0, 255))
	end

	return Buffer
end

local function ExpectBytes(Name: string, Buffer: buffer, Expected: { number })
	if buffer.len(Buffer) ~= #Expected then
		ErrorPrint(`Golden snapshot "{Name}" expected {#Expected} bytes, got {buffer.len(Buffer)}.`)
	end

	for Offset = 0, #Expected - 1 do
		local Got = buffer.readu8(Buffer, Offset)
		local Expect = Expected[Offset + 1]
		if Got ~= Expect then
			ErrorPrint(`Golden snapshot "{Name}" byte {Offset} expected {Expect}, got {Got}.`)
		end
	end
end

local function DroppedTotal(Module): number
	local Metrics = Module.Stats()
	local DroppedPackets = Metrics.DroppedPackets or {}
	local Total = 0
	for _, Count in DroppedPackets do
		Total += Count
	end

	return Total
end

--> Tests
local Instance = setmetatable({
	__typeof = "Instance",
	IsA = function(self)
		return true
	end,
}, {
	__tostring = function()
		return "Instance"
	end,
})

local InstanceNeverIsA = setmetatable({
	__typeof = "Instance",
	ClassName = "Never",
	IsA = function(self)
		return false
	end,
}, {
	__tostring = function()
		return "Instance (Invalid)"
	end,
})

local Example: Client.Example = {
	Field = 0,
	Float16Field = 0,
	Enum = "A",
	Nested = {
		Guh = 1,
		Array = table.create(10, 0),
	},
}

PrettyPrint("blue", "Running output tests...")

FireAndExpect("Reliable Server", Server.ReliableServer, Client.ReliableServer, 1)
FireAndExpect("Unreliable Server", Server.UnreliableServer, Client.UnreliableServer, 1)
FireAndExpect("Empty Reliable Server", Server.EmptyEvent, Client.EmptyEvent, nil)
FireAndExpect("Empty Unreliable Server", Server.EmptyUnreliableEvent, Client.EmptyUnreliableEvent, nil)

RunClosure("State Channel Snapshot And Patch", function()
	local Updates = {}
	local Disconnect = Client.PlayerState.On(function(Value, Version, Patch)
		table.insert(Updates, {
			Value = Value,
			Version = Version,
			Patch = Patch,
		})
	end)

	Server.PlayerState.SetAll({
		Health = 100,
		Stamina = 80,
		Equipped = "Sword",
	})
	task.wait(1 / 10)

	local Snapshot = Client.PlayerState.Get()
	assert(Snapshot, "Expected PlayerState snapshot")
	assert(Snapshot.Health == 100, `Expected Health 100, got {Snapshot.Health}`)
	assert(Snapshot.Stamina == 80, `Expected Stamina 80, got {Snapshot.Stamina}`)
	assert(Snapshot.Equipped == "Sword", `Expected Equipped Sword, got {Snapshot.Equipped}`)
	assert(Client.PlayerState.Version() == 1, `Expected version 1, got {Client.PlayerState.Version()}`)

	Server.PlayerState.PatchAll({
		Stamina = 50,
	})
	task.wait(1 / 10)

	Snapshot = Client.PlayerState.Get()
	assert(Snapshot, "Expected PlayerState snapshot after patch")
	assert(Snapshot.Health == 100, `Expected Health 100 after patch, got {Snapshot.Health}`)
	assert(Snapshot.Stamina == 50, `Expected Stamina 50 after patch, got {Snapshot.Stamina}`)
	assert(Client.PlayerState.Version() == 2, `Expected version 2, got {Client.PlayerState.Version()}`)
	assert(#Updates == 2, `Expected 2 channel updates, got {#Updates}`)
	assert(Updates[2].Patch.Stamina == 50, "Expected patch payload to include Stamina")

	Disconnect()
end)

FireAndExpect("Reliable Client", Client.ReliableClient, Server.ReliableClient, 1)
FireAndExpect("Unreliable Client", Client.UnreliableClient, Server.UnreliableClient, 1)
FireAndExpect("Empty Reliable Client", Client.ClientEmptyEvent, Server.ClientEmptyEvent, nil)
FireAndExpect("Empty Unreliable Client", Client.ClientEmptyUnreliableEvent, Server.ClientEmptyUnreliableEvent, nil)

FireManyAndExpectMany("Many Reliable Sync Server", 8, Server.ManyReliableSync, Client.ManyReliableSync, 1)
FireManyAndExpectMany("Many Reliable Async Server", 8, Server.ManyReliableAsync, Client.ManyReliableAsync, 1)
FireManyAndExpectMany("Many Unreliable Sync Server", 8, Server.ManyUnreliableSync, Client.ManyUnreliableSync, 1)
FireManyAndExpectMany("Many Unreliable Async Server", 8, Server.ManyUnreliableAsync, Client.ManyUnreliableAsync, 1)

FireAndExpect("Unknown", Server.Unknown, Client.Unknown, newproxy())
FireAndExpect("Unknown (false)", Server.Unknown, Client.Unknown, false)
FireAndExpectAll("Unknown (nil mixed)", Server.Unknown, Client.Unknown, { "a", nil, "b", nil, nil, nil, "c" })

FireAndExpect(
	"Generic",
	Server.Generic,
	Client.Generic,
	{ Data = 0, Array = { 0 }, Optional = nil, Nested = { Value = 0 } }
)

FireAndExpect("Set 8", Server.Flags8, Client.Flags8, GetFlags(8))
FireAndExpect("Set 16", Server.Flags16, Client.Flags16, GetFlags(16))
FireAndExpect("Set 32", Server.Flags32, Client.Flags32, GetFlags(32))
FireAndExpect("Set >32", Server.Flags33, Client.Flags33, GetFlags(33))

FireAndExpect("Map", Server.MapEvent, Client.MapEvent, { ["string"] = 1 })
FireAndExpect("Map Struct", Server.MapStructEvent, Client.MapStructEvent, { Map = { string = 1 } })
FireAndExpect("Map Complex", Server.MapComplexEvent, Client.MapComplexEvent, { string = table.create(8, 1) })
FireAndExpect("Map Reference", Server.MapReferenceEvent, Client.MapReferenceEvent, { A = "A" })

FireAndExpect("Struct", Server.Reference, Client.Reference, Example)
FireAndExpect("Array", Server.ArrayPrimitive, Client.ArrayPrimitive, { 1, 2, 3, 4, 5, 6, 7, 8 })
FireAndExpect("Optional", Server.OptionalPrimitive, Client.OptionalPrimitive, 1)
FireAndExpect("Optional (nil)", Server.OptionalPrimitive, Client.OptionalPrimitive, nil)

FireAndExpect("Instance Any", Server.InstanceAny, Client.InstanceAny, Instance)
FireAndExpect("Instance Type", Server.InstanceOfType, Client.InstanceOfType, Instance)
FireAndFail("Instance Type (Fail)", Server.InstanceOfType, Client.InstanceOfType, nil)
FireAndExpect("Instance Optional", Server.InstanceOptional, Client.InstanceOptional, Instance)
FireAndExpectSeparate(
	"Instance Optional (nil)",
	Server.InstanceOptional,
	Client.InstanceOptional,
	Shared.ServerOnlyInstance,
	nil
)

local Array = table.create(8, Example)
FireAndExpect("Reference", Server.Reference, Client.Reference, Example)
FireAndExpect("Referency Array", Server.ReferenceArray, Client.ReferenceArray, Array)
FireAndExpect("Referency Optional", Server.ReferenceOptional, Client.ReferenceOptional, Example)
FireAndExpect("Referency Optional (nil)", Server.ReferenceOptional, Client.ReferenceOptional, nil)

InvokeAndExpect("Remote Function", Client.RemoteFunction, Server.RemoteFunction, 1, true)
InvokeAndExpect("Remote Function (yield)", Client.RemoteFunction, Server.RemoteFunction, 1, true, 1)
InvokeAndExpect("Remote Function (error)", Client.RemoteFunction, Server.RemoteFunction, 1, false)
InvokeAndExpect("Empty Remote Function", Client.EmptyFunction, Server.EmptyFunction, nil, true)
InvokeAndExpect("Unit Remote Function", Client.UnitFunction, Server.UnitFunction, nil, true)

QueueAndExpect("Reliable Queue", Server.ReliableServer, Client.ReliableServer, 1)
QueueAndExpect("Many Reliable Sync Queue", Server.ManyReliableSync, Client.ManyReliableSync, 1)
QueueAndExpect("Many Reliable Async Queue", Server.ManyReliableAsync, Client.ManyReliableAsync, 1)
--QueueAndExpect("Unreliable Queue", Server.UnreliableServer, Client.UnreliableServer, 1)

FireAndFail("Invalid Instance Any", Server.InstanceAny, Client.InstanceAny, true)
FireAndFail("Invalid Instance Type", Server.InstanceOfType, Client.InstanceOfType, InstanceNeverIsA)

FireAndExpectAll("Correct order", Server.ReliableServer, Client.ReliableServer, { 1, 2, 3, 4 })
FireAndExpectAll(
	"Multiple instances (nil and non nil)",
	Server.InstanceOptional,
	Client.InstanceOptional,
	{ nil, Instance, nil, Instance, Instance }
)

FireAndExpectAll("Many primitive", Server.ReliableServer, Client.ReliableServer, table.create(255, 1))
FireAndExpectAll("Many structs", Server.Reference, Client.Reference, table.create(255, Example))

FireAndExpectTuple(
	"Reliable Tuple",
	Server.Tuple,
	Client.Tuple,
	255,
	"A",
	65535,
	Instance,
	Instance,
	table.create(8, 0)
)
FireAndExpectTuple(
	"Unreliable Tuple",
	Server.TupleUnreliable,
	Client.TupleUnreliable,
	255,
	"A",
	65535,
	Instance,
	Instance
)
InvokeAndExpectTuple(
	"Function Tuple",
	Client.TupleFunction,
	Server.TupleFunction,
	{ 255, "A", 65535, Instance, Instance },
	{ Instance, Instance, 65535, "A", 255 }
)

FireAllAndExpectAll("Many events", 32, {
	Reliable = {
		Data = { 0 },
		Outgoing = Server.ReliableServer,
		Incoming = Client.ReliableServer,
	},
	Unreliable = {
		Data = { 0 },
		Outgoing = Server.UnreliableServer,
		Incoming = Client.UnreliableServer,
	},
	Reference = {
		Data = { Example },
		Outgoing = Server.Reference,
		Incoming = Client.Reference,
	},
	ReliableTuple = {
		Data = { 255, "A", 65535, Instance, Instance, table.create(8, 0) },
		Outgoing = Server.Tuple,
		Incoming = Client.Tuple,
	},
	UnreliableTuple = {
		Data = { 255, "A", 65535, Instance, Instance },
		Outgoing = Server.TupleUnreliable,
		Incoming = Client.TupleUnreliable,
	},
})

FireAndExpect("TagEnum Join", Server.PlayerEvent, Client.PlayerEvent, { Type = "Join", Name = "Player", UserId = 5 })
FireAndExpect("TagEnum Chat", Server.PlayerEvent, Client.PlayerEvent, { Type = "Chat", UserId = 5, Message = "Hello" })
FireAndExpect("TagEnum Leave", Server.PlayerEvent, Client.PlayerEvent, { Type = "Leave", UserId = 5 })

RunClosure("Color3", function()
	local Color = BaseEnvironment.Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))

	local Serialized = Server.Color.Write(Color)
	local Deserialized = Server.Color.Read(Serialized)

	assert(Color.R == Deserialized.R, `Expected {Color.R}, got {Deserialized.R}`)
	assert(Color.G == Deserialized.G, `Expected {Color.G}, got {Deserialized.G}`)
	assert(Color.B == Deserialized.B, `Expected {Color.B}, got {Deserialized.B}`)
end)

RunClosure("Color3 Array", function()
	local Array = {}
	for _ = 1, 32 do
		table.insert(
			Array,
			BaseEnvironment.Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))
		)
	end

	local Serialized = Server.ColorArray.Write(Array)
	local Deserialized = Server.ColorArray.Read(Serialized)

	assert(#Array == #Deserialized, `Expected {#Array} elements`)

	for Index, Got in Deserialized do
		local Expected = Array[Index]
		assert(Expected.R == Got.R, `Expected {Expected.R}, got {Got.R}`)
		assert(Expected.G == Got.G, `Expected {Expected.G}, got {Got.G}`)
		assert(Expected.B == Got.B, `Expected {Expected.B}, got {Got.B}`)
	end
end)

RunClosure("DateTime", function()
	for n = 1, 30 do
		local DateTime = BaseEnvironment.DateTime.fromUnixTimestamp(2 ^ n)
		local Serialized = Server.DateSeconds.Write(DateTime)
		local Deserialized = Server.DateSeconds.Read(Serialized)
		assert(
			DateTime.UnixTimestamp == Deserialized.UnixTimestamp,
			`Expected timestamp {DateTime.UnixTimestamp}, got {Deserialized.UnixTimestamp}`
		)
	end
end)

RunClosure("DateTimeMillis", function()
	for n = 1, 30 do
		local DateTime = BaseEnvironment.DateTime.fromUnixTimestampMillis(2 ^ n)
		local Serialized = Server.DateMilliseconds.Write(DateTime)
		local Deserialized = Server.DateMilliseconds.Read(Serialized)
		assert(
			DateTime.UnixTimestampMillis == Deserialized.UnixTimestampMillis,
			`Expected timestamp {DateTime.UnixTimestampMillis}, got {Deserialized.UnixTimestampMillis}`
		)
	end
end)

RunClosure("BrickColor", function()
	local BrickColor = BaseEnvironment.BrickColor.new(373)
	local Serialized = Server.BrickkColor.Write(BrickColor)
	local Deserialized = Server.BrickkColor.Read(Serialized)

	assert(
		BrickColor.Number == Deserialized.Number,
		`Expected BrickColor number to be {BrickColor.Number}, got {Deserialized.Number}`
	)
end)

RunClosure("Nested Map", function()
	local Map = { string = 1 }
	local Serialized = Server.MapNested.Write({ [Map] = Map })
	local Deserialized = Server.MapNested.Read(Serialized)

	local Elements = 0
	for KeyMap, ValueMap in Deserialized do
		if Elements >= 1 then
			error("Deserialized doesn't match original")
		end

		Elements += 1
		assert(type(KeyMap) == "table", "Deserialized doesn't match original")
		assert(type(ValueMap) == "table", "Deserialized doesn't match original")
		assert(type(KeyMap.string) == "number", "Deserialized doesn't match original")
		assert(type(ValueMap.string) == "number", "Deserialized doesn't match original")
	end
end)

RunClosure("Standalone", function()
	local Original = {
		One = 1,
		Two = 2,
		Three = 3,
		Event = { Type = "Join", Name = "JohnDoe", UserId = 1 },
		Nested = {
			Four = "ABC",
			Five = "DEF",
		},
	}

	local Serialized = Server.Standalone.Write(Original)
	local Deserialized = Server.Standalone.Read(Serialized)

	assert(Equals(Original, Deserialized), "Deserialized doesn't match original")
end)

RunClosure("Disconnect & Queue", function()
	local Expect = 1
	local Events = {
		"ReliableServer",
		"UnreliableServer",
		"ManyReliableSync",
		"ManyReliableAsync",
		"ManyUnreliableSync",
		"ManyUnreliableAsync",
	}

	for _, Event in Events do
		local Outgoing = Server[Event]
		local Incoming = Client[Event]

		local NeverRecieve: never
		Incoming.On(function(Value: never)
			NeverRecieve = Value
		end)()

		local Recieve: typeof(Expect)
		local RecieveDisconnect = Incoming.On(function(Value: typeof(Expect))
			Recieve = Value
		end)

		Outgoing.FireAll(Expect)

		task.wait(0.5)

		if Recieve ~= Expect then
			error(`Failed queue test on {Event}, expected "{Expect}", got "{Recieve}"`)
		end

		if NeverRecieve ~= nil then
			error(`Failed disconnect test on {Event}, disconnected listener still recieving.`)
		end

		RecieveDisconnect()
	end
end)

local Element = { Static = 0, Dynamic = buffer.create(64) }

FireAndExpect("Dynamic Array Data Integrity", Server.DynamicArray, Client.DynamicArray, table.create(12, Element))
FireAndExpect("Dynamic Map Data Integrity", Server.DynamicMap, Client.DynamicMap, table.create(64, Element))

RunClosure("CLI compile prompt", function()
	pcall(function()
		fs.removeDir("../Network")
	end)

	local Result: process.ExecResult
	local Thread = task.spawn(function()
		Result = process.exec("lune", { "run", Compiler, COMPILE_TEST_FILE }, { cwd = "../src/CLI" })
	end)

	if coroutine.status(Thread) ~= "suspended" then
		error(Result and Result.stderr or "CLI didn't prompt")
	end

	task.cancel(Thread)
end)

RunClosure("CLI compile --yes", function()
	local Result = process.exec("lune", { "run", Compiler, COMPILE_TEST_FILE, "--", "--yes" }, { cwd = "../src/CLI" })
	assert(Result.ok, Result.stderr)
end)

RunClosure("CI utility modes", function()
	for _, Flag in { "--doctor", "--benchmark", "--load-sim", "--capture-replay", "--golden-snapshots", "--compatibility", "--schema-docs" } do
		local Result = process.exec("lune", { "run", Compiler, COMPILE_TEST_FILE, "--", Flag, "--yes" }, { cwd = "../src/CLI" })
		assert(Result.ok, `{Flag} failed:\n{Result.stderr}`)
	end

	local StrictResult = process.exec(
		"lune",
		{ "run", Compiler, "../../test/Sources/StrictBad", "--", "--strict", "--yes" },
		{ cwd = "../src/CLI" }
	)
	assert(not StrictResult.ok, "Expected strict production mode to reject StrictBad.blink.")
end)

RunClosure("Protocol negotiation accepts mixed v1 and v2", function()
	do
		local Result
		local Disconnect = Server.ReliableClient.On(function(Player, Value)
			if tostring(Player) ~= "Player" then
				ErrorPrint(`Expected protocol negotiation player to be Player, got {Player}.`)
			end
			Result = Value
		end)

		Server.Configure({
			ProtocolVersion = 2,
			ProtocolMode = "Negotiated",
			AcceptProtocolVersion1 = true,
			EnableProtocolHandshake = true,
			RateLimitPerSecond = 0,
		})
		Client.Configure({
			ProtocolVersion = 1,
			ProtocolMode = "Legacy",
			EnableProtocolHandshake = false,
			RateLimitPerSecond = 0,
		})

		Client.ReliableClient.Fire(7)
		Client.StepReplication()
		task.wait(1 / 30)
		assert(Result == 7, `Expected negotiated server to accept v1 client packet, got {Result}.`)
		Disconnect()
	end

	do
		local Result
		local Disconnect = Client.ReliableServer.On(function(Value)
			Result = Value
		end)

		Client.Configure({
			ProtocolVersion = 2,
			ProtocolMode = "Negotiated",
			AcceptProtocolVersion1 = true,
			EnableProtocolHandshake = true,
			RateLimitPerSecond = 0,
		})
		Server.Configure({
			ProtocolVersion = 1,
			ProtocolMode = "Legacy",
			EnableProtocolHandshake = false,
			RateLimitPerSecond = 0,
		})

		Server.ReliableServer.FireAll(8)
		Server.StepReplication()
		task.wait(1 / 30)
		assert(Result == 8, `Expected negotiated client to accept v1 server packet, got {Result}.`)
		Disconnect()
	end

	Client.Configure({
		ProtocolVersion = 2,
		ProtocolMode = "Negotiated",
		AcceptProtocolVersion1 = true,
		EnableProtocolHandshake = true,
		RateLimitPerSecond = 0,
	})
	Server.Configure({
		ProtocolVersion = 2,
		ProtocolMode = "Negotiated",
		AcceptProtocolVersion1 = true,
		EnableProtocolHandshake = true,
		RateLimitPerSecond = 0,
	})
end)

RunClosure("Capture replay inspector and schema helpers", function()
	Client.Capture.Clear()
	Server.Capture.Clear()
	Client.Capture.Start({ Limit = 64, Redactions = { "Secret" } })
	Server.Capture.Start({ Limit = 64 })

	local Disconnect = Client.ReliableServer.On(function() end)
	Server.ReliableServer.FireAll(42)
	Server.StepReplication()
	task.wait(1 / 30)
	Disconnect()

	local Entries = Client.Capture.Entries()
	local FoundReceive = false
	for _, Entry in Entries do
		if Entry.Name == "ReliableServer" and Entry.Direction == "receive" and Entry.Status == "accepted" then
			FoundReceive = true
			assert(string.find(Entry.PayloadSummary or "", "42", 1, true), "Expected capture payload summary to include decoded value.")
		end
	end
	assert(FoundReceive, "Expected an accepted ReliableServer receive capture.")

	local Replayed = 0
	local Replay = Client.Capture.Replay(Entries, {
		ReliableServer = function()
			Replayed += 1
		end,
	})
	assert(Replay.Accepted > 0, "Expected replay to count accepted entries.")
	assert(Replayed > 0, "Expected replay handler to be called.")

	Client.Inspector.Enable(true)
	local Snapshot = Client.Inspector.Snapshot()
	assert(Snapshot.Metrics.CapturedPackets >= 1, "Expected inspector snapshot to include captured packet count.")
	assert(Snapshot.Protocol.LocalSchemaVersion == 2, "Expected inspector protocol schema version.")

	Client.Schema.SetDefault("Defaulted", 99)
	Client.Schema.RenameField("OldName", "NewName")
	Client.Schema.DeprecateField("RemoveMe")
	Client.Schema.RegisterMigration(1, function(Payload)
		Payload.Migrated = true
		return Payload
	end)

	local Migrated, Version = Client.Schema.Migrate({
		OldName = 1,
		RemoveMe = true,
	}, 1)
	assert(Version == 2, `Expected migrated version 2, got {Version}.`)
	assert(Migrated.NewName == 1, "Expected renamed field to migrate.")
	assert(Migrated.Defaulted == 99, "Expected default field to be applied.")
	assert(Migrated.RemoveMe == nil, "Expected deprecated field to be removed.")
	assert(Migrated.Migrated == true, "Expected migration stub callback to run.")

	Client.Capture.Stop()
	Server.Capture.Stop()
end)

RunClosure("Replication adapter stubs", function()
	local Published
	local MessagingService = {
		PublishAsync = function(self, Topic, Data)
			Published = {
				Topic = Topic,
				Data = Data,
			}
			return true
		end,
		SubscribeAsync = function(self, Topic, Callback)
			return {
				Disconnect = function() end,
			}
		end,
	}

	local Messaging = Server.Replication.MessagingService("blink:test", MessagingService)
	Messaging.PublishGroup("party-a", { Score = 10 })
	assert(Published.Topic == "blink:test", "Expected MessagingService topic.")
	assert(Published.Data.Channel == "group:party-a", "Expected MessagingService group channel.")
	assert(Published.Data.SchemaVersion == 2, "Expected MessagingService schema version.")

	local Stored
	local MemoryStoreService = {
		GetSortedMap = function(self, Name)
			return {
				SetAsync = function(self, Key, Value, Expiration)
					Stored = {
						Name = Name,
						Key = Key,
						Value = Value,
						Expiration = Expiration,
					}
				end,
				GetAsync = function(self, Key)
					return Stored and Stored.Value
				end,
				RemoveAsync = function(self, Key)
					Stored = nil
				end,
			}
		end,
	}

	local Memory = Server.Replication.MemoryStore("blink:state", MemoryStoreService)
	Memory.SetZone("PlayerState", "lobby", "snapshot", { Health = 100 }, 30)
	assert(Stored.Name == "blink:state", "Expected MemoryStore map name.")
	assert(Stored.Key == "zone:PlayerState:lobby:snapshot", "Expected scoped MemoryStore key.")
	assert(Stored.Value.SchemaVersion == 2, "Expected MemoryStore schema version.")
	assert(Stored.Expiration == 30, "Expected MemoryStore expiration.")
end)

RunClosure("Golden binary snapshots", function()
	ExpectBytes("Byte", Client.Byte.Write(5), { 5 })
	ExpectBytes("GoldenFlags8", Client.GoldenFlags8.Write({
		F1 = true,
		F2 = false,
		F3 = false,
		F4 = false,
		F5 = false,
		F6 = false,
		F7 = false,
		F8 = true,
	}), { 129 })

	local Exact = buffer.create(9)
	for Offset = 0, 8 do
		buffer.writeu8(Exact, Offset, Offset)
	end
	ExpectBytes("ExactBuffer", Client.ExactBuffer.Write(Exact), { 0, 1, 2, 3, 4, 5, 6, 7, 8 })
end)

local MergeStruct: Server.MergeStruct = {
	Data = 1,
	Field = 0,
	Float16Field = 0,
	Enum = "A",
	Nested = {
		Guh = 1,
		Array = table.create(10, 0),
	},
	AnotherNested = {
		Value = 1,
	},
	Map = {
		[{ 0 }] = 0,
	},
	Struct = {
		Data = 0,
		Array = { 0 },
		Nested = {
			Value = "hi",
		},
	},
}

FireAndPollExpect("Poll Reliable Client", Client.ClientPollEvent, Server.ClientPollEvent, MergeStruct)
FireAndPollExpect("Poll Reliable Server", Server.ServerPollEvent, Client.ServerPollEvent, MergeStruct)
FireAndPollExpect(
	"Poll Unreliable Client",
	Client.ClientUnreliablePollEvent,
	Server.ClientUnreliablePollEvent,
	MergeStruct
)
FireAndPollExpect(
	"Poll Unreliable Server",
	Server.ServerUnreliablePollEvent,
	Client.ServerUnreliablePollEvent,
	MergeStruct
)
FireAndPollExpect("Poll Empty Reliable Client", Client.ClientEmptyPollEvent, Server.ClientEmptyPollEvent, nil)
FireAndPollExpect("Poll Empty Reliable Server", Server.ServerEmptyPollEvent, Client.ServerEmptyPollEvent, nil)
FireAndPollExpect(
	"Poll Empty Unreliable Client",
	Client.ClientEmptyUnreliablePollEvent,
	Server.ClientEmptyUnreliablePollEvent,
	nil
)
FireAndPollExpect(
	"Poll Empty Unreliable Server",
	Server.ServerEmptyUnreliablePollEvent,
	Client.ServerEmptyUnreliablePollEvent,
	nil
)

RunClosure("Queue up and poll", function()
	local Expect = 10
	local Results = {
		Client = {},
		Server = {},
	}

	for _ = 1, Expect do
		Client.ClientPollEvent.Fire(MergeStruct)
		Server.ServerPollEvent.FireAll(MergeStruct)
	end

	task.wait(1 / 30)

	for Index, Value in Client.ServerPollEvent.Iter() do
		table.insert(Results.Client, Value)
	end

	for Index, Player, Value in Server.ClientPollEvent.Iter() do
		if tostring(Player) ~= "Player" then
			ErrorPrint(`Expected argument #1 to be Player, got {Player} instead.`)
		end

		table.insert(Results.Server, Value)
	end

	for _, Context in Results do
		if #Context ~= Expect then
			ErrorPrint(`Expected to poll {Expect} events, got {#Results.Client} instead`)
		end

		for _, Result in Context do
			if not Equals(Result, MergeStruct) then
				Fail("Closure", Expect, Result)
			end
		end
	end
end)

RunClosure("Ranges should be enforced", function()
	do
		local UpperSuccess = pcall(function()
			Client.NegativeRange.Write(11)
		end)

		local LowerSuccess = pcall(function()
			Client.NegativeRange.Write(-6)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected integer range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			Client.DecimalRange.Write(10.6)
		end)

		local LowerSuccess = pcall(function()
			Client.DecimalRange.Write(-5.6)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected decimal range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			Client.UnboundUpper.Write(2 ^ 53 + 1)
		end)

		local LowerSuccess = pcall(function()
			Client.UnboundUpper.Write(-1)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected unbound upper range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			Client.UnboundLower.Write(1)
		end)

		local LowerSuccess = pcall(function()
			Client.UnboundLower.Write(-(2 ^ 53 + 1))
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected unbound upper range to be enforced.")
		end
	end

	Client.ExactRange.Write(0)

	Client.DecimalRange.Write(-5.5)
	Client.DecimalRange.Write(10)

	Client.NegativeRange.Write(-5)
	Client.NegativeRange.Write(10)

	Client.UnboundUpper.Write(0)
	Client.UnboundUpper.Write(16777216)

	Client.UnboundLower.Write(-16777216)
	Client.UnboundLower.Write(0)
end)

RunClosure("Multi Dimensional Array", function()
	local Array = { { { 1, 2, 3, 4, 5, 6 } } }
	local Serialized = Client.MultiDimensionalArray.Write(Array)
	local Deserialized = Client.MultiDimensionalArray.Read(Serialized)

	if not Equals(Array, Deserialized) then
		ErrorPrint(`Expected: {Format(Array)}, got: {Format(Deserialized)} instead`)
	end
end)

do
	local foo: Client.Issue33_Foo = "One"
	local map: Client.Issue33_Map<number> = { [foo] = 0 }
	local enum: Client.Issue33_Enum<number> = { Tag = "Variant", field = foo }
	local struct: Client.Issue33_Struct<number> = { field = foo }

	FireAndExpectTuple(
		"Generics containing a unit enum value",
		Server.Issue33.Event,
		Client.Issue33.Event,
		map,
		enum,
		struct
	)
end

RunClosure("Export buffer trimming", function()
	local Buffer = Client.Byte.Write(0)
	if buffer.len(Buffer) ~= 1 then
		ErrorPrint(`Expected buffer to be trimmed to 1 byte`)
	end
end)

do
	local enum: Client.Indexers_TestEnums = "b b"
	local flags: Client.Indexers_TestFlags = { ["a a"] = true }
	local struct: Client.Indexers_TestStruct = {
		["z z"] = 0,
		["1 1"] = 1,
		["2 2"] = 2,
		["3 3"] = 3,
	}
	local tagged: Client.Indexers_TestTaggedEnums = {
		Type = "c c",
		Test = 1,
	}

	FireAndExpectTuple("Indexers", Server.Indexers.TestEvent, Client.Indexers.TestEvent, struct, flags, enum, tagged)
end

RunClosure("Buffer (Default, Fixed, Bounded)", function()
	local ExactBuffer = buffer.create(9)
	local BoundedBuffer = buffer.create(256)

	-- write some random bytes
	for offset = 0, 8, 4 do
		buffer.writeu8(ExactBuffer, offset, math.random(0, 2 ^ 30))
	end

	for offset = 0, 255, 4 do
		buffer.writeu8(BoundedBuffer, offset, math.random(0, 2 ^ 30))
	end

	-- test serdes
	do
		local Serialised = Client.Buffer.Write(BoundedBuffer)
		local Deserialised = Client.Buffer.Read(Serialised)
		assert(Equals(BoundedBuffer, Deserialised), `Default buffer serdes failed`)
	end

	do
		local Serialised = Client.ExactBuffer.Write(ExactBuffer)
		local Deserialised = Client.ExactBuffer.Read(Serialised)
		assert(Equals(ExactBuffer, Deserialised), `Fixed buffer serdes failed`)
	end

	do
		local Serialised = Client.BoundedBuffer.Write(BoundedBuffer)
		local Deserialised = Client.BoundedBuffer.Read(Serialised)
		assert(Equals(BoundedBuffer, Deserialised), `Bounded buffer serdes failed`)
	end
end)

RunClosure("Fuzz malformed packets", function()
	Server.Configure({
		ProtocolVersion = 2,
		ProtocolMode = "Strict",
		AcceptProtocolVersion1 = false,
		MaxReliablePacketBytes = 256,
		MaxUnreliablePacketBytes = 256,
		RateLimitPerSecond = 0,
	})
	Client.Configure({
		ProtocolVersion = 2,
		ProtocolMode = "Strict",
		AcceptProtocolVersion1 = false,
		MaxReliablePacketBytes = 256,
		MaxUnreliablePacketBytes = 256,
		RateLimitPerSecond = 0,
	})

	local ServerReliable = ServerEnvironment.Instances.BLINK_RELIABLE_REMOTE.OnServerEvent
	local ServerUnreliable = ServerEnvironment.Instances.BLINK_UNRELIABLE_REMOTE.OnServerEvent
	local ClientReliable = ClientEnvironment.Instances.BLINK_RELIABLE_REMOTE.OnClientEvent
	local ClientUnreliable = ClientEnvironment.Instances.BLINK_UNRELIABLE_REMOTE.OnClientEvent

	local Before = DroppedTotal(Server) + DroppedTotal(Client)
	local Oversized = buffer.create(257)
	FireSignalSync(ServerReliable, Shared.Player, Oversized, {})
	FireSignalSync(ClientReliable, Oversized, {})

	local Empty = buffer.create(0)
	FireSignalSync(ServerReliable, Shared.Player, Empty, { "not an instance" })
	FireSignalSync(ServerReliable, Shared.Player, Empty, "not a table")
	FireSignalSync(ClientReliable, Empty, { "not an instance" })
	FireSignalSync(ClientReliable, Empty, "not a table")

	for _ = 1, 128 do
		local Packet = RandomBuffer(math.random(1, 96))
		FireSignalSync(ServerReliable, Shared.Player, Packet, {})
		FireSignalSync(ServerUnreliable, Shared.Player, Packet, {})
		FireSignalSync(ClientReliable, Packet, {})
		FireSignalSync(ClientUnreliable, Packet, {})
	end

	local After = DroppedTotal(Server) + DroppedTotal(Client)
	if After <= Before then
		ErrorPrint("Expected malformed packet fuzzing to record dropped packets.")
	end
end)

PrettyPrint("green", `All tests passed successfully!`)

process.exit(0)
