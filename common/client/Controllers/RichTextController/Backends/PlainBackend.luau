local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Config = SharedConfig.RichTextConfig

--[[
	The fallback backend: plain text in a TextLabel.

	It exists for two jobs.

	The first is being the safety net. If the vendor falls out of sync, breaks on an
	engine update, or fails its require, the controller drops down to this and the
	sentence appears: no shake, no color, no typewriter, but it appears. A server
	restart warning that vanishes because a text library broke is a big loss for a
	small cause.

	The second is proving that swapping technology works. Two backends force the
	interface to be real: what `RichTextController` can do is what both can answer.
	A third backend, if one comes, enters through the same door.

	**What it does not do.** No effects: aliases become empty (except `[br]`, which
	becomes a real line break). `[event=...]` does not fire: `OnEvent` here never
	calls back, and anything that syncs dialog with the camera needs a path that
	does not depend on it alone. `OnFinished` calls as soon as the text is in,
	because there is no typing to wait for here.

	See docs/common/rich-text.md.
]]

local Backend = {
	Name = "Plain"
}

local LABEL_NAME = "RichTextPlain"

--[[ INTERNAL ]]

--[=[
	The TextLabel to write into.

	A container that is already a text object is the label itself: that is the common
	case, and respecting what the designer authored (font, size, anchor) beats
	anything we would choose. A Frame container gets a label filling it, created once
	and reused.
]=]
local function resolveLabel(container : GuiObject) : TextLabel | TextButton | TextBox
	if container:IsA("TextLabel") or container:IsA("TextButton") or container:IsA("TextBox") then
		return container
	end

	local existing = container:FindFirstChild(LABEL_NAME)
	if existing and existing:IsA("TextLabel") then
		return existing
	end

	local label = Instance.new("TextLabel")
	label.Name = LABEL_NAME
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextWrapped = true
	label.TextScaled = false
	label.Text = ""
	label.Parent = container

	return label
end

--[[ BACKEND API ]]

--[=[
	Loads nothing, so it never fails. That is what makes it last in line in
	`RichTextConfig.Backends`.
]=]
function Backend.Load() : boolean
	return true
end

--[=[
	A known alias disappears; `[br]` becomes a line break. A name that is not an alias
	returns `nil` and goes back to being plain text, as in the other backends: the
	rule for what is a tag and what is a stray bracket must be the same in both, or
	the text changes meaning when the fallback kicks in.
]=]
function Backend.Tag(name : string, _value : string?, _closing : boolean) : string?
	if not Config.Aliases[name] then
		return nil
	end

	if name == "br" then
		return "\n"
	end

	return ""
end

function Backend.Create(container : GuiObject) : any
	return {
		Container = container,
		Label = resolveLabel(container),
		Text = "",
		Finished = {},
	}
end

--[=[
	The options that survive without any effect: color, size, font, alignment.

	It only applies what was requested: what the designer left on the label still
	applies for the rest.
]=]
function Backend.Apply(object : any, options : any)
	local label = object.Label

	if options.Size then
		label.TextSize = options.Size
	end

	if options.Color then
		label.TextColor3 = options.Color
	end

	if options.Transparency then
		label.TextTransparency = options.Transparency
	end

	if options.Font then
		local success, font = pcall(
			Font.new,
			options.Font,
			options.Weight or Enum.FontWeight.Regular,
			if options.Italic then Enum.FontStyle.Italic else Enum.FontStyle.Normal
		)

		if success then
			label.FontFace = font
		end
	end

	if options.Align then
		label.TextXAlignment = Enum.TextXAlignment[options.Align.Name]
	end

	if options.VerticalAlign then
		label.TextYAlignment = Enum.TextYAlignment[options.VerticalAlign.Name]
	end

	if options.ZIndex then
		label.ZIndex = options.ZIndex
	end

	if options.Wrapped ~= nil then
		label.TextWrapped = options.Wrapped
	end
end

--[=[
	Writes everything at once.

	A raw library tag (the `<...>` someone in a hurry writes directly) is stripped
	here too: in HyperText it becomes an effect, and what becomes an effect there
	must not become a scribble on screen here.
]=]
function Backend.Render(object : any, text : string, _options : any)
	local plain = (string.gsub(text, "<[^<>]->", ""))

	object.Text = plain
	object.Label.Text = plain

	for _, callback in object.Finished do
		task.spawn(callback, false)
	end
end

function Backend.Skip(_object : any)
end

function Backend.Pause(_object : any)
end

function Backend.Resume(_object : any)
end

function Backend.Clear(object : any, _instant : boolean?)
	object.Text = ""
	object.Label.Text = ""
end

function Backend.Destroy(object : any)
	table.clear(object.Finished)

	if object.Label.Name == LABEL_NAME then
		object.Label:Destroy()
	else
		object.Label.Text = ""
	end
end

--[=[
	Never writing: the text appears whole inside `Render`.
]=]
function Backend.IsRendering(_object : any) : boolean
	return false
end

function Backend.GetText(object : any) : string?
	return object.Text
end

function Backend.OnFinished(object : any, callback : (skipped : boolean) -> ()) : () -> ()
	table.insert(object.Finished, callback)

	return function()
		local index = table.find(object.Finished, callback)
		if index then
			table.remove(object.Finished, index)
		end
	end
end

--[=[
	Fires nothing: without typing, there is no "the sentence reached the middle". It
	still returns the disconnect function so callers do not need to know which
	backend they are on.
]=]
function Backend.OnEvent(_object : any, _callback : (name : string) -> ()) : () -> ()
	return function() end
end

return Backend
