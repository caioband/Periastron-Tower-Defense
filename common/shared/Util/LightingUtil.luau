--[[
	Pieces shared by `LightingService` (server) and `LightingController` (client):
	finding the presets folder, reading a preset's values, and interpolating.

	See `SharedConfig.LightingConfig` for the preset format, and
	docs/common/lighting.md.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Config = SharedConfig.LightingConfig

local LightingUtil = {}

--[[ PRESETS FOLDER ]]

--[[
	Finds (server) or waits for (client) the presets folder.

	`create` is only true on the server: `Assets` is place content, not synced by
	Rojo, so the `Lighting` subfolder may simply not exist yet.
]]
function LightingUtil.GetPresetsRoot(create: boolean?, timeout: number?): Folder?
	local current: Instance = ReplicatedStorage

	for _, name in Config.PresetsPath do
		local nextChild = current:FindFirstChild(name)

		if not nextChild and create then
			local folder = Instance.new("Folder")
			folder.Name = name
			folder.Parent = current
			nextChild = folder
		elseif not nextChild then
			nextChild = current:WaitForChild(name, timeout or 30)
		end

		if not nextChild then
			return nil
		end

		current = nextChild
	end

	return current :: Folder
end

--[[ READING ]]

--[[
	Property values of a preset instance (Sky, Atmosphere, an effect…).

	Reads only what `LightingConfig.Properties` lists for its class; the `pcall`
	covers a property the engine removed or locked in a new version, without
	breaking the whole transition over one.
]]
function LightingUtil.ReadInstance(instance: Instance): { [string]: any }
	local values = {}

	for _, propertyName in Config:GetProperties(instance.ClassName) do
		local ok, value = pcall(function()
			return (instance :: any)[propertyName]
		end)

		if ok then
			values[propertyName] = value
		end
	end

	return values
end

--[[
	Properties of Lighting itself that the preset declares: the Folder's
	attributes. An attribute whose name is not in `LightingConfig` is ignored (it
	may be a note from whoever built the preset).
]]
function LightingUtil.ReadPresetAttributes(folder: Instance): { [string]: any }
	local attributes = folder:GetAttributes()
	local values = {}

	for _, propertyName in Config:GetProperties("Lighting") do
		if attributes[propertyName] ~= nil then
			values[propertyName] = attributes[propertyName]
		end
	end

	return values
end

--[[ INTERPOLATION ]]

--[[
	Types that can be halfway. The rest (boolean, string, EnumItem,
	NumberSequence, ColorSequence) does not interpolate and is applied at once; see
	`LightingController`, which picks the moment of the cut.
]]
local INTERPOLATORS: { [string]: (any, any, number) -> any } = {
	number = function(a, b, t)
		return a + (b - a) * t
	end,

	Color3 = function(a, b, t)
		return a:Lerp(b, t)
	end,

	Vector2 = function(a, b, t)
		return a:Lerp(b, t)
	end,

	Vector3 = function(a, b, t)
		return a:Lerp(b, t)
	end,

	CFrame = function(a, b, t)
		return a:Lerp(b, t)
	end,

	UDim2 = function(a, b, t)
		return a:Lerp(b, t)
	end,

	UDim = function(a, b, t)
		return UDim.new(a.Scale + (b.Scale - a.Scale) * t, a.Offset + (b.Offset - a.Offset) * t)
	end,

	NumberRange = function(a, b, t)
		return NumberRange.new(a.Min + (b.Min - a.Min) * t, a.Max + (b.Max - a.Max) * t)
	end,

	Rect = function(a, b, t)
		return Rect.new(a.Min:Lerp(b.Min, t), a.Max:Lerp(b.Max, t))
	end,
}

-- Interpolation only exists between two values of the same interpolable type.
function LightingUtil.GetInterpolator(from: any, to: any): ((any, any, number) -> any)?
	local fromType = typeof(from)
	if fromType ~= typeof(to) then
		return nil
	end

	return INTERPOLATORS[fromType]
end

-- An easing curve without creating a Tween: `GetValue` is the same math TweenService does.
function LightingUtil.Ease(alpha: number): number
	return TweenService:GetValue(math.clamp(alpha, 0, 1), Config.Transition.Style, Config.Transition.Direction)
end

--[[ THE PANELS' BLUR ]]

--[=[
	The name of the `BlurEffect` the UI panels share.

	**One for everyone**, so it is looked up before being created: `UILibraryController`
	uses the same blur for its panels and the Lobby shops reuse it. Two
	`BlurEffect`s in Lighting add up, and the background would get twice the blur
	with two panels open.
]=]
LightingUtil.UI_BLUR_NAME = "UIBlur"

--[=[
	The panels' blur, created the first time someone asks.

	It is (re)created with the `KeepAttribute` mark: without it, it is a Lighting
	child that belongs to no preset, and a preset change would sweep it. The mark is
	always (re)written, because the instance may come from another system without it.
]=]
function LightingUtil.GetUIBlur(): BlurEffect
	local blur = Lighting:FindFirstChild(LightingUtil.UI_BLUR_NAME)

	if not blur or not blur:IsA("BlurEffect") then
		blur = Instance.new("BlurEffect")
		blur.Name = LightingUtil.UI_BLUR_NAME
		blur.Size = 0
		blur.Parent = Lighting
	end

	blur:SetAttribute(Config.KeepAttribute, true)

	return blur
end

--[=[
	Tweens the blur to `size` and returns the tween, so the caller can cancel it.

	Canceling is what lets two requests chain: `Tween:Cancel()` does not restore
	the property, so closing mid-open goes down from where the rise reached instead
	of two tweens writing the same `Size`. Keep the return in a maid: one tween per
	panel at a time.

	Zeroing a blur that does not exist returns nil and creates nothing: a panel that
	closes without ever opening (a new `ScreenGui`'s bind runs the close) must not
	leave a `BlurEffect` per player in Lighting.
]=]
function LightingUtil.TweenUIBlur(size: number, info: TweenInfo): Tween?
	if size <= 0 and not Lighting:FindFirstChild(LightingUtil.UI_BLUR_NAME) then
		return nil
	end

	local tween = TweenService:Create(LightingUtil.GetUIBlur(), info, { Size = size })
	tween:Play()

	return tween
end

return LightingUtil
