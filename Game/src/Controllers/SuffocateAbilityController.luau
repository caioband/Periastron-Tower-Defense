local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Assets = Shared:WaitForChild("Assets")

local GameClock = require(Shared.Util.GameClock)
local Me = require(Vendor.Me)

local Framework = Me.new()

local PRELOAD_NAME = "Suffocated"

local SuffocateAbilityController = {
	Controllers = {
		UnitPlacementController = {},
		VFXController = {},
	},
	Active = {},
}

function SuffocateAbilityController:preload()
	local list = {}

	local units = Assets:FindFirstChild("Units")
	if units then
		for _, model in units:GetChildren() do
			local animation = model:FindFirstChild(PRELOAD_NAME)
			if animation and animation:IsA("Animation") then
				table.insert(list, animation)
			end
		end
	end

	local animations = Assets:FindFirstChild("Animations")
	local shared = animations and animations:FindFirstChild(PRELOAD_NAME)
	if shared and shared:IsA("Animation") then
		table.insert(list, shared)
	end

	if #list > 0 then
		ContentProvider:PreloadAsync(list)
	end
end

function SuffocateAbilityController:getClass(unitId : string)
	local placement = self.Controllers.UnitPlacementController
	local class = placement and placement.classesById[unitId]
	if not class or not class.model or not class.model.Parent then
		return nil
	end
	return class
end

function SuffocateAbilityController:getTrack(class, animationName : string)
	class.loadedAnimations = class.loadedAnimations or {}

	local track = class.loadedAnimations[animationName]
	if track then
		return track
	end

	local animations = Assets:FindFirstChild("Animations")
	local shared = animations and animations:FindFirstChild(animationName)
	if not (shared and shared:IsA("Animation")) then
		return nil
	end

	local controller = class.model:FindFirstChildWhichIsA("AnimationController")
	local animator = controller and controller:FindFirstChildWhichIsA("Animator")
	if not animator then
		return nil
	end

	track = animator:LoadAnimation(shared)
	class.loadedAnimations[animationName] = track
	return track
end

function SuffocateAbilityController:fadeOut(unitId : string, fadeTime : number)
	local active = self.Active[unitId]
	if not active then
		local class = self:getClass(unitId)
		if not class then
			return
		end
		active = { Class = class }
		self.Active[unitId] = active
	end

	local model = active.Class.model
	if not model or not model.Parent or active.Faded then
		return
	end

	local realTime = math.max(fadeTime / math.max(GameClock.GetScale(), 0.01), 0.05)
	local info = TweenInfo.new(realTime, Enum.EasingStyle.Linear)
	local skip = active.VFX

	active.Faded = {}

	for _, descendant in model:GetDescendants() do
		if skip and (descendant.Name == skip or descendant:FindFirstAncestor(skip)) then
			continue
		end
		if descendant:IsA("BasePart") or descendant:IsA("Decal") or descendant:IsA("Texture") then
			active.Faded[descendant] = descendant.Transparency
			TweenService:Create(descendant, info, { Transparency = 1 }):Play()
		end
	end
end

function SuffocateAbilityController:restore(active)
	local faded = active.Faded
	if not faded then
		return
	end
	active.Faded = nil

	local info = TweenInfo.new(0.2, Enum.EasingStyle.Linear)
	for instance, original in faded do
		if instance.Parent then
			TweenService:Create(instance, info, { Transparency = original }):Play()
		end
	end
end

function SuffocateAbilityController:start()
	for name in self.Controllers do
		self.Controllers[name] = Framework:Get(name)
	end

	task.spawn(function()
		self:preload()
	end)

	Framework:Listen("UnitSuffocate", function(unitId, duration, animationName, vfxName)
		if typeof(unitId) ~= "string" or typeof(duration) ~= "number" then
			return
		end

		local class = self:getClass(unitId)
		if not class then
			return
		end

		local active = { Class = class }
		self.Active[unitId] = active

		if typeof(animationName) == "string" then
			local track = self:getTrack(class, animationName)
			if track then
				track.Priority = Enum.AnimationPriority.Action4
				track:Play(0)
				track:AdjustSpeed(GameClock.GetScale())
				active.Track = track
			end
		end

		local vfx = self.Controllers.VFXController
		if vfx and typeof(vfxName) == "string" and vfxName ~= "" then
			active.VFX = vfxName
			vfx:PlayVictimVFX(class.model, vfxName, duration)
		end
	end)

	Framework:Listen("UnitSuffocateEnd", function(unitId)
		local active = self.Active[unitId]
		if not active then
			return
		end
		self.Active[unitId] = nil

		self:restore(active)

		if active.Track then
			active.Track:Stop(0.2)
		end

		local model = active.Class.model
		local vfx = self.Controllers.VFXController
		if active.VFX and vfx and model and model.Parent then
			vfx:StopVictimVFX(model, active.VFX)
		end
	end)

	Framework:Listen("UnitSuffocateFade", function(unitId, fadeTime)
		if typeof(unitId) ~= "string" or typeof(fadeTime) ~= "number" then
			return
		end
		self:fadeOut(unitId, fadeTime)
	end)
end

function SuffocateAbilityController:init()
end

return SuffocateAbilityController