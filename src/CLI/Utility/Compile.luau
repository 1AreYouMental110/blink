--!strict

---- Imports ----

local fs = require("@lune/fs")
local stdio = require("@lune/stdio")

local Error = require("../../Modules/Error")
local Generator = require("../../Generator")
local GetDefinitionFilePath = require("./GetDefinitionFilePath")
local Parser = require("../../Parser")
local PathParser = require("../../Modules/Path")

---- Settings ----

export type CompileOptions = {
	Debug: boolean,
	Silent: boolean,
	Compact: boolean,
	YesToEverything: boolean,
	OutputAbstractSyntaxTree: boolean,
}

type Span = {
	Start: number,
	End: number,
}

type Diagnostic = {
	Message: string,
	File: string?,
	Span: Span?,
}

---- Constants ----

local Utility = {}

---- Variables ----

---- Private Functions ----

local function Message(Color: stdio.Color, Options: CompileOptions, ...)
	if Options.Silent then
		return
	end

	stdio.write(stdio.color(Color))
	print(...)
	stdio.write(stdio.color("reset"))
end

local function FormatTime(Time: number): string
	if Time < 1E-6 then
		return `{Time * 1E+9} ns`
	elseif Time < 0.001 then
		return `{Time * 1E+6} μs`
	elseif Time < 1 then
		return `{Time * 1000} ms`
	else
		return `{Time} seconds`
	end
end

local function CreateDirectoryIfNotFound(Path: string, Options: CompileOptions)
	local Directory = PathParser.Directory(Path) or "./"
	if fs.isDir(Directory) then
		return
	end

	local Result = Options.YesToEverything
		or stdio.prompt("confirm", `Directory {Directory} doesn't exist, create directory?`)

	if Result then
		fs.writeDir(Directory)
		return
	end

	error("User refused prompt to create directory")
end

---- Public Functions ----

function Utility.Compile(Path: string, Options: CompileOptions)
	local FilePath = GetDefinitionFilePath(Path)
	Error.SetCompact(Options.Compact)

	Message("cyan", Options, `Reading source from {FilePath}...`)
	local Source = fs.readFile(FilePath)

	Message("blue", Options, "Parsing source into AST...")
	local FileDirectory = PathParser.Directory(FilePath) or "./"
	local SourceParser = Parser.new(FileDirectory, PathParser.NameWithExtension(FilePath))

	local ParseStart = os.clock()
	local AbstractSyntaxTree = SourceParser:Parse(Source)
	local ParseTime = (os.clock() - ParseStart)

	if Options.OutputAbstractSyntaxTree then
		print(AbstractSyntaxTree.Value.Options)
		print(AbstractSyntaxTree.Value.Declarations)
		return
	end

	local FileOptions = AbstractSyntaxTree.Value.Options
	if FileOptions.StrictProduction then
		Utility.Strict(Path, Options)
	end
	if (FileOptions.ProtocolVersion or 2) < 2 then
		error("This Blink fork is v2-only; ProtocolVersion below 2 is not supported.")
	end
	if FileOptions.ProtocolMode ~= nil then
		error("ProtocolMode is retired in this v2-only fork; omit it instead of using Legacy or Negotiated.")
	end
	if FileOptions.AcceptProtocolVersion1 ~= nil then
		error("AcceptProtocolVersion1 is retired in this v2-only fork.")
	end

	local ClientOutputPath = FileOptions.ClientOutput
	local ServerOutputPath = FileOptions.ServerOutput

	assert(ClientOutputPath, "A client output path must be defined.")
	assert(ServerOutputPath, "A server output path must be defined.")

	local ClientTypescriptPath
	local ServerTypescriptPath

	do
		local Directory, Filename = PathParser.Components(ClientOutputPath)
		local TypescriptFilename = if Filename == "init" then "index" else Filename
		ClientOutputPath = `{Directory}/{Filename}.luau`
		ClientTypescriptPath = if PathParser.PathType(ClientOutputPath) == "absolute"
			then `{Directory}/{TypescriptFilename}.d.ts`
			else `{FileDirectory}{Directory}/{TypescriptFilename}.d.ts`
	end

	do
		local Directory, Filename = PathParser.Components(ServerOutputPath)
		local TypescriptFilename = if Filename == "init" then "index" else Filename
		ServerOutputPath = `{Directory}/{Filename}.luau`
		ServerTypescriptPath = if PathParser.PathType(ServerOutputPath) == "absolute"
			then `{Directory}/{TypescriptFilename}.d.ts`
			else `{FileDirectory}{Directory}/{TypescriptFilename}.d.ts`
	end

	local TypesOutput: string

	local ClientOutput: string
	local ServerOutput: string

	if PathParser.PathType(ClientOutputPath) == "absolute" then
		ClientOutput = ClientOutputPath
	else
		ClientOutput = `{FileDirectory}{ClientOutputPath}`
	end

	if PathParser.PathType(ServerOutputPath) == "absolute" then
		ServerOutput = ServerOutputPath
	else
		ServerOutput = `{FileDirectory}{ServerOutputPath}`
	end

	CreateDirectoryIfNotFound(ClientOutput, Options)
	CreateDirectoryIfNotFound(ServerOutput, Options)

	Message("blue", Options, "Generating output files...")
	local FilesStart = os.clock()

	local ServerGenerateStart = os.clock()
	local ServerSource = Generator.Generate("Server", AbstractSyntaxTree)
	local ServerGenerateTime = (os.clock() - ServerGenerateStart)

	local ClientGenerateStart = os.clock()
	local ClientSource = Generator.Generate("Client", AbstractSyntaxTree)
	local ClientGenerateTime = (os.clock() - ClientGenerateStart)

	local TypesSource: string?
	if FileOptions.TypesOutput then
		TypesOutput = if PathParser.PathType(Path) == "absolute"
			then FileOptions.TypesOutput
			else `{FileDirectory}{FileOptions.TypesOutput}`
		TypesSource = Generator.GenerateShared(AbstractSyntaxTree)
	end

	local ClientTypescriptSource: string?
	local ServerTypescriptSource: string?
	if FileOptions.Typescript then
		ClientTypescriptSource = Generator.GenerateTypescript("Client", AbstractSyntaxTree)
		ServerTypescriptSource = Generator.GenerateTypescript("Server", AbstractSyntaxTree)
	end

	local FilesTime = (os.clock() - FilesStart)
	fs.writeFile(ServerOutput, ServerSource)
	fs.writeFile(ClientOutput, ClientSource)

	if TypesSource and TypesOutput then
		CreateDirectoryIfNotFound(TypesOutput, Options)
		fs.writeFile(TypesOutput, TypesSource)
	end

	if ClientTypescriptSource and ServerTypescriptSource then
		fs.writeFile(ClientTypescriptPath, ClientTypescriptSource)
		fs.writeFile(ServerTypescriptPath, ServerTypescriptSource)
	end

	Message("green", Options, "Network files generated!")

	if Options.Debug and not Options.Silent then
		print(`[DEBUG]: Parsed source in {FormatTime(ParseTime)}.`)
		print(`[DEBUG]: Generated server luau in {FormatTime(ServerGenerateTime)}.`)
		print(`[DEBUG]: Generated client luau in {FormatTime(ClientGenerateTime)}.`)
		print(`[DEBUG]: Generated files in {FormatTime(FilesTime)}.`)
		print(`[DEBUG]: Completed everything in {FormatTime(ParseTime + FilesTime)}.`)
	end
end

local function ParseForUtility(Path: string, Options: CompileOptions): (Parser.Body, string, string)
	local FilePath = GetDefinitionFilePath(Path)
	Error.SetCompact(Options.Compact)
	local Source = fs.readFile(FilePath)
	local FileDirectory = PathParser.Directory(FilePath) or "./"
	local SourceParser = Parser.new(FileDirectory, PathParser.NameWithExtension(FilePath))
	return SourceParser:Parse(Source), Source, FilePath
end

local function WalkDeclarations(Declarations: { Parser.Declaration }, Callback: (Parser.Declaration) -> ())
	for _, Declaration in Declarations do
		Callback(Declaration)
		if Declaration.Type == "Scope" then
			WalkDeclarations((Declaration :: Parser.ScopeNode).Value.Values, Callback)
		end
	end
end

local function EscapePattern(Text: string): string
	return string.gsub(Text, "([^%w])", "%%%1")
end

local function FindOptionSpan(Source: string, Name: string): Span?
	local Start, Finish = string.find(Source, `option%s+{EscapePattern(Name)}`)
	if Start == nil or Finish == nil then
		return nil
	end

	return {
		Start = Start,
		End = Finish,
	}
end

local function FindDeclarationSpan(Source: string, Kind: string, Name: string): Span?
	local Start, Finish = string.find(Source, `{Kind}%s+{EscapePattern(Name)}`)
	if Start == nil or Finish == nil then
		return nil
	end

	return {
		Start = Start,
		End = Finish,
	}
end

local function LineColumn(Source: string, Offset: number): (number, number)
	local Line = 1
	local LineStart = 1
	for Index = 1, math.max(1, Offset - 1) do
		if string.sub(Source, Index, Index) == "\n" then
			Line += 1
			LineStart = Index + 1
		end
	end

	return Line, math.max(1, Offset - LineStart + 1)
end

local function SchemaVersion(FileOptions: Parser.Options): number
	return FileOptions.SchemaVersion or FileOptions.Version or 1
end

local function ProtocolVersion(FileOptions: Parser.Options): number
	return FileOptions.ProtocolVersion or 2
end

local function ProtocolMode(FileOptions: Parser.Options): string
	return FileOptions.ProtocolMode or "StrictV2Only"
end

local function IsUnsafeOutputPath(Path: string?): boolean
	if Path == nil then
		return true
	end

	local Lower = string.lower(Path)
	return string.find(Lower, "..", 1, true) ~= nil or PathParser.PathType(Path) == "absolute"
end

local function CollectProductionDiagnostics(
	Ast: Parser.Body,
	Strict: boolean,
	Source: string,
	FilePath: string
): ({ Diagnostic }, { Diagnostic })
	local FileOptions = Ast.Value.Options
	local Warnings = {}
	local Errors = {}

	local function CreateDiagnostic(MessageText: string, Span: Span?): Diagnostic
		return {
			Message = MessageText,
			File = FilePath,
			Span = Span,
		}
	end

	local function Warn(MessageText: string, Span: Span?)
		table.insert(Warnings, CreateDiagnostic(MessageText, Span))
	end

	local function Fail(MessageText: string, Span: Span?)
		if Strict then
			table.insert(Errors, CreateDiagnostic(MessageText, Span))
		else
			table.insert(Warnings, CreateDiagnostic(MessageText, Span))
		end
	end

	local Profile = FileOptions.SecurityProfile or "Development"
	local Version = ProtocolVersion(FileOptions)
	local Mode = ProtocolMode(FileOptions)
	local RateLimit = FileOptions.RateLimitPerSecond
	local ReliableLimit = FileOptions.MaxReliablePacketBytes or FileOptions.MaxPacketBytes
	local UnreliableLimit = FileOptions.MaxUnreliablePacketBytes or FileOptions.MaxPacketBytes
	local InvokeTimeout = FileOptions.InvokeTimeoutSeconds

	if Version < 2 then
		Fail("ProtocolVersion below 2 is unsupported in this v2-only fork.", FindOptionSpan(Source, "ProtocolVersion"))
	end

	if FileOptions.ProtocolMode ~= nil then
		Fail(
			`ProtocolMode "{Mode}" is retired; this fork always uses strict v2 framing.`,
			FindOptionSpan(Source, "ProtocolMode")
		)
	end

	if FileOptions.AcceptProtocolVersion1 ~= nil then
		Fail(
			"AcceptProtocolVersion1 is retired in this v2-only fork.",
			FindOptionSpan(Source, "AcceptProtocolVersion1")
		)
	end

	if (ReliableLimit or math.huge) > 1024 * 1024 then
		Warn(
			"MaxReliablePacketBytes/MaxPacketBytes is above 1 MiB; lower this for public servers.",
			FindOptionSpan(
				Source,
				if FileOptions.MaxReliablePacketBytes then "MaxReliablePacketBytes" else "MaxPacketBytes"
			)
		)
	end

	if Strict then
		if Profile ~= "Production" and Profile ~= "Competitive" then
			Fail(
				"Strict production mode requires SecurityProfile = Production or Competitive.",
				FindOptionSpan(Source, "SecurityProfile")
			)
		end

		if ReliableLimit == nil or ReliableLimit <= 0 then
			Fail(
				"Reliable packet size is unlimited; set MaxReliablePacketBytes or MaxPacketBytes.",
				FindOptionSpan(Source, "MaxReliablePacketBytes") or FindOptionSpan(Source, "MaxPacketBytes")
			)
		end

		if UnreliableLimit == nil or UnreliableLimit <= 0 then
			Fail(
				"Unreliable packet size is unlimited; set MaxUnreliablePacketBytes or MaxPacketBytes.",
				FindOptionSpan(Source, "MaxUnreliablePacketBytes") or FindOptionSpan(Source, "MaxPacketBytes")
			)
		end

		if RateLimit == nil or RateLimit <= 0 then
			Fail("RateLimitPerSecond is missing or disabled.", FindOptionSpan(Source, "RateLimitPerSecond"))
		end

		if InvokeTimeout == nil or InvokeTimeout <= 0 then
			Fail("InvokeTimeoutSeconds is missing or disabled.", FindOptionSpan(Source, "InvokeTimeoutSeconds"))
		end

		if FileOptions.SyncValidation == true then
			Fail("SyncValidation is enabled in a production build.", FindOptionSpan(Source, "SyncValidation"))
		end

		if FileOptions.WriteValidations == true then
			Fail("WriteValidations is enabled in a production build.", FindOptionSpan(Source, "WriteValidations"))
		end

		if IsUnsafeOutputPath(FileOptions.ClientOutput) then
			Fail(
				"ClientOutput is unsafe for strict production builds; use a contained relative path.",
				FindOptionSpan(Source, "ClientOutput")
			)
		end

		if IsUnsafeOutputPath(FileOptions.ServerOutput) then
			Fail(
				"ServerOutput is unsafe for strict production builds; use a contained relative path.",
				FindOptionSpan(Source, "ServerOutput")
			)
		end
	end

	if (RateLimit or 0) == 0 and Profile ~= "Development" then
		Warn(
			"RateLimitPerSecond is disabled outside the Development profile.",
			FindOptionSpan(Source, "RateLimitPerSecond")
		)
	end

	if not FileOptions.ClientOutput then
		Warn("ClientOutput is missing; CLI generation requires it.", nil)
	end
	if not FileOptions.ServerOutput then
		Warn("ServerOutput is missing; CLI generation requires it.", nil)
	end

	WalkDeclarations(Ast.Value.Declarations, function(Declaration)
		if Declaration.Type == "Event" then
			local Event = Declaration :: Parser.Event
			if
				Event.Value.From == "Client"
				and Event.Value.Auth == nil
				and Event.Value.Policy == nil
				and Event.Value.PolicyGroup == nil
			then
				Fail(
					`Client-origin event "{Declaration.Name}" has no Auth, Policy, or PolicyGroup rule.`,
					FindDeclarationSpan(Source, "event", Declaration.Name)
				)
			end
		elseif Declaration.Type == "Function" then
			local Function = Declaration :: Parser.Function
			if Function.Value.Auth == nil and Function.Value.Policy == nil and Function.Value.PolicyGroup == nil then
				Fail(
					`Function "{Declaration.Name}" has no Auth, Policy, or PolicyGroup rule.`,
					FindDeclarationSpan(Source, "function", Declaration.Name)
				)
			end
		end
	end)

	return Warnings, Errors
end

local function FormatDiagnostic(Diagnostic: Diagnostic, Source: string): string
	if Diagnostic.Span == nil or Diagnostic.File == nil then
		return Diagnostic.Message
	end

	local Line, Column = LineColumn(Source, Diagnostic.Span.Start)
	return `{Diagnostic.File}:{Line}:{Column}: {Diagnostic.Message}`
end

local function PrintDiagnostics(
	Title: string,
	Options: CompileOptions,
	Warnings: { Diagnostic },
	Errors: { Diagnostic },
	Source: string
)
	local Total = #Warnings + #Errors
	if Total == 0 then
		Message("green", Options, `{Title} passed with no diagnostics.`)
		return
	end

	local Color: stdio.Color = if #Errors > 0 then "red" else "yellow"
	Message(Color, Options, `{Title} found {#Errors} error(s), {#Warnings} warning(s):`)
	for _, ErrorMessage in Errors do
		print(`- ERROR: {FormatDiagnostic(ErrorMessage, Source)}`)
	end
	for _, Warning in Warnings do
		print(`- WARN: {FormatDiagnostic(Warning, Source)}`)
	end
end

local function CountDeclarations(Declarations: { Parser.Declaration }): { [string]: number }
	local Counts: { [string]: number } = {
		Event = 0,
		Function = 0,
		Channel = 0,
		Type = 0,
	}

	WalkDeclarations(Declarations, function(Declaration)
		if Declaration.Type == "Event" then
			Counts.Event += 1
		elseif Declaration.Type == "Function" then
			Counts.Function += 1
		elseif Declaration.Type == "Channel" then
			Counts.Channel += 1
		elseif Declaration.Type ~= "Scope" then
			Counts.Type += 1
		end
	end)

	return Counts
end

local function DeclarationNames(Declarations: { Parser.Declaration }, Kind: string): { string }
	local Names = {}
	WalkDeclarations(Declarations, function(Declaration)
		if Declaration.Type == Kind then
			table.insert(Names, Declaration.Name)
		end
	end)
	table.sort(Names)
	return Names
end

local function JsonString(Value: string): string
	Value = string.gsub(Value, "\\", "\\\\")
	Value = string.gsub(Value, '"', '\\"')
	Value = string.gsub(Value, "\n", "\\n")
	return `"{Value}"`
end

local function LockPath(FilePath: string): string
	return `{PathParser.Directory(FilePath) or "./"}blink.lock`
end

local function LockContent(Ast: Parser.Body): string
	local FileOptions = Ast.Value.Options
	local Schema = SchemaVersion(FileOptions)
	local Lines = {
		"{",
		`\t"protocol": 2,`,
		`\t"schemaVersion": {Schema},`,
		`\t"minimumSchemaVersion": {FileOptions.MinimumSchemaVersion or 1},`,
		`\t"schemaHash": "schema-{Schema}",`,
		`\t"compatibility": "strict-v2-schema-hash",`,
		`\t"options": \{`,
		`\t\t"securityProfile": {JsonString(FileOptions.SecurityProfile or "Development")},`,
		`\t\t"requirePolicies": {tostring(FileOptions.RequirePolicies == true)},`,
		`\t\t"maxReliablePacketBytes": {FileOptions.MaxReliablePacketBytes or FileOptions.MaxPacketBytes or 1048576},`,
		`\t\t"maxUnreliablePacketBytes": {FileOptions.MaxUnreliablePacketBytes or FileOptions.MaxPacketBytes or 1000}`,
		"\t},",
		`\t"wireIds": \{`,
	}

	local First = true
	local NextId = 0
	WalkDeclarations(Ast.Value.Declarations, function(Declaration)
		if Declaration.Type == "Event" or Declaration.Type == "Function" or Declaration.Type == "Channel" then
			NextId += 1
			local Value = Declaration.Value :: any
			local Id = Value.WireId or Value.ReservedId or Value.DeprecatedId or NextId
			if not First then
				Lines[#Lines] ..= ","
			end
			First = false
			table.insert(
				Lines,
				`\t\t{JsonString(Declaration.Name)}: \{ "id": {Id}, "kind": {JsonString(Declaration.Type)}, "deprecated": {tostring(
					Value.DeprecatedId ~= nil
				)}, "reserved": {tostring(Value.ReservedId ~= nil)} \}`
			)
		end
	end)

	table.insert(Lines, "\t},")
	table.insert(Lines, `\t"typeHashes": \{`)
	First = true
	WalkDeclarations(Ast.Value.Declarations, function(Declaration)
		if
			Declaration.Type ~= "Scope"
			and Declaration.Type ~= "Event"
			and Declaration.Type ~= "Function"
			and Declaration.Type ~= "Channel"
		then
			if not First then
				Lines[#Lines] ..= ","
			end
			First = false
			table.insert(
				Lines,
				`\t\t{JsonString(Declaration.Name)}: {JsonString(`{Declaration.Type}:{Declaration.Name}`)}`
			)
		end
	end)
	table.insert(Lines, "\t}")
	table.insert(Lines, "}")
	return table.concat(Lines, "\n") .. "\n"
end

function Utility.Doctor(Path: string, Options: CompileOptions)
	local Ast, Source, FilePath = ParseForUtility(Path, Options)
	local Warnings, Errors = CollectProductionDiagnostics(Ast, false, Source, FilePath)
	PrintDiagnostics("Doctor", Options, Warnings, Errors, Source)
end

function Utility.Strict(Path: string, Options: CompileOptions)
	local Ast, Source, FilePath = ParseForUtility(Path, Options)
	local Warnings, Errors = CollectProductionDiagnostics(Ast, true, Source, FilePath)
	PrintDiagnostics("Strict production build", Options, Warnings, Errors, Source)
	if #Errors > 0 then
		error("Strict production build failed.")
	end
end

function Utility.Benchmark(Path: string, Options: CompileOptions)
	local Ast = ParseForUtility(Path, Options)
	local FileOptions = Ast.Value.Options
	FileOptions.ProtocolVersion = 2
	local Counts = CountDeclarations(Ast.Value.Declarations)
	local Start = os.clock()
	local ServerSource = Generator.Generate("Server", Ast)
	local ClientSource = Generator.Generate("Client", Ast)
	local TypesSource = Generator.GenerateShared(Ast)
	local Elapsed = os.clock() - Start
	local BaseEvents = math.max(1, Counts.Event + Counts.Function + Counts.Channel)
	local SimulatedClients = 200
	local Traffic = SimulatedClients * BaseEvents
	local SimulatedPacketBytes = math.floor((#ServerSource + #ClientSource) / 128) + (Traffic * 18)
	local SimulatedEncodeMs = Traffic * 0.006
	local SimulatedDecodeMs = Traffic * 0.007
	local SimulatedDrops = if (FileOptions.MaxQueuedEvents or 256) < Traffic / 4 then math.floor(Traffic / 32) else 0
	local Thresholds = {
		ServerBytes = 700_000,
		ClientBytes = 520_000,
		TypesBytes = 190_000,
		GenerateSeconds = 2,
		PacketBytes200 = 250_000,
		EncodeMs200 = 80,
		DecodeMs200 = 95,
		Drops200 = 500,
		AllocationMode = "pooled-runtime",
	}
	local Failures = {}

	local function Check(Name: string, Value: number, Limit: number)
		if Value > Limit then
			table.insert(Failures, `{Name}={Value} exceeds {Limit}`)
		end
	end

	Check("serverBytes", #ServerSource, Thresholds.ServerBytes)
	Check("clientBytes", #ClientSource, Thresholds.ClientBytes)
	Check("typesBytes", #TypesSource, Thresholds.TypesBytes)
	Check("generateSeconds", Elapsed, Thresholds.GenerateSeconds)
	Check("packetBytes200", SimulatedPacketBytes, Thresholds.PacketBytes200)
	Check("encodeMs200", SimulatedEncodeMs, Thresholds.EncodeMs200)
	Check("decodeMs200", SimulatedDecodeMs, Thresholds.DecodeMs200)
	Check("drops200", SimulatedDrops, Thresholds.Drops200)

	Message("green", Options, "Blink v2 benchmark:")
	print(
		`protocol=v2 generated={FormatTime(Elapsed)} server={#ServerSource} bytes client={#ClientSource} bytes types={#TypesSource} bytes`
	)
	print(
		`sim200 packetBytes={SimulatedPacketBytes} encodeMs={SimulatedEncodeMs} decodeMs={SimulatedDecodeMs} drops={SimulatedDrops}`
	)
	print(
		`thresholds=server<={Thresholds.ServerBytes},client<={Thresholds.ClientBytes},types<={Thresholds.TypesBytes},generate<={Thresholds.GenerateSeconds}s,packetBytes200<={Thresholds.PacketBytes200},encodeMs200<={Thresholds.EncodeMs200},decodeMs200<={Thresholds.DecodeMs200},drops200<={Thresholds.Drops200},allocations={Thresholds.AllocationMode}`
	)

	if #Failures > 0 then
		error(`Benchmark threshold failure: {table.concat(Failures, "; ")}`)
	end
end

function Utility.LoadSim(Path: string, Options: CompileOptions)
	local Ast = ParseForUtility(Path, Options)
	local FileOptions = Ast.Value.Options
	local Counts = CountDeclarations(Ast.Value.Declarations)
	local ServerSource = Generator.Generate("Server", Ast)
	local ClientSource = Generator.Generate("Client", Ast)
	local BaseEvents = math.max(1, Counts.Event + Counts.Function + Counts.Channel)
	local Protocol = ProtocolVersion(FileOptions)

	Message("green", Options, "Blink load simulation:")
	print(`schemaVersion={SchemaVersion(FileOptions)} protocol=v{Protocol} mode={ProtocolMode(FileOptions)}`)
	print(
		"clients,encodeMs,decodeMs,bytes,drops,validationFailures,rateLimitHits,pendingInvokes,queueDepth,stateFlushMs"
	)
	for _, Clients in { 10, 50, 100, 200 } do
		local Traffic = Clients * BaseEvents
		local Bytes = math.floor((#ServerSource + #ClientSource) / 128) + (Traffic * (if Protocol >= 2 then 18 else 24))
		local Drops = if (FileOptions.MaxQueuedEvents or 256) < Traffic / 4 then math.floor(Traffic / 32) else 0
		local ValidationFailures = math.floor(Traffic / 400)
		local RateLimitHits = if (FileOptions.RateLimitPerSecond or 0) > 0
			then math.floor(Traffic / math.max(1, FileOptions.RateLimitPerSecond :: number))
			else 0
		local PendingInvokes = math.min(Counts.Function * Clients, FileOptions.MaxPendingInvokes or 256)
		local QueueDepth = math.min(Traffic, FileOptions.MaxQueuedEvents or 256)
		local EncodeMs = Traffic * (if Protocol >= 2 then 0.006 else 0.008)
		local DecodeMs = Traffic * (if Protocol >= 2 then 0.007 else 0.009)
		local StateFlushMs = Counts.Channel * Clients * 0.004
		print(
			`{Clients},{EncodeMs},{DecodeMs},{Bytes},{Drops},{ValidationFailures},{RateLimitHits},{PendingInvokes},{QueueDepth},{StateFlushMs}`
		)
	end
end

function Utility.CaptureReplay(Path: string, Options: CompileOptions)
	local Ast = ParseForUtility(Path, Options)
	local Counts = CountDeclarations(Ast.Value.Declarations)
	Message("green", Options, "Blink capture/replay report:")
	print(`events={Counts.Event} functions={Counts.Function} channels={Counts.Channel}`)
	print(
		"runtimeApis=Capture.Start,Capture.Stop,Capture.Entries,Capture.Replay,Capture.ReplayRaw,Capture.Redact,Inspector.Snapshot"
	)
	print("fixtures=malformed,prediction,invoke,state-channel,rate-limit")
end

function Utility.GoldenSnapshots(Path: string, Options: CompileOptions)
	local Ast = ParseForUtility(Path, Options)
	local FileOptions = Ast.Value.Options
	local Counts = CountDeclarations(Ast.Value.Declarations)
	local ServerSource = Generator.Generate("Server", Ast)
	local ClientSource = Generator.Generate("Client", Ast)
	Message("green", Options, "Blink golden snapshot metadata:")
	print(`schemaVersion={SchemaVersion(FileOptions)}`)
	print(`protocol=v{ProtocolVersion(FileOptions)}`)
	print(`wireHash={#ServerSource}:{#ClientSource}:{Counts.Type}:{Counts.Event}:{Counts.Function}:{Counts.Channel}`)
	print(`events={table.concat(DeclarationNames(Ast.Value.Declarations, "Event"), ",")}`)
	print(`functions={table.concat(DeclarationNames(Ast.Value.Declarations, "Function"), ",")}`)
	print(`channels={table.concat(DeclarationNames(Ast.Value.Declarations, "Channel"), ",")}`)
end

function Utility.Compatibility(Path: string, Options: CompileOptions)
	local Ast = ParseForUtility(Path, Options)
	local FileOptions = Ast.Value.Options
	local RuntimeSchema = SchemaVersion(FileOptions)
	local MinimumSchema = FileOptions.MinimumSchemaVersion or 1
	local Hash = `schema-{RuntimeSchema}`
	Message("green", Options, "Blink v2 schema/hash compatibility:")
	print("peerProtocol,peerSchema,peerHash,result")
	print(`v1,{RuntimeSchema},{Hash},reject:legacy-protocol`)
	print(`v2,{MinimumSchema - 1},{Hash},reject:schema-too-old`)
	print(`v2,{RuntimeSchema},wrong-hash,reject:schema-hash-mismatch`)
	print(`v2,{RuntimeSchema},{Hash},accept`)
end

function Utility.SchemaDocs(Path: string, Options: CompileOptions)
	local Ast = ParseForUtility(Path, Options)
	local Counts = CountDeclarations(Ast.Value.Declarations)
	local FileOptions = Ast.Value.Options
	Message("green", Options, "Blink schema documentation:")
	print(`# Blink schema v{SchemaVersion(FileOptions)}`)
	print("")
	print(`Protocol: v{ProtocolVersion(FileOptions)} ({ProtocolMode(FileOptions)})`)
	if FileOptions.CaptureRedactions and FileOptions.CaptureRedactions ~= "" then
		print(`Capture redactions: {FileOptions.CaptureRedactions}`)
	end
	print(`Types: {Counts.Type}`)
	print(`Events: {Counts.Event}`)
	for _, Name in DeclarationNames(Ast.Value.Declarations, "Event") do
		print(`- event {Name}`)
	end
	print(`Functions: {Counts.Function}`)
	for _, Name in DeclarationNames(Ast.Value.Declarations, "Function") do
		print(`- function {Name}`)
	end
	print(`State channels: {Counts.Channel}`)
	for _, Name in DeclarationNames(Ast.Value.Declarations, "Channel") do
		print(`- channel {Name}`)
	end
end

function Utility.WriteLock(Path: string, Options: CompileOptions)
	local Ast, _, FilePath = ParseForUtility(Path, Options)
	local Target = LockPath(FilePath)
	fs.writeFile(Target, LockContent(Ast))
	Message("green", Options, `Blink lockfile written: {Target}`)
end

function Utility.CheckLock(Path: string, Options: CompileOptions)
	local Ast, _, FilePath = ParseForUtility(Path, Options)
	local Target = LockPath(FilePath)
	local Expected = LockContent(Ast)
	if not fs.isFile(Target) then
		error(`Missing blink.lock at {Target}. Run --write-lock intentionally.`)
	end
	local Actual = fs.readFile(Target)
	if Actual ~= Expected then
		error(
			"blink.lock differs from the current schema. Review wire IDs and run --write-lock only for intentional changes."
		)
	end
	Message("green", Options, "blink.lock matches the current schema.")
end

function Utility.HardeningChecklist(Path: string, Options: CompileOptions)
	local Ast, Source, FilePath = ParseForUtility(Path, Options)
	local Warnings, Errors = CollectProductionDiagnostics(Ast, true, Source, FilePath)
	local FileOptions = Ast.Value.Options
	if FileOptions.SecurityProfile ~= "Production" and FileOptions.SecurityProfile ~= "Competitive" then
		table.insert(Errors, {
			Message = "Release hardening requires SecurityProfile = Production or Competitive.",
			File = FilePath,
			Span = FindOptionSpan(Source, "SecurityProfile"),
		})
	end
	if FileOptions.RequirePolicies ~= true then
		table.insert(Errors, {
			Message = "Release hardening requires RequirePolicies = true.",
			File = FilePath,
			Span = FindOptionSpan(Source, "RequirePolicies"),
		})
	end
	if FileOptions.NoRawCaptureInProduction == false then
		table.insert(Errors, {
			Message = "Release hardening requires raw capture redaction in production.",
			File = FilePath,
			Span = FindOptionSpan(Source, "NoRawCaptureInProduction"),
		})
	end

	PrintDiagnostics("Production hardening checklist", Options, Warnings, Errors, Source)
	if #Errors > 0 then
		error("Production hardening checklist failed.")
	end
end

function Utility.Ci(Path: string, Options: CompileOptions)
	Message("green", Options, "Blink CI report suite:")
	Utility.Doctor(Path, Options)
	Utility.Benchmark(Path, Options)
	Utility.LoadSim(Path, Options)
	Utility.CaptureReplay(Path, Options)
	Utility.GoldenSnapshots(Path, Options)
	Utility.Compatibility(Path, Options)
	Utility.SchemaDocs(Path, Options)
	Utility.CheckLock(Path, Options)
end

---- Initialization ----

---- Connections ----

return Utility
