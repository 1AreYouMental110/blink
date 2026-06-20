--!strict

-- ******************************* --
-- 			AX3NX / AXEN		   --
-- ******************************* --

---- Services ----

local RunService = game:GetService("RunService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local Selection = game:GetService("Selection")
local ServerStorage = game:GetService("ServerStorage")
local StudioService = game:GetService("StudioService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local TweenService = game:GetService("TweenService")

if RunService:IsRunning() then
	return
end

---- Imports ----

local Editor = require("@self/Editor")
local Profiler = require("@self/Profiler")
local State = require("@self/State")

local Generator = require("@compiler/Generator")
local Parser = require("@compiler/Parser")

---- Settings ----

local FILES_FOLDER = "BLINK_CONFIGURATION_FILES"
local TEMPLATE_FILE = {
	Name = "Template",
	Source = table.concat({
		"type Example = u8",
		"event MyEvent {",
		"\tFrom: Server,",
		"\tType: Reliable,",
		"\tCall: SingleSync,",
		"\tData: Example",
		"}",
	}, "\n"),
}

local ERROR_WIDGET = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, true, 500, 240, 300, 240)

local EDITOR_WIDGET = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Left, false, false, 360, 400, 300, 400)

local OBSERVABILITY_WIDGET = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 360, 420, 300, 260)

local SAVE_COLOR = Color3.fromRGB(0, 100, 0)
local BUTTON_COLOR = Color3.fromRGB(30, 30, 30)
local EXPAND_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

---- Constants ----

local Toolbar = plugin:CreateToolbar("Blink Suite")
local EditorButton = Toolbar:CreateButton("Editor", "Opens the configuration editor", "rbxassetid://118423040995617")
EditorButton.ClickableWhenViewportHidden = true
local ObservabilityButton =
	Toolbar:CreateButton("Metrics", "Opens Blink generation and runtime metric guidance", "rbxassetid://118423040995617")
ObservabilityButton.ClickableWhenViewportHidden = true

local Template = script.Widget
local FileTemplate = Template.Side.Content.Top.Files.File:Clone()

--> Remove templates
--Template.Editor.Text.Line:Destroy()
Template.Side.Content.Top.Files.File:Destroy()

local ErrorWidget = plugin:CreateDockWidgetPluginGui("Generation Error", ERROR_WIDGET)
ErrorWidget.Name = "Generation Error"
ErrorWidget.Title = "Error"
ErrorWidget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local ErrorInterface = script.Error:Clone()
ErrorInterface.Visible = true
ErrorInterface.Parent = ErrorWidget

local ErrorText: TextLabel = ErrorInterface.Text

local EditorWidget = plugin:CreateDockWidgetPluginGui("Configuration Editor", EDITOR_WIDGET)
EditorWidget.Name = "Blink Editor"
EditorWidget.Title = "Configuration Editor"
EditorWidget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local EditorInterface = script.Widget
EditorInterface.Size = UDim2.fromScale(1, 1)
EditorInterface.Parent = EditorWidget

local ObservabilityWidget = plugin:CreateDockWidgetPluginGui("Blink Observability", OBSERVABILITY_WIDGET)
ObservabilityWidget.Name = "Blink Observability"
ObservabilityWidget.Title = "Blink Observability"
ObservabilityWidget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local ObservabilityFrame = Instance.new("Frame")
ObservabilityFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
ObservabilityFrame.BorderSizePixel = 0
ObservabilityFrame.Size = UDim2.fromScale(1, 1)
ObservabilityFrame.Parent = ObservabilityWidget

local ObservabilityPadding = Instance.new("UIPadding")
ObservabilityPadding.PaddingTop = UDim.new(0, 12)
ObservabilityPadding.PaddingBottom = UDim.new(0, 12)
ObservabilityPadding.PaddingLeft = UDim.new(0, 12)
ObservabilityPadding.PaddingRight = UDim.new(0, 12)
ObservabilityPadding.Parent = ObservabilityFrame

local ObservabilityText = Instance.new("TextLabel")
ObservabilityText.BackgroundTransparency = 1
ObservabilityText.FontFace = Font.fromEnum(Enum.Font.Code)
ObservabilityText.RichText = false
ObservabilityText.TextColor3 = Color3.fromRGB(230, 230, 230)
ObservabilityText.TextSize = 14
ObservabilityText.TextWrapped = true
ObservabilityText.TextXAlignment = Enum.TextXAlignment.Left
ObservabilityText.TextYAlignment = Enum.TextYAlignment.Top
ObservabilityText.Size = UDim2.fromScale(1, 1)
ObservabilityText.Text = "Generate a Blink config to populate compiler metrics.\n\nRuntime modules now expose:\nStats()\nReport()\nStartReporter(seconds)"
ObservabilityText.Parent = ObservabilityFrame

local Side = EditorInterface.Side
local Overlay = EditorInterface.Overlay
local QuickActions = EditorInterface.Quick

local QuickSave = QuickActions.Save
local QuickClear = QuickActions.Clear

local Content = Side.Content
local Expand = Side.Expand
local Settings = Side.Settings

local Top = Content.Top
local Bottom = Content.Bottom

local Files = Top.Files
local Import = Top.Title.Import
local Search = Top.Title.Search.Input

local Prompt = Bottom.Save
local Buttons = Bottom.Buttons

local GeneratePrompt = Bottom.Generate
local GenerateButtons = GeneratePrompt.Buttons
local Hint = GeneratePrompt.Hint
local Generate = GenerateButtons.Generate
local CancelGenerate = GenerateButtons.Cancel

local Input = Prompt.Input
local Save = Buttons.Save
local Cancel = Buttons.Cancel

--> Tweens
local Tweens = {
	Editor = {
		Expand = {
			Side = TweenService:Create(Side, EXPAND_TWEEN, { Position = UDim2.new() }),
			Content = TweenService:Create(Content, EXPAND_TWEEN, { GroupTransparency = 0 }),
			Overlay = TweenService:Create(Overlay, EXPAND_TWEEN, { BackgroundTransparency = 0.5 }),
			Settings = TweenService:Create(Settings, EXPAND_TWEEN, { ImageTransparency = 1 }),
		},

		Retract = {
			Side = TweenService:Create(Side, EXPAND_TWEEN, { Position = Side.Position }),
			Content = TweenService:Create(Content, EXPAND_TWEEN, { GroupTransparency = 1 }),
			Overlay = TweenService:Create(Overlay, EXPAND_TWEEN, { BackgroundTransparency = 1 }),
			Settings = TweenService:Create(Settings, EXPAND_TWEEN, { ImageTransparency = 0 }),
		},
	},
}

---- Variables ----

local Saving = false
local IsFirstTimeOpening = true

local Expanded = State.new(false)
local Selected: State.Class<Instance?> = State.new(nil :: any)
local Generating: State.Class<StringValue?> = State.new(nil :: any)

local Editing: string?

local ProfilerTick = 0
local ProfilerClicks = 0

---- Private Functions ----

--> Interface utility functions

local function FormatDuration(Seconds: number): string
	return string.format("%.2f ms", Seconds * 1_000)
end

local function FormatBytes(Bytes: number): string
	if Bytes >= 1024 * 1024 then
		return string.format("%.2f MiB", Bytes / (1024 * 1024))
	elseif Bytes >= 1024 then
		return string.format("%.2f KiB", Bytes / 1024)
	end

	return `{Bytes} B`
end

local function SetObservabilityText(Text: string)
	ObservabilityText.Text = Text
end

local function ShowError(Error: string)
	local Start = string.find(Error, "<font", 1, true)
	ErrorText.Text = string.sub(Error, Start or 1, #Error)
	ErrorText.RichText = true
	ErrorWidget.Enabled = true
end

local function PlayTweens(Tweens: { [string]: Tween })
	for _, Tween in Tweens do
		Tween:Play()
	end
end

local function CreateOrUpdateModuleScript(Name: string, Source: string, Parent: Instance)
	local ModuleScript = Parent:FindFirstChild(Name)
	if not ModuleScript or not ModuleScript:IsA("ModuleScript") then
		if ModuleScript then
			ModuleScript:Destroy()
		end

		ModuleScript = Instance.new("ModuleScript")
		ModuleScript.Name = Name
		ModuleScript.Parent = Parent
	end

	--> Update source after parenting to DM
	ScriptEditorService:UpdateSourceAsync(ModuleScript :: ModuleScript, function()
		return Source
	end)
end

local function GetPathParts(Path: string, DefaultPath: string): { string }
	local Normalized = if Path ~= "" then Path else DefaultPath
	Normalized = string.gsub(Normalized, "\\", "/")
	Normalized = string.gsub(Normalized, "^%./", "")
	Normalized = string.gsub(Normalized, "%.luau$", "")
	Normalized = string.gsub(Normalized, "%.lua$", "")

	local Parts = {}
	for Part in string.gmatch(Normalized, "[^/%s]+") do
		local DotParts = string.split(Part, ".")
		for _, DotPart in DotParts do
			if DotPart ~= "" and DotPart ~= "." then
				table.insert(Parts, DotPart)
			end
		end
	end

	if #Parts == 0 then
		return string.split(DefaultPath, "/")
	end

	return Parts
end

local function EnsureFolderPath(Root: Instance, Parts: { string }): Instance
	local Parent = Root
	for Index = 1, #Parts - 1 do
		local Name = Parts[Index]
		local Child = Parent:FindFirstChild(Name)
		if not Child or not Child:IsA("Folder") then
			if Child then
				Child:Destroy()
			end

			local Folder = Instance.new("Folder")
			Folder.Name = Name
			Folder.Parent = Parent
			Child = Folder
		end

		Parent = Child
	end

	return Parent
end

local function WriteGeneratedModule(Root: Instance, Path: string, DefaultPath: string, Source: string)
	local Parts = GetPathParts(Path, DefaultPath)
	local Parent = EnsureFolderPath(Root, Parts)
	CreateOrUpdateModuleScript(Parts[#Parts], Source, Parent)
end

local function RequestScriptPermissions(): boolean
	local Success = pcall(function()
		local Script = Instance.new("Script", script)
		Script:Destroy()
	end)

	return Success
end

local function ClearChildrenWhichAre(Parent: Instance, Class: string)
	for Index, Child in Parent:GetChildren() do
		if Child:IsA(Class) then
			Child:Destroy()
		end
	end
end

--> Files utility functions

local function GetSaveFolder(): Folder
	local SaveFolder = ServerStorage:FindFirstChild(FILES_FOLDER)
	if not SaveFolder then
		local Folder = Instance.new("Folder")
		Folder.Name = FILES_FOLDER
		Folder.Parent = ServerStorage
		SaveFolder = Folder
	end

	return SaveFolder
end

local function GenerateFile(File: StringValue, Directory: Instance)
	local Source = File.Value
	local SourceParser = Parser.new()
	local ParseStarted = os.clock()
	local Success, Error, AbstractSyntaxTree = pcall(function()
		return nil, SourceParser:Parse(Source)
	end)
	local ParseSeconds = os.clock() - ParseStarted

	if not Success then
		ShowError(tostring(Error))
		SetObservabilityText(`Generation failed for {File.Name}\n\nParse time: {FormatDuration(ParseSeconds)}\n\n{tostring(Error)}`)
		return
	end

	if not RequestScriptPermissions() then
		ShowError("File generation failed, plugin doesn't have script inject permissions.")
		warn("[BLINK]: File generation failed, plugin doesn't have script inject permissions.")
		SetObservabilityText(`Generation failed for {File.Name}\n\nThe plugin does not have script inject permissions.`)
		return
	end

	local FileOptions = AbstractSyntaxTree.Value.Options
	local GenerateStarted = os.clock()
	local ServerSource = Generator.Generate("Server", AbstractSyntaxTree)
	local ClientSource = Generator.Generate("Client", AbstractSyntaxTree)
	local TypesSource = Generator.GenerateShared(AbstractSyntaxTree)
	local GenerateSeconds = os.clock() - GenerateStarted

	ChangeHistoryService:SetWaypoint("Before Blink generation")
	WriteGeneratedModule(Directory, FileOptions.TypesOutput or "", "Blink/Types", TypesSource)
	WriteGeneratedModule(Directory, FileOptions.ServerOutput or "", "Blink/Server", ServerSource)
	WriteGeneratedModule(Directory, FileOptions.ClientOutput or "", "Blink/Client", ClientSource)
	ChangeHistoryService:SetWaypoint("After Blink generation")
	SetObservabilityText(table.concat({
		`Last generation: {File.Name}`,
		`Parse: {FormatDuration(ParseSeconds)}`,
		`Generate: {FormatDuration(GenerateSeconds)}`,
		`Server: {FormatBytes(#ServerSource)}`,
		`Client: {FormatBytes(#ClientSource)}`,
		`Types: {FormatBytes(#TypesSource)}`,
		"",
		"Runtime metrics:",
		"local Net = require(path.to.Blink.Server)",
		"print(Net.Stats())",
		"Net.Report()",
		"local stop = Net.StartReporter(5)",
	}, "\n"))
end

local function LoadFile(File: StringValue)
	Expanded:Set(false)
	Editing = File.Name
	Editor.SetSource(File.Value)
end

local function LoadFiles()
	--> Remove previous files
	Generating:Set()
	ClearChildrenWhichAre(Files, "Frame")

	--> Load new files
	local FileInstances = GetSaveFolder():GetChildren()
	table.sort(FileInstances, function(a, b)
		return a.Name < b.Name
	end)

	for _, File: StringValue in FileInstances :: { any } do
		local Name = File.Name
		local Frame = FileTemplate:Clone()
		local Buttons = Frame.Buttons

		Frame.Name = Name
		Frame.Title.Text = Name

		Buttons.Edit.MouseButton1Click:Connect(function()
			LoadFile(File)
		end)

		Buttons.Delete.MouseButton1Click:Connect(function()
			ChangeHistoryService:SetWaypoint(`Before deleting Blink config {File.Name}`)
			File:Destroy()
			LoadFiles()
			ChangeHistoryService:SetWaypoint(`After deleting Blink config {File.Name}`)
		end)

		Buttons.Generate.MouseButton1Click:Connect(function()
			if GeneratePrompt.Visible then
				return
			end

			Generating:Set(File)
		end)

		Frame.Parent = Files
	end
end

local function SaveFile(Name: string, Source: string)
	local SaveFolder = GetSaveFolder()
	local SaveInstance: StringValue? = SaveFolder:FindFirstChild(Name) :: StringValue
	ChangeHistoryService:SetWaypoint(`Before saving Blink config {Name}`)
	if not SaveInstance then
		local NewSaveInstance = Instance.new("StringValue")
		NewSaveInstance.Name = Name
		NewSaveInstance.Value = Source
		NewSaveInstance.Parent = SaveFolder
		ChangeHistoryService:SetWaypoint(`After saving Blink config {Name}`)
		return
	end

	SaveInstance.Value = Source
	ChangeHistoryService:SetWaypoint(`After saving Blink config {Name}`)
end

local function CreateTemplateFile()
	if ServerStorage:FindFirstChild(FILES_FOLDER) then
		return
	end

	SaveFile(TEMPLATE_FILE.Name, TEMPLATE_FILE.Source)
	LoadFile(GetSaveFolder():FindFirstChild(TEMPLATE_FILE.Name) :: StringValue)
end

local function HandleFirstTimeOpen()
	if IsFirstTimeOpening == false then
		return
	end

	CreateTemplateFile()
	LoadFiles()
	IsFirstTimeOpening = false
end

---- Public Functions ----

local function OnSearch(PressedEnter: boolean)
	if not PressedEnter then
		return
	end

	local Query = Search.Text
	for _, Frame in Files:GetChildren() do
		if not Frame:IsA("Frame") then
			continue
		end

		if Query == "" then
			Frame.Visible = true
			continue
		end

		Frame.Visible = (string.find(Frame.Name, Query) ~= nil)
	end
end

local function OnSaveCompleted()
	Saving = false
	Prompt.Visible = false
	Cancel.Visible = false
	Save.BackgroundColor3 = BUTTON_COLOR
end

local function OnSaveActivated()
	if Saving then
		local Name = Input.Text
		if Name == "" then
			return
		end

		SaveFile(Name, Editor.GetSource())
		LoadFiles()
		OnSaveCompleted()

		return
	end

	Saving = true
	Input.Text = Editing or ""
	Prompt.Visible = true
	Cancel.Visible = true
	Save.BackgroundColor3 = SAVE_COLOR
end

local function OnExpandActivated()
	HandleFirstTimeOpen()
	Expanded:Set(not Expanded:Get())
end

local function OnEditorButtonClicked()
	HandleFirstTimeOpen()
	EditorWidget.Enabled = not EditorWidget.Enabled
end

local function OnEditorWidgetEnabled()
	EditorButton:SetActive(EditorWidget.Enabled)
end

local function OnObservabilityButtonClicked()
	ObservabilityWidget.Enabled = not ObservabilityWidget.Enabled
end

local function OnObservabilityWidgetEnabled()
	ObservabilityButton:SetActive(ObservabilityWidget.Enabled)
end

local function OnQuickSave()
	if Expanded:Get() then
		return
	end

	if not Editing then
		Expanded:Set(true)
		OnSaveActivated()
		return
	end

	SaveFile(Editing, Editor.GetSource())
end

local function OnQuickClear()
	if Expanded:Get() then
		return
	end

	Editor.SetSource("")
end

local function OnImport()
	local File: File? = StudioService:PromptImportFile({ "blink", "txt" })
	if not File then
		return
	end

	Editing = nil
	Expanded:Set(false)
	Editor.SetSource(File:GetBinaryContents())
end

local function OnExpandRightClicked()
	if ProfilerClicks == 0 then
		ProfilerTick = os.clock()
		ProfilerClicks += 1
		return
	end

	local Elapsed = (os.clock() - ProfilerTick)
	if Elapsed > 1 then
		ProfilerTick = os.clock()
		return
	end

	ProfilerTick = 0
	ProfilerClicks = 0
	Profiler.toggle()
end

---- Initialization ----

Editor.Initialize(EditorWidget)
Profiler.Initialize()

---- Connections ----

Expanded:OnChange(function(Value)
	--Content.Visible = Value
	PlayTweens(Value and Tweens.Editor.Expand or Tweens.Editor.Retract)
end)

Selected:OnChange(function(Value: Instance?)
	Generate.TextTransparency = Value and 0 or 0.5
	Hint.Text = Value and `<b>Selected</b>\n{Value:GetFullName()}`
		or "Select the location in which to generate the output scripts."
end)

Generating:OnChange(function(File: StringValue?)
	GeneratePrompt.Visible = (File ~= nil)
end)

Selection.SelectionChanged:Connect(function()
	local Instances = Selection:Get()
	Selected:Set(Instances[1])
end)

Generate.MouseButton1Click:Connect(function()
	local File = Generating:Get()
	if not File then
		return
	end

	local Directory = Selected:Get()
	if not Directory then
		return
	end

	Generating:Set()
	GenerateFile(File, Directory)
end)

CancelGenerate.MouseButton1Click:Connect(function()
	Generating:Set()
end)

Import.MouseButton1Click:Connect(OnImport)
Search.FocusLost:Connect(OnSearch)
Save.MouseButton1Click:Connect(OnSaveActivated)
Cancel.MouseButton1Click:Connect(OnSaveCompleted)
Expand.MouseButton1Click:Connect(OnExpandActivated)
Expand.MouseButton2Click:Connect(OnExpandRightClicked)
QuickSave.MouseButton1Click:Connect(OnQuickSave)
QuickClear.MouseButton1Click:Connect(OnQuickClear)
EditorButton.Click:Connect(OnEditorButtonClicked)
EditorWidget:GetPropertyChangedSignal("Enabled"):Connect(OnEditorWidgetEnabled)
ObservabilityButton.Click:Connect(OnObservabilityButtonClicked)
ObservabilityWidget:GetPropertyChangedSignal("Enabled"):Connect(OnObservabilityWidgetEnabled)
