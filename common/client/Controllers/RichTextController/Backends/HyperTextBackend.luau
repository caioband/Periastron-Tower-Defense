local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local log = Log.new("RichTextController")

local Config = SharedConfig.RichTextConfig

--[[
	The backend that speaks HyperText.

	This is the only file in the game that knows HyperText exists. It translates two
	things: `RichTextController`'s neutral options into the library's markups, and
	`RichTextConfig`'s aliases into its tags.

	**The require is late and inside a pcall** on purpose. `Me:Load()` requires every
	descendant of `Controllers` in an unprotected loop: a vendor require error up
	here would take down the whole client boot, and the price of rendering text must
	not be the player's screen. On failure, `Load()` returns `false` and the
	controller drops to the next backend.

	About the vendor: `ReplicatedStorage.Shared.Vendor.HyperText`, v4.2.0, MIT; the
	license and source commit are in the `Attribution.luau` next to it.

	See docs/common/rich-text.md.
]]

local Backend = {
	Name = "HyperText"
}

local HyperText = nil :: any

--[=[
	A neutral value becoming a HyperText value, for things that do not share a unit
	on both sides. It is the alias table's `Converter`.
]=]
local Converters = {
	--[[
		Characters per second (how you think about a typewriter) become seconds per
		character (how HyperText counts). Zero or less is "all at once", which there
		is a zero interval.
	]]
	Speed = function(value : string) : string?
		local speed = tonumber(value)
		if not speed then
			return nil
		end

		if speed <= 0 then
			return "0"
		end

		return string.format("%.4f", 1 / speed)
	end,

	--[[
		The name of a `RichTextConfig.Gradients` palette becomes the tag's attributes.

		The game writes `[gradient=orange]` and does not need to know that on the other
		side there is an attribute called `colors` with semicolons in it. A palette
		that does not exist returns `nil`, and the alias warns instead of drawing some
		random gradient.
	]]
	Gradient = function(value : string) : string?
		local palette = Config.Gradients[value]
		if not palette then
			return nil
		end

		local attributes = { `colors={palette.Colors}` }

		if palette.MoveSpeed then
			table.insert(attributes, `moveSpeed={palette.MoveSpeed}`)
		end

		if palette.MoveDir then
			table.insert(attributes, `moveDir={palette.MoveDir}`)
		end

		if palette.Rot then
			table.insert(attributes, `rot={palette.Rot}`)
		end

		return table.concat(attributes, " ")
	end,
}

--[[ INTERNAL ]]

--[=[
	An alias value going inside a tag.

	`<` and `>` would escape the tag and become another one; `%` would break
	`string.format`. None of these appear in a legitimate value (a color, a number,
	an id), so stripping is more honest than escaping.
]=]
local function sanitize(value : string) : string
	return (string.gsub(value, "[<>%%]", ""))
end

--[=[
	A sound id the way HyperText wants it: a URI. Accepts a number because that is
	how asset ids travel in the game config.
]=]
local function toSoundURI(sound : string | number) : string
	if type(sound) == "number" then
		return `rbxassetid://{sound}`
	end

	return sound
end

--[[ BACKEND API ]]

--[=[
	Loads the library. `false` when it is not there or does not load; the controller
	handles that and drops to the next backend.
]=]
function Backend.Load() : boolean
	if HyperText then
		return true
	end

	local folder = Vendor:FindFirstChild("HyperText")
	local main = folder and folder:FindFirstChild("Main")
	if not main or not main:IsA("ModuleScript") then
		return false
	end

	local success, result = pcall(require, main)
	if not success then
		log:StudioWarn(`HyperText did not load: {result}`)

		return false
	end

	HyperText = result

	return true
end

--[=[
	An alias becoming a HyperText tag. `nil` when the name is not an alias; then the
	controller returns the bracket to the text as plain text.
]=]
function Backend.Tag(name : string, value : string?, closing : boolean) : string?
	local alias = Config.Aliases[name]
	local dialect = alias and alias.HyperText
	if not dialect then
		return nil
	end

	if closing then
		return dialect.Close or ""
	end

	local open = dialect.Open
	if not string.find(open, "%%s") then
		return open
	end

	local raw = value or alias.Default
	if not raw then
		log:StudioWarn(`alias "{name}" needs a value: [{name}=...].`)

		return ""
	end

	if alias.Converter then
		local converter = Converters[alias.Converter]
		local converted = converter and converter(raw)

		if not converted then
			log:StudioWarn(`invalid value in [{name}={raw}].`)

			return ""
		end

		raw = converted
	end

	return string.format(open, sanitize(raw))
end

--[=[
	The container's render object.

	A TextLabel container gets its own text cleared: HyperText draws **inside** the
	container, and the text authored in Studio would sit under the render, left over
	on screen. The label still serves as the frame (size, position, anchor); that is
	what the designer looks after.
]=]
function Backend.Create(container : GuiObject) : any
	if container:IsA("TextLabel") or container:IsA("TextButton") or container:IsA("TextBox") then
		container.Text = ""
	end

	local success, result = pcall(HyperText.new, container)
	if not success then
		log:StudioWarn(`could not create the renderer in {container:GetFullName()}: {result}`)

		return nil
	end

	return result
end

--[=[
	Neutral options becoming the object's default markups.

	Only what was requested goes into the dictionary: `newMarkups()` starts empty and
	`UpdateDefaultMarkups` merges, so what does not come here stays at the library
	default instead of being reset.
]=]
function Backend.Apply(object : any, options : any)
	local markups = HyperText.newMarkups()

	if options.Size then
		markups.size.value = options.Size
	end

	if options.Color then
		markups.color.value = options.Color
	end

	if options.Font then
		markups.font.value = options.Font
	end

	if options.Weight then
		markups.weight.value = options.Weight
	end

	if options.Italic ~= nil then
		markups.italic.value = options.Italic
	end

	if options.Transparency then
		markups.trans.value = options.Transparency
	end

	if options.Speed then
		markups.interval.value = if options.Speed > 0 then 1 / options.Speed else 0
	end

	if options.Sound then
		markups.soundId.value = toSoundURI(options.Sound)
		markups.soundId.attributes.volume = options.SoundVolume
	end

	if options.Anim then
		-- "none" is the absence of the entrance animation, and absence in HyperText is
		-- written by deleting the markup, which is optional precisely for that.
		markups.anim.value = if options.Anim == "none" then HyperText.DELETE else options.Anim
		markups.anim.attributes.dur = options.AnimDuration
		markups.anim.attributes.loop = options.AnimLoop
	end

	if options.Stroke then
		markups.stroke.value = true
		markups.stroke.attributes.thickness = options.Stroke.Thickness
		markups.stroke.attributes.color = options.Stroke.Color
		markups.stroke.attributes.trans = options.Stroke.Transparency
	end

	if options.Shadow then
		markups.shadow.value = true
		markups.shadow.attributes.color = options.Shadow.Color
		markups.shadow.attributes.offset = options.Shadow.Offset
	end

	if options.Align then
		markups.horizontalAlignment.value = options.Align
	end

	if options.VerticalAlign then
		markups.verticalAlignment.value = options.VerticalAlign
	end

	if options.ZIndex then
		markups.ZIndex.value = options.ZIndex
	end

	-- A rejected value (a color where it expects a number, a font that does not exist)
	-- kills the caller's thread, and the caller is a game screen. It becomes a warning.
	local success, result = pcall(object.UpdateDefaultMarkups, object, markups)
	if not success then
		log:StudioWarn(`HyperText rejected the options: {result}`)
	end
end

--[=[
	Renders.

	The sizeless-container warning is ours, not the library's: it simply draws
	nothing when the container measures zero (a disabled screen, a frame that has not
	been through layout yet), and a render that does not happen **and does not
	complain** is half an hour of looking for the bug in the wrong place.
]=]
function Backend.Render(object : any, text : string, options : any)
	local container = object._container
	if container and container.AbsoluteSize.Magnitude == 0 then
		log:StudioWarn(`{container:GetFullName()} measures zero on screen; the text was not drawn.`)
	end

	object:Render(text, options.Yield, options.Wrapped)
end

function Backend.Skip(object : any)
	object:CompleteRender()
end

function Backend.Pause(object : any)
	object:PauseRender()
end

function Backend.Resume(object : any)
	object:ResumeRender()
end

function Backend.Clear(object : any, instant : boolean?)
	object:Clear(instant)
end

function Backend.Destroy(object : any)
	object:Destroy()
end

function Backend.IsRendering(object : any) : boolean
	return object.rendering
end

function Backend.GetText(object : any) : string?
	return object:GetPlainText()
end

function Backend.OnFinished(object : any, callback : (skipped : boolean) -> ()) : () -> ()
	local connection = object.onRenderEnded:Connect(callback)

	return function()
		connection:Disconnect()
	end
end

function Backend.OnEvent(object : any, callback : (name : string) -> ()) : () -> ()
	local connection = object.renderEvent:Connect(callback)

	return function()
		connection:Disconnect()
	end
end

return Backend
